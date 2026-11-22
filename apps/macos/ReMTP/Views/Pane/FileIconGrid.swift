import AppKit
import Quartz
import SwiftUI

/// Icons view: the open folder as an NSCollectionView grid. QuickLook thumbnails for local files, type icons
/// for device files, two-line names shortened in the middle, the compare status as a badge. Selection,
/// keys, the context menu and drags work like the list; a drop on a folder icon goes into that folder,
/// anywhere else into the open folder.
struct FileIconGrid: NSViewRepresentable {
    let pane: PaneModel
    let app: AppModel
    let listingGeneration: Int
    let statusToken: Int

    init(pane: PaneModel, app: AppModel, listingGeneration: Int, statusToken: Int) {
        self.pane = pane
        self.app = app
        self.listingGeneration = listingGeneration
        self.statusToken = app.displayedStatusToken(statusToken, in: pane)
    }

    func makeCoordinator() -> FileIconCoordinator {
        FileIconCoordinator(pane: pane, app: app)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(listingGeneration: listingGeneration, statusToken: statusToken)
    }
}

/// The grid's collection view: pane keys and type-select, double-click, focus tracking, Quick Look, and
/// its own drop handling (the coordinator decides; NSCollectionView's insertion gaps aren't used).
final class PaneCollectionView: NSCollectionView, PaneDragSourceView {
    var paneKind: PaneKind?
    var onKey: ((PaneKey) -> Bool)?
    var onTypeSelect: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    var onDoubleClick: ((Int) -> Void)?
    /// Right-click on an unselected item: select it before the menu shows.
    var onMenuSelect: ((Int) -> Void)?
    /// Select All / Deselect All changed the selection.
    var onSelectionCommand: (() -> Void)?
    var onDragUpdate: ((NSDraggingInfo) -> NSDragOperation)?
    var onDragExit: (() -> Void)?
    var onDrop: ((NSDraggingInfo) -> Bool)?
    var onDragEnded: (() -> Void)?
    var quickLookPane: (() -> PaneModel?)?
    private var typeSelect = TypeSelectBuffer()

    override func keyDown(with event: NSEvent) {
        if let key = PaneKey.from(event, typing: typeSelect.isTyping), onKey?(key) == true { return }
        let continuesTyping = typeSelect.isTyping && event.keyCode == 49
        if PaneKey.isTypeSelect(event) || continuesTyping, let characters = event.characters, !characters.isEmpty {
            onTypeSelect?(typeSelect.add(characters))
            return
        }
        super.keyDown(with: event)
    }

    /// NSCollectionView takes ⌘↑ / ⌘↓ as key equivalents (scrolling) before they reach `keyDown`: the pane's
    /// ⌘ keys (open, enclosing folder, delete, copy) go to the pane first, as they do in the list.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self, event.modifierFlags.contains(.command),
           let key = PaneKey.from(event, typing: false), onKey?(key) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func selectAll(_ sender: Any?) {
        super.selectAll(sender)
        onSelectionCommand?()
    }

    override func deselectAll(_ sender: Any?) {
        super.deselectAll(sender)
        onSelectionCommand?()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let index = indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item {
            onDoubleClick?(index)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-clicking an unselected item selects it, so every command acts on the selection.
        if let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)), !selectionIndexPaths.contains(path) {
            onMenuSelect?(path.item)
        }
        window?.makeFirstResponder(self)
        return super.menu(for: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    // MARK: Drop destination

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragUpdate?(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragUpdate?(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExit?()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDrop?(sender) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {}

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragEnded?()
    }

    // MARK: Quick Look panel control

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        quickLookPane?() != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let pane = quickLookPane?() else { return }
        QuickLookController.shared.keyTarget = self
        QuickLookController.shared.take(panel, pane: pane)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookController.shared.release(panel)
    }
}

@MainActor
final class FileIconCoordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let pane: PaneModel
    let app: AppModel
    private(set) var collectionView: PaneCollectionView!
    private let highlight = DropHighlightView()
    private(set) var items: [FileItem] = []
    private var shownGeneration = -1
    private var shownStatusToken = -1
    private var shownLocation: PaneLocation?
    private var applyingSelection = false
    private var reloadPending = false
    private var focused = false
    private let renamer = InlineRenamer()
    private weak var editingItem: IconItem?
    private let contextMenu: PaneContextMenu
    private let dragSupport: PaneDragSupport
    private lazy var springs = SpringLoader { [weak self] folder in self?.pane.navigate(to: folder) }
    /// The folder icon a drag would drop into.
    private var dropIndex: Int?

