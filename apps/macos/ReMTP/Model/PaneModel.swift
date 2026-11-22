import AppKit
import Observation

enum SortKey: String {
    case name, status, modified, kind, size
}

/// How a pane shows its folder: a sortable list, a column browser or an icon grid.
enum PaneViewMode: String, CaseIterable, Identifiable {
    case list, columns, icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "List"
        case .columns: return "Columns"
        case .icons: return "Icons"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        case .icons: return "square.grid.2x2"
        }
    }

    /// ⌘1 / ⌘2 / ⌘3, in the toolbar control's order.
    var shortcut: Character {
        switch self {
        case .list: return "1"
        case .columns: return "2"
        case .icons: return "3"
        }
    }
}

typealias RenameCompletion = @MainActor (String) -> Void

/// Imperative hooks into the view showing a pane (list, columns or icons): focus, selection, inline rename.
/// The view for the current mode installs them; `owner` tells which one did (two exist briefly while the
/// mode changes).
@MainActor
final class PaneViewBridge {
    weak var owner: AnyObject?
    /// The view that takes the pane's keyboard focus (the table, the icon grid, the focused column).
    var focusTarget: (() -> NSView?)?
    var selectNames: ((Set<String>, String?) -> Void)?
    var beginRename: ((String, RenameCompletion?) -> Void)?
    /// Columns: moves into the open folder's column (⌘↓ / → on the folder selected in the column before it).
    var enterOpenFolder: (() -> Void)?
    /// A transfer finished writing into a folder (columns: an earlier column may show it).
    var folderChanged: ((PaneLocation) -> Void)?
    /// The list's table (List mode only).
    weak var tableView: NSTableView?
    #if DEBUG
    /// Self-check: drives each view's drop resolution.
    weak var coordinator: FileTableCoordinator?
    weak var iconCoordinator: FileIconCoordinator?
    weak var columnCoordinator: ColumnBrowserCoordinator?
    #endif

    /// The pane's focusable view, if it is in a window.
    var view: NSView? { focusTarget?() }

    func install(owner: AnyObject) {
        self.owner = owner
        focusTarget = nil
        selectNames = nil
        beginRename = nil
        enterOpenFolder = nil
        folderChanged = nil
        tableView = nil
        #if DEBUG
        coordinator = nil
        iconCoordinator = nil
        columnCoordinator = nil
        #endif
    }

    func focus() {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}

/// One side of the window: the Mac pane (local file system) or the device pane (DeviceService).
@Observable
@MainActor
final class PaneModel {
    let kind: PaneKind
    @ObservationIgnored weak var app: AppModel? {
        didSet { if let app { Thumbnails.shared.transfers = app.transfers } }
    }

    private(set) var location: PaneLocation?
    private(set) var items: [FileItem] = []
    private(set) var allItems: [FileItem] = []
    @ObservationIgnored private(set) var index: [String: FileItem] = [:]
    /// Bumps whenever `items` changes (reload, sort, filter).
    private(set) var listingGeneration = 0
    /// Bumps whenever the folder's contents change; the other pane re-compares.
    private(set) var contentGeneration = 0
    private(set) var hasListing = false
    private(set) var isLoading = false
    private(set) var loadError: String?
    /// Free space on the Mac volume (Mac pane only).
    private(set) var availableBytes: Int64?

    var selection: Set<String> = []
    /// List, columns or icons. `AppModel.setViewMode` changes and remembers it.
    var viewMode: PaneViewMode = .list {
        didSet { if viewMode != .columns { openFolderItem = nil } }
    }
    /// Columns view: the open folder as a row of the column before it (nil at the root and in the other
    /// views). With nothing selected inside the open folder, commands act on it, like Finder.
    private(set) var openFolderItem: FileItem?
    var sortKey: SortKey = .name
    var ascending = true
    var filter = "" {
        didSet { if filter != oldValue { applySortAndFilter() } }
    }
    var showHidden = false {
        didSet { if showHidden != oldValue { reload() } }
    }

