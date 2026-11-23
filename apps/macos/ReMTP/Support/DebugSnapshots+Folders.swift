#if DEBUG
import AppKit
import SwiftUI

extension DebugSnapshots {
    /// Device folders: reopened where they were left, and pinned in the sidebar.
    static func folderChecks(app: AppModel, macPath: String?, shot: (String) -> Void) async {
        guard let demo = app.demoService else { return check("Device folders: demo backend", false) }
        let galaxy = DemoDeviceService.galaxyID, sp3000 = DemoDeviceService.sp3000ID
        let storage: UInt32 = 0x0001_0001
        func at(_ device: String, _ path: String) -> DeviceLocation { DeviceLocation(deviceID: device, storageID: storage, path: path) }
        func path() -> String? {
            guard let loc = app.devicePane.location?.device, loc.deviceID == app.shownDeviceID else { return nil }
            return loc.path
        }
        func showing(_ device: String, _ path: String) -> Bool {
            app.devicePaneBrowsable && app.devicePane.hasListing && app.devicePane.location?.device == at(device, path)
        }

        // Put back at the end: plug state, panes, selection, remembered folders.
        let wasPlugged = demo.withLock { [galaxy, sp3000].map { demo.device($0)?.plugged ?? false } }
        let previousShown = app.shownDeviceID, previousLocation = app.devicePane.location, previousKind = app.activeKind
        let previousLast = app.folders.lastFoldersSnapshot
        let previousFavorites = [galaxy, sp3000].map { app.folders.favorites(of: $0).map(\.id) }
        defer {
            for (id, plugged) in zip([galaxy, sp3000], wasPlugged) { demo.setPlugged(deviceID: id, plugged) }
        }
        for id in [galaxy, sp3000] { demo.setPlugged(deviceID: id, true) }
        let ready = await until(6) {
            for id in [galaxy, sp3000] {
                if let session = app.session(for: id), case .held = session.phase { app.release(session) }
            }
            return [galaxy, sp3000].allSatisfy { app.session(for: $0)?.isReady == true }
        }
        guard ready else { return check("Device folders: Galaxy S23 and SP3000 connect", false) }

        // 1. The last folder per device: Galaxy in DCIM › Camera, then the SP3000, then the Galaxy again.
        app.showStorage(deviceID: galaxy, storageID: storage)
        app.devicePane.navigate(to: .device(at(galaxy, "/DCIM/Camera")))
        let inCamera = await until(3) { showing(galaxy, "/DCIM/Camera") }
        app.showDevice(sp3000)
        let onSP3000 = await until(3) { app.shownDeviceID == sp3000 && app.devicePaneBrowsable && app.devicePane.hasListing }
        app.showDevice(galaxy)
        let backInCamera = await until(3) { showing(galaxy, "/DCIM/Camera") }
        check("Device folders: Galaxy reopens in DCIM › Camera after showing the SP3000 (\(path() ?? "none"))",
              inCamera && onSP3000 && backInCamera)
        // Showing the device that's already shown leaves the pane where it is.
        app.devicePane.navigate(to: .device(at(galaxy, "/DCIM")))
        _ = await until(3) { showing(galaxy, "/DCIM") }
        app.showDevice(galaxy)
        await wait(0.3)
        let stayed = showing(galaxy, "/DCIM")
        // A storage row opens that storage's last folder.
        app.devicePane.navigate(to: .device(at(galaxy, "/DCIM/Camera")))
        _ = await until(3) { showing(galaxy, "/DCIM/Camera") }
        app.showDevice(sp3000)
        _ = await until(3) { app.shownDeviceID == sp3000 && app.devicePane.hasListing }
        app.sidebarSelection = .storage(galaxy, storage)
        let storageRow = await until(3) { showing(galaxy, "/DCIM/Camera") }
        check("Device folders: showing the shown device keeps its folder; the storage row opens its last folder",
              stayed && storageRow)

        // 2. Persisted: a fresh store on the same defaults has it, also under the device's charging-only id.
        let fresh = DeviceFolders(defaults: AppDefaults.store(demo: true))
        let chargingGalaxy = "04e8:6865:\(DemoDeviceService.legacyGalaxyID)"
        check("Device folders: the last folder is saved and keyed by vendor and serial (\(fresh.lastPath(of: galaxy, storageID: storage) ?? "nil"))",
              fresh.lastPath(of: galaxy, storageID: storage) == "/DCIM/Camera" && fresh.lastStorage(of: galaxy) == storage
                && fresh.lastPath(of: chargingGalaxy, storageID: storage) == "/DCIM/Camera"
                && USBDeviceIdentity.folderKey(for: galaxy) == USBDeviceIdentity.folderKey(for: chargingGalaxy))

        // 3. The folder is gone: the nearest folder above it that exists.
        let gone = "/DCIM/Camera/Folder check", inner = "/DCIM/Camera/Folder check/Inner"
        if let connection = app.connection(for: galaxy) {
            try? await offMain { try connection.createFolder(storageID: storage, path: inner) }
        }
        app.devicePane.navigate(to: .device(at(galaxy, inner)))
        let inInner = await until(3) { showing(galaxy, inner) }
        app.showDevice(sp3000)
        _ = await until(3) { app.shownDeviceID == sp3000 && app.devicePane.hasListing }
        if let connection = app.connection(for: galaxy) {
            try? await offMain { try connection.delete(storageID: storage, path: gone) }
        }
        app.showDevice(galaxy)
        let fellBack = await until(4) { showing(galaxy, "/DCIM/Camera") && app.devicePane.loadError == nil }
        check("Device folders: a remembered folder that's gone falls back to the nearest parent (\(path() ?? "none"))",
              inInner && fellBack && app.folders.lastPath(of: galaxy, storageID: storage) == "/DCIM/Camera")
        // With nothing left above it, the storage root.
        app.devicePane.navigate(to: .device(at(galaxy, "/No such folder/Deeper")), fallBackToParent: true)
        let toRoot = await until(4) { showing(galaxy, "/") && app.devicePane.loadError == nil }
        check("Device folders: … and to the storage root when no parent is left (\(path() ?? "none"))", toRoot)

        // 4. Pinning from the device pane's context menu.
        for id in [galaxy, sp3000] {
            for favorite in app.folders.favorites(of: id) { app.folders.unpin(favorite.id, of: id) }
        }
        let outline = folderWindow.flatMap { firstOutline(in: $0.contentView?.superview) }
        let rowsBefore = outline?.numberOfRows ?? -1
        app.devicePane.navigate(to: .device(at(galaxy, "/DCIM")))
        _ = await until(3) { showing(galaxy, "/DCIM") && app.devicePane.item(named: "Camera") != nil }
        app.activate(.device)
        app.devicePane.selectAndReveal(["Camera"])
        let menu = PaneContextMenu(pane: app.devicePane, app: app)
        menu.menuNeedsUpdate(menu.menu)
        let addItem = menu.menu.items.first { $0.title == "Add to Sidebar" }
        let fileMenu = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
        let fileAdd = fileMenu?.items.first { $0.title == "Add to Sidebar" }
        let fileRemove = fileMenu?.items.first { $0.title == "Remove from Sidebar" }
        if let addItem, let action = addItem.action { NSApp.sendAction(action, to: addItem.target, from: addItem) }
        let pinned = app.folders.favorites(of: galaxy)
        let camera = pinned.first { $0.path == "/DCIM/Camera" }
        let rowShown = await until(2) { (outline?.numberOfRows ?? -2) == rowsBefore + 1 }
        check("Device folders: Add to Sidebar (context menu and File ⌃⌘T) pins DCIM › Camera under the Galaxy "
              + "(\(rowsBefore) → \(outline?.numberOfRows ?? -1) sidebar rows)",
              addItem?.isEnabled == true && fileAdd?.keyEquivalent == "t" && fileAdd?.keyEquivalentModifierMask == [.command, .control]
                && fileRemove != nil && pinned.count == 1 && camera != nil && rowShown
                && app.sidebarFavorites(underRow: galaxy).map(\.id) == pinned.map(\.id)
                && camera.map { app.place(of: $0, onDevice: galaxy) } == "Internal › DCIM › Camera")

        // Clicking it opens the folder; the row is the selection while the folder is open.
        if let camera {
            app.showDevice(sp3000)
            _ = await until(3) { app.shownDeviceID == sp3000 && app.devicePane.hasListing }
            app.sidebarSelection = .favorite(galaxy, camera.id)
            let opened = await until(3) { showing(galaxy, "/DCIM/Camera") }
            check("Device folders: clicking the favourite shows the Galaxy in DCIM › Camera, selected in the sidebar",
                  opened && app.sidebarSelection == .favorite(galaxy, camera.id) && app.activeKind == .device)
        }

        // 5. No duplicates, by menu, drop or another spelling; drops only pin folders of the device they're on.
        app.devicePane.navigate(to: .device(at(galaxy, "/DCIM")))
        _ = await until(3) { showing(galaxy, "/DCIM") && app.devicePane.item(named: "Camera") != nil }
        app.activate(.device)
        app.devicePane.selectAndReveal(["Camera"])
        menu.menuNeedsUpdate(menu.menu)
        let addAgain = menu.menu.items.first { $0.title == "Add to Sidebar" }
        let canAddAgain = app.canAddToSidebar
        app.addToSidebar()
        let respelled = app.pin([at(galaxy, "DCIM/Camera/")])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.cro13.ReMTP.selfcheck-pin"))
        func drag(_ items: [DeviceDragItem]) -> DragPayload {
            pasteboard.clearContents()
            pasteboard.writeObjects(items.map { item in
                let entry = NSPasteboardItem()
                entry.setData((try? JSONEncoder().encode(item)) ?? Data(), forType: DeviceDragItem.pasteboardType)
                return entry
            })
            return DragPayload.read(pasteboard, source: .device, allowsMove: true)
        }
        func folder(_ device: String, _ path: String) -> DeviceDragItem {
            DeviceDragItem(deviceID: device, storageID: storage, path: path, name: DevicePath.lastComponent(path), isDir: true, size: 0)
        }
        let cameraDrag = drag([folder(galaxy, "/DCIM/Camera")])
        let droppedAgain = app.pinDropped(cameraDrag, onDevice: galaxy)
        let lisbon = drag([folder(galaxy, "/Download/Lisbon 2026"),
                           DeviceDragItem(deviceID: galaxy, storageID: storage, path: "/Download/Boarding pass.pdf",
                                          name: "Boarding pass.pdf", isDir: false, size: 1)])
        let wrongDevice = app.foldersToPin(lisbon, onDevice: sp3000)
        let dropped = app.pinDropped(lisbon, onDevice: galaxy)
        let titles = app.folders.favorites(of: galaxy).map(\.title)
        check("Device folders: no duplicates; a dropped folder pins under its own device only (\(titles))",
              // A disabled context-menu item has no action; `isEnabled` only follows once AppKit validates the
              // menu for display.
              addAgain != nil && addAgain?.action == nil && !canAddAgain && respelled == 0 && !droppedAgain && wrongDevice.isEmpty
                && dropped && titles == ["Camera", "Lisbon 2026"])

        // Screenshots: the sidebar with favourites, then with the Galaxy unplugged.
        app.sidebarSelection = .storage(galaxy, storage)
        app.devicePane.navigate(to: .device(at(galaxy, "/DCIM/Camera")))
        _ = await until(3) { showing(galaxy, "/DCIM/Camera") }
        await wait(0.5)
        await captureAppearances("13-folders-sidebar", shot: shot)
        let frames = SidebarFrames.frames
        let storageIcon = frames["storage-icon:Internal"], storageTitle = frames["storage-title:Internal"]
        let aligned = ["Camera", "Lisbon 2026"].allSatisfy { name in
            guard let icon = frames["favorite-icon:\(name)"], let title = frames["favorite-title:\(name)"],
                  let storageIcon, let storageTitle, let outline, let window = outline.window else { return false }
            // Not clipped: the title's full width fits inside the sidebar.
            let sidebar = outline.convert(outline.visibleRect, to: nil)
            let sidebarWidth = sidebar.width
            return abs(icon.minX - storageIcon.minX) < 1 && abs(title.minX - storageTitle.minX) < 1
                && title.maxX <= sidebarWidth && title.width > 8 && window.contentView != nil
        }
        check("Device folders: favourite rows line up with the storage rows and their titles fit "
              + "(\(frames.filter { $0.key.hasPrefix("favorite") || $0.key.hasPrefix("storage") }.sorted { $0.key < $1.key }.map { "\($0.key) \(Int($0.value.minX))–\(Int($0.value.maxX))" }))",
              aligned)

        // 6. Unplugged: the favourites stay under the dimmed device; one opens the not-connected pane, and the
        // folder once the device is back.
        demo.setPlugged(deviceID: galaxy, false)
        let unplugged = await until(3) { app.session(for: galaxy) == nil && app.disconnectedDevices.contains { $0.id == galaxy } }
        if let camera {
            app.sidebarSelection = .favorite(galaxy, camera.id)
            await wait(0.3)
            let notConnected = app.shownDeviceID == galaxy && !app.devicePaneBrowsable && app.windowSubtitle == "Not connected"
            await captureAppearances("13-folders-unplugged", shot: shot)
            check("Device folders: while the Galaxy is unplugged its favourites are shown dimmed and open its not-connected pane",
                  unplugged && app.sidebarFavorites(underRow: galaxy).count == 2 && notConnected)
            demo.setPlugged(deviceID: galaxy, true)
            let reopened = await until(6) { showing(galaxy, "/DCIM/Camera") }
            check("Device folders: plugged back in, the Galaxy opens the favourite that was clicked", reopened)
        }

        // 7. Remove from Sidebar: the row's context menu and the File menu.
        if let camera { app.removeFavorite(camera, onDevice: galaxy) }
        app.devicePane.navigate(to: .device(at(galaxy, "/Download")))
        _ = await until(3) { showing(galaxy, "/Download") && app.devicePane.item(named: "Lisbon 2026") != nil }
        app.activate(.device)
        app.devicePane.selectAndReveal(["Lisbon 2026"])
        let canRemove = app.canRemoveFromSidebar
        app.removeFromSidebar()
        let removed = await until(2) { (outline?.numberOfRows ?? -2) == rowsBefore }
        check("Device folders: Remove from Sidebar takes the rows away",
              canRemove && app.folders.favorites(of: galaxy).isEmpty && removed
                && DeviceFolders(defaults: AppDefaults.store(demo: true)).favorites(of: galaxy).isEmpty)

        // 8. The real app's defaults never see any of it.
        let demoDefaults = AppDefaults.store(demo: true)
        check("Device folders are kept in \(AppDefaults.demoSuiteName); the app’s own defaults are unchanged",
              DeviceFolders.standardSnapshot() == DeviceFolders.standardAtLaunch
                && demoDefaults.data(forKey: DeviceFolders.lastKey) != nil)

        // Put back what this changed.
        for (id, ids) in zip([galaxy, sp3000], previousFavorites) {
            for favorite in app.folders.favorites(of: id) where !ids.contains(favorite.id) { app.folders.unpin(favorite.id, of: id) }
        }
        if let previousLocation, let loc = previousLocation.device, app.session(for: loc.deviceID)?.isReady == true {
            app.devicePane.navigate(to: previousLocation, recordHistory: false)
            _ = await until(3) { app.devicePane.hasListing }
        }
        if let previousShown { app.shownDeviceID = previousShown }
        app.activate(previousKind)
        app.folders.restoreLastFolders(previousLast)
    }

    private static var folderWindow: NSWindow? { NSApp.windows.first { $0.frame.width > 600 } }

    private static func firstOutline(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        for child in view.subviews { if let found = firstOutline(in: child) { return found } }
        return nil
    }
}
#endif