    init(pane: PaneModel, app: AppModel) {
        self.pane = pane
        self.app = app
        contextMenu = PaneContextMenu(pane: pane, app: app)
        dragSupport = PaneDragSupport(pane: pane, app: app)
        super.init()
        renamer.restore = { [weak self] _, _ in
            self?.editingItem?.isEditing = false
            self?.editingItem = nil
        }
        renamer.commit = { [weak self] item, name, onRenamed in
            guard let self else { return }
            self.app.rename(item, to: name, in: self.pane, onRenamed: onRenamed)
        }
        renamer.ended = { [weak self] in
            guard let self else { return }
            if self.reloadPending || self.shownGeneration != self.pane.listingGeneration { self.reloadItems() }
            self.collectionView.window?.makeFirstResponder(self.collectionView)
        }
    }

    // MARK: Setup

    func makeView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let scroll = NSScrollView(frame: container.bounds)
        scroll.autoresizingMask = [.width, .height]
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = IconItem.size
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 12, right: 10)
        let grid = PaneCollectionView(frame: scroll.contentView.bounds)
        grid.autoresizingMask = [.width]
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.backgroundColors = [.clear]
        grid.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        grid.dataSource = self
        grid.delegate = self
        grid.menu = contextMenu.menu
        grid.paneKind = pane.kind
        grid.registerForDraggedTypes(DragPayload.pasteboardTypes)
        grid.setDraggingSourceOperationMask([.copy], forLocal: false)
        grid.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView = grid

        grid.onKey = { [weak self] key in
            guard let self else { return false }
            return PaneKeyCommands.perform(key, in: self.pane, app: self.app)
        }
        grid.onTypeSelect = { [weak self] query in self?.typeSelect(query) }
        grid.onDoubleClick = { [weak self] index in
            guard let self, self.items.indices.contains(index) else { return }
            self.app.open(self.items[index], in: self.pane)
        }
        grid.onMenuSelect = { [weak self] index in self?.userSelect([index]) }
        grid.onSelectionCommand = { [weak self] in self?.selectionDidChange() }
        grid.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.focused = focused
            if focused {
                self.app.activate(self.pane.kind)
                self.app.tableFocused = true
            } else if self.app.activeKind == self.pane.kind {
                self.app.tableFocused = false
            }
            self.refreshLooks()
        }
        grid.quickLookPane = { [weak self] in
            guard let self, self.pane.kind == .mac else { return nil }
            return self.pane
        }
        grid.onDragUpdate = { [weak self] info in self?.dragUpdated(info) ?? [] }
        grid.onDragExit = { [weak self] in
            guard let self else { return }
            self.springs.cancel()
            self.showDropTarget(nil, wholeView: false)
            self.pane.dragExited(.table)
        }
        grid.onDrop = { [weak self] info in self?.performDrop(info) ?? false }
        grid.onDragEnded = { [weak self] in
            guard let self else { return }
            self.springs.cancel()
            self.showDropTarget(nil, wholeView: false)
            self.app.dragEnded()
        }

        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        container.addSubview(scroll)
        highlight.frame = container.bounds
        highlight.autoresizingMask = [.width, .height]
        container.addSubview(highlight)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: name, object: nil)
        }
        installBridge()
        return container
    }

    /// Takes over the pane's view hooks.
    func installBridge() {
        let bridge = pane.bridge
        bridge.install(owner: self)
        #if DEBUG
        bridge.iconCoordinator = self
        #endif
        bridge.focusTarget = { [weak self] in self?.collectionView }
        bridge.selectNames = { [weak self] names, scrollTo in self?.select(names, scrollTo: scrollTo) }
        bridge.beginRename = { [weak self] name, onRenamed in self?.beginRename(name, onRenamed: onRenamed) }
    }

    @objc private func windowKeyChanged(_ notification: Notification) {
        guard (notification.object as? NSWindow) === collectionView.window else { return }
        refreshLooks()
    }

    // MARK: Updates from SwiftUI

    func update(listingGeneration: Int, statusToken: Int) {
        if listingGeneration != shownGeneration {
            // Don't pull the items out from under an inline rename; catch up when it ends.
            if renamer.isActive {
                reloadPending = true
                return
            }
            reloadItems()
            shownStatusToken = statusToken
            return
        }
        if statusToken != shownStatusToken {
            shownStatusToken = statusToken
            for case let item as IconItem in collectionView.visibleItems() {
                guard let index = collectionView.indexPath(for: item)?.item, items.indices.contains(index) else { continue }
                showStatus(of: items[index], in: item)
            }
        }
    }

    private func reloadItems() {
        reloadPending = false
        shownGeneration = pane.listingGeneration
        items = pane.items
        applyingSelection = true
        collectionView.reloadData()
        let selected = indexPaths(for: pane.selection)
        collectionView.selectionIndexPaths = selected
        applyingSelection = false
        if shownLocation != pane.location {
            shownLocation = pane.location
            if let first = selected.min() {
                scrollTo(first.item)
            } else if let clip = collectionView.enclosingScrollView?.contentView {
                clip.scroll(to: .zero)
                collectionView.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
    }

    private func syncIfNeeded() {
        if shownGeneration != pane.listingGeneration { reloadItems() }
    }

    private func indexPaths(for names: Set<String>) -> Set<IndexPath> {
        Set(items.indices.filter { names.contains(items[$0].name) }.map { IndexPath(item: $0, section: 0) })
    }

    private func scrollTo(_ index: Int) {
        guard items.indices.contains(index) else { return }
        collectionView.layoutSubtreeIfNeeded()
        collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge)
    }

    private func showStatus(of file: FileItem, in item: IconItem) {
        let status = app.status(for: file, in: pane)
        let look = status.visibleLook(missingDirection: app.missingStatusDirection(in: pane))
        item.showStatus(status, look: look, text: look == nil ? nil : app.statusText(status, in: pane))
    }

    /// Selection and focus look of the visible items.
    private func refreshLooks() {
        let emphasized = focused && (collectionView.window?.isKeyWindow ?? false)
        for case let item as IconItem in collectionView.visibleItems() { item.emphasized = emphasized }
    }

    // MARK: Data source

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let view = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath)
        guard let item = view as? IconItem, items.indices.contains(indexPath.item) else { return view }
        let file = items[indexPath.item]
        item.show(file)
        FileIconLoader.load(file, into: item, size: IconItem.iconSize, scale: collectionView.window?.backingScaleFactor ?? 2)
        showStatus(of: file, in: item)
        item.emphasized = focused && (collectionView.window?.isKeyWindow ?? false)
        item.isDropTarget = dropIndex == indexPath.item
        return item
    }

    // MARK: Selection

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange()
    }

    private func selectionDidChange() {
        guard !applyingSelection else { return }
        let names = Set(collectionView.selectionIndexPaths.compactMap { items.indices.contains($0.item) ? items[$0.item].name : nil })
        if names != pane.selection { pane.selection = names }
        QuickLookController.shared.selectionChanged()
    }

    /// A selection the user made without the collection view's own handling (type-select, right-click).
    private func userSelect(_ indexes: [Int]) {
        applyingSelection = true
        collectionView.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        applyingSelection = false
        selectionDidChange()
        if let first = indexes.first { scrollTo(first) }
    }

    private func select(_ names: Set<String>, scrollTo name: String?) {
        syncIfNeeded()
        applyingSelection = true
        collectionView.selectionIndexPaths = indexPaths(for: names)
        applyingSelection = false
        if let name, let index = items.firstIndex(where: { $0.name == name }) { scrollTo(index) }
        QuickLookController.shared.selectionChanged()
    }

    private func typeSelect(_ query: String) {
        app.activate(pane.kind)
        guard let index = TypeSelectBuffer.match(query, in: items.map(\.name)) else { return }
        userSelect([index])
    }

    // MARK: Inline rename

    private func beginRename(_ name: String, onRenamed: RenameCompletion?) {
        syncIfNeeded()
        guard let index = items.firstIndex(where: { $0.name == name }) else { return }
        scrollTo(index)
        collectionView.layoutSubtreeIfNeeded()
        guard let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? IconItem else { return }
        editingItem = item
        item.isEditing = true
        renamer.begin(item.label, item: items[index], onRenamed: onRenamed)
    }

    // MARK: Drag source

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        !renamer.isActive
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard items.indices.contains(indexPath.item) else { return nil }
        return dragSupport.writer(for: items[indexPath.item])
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                        forItemsAt indexPaths: Set<IndexPath>) {
        dragSupport.began()
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                        dragOperation operation: NSDragOperation) {
        dragSupport.ended()
    }

    // MARK: Drop target

    /// The item under `point` (collection view coordinates).
    private func index(at point: NSPoint) -> Int? {
        collectionView.indexPathForItem(at: point).map(\.item).flatMap { items.indices.contains($0) ? $0 : nil }
    }

    /// Where a drop on the item at `index` (nil: between items, on empty space) goes and what it does. Only a
    /// folder icon takes the drop itself; a folder that refuses it (one of the dragged folders) falls back to
    /// the open folder, like the list.
    func iconDrop(_ drag: DragPayload, at index: Int?) -> (DropTarget, NSDragOperation)? {
        let item = index.flatMap { items.indices.contains($0) ? items[$0] : nil }
        guard let target = pane.dropTarget(.row(item, on: true)) else { return nil }
        let operation = app.dropOperation(drag, into: target.location, in: pane)
        if operation.isEmpty, case .folder = target, let open = pane.dropTarget(.row(nil, on: false)) {
            return (open, app.dropOperation(drag, into: open.location, in: pane))
        }
        return (target, operation)
    }

    private func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        let drag = DragPayload.read(info)
        pane.dragEntered(.table, accepted: true, drag: drag)
        let point = collectionView.convert(info.draggingLocation, from: nil)
        autoscroll(near: point)
        let index = index(at: point)
        guard let (target, operation) = iconDrop(drag, at: index), !operation.isEmpty else {
            springs.cancel()
            showDropTarget(nil, wholeView: false)
            return []
        }
        if case .folder(_, let location) = target {
            showDropTarget(index, wholeView: false)
            springs.spring(location)
        } else {
            // Into the open folder: the whole grid highlights.
            showDropTarget(nil, wholeView: true)
            springs.cancel()
        }
        return operation
    }

    private func performDrop(_ info: NSDraggingInfo) -> Bool {
        springs.cancel()
        showDropTarget(nil, wholeView: false)
        defer { app.dragEnded() }
        let drag = DragPayload.read(info)
        let point = collectionView.convert(info.draggingLocation, from: nil)
        guard let (target, operation) = iconDrop(drag, at: index(at: point)), !operation.isEmpty else { return false }
        return app.performDrop(drag, into: target.location, in: pane)
    }

    private func showDropTarget(_ index: Int?, wholeView: Bool) {
        highlight.isHighlighted = wholeView
        guard dropIndex != index else { return }
        let old = dropIndex
        dropIndex = index
        for changed in [old, index].compactMap({ $0 }) {
            (collectionView.item(at: IndexPath(item: changed, section: 0)) as? IconItem)?.isDropTarget = changed == index
        }
    }

    /// Scrolls while a drag rests near the top or bottom edge.
    private func autoscroll(near point: NSPoint) {
        guard let scroll = collectionView.enclosingScrollView else { return }
        let clip = scroll.contentView
        let visible = clip.documentVisibleRect
        let edge: CGFloat = 28
        var origin = visible.origin
        if point.y < visible.minY + edge {
            origin.y -= 14
        } else if point.y > visible.maxY - edge {
            origin.y += 14
        } else {
            return
        }
        origin.y = max(0, min(origin.y, collectionView.bounds.height - visible.height))
        guard origin.y != visible.origin.y else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    #if DEBUG
    /// Self-check: the folder spring-loading would open, and an item's frame in window coordinates.
    var springTarget: PaneLocation? { springs.folder }

    func windowFrame(ofItem index: Int) -> NSRect? {
        collectionView.layoutSubtreeIfNeeded()
        guard let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) else { return nil }
        return collectionView.convert(attributes.frame, to: nil)
    }

    var isWholeViewDropHighlighted: Bool { highlight.isHighlighted }
    var dropTargetIndex: Int? { dropIndex }
    #endif
}

