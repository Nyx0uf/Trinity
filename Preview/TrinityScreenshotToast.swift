import AppKit

/// A nonmodal screenshot status banner using the system's adaptive Liquid Glass material.
/// AppKit handles transparency, contrast and glass motion preferences; presentation adds no animation.
@MainActor
final class TrinityScreenshotToast: NSGlassEffectView {
	/// Wrapping status text, also announced to assistive technologies when it changes.
	private let messageLabel = NSTextField(wrappingLabelWithString: "")
	/// One-shot dismissal timer, replaced whenever a newer screenshot status arrives.
	private var dismissalTimer: Timer?

	/// Creates a hidden glass banner whose size follows its text and the available window width.
	init() {
		super.init(frame: .zero)
		translatesAutoresizingMaskIntoConstraints = false
		style = .regular
		cornerRadius = 16
		isHidden = true

		let content = NSView()
		content.translatesAutoresizingMaskIntoConstraints = false
		contentView = content
		messageLabel.translatesAutoresizingMaskIntoConstraints = false
		messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
		messageLabel.textColor = .labelColor
		messageLabel.alignment = .center
		messageLabel.isSelectable = true
		content.addSubview(messageLabel)
		NSLayoutConstraint.activate([
			content.leadingAnchor.constraint(equalTo: leadingAnchor),
			content.trailingAnchor.constraint(equalTo: trailingAnchor),
			content.topAnchor.constraint(equalTo: topAnchor),
			content.bottomAnchor.constraint(equalTo: bottomAnchor),
			messageLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
			messageLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
			messageLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
			messageLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
			widthAnchor.constraint(lessThanOrEqualToConstant: 520)
		])
	}

	/// Not supported: the toast is always created in code.
	required init?(coder: NSCoder) { nil }

	/// Shows the latest status without moving focus; an omitted duration keeps progress visible.
	func show(_ message: String, isError: Bool = false, dismissAfter duration: TimeInterval? = nil) {
		dismissalTimer?.invalidate()
		dismissalTimer = nil
		messageLabel.stringValue = message
		isHidden = false
		NSAccessibility.post(
			element: messageLabel,
			notification: .announcementRequested,
			userInfo: [
				.announcement: message,
				.priority: (isError ? NSAccessibilityPriorityLevel.high : .medium).rawValue
			]
		)
		if let duration {
			dismissalTimer = Timer.scheduledTimer(timeInterval: duration, target: self, selector: #selector(dismiss), userInfo: nil, repeats: false)
		}
	}

	/// Hides the banner and cancels any outstanding dismissal when the window closes or status expires.
	@objc func dismiss() {
		dismissalTimer?.invalidate()
		dismissalTimer = nil
		isHidden = true
	}
}
