import AppKit

/// Standalone app for inspecting and debugging the renderer outside the screensaver host.
///
/// It owns one resizable window whose content is a `TrinityMetalView`, a menu bar with options,
/// diagnostics and full-screen commands, and the options sheet while it is open.
@main
@MainActor
final class TrinityPreviewApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
	/// The single preview window, owned for the app's lifetime; it is not released when closed.
	private let window: NSWindow
	/// The window's content view and the renderer under inspection.
	private let metalView: TrinityMetalView
	/// The open options sheet's controller; nil while no sheet is shown.
	private var options: TrinityOptionsController?
	/// Refreshes the diagnostics overlay once a second until the window closes.
	private var diagnosticsTimer: Timer?
	/// Performance overlay in the window's top-left corner; hidden by default.
	private let diagnosticLabel = NSTextField(labelWithString: "")
	/// View menu item toggling the overlay; its title reflects the overlay's state.
	private let diagnosticsItem = NSMenuItem(
		title: String(localized: .menuShowDiagnostics),
		action: #selector(TrinityPreviewApp.toggleDiagnostics),
		keyEquivalent: "d"
	)
	/// Whether the overlay is shown.
	private var diagnosticsVisible = false

	/// Entry point: runs the shared application with this object as its delegate.
	static func main() {
		let application = NSApplication.shared
		let delegate = TrinityPreviewApp()
		application.delegate = delegate
		application.setActivationPolicy(.regular)
		application.run()
		withExtendedLifetime(delegate) {}
	}

	/// Creates the window and its Metal view; they are configured and shown at launch.
	override init() {
		window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
			styleMask: [.titled, .closable, .resizable],
			backing: .buffered,
			defer: false
		)
		metalView = TrinityMetalView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
		super.init()
	}

	/// Builds the menus, shows the window and starts rendering. `--diagnostics` shows the
	/// overlay immediately and also logs it every second.
	func applicationDidFinishLaunching(_ notification: Notification) {
		NSWindow.allowsAutomaticWindowTabbing = false
		buildMenu()
		window.title = String(localized: .previewWindowTitle)
		window.minSize = NSSize(width: 1024, height: 576)
		window.collectionBehavior = [.fullScreenPrimary]
		window.delegate = self
		window.isReleasedWhenClosed = false
		metalView.autoresizingMask = [.width, .height]
		window.contentView = metalView
		diagnosticLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
		diagnosticLabel.textColor = .white
		diagnosticLabel.backgroundColor = NSColor.black.withAlphaComponent(0.8)
		diagnosticLabel.drawsBackground = true
		diagnosticLabel.translatesAutoresizingMaskIntoConstraints = false
		diagnosticLabel.isHidden = true
		metalView.addSubview(diagnosticLabel)
		NSLayoutConstraint.activate([
			diagnosticLabel.leadingAnchor.constraint(equalTo: metalView.leadingAnchor, constant: 16),
			diagnosticLabel.topAnchor.constraint(equalTo: metalView.topAnchor, constant: 16)
		])
		metalView.onError = { [weak self] message in self?.showError(message) }
		window.center()
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.activate(ignoringOtherApps: true)
		metalView.start()
		if let message = metalView.failureMessage { showError(message) }
		diagnosticsTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(refreshDiagnostics), userInfo: nil, repeats: true)
		if CommandLine.arguments.contains("--diagnostics") { toggleDiagnostics() }
	}

	/// Installs the application and View menus. Every item except Quit targets this delegate.
	private func buildMenu() {
		let main = NSMenu()
		let appItem = NSMenuItem()
		let app = NSMenu()
		app.addItem(withTitle: String(localized: .menuAbout), action: #selector(about), keyEquivalent: "")
		app.addItem(.separator())
		app.addItem(withTitle: String(localized: .menuOptions), action: #selector(openOptions), keyEquivalent: ",")
		app.addItem(.separator())
		app.addItem(withTitle: String(localized: .menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		appItem.submenu = app
		main.addItem(appItem)
		let viewTitle = String(localized: .menuView)
		let viewItem = NSMenuItem(title: viewTitle, action: nil, keyEquivalent: "")
		let view = NSMenu(title: viewTitle)
		view.addItem(diagnosticsItem)
		let fullscreen = view.addItem(withTitle: String(localized: .menuEnterFullScreen), action: #selector(toggleFullScreen), keyEquivalent: "f")
		fullscreen.keyEquivalentModifierMask = [.command, .control]
		viewItem.submenu = view
		main.addItem(viewItem)
		NSApplication.shared.mainMenu = main
		for menu in [app, view] { for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self } }
	}

	/// Shows the standard About panel. AppKit reads the version and build from the bundle's
	/// `CFBundleShortVersionString` and `CFBundleVersion`, set from `MARKETING_VERSION` and
	/// `CURRENT_PROJECT_VERSION`.
	@objc private func about() {
		NSApplication.shared.orderFrontStandardAboutPanel(options: [
			.applicationName: String(localized: .aboutApplicationName),
			.credits: NSAttributedString(string: String(localized: .aboutCredits))
		])
	}

	/// Enters or exits full screen.
	@objc private func toggleFullScreen() { window.toggleFullScreen(nil) }

	/// Keeps the full-screen item's title in step with the window's state; every item stays enabled.
	func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		if menuItem.action == #selector(toggleFullScreen) {
			menuItem.title = String(localized: window.styleMask.contains(.fullScreen) ? .menuExitFullScreen : .menuEnterFullScreen)
		}
		return true
	}

	/// Opens the options sheet on the current configuration. Apply saves the result and applies it here.
	@objc private func openOptions() {
		guard options == nil else { return }

		let controller = TrinityOptionsController(configuration: metalView.configuration) { [weak self] result in
			if let result {
				result.save()
				self?.metalView.configuration = result
			}
			self?.options = nil
		}
		options = controller
		if let sheet = controller.window { window.beginSheet(sheet) }
	}

	/// Shows or hides the performance overlay and updates the menu item's title.
	@objc private func toggleDiagnostics() {
		diagnosticsVisible.toggle()
		diagnosticLabel.isHidden = !diagnosticsVisible
		diagnosticsItem.title = String(localized: diagnosticsVisible ? .menuHideDiagnostics : .menuShowDiagnostics)
		refreshDiagnostics()
	}

	/// Updates the overlay with the requested and measured frame rates, render size, GPU time and
	/// skipped frames, and logs it when launched with `--diagnostics`. Does nothing while hidden.
	@objc private func refreshDiagnostics() {
		guard diagnosticsVisible, let stats = metalView.renderer?.diagnostics else { return }

		let requested = metalView.configuration.frameRate.requestedRate(on: window.screen)
		let integer = IntegerFormatStyle<Int>.number.grouping(.never)
		let summary = String(localized: .diagnosticsSummary(
			requested.formatted(.number.precision(.fractionLength(0))),
			stats.framesPerSecond.formatted(.number.precision(.fractionLength(1))),
			stats.width.formatted(integer),
			stats.height.formatted(integer),
			stats.gpuMilliseconds.formatted(.number.precision(.fractionLength(2))),
			stats.skippedFrames.formatted(integer)
		))
		// The spaces pad the label's background around the text.
		diagnosticLabel.stringValue = " \(summary) "
		if CommandLine.arguments.contains("--diagnostics") {
			TrinityLog.diagnostics.notice("\(summary, privacy: .public)")
		}
	}

	/// Presents a rendering failure as a sheet on the preview window.
	private func showError(_ message: String) {
		let alert = NSAlert()
		alert.messageText = String(localized: .renderingFailedTitle)
		alert.informativeText = message
		alert.beginSheetModal(for: window)
	}

	/// Stops rendering and the diagnostics timer when the window closes.
	func windowWillClose(_ notification: Notification) {
		metalView.stop()
		diagnosticsTimer?.invalidate()
	}

	/// Quits once the preview window closes.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	/// Stops rendering and the diagnostics timer before quitting.
	func applicationWillTerminate(_ notification: Notification) {
		metalView.stop()
		diagnosticsTimer?.invalidate()
	}
}