// MARK: - Items

/// One icon: the file's icon or thumbnail, its name in up to two lines (shortened in the middle), and its
/// compare status as a badge. Selected: a soft plate behind the icon and an accent plate behind the name.
final class IconItem: NSCollectionViewItem, FileIconCell {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")
    static let size = NSSize(width: 112, height: 116)
    static let iconSize: CGFloat = 64
    static let labelFont = NSFont.systemFont(ofSize: 12)
    static let labelWidth: CGFloat = 104

    private var itemView: IconItemView { view as! IconItemView }
    var iconImageView: NSImageView { itemView.iconView }
    var label: NSTextField { itemView.label }
    var representedKey: String?
    private(set) var file: FileItem?

    private(set) var status: ItemStatus = .none
    private var statusLook: ItemStatus.Look?
    var emphasized = false {
        didSet { if emphasized != oldValue { updateLook() } }
    }
    var isDropTarget = false {
        didSet { if isDropTarget != oldValue { updateLook() } }
    }
    var isEditing = false {
        didSet {
            guard isEditing != oldValue else { return }
            itemView.isEditing = isEditing
            if !isEditing, let file { itemView.showName(file.name) }
            updateLook()
        }
    }

    override var isSelected: Bool {
        didSet { updateLook() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateLook() }
    }

