import AppKit

/// Options window editing a draft configuration with its own live preview.
///
/// Used as a sheet by both the preview app and the screensaver. Apply passes the validated draft
/// to the completion, Cancel passes nil, and Restore Defaults only resets the draft. The owner saves.
@MainActor
final class TrinityOptionsController: NSWindowController {
	/// The settings being edited; applied to the preview immediately, saved only on Apply.
	private var draft: TrinityConfiguration
	/// Live preview of `draft`, running from creation until the window closes.
	private let preview: TrinityMetalView
	/// One slider per `TrinityParameter.all` entry, in the same order; each slider's tag is its index.
	private var sliders: [NSSlider] = []
	/// Value labels matching `sliders`.
	private var values: [NSTextField] = []
	/// Frame-rate policy pop-up; item indices are `TrinityFrameRate` raw values.
	private let frameRate = NSPopUpButton()
	/// Called once when the window closes; released afterwards so it cannot run twice.
	private var completion: ((TrinityConfiguration?) -> Void)?

	/// Builds the window around `configuration` and starts its preview in `context`.
	/// `completion` receives the validated settings on Apply, or nil on Cancel.
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
		window.title = String(localized: .optionsWindowTitle)
		super.init(window: window)
		buildContent()
		refreshControls()
		preview.start()
	}

	/// Not supported: the controller is always created in code.
	required init?(coder: NSCoder) { nil }

	/// Lays out the heading, preview, one slider row per parameter, the frame-rate pop-up and the buttons.
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
		let title = NSTextField(labelWithString: String(localized: .optionsHeading))
		title.font = .systemFont(ofSize: 22, weight: .semibold)
		outer.addArrangedSubview(title)
		preview.translatesAutoresizingMaskIntoConstraints = false
		outer.addArrangedSubview(preview)
		preview.heightAnchor.constraint(equalToConstant: 160).isActive = true
		preview.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -48).isActive = true
		for (index, parameter) in TrinityParameter.all.enumerated() {
			let name = String(localized: parameter.title)
			let label = NSTextField(labelWithString: name)
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
			slider.setAccessibilityLabel(name)
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
		let frameRateTitle = String(localized: .optionsFrameRate)
		frameRate.setAccessibilityLabel(frameRateTitle)
		outer.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: frameRateTitle), frameRate]))
		let reset = NSButton(title: String(localized: .optionsRestoreDefaults), target: self, action: #selector(restoreDefaults))
		let cancel = NSButton(title: String(localized: .optionsCancel), target: self, action: #selector(cancel))
		cancel.keyEquivalent = "\u{1b}"
		let apply = NSButton(title: String(localized: .optionsApply), target: self, action: #selector(apply))
		apply.keyEquivalent = "\r"
		let spacer = NSView()
		spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
		let buttons = NSStackView(views: [reset, spacer, cancel, apply])
		outer.addArrangedSubview(buttons)
		buttons.widthAnchor.constraint(equalTo: preview.widthAnchor).isActive = true
	}

	/// Shows `draft` in every control and the preview.
	private func refreshControls() {
		for (index, parameter) in TrinityParameter.all.enumerated() {
			let number = draft[keyPath: parameter.keyPath]
			sliders[index].doubleValue = number
			values[index].stringValue = number.formatted(.number.precision(.fractionLength(parameter.decimals)))
		}
		frameRate.selectItem(at: draft.frameRate.rawValue)
		preview.configuration = draft
	}

	/// Stores a slider's value in the draft, rounding whole-number parameters.
	@objc private func sliderChanged(_ sender: NSSlider) {
		let parameter = TrinityParameter.all[sender.tag]
		draft[keyPath: parameter.keyPath] = parameter.decimals == 0 ? sender.doubleValue.rounded() : sender.doubleValue
		refreshControls()
	}

	/// Stores the selected frame-rate policy in the draft.
	@objc private func frameRateChanged() {
		draft.frameRate = TrinityFrameRate(rawValue: frameRate.indexOfSelectedItem) ?? .display
		preview.configuration = draft
	}

	/// Resets the draft, not the saved settings, to the defaults.
	@objc private func restoreDefaults() {
		draft = .defaults
		refreshControls()
	}

	/// Closes the window with the validated draft.
	@objc private func apply() { finish(draft.validated()) }

	/// Closes the window without a result.
	@objc private func cancel() { finish(nil) }

	/// Stops the preview, closes the sheet or window, and calls the completion once.
	private func finish(_ result: TrinityConfiguration?) {
		preview.stop()
		if let window, let parent = window.sheetParent { parent.endSheet(window) }
		else { window?.orderOut(nil) }
		let callback = completion
		completion = nil
		callback?(result)
	}
}
