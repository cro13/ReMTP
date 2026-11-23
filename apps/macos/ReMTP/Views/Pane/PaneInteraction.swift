import AppKit
import UniformTypeIdentifiers

// What the list, the columns and the icon grid share: pane keys, the context menu, dragging files out,
// spring-loading, inline rename, status badges and file icons. Every command goes through `AppModel` and
// acts on `PaneModel.targetItems`, so all three views use the same selection model.

/// Pane-level keys (Tab, Return, Space, F5, ⌘↑/⌘↓, ⌘⌫, ⌘⇧←/→, ← / →).
enum PaneKey {
    case tab, returnKey, space, f5, open, parent, delete, copyRight, copyLeft, left, right

    /// The pane key for `event`, or nil when the view handles it (arrows with modifiers, type-select, …).
    /// `typing`: a type-select search is in progress, so Space belongs to it.
    static func from(_ event: NSEvent, typing: Bool) -> PaneKey? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 48 where !flags.contains(.command) && !flags.contains(.control): return .tab
        case 36 where flags.isEmpty, 76 where flags.isEmpty: return .returnKey
        case 49 where flags.isEmpty && !typing: return .space
        case 96: return .f5
        case 125 where flags == .command: return .open
        case 126 where flags == .command: return .parent
        case 51 where flags == .command, 117 where flags == .command: return .delete
        case 124 where flags == [.command, .shift]: return .copyRight
        case 123 where flags == [.command, .shift]: return .copyLeft
        case 123 where flags.isEmpty: return .left
        case 124 where flags.isEmpty: return .right
        default: return nil
        }
    }

    /// Whether `event` types part of a name (type-select): letters, digits or punctuation without ⌘ or ⌃.
    static func isTypeSelect(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]),
              let scalar = event.characters?.unicodeScalars.first else { return false }
        return CharacterSet.alphanumerics.union(.punctuationCharacters).contains(scalar)
    }
}

@MainActor
enum PaneKeyCommands {
    /// Runs the command for `key` in `pane`. False for ← / →, which each view handles itself.
    static func perform(_ key: PaneKey, in pane: PaneModel, app: AppModel) -> Bool {
        if key == .left || key == .right { return false }
        app.activate(pane.kind)
        switch key {
        case .tab: app.switchPane()
        case .returnKey: app.beginRename()
        case .space:
            if pane.kind == .mac { app.quickLook() } else { NSSound.beep() }
        case .f5: app.copySelection(from: pane)
        case .open: app.openSelection()
        case .parent: pane.goUp()
        case .delete: app.deleteSelection()
        case .copyRight: app.copyLeftToRight()
        case .copyLeft: app.copyRightToLeft()
        case .left, .right: return false
        }
        return true
    }
}

/// Finder-style type-select for views without NSTableView's: keys typed within a second of each other
/// pick the first name starting with them (else the first that sorts after them).
struct TypeSelectBuffer {
    private var text = ""
    private var last: TimeInterval = 0

    var isTyping: Bool { Date().timeIntervalSinceReferenceDate - last <= 1.0 }

    mutating func add(_ characters: String) -> String {
        let now = Date().timeIntervalSinceReferenceDate
        if now - last > 1.0 { text = "" }
        text += characters
        last = now
        return text
    }

    static func match(_ query: String, in names: [String]) -> Int? {
        guard !query.isEmpty else { return nil }
        if let prefix = names.firstIndex(where: {
            $0.range(of: query, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil
        }) {
            return prefix
        }
        return names.indices
            .filter { names[$0].localizedStandardCompare(query) == .orderedDescending }
            .min { names[$0].localizedStandardCompare(names[$1]) == .orderedAscending }
    }
}

// MARK: - Drags

/// Views that start drags from a pane: drops tell the source pane by it.
@MainActor
protocol PaneDragSourceView: AnyObject {
    var paneKind: PaneKind? { get }
}

extension DragPayload {
    /// The payload of an AppKit drag over one of the pane views.
    @MainActor
    static func read(_ info: NSDraggingInfo) -> DragPayload {
        let source = (info.draggingSource as? PaneDragSourceView)?.paneKind
        return read(info.draggingPasteboard, source: source, allowsMove: info.draggingSourceOperationMask.contains(.move))
    }
}

/// Dragging files out of a pane: local files as URLs, device files as our own type plus a Finder promise.
@MainActor
final class PaneDragSupport: NSObject, NSFilePromiseProviderDelegate {
    let pane: PaneModel
    let app: AppModel