    override func loadView() {
        view = IconItemView(frame: NSRect(origin: .zero, size: Self.size))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isEditing = false
        isDropTarget = false
        representedKey = nil
        showStatus(.none, look: nil, text: nil)
    }

    func show(_ file: FileItem) {
        self.file = file
        itemView.showName(file.name)
        updateLook()
    }

    func showStatus(_ status: ItemStatus, look: ItemStatus.Look?, text: String?) {
        self.status = status
        statusLook = look
        itemView.statusText = text
        let name = file?.name ?? ""
        view.toolTip = text.map { "\(name)\n\($0)" } ?? name
        updateBadge()
    }

    private func updateBadge() {
        let badge = itemView.badgeView
        let emphasized = itemView.look.selected && itemView.look.emphasized
        badge.usesSelectionColors = emphasized
        badge.image = statusLook.flatMap {
            let color = emphasized ? NSColor.alternateSelectedControlTextColor : $0.color
            return StatusSymbols.image($0.mark, color: color, size: 12, weight: $0.weight)
        }
        badge.isHidden = statusLook == nil
    }

    private func updateLook() {
        let selectedLook = (isSelected && highlightState != .forDeselection) || highlightState == .forSelection
        itemView.look = IconItemView.Look(selected: selectedLook, emphasized: emphasized, dropTarget: isDropTarget, editing: isEditing)
        updateBadge()
    }
}

