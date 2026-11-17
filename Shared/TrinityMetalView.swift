import AppKit
import QuartzCore

/// Where a `TrinityMetalView` is presented, which decides whether window occlusion gates rendering.
enum TrinityPresentationContext {
	/// A window of the preview app, or the options window's live preview outside the screensaver.
	/// Rendering pauses while the window is occluded.
	case application
	/// The macOS screensaver host, whose remotely presented windows misreport occlusion.
	case screenSaver
}

/// Display-link target that forwards ticks to a weakly held view, so the link never keeps
/// the view alive.
@MainActor
private final class TrinityDisplayLinkTarget: NSObject {
	/// The view receiving ticks; ticks stop being forwarded once it is released.
	weak var view: TrinityMetalView?

	/// Creates a target forwarding to `view`.
	init(_ view: TrinityMetalView) { self.view = view }

	/// Display-link callback.
	@objc func tick(_ link: CADisplayLink) { view?.tick(link) }
}

/// Layer-backed view presenting `TrinityRenderer` through a `CAMetalLayer` and a view-bound
/// display link.
///
/// It is the single source of truth for whether frames are drawn: the link runs only while
/// `start()` has been requested, the displays are awake, and the view is in a window and not hidden.
@MainActor
final class TrinityMetalView: NSView {
	/// Settings applied from the next frame. A frame-rate policy change resets timing.
	var configuration: TrinityConfiguration {
		didSet {
			if oldValue.frameRate != configuration.frameRate { renderer?.resetTiming() }
			updateFrameRate()
		}
	}

	/// Called with a localized message when a frame fails and rendering stops. Setup failures
	/// are reported through `failureMessage` instead, since they happen before this can be set.
	var onError: ((String) -> Void)?
	/// The renderer, or nil when Metal setup failed.
	private(set) var renderer: TrinityRenderer?
	/// Localized description of the setup or rendering failure that stopped this view; nil while healthy.
	private(set) var failureMessage: String?
	/// The running display link; nil while stopped.
	private var displayLink: CADisplayLink?
	/// Retains the link's weak forwarding target while the link exists.
	private var linkTarget: TrinityDisplayLinkTarget?
	/// Whether the owner asked for animation with `start()`.
	private var requestedRunning = false
	/// True between the system's screens-did-sleep and screens-did-wake notifications.
	private var displaySleeping = false
	/// The view's backing layer and the drawable source for every frame.
	private let metalLayer = CAMetalLayer()
	/// Whether the sleep, wake and window observers are registered; true between `start()` and `stop()`.
	private var observersInstalled = false
	/// The window whose screen and occlusion notifications this view receives; nil when none is observed.
	private weak var observedWindow: NSWindow?
	/// Decides whether occlusion pauses rendering.
	private let presentationContext: TrinityPresentationContext

	/// Creates a stopped view and its renderer. A setup failure is logged and recorded in
	/// `failureMessage`, leaving the view black. Call `start()` to begin animating.
	init(frame: NSRect, configuration: TrinityConfiguration = .load(), context: TrinityPresentationContext = .application) {
		self.configuration = configuration
		presentationContext = context
		super.init(frame: frame)
		wantsLayer = true
		layer = metalLayer
		metalLayer.backgroundColor = NSColor.black.cgColor
		metalLayer.pixelFormat = .bgra8Unorm
		metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
		metalLayer.framebufferOnly = true
		metalLayer.isOpaque = true
		metalLayer.maximumDrawableCount = 3
		metalLayer.allowsNextDrawableTimeout = true
		do {
			let renderer = try TrinityRenderer(bundle: Bundle(for: Self.self))
			self.renderer = renderer
			metalLayer.device = renderer.device
		} catch {
			failureMessage = error.localizedDescription
			TrinityLog.rendering.error("Cannot start rendering: \(error.localizedDescription, privacy: .public)")
		}
	}

	/// Not supported: the view is always created in code.
	required init?(coder: NSCoder) { nil }

	// The display link retains only a weak forwarding target. The view therefore
	// remains releasable even if the host fails to balance start/stop calls.
	isolated deinit {
		displayLink?.invalidate()
		NotificationCenter.default.removeObserver(self)
		NSWorkspace.shared.notificationCenter.removeObserver(self)
	}

	/// Requests animation. Frames are drawn once the view is in a visible window and the displays are awake.
	func start() {
		requestedRunning = true
		installObservers()
		reconcileAnimation()
	}

	/// Stops animation: invalidates the display link, so no further GPU work is submitted, and removes observers.
	func stop() {
		requestedRunning = false
		invalidateLink()
		removeObservers()
	}

