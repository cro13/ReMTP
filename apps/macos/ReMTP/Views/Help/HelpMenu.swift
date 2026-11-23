import AppKit
import SwiftUI

/// The Help menu's items.
struct HelpMenuItems: View {
    let app: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("ReMTP Help") { NSWorkspace.shared.open(HelpLinks.readme) }
            .keyboardShortcut("?", modifiers: .command)
        Button("Device Troubleshooting") { openWindow(id: "troubleshooting") }
        Divider()
        Button("Report a Device Problem…") { HelpLinks.openReport(.device, app: app) }
        Button("Report a Bug…") { HelpLinks.openReport(.bug, app: app) }
    }
}
