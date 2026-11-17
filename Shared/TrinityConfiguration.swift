import AppKit
import ScreenSaver

enum TrinityFrameRate: Int, CaseIterable, Codable {
	case display
	case sixty
	case thirty

	var title: String {
		switch self {
			case .display:
				"Match Display"

			case .sixty:
				"60 fps"

			case .thirty:
				"30 fps"
		}
	}

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

struct TrinityConfiguration: Codable, Equatable {
	static let moduleIdentifier = "fr.whine.Trinity"
	static let defaults = TrinityConfiguration()
	var columns = 80.0
	var fallSpeed = 0.3
	var animationSpeed = 1.0
	var cycleSpeed = 0.03
	var trailLength = 0.75
	var brightness = 1.0
	var cursorIntensity = 2.0
	var bloomSize = 0.4
	var bloomStrength = 0.7
	var hue = 0.3
	var dither = 0.05
	var resolution = 1.0
	var frameRate = TrinityFrameRate.display

	/// Defaults key holding the JSON-encoded configuration. Changing it discards saved settings.
	static let storageKey = "configuration.v1"

	/// Loads the saved configuration, falling back to the defaults when none is saved
	/// or the stored data is unreadable. Failures are logged; a screensaver has no UI to report them.
	static func load() -> TrinityConfiguration {
		guard let store = ScreenSaverDefaults(forModuleWithName: moduleIdentifier) else {
			NSLog("Trinity: cannot open settings for %@; using defaults.", moduleIdentifier)
			return .defaults
		}
		guard let data = store.data(forKey: storageKey) else { return .defaults }

		do {
			return try JSONDecoder().decode(Self.self, from: data).validated()
		} catch {
			NSLog("Trinity: cannot read saved settings; using defaults. %@", String(describing: error))
			return .defaults
		}
	}

	/// Saves the validated configuration for the preview app and new screensaver instances.
	/// Failures are logged and leave the previously saved settings in place.
	func save() {
		guard let store = ScreenSaverDefaults(forModuleWithName: Self.moduleIdentifier) else {
			NSLog("Trinity: cannot open settings for %@; changes not saved.", Self.moduleIdentifier)
			return
		}

		do {
			store.set(try JSONEncoder().encode(validated()), forKey: Self.storageKey)
		} catch {
			NSLog("Trinity: cannot encode settings; changes not saved. %@", String(describing: error))
			return
		}

		if !store.synchronize() {
			NSLog("Trinity: settings could not be written to disk.")
		}
	}

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

struct TrinityParameter {
	let title: String
	let keyPath: WritableKeyPath<TrinityConfiguration, Double>
	let range: ClosedRange<Double>
	let decimals: Int

	static let all: [Self] = [
		.init(title: "Density", keyPath: \.columns, range: 20...240, decimals: 0),
		.init(title: "Fall speed", keyPath: \.fallSpeed, range: 0...1.5, decimals: 2),
		.init(title: "Animation speed", keyPath: \.animationSpeed, range: 0...3, decimals: 2),
		.init(title: "Glyph cycle speed", keyPath: \.cycleSpeed, range: 0...0.15, decimals: 3),
		.init(title: "Trail length", keyPath: \.trailLength, range: 0.1...2, decimals: 2),
		.init(title: "Brightness", keyPath: \.brightness, range: 0...2, decimals: 2),
		.init(title: "Cursor intensity", keyPath: \.cursorIntensity, range: 0...5, decimals: 2),
		.init(title: "Bloom size", keyPath: \.bloomSize, range: 0...1, decimals: 2),
		.init(title: "Bloom strength", keyPath: \.bloomStrength, range: 0...1, decimals: 2),
		.init(title: "Hue", keyPath: \.hue, range: 0...1, decimals: 2),
		.init(title: "Dither", keyPath: \.dither, range: 0...1, decimals: 2),
		.init(title: "Resolution scale", keyPath: \.resolution, range: 0.25...1, decimals: 2)
	]
}