final class IconStatusBadgeView: NSImageView {
    var usesSelectionColors = false {
        didSet { if usesSelectionColors != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let plate = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        (usesSelectionColors ? NSColor.selectedContentBackgroundColor : NSColor.controlBackgroundColor).setFill()
        plate.fill()
        NSColor.separatorColor.setStroke()
        plate.stroke()
        super.draw(dirtyRect)
    }
}

/// The item's view: lays out and draws the selection plates; the icon, badge and name are subviews.
final class IconItemView: NSView {
    struct Look: Equatable {
        var selected = false
        var emphasized = false
        var dropTarget = false
        var editing = false
    }

    let iconView = NSImageView()
    let badgeView = IconStatusBadgeView()
    let label = NSTextField(labelWithString: "")
    private var name = ""
    private var lines: [String] = []
    var statusText: String?
    var look = Look() {
        didSet {
            guard look != oldValue else { return }
            applyLook()
            needsDisplay = true
        }
    }
    var isEditing = false {
        didSet {
            guard isEditing != oldValue else { return }
            if isEditing {
                label.stringValue = name
                label.drawsBackground = true
                label.backgroundColor = .textBackgroundColor
                label.textColor = .textColor
                label.isBordered = true
            } else {
                label.drawsBackground = false
                label.isBordered = false
            }
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // NSImageView registers for image and file drags itself: drops over an icon must reach the grid.
        iconView.unregisterDraggedTypes()
        badgeView.imageScaling = .scaleNone
        badgeView.unregisterDraggedTypes()
        badgeView.isHidden = true
        label.font = IconItem.labelFont
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.cell?.usesSingleLineMode = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        label.focusRingType = .default
        addSubview(iconView)
        addSubview(badgeView)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// "Boarding pass.pdf, Same in “Lisbon 2026” on this Mac": the name and the status, like a list row.
    override func accessibilityLabel() -> String? {
        statusText.map { "\(name), \($0)" } ?? name
    }

    func showName(_ name: String) {
        self.name = name
        lines = IconLabel.lines(name, width: IconItem.labelWidth - 6, font: IconItem.labelFont)
        label.stringValue = lines.joined(separator: "\n")
        label.toolTip = nil
        needsLayout = true
        needsDisplay = true
    }

    private func applyLook() {
        guard !isEditing else { return }
        label.textColor = look.selected && look.emphasized ? .alternateSelectedControlTextColor : .labelColor
    }

    private var iconFrame: NSRect {
        let size = IconItem.iconSize
        return NSRect(x: (bounds.width - size) / 2, y: 8, width: size, height: size)
    }

    private var plateFrame: NSRect { iconFrame.insetBy(dx: -5, dy: -5) }

    private var badgeFrame: NSRect {
        let icon = iconFrame
        return NSRect(x: icon.maxX - 15, y: icon.maxY - 17, width: 21, height: 21)
    }

    private static var lineHeight: CGFloat {
        let font = IconItem.labelFont
        return ceil(font.ascender - font.descender + font.leading)
    }

    private var textWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: IconItem.labelFont]
        return lines.map { ceil(($0 as NSString).size(withAttributes: attributes).width) }.max() ?? 0
    }

