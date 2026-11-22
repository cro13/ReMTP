import AppKit
import SwiftUI

extension NSUserInterfaceItemIdentifier {
    static let columnCell = NSUserInterfaceItemIdentifier("columnCell")
}

/// Columns view: a Finder-like column browser, one table per folder level from the root (home or the
/// volume on the Mac, the storage on a device) down to the open folder. Selecting a single folder opens it
/// in the next column; the open folder is always the deepest selected folder, which is the pane's location
/// (the path bar, the footer and the drop bar follow it). With nothing selected inside it, commands act on
/// the open folder itself (`PaneModel.targetItems`). ← / → move between columns.
struct FileColumns: NSViewRepresentable {
    let pane: PaneModel
    let app: AppModel
    let location: PaneLocation?
    let listingGeneration: Int
    let statusToken: Int
    let showHidden: Bool

    init(pane: PaneModel, app: AppModel, location: PaneLocation?, listingGeneration: Int, statusToken: Int, showHidden: Bool) {
        self.pane = pane
        self.app = app
        self.location = location
        self.listingGeneration = listingGeneration
        self.statusToken = app.displayedStatusToken(statusToken, in: pane)
        self.showHidden = showHidden
    }

    func makeCoordinator() -> ColumnBrowserCoordinator {
        ColumnBrowserCoordinator(pane: pane, app: app)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(statusToken: statusToken)
    }
}

/// The browser's scroll view: a mouse wheel moves sideways by whole columns (trackpad swipes, which have
/// phases, scroll freely and settle on a column when they end).
final class ColumnScrollView: NSScrollView {
    /// Scrolls by this many columns.
    var step: ((Int) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard let step, event.phase.isEmpty, event.momentumPhase.isEmpty, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
            return super.scrollWheel(with: event)
        }
        step(event.scrollingDeltaX > 0 ? -1 : 1)
    }
}

/// The columns' document view: lays the columns out side by side and draws the lines between them.
final class ColumnStackView: NSView {
    var separators: [CGFloat] = [] {
        didSet { if separators != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        for x in separators { NSRect(x: x, y: 0, width: 1, height: bounds.height).fill() }
    }
}

@MainActor
final class ColumnBrowserCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// One folder level.
    final class Column {
        var folder: PaneLocation
        var items: [FileItem] = []
        /// `items` hold a listing of `folder` (not just a placeholder).
        var loaded = false
        let table: PaneTableView
        let scroll: NSScrollView
        var loadToken = 0
        /// Mac folders of earlier columns: re-listed when they change on disk (the pane watches the open folder).
        var watcher: DirectoryWatcher?

        init(folder: PaneLocation, table: PaneTableView, scroll: NSScrollView) {
            self.folder = folder
            self.table = table
            self.scroll = scroll
        }
    }

    /// Columns are at most `columnWidth` and at least `minColumnWidth` wide: they share the pane's width
    /// in whole columns, and the browser scrolls by whole columns, so the leftmost one is never cut off.
    static let columnWidth: CGFloat = 240
    static let minColumnWidth: CGFloat = 200

    /// How many columns fit side by side in `width` points, and how wide each is (1 pt lines between them).
    static func tile(_ width: CGFloat) -> (count: Int, width: CGFloat) {
        var count = max(1, Int(((width + 1) / (columnWidth + 1)).rounded(.up)))
        while count > 1, ((width + 1) / CGFloat(count)).rounded(.down) - 1 < minColumnWidth { count -= 1 }
        return (count, max(1, ((width + 1) / CGFloat(count)).rounded(.down) - 1))
    }

    let pane: PaneModel
    let app: AppModel
    private var scroll: NSScrollView!
    private var stack: ColumnStackView!
    private(set) var columns: [Column] = []
    private var tiling = (count: 1, width: columnWidth)
    private var shownGeneration = -1
    private var shownStatusToken = -1
    private var shownLocation: PaneLocation?
    private var shownShowHidden = false
    private var applyingSelection = false
    /// The names a column selected as the user moved up into it (shown until the pane has loaded it).
    private var pendingNames: Set<String>?
    private let renamer = InlineRenamer()
    private weak var renamingColumn: Column?
    private var pendingStatusToken: Int?
    private let contextMenu: PaneContextMenu
    private let dragSupport: PaneDragSupport
    private lazy var springs = SpringLoader { [weak self] folder in self?.pane.navigate(to: folder) }

