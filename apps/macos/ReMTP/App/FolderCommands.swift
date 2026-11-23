import SwiftUI

/// Menu commands for pinned device folders: File › Add to Sidebar (⌃⌘T, as in Finder) and Remove from Sidebar.
/// They act on the device pane's selected folders, or its open folder when nothing is selected.
struct FolderCommands: Commands {
    let app: AppModel

    var body: some Commands {
        CommandGroup(before: .saveItem) {
            Button("Add to Sidebar") { app.addToSidebar() }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(!app.canAddToSidebar)
            Button("Remove from Sidebar") { app.removeFromSidebar() }
                .disabled(!app.canRemoveFromSidebar)
            Divider()
        }
    }
}
