import AppKit

@main
@MainActor
final class TrinityPreviewApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
	private var window: NSWindow!
	private var metalView: TrinityMetalView!
	private var options: TrinityOptionsController?
	private var diagnosticsTimer: Timer?
	private let diagnosticLabel = NSTextField(labelWithString: "")
	private var diagnosticsVisible = false

	static func main() {
		let application = NSApplication.shared
		let delegate = TrinityPreviewApp()
		application.delegate = delegate
		application.setActivationPolicy(.regular)
		application.run()
		withExtendedLifetime(delegate) {}
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		NSWindow.allowsAutomaticWindowTabbing = false
		buildMenu()
		window = NSWindow(
			contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
			styleMask: [.titled, .closable, .miniaturizable, .resizable],
			backing: .buffered,
			defer: false
		)
		window.title = "Trinity Preview"
		window.minSize = NSSize(width: 420, height: 300)
		window.collectionBehavior = [.fullScreenPrimary]
		window.delegate = self
		window.isReleasedWhenClosed = false
		metalView = TrinityMetalView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
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

	private func buildMenu() {
		let main = NSMenu()
		let appItem = NSMenuItem()
		let app = NSMenu()
		app.addItem(withTitle: "About Trinity", action: #selector(about), keyEquivalent: "")
		app.addItem(.separator())
		app.addItem(withTitle: "Trinity Options…", action: #selector(openOptions), keyEquivalent: ",")
		app.addItem(.separator())
		app.addItem(withTitle: "Quit Trinity Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		appItem.submenu = app
		main.addItem(appItem)
		let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
		let view = NSMenu(title: "View")
		view.addItem(withTitle: "Show Diagnostics", action: #selector(toggleDiagnostics), keyEquivalent: "d")
		let fullscreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(toggleFullScreen), keyEquivalent: "f")
		fullscreen.keyEquivalentModifierMask = [.command, .control]
		viewItem.submenu = view
		main.addItem(viewItem)
		NSApplication.shared.mainMenu = main
		for menu in [app, view] { for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self } }
	}

	@objc private func about() {
		NSApplication.shared.orderFrontStandardAboutPanel(options: [
			.applicationName: "Trinity",
			.applicationVersion: "1.0",
			.credits: NSAttributedString(string: "A native Metal port of Rezmason’s classic Matrix rain.\nOriginal effect © 2018 Rezmason · MIT License")
		])
	}

	@objc private func toggleFullScreen() { window.toggleFullScreen(nil) }
	func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
		if menuItem.action == #selector(toggleFullScreen) {
			menuItem.title = window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
		}
		return true
	}

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

	@objc private func toggleDiagnostics() {
		diagnosticsVisible.toggle()
		diagnosticLabel.isHidden = !diagnosticsVisible
		let item = NSApplication.shared.mainMenu?.item(withTitle: "View")?.submenu?.items.first
		item?.title = diagnosticsVisible ? "Hide Diagnostics" : "Show Diagnostics"
		refreshDiagnostics()
	}

	@objc private func refreshDiagnostics() {
		guard diagnosticsVisible, let stats = metalView.renderer?.diagnostics else { return }

		let requested = metalView.configuration.frameRate.requestedRate(on: window.screen)
		let integer = IntegerFormatStyle<Int>.number.grouping(.never)
		let target = requested.formatted(.number.precision(.fractionLength(0)))
		let actual = stats.framesPerSecond.formatted(.number.precision(.fractionLength(1)))
		let size = "\(stats.width.formatted(integer)) × \(stats.height.formatted(integer))"
		let gpu = stats.gpuMilliseconds.formatted(.number.precision(.fractionLength(2)))
		let skipped = stats.skippedFrames.formatted(integer)
		diagnosticLabel.stringValue = " Target \(target) fps · Actual \(actual) fps · \(size) · GPU \(gpu) ms · Skipped \(skipped) "
		if CommandLine.arguments.contains("--diagnostics") {
			TrinityLog.diagnostics.notice("\(self.diagnosticLabel.stringValue, privacy: .public)")
		}
	}

	private func showError(_ message: String) {
		let alert = NSAlert()
		alert.messageText = "Trinity could not start rendering"
		alert.informativeText = message
		alert.beginSheetModal(for: window)
	}

	func windowWillClose(_ notification: Notification) {
		metalView.stop()
		diagnosticsTimer?.invalidate()
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
	func applicationWillTerminate(_ notification: Notification) {
		metalView?.stop()
		diagnosticsTimer?.invalidate()
	}
}