    private var labelPlate: NSRect {
        let top = plateFrame.maxY + 3
        let height = CGFloat(max(1, lines.count)) * Self.lineHeight + 2
        let width = min(bounds.width - 2, textWidth + 10)
        return NSRect(x: (bounds.width - width) / 2, y: top, width: width, height: height)
    }

    override func layout() {
        super.layout()
        iconView.frame = iconFrame
        badgeView.frame = badgeFrame
        let top = plateFrame.maxY + 3
        if isEditing {
            label.frame = NSRect(x: 2, y: top - 1, width: bounds.width - 4, height: max(Self.lineHeight * 2 + 6, bounds.height - top))
        } else {
            let height = CGFloat(max(1, lines.count)) * Self.lineHeight + 2
            label.frame = NSRect(x: (bounds.width - IconItem.labelWidth) / 2, y: top + 1, width: IconItem.labelWidth, height: height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if look.dropTarget {
            let plate = NSBezierPath(roundedRect: plateFrame, xRadius: 8, yRadius: 8)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            plate.fill()
            plate.lineWidth = 2
            NSColor.controlAccentColor.setStroke()
            plate.stroke()
        } else if look.selected {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: plateFrame, xRadius: 8, yRadius: 8).fill()
        }
        if look.selected, !look.editing {
            (look.emphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
            NSBezierPath(roundedRect: labelPlate, xRadius: 4, yRadius: 4).fill()
        }
    }
}

/// Icon names: up to two lines; the first wraps like the text system, the rest is shortened in the middle
/// (so the extension stays visible).
@MainActor
enum IconLabel {
    private static var cache: [String: [String]] = [:]

    static func lines(_ name: String, width: CGFloat, font: NSFont) -> [String] {
        let key = "\(width)|\(font.pointSize)|\(name)"
        if let cached = cache[key] { return cached }
        let result = compute(name, width: width, font: font)
        if cache.count > 4_000 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private static func compute(_ name: String, width: CGFloat, font: NSFont) -> [String] {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func fits(_ text: String) -> Bool { (text as NSString).size(withAttributes: attributes).width <= width }
        guard !name.isEmpty, !fits(name) else { return [name] }
        let storage = NSTextStorage(string: name, attributes: attributes)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        var glyphs = NSRange()
        _ = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &glyphs)
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let string = name as NSString
        guard characters.length > 0, NSMaxRange(characters) < string.length else { return [name] }
        let first = string.substring(with: characters).trimmingCharacters(in: .whitespaces)
        let rest = string.substring(from: NSMaxRange(characters))
        let second = fits(rest) ? rest : Format.middleTruncated(rest, width: width, font: font)
        return [first, second]
    }
}