    init(pane: PaneModel, app: AppModel) {
        self.pane = pane
        self.app = app
    }

    func writer(for item: FileItem) -> (any NSPasteboardWriting)? {
        if let url = item.url { return url as NSURL }
        guard let path = item.devicePath, let loc = pane.location?.device else { return nil }
        let type = item.isDirectory ? UTType.folder : (item.type ?? .data)
        let provider = DevicePromiseProvider(fileType: type.identifier, delegate: self)
        provider.dragItem = DeviceDragItem(deviceID: loc.deviceID, storageID: loc.storageID, path: path, name: item.name,
                                           isDir: item.isDirectory, size: item.size ?? 0)
        return provider
    }

    func began() {
        DragTracker.source = pane.kind
    }

    func ended() {
        DragTracker.source = nil
        app.dragEnded()
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider as? DevicePromiseProvider)?.dragItem?.name ?? "Untitled"
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        guard let item = (filePromiseProvider as? DevicePromiseProvider)?.dragItem else {
            return completionHandler(DeviceServiceError.notFound(path: url.lastPathComponent))
        }
        let app = MainActor.assumeIsolated { self.app }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { app.fulfillPromise(item, to: url, completion: completionHandler) }
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        .main
    }
}

/// Spring-loading: resting a drag on a folder for `delay` opens it, like Finder.
@MainActor
final class SpringLoader {
    static let delay: TimeInterval = 1.0
    private(set) var folder: PaneLocation?
    private var timer: Timer?
    private let open: (PaneLocation) -> Void

    init(open: @escaping (PaneLocation) -> Void) {
        self.open = open
    }

    func spring(_ folder: PaneLocation) {
        guard self.folder != folder else { return }
        cancel()
        self.folder = folder
        let timer = Timer(timeInterval: Self.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let folder = self.folder else { return }
                self.folder = nil
                self.timer = nil
                self.open(folder)
            }
        }
        // Drags run the run loop in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        folder = nil
    }
}

/// The accent outline over a pane view while a drop into the folder it shows is targeted (the icon grid's
/// counterpart of NSTableView's whole-table drop highlight). Never takes clicks or drags.
final class DropHighlightView: NSView {
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 7, yRadius: 7)
        NSColor.controlAccentColor.withAlphaComponent(0.07).setFill()
        path.fill()
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

// MARK: - Context menu

/// The file context menu of every pane view. Like the menu bar, it acts on `pane.targetItems`.
@MainActor
final class PaneContextMenu: NSObject, NSMenuDelegate {
    let pane: PaneModel
    let app: AppModel
    let menu = NSMenu()