    private(set) var canGoBack = false
    private(set) var canGoForward = false
    @ObservationIgnored private var backStack: [PaneLocation] = []
    @ObservationIgnored private var forwardStack: [PaneLocation] = []
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var pendingSelection: Set<String>?
    @ObservationIgnored private var writesDuringReload: [String: FileItem] = [:]
    @ObservationIgnored let bridge = PaneViewBridge()
    @ObservationIgnored private var watcher: DirectoryWatcher?

    /// A drag the open folder accepts is over the pane (list, drop bar or path bar): show the drop bar.
    private(set) var dropBarVisible = false
    /// The drop bar or path bar segment under the pointer, when it accepts the drag.
    private(set) var dropHighlight: DropZone?
    @ObservationIgnored private var dragZones: Set<DropZone> = []
    @ObservationIgnored private var dragHide: DispatchWorkItem?
    @ObservationIgnored private var dragWatch: Timer?

    init(kind: PaneKind) {
        self.kind = kind
        if kind == .mac {
            watcher = DirectoryWatcher { [weak self] in
                guard let self, let location = self.location,
                      self.app?.transfers.isWriting(in: location) != true else { return }
                self.reload(quiet: true)
            }
        }
    }

    // MARK: Navigation

    func navigate(to location: PaneLocation, recordHistory: Bool = true, select name: String? = nil) {
        navigate(to: location, recordHistory: recordHistory, selecting: name.map { [$0] } ?? [])
    }

    /// Goes to `location` and selects `names` there once it has loaded.
    func navigate(to location: PaneLocation, recordHistory: Bool = true, selecting names: Set<String>) {
        if let current = self.location, current == location {
            if !names.isEmpty { selectAndReveal(names) }
            return
        }
        if recordHistory, let current = self.location {
            backStack.append(current)
            if backStack.count > 100 { backStack.removeFirst() }
            forwardStack.removeAll()
        }
        self.location = location
        if let id = location.device?.deviceID, app?.shownDeviceID != id { app?.shownDeviceID = id }
        updateHistoryFlags()
        pendingSelection = names.isEmpty ? nil : names
        selection = []
        openFolderItem = nil
        filter = ""
        hasListing = false
        items = []
        allItems = []
        index = [:]
        listingGeneration &+= 1
        contentGeneration &+= 1
        watcher?.watch(location.macURL)
        reload()
    }

    /// Clears the location (device gone and no other device to show).
    func clear() {
        location = nil
        openFolderItem = nil
        items = []
        allItems = []
        index = [:]
        selection = []
        hasListing = false
        loadError = nil
        backStack.removeAll()
        forwardStack.removeAll()
        updateHistoryFlags()
        listingGeneration &+= 1
        contentGeneration &+= 1
        watcher?.watch(nil)
    }

    /// The device behind this pane went away: drop the listing and anything still loading, but keep the
    /// location and history so the same folder comes back when the device does.
    func invalidateListing() {
        loadToken &+= 1
        isLoading = false
        loadError = nil
        pendingSelection = nil
        items = []
        allItems = []
        index = [:]
        selection = []
        hasListing = false
        listingGeneration &+= 1
        contentGeneration &+= 1
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        if let current = location { forwardStack.append(current) }
        let from = location
        location = nil
        navigate(to: target, recordHistory: false, select: childName(of: target, toward: from))
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        if let current = location { backStack.append(current) }
        location = nil
        navigate(to: target, recordHistory: false)
    }

    var parentLocation: PaneLocation? {
        switch location {
        case .mac(let url):
            let parent = url.deletingLastPathComponent()
            return parent.path == url.path ? nil : .mac(parent)
        case .device(let loc):
            guard !DevicePath.isRoot(loc.path) else { return nil }
            return .device(DeviceLocation(deviceID: loc.deviceID, storageID: loc.storageID, path: DevicePath.parent(loc.path)))
        case nil:
            return nil
        }
    }

    func goUp() {
        guard let parent = parentLocation, let location else { return }
        navigate(to: parent, select: childName(of: parent, toward: location))
    }

