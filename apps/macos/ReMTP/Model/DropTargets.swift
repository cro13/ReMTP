import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a drag is over in a pane.
enum DropSpot: Equatable {
    /// The "Drop here to copy into …" bar under the list.
    case bar
    /// A path bar segment (the last one is the open folder).
    case crumb(PaneLocation)
    /// A table row: its item (nil for empty space and placeholder rows) and whether the drop is `.on` the
    /// row (true) or between rows (`.above`, false).
    case row(FileItem?, on: Bool)
}

/// The folder a drop goes into.
enum DropTarget: Equatable {
    /// The folder the pane shows (the list highlights as a whole).
    case openFolder(PaneLocation)
    /// A folder row in the list (that row highlights).
    case folder(FileItem, PaneLocation)
    /// An earlier path bar segment.
    case ancestor(PaneLocation)

    var location: PaneLocation {
        switch self {
        case .openFolder(let location), .folder(_, let location), .ancestor(let location): return location
        }
    }
}

extension PaneModel {
    /// Resolves what's under the pointer to the folder that receives the drop. Only `.on` a folder row
    /// drops into that folder; between rows, on a file, on empty space and on the drop bar all mean the
    /// open folder. Whether the drop is allowed there is `AppModel.dropOperation`.
    func dropTarget(_ spot: DropSpot) -> DropTarget? {
        guard let open = location else { return nil }
        switch spot {
        case .bar:
            return .openFolder(open)
        case .crumb(let crumb):
            return crumb == open ? .openFolder(open) : .ancestor(crumb)
        case .row(let item?, on: true) where item.isBrowsable:
            return location(of: item).map { .folder(item, $0) } ?? .openFolder(open)
        case .row:
            return .openFolder(open)
        }
    }
}

/// What a drag carries, read from its pasteboard.
struct DragPayload {
    /// The pane the drag started in; nil when it comes from another app (Finder).
    var source: PaneKind?
    /// Device rows (drags from the device pane).
    var deviceItems: [DeviceDragItem]
    /// Local files and folders (Finder, the Mac pane).
    var urls: [URL]
    /// The source allows moving (false while Option is held).
    var allowsMove: Bool

    /// What the drop targets (list, drop bar, path bar) accept.
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, DeviceDragItem.pasteboardType]
    static let contentTypes: [UTType] = [.fileURL, DeviceDragItem.contentType]

    /// The pasteboard SwiftUI drop targets read (the drag pasteboard; the self-check swaps in its own).
    @MainActor static var dragPasteboard = NSPasteboard(name: .drag)

    @MainActor private static var cache: (name: NSPasteboard.Name, changeCount: Int, payload: DragPayload)?

    /// Reads `pasteboard` once per drag (validation runs on every pointer move).
    @MainActor
    static func read(_ pasteboard: NSPasteboard, source: PaneKind?, allowsMove: Bool) -> DragPayload {
        var payload: DragPayload
        if let cache, cache.name == pasteboard.name, cache.changeCount == pasteboard.changeCount {
            payload = cache.payload
        } else {
            let items = DeviceDragItem.read(from: pasteboard)
            let urls = items.isEmpty
                ? pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                : []
            payload = DragPayload(source: nil, deviceItems: items, urls: urls, allowsMove: false)
            cache = (pasteboard.name, pasteboard.changeCount, payload)
        }
        payload.source = source
        payload.allowsMove = allowsMove
        return payload
    }

    /// The drag in progress, for SwiftUI drop targets (they don't see AppKit's dragging info).
    @MainActor
    static func current() -> DragPayload {
        read(dragPasteboard, source: DragTracker.source, allowsMove: !NSEvent.modifierFlags.contains(.option))
    }
}

/// The pane a drag in progress started in. The tables set it as drag sources.
@MainActor
enum DragTracker {
    static var source: PaneKind?
}

extension NSDragOperation {
    /// What a SwiftUI drop target proposes for this operation.
    var dropOperation: DropOperation {
        if contains(.move) { return .move }
        if contains(.copy) { return .copy }
        return .forbidden
    }
}

/// The drop bar and path bar segments as drop targets (SwiftUI). The list is an NSTableView and
/// resolves its drops in `FileTableCoordinator`; both end up in `AppModel.performDrop`.
@MainActor
struct PaneDropDelegate: DropDelegate {
    let app: AppModel
    let pane: PaneModel
    let spot: DropSpot
    let zone: PaneModel.DropZone

    private func operation() -> NSDragOperation {
        guard let target = pane.dropTarget(spot) else { return [] }
        return app.dropOperation(.current(), into: target.location, in: pane)
    }

    // Always validated, so the pane notices the drag (keeps the drop bar up); `dropUpdated` refuses.
    func validateDrop(info: DropInfo) -> Bool { true }

    func dropEntered(info: DropInfo) {
        pane.dragEntered(zone, accepted: !operation().isEmpty, drag: .current())
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let operation = operation()
        pane.dragUpdated(zone, accepted: !operation.isEmpty)
        return DropProposal(operation: operation.dropOperation)
    }

    func dropExited(info: DropInfo) {
        pane.dragExited(zone)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { app.dragEnded() }
        guard let target = pane.dropTarget(spot) else { return false }
        return app.performDrop(.current(), into: target.location, in: pane)
    }
}