    init(pane: PaneModel, app: AppModel) {
        self.pane = pane
        self.app = app
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        app.activate(pane.kind)
        let selected = pane.targetItems
        let other = app.otherSideName(for: pane)
        func add(_ title: String, _ action: Selector, enabled: Bool = true, key: String = "",
                 modifiers: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            menu.addItem(item)
        }
        if !selected.isEmpty {
            add("Open", #selector(menuOpen), key: String(UnicodeScalar(NSDownArrowFunctionKey)!), modifiers: .command)
            let canCopy = pane.kind == .device ? app.macPane.location != nil : app.devicePaneBrowsable
            add("Copy to \(Format.middleTruncated(other, width: 220))", #selector(menuCopy), enabled: canCopy)
            if pane.kind == .mac {
                add("Quick Look", #selector(menuQuickLook), key: "y", modifiers: .command)
                add("Show in Finder", #selector(menuShowInFinder))
            }
            add("Get Info", #selector(menuInfo))
            menu.addItem(.separator())
            add("Rename", #selector(menuRename), enabled: selected.count == 1)
        }
        add("New Folder", #selector(menuNewFolder), key: "n", modifiers: [.command, .shift])
        if !selected.isEmpty {
            add(pane.kind == .mac ? "Move to Trash" : "Delete…", #selector(menuDelete),
                key: String(UnicodeScalar(NSBackspaceCharacter)!), modifiers: .command)
            menu.addItem(.separator())
            add(selected.count == 1 ? "Copy Path" : "Copy Paths", #selector(menuCopyPath))
            if pane.kind == .device, selected.contains(where: \.isBrowsable) {
                add("Add to Sidebar", #selector(menuAddToSidebar), enabled: app.canAddToSidebar,
                    key: "t", modifiers: [.command, .control])
            }
        } else {
            menu.addItem(.separator())
        }
        add("Refresh", #selector(menuRefresh), key: "r", modifiers: .command)
    }

    @objc private func menuOpen() { app.openSelection() }
    @objc private func menuCopy() { app.copySelection(from: pane) }
    @objc private func menuQuickLook() { app.quickLook() }
    @objc private func menuShowInFinder() { app.showInFinder() }
    @objc private func menuInfo() { app.inspectorVisible = true }
    @objc private func menuRename() { app.beginRename() }
    @objc private func menuNewFolder() { app.newFolder() }
    @objc private func menuDelete() { app.deleteSelection() }
    @objc private func menuCopyPath() { app.copyPaths() }
    @objc private func menuRefresh() { app.refresh() }
    @objc private func menuAddToSidebar() { app.addToSidebar() }
}

// MARK: - Inline rename

/// Inline rename in a text field of the view (a list or column row's name, an icon's label). Return or
/// clicking away commits, Escape cancels.
@MainActor
final class InlineRenamer: NSObject, NSTextFieldDelegate {
    private(set) var field: NSTextField?
    private(set) var item: FileItem?
    private var onRenamed: RenameCompletion?
    var isActive: Bool { field != nil }
    /// Puts the field back into its display state (default: the item's name).
    var restore: ((NSTextField, FileItem) -> Void)?
    /// A new name was entered.
    var commit: ((FileItem, String, RenameCompletion?) -> Void)?
    /// Editing ended either way: catch up on deferred reloads, give the view its focus back.
    var ended: (() -> Void)?

    func begin(_ field: NSTextField, item: FileItem, onRenamed: RenameCompletion?) {
        field.isEditable = true
        field.isSelectable = true
        field.delegate = self
        self.field = field
        self.item = item
        self.onRenamed = onRenamed
        field.window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let stem = item.isBrowsable ? item.name : (item.name as NSString).deletingPathExtension
            editor.selectedRange = NSRange(location: 0, length: (stem.isEmpty ? item.name : stem).utf16.count)
        }
    }

    func end(commit: Bool) {
        guard let field, let item else { return }
        self.field = nil
        self.item = nil
        let onRenamed = self.onRenamed
        self.onRenamed = nil
        let newName = field.stringValue
        field.isEditable = false
        field.isSelectable = false
        field.delegate = nil
        if let restore { restore(field, item) } else { field.stringValue = item.name }
        if commit, newName != item.name, !newName.isEmpty { self.commit?(item, newName, onRenamed) }
        ended?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === self.field else { return }
        end(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), control === field {
            end(commit: false)
            return true
        }
        return false
    }
}

// MARK: - Status and icons

enum MissingStatusDirection {
    case left, right

    var symbol: String { self == .left ? "arrow.left" : "arrow.right" }
}

extension AppModel {
    private var hasComparisonListings: Bool {
        devicePaneBrowsable && macPane.hasListing && devicePane.hasListing
    }

    func missingStatusDirection(in pane: PaneModel) -> MissingStatusDirection? {
        guard hasComparisonListings, foldersOverlap(pane) else { return nil }
        return leftPane === pane ? .right : .left
    }

    func comparisonUnavailableReason(in pane: PaneModel) -> String? {
        hasComparisonListings && !foldersOverlap(pane) ? "Not compared: different folders" : nil
    }

    func displayedStatusToken(_ statusToken: Int, in pane: PaneModel) -> Int {
        let direction = missingStatusDirection(in: pane)
        return statusToken &* 3 &+ (direction == .left ? 1 : direction == .right ? 2 : 0)
    }
}

extension ItemStatus {
    /// How the status shows: the list's status column, the icon grid's badges, the columns' symbols.
    struct Look {
        /// Nil while a file is being copied: the list draws a progress ring instead.
        var symbol: String?
        var text: String
        var color: NSColor
        var weight: NSFont.Weight
        var fraction: Double?

        /// The symbol where no progress ring is drawn (icon badges, column rows).
        var mark: String { symbol ?? "arrow.right.circle" }
    }

    /// Comparison marks require overlapping folders; transfer marks are independent.
    func visibleLook(missingDirection: MissingStatusDirection?) -> Look? {
        guard let missingDirection else { return isTransfer ? look : nil }
        guard isMissing else { return look }
        return Look(symbol: missingDirection.symbol, text: "Missing", color: .secondaryLabelColor, weight: .medium)
    }

    /// The mark and its spoken description.
    var look: Look? {
        switch self {
        case .none, .notOnDevice, .notOnMac: return nil
        case .same:
            return Look(symbol: "checkmark.circle", text: "Same", color: .systemGreen, weight: .medium)
        case .differs:
            return Look(symbol: "circle.lefthalf.filled", text: "Differs", color: .systemOrange, weight: .medium)
        case .folderOnBoth:
            return Look(symbol: "equal.circle", text: "Exists", color: .secondaryLabelColor, weight: .regular)
        case .queued:
            return Look(symbol: "clock", text: "Queued", color: .controlAccentColor, weight: .medium)
        case .copyingFolder:
            return Look(symbol: "arrow.right.circle", text: "Copying…", color: .controlAccentColor, weight: .medium)
        case .copying(let f), .arriving(let f):
            return Look(symbol: nil, text: "\(Int((f * 100).rounded(.down)))%", color: .controlAccentColor, weight: .medium, fraction: f)
        }
    }
}

enum StatusSymbols {
    @MainActor private static var cache: [String: NSImage] = [:]

    /// `name` drawn in `color` at `size` points (cached).
    @MainActor
    static func image(_ name: String, color: NSColor, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
        let key = "\(name)|\(color.description)|\(size)|\(weight.rawValue)"
        if let cached = cache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        cache[key] = image
        return image
    }
}

/// Cells that show a file's icon and swap in its QuickLook thumbnail when it arrives.
@MainActor
protocol FileIconCell: AnyObject {
    var iconImageView: NSImageView { get }
    var representedKey: String? { get set }
}

@MainActor
enum FileIconLoader {
    /// Shows `item`'s type icon in `cell`, then (local images, movies and PDFs) its thumbnail at `size` points.
    static func load(_ item: FileItem, into cell: any FileIconCell, size: CGFloat, scale: CGFloat) {
        let key = item.url?.path ?? item.devicePath ?? item.name
        cell.representedKey = key
        guard Thumbnails.canThumbnail(item) else {
            cell.iconImageView.image = FileIcons.icon(for: item)
            return
        }
        if let cached = Thumbnails.shared.cached(for: item, size: size) {
            cell.iconImageView.image = cached
            return
        }
        cell.iconImageView.image = FileIcons.icon(for: item)
        Thumbnails.shared.thumbnail(for: item, size: size, scale: scale) { [weak cell] image in
            guard let cell, cell.representedKey == key, let image else { return }
            cell.iconImageView.image = image
        }
    }
}