    init(pane: PaneModel, app: AppModel) {
        self.pane = pane
        self.app = app
        contextMenu = PaneContextMenu(pane: pane, app: app)
        dragSupport = PaneDragSupport(pane: pane, app: app)
        super.init()
        renamer.commit = { [weak self] item, name, onRenamed in
            guard let self else { return }
            self.app.rename(item, to: name, in: self.pane, onRenamed: onRenamed)
        }
        renamer.ended = { [weak self] in
            guard let self else { return }
            let column = self.renamingColumn
            self.renamingColumn = nil
            if let token = self.pendingStatusToken { self.update(statusToken: token) }
            if let table = column?.table ?? self.columns.last?.table { table.window?.makeFirstResponder(table) }
        }
    }

    // MARK: Setup

    func makeView() -> NSScrollView {
        let scroll = ColumnScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.step = { [weak self] by in
            guard let self else { return }
            self.showColumns(from: self.leftmostColumn + by, animated: true)
        }
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .none
        let stack = ColumnStackView(frame: scroll.contentView.bounds)
        scroll.documentView = stack
        self.scroll = scroll
        self.stack = stack
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewResized(_:)),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollEnded(_:)),
                                               name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        installBridge()
        return scroll
    }

    /// Takes over the pane's view hooks.
    func installBridge() {
        let bridge = pane.bridge
        bridge.install(owner: self)
        #if DEBUG
        bridge.columnCoordinator = self
        #endif
        bridge.focusTarget = { [weak self] in self?.focusColumn?.table }
        bridge.selectNames = { [weak self] names, scrollTo in self?.select(names, scrollTo: scrollTo) }
        bridge.beginRename = { [weak self] name, onRenamed in self?.beginRename(name, onRenamed: onRenamed) }
        bridge.enterOpenFolder = { [weak self] in
            guard let self, let last = self.columns.last else { return }
            self.enter(last)
        }
        bridge.folderChanged = { [weak self] folder in
            guard let self else { return }
            for column in self.columns.dropLast() where column.folder.isSameFolder(as: folder) { self.load(column) }
        }
    }

    @objc private func clipViewResized(_ notification: Notification) {
        layoutColumns()
        scrollToLastColumn()
    }

    /// A trackpad swipe or a scroller drag ended: settle on the nearest whole column.
    @objc private func liveScrollEnded(_ notification: Notification) {
        showColumns(from: leftmostColumn, animated: true)
    }

    private func makeColumn(_ folder: PaneLocation) -> Column {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.columnWidth, height: 400))
        let table = PaneTableView(frame: scroll.contentView.bounds)
        table.style = .inset
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.focusRingType = .none
        let name = NSTableColumn(identifier: .nameColumn)
        name.resizingMask = .autoresizingMask
        name.width = Self.columnWidth - 24
        table.addTableColumn(name)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.menu = contextMenu.menu
        table.paneKind = pane.kind
        table.registerForDraggedTypes(DragPayload.pasteboardTypes)
        table.setDraggingSourceOperationMask([.copy], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.draggingDestinationFeedbackStyle = .regular

        table.onKey = { [weak self, weak table] key in
            guard let self, let table else { return false }
            return self.handle(key, in: table)
        }
        table.onDragHover = { [weak self] info in
            guard let self else { return }
            if let info {
                self.pane.dragEntered(.table, accepted: true, drag: DragPayload.read(info))
            } else {
                self.springs.cancel()
                self.pane.dragExited(.table)
            }
        }
        table.onDragEnded = { [weak self] in
            self?.springs.cancel()
            self?.app.dragEnded()
        }
        table.onFocusChange = { [weak self] focused in
            guard let self else { return }
            if focused {
                self.app.activate(self.pane.kind)
                self.app.tableFocused = true
            } else if self.app.activeKind == self.pane.kind {
                self.app.tableFocused = false
            }
        }
        table.quickLookPane = { [weak self] in
            guard let self, self.pane.kind == .mac else { return nil }
            return self.pane
        }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        return Column(folder: folder, table: table, scroll: scroll)
    }

    // MARK: Folder chain

    /// The folders the columns show, from the root down to the open folder (the pane's location, exactly).
    static func chain(for pane: PaneModel) -> [PaneLocation] {
        guard let location = pane.location else { return [] }
        var chain: [PaneLocation] = []
        for crumb in pane.crumbs where !(chain.last?.isSameFolder(as: crumb.location) ?? false) {
            chain.append(crumb.location)
        }
        if let last = chain.last, last.isSameFolder(as: location) {
            chain[chain.count - 1] = location
        } else {
            chain.append(location)
        }
        return chain
    }

    private func columnIndex(_ table: NSTableView) -> Int? {
        columns.firstIndex { $0.table === table }
    }

    private var focusedColumn: Column? {
        columns.first { column in column.table.window.map { $0.firstResponder === column.table } ?? false }
    }

    /// Where the pane's focus goes: the focused column, else the column showing the selection (the open
    /// folder's own column when something in it is selected, else the column the open folder is selected in).
    private var focusColumn: Column? {
        focusedColumn ?? selectionColumn
    }

    private var selectionColumn: Column? {
        if pane.selection.isEmpty, columns.count >= 2 { return columns[columns.count - 2] }
        return columns.last
    }

    // MARK: Updates

    func update(statusToken: Int) {
        // Don't pull rows out from under an inline rename; catch up when it ends.
        if renamer.isActive {
            pendingStatusToken = statusToken
            return
        }
        pendingStatusToken = nil
        if pane.location != shownLocation || pane.showHidden != shownShowHidden { rebuild() }
        if pane.listingGeneration != shownGeneration { refreshLastColumn() }
        if statusToken != shownStatusToken {
            shownStatusToken = statusToken
            if let last = columns.last { reloadVisibleRows(of: last) }
        }
    }

    /// Lines the columns up with the pane's location: columns for folders still on the way down stay
    /// (with their selection and scroll position), the rest are replaced.
    private func rebuild() {
        let hiddenChanged = pane.showHidden != shownShowHidden
        let previousLast = columns.last
        shownLocation = pane.location
        shownShowHidden = pane.showHidden
        let chain = Self.chain(for: pane)
        var keep = 0
        while keep < columns.count, keep < chain.count, columns[keep].folder.isSameFolder(as: chain[keep]) { keep += 1 }
        let hadFocus = focusedColumn != nil
        let focusedFolder = focusedColumn?.folder
        for column in columns[keep...] { column.scroll.removeFromSuperview() }
        columns.removeSubrange(keep...)
        for folder in chain[keep...] {
            let column = makeColumn(folder)
            columns.append(column)
            stack.addSubview(column.scroll)
        }
        if let last = columns.last, let location = pane.location { last.folder = location }
        layoutColumns()
        for (index, column) in columns.enumerated() {
            if index < columns.count - 1 {
                if hiddenChanged || index >= keep { column.loaded = false }
                load(column)
                selectChild(in: index)
                if column.watcher == nil, let url = column.folder.macURL {
                    let watcher = DirectoryWatcher { [weak self, weak column] in
                        guard let self, let column else { return }
                        self.load(column)
                    }
                    watcher.watch(url)
                    column.watcher = watcher
                }
            } else {
                column.watcher = nil
            }
        }
        // The column that was last no longer shows statuses (they compare the open folder only).
        if let previousLast, previousLast !== columns.last, columns.contains(where: { $0 === previousLast }) {
            reloadVisibleRows(of: previousLast)
        }
        if let last = columns.last, keep == columns.count {
            // Moved up into a column that stays: show the selection it should have while the pane loads it.
            setSelection(pendingNames ?? pane.selection, in: last)
        }
        pendingNames = nil
        scrollToLastColumn()
        // The focus stays in its column while it is one of the last two (the user moved there); after the
        // pane went somewhere else it goes to the column showing the selection.
        if hadFocus {
            let index = focusedFolder.flatMap { folder in columns.firstIndex { $0.folder.isSameFolder(as: folder) } }
            if index.map({ $0 < columns.count - 2 }) ?? true, let column = selectionColumn {
                column.table.window?.makeFirstResponder(column.table)
            }
        }
        updateOpenFolderItem()
    }

    /// The open folder's column shows the pane's own listing (filtered and sorted like the list).
    private func refreshLastColumn() {
        shownGeneration = pane.listingGeneration
        guard let last = columns.last else { return }
        // Until the pane has listed it, a column that was already showing the folder keeps its rows.
        if pane.hasListing || pane.loadError != nil || !last.loaded {
            last.items = pane.items
            last.loaded = pane.hasListing
            applyingSelection = true
            last.table.reloadData()
            applyingSelection = false
            setSelection(pane.selection, in: last)
        }
        updateOpenFolderItem()
    }

    private func reloadVisibleRows(of column: Column) {
        let visible = column.table.rows(in: column.table.visibleRect)
        guard visible.length > 0 else { return }
        column.table.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                                columnIndexes: IndexSet(integer: 0))
    }

    private func layoutColumns() {
        guard let scroll, let stack else { return }
        let visible = scroll.contentView.bounds
        tiling = Self.tile(visible.width)
        var x: CGFloat = 0
        var separators: [CGFloat] = []
        for column in columns {
            column.scroll.frame = NSRect(x: x, y: 0, width: tiling.width, height: visible.height)
            column.table.sizeLastColumnToFit()
            x += tiling.width
            separators.append(x)
            x += 1
        }
        stack.separators = separators
        let hidden = CGFloat(max(0, columns.count - tiling.count))
        let size = NSSize(width: visible.width + hidden * (tiling.width + 1), height: visible.height)
        if stack.frame.size != size { stack.setFrameSize(size) }
    }

    /// The column nearest the left edge.
    private var leftmostColumn: Int {
        Int((scroll.contentView.bounds.minX / (tiling.width + 1)).rounded())
    }

    /// Keeps the deepest column in view.
    private func scrollToLastColumn() {
        showColumns(from: columns.count - tiling.count, animated: false)
    }

    /// Scrolls so the column at `index` (as far as the columns allow) is the leftmost one, whole.
    private func showColumns(from index: Int, animated: Bool) {
        let clip = scroll.contentView
        let origin = NSPoint(x: CGFloat(max(0, min(index, columns.count - tiling.count))) * (tiling.width + 1), y: 0)
        guard origin != clip.bounds.origin else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scroll.reflectScrolledClipView(self.scroll.contentView)
                }
            }
        } else {
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// Selects the next column's folder in the column at `index`.
    private func selectChild(in index: Int) {
        guard index + 1 < columns.count else { return }
        let column = columns[index]
        let next = columns[index + 1].folder
        let rows = IndexSet(column.items.indices.filter { pane.location(of: column.items[$0])?.isSameFolder(as: next) == true })
        guard column.table.selectedRowIndexes != rows else { return }
        applyingSelection = true
        column.table.selectRowIndexes(rows, byExtendingSelection: false)
        applyingSelection = false
        if let row = rows.first { column.table.scrollRowToVisible(row) }
    }

    private func setSelection(_ names: Set<String>, in column: Column) {
        let rows = IndexSet(column.items.indices.filter { names.contains(column.items[$0].name) })
        guard column.table.selectedRowIndexes != rows else { return }
        applyingSelection = true
        column.table.selectRowIndexes(rows, byExtendingSelection: false)
        applyingSelection = false
    }

    /// Tells the pane which row of the column before it is the open folder (commands act on it while
    /// nothing inside it is selected).
    private func updateOpenFolderItem() {
        guard columns.count >= 2, let location = pane.location else { return pane.setOpenFolderItem(nil) }
        let parent = columns[columns.count - 2]
        pane.setOpenFolderItem(parent.items.first { pane.location(of: $0)?.isSameFolder(as: location) == true })
    }

    // MARK: Loading earlier columns

    /// Lists an earlier column's folder off the main thread (the open folder's column uses the pane's listing).
    private func load(_ column: Column) {
        column.loadToken &+= 1
        let token = column.loadToken
        let folder = column.folder
        let showHidden = pane.showHidden
        let app = self.app
        Task {
            let listed = await Self.list(folder, showHidden: showHidden, app: app)
            guard column.loadToken == token, let index = self.columns.firstIndex(where: { $0 === column }),
                  index < self.columns.count - 1 else { return }
            var items = listed ?? (column.loaded ? column.items : [])
            // The next column's folder always has a row (hidden folders such as /tmp or ~/Library).
            let next = self.columns[index + 1].folder
            if !items.contains(where: { self.pane.location(of: $0)?.isSameFolder(as: next) == true }), let extra = Self.item(for: next) {
                items.append(extra)
            }
            items = PaneModel.sorted(items, by: self.pane.sortKey, ascending: self.pane.ascending)
            if items != column.items || !column.loaded {
                column.items = items
                column.loaded = true
                if !(self.renamer.isActive && self.renamingColumn === column) {
                    self.applyingSelection = true
                    column.table.reloadData()
                    self.applyingSelection = false
                }
            }
            self.selectChild(in: index)
            if index == self.columns.count - 2 { self.updateOpenFolderItem() }
        }
    }

    private static func list(_ folder: PaneLocation, showHidden: Bool, app: AppModel) async -> [FileItem]? {
        switch folder {
        case .mac(let url):
            return try? await offMain { try LocalFileSystem.list(url, showHidden: showHidden) }
        case .device(let loc):
            guard let connection = app.connection(for: loc.deviceID) else { return nil }
            let entries = try? await offMain { try connection.list(storageID: loc.storageID, path: loc.path) }
            return entries?.map { FileItem.device($0, in: loc) }.filter { showHidden || !$0.isHidden }
        }
    }

    /// A row for a folder the listing leaves out.
    private static func item(for folder: PaneLocation) -> FileItem? {
        switch folder {
        case .mac(let url):
            let url = url.standardizedFileURL
            return FileItem(name: url.lastPathComponent, isDirectory: true, size: nil, modified: nil, url: url, isHidden: true)
        case .device(let loc):
            guard !DevicePath.isRoot(loc.path) else { return nil }
            return FileItem(name: DevicePath.lastComponent(loc.path), isDirectory: true, size: nil, modified: nil,
                            devicePath: loc.path, isHidden: true)
        }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int {
        columnIndex(tableView).map { columns[$0].items.count } ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let index = columnIndex(tableView), columns[index].items.indices.contains(row) else { return nil }
        let item = columns[index].items[row]
        let cell = tableView.makeView(withIdentifier: .columnCell, owner: self) as? ColumnCellView ?? ColumnCellView()
        let status = index == columns.count - 1 ? app.status(for: item, in: pane) : .none
        let look = status.visibleLook(missingDirection: app.missingStatusDirection(in: pane))
        cell.show(item, look: look, text: look == nil ? nil : app.statusText(status, in: pane))
        FileIconLoader.load(item, into: cell, size: 36, scale: tableView.window?.backingScaleFactor ?? 2)
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard let index = columnIndex(tableView), columns[index].items.indices.contains(row) else { return nil }
        return columns[index].items[row].name
    }

    // MARK: Selection

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection, let table = notification.object as? NSTableView, let index = columnIndex(table) else { return }
        userSelectionChanged(in: index)
    }

    /// The user changed the selection in the column at `index`. A single folder opens in the next column
    /// (and is the open folder); anything else makes that column's folder the open folder, with the
    /// selection inside it.
    private func userSelectionChanged(in index: Int) {
        let column = columns[index]
        let selected = column.table.selectedRowIndexes.compactMap { column.items.indices.contains($0) ? column.items[$0] : nil }
        let names = Set(selected.map(\.name))
        if selected.count == 1, let folder = selected.first, folder.isBrowsable, let target = pane.location(of: folder) {
            if target.isSameFolder(as: pane.location) {
                // Back on the open folder's row: nothing inside it is selected any more.
                if !pane.selection.isEmpty { pane.selection = [] }
                if let last = columns.last { setSelection([], in: last) }
            } else {
                pane.navigate(to: target)
            }
            pane.setOpenFolderItem(folder)
        } else if index == columns.count - 1 {
            if names != pane.selection { pane.selection = names }
        } else {
            pendingNames = names
            pane.navigate(to: column.folder, selecting: names)
        }
        QuickLookController.shared.selectionChanged()
    }

    /// Selection set from outside (after a reload, a new folder, a rename): the open folder's column.
    private func select(_ names: Set<String>, scrollTo name: String?) {
        if pane.location != shownLocation { rebuild() }
        if pane.listingGeneration != shownGeneration { refreshLastColumn() }
        guard let last = columns.last else { return }
        setSelection(names, in: last)
        if let name, let row = last.items.firstIndex(where: { $0.name == name }) {
            last.table.scrollRowToVisible(row)
            // A reveal (the footer's counts, a rename) also brings the open folder's column into view when
            // the browser was scrolled back to its ancestors.
            scrollToLastColumn()
        }
        // The focus follows a selection made inside the open folder (going up, after a rename or a new folder).
        if !names.isEmpty, let focused = focusedColumn, focused !== last { last.table.window?.makeFirstResponder(last.table) }
        QuickLookController.shared.selectionChanged()
    }

    /// Moves into `column` (the open folder's): focuses it and selects its first row if nothing is selected.
    private func enter(_ column: Column) {
        column.table.window?.makeFirstResponder(column.table)
        guard column.table.selectedRowIndexes.isEmpty, column.table.numberOfRows > 0 else { return }
        column.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        column.table.scrollRowToVisible(0)
    }

    // MARK: Keys

    private func handle(_ key: PaneKey, in table: PaneTableView) -> Bool {
        guard let index = columnIndex(table) else { return false }
        switch key {
        case .left:
            app.activate(pane.kind)
            guard index > 0 else { return true }
            let previous = columns[index - 1]
            previous.table.window?.makeFirstResponder(previous.table)
            userSelectionChanged(in: index - 1)
            return true
        case .right:
            app.activate(pane.kind)
            let rows = table.selectedRowIndexes
            guard rows.count == 1, let row = rows.first, columns[index].items.indices.contains(row),
                  columns[index].items[row].isBrowsable, index + 1 < columns.count else { return true }
            enter(columns[index + 1])
            return true
        default:
            return PaneKeyCommands.perform(key, in: pane, app: app)
        }
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        guard let index = columnIndex(sender), columns[index].items.indices.contains(sender.clickedRow) else { return }
        let item = columns[index].items[sender.clickedRow]
        if item.isBrowsable {
            if index + 1 < columns.count { enter(columns[index + 1]) }
        } else {
            app.open(item, in: pane)
        }
    }

    // MARK: Inline rename

    private func beginRename(_ name: String, onRenamed: RenameCompletion?) {
        if pane.location != shownLocation { rebuild() }
        if pane.listingGeneration != shownGeneration { refreshLastColumn() }
        if let last = columns.last, let row = last.items.firstIndex(where: { $0.name == name }),
           pane.selection.contains(name) || pane.openFolderItem?.name != name || columns.count < 2 {
            return beginRename(in: last, row: row, onRenamed: onRenamed)
        }
        if columns.count >= 2, let folder = pane.openFolderItem, folder.name == name {
            let parent = columns[columns.count - 2]
            if let row = parent.items.firstIndex(where: { $0.name == name }) {
                beginRename(in: parent, row: row, onRenamed: onRenamed)
            }
        }
    }

    private func beginRename(in column: Column, row: Int, onRenamed: RenameCompletion?) {
        column.table.scrollRowToVisible(row)
        guard let cell = column.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ColumnCellView else { return }
        renamingColumn = column
        renamer.begin(cell.label, item: column.items[row], onRenamed: onRenamed)
    }

    // MARK: Drag source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard !renamer.isActive, let index = columnIndex(tableView), columns[index].items.indices.contains(row) else { return nil }
        return dragSupport.writer(for: columns[index].items[row])
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        dragSupport.began()
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        dragSupport.ended()
    }

    // MARK: Drop target

    /// Where a drop on `row` of the column at `index` goes and what it does. `.on` a folder row: into that
    /// folder (a folder that refuses the drag falls back to the column's folder). Anywhere else in a
    /// column: into that column's folder, which for the last column is the open folder.
    func columnDrop(_ drag: DragPayload, column index: Int, row: Int, on: Bool) -> (DropTarget, NSDragOperation)? {
        guard columns.indices.contains(index) else { return nil }
        let column = columns[index]
        let item = column.items.indices.contains(row) ? column.items[row] : nil
        let own: DropTarget
        if index == columns.count - 1 {
            guard let open = pane.dropTarget(.row(nil, on: false)) else { return nil }
            own = open
        } else {
            own = .ancestor(column.folder)
        }
        var target = own
        if on, let item, item.isBrowsable, let location = pane.location(of: item) { target = .folder(item, location) }
        let operation = app.dropOperation(drag, into: target.location, in: pane)
        if operation.isEmpty, case .folder = target {
            return (own, app.dropOperation(drag, into: own.location, in: pane))
        }
        return (target, operation)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let drag = DragPayload.read(info)
        pane.dragEntered(.table, accepted: true, drag: drag)
        guard let index = columnIndex(tableView),
              let (target, operation) = columnDrop(drag, column: index, row: row, on: dropOperation == .on), !operation.isEmpty else {
            springs.cancel()
            return []
        }
        if case .folder(_, let location) = target {
            springs.spring(location)
        } else {
            // Into the column's folder: the whole column highlights.
            springs.cancel()
            tableView.setDropRow(-1, dropOperation: .on)
        }
        return operation
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        springs.cancel()
        defer { app.dragEnded() }
        let drag = DragPayload.read(info)
        guard let index = columnIndex(tableView),
              let (target, operation) = columnDrop(drag, column: index, row: row, on: dropOperation == .on), !operation.isEmpty else {
            return false
        }
        return app.performDrop(drag, into: target.location, in: pane)
    }

    #if DEBUG
    /// Self-check: the folder spring-loading would open.
    var springTarget: PaneLocation? { springs.folder }
    #endif
}