    private func childName(of parent: PaneLocation, toward child: PaneLocation?) -> String? {
        switch (parent, child) {
        case (.mac(let p), .mac(let c)?):
            let pc = p.standardizedFileURL.pathComponents, cc = c.standardizedFileURL.pathComponents
            return cc.count > pc.count && Array(cc.prefix(pc.count)) == pc ? cc[pc.count] : nil
        case (.device(let p), .device(let c)?):
            let pc = DevicePath.components(p.path), cc = DevicePath.components(c.path)
            return cc.count > pc.count && Array(cc.prefix(pc.count)) == pc ? cc[pc.count] : nil
        default:
            return nil
        }
    }

    private func updateHistoryFlags() {
        canGoBack = !backStack.isEmpty
        canGoForward = !forwardStack.isEmpty
    }

    func location(of item: FileItem) -> PaneLocation? {
        if let url = item.url { return .mac(url) }
        if let path = item.devicePath, case .device(let loc) = location {
            return .device(DeviceLocation(deviceID: loc.deviceID, storageID: loc.storageID, path: path))
        }
        return nil
    }

    /// Columns view: `item` (a row of the column before the open folder's) is the open folder.
    func setOpenFolderItem(_ item: FileItem?) {
        let valid = item.map { viewMode == .columns && isOpenFolder($0) } ?? true
        let value = valid ? item : nil
        if openFolderItem != value { openFolderItem = value }
    }

    /// Whether `item` is the folder the pane has open (only the columns view shows it as a row).
    func isOpenFolder(_ item: FileItem) -> Bool {
        guard item.isBrowsable, let location, let own = self.location(of: item) else { return false }
        return own.isSameFolder(as: location)
    }

    /// The folder `items` are in: the open folder, or its parent when they are the open folder itself.
    func folder(containing items: [FileItem]) -> PaneLocation? {
        items.contains(where: isOpenFolder) ? (parentLocation ?? location) : location
    }

    /// Where the open folder is once it is renamed to `newName`.
    func renamedOpenFolder(_ newName: String) -> PaneLocation? {
        switch parentLocation {
        case .mac(let parent)?:
            return .mac(parent.appendingPathComponent(newName, isDirectory: true))
        case .device(let parent)?:
            return .device(DeviceLocation(deviceID: parent.deviceID, storageID: parent.storageID,
                                          path: DevicePath.join(parent.path, newName)))
        case nil:
            return nil
        }
    }

    // MARK: Loading

    /// Re-lists the current folder. `quiet` keeps the current rows visible (no spinner).
    func reload(quiet: Bool = false) {
        guard let location else { return }
        loadToken &+= 1
        let token = loadToken
        writesDuringReload.removeAll()
        if !quiet { isLoading = true }
        let showHidden = self.showHidden
        let sortKey = self.sortKey
        let ascending = self.ascending
        let filter = self.filter
        Task { [weak self] in
            guard let self else { return }
            do {
                let prepared: (listed: [FileItem], index: [String: FileItem], sorted: [FileItem]?, available: Int64?)
                switch location {
                case .mac(let url):
                    prepared = try await offMain {
                        let listed = try LocalFileSystem.list(url, showHidden: showHidden)
                        let available = LocalFileSystem.availableCapacity(url)
                        let (index, sorted) = Self.prepare(listed, sortKey: sortKey, ascending: ascending, filter: filter)
                        return (listed, index, sorted, available)
                    }
                case .device(let loc):
                    guard let connection = self.app?.connection(for: loc.deviceID) else {
                        throw DeviceServiceError.disconnected
                    }
                    prepared = try await offMain {
                        let entries = try connection.list(storageID: loc.storageID, path: loc.path)
                        let listed = entries.map { FileItem.device($0, in: loc) }
                            .filter { showHidden || !$0.isHidden }
                        let (index, sorted) = Self.prepare(listed, sortKey: sortKey, ascending: ascending, filter: filter)
                        return (listed, index, sorted, nil)
                    }
                }
                guard token == self.loadToken, self.location == location else { return }
                self.availableBytes = prepared.available ?? self.availableBytes
                let matchesView = self.sortKey == sortKey && self.ascending == ascending && self.filter == filter
                if self.writesDuringReload.isEmpty {
                    self.apply(prepared.listed, prebuiltIndex: prepared.index, preSorted: matchesView ? prepared.sorted : nil)
                } else {
                    var writes = self.writesDuringReload
                    let listed = prepared.listed.map { item in
                        guard let write = writes.removeValue(forKey: item.name), !write.isDirectory else { return item }
                        return item.size == write.size ? item : write
                    }
                    self.apply(listed + writes.values)
                }
            } catch {
                guard token == self.loadToken, self.location == location else { return }
                self.isLoading = false
                self.loadError = error.localizedDescription
                if !quiet {
                    self.allItems = []
                    self.index = [:]
                    self.items = []
                    self.listingGeneration &+= 1
                    self.contentGeneration &+= 1
                }
            }
        }
    }

