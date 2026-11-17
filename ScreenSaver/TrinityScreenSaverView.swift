import AppKit
import ScreenSaver

@MainActor
@objc(TrinityScreenSaverView)
final class TrinityScreenSaverView: ScreenSaverView {
	private var metalView: TrinityMetalView?
	private var options: TrinityOptionsController?

	override init?(frame: NSRect, isPreview: Bool) {
		super.init(frame: frame, isPreview: isPreview)
		setUp()
	}

	required init?(coder: NSCoder) {
		super.init(coder: coder)
		setUp()
	}

	private func setUp() {
		// The host's timer is intentionally idle: CADisplayLink owns presentation.
		animationTimeInterval = 1
		let view = TrinityMetalView(frame: bounds, context: .screenSaver)
		view.autoresizingMask = [.width, .height]
		addSubview(view)
		metalView = view
	}

	override func draw(_ rect: NSRect) {
		NSColor.black.setFill()
		rect.fill()
	}

	override func startAnimation() {
		super.startAnimation()
		metalView?.configuration = .load()
		metalView?.start()
	}

	override func stopAnimation() {
		metalView?.stop()
		super.stopAnimation()
	}

	override func animateOneFrame() {}
	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if window == nil { metalView?.stop() }
		else if isAnimating { metalView?.start() }
	}

	override var hasConfigureSheet: Bool { true }
	// The host may read this property more than once per presentation. Return the open
	// sheet rather than building another controller with its own running preview.
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
