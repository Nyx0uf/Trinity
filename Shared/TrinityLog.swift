import OSLog

/// Unified-log destinations shared by the screensaver and the preview app.
///
/// Both targets log under the subsystem `fr.whine.Trinity`, regardless of the hosting process,
/// so `log stream --predicate 'subsystem == "fr.whine.Trinity"'` captures either product.
/// The loggers are nonisolated so Metal completion handlers can use them off the main actor.
enum TrinityLog {
	/// Subsystem for every Trinity logger; matches the `ScreenSaverDefaults` module name.
	nonisolated static let subsystem = "fr.whine.Trinity"

	/// Loading and saving of `TrinityConfiguration`.
	nonisolated static let settings = Logger(subsystem: subsystem, category: "settings")

	/// Metal setup, frame encoding and GPU command buffer failures.
	nonisolated static let rendering = Logger(subsystem: subsystem, category: "rendering")

	/// Preview-app performance reports enabled with `--diagnostics`.
	nonisolated static let diagnostics = Logger(subsystem: subsystem, category: "diagnostics")
}