	/// Registers for display sleep and wake and for the current window's notifications.
	private func installObservers() {
		guard !observersInstalled else { return }

		observersInstalled = true
		let workspace = NSWorkspace.shared.notificationCenter
		workspace.addObserver(self, selector: #selector(screensSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
		workspace.addObserver(self, selector: #selector(screensWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
		observeWindow()
	}

	/// Removes every observer registered by `installObservers()`.
	private func removeObservers() {
		observersInstalled = false
		let workspace = NSWorkspace.shared.notificationCenter
		workspace.removeObserver(self, name: NSWorkspace.screensDidSleepNotification, object: nil)
		workspace.removeObserver(self, name: NSWorkspace.screensDidWakeNotification, object: nil)
		stopObservingWindow()
	}

	/// Observes screen and occlusion changes of the current window, replacing any previous window.
	///
	/// Display sleep is system-wide, but screen and occlusion changes come from this view's
	/// own window only. Several screensaver instances share one host process, one per display,
	/// and must not react to each other's windows. Called again whenever the view changes window.
	private func observeWindow() {
		guard observersInstalled, observedWindow !== window else { return }

		stopObservingWindow()
		guard let window else { return }

		let center = NotificationCenter.default
		center.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: window)
		center.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
		observedWindow = window
	}

	/// Stops observing `observedWindow`.
	private func stopObservingWindow() {
		let center = NotificationCenter.default
		center.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: observedWindow)
		center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: observedWindow)
		observedWindow = nil
	}

	/// Pauses rendering while the displays sleep.
	@objc private func screensSleep() {
		displaySleeping = true
		reconcileAnimation()
	}

	/// Resumes rendering, if still requested, when the displays wake.
	@objc private func screensWake() {
		displaySleeping = false
		reconcileAnimation()
	}

	/// Adapts the drawable size and frame rate after the window moves to another screen.
	@objc private func screenChanged() {
		updateDrawableSize()
		updateFrameRate()
	}

	/// Re-evaluates whether to run after the window's occlusion state changes.
	@objc private func visibilityChanged() { reconcileAnimation() }

	/// Invalidates and releases the display link and resets timing so resuming does not catch up.
	private func invalidateLink() {
		displayLink?.invalidate()
		displayLink = nil
		linkTarget = nil
		renderer?.resetTiming()
	}

	/// Creates or invalidates the display link to match the current running conditions.
	private func reconcileAnimation() {
		guard requestedRunning, !displaySleeping, window != nil, !isHiddenOrHasHiddenAncestor,
		      renderer != nil, failureMessage == nil else {
			invalidateLink()
			return
		}

		if displayLink == nil {
			let target = TrinityDisplayLinkTarget(self)
			let link = displayLink(target: target, selector: #selector(TrinityDisplayLinkTarget.tick(_:)))
			linkTarget = target
			displayLink = link
			updateFrameRate()
			link.add(to: .main, forMode: .common)
		}
	}

	/// Applies the configured frame-rate policy for the window's current screen.
	private func updateFrameRate() {
		let rate = configuration.frameRate.requestedRate(on: window?.screen)
		displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
	}

	/// Matches the layer's scale and drawable size to the view's bounds in backing pixels.
	private func updateDrawableSize() {
		let scale = window?.backingScaleFactor ?? 1
		metalLayer.contentsScale = scale
		let size = CGSize(width: max(0, bounds.width * scale), height: max(0, bounds.height * scale))
		if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
	}

	/// Resizes the drawable after layout.
	override func layout() {
		super.layout()
		updateDrawableSize()
	}

	/// Resizes the drawable after a backing scale change.
	override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		updateDrawableSize()
	}

	/// Follows the new window's notifications, size and frame rate, and starts or stops rendering.
	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		observeWindow()
		updateDrawableSize()
		updateFrameRate()
		reconcileAnimation()
	}

	/// Stops rendering while hidden.
	override func viewDidHide() {
		super.viewDidHide()
		reconcileAnimation()
	}

	/// Resumes rendering, if still requested, when shown again.
	override func viewDidUnhide() {
		super.viewDidUnhide()
		reconcileAnimation()
	}

	/// Renders one frame for `link`'s target timestamp, or invalidates the link when the running
	/// conditions no longer hold. A rendering failure stops the view and reports `onError`.
	fileprivate func tick(_ link: CADisplayLink) {
		guard requestedRunning, !displaySleeping, let window, !isHiddenOrHasHiddenAncestor else {
			invalidateLink()
			return
		}

		// legacyScreenSaver presents its service window remotely. In fullscreen,
		// that window reports no .visible occlusion flag even while on screen.
		// Its display link and ScreenSaverView lifecycle remain the rendering gates.
		if presentationContext == .application && !window.occlusionState.contains(.visible) {
			renderer?.resetTiming()
			return
		}
		do {
			try renderer?.render(to: metalLayer, at: link.targetTimestamp, configuration: configuration)
		} catch {
			failureMessage = error.localizedDescription
			TrinityLog.rendering.error("Rendering stopped: \(error.localizedDescription, privacy: .public)")
			invalidateLink()
			onError?(error.localizedDescription)
		}
	}
}
