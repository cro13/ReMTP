import AppKit
import SwiftUI

/// Menu bar commands. List shortcuts that clash with text editing (⌘↑, ⌘↓, ⌘⌫, ⌘⇧←/→) only act
/// while a file list has focus; otherwise the key goes back to the focused text field.
struct AppCommands: Commands {
    let app: AppModel

    var body: some Commands {
        ToolbarCommands()
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { app.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Open") { listOnly(#selector(NSResponder.moveToEndOfDocument(_:))) { app.openSelection() } }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Quick Look") { app.quickLook() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(app.activeKind != .mac)
            Button("Rename") { app.beginRename() }
            Button(app.activeKind == .mac ? "Move to Trash" : "Delete…") {
                listOnly(#selector(NSResponder.deleteToBeginningOfLine(_:))) { app.deleteSelection() }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Divider()
            Button("Copy Path") { app.copyPaths() }
            Button("Show in Finder") { app.showInFinder() }
                .disabled(app.activeKind != .mac)
        }
        CommandGroup(after: .textEditing) {
            Button("Filter by Name") { app.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandGroup(before: .sidebar) {
            // The active pane's view (the toolbar's segmented control).
            ForEach(PaneViewMode.allCases) { mode in
                Toggle("as \(mode.title)", isOn: Binding(get: { app.activePane.viewMode == mode }, set: { _ in app.setViewMode(mode) }))
                    .keyboardShortcut(KeyEquivalent(mode.shortcut), modifiers: .command)
            }
            Divider()
            Toggle("Show Inspector", isOn: Binding(get: { app.inspectorVisible }, set: { app.inspectorVisible = $0 }))
                .keyboardShortcut("i", modifiers: .command)
            Button(app.transfers.drawerExpanded ? "Hide Transfers" : "Show Transfers") {
                app.showTransfers(!app.transfers.drawerExpanded)
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            Toggle("Show Hidden Files", isOn: Binding(get: { app.activePane.showHidden }, set: { app.activePane.showHidden = $0 }))
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Swap Panes") { app.swapPanes() }
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { app.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { app.goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Enclosing Folder") { listOnly(#selector(NSResponder.moveToBeginningOfDocument(_:))) { app.goUp() } }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Divider()
            Button("Home") { app.goHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Switch to Other Pane") { app.switchPane() }
            Divider()
            Button("Refresh") { app.refresh() }
                .keyboardShortcut("r", modifiers: .command)
        }
        CommandMenu("Transfer") {
            Button("Copy to Other Pane") {
                listOnly(#selector(NSResponder.complete(_:))) { app.copyToOtherPane() }
            }
            .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: [])
            Button("Copy Left Pane to Right") {
                listOnly(#selector(NSResponder.moveToEndOfLineAndModifySelection(_:))) { app.copyLeftToRight() }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            Button("Copy Right Pane to Left") {
                listOnly(#selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:))) { app.copyRightToLeft() }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            // Placeholder data: only with the demo backend until the sync engine exists.
            if app.showsSync {
                Divider()
                Button("Sync…") { app.openSync() }
            }
            Divider()
            Button(app.transfers.allPaused ? "Resume All" : "Pause All") {
                if app.transfers.allPaused { app.transfers.resumeAll() } else { app.transfers.pauseAll() }
            }
            .disabled(app.transfers.activeJobs.isEmpty)
            Button("Cancel All") { app.transfers.cancelAll() }
                .disabled(app.transfers.activeJobs.isEmpty)
        }
        CommandMenu("Debug") {
            // Demo backend controls: hidden with the real backend.
            if app.isDemo {
                Button("Simulate “Galaxy S23 Held by ptpcamerad”") {
                    app.demoService?.simulateSystemHold(deviceID: DemoDeviceService.galaxyID)
                }
                Button("Simulate “SP3000 Held by ptpcamerad”") {
                    app.demoService?.simulateSystemHold(deviceID: DemoDeviceService.sp3000ID)
                }
                Divider()
                Button("Unplug SP3000") { app.demoService?.setPlugged(deviceID: DemoDeviceService.sp3000ID, false) }
                Button("Plug In SP3000") { app.demoService?.setPlugged(deviceID: DemoDeviceService.sp3000ID, true) }
                Button("Unplug Galaxy S23") { app.demoService?.setPlugged(deviceID: DemoDeviceService.galaxyID, false) }
                Button("Plug In Galaxy S23") { app.demoService?.setPlugged(deviceID: DemoDeviceService.galaxyID, true) }
                Divider()
            }
            Button("Forget Remembered Devices") {
                for device in app.disconnectedDevices { app.forget(device.id) }
            }
            .disabled(app.disconnectedDevices.isEmpty)
        }
        // There is no help book: drop SwiftUI's "ReMTP Help" item (it only says help isn't available).
        CommandGroup(replacing: .help) {}
    }

    /// Runs `action` if a file list has focus; otherwise hands the keystroke's editing command to
    /// the focused text view (search field, rename editor).
    @MainActor
    private func listOnly(_ fallback: Selector, _ action: () -> Void) {
        if app.tableFocused {
            action()
        } else if let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
            textView.doCommand(by: fallback)
        }
    }
}
