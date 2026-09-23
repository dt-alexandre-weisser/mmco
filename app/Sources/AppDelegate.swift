import Cocoa
import SwiftUI

/// Faceless URL-scheme handler. `mmco://checkout?repo=<owner/repo>&branch=<branch>` starts a CLI
/// run and quits; `mmco://settings` shows the mapping table and quits when the window closes;
/// `mmco://config` and `mmco://log` open the JSON config and the log through the CLI.
/// A plain launch (Finder, `open -a mmco`) with no URL behaves like `mmco://settings`.
/// The same binary is also the Chrome native-messaging host, see main.swift and NativeHost.swift.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var settingsWindow: NSWindow?
    private var receivedURL = false
    private var pendingRuns = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.receivedURL else { return }
            self.showSettings()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedURL = true
        for url in urls { handle(url) }
    }

    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "mmco" else { return }
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let param = { (name: String) in query.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

        switch action {
        case "checkout":
            let repo = param("repo")
            guard !repo.isEmpty else { return fail("mmco://checkout needs a repo=<owner/repo> parameter") }
            run(repo: repo, branch: param("branch"))
        case "settings", "":
            showSettings()
        case "config":
            runCLI(["--config"])
        case "log":
            runCLI(["--log"])
        default:
            fail("unknown mmco action: \(action)")
        }
    }

    /// The run is detached (own session, /dev/null streams) and reports through its run folder,
    /// so the app has nothing to wait for. Progress is visible in the Chrome extension and mmco --log.
    private func run(repo: String, branch: String) {
        do {
            _ = try RunLauncher.launch(repo: repo, branch: branch)
        } catch {
            return fail(error.localizedDescription)
        }
        if settingsWindow == nil { NSApp.terminate(nil) }
    }

    private func runCLI(_ arguments: [String]) {
        pendingRuns += 1
        CLIRunner.run(arguments: arguments) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result { self.fail(error.localizedDescription) }
                self.pendingRuns -= 1
                if self.pendingRuns == 0 && self.settingsWindow == nil { NSApp.terminate(nil) }
            }
        }
    }

    private func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let store = ConfigStore()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "mmco settings"
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(store: store))
        window.delegate = self
        window.isReleasedWhenClosed = false
        settingsWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        settingsWindow = nil
        if pendingRuns == 0 { NSApp.terminate(nil) }
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "mmco"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        if pendingRuns == 0 && settingsWindow == nil { NSApp.terminate(nil) }
    }
}
