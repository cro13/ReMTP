import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A row in the table: a real item, or a placeholder for files arriving from a transfer.
enum PaneRow {
    case item(FileItem)
    case arriving(name: String, size: UInt64, fraction: Double)
    case summary(String)

    var item: FileItem? {
        if case .item(let item) = self { return item }
        return nil
    }
}

/// The pane's file list: a view-based NSTableView for 10k+ rows.
struct FileTable: NSViewRepresentable {
    let pane: PaneModel
    let app: AppModel
    let listingGeneration: Int
    let statusToken: Int
    let arrival: ArrivalInfo?
    let statusTitle: String

    init(pane: PaneModel, app: AppModel, listingGeneration: Int, statusToken: Int, arrival: ArrivalInfo?, statusTitle: String) {
        self.pane = pane
        self.app = app
        self.listingGeneration = listingGeneration
        self.statusToken = app.displayedStatusToken(statusToken, in: pane)
        self.arrival = arrival
        self.statusTitle = app.comparisonUnavailableReason(in: pane) ?? statusTitle
    }

    func makeCoordinator() -> FileTableCoordinator {
        FileTableCoordinator(pane: pane, app: app)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(listingGeneration: listingGeneration, statusToken: statusToken, arrival: arrival,
                                   statusTitle: statusTitle)
    }
}

