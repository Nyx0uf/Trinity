import AppKit

@MainActor
final class TrinityOptionsController: NSWindowController {
	private var draft: TrinityConfiguration
	private let preview: TrinityMetalView
	private var sliders: [NSSlider] = []
	private var values: [NSTextField] = []
	private let frameRate = NSPopUpButton()
	private var completion: ((TrinityConfiguration?) -> Void)?

	init(
		configuration: TrinityConfiguration,
		context: TrinityPresentationContext = .application,
		completion: @escaping (TrinityConfiguration?) -> Void
	) {
		draft = configuration
		preview = TrinityMetalView(frame: .zero, configuration: configuration, context: context)
		self.completion = completion
		let window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.title = "Trinity Options"
		super.init(window: window)
		buildContent()
		refreshControls()
		preview.start()
	}

	required init?(coder: NSCoder) { nil }

	private func buildContent() {
		guard let content = window?.contentView else { return }

		let outer = NSStackView()
		outer.orientation = .vertical
		outer.spacing = 12
		outer.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
		outer.translatesAutoresizingMaskIntoConstraints = false
		content.addSubview(outer)
		NSLayoutConstraint.activate([
			outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
			outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
			outer.topAnchor.constraint(equalTo: content.topAnchor),
			outer.bottomAnchor.constraint(equalTo: content.bottomAnchor)
		])
		let title = NSTextField(labelWithString: "Trinity")
		title.font = .systemFont(ofSize: 22, weight: .semibold)
		outer.addArrangedSubview(title)
		preview.translatesAutoresizingMaskIntoConstraints = false
		outer.addArrangedSubview(preview)
		preview.heightAnchor.constraint(equalToConstant: 160).isActive = true
		preview.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -48).isActive = true
		for (index, parameter) in TrinityParameter.all.enumerated() {
			let label = NSTextField(labelWithString: parameter.title)
			label.widthAnchor.constraint(equalToConstant: 150).isActive = true
			let slider = NSSlider(
				value: 0,
				minValue: parameter.range.lowerBound,
				maxValue: parameter.range.upperBound,
				target: self,
				action: #selector(sliderChanged(_:))
			)
			slider.tag = index
			slider.isContinuous = true
			slider.setAccessibilityLabel(parameter.title)
			slider.widthAnchor.constraint(equalToConstant: 430).isActive = true
			let value = NSTextField(labelWithString: "")
			value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
			value.alignment = .right
			value.widthAnchor.constraint(equalToConstant: 58).isActive = true
			let row = NSStackView(views: [label, slider, value])
			row.spacing = 12
			outer.addArrangedSubview(row)
			sliders.append(slider)
			values.append(value)
		}
		for policy in TrinityFrameRate.allCases { frameRate.addItem(withTitle: policy.title) }
		frameRate.target = self
		frameRate.action = #selector(frameRateChanged)
		frameRate.setAccessibilityLabel("Frame rate")
		outer.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "Frame rate"), frameRate]))
		let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
		let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
		cancel.keyEquivalent = "\u{1b}"
		let apply = NSButton(title: "Apply", target: self, action: #selector(apply))
		apply.keyEquivalent = "\r"
		let spacer = NSView()
		spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
		let buttons = NSStackView(views: [reset, spacer, cancel, apply])
		outer.addArrangedSubview(buttons)
		buttons.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
	}

	private func refreshControls() {
		for (index, parameter) in TrinityParameter.all.enumerated() {
			let number = draft[keyPath: parameter.keyPath]
			sliders[index].doubleValue = number
			values[index].stringValue = number.formatted(.number.precision(.fractionLength(parameter.decimals)))
		}
		frameRate.selectItem(at: draft.frameRate.rawValue)
		preview.configuration = draft
	}

	@objc private func sliderChanged(_ sender: NSSlider) {
		let parameter = TrinityParameter.all[sender.tag]
		draft[keyPath: parameter.keyPath] = parameter.decimals == 0 ? sender.doubleValue.rounded() : sender.doubleValue
		refreshControls()
	}

	@objc private func frameRateChanged() {
		draft.frameRate = TrinityFrameRate(rawValue: frameRate.indexOfSelectedItem) ?? .display
		preview.configuration = draft
	}

	@objc private func restoreDefaults() {
		draft = .defaults
		refreshControls()
	}

	@objc private func apply() { finish(draft.validated()) }
	@objc private func cancel() { finish(nil) }

	private func finish(_ result: TrinityConfiguration?) {
		preview.stop()
		if let window, let parent = window.sheetParent { parent.endSheet(window) }
		else { window?.orderOut(nil) }
		let callback = completion
		completion = nil
		callback?(result)
	}
}