    func recordTransferWrite(_ target: PaneLocation, bytes: UInt64, original: FileItem?) {
        guard let location, let relative = target.relativeComponents(to: location), let name = relative.first else { return }
        let hidden = name.hasPrefix(".")
        guard showHidden || !hidden else { return }
        let directory = relative.count > 1
        let key = FileItem.compareKey(name)
        let previous = index[key]
        if directory, previous?.name == name, previous?.isDirectory == true { return }
        let child = location.appending([name])
        let item = FileItem(name: name, isDirectory: directory, size: directory ? nil : bytes,
                            modified: directory ? nil : original?.modified,
                            url: child.macURL, devicePath: child.device?.path, isHidden: hidden,
                            deviceID: child.device?.deviceID, storageID: child.device?.storageID)
        writesDuringReload[name] = item
        guard hasListing else { return }
        if previous != nil, let position = allItems.firstIndex(where: { $0.name == name }) {
            allItems[position] = item
        } else {
            allItems.append(item)
        }
        index[key] = item
        contentGeneration &+= 1

        let query = filter.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty || name.localizedCaseInsensitiveContains(query) else { return }
        if sortKey == .status {
            applySortAndFilter()
            return
        }
        if previous != nil, let position = items.firstIndex(where: { $0.name == name }) {
            items.remove(at: position)
        }
        let ordered = Self.order(by: sortKey, ascending: ascending)
        var lower = items.startIndex, upper = items.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ordered(items[middle], item) { lower = middle + 1 } else { upper = middle }
        }
        items.insert(item, at: lower)
        listingGeneration &+= 1
    }

    var comparisonGroups: [Int: [FileItem]] {
        Dictionary(grouping: items) { app?.status(for: $0, in: self).rank ?? ItemStatus.none.rank }
    }

    var currentArrivals: ArrivalInfo? {
        guard let location else { return nil }
        return app?.transfers.paneArrivals(in: location, existing: index)
    }

    private nonisolated static func prepare(_ listed: [FileItem], sortKey: SortKey, ascending: Bool,
                                            filter: String) -> ([String: FileItem], [FileItem]?) {
        var newIndex: [String: FileItem] = [:]
        newIndex.reserveCapacity(listed.count)
        for item in listed { newIndex[item.compareKey] = item }
        guard sortKey != .status else { return (newIndex, nil) }
        var filtered = listed
        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            filtered = filtered.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        return (newIndex, sorted(filtered, by: sortKey, ascending: ascending))
    }

    private func apply(_ listed: [FileItem], prebuiltIndex: [String: FileItem]? = nil, preSorted: [FileItem]? = nil) {
        isLoading = false
        loadError = nil
        hasListing = true
        allItems = listed
        if let prebuiltIndex {
            index = prebuiltIndex
        } else {
            var newIndex: [String: FileItem] = [:]
            newIndex.reserveCapacity(listed.count)
            for item in listed { newIndex[item.compareKey] = item }
            index = newIndex
        }
        contentGeneration &+= 1
        if let preSorted {
            items = preSorted
            listingGeneration &+= 1
        } else {
            applySortAndFilter()
        }
        let names = Set(allItems.map(\.name))
        if let pending = pendingSelection, !pending.isDisjoint(with: names) {
            pendingSelection = nil
            selectAndReveal(pending.intersection(names))
        } else {
            let kept = selection.intersection(names)
            if kept != selection { selection = kept }
        }
    }

    func applySortAndFilter() {
        var result = allItems
        let query = filter.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        let ranks = sortKey == .status
            ? Dictionary(result.map { ($0.name, app?.status(for: $0, in: self).rank ?? 9) }, uniquingKeysWith: { a, _ in a })
            : [:]
        items = Self.sorted(result, by: sortKey, ascending: ascending, ranks: ranks)
        listingGeneration &+= 1
    }

