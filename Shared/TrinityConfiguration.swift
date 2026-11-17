import AppKit
import ScreenSaver

/// Presentation-rate policy for the display link. Raw values are persisted and index the options pop-up.
enum TrinityFrameRate: Int, CaseIterable, Codable {
	/// Follows the screen's maximum refresh rate.
	case display
	/// Caps presentation at 60 frames per second.
	case sixty
	/// Caps presentation at 30 frames per second.
	case thirty

	/// Localized name shown in the options pop-up.
	var title: String {
		switch self {
			case .display:
				String(localized: .frameRateMatchDisplay)

			case .sixty:
				String(localized: .frameRateSixty)

			case .thirty:
				String(localized: .frameRateThirty)
		}
	}

	/// Frames per second to request on `screen`, never above its maximum; 60 when the screen is unknown.
	func requestedRate(on screen: NSScreen?) -> Float {
		let maximum = Float(screen?.maximumFramesPerSecond ?? 60)
		switch self {
			case .display:
				return maximum

			case .sixty:
				return min(60, maximum)

			case .thirty:
				return min(30, maximum)
		}
	}
}

/// User-tunable settings shared by the screensaver and the preview app.
///
/// Defaults reproduce upstream's classic preset. The JSON encoding is persisted under
/// `storageKey`, so renaming properties or changing their types breaks saved settings.
struct TrinityConfiguration: Codable, Equatable {
	/// `ScreenSaverDefaults` module name, shared by both products so they read the same settings.
	static let moduleIdentifier = "fr.whine.Trinity"
	/// Upstream's classic defaults.
	static let defaults = TrinityConfiguration()
	/// Defaults key holding the JSON-encoded configuration. Changing it discards saved settings.
	static let storageKey = "configuration.v1"

	/// Simulation grid dimension in glyphs along the viewport's shorter axis; a whole number.
	var columns = 80.0
	/// Speed of the falling illumination, relative to upstream.
	var fallSpeed = 0.3
	/// Multiplier applied to elapsed time for the whole animation.
	var animationSpeed = 1.0
	/// Glyph symbol changes per 60 Hz reference frame.
	var cycleSpeed = 0.03
	/// Length of each falling trail, relative to upstream.
	var trailLength = 0.75
	/// Glyph brightness multiplier.
	var brightness = 1.0
	/// Brightness multiplier of the leading cursor glyph.
	var cursorIntensity = 2.0
	/// Size of the first bloom level as a fraction of the render resolution; 0 disables bloom.
	var bloomSize = 0.4
	/// Strength of the combined bloom; 0 disables bloom.
	var bloomStrength = 0.7
	/// Palette hue, from 0 to 1 around the color wheel.
	var hue = 0.3
	/// Amount of noise subtracted before palette mapping to hide banding.
	var dither = 0.05
	/// Render resolution as a fraction of the drawable's pixel size.
	var resolution = 1.0
	/// Presentation-rate policy.
	var frameRate = TrinityFrameRate.display

	/// Loads the saved configuration, falling back to the defaults when none is saved
	/// or the stored data is unreadable. Failures are logged; a screensaver has no UI to report them.
	static func load() -> TrinityConfiguration {
		guard let store = ScreenSaverDefaults(forModuleWithName: moduleIdentifier) else {
			TrinityLog.settings.error("Cannot open settings for \(moduleIdentifier, privacy: .public); using defaults.")
			return .defaults
		}
		guard let data = store.data(forKey: storageKey) else { return .defaults }

		do {
			return try JSONDecoder().decode(Self.self, from: data).validated()
		} catch {
			TrinityLog.settings.error("Cannot read saved settings; using defaults. \(String(describing: error), privacy: .public)")
			return .defaults
		}
	}

	/// Saves the validated configuration for the preview app and new screensaver instances.
	/// Failures are logged and leave the previously saved settings in place.
	func save() {
		guard let store = ScreenSaverDefaults(forModuleWithName: Self.moduleIdentifier) else {
			TrinityLog.settings.error("Cannot open settings for \(Self.moduleIdentifier, privacy: .public); changes not saved.")
			return
		}

		do {
			store.set(try JSONEncoder().encode(validated()), forKey: Self.storageKey)
		} catch {
			TrinityLog.settings.error("Cannot encode settings; changes not saved. \(String(describing: error), privacy: .public)")
			return
		}

		if !store.synchronize() {
			TrinityLog.settings.error("Settings could not be written to disk.")
		}
	}

	/// Returns a copy with every parameter clamped to its range, non-finite values reset
	/// to their defaults, and `columns` rounded to a whole number.
	func validated() -> Self {
		var copy = self
		for parameter in TrinityParameter.all {
			let value = copy[keyPath: parameter.keyPath]
			copy[keyPath: parameter.keyPath] = value.isFinite
				? min(parameter.range.upperBound, max(parameter.range.lowerBound, value))
				: Self.defaults[keyPath: parameter.keyPath]
		}
		copy.columns.round()
		return copy
	}
}

/// Describes one numeric setting: its label, storage, valid range and displayed precision.
/// `all` drives both validation and the options window's slider rows, in display order.
struct TrinityParameter {
	/// Localized slider label, also used as the slider's accessibility label.
	let title: LocalizedStringResource
	/// The configuration property this parameter edits.
	let keyPath: WritableKeyPath<TrinityConfiguration, Double>
	/// Inclusive range enforced by `TrinityConfiguration.validated()` and the slider.
	let range: ClosedRange<Double>
	/// Fraction digits shown in the value label; 0 also rounds slider values to whole numbers.
	let decimals: Int

	/// Every tunable parameter, in the order the options window lists them.
	static let all: [Self] = [
		.init(title: .parameterDensity, keyPath: \.columns, range: 20...240, decimals: 0),
		.init(title: .parameterFallSpeed, keyPath: \.fallSpeed, range: 0...1.5, decimals: 2),
		.init(title: .parameterAnimationSpeed, keyPath: \.animationSpeed, range: 0...3, decimals: 2),
		.init(title: .parameterGlyphCycleSpeed, keyPath: \.cycleSpeed, range: 0...0.15, decimals: 3),
		.init(title: .parameterTrailLength, keyPath: \.trailLength, range: 0.1...2, decimals: 2),
		.init(title: .parameterBrightness, keyPath: \.brightness, range: 0...2, decimals: 2),
		.init(title: .parameterCursorIntensity, keyPath: \.cursorIntensity, range: 0...5, decimals: 2),
		.init(title: .parameterBloomSize, keyPath: \.bloomSize, range: 0...1, decimals: 2),
		.init(title: .parameterBloomStrength, keyPath: \.bloomStrength, range: 0...1, decimals: 2),
		.init(title: .parameterHue, keyPath: \.hue, range: 0...1, decimals: 2),
		.init(title: .parameterDither, keyPath: \.dither, range: 0...1, decimals: 2),
		.init(title: .parameterResolutionScale, keyPath: \.resolution, range: 0.25...1, decimals: 2)
	]
}