/// A column row: icon (or thumbnail), name, the compare status (open folder's column only) and a chevron
/// on folders.
final class ColumnCellView: NSTableCellView, FileIconCell {
    let iconView = NSImageView()
    let label = NSTextField(labelWithString: "")
    private let statusView = NSImageView()
    private let chevron = NSImageView()
    var representedKey: String?
    var iconImageView: NSImageView { iconView }
    private var look: ItemStatus.Look?
    private var statusText: String?
    /// Hidden status symbols and chevrons give their room to the name.
    private var statusWidth: NSLayoutConstraint!
    private var statusGap: NSLayoutConstraint!
    private var chevronWidth: NSLayoutConstraint!

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    init() {
        super.init(frame: .zero)
        identifier = .columnCell
        for view in [iconView, statusView, chevron] {
            view.translatesAutoresizingMaskIntoConstraints = false
            // NSImageView takes image and file drags itself: drops over a row must reach the table.
            view.unregisterDraggedTypes()
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        statusView.imageScaling = .scaleNone
        chevron.imageScaling = .scaleNone
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        label.cell?.wraps = false
        label.isEditable = false
        label.isSelectable = false
        label.focusRingType = .none
        label.drawsBackground = false
        label.isBordered = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [iconView, label, statusView, chevron] as [NSView] { addSubview(view) }
        imageView = iconView
        textField = label
        statusWidth = statusView.widthAnchor.constraint(equalToConstant: 14)
        statusGap = chevron.leadingAnchor.constraint(equalTo: statusView.trailingAnchor, constant: 3)
        chevronWidth = chevron.widthAnchor.constraint(equalToConstant: 9)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusView.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            statusView.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusWidth,
            statusGap,
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronWidth,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// `text`: the status in words, as in the list's status column (tooltip, VoiceOver).
    func show(_ item: FileItem, look: ItemStatus.Look?, text: String?) {
        label.stringValue = item.name
        chevron.isHidden = !item.isBrowsable
        chevronWidth.constant = item.isBrowsable ? 9 : 0
        self.look = look
        statusText = text
        statusWidth.constant = look == nil ? 0 : 14
        statusGap.constant = look == nil || !item.isBrowsable ? 0 : 3
        toolTip = text.map { "\(item.name) · \($0)" }
        applyColors()
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        chevron.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .tertiaryLabelColor
        if let look {
            let color = emphasized ? NSColor.alternateSelectedControlTextColor : look.color
            statusView.image = StatusSymbols.image(look.mark, color: color, size: 12, weight: look.weight)
            statusView.isHidden = false
            statusView.setAccessibilityLabel(statusText ?? look.text)
        } else {
            statusView.image = nil
            statusView.isHidden = true
        }
    }
}
