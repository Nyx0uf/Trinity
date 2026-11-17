import AppKit
import QuartzCore

enum TrinityPresentationContext {
	case application
	case screenSaver
}

@MainActor
private final class TrinityDisplayLinkTarget: NSObject {
	weak var view: TrinityMetalView?
	init(_ view: TrinityMetalView) { self.view = view }
	@objc func tick(_ link: CADisplayLink) { view?.tick(link) }
}

@MainActor
final class TrinityMetalView: NSView {
	var configuration: TrinityConfiguration {
		didSet {
			if oldValue.frameRate != configuration.frameRate { renderer?.resetTiming() }
			updateFrameRate()
		}
	}

	var onError: ((String) -> Void)?
	private(set) var renderer: TrinityRenderer?
	private(set) var failureMessage: String?
	private var displayLink: CADisplayLink?
	private var linkTarget: TrinityDisplayLinkTarget?
	private var requestedRunning = false
	private var displaySleeping = false
	private let metalLayer = CAMetalLayer()
	private var observersInstalled = false
	private let presentationContext: TrinityPresentationContext

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

	required init?(coder: NSCoder) { nil }

	// The display link retains only a weak forwarding target. The view therefore
	// remains releasable even if the host fails to balance start/stop calls.
	isolated deinit {
		displayLink?.invalidate()
		NotificationCenter.default.removeObserver(self)
		NSWorkspace.shared.notificationCenter.removeObserver(self)
	}

	func start() {
		requestedRunning = true
		installObservers()
		reconcileAnimation()
	}

	func stop() {
		requestedRunning = false
		invalidateLink()
		removeObservers()
	}

	private func installObservers() {
		guard !observersInstalled else { return }

		observersInstalled = true
		let workspace = NSWorkspace.shared.notificationCenter
		workspace.addObserver(self, selector: #selector(screensSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
		workspace.addObserver(self, selector: #selector(screensWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSWindow.didChangeScreenNotification, object: nil)
		NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
	}

	private func removeObservers() {
		observersInstalled = false
		let workspace = NSWorkspace.shared.notificationCenter
		workspace.removeObserver(self, name: NSWorkspace.screensDidSleepNotification, object: nil)
		workspace.removeObserver(self, name: NSWorkspace.screensDidWakeNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
		NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
	}

	@objc private func screensSleep() {
		displaySleeping = true
		reconcileAnimation()
	}

	@objc private func screensWake() {
		displaySleeping = false
		reconcileAnimation()
	}

	@objc private func screenChanged() {
		updateDrawableSize()
		updateFrameRate()
	}

	@objc private func visibilityChanged() { reconcileAnimation() }

	private func invalidateLink() {
		displayLink?.invalidate()
		displayLink = nil
		linkTarget = nil
		renderer?.resetTiming()
	}

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

	private func updateFrameRate() {
		let rate = configuration.frameRate.requestedRate(on: window?.screen)
		displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
	}

	private func updateDrawableSize() {
		let scale = window?.backingScaleFactor ?? 1
		metalLayer.contentsScale = scale
		let size = CGSize(width: max(0, bounds.width * scale), height: max(0, bounds.height * scale))
		if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
	}

	override func layout() {
		super.layout()
		updateDrawableSize()
	}

	override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		updateDrawableSize()
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		updateDrawableSize()
		reconcileAnimation()
	}

	override func viewDidHide() {
		super.viewDidHide()
		reconcileAnimation()
	}

	override func viewDidUnhide() {
		super.viewDidUnhide()
		reconcileAnimation()
	}

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