    /// `items` in the pane's order for `key`. Status order needs `ranks` (by name); without them it is by name.
    nonisolated static func sorted(_ items: [FileItem], by key: SortKey, ascending: Bool, ranks: [String: Int] = [:]) -> [FileItem] {
        items.sorted(by: order(by: key, ascending: ascending, ranks: ranks))
    }

    private nonisolated static func order(by key: SortKey, ascending: Bool, ranks: [String: Int] = [:]) -> (FileItem, FileItem) -> Bool {
        let sortKey = key == .status && ranks.isEmpty ? .name : key
        let byName: (FileItem, FileItem) -> Bool = { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        switch sortKey {
        case .name:
            return { a, b in
                if a.isBrowsable != b.isBrowsable { return a.isBrowsable }
                return byName(a, b)
            }
        case .kind:
            return { a, b in
                if a.kind != b.kind {
                    let order = a.kind.localizedStandardCompare(b.kind)
                    return ascending ? order == .orderedAscending : order == .orderedDescending
                }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .modified:
            return { a, b in
                let da = a.modified ?? .distantPast, db = b.modified ?? .distantPast
                if da != db { return ascending ? da < db : da > db }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .size:
            return { a, b in
                let sa = a.size ?? 0, sb = b.size ?? 0
                if a.isBrowsable != b.isBrowsable { return a.isBrowsable == !ascending }
                if sa != sb { return ascending ? sa < sb : sa > sb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .status:
            return { a, b in
                let ra = ranks[a.name] ?? 9, rb = ranks[b.name] ?? 9
                if ra != rb { return ascending ? ra < rb : ra > rb }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    func setSort(_ key: SortKey, ascending: Bool) {
        sortKey = key
        self.ascending = ascending
        applySortAndFilter()
    }

    // MARK: Selection

    var selectedItems: [FileItem] { items.filter { selection.contains($0.name) } }

    /// Items a command acts on, the same in every view. Right-clicking an unselected item selects it first,
    /// so this is the selection; in the columns view with nothing selected inside the open folder, it is
    /// the open folder (selected in the column before it).
    var targetItems: [FileItem] {
        let selected = selectedItems
        if selected.isEmpty, viewMode == .columns, let folder = openFolderItem { return [folder] }
        return selected
    }

    func selectAndReveal(_ names: Set<String>, scrollTo: String? = nil) {
        selection = names
        bridge.selectNames?(names, scrollTo ?? names.first)
    }

    func item(named name: String) -> FileItem? { index[FileItem.compareKey(name)] }

    // MARK: Drag hover

    /// The parts of a pane that take drops.
    enum DropZone: Hashable {
        case table, bar, crumb(Int)
    }

    /// A drag entered (or moves over) `zone`; `accepted` is whether `zone` takes it. The drop bar shows
    /// while the open folder takes the drag (re-checked as the list spring-loads into other folders).
    func dragEntered(_ zone: DropZone, accepted: Bool, drag: DragPayload) {
        dragHide?.cancel()
        dragHide = nil
        dragZones.insert(zone)
        dragUpdated(zone, accepted: accepted)
        let barAccepts = location.flatMap { location in app.map { !$0.dropOperation(drag, into: location, in: self).isEmpty } } ?? false
        guard barAccepts != dropBarVisible else { return }
        dropBarVisible = barAccepts
        if barAccepts {
            startDragWatch()
        } else {
            dragWatch?.invalidate()
            dragWatch = nil
        }
    }

    func dragUpdated(_ zone: DropZone, accepted: Bool) {
        guard zone != .table else { return }
        if accepted, dropHighlight != zone {
            dropHighlight = zone
        } else if !accepted, dropHighlight == zone {
            dropHighlight = nil
        }
    }

    func dragExited(_ zone: DropZone) {
        dragZones.remove(zone)
        if dropHighlight == zone { dropHighlight = nil }
        guard dragZones.isEmpty, dropBarVisible else { return }
        // The pointer may be on its way between the list, the drop bar and the path bar: wait a moment.
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dragZones.isEmpty else { return }
                self.dragEnded()
            }
        }
        dragHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// The drag ended (dropped anywhere or cancelled).
    func dragEnded() {
        dragHide?.cancel()
        dragHide = nil
        dragWatch?.invalidate()
        dragWatch = nil
        dragZones = []
        if dropHighlight != nil { dropHighlight = nil }
        if dropBarVisible { dropBarVisible = false }
    }

    /// Not every drag end reaches a destination (dropped in another app, cancelled outside the window):
    /// the bar also goes away once no mouse button is down. Runs in the event-tracking mode drags use.
    private func startDragWatch() {
        dragWatch?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, PaneModel.watchesMouseDuringDrags, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.dragEnded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragWatch = timer
    }

    /// The self-check simulates drags without a mouse button down.
    static var watchesMouseDuringDrags = true

    // MARK: Display

    var folderName: String {
        switch location {
        case .mac(let url):
            if url.path == "/" { return LocalFileSystem.volumeName(url) }
            return FileManager.default.displayName(atPath: url.path)
        case .device(let loc):
            if DevicePath.isRoot(loc.path) {
                return app?.session(for: loc.deviceID)?.storage(loc.storageID)?.description ?? "Storage"
            }
            return DevicePath.lastComponent(loc.path)
        case nil:
            return kind == .mac ? "This Mac" : "No Device"
        }
    }

    /// "Download · Galaxy S23", "Lisbon 2026 · This Mac".
    var subtitle: String {
        switch location {
        case .mac(let url):
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return "This Mac" }
            let parentName = parent.path == "/" ? LocalFileSystem.volumeName(parent) : FileManager.default.displayName(atPath: parent.path)
            return "\(parentName) · This Mac"
        case .device(let loc):
            let session = app?.session(for: loc.deviceID)
            let deviceName = session?.name ?? "Device"
            let storageName = session?.storage(loc.storageID)?.description ?? "Storage"
            if DevicePath.isRoot(loc.path) { return deviceName }
            let parent = DevicePath.parent(loc.path)
            return "\(DevicePath.isRoot(parent) ? storageName : DevicePath.lastComponent(parent)) · \(deviceName)"
        case nil:
            return ""
        }
    }

    var crumbs: [Crumb] {
        switch location {
        case .mac(let url):
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            let parts = url.standardizedFileURL.pathComponents
            let homeParts = home.pathComponents
            var crumbs: [Crumb] = []
            var start: Int
            if parts.count >= homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts {
                crumbs.append(Crumb(id: 0, title: app?.homeTitle ?? home.lastPathComponent, systemImage: "house", location: .mac(home)))
                start = homeParts.count
            } else {
                let root = URL(fileURLWithPath: "/")
                crumbs.append(Crumb(id: 0, title: LocalFileSystem.volumeName(root), systemImage: "internaldrive", location: .mac(root)))
                start = 1
            }
            var current = start == 1 ? URL(fileURLWithPath: "/") : home
            while start < parts.count {
                current.appendPathComponent(parts[start])
                crumbs.append(Crumb(id: crumbs.count, title: FileManager.default.displayName(atPath: current.path),
                                    systemImage: nil, location: .mac(current)))
                start += 1
            }
            return crumbs
        case .device(let loc):
            let session = app?.session(for: loc.deviceID)
            let rootLocation = PaneLocation.device(DeviceLocation(deviceID: loc.deviceID, storageID: loc.storageID, path: "/"))
            var crumbs = [
                Crumb(id: 0, title: session?.name ?? "Device", systemImage: "smartphone", location: rootLocation),
                Crumb(id: 1, title: session?.storage(loc.storageID)?.description ?? "Storage", systemImage: nil, location: rootLocation),
            ]
            var path = "/"
            for part in DevicePath.components(loc.path) {
                path = DevicePath.join(path, part)
                crumbs.append(Crumb(id: crumbs.count, title: part, systemImage: nil,
                                    location: .device(DeviceLocation(deviceID: loc.deviceID, storageID: loc.storageID, path: path))))
            }
            return crumbs
        case nil:
            return []
        }
    }
}