@MainActor
final class FileTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let pane: PaneModel
    let app: AppModel
    private(set) var tableView: PaneTableView!
    private var rows: [PaneRow] = []
    private var itemCount = 0
    private var shownGeneration = -1
    private var shownStatusToken = -1
    private var shownArrival: ArrivalInfo?
    private var shownLocation: PaneLocation?
    private var applyingSelection = false
    private let renamer = InlineRenamer()
    private var pendingArrival: ArrivalInfo?
    private var showsStatusColumn = false
    private var fittingColumns = false
    private var automaticallyHidden: Set<NSUserInterfaceItemIdentifier> = []
    private var automaticVisibilityKey: String?
    private let contextMenu: PaneContextMenu
    private let dragSupport: PaneDragSupport
    /// Spring-loading: resting on a folder row opens it.
    private lazy var springs = SpringLoader { [weak self] folder in self?.pane.navigate(to: folder) }
    static let springDelay = SpringLoader.delay

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
            if self.shownGeneration != self.pane.listingGeneration || self.pendingArrival != self.shownArrival {
                self.reloadRows(arrival: self.pendingArrival ?? self.shownArrival)
            }
            self.pendingArrival = nil
            self.tableView.window?.makeFirstResponder(self.tableView)
        }
    }

    // MARK: Setup

    func makeScrollView() -> NSScrollView {
        // Start with a real size so the table tracks its clip view's width from then on (a zero-sized
        // start leaves the columns wider than the pane).
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let table = PaneTableView(frame: scroll.contentView.bounds)
        tableView = table
        table.style = .inset
        // Stripes come from the row views (`StripedRowView`): only rows that exist get one.
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsTypeSelect = true
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.focusRingType = .none

        func column(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat, key: SortKey,
                    alignment: NSTextAlignment = .left) -> NSTableColumn {
            let column = NSTableColumn(identifier: id)
            column.title = title
            column.width = width
            column.minWidth = min
            column.headerCell.alignment = alignment
            column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            return column
        }
        let name = column(.nameColumn, "Name", width: 280, min: 140, key: .name)
        name.resizingMask = [.autoresizingMask, .userResizingMask]
        table.addTableColumn(name)
        // A symbol per row, so the column is as narrow as one: its header shows the other side's symbol
        // and the title ("On Galaxy S23") is the header's tooltip.
        let status = column(.statusColumn, "On Device", width: 26, min: 26, key: .status)
        status.maxWidth = 26
        status.resizingMask = []
        let statusHeader = StatusHeaderCell(textCell: status.title)
        statusHeader.symbolName = pane.kind == .mac ? "smartphone" : "laptopcomputer"
        status.headerCell = statusHeader
        table.addTableColumn(status)
        table.addTableColumn(column(.modifiedColumn, "Date Modified", width: Self.dateWidth, min: 80, key: .modified))
        table.addTableColumn(column(.sizeColumn, "Size", width: 64, min: 50, key: .size, alignment: .right))
        let kind = column(.kindColumn, "Kind", width: pane.kind == .device ? Self.kindWidth : 100,
                          min: pane.kind == .device ? Self.kindWidth : 44, key: .kind)
        table.addTableColumn(kind)
        table.sortDescriptors = [NSSortDescriptor(key: SortKey.name.rawValue, ascending: true)]
        // Demo runs and the self-check share the real app's defaults domain: they don't save columns.
        if !app.isDemo {
            // v3: new column widths (narrower Date, Size and Kind) that saved v2 widths would override.
            let name = "ReMTP.\(pane.kind.rawValue).table.v3"
            table.autosaveName = name
            table.autosaveTableColumns = true
            if kind.width < kind.minWidth { kind.width = kind.minWidth }
            let key = "\(name).automaticallyHidden"
            automaticVisibilityKey = key
            if let saved = UserDefaults.standard.stringArray(forKey: key) {
                automaticallyHidden = Set(saved.map { NSUserInterfaceItemIdentifier($0) })
            } else {
                automaticallyHidden = Set([status.identifier, .kindColumn, .modifiedColumn].filter {
                    table.tableColumn(withIdentifier: $0)?.isHidden == true
                })
                UserDefaults.standard.set(automaticallyHidden.map(\.rawValue), forKey: key)
            }
        }
        // Autosave may have restored the user's last sort order.
        if let restored = table.sortDescriptors.first, let key = restored.key.flatMap(SortKey.init(rawValue:)),
           key != pane.sortKey || restored.ascending != pane.ascending {
            pane.setSort(key, ascending: restored.ascending)
        }

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

        table.onKey = { [weak self] key in
            guard let self else { return false }
            return PaneKeyCommands.perform(key, in: self.pane, app: self.app)
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

        installBridge()

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewResized(_:)),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)
        // A column the user widened takes its width from Name (or hides an optional column) right away, not
        // at the next pane resize. Name's own refit ends the loop: its width comes out the same.
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewResized(_:)),
                                               name: NSTableView.columnDidResizeNotification, object: table)
        return scroll
    }

    /// Takes over the pane's view hooks (again after a view mode change).
    func installBridge() {
        let bridge = pane.bridge
        bridge.install(owner: self)
        bridge.tableView = tableView
        #if DEBUG
        bridge.coordinator = self
        #endif
        bridge.focusTarget = { [weak self] in self?.tableView }
        bridge.selectNames = { [weak self] names, scrollTo in self?.select(names, scrollTo: scrollTo) }
        bridge.beginRename = { [weak self] name, onRenamed in self?.beginRename(name, onRenamed: onRenamed) }
    }

    @objc private func clipViewResized(_ notification: Notification) {
        fitColumns()
    }

    /// Room for a camera filename, including a suffix used to distinguish otherwise identical names.
    private static let nameFloor: CGFloat = {
        let sample = "IMG_20261007_030337_001.jpg" as NSString
        let width = sample.size(withAttributes: [.font: NameCellView.font]).width
        return ceil(width) + 2 * NameCellView.horizontalInset + NameCellView.iconSize + NameCellView.iconGap
    }()

    /// Date Modified fits a long date in the user's locale: 118 pt for "28 Sept 2025, 22:59", more where
    /// the date runs longer ("Sep 28, 2025, 10:59 PM").
    private static let dateWidth: CGFloat = {
        let parts = DateComponents(year: 2025, month: 9, day: 28, hour: 22, minute: 59)
        guard let sample = Calendar.current.date(from: parts) else { return 118 }
        let text = Format.listDate(sample) as NSString
        let width = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        return max(118, ceil(width) + 8)
    }()

    private static let kindWidth: CGFloat = {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        let widths = ["WhatsApp backup", "FLAC 24/192"].map { ($0 as NSString).size(withAttributes: attributes).width }
        return ceil(widths.max() ?? 0) + 8
    }()

    static var deviceListComfortWidth: CGFloat {
        nameFloor + kindWidth + 26 + 64 + 4 * 10 + 2 * 10
    }

    func tableView(_ tableView: NSTableView, toolTipFor cell: NSCell, rect: NSRectPointer,
                   tableColumn: NSTableColumn?, row: Int, mouseLocation: NSPoint) -> String {
        guard tableColumn?.identifier == .kindColumn, let column = tableColumn,
              let view = tableView.view(atColumn: tableView.column(withIdentifier: column.identifier), row: row,
                                        makeIfNecessary: false) as? TextCellView else { return "" }
        return view.label.stringValue
    }

    private func fitColumns() {
        guard !fittingColumns, let table = tableView, let clip = table.enclosingScrollView?.contentView,
              let name = table.tableColumn(withIdentifier: .nameColumn) else { return }
        let available = clip.bounds.width
        guard available > 0 else { return }
        fittingColumns = true
        defer { fittingColumns = false }
        // Each column takes its width plus the intercell spacing; the inset style pads both ends.
        let spacing = table.intercellSpacing.width, inset = table.rect(ofColumn: 0).minX
        let manuallyHidden = Set(table.tableColumns.filter(\.isHidden).map(\.identifier)).subtracting(automaticallyHidden)
        var fitted: Set<NSUserInterfaceItemIdentifier> = showsStatusColumn || manuallyHidden.contains(.statusColumn)
            ? [] : [.statusColumn]
        var others = table.tableColumns.filter {
            $0.identifier != .nameColumn && !manuallyHidden.contains($0.identifier) && !fitted.contains($0.identifier)
        }
            .reduce(CGFloat(0)) { $0 + $1.width + spacing }
        let hideOrder: [NSUserInterfaceItemIdentifier] = pane.location?.device != nil
            ? [.modifiedColumn, .kindColumn] : [.kindColumn, .modifiedColumn]
        for id in hideOrder where available - 2 * inset - spacing - others < Self.nameFloor {
            guard !manuallyHidden.contains(id), let column = table.tableColumn(withIdentifier: id) else { continue }
            fitted.insert(id)
            others -= column.width + spacing
        }
        if fitted != automaticallyHidden {
            automaticallyHidden = fitted
            if let key = automaticVisibilityKey {
                UserDefaults.standard.set(fitted.map(\.rawValue), forKey: key)
            }
        }
        for id in [NSUserInterfaceItemIdentifier.statusColumn, .kindColumn, .modifiedColumn] {
            guard let column = table.tableColumn(withIdentifier: id) else { continue }
            let hide = manuallyHidden.contains(id) || fitted.contains(id)
            if column.isHidden != hide { column.isHidden = hide }
        }
        guard let lastVisible = table.tableColumns.lastIndex(where: { !$0.isHidden }) else { return }
        let first = table.rect(ofColumn: 0), last = table.rect(ofColumn: lastVisible)
        let natural = last.maxX + first.minX
        let width = max(name.minWidth, name.width + (available - natural))
        if abs(width - name.width) > 0.5 { name.width = width }
    }

    // MARK: Updates from SwiftUI

    func update(listingGeneration: Int, statusToken: Int, arrival: ArrivalInfo?, statusTitle: String) {
        if let column = tableView.tableColumn(withIdentifier: .statusColumn), column.headerToolTip != statusTitle {
            column.title = statusTitle
            column.headerToolTip = statusTitle
            tableView.headerView?.needsDisplay = true
        }
        if listingGeneration != shownGeneration {
            // Don't pull the rows out from under an inline rename; catch up when it ends.
            if renamer.isActive {
                pendingArrival = arrival
                return
            }
            reloadRows(arrival: arrival)
            shownStatusToken = statusToken
            return
        }
        let arrivalChanged = arrival != shownArrival
        let statusChanged = statusToken != shownStatusToken
        if arrivalChanged {
            if renamer.isActive {
                pendingArrival = arrival
                return
            }
            updateArrivalRows(arrival)
        }
        if arrivalChanged || statusChanged { updateStatusVisibility() }
        if statusChanged {
            shownStatusToken = statusToken
            let visible = tableView.rows(in: tableView.visibleRect)
            if showsStatusColumn, visible.length > 0 {
                reloadStatus(rows: IndexSet(integersIn: visible.location..<(visible.location + visible.length)))
            }
        }
    }

    private func updateStatusVisibility() {
        let comparing = app.missingStatusDirection(in: pane) != nil
        let hasOutgoing = pane.location.map { location in
            app.transfers.jobs.contains { $0.isActive && $0.sourceFolder == location }
        } ?? false
        showsStatusColumn = shownArrival?.currentName != nil || ((comparing || hasOutgoing) && rows.contains { row in
            guard let item = row.item else { return false }
            let status = app.status(for: item, in: pane)
            return comparing ? status != .none : status.isTransfer
        })
        fitColumns()
    }

    private func reloadStatus(rows indexes: IndexSet) {
        guard let column = tableView.tableColumns.firstIndex(where: { $0.identifier == .statusColumn }) else { return }
        tableView.reloadData(forRowIndexes: indexes, columnIndexes: IndexSet(integer: column))
    }

    private static func arrivalRows(for arrival: ArrivalInfo?) -> [PaneRow] {
        guard let arrival else { return [] }
        var tail: [PaneRow] = []
        if let name = arrival.currentName {
            tail.append(.arriving(name: name, size: arrival.currentSize, fraction: arrival.fraction))
        }
        if arrival.remaining > 0 {
            let text = arrival.currentName == nil
                ? "\(Format.count(arrival.remaining, "item")) queued"
                : "\(Format.count(arrival.remaining, "more item")) queued"
            tail.append(.summary(text))
        }
        return tail
    }

    /// Updates only the trailing arrival/summary rows so rapid small-file transfers don't reload the whole table.
    private func updateArrivalRows(_ arrival: ArrivalInfo?) {
        let oldTailCount = rows.count - itemCount
        let newTail = Self.arrivalRows(for: arrival)
        shownArrival = arrival
        if oldTailCount == newTail.count {
            guard !newTail.isEmpty else { return }
            rows.replaceSubrange(itemCount..<rows.count, with: newTail)
            let rowRange = IndexSet(integersIn: itemCount..<rows.count)
            let cols = IndexSet(integersIn: 0..<tableView.numberOfColumns)
            tableView.reloadData(forRowIndexes: rowRange, columnIndexes: cols)
            return
        }
        rows.replaceSubrange(itemCount..<rows.count, with: newTail)
        tableView.beginUpdates()
        if oldTailCount > newTail.count {
            tableView.removeRows(at: IndexSet(integersIn: (itemCount + newTail.count)..<(itemCount + oldTailCount)), withAnimation: [])
        } else {
            tableView.insertRows(at: IndexSet(integersIn: (itemCount + oldTailCount)..<(itemCount + newTail.count)), withAnimation: [])
        }
        if min(oldTailCount, newTail.count) > 0 {
            let overlap = IndexSet(integersIn: itemCount..<(itemCount + min(oldTailCount, newTail.count)))
            tableView.reloadData(forRowIndexes: overlap, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }
        tableView.endUpdates()
    }

    private func reloadRows(arrival: ArrivalInfo?) {
        shownGeneration = pane.listingGeneration
        shownArrival = arrival
        var newRows = pane.items.map(PaneRow.item)
        itemCount = newRows.count
        newRows.append(contentsOf: Self.arrivalRows(for: arrival))
        rows = newRows
        applyingSelection = true
        tableView.reloadData()
        updateStatusVisibility()
        let selected = IndexSet(pane.items.indices.filter { pane.selection.contains(pane.items[$0].name) })
        tableView.selectRowIndexes(selected, byExtendingSelection: false)
        applyingSelection = false
        if shownLocation != pane.location {
            shownLocation = pane.location
            if let first = selected.first { tableView.scrollRowToVisible(first) } else if !rows.isEmpty { tableView.scrollRowToVisible(0) }
        }
    }

    private func syncRowsIfNeeded() {
        if shownGeneration != pane.listingGeneration { reloadRows(arrival: shownArrival) }
    }

    private func select(_ names: Set<String>, scrollTo: String?) {
        syncRowsIfNeeded()
        let indexes = IndexSet(pane.items.indices.filter { names.contains(pane.items[$0].name) })
        applyingSelection = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        applyingSelection = false
        if let scrollTo, let row = pane.items.firstIndex(where: { $0.name == scrollTo }) { tableView.scrollRowToVisible(row) }
        QuickLookController.shared.selectionChanged()
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        switch id {
        case .nameColumn:
            let cell = tableView.makeView(withIdentifier: .nameCell, owner: self) as? NameCellView ?? NameCellView()
            configureName(cell, entry)
            return cell
        case .statusColumn:
            let cell = tableView.makeView(withIdentifier: .statusCell, owner: self) as? StatusCellView ?? StatusCellView()
            switch entry {
            case .item(let item): cell.status = app.status(for: item, in: pane)
            case .arriving(_, _, let fraction): cell.status = .arriving(fraction)
            case .summary: cell.status = .none
            }
            cell.missingDirection = app.missingStatusDirection(in: pane)
            cell.text = cell.missingDirection != nil || cell.status.isTransfer ? app.statusText(cell.status, in: pane) : nil
            return cell
        case .modifiedColumn, .kindColumn, .sizeColumn:
            let cell = tableView.makeView(withIdentifier: .textCell, owner: self) as? TextCellView ?? TextCellView()
            cell.label.alignment = id == .sizeColumn ? .right : .left
            cell.cancelKindProbe()
            cell.toolTip = nil
            cell.label.font = id == .sizeColumn ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            switch entry {
            case .item(let item):
                switch id {
                case .modifiedColumn:
                    cell.label.stringValue = item.modified.map(Format.listDate) ?? "--"
                    // The full date, also when a narrow column cuts the list date short.
                    cell.toolTip = item.modified.map { Format.date($0) }
                case .kindColumn:
                    cell.label.stringValue = item.kind
                    if let key = FileKindDetails.Key(item) {
                        cell.kindProbe = key
                        cell.kindToken = FileKindDetails.shared.load(key) { [weak cell] suffix in
                            guard let cell, cell.kindProbe == key, let suffix else { return }
                            cell.label.stringValue = "\(item.kind) \(suffix)"
                        }
                    }
                default: cell.label.stringValue = item.size.map(Format.bytes) ?? "--"
                }
            case .arriving(let name, let size, _):
                switch id {
                case .modifiedColumn: cell.label.stringValue = ""
                case .kindColumn:
                    cell.label.stringValue = FileKinds.describe(name: name, isDirectory: false,
                                                                type: FileKinds.type(for: name, isDirectory: false))
                default: cell.label.stringValue = Format.bytes(size)
                }
            case .summary:
                cell.label.stringValue = ""
            }
            return cell
        default:
            return nil
        }
    }

    private func configureName(_ cell: NameCellView, _ entry: PaneRow) {
        cell.label.textColor = .labelColor
        cell.label.font = .systemFont(ofSize: 13)
        switch entry {
        case .item(let item):
            cell.label.stringValue = item.name
            cell.label.toolTip = nil
            FileIconLoader.load(item, into: cell, size: 36, scale: tableView.window?.backingScaleFactor ?? 2)
        case .arriving(let name, _, _):
            let item = FileItem(name: name, isDirectory: false, size: nil, modified: nil)
            cell.representedKey = nil
            cell.label.stringValue = name
            cell.iconView.image = FileIcons.icon(for: item)
        case .summary(let text):
            cell.representedKey = nil
            cell.label.stringValue = text
            cell.iconView.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            cell.iconView.contentTintColor = .secondaryLabelColor
        }
        if case .summary = entry {} else { cell.iconView.contentTintColor = nil }
    }

    // MARK: Delegate

    /// A row scrolled away or dropped by a reload (another folder) no longer wants its Kind details: the
    /// probe is cancelled so it doesn't queue ahead of the rows now on screen.
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        for column in 0..<rowView.numberOfColumns {
            (rowView.view(atColumn: column) as? TextCellView)?.cancelKindProbe()
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: .stripedRow, owner: self) as? StripedRowView ?? StripedRowView()
        view.identifier = .stripedRow
        view.striped = row % 2 == 1
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row].item != nil
    }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.filteredIndexSet { $0 < itemCount }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !applyingSelection else { return }
        let names = Set(tableView.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].item?.name : nil })
        if names != pane.selection { pane.selection = names }
        QuickLookController.shared.selectionChanged()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key.flatMap(SortKey.init(rawValue:)) else { return }
        pane.setSort(key, ascending: descriptor.ascending)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tableColumn?.identifier == .nameColumn, rows.indices.contains(row) else { return nil }
        return rows[row].item?.name
    }

    @objc func doubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard rows.indices.contains(row), let item = rows[row].item else { return }
        app.open(item, in: pane)
    }

    // MARK: Inline rename

    private func beginRename(_ name: String, onRenamed: RenameCompletion?) {
        syncRowsIfNeeded()
        guard let row = pane.items.firstIndex(where: { $0.name == name }), let item = rows[row].item else { return }
        tableView.scrollRowToVisible(row)
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCellView else { return }
        renamer.begin(cell.label, item: item, onRenamed: onRenamed)
    }

    // MARK: Drag source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row), let item = rows[row].item else { return nil }
        return dragSupport.writer(for: item)
    }

    // MARK: Drag session

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        dragSupport.began()
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        dragSupport.ended()
    }

    // MARK: Drop target

    /// Where a drop at (`row`, `dropOperation`) goes and what it does. A folder row that refuses the drag
    /// (e.g. one of the dragged folders) falls back to the open folder.
    func tableDrop(_ drag: DragPayload, row: Int, dropOperation: NSTableView.DropOperation) -> (DropTarget, NSDragOperation)? {
        let item = row >= 0 && row < itemCount && rows.indices.contains(row) ? rows[row].item : nil
        guard let target = pane.dropTarget(.row(item, on: dropOperation == .on)) else { return nil }
        let operation = app.dropOperation(drag, into: target.location, in: pane)
        if operation.isEmpty, case .folder = target, let open = pane.dropTarget(.row(nil, on: false)) {
            return (open, app.dropOperation(drag, into: open.location, in: pane))
        }
        return (target, operation)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        let drag = DragPayload.read(info)
        pane.dragEntered(.table, accepted: true, drag: drag)
        guard let (target, operation) = tableDrop(drag, row: row, dropOperation: dropOperation), !operation.isEmpty else {
            springs.cancel()
            return []
        }
        if case .folder(_, let location) = target {
            springs.spring(location)
        } else {
            // Into the open folder: the whole list highlights.
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
        guard let (target, operation) = tableDrop(drag, row: row, dropOperation: dropOperation), !operation.isEmpty else {
            return false
        }
        return app.performDrop(drag, into: target.location, in: pane)
    }

    #if DEBUG
    /// Self-check: the folder spring-loading would open.
    var springTarget: PaneLocation? { springs.folder }
    #endif
}
