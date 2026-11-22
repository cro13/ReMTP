import AppKit
import SwiftUI

/// Picks the backend; views only see `DeviceService`. The Rust core is the default. `--demo` (or the
/// `UseDemoDevices` user default) runs the simulated devices, which the debug snapshot run also uses.
enum DeviceServiceFactory {
    static func make() -> any DeviceService {
        let info = ProcessInfo.processInfo
        if info.arguments.contains("--demo") || UserDefaults.standard.bool(forKey: "UseDemoDevices")
            || info.environment["REMTP_SNAPSHOT_DIR"] != nil {
            return DemoDeviceService()
        }
        return RustDeviceService()
    }
}

@main
struct ReMTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("ReMTP", id: "main") {
            MainWindow(app: delegate.app)
        }
        .defaultSize(width: 1440, height: 880)
        .commands { AppCommands(app: delegate.app) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var app: AppModel = {
        #if DEBUG
        // The self-check starts from empty demo defaults (known devices, names) so every run is the same.
        if ProcessInfo.processInfo.environment["REMTP_SNAPSHOT_DIR"] != nil {
            AppDefaults.store(demo: true).removePersistentDomain(forName: AppDefaults.demoSuiteName)
        }
        #endif
        return AppModel(service: DeviceServiceFactory.make())
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        app.start()
        if app.isDemo { stopAutosaveForDemo() }
        #if DEBUG
        DebugSnapshots.runIfRequested(app: app)
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if app.isShutDown { return .terminateNow }
        let active = app.transfers.activeJobs.count
        if active > 0 {
            let alert = NSAlert()
            alert.messageText = "Quit while \(Format.count(active, "transfer")) \(active == 1 ? "is" : "are") running?"
            alert.informativeText = "Files that haven’t been copied yet will be skipped."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        // Closing sessions waits for the device, so cleanup runs off the main thread and the app
        // terminates when it is done (time-boxed in `shutdown`). The UI stays responsive meanwhile.
        app.shutdown { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // `shutdown` normally did this already. If it didn't run, still give ptpcamerad back
        // (quick, and a no-op unless ReMTP paused it).
        if !app.isShutDown { try? app.service.restoreSystemHold() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Demo runs (and the self-check) share the real app's defaults domain, where AppKit autosaves the
    /// window frame and the sidebar width: they don't save those (their own settings go to
    /// `AppDefaults.demoSuiteName`; the file tables skip column autosave).
    private func stopAutosaveForDemo() {
        func strip() {
            for window in NSApp.windows {
                if !window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("") }
                func visit(_ view: NSView) {
                    if let split = view as? NSSplitView, split.autosaveName != nil { split.autosaveName = nil }
                    view.subviews.forEach(visit)
                }
                window.contentView.map(visit)
            }
        }
        strip()
        DispatchQueue.main.async { strip() }
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { strip() }
            }
        }
    }
}
