import AppKit
import ScreenSaver

/// The bundle's principal class: adapts the macOS ScreenSaver interface to `TrinityMetalView`.
///
/// The host creates one instance per display, plus one for the System Settings thumbnail.
/// `startAnimation()` and `stopAnimation()` start and stop the Metal view; the host's
/// `animateOneFrame` timer is unused because a display link drives presentation.
@MainActor
@objc(TrinityScreenSaverView)
final class TrinityScreenSaverView: ScreenSaverView {
	/// The rendering subview, filling this view; nil only if it was never set up.
	private var metalView: TrinityMetalView?
	/// The open options sheet's controller; nil while no sheet is shown.
	private var options: TrinityOptionsController?

	/// Creates the view for the host, either fullscreen or as a System Settings preview.
	override init?(frame: NSRect, isPreview: Bool) {
		super.init(frame: frame, isPreview: isPreview)
		setUp()
	}

	/// Creates the view from an archive.
	required init?(coder: NSCoder) {
		super.init(coder: coder)
		setUp()
	}

	/// Adds the Metal view, stopped until `startAnimation()`.
	private func setUp() {
		// The host's timer is intentionally idle: CADisplayLink owns presentation.
		animationTimeInterval = 1
		let view = TrinityMetalView(frame: bounds, context: .screenSaver)
		view.autoresizingMask = [.width, .height]
		addSubview(view)
		metalView = view
	}

	/// Fills with black, visible only before the Metal layer presents its first frame.
	override func draw(_ rect: NSRect) {
		NSColor.black.setFill()
		rect.fill()
	}

	/// Reloads the saved settings, which may have changed since this instance was created, and starts rendering.
	override func startAnimation() {
		super.startAnimation()
		metalView?.configuration = .load()
		metalView?.start()
	}

	/// Stops rendering, so a dismissed instance submits no more GPU work.
	override func stopAnimation() {
		metalView?.stop()
		super.stopAnimation()
	}

	/// Intentionally empty: the display link owns presentation.
	override func animateOneFrame() {}

	/// Stops rendering when removed from a window and resumes it when re-added while animating.
	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if window == nil { metalView?.stop() }
		else if isAnimating { metalView?.start() }
	}

	/// Trinity always offers an options sheet.
	override var hasConfigureSheet: Bool { true }

	/// The options sheet, on the saved settings. Apply saves them and applies them to this instance.
	///
	/// The host may read this property more than once per presentation. Return the open
	/// sheet rather than building another controller with its own running preview.
	override var configureSheet: NSWindow? {
		if let window = options?.window { return window }

		let controller = TrinityOptionsController(configuration: .load(), context: .screenSaver) { [weak self] result in
			if let result {
				result.save()
				self?.metalView?.configuration = result
			}
			self?.options = nil
		}
		options = controller
		return controller.window
	}
}
