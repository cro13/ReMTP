#if DEBUG
import AppKit
import SwiftUI

extension DebugSnapshots {
    /// Menu bar: Copy the Remaining and Show Needs Attention in the Transfer menu, the Help menu, its report
    /// links and the Device Troubleshooting window. Stops a copy of its own (in a folder of its own) to have
    /// something to continue, then removes its jobs and files and plugs Galaxy S23 back as it found it.
    static func menuChecks(app: AppModel, macPath: String?, shot: (String) -> Void) async {
        helpMenuChecks(app: app)
        await reportLinkChecks(app: app)
        await transferMenuChecks(app: app, macPath: macPath, shot: shot)
        await troubleshootingChecks(app: app, shot: shot)
    }

    // MARK: Menus

    private static func mainMenu(_ title: String) -> NSMenu? {
        NSApp.mainMenu?.items.first { $0.title == title }?.submenu
    }

    private static func menuItem(_ menu: String, _ matches: (String) -> Bool) -> (menu: NSMenu, index: Int)? {
        guard let submenu = mainMenu(menu), let index = submenu.items.firstIndex(where: { matches($0.title) }) else {
            return nil
        }
        return (submenu, index)
    }

    private static func copyRemainingItem() -> (menu: NSMenu, index: Int)? {
        menuItem("Transfer") { $0.hasPrefix("Copy the Remaining") || $0 == "Copy Remaining Files" }
    }

    /// Brings a main menu up to date the way opening it does: SwiftUI rebuilds its items in
    /// `menuNeedsUpdate`, then AppKit validates them.
    private static func refresh(_ title: String) async {
        await wait(0.3)
        guard let menu = mainMenu(title) else { return }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
    }

    /// The item's title and enabled state, with the menu up to date.
    private static func itemState(_ menu: String, _ find: () -> (menu: NSMenu, index: Int)?) async -> (title: String, enabled: Bool)? {
        await refresh(menu)
        guard let found = find() else { return nil }
        let item = found.menu.items[found.index]
        return (item.title, item.isEnabled)
    }

    /// Chooses the item as a click would, with the menu up to date.
    private static func choose(_ menu: String, _ find: () -> (menu: NSMenu, index: Int)?) async -> Bool {
        await refresh(menu)
        guard let found = find(), found.menu.items[found.index].isEnabled else { return false }
        found.menu.performActionForItem(at: found.index)
        return true
    }

    private static func needsAttentionItem() -> (menu: NSMenu, index: Int)? {
        menuItem("Transfer") { $0 == "Show Needs Attention" }
    }

    private static func helpMenuChecks(app: AppModel) {
        let titles = mainMenu("Help")?.items.map(\.title) ?? []
        let expected = ["ReMTP Help", "Device Troubleshooting", "Report a Device Problem…", "Report a Bug…"]
        check("Help menu: \(expected.joined(separator: ", ")) (\(titles.filter { !$0.isEmpty }))",
              expected.allSatisfy(titles.contains))
        let helpItem = mainMenu("Help")?.items.first { $0.title == "ReMTP Help" }
        check("ReMTP Help has ⌘? and opens the README (\(HelpLinks.readme.absoluteString))",
              helpItem?.keyEquivalent == "?" && helpItem?.keyEquivalentModifierMask.contains(.command) == true
              && HelpLinks.readme.absoluteString == "https://github.com/cro13/ReMTP#readme")
        let item = copyRemainingItem().map { $0.menu.items[$0.index] }
        check("Transfer › Copy the Remaining has ⌥⌘R and Show Needs Attention is next to it",
              item?.keyEquivalent == "r" && item?.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control])
                == [.command, .option]
              && menuItem("Transfer", { $0 == "Show Needs Attention" }) != nil)
    }

    // MARK: Report links

    private static func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    private static func reportLinkChecks(app: AppModel) async {
        let system = HelpLinks.System.current
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "-") (\(info["CFBundleVersion"] as? String ?? "-"))"
        check("Reports carry the app version \(version) and \(system.mac)",
              system.appVersion == version && system.macOS.hasPrefix("macOS 1") && system.mac.contains(system.macOS))

        // No device shown: only the versions.
        let bare = query(HelpLinks.reportURL(.device, device: nil, system: system))
        let bareBug = query(HelpLinks.reportURL(.bug, device: nil, system: system))
        check("With no device, a report prefills only the app and macOS versions (\(bare.keys.sorted()), \(bareBug.keys.sorted()))",
              Set(bare.keys) == ["template", "mac", "notes"] && bare["notes"] == "ReMTP \(version)"
              && Set(bareBug.keys) == ["template", "version", "mac"] && bareBug["version"] == version)

        // "&" and spaces in a value stay inside it.
        let ampersand = HelpLinks.DeviceFacts(vendor: "Astell&Kern", model: "SP3000", connection: "USB 2.0 · MTP")
        let ampersandURL = HelpLinks.reportURL(.bug, device: ampersand, system: system)
        check("Report values are percent-encoded (\(ampersandURL.absoluteString.count) characters)",
              query(ampersandURL)["device"] == "Astell&Kern SP3000 · USB 2.0 · MTP"
              && ampersandURL.absoluteString.contains("Astell%26Kern%20SP3000") && ampersandURL.absoluteString.count < 500)

        // The shown device, under a name of the user's own.
        let galaxy = DemoDeviceService.galaxyID
        guard let demo = app.demoService else { return check("Report links need the demo backend", false) }
        let wasPlugged = demo.demoDevices.first { $0.id == galaxy }?.plugged ?? false
        demo.setPlugged(deviceID: galaxy, true)
        _ = await until(4) { app.session(for: galaxy) != nil }
        if let session = app.session(for: galaxy), session.isSystemHold { app.release(session) }
        let ready = await until(4) { app.session(for: galaxy)?.isReady == true && app.session(for: galaxy)?.details != nil }
        let previousShown = app.shownDeviceID
        let previousCustom = app.known.customName(galaxy)
        let privateName = "Menu Check Private Name"
        app.renameDevice(galaxy, to: privateName)
        app.showDevice(galaxy)
        _ = await until(2) { app.devicePane.hasListing }
        let session = app.session(for: galaxy)
        let facts = app.reportedDevice
        let deviceURL = HelpLinks.reportURL(.device, device: facts, system: system)
        let bugURL = HelpLinks.reportURL(.bug, device: facts, system: system)
        let fields = query(deviceURL), bugFields = query(bugURL)
        let decoded = [deviceURL, bugURL].map { $0.absoluteString.removingPercentEncoding ?? $0.absoluteString }
        let fileNames = app.devicePane.items.map(\.name) + app.macPane.items.map(\.name)
        let leaks = [privateName, "Galaxy S23", "/Download", NSHomeDirectory()] + fileNames
        let leaked = leaks.filter { leak in decoded.contains { $0.contains(leak) } }
        let connection = facts?.connection ?? "none"
        check("Report a Device Problem… prefills the shown device: \(facts?.label ?? "none"), \(connection)",
              ready && app.displayName(forDevice: galaxy) == privateName
              && fields["template"] == "device_report.yml" && fields["device"] == "Samsung SM-S911B"
              && fields["title"] == "Samsung SM-S911B" && fields["mac"] == system.mac
              && fields["notes"] == "ReMTP \(version)\nConnection: USB 3 · MTP"
              && session.map { $0.subtitle == "Samsung · \(connection)" } == true)
        check("Report a Bug… prefills version, Mac and device (\(bugFields["device"] ?? "none"))",
              bugFields["template"] == "bug_report.yml" && bugFields["version"] == version && bugFields["mac"] == system.mac
              && bugFields["device"] == "Samsung SM-S911B · USB 3 · MTP")
        check("Reports leave out the custom name, the device’s own name, file names and paths (leaked: \(leaked))",
              leaked.isEmpty && !fileNames.isEmpty && deviceURL.absoluteString.count < 500 && bugURL.absoluteString.count < 500)

        // Charging only, when the Pixel is in that mode.
        let charging = DemoDeviceService.pixelChargingID
        let pixel = demo.demoDevices.first { $0.id == charging || $0.id == DemoDeviceService.pixelID }
        if pixel?.id == charging {
            demo.setPlugged(deviceID: charging, true)
            if await until(3, { app.adbOnlyDevices.contains { $0.id == charging } }) {
                app.sidebarSelection = .adbOnly(charging)
                await wait(0.2)
                let chargingFacts = app.reportedDevice
                check("A charging-only device reports “Charging only” (\(chargingFacts?.label ?? "none"))",
                      chargingFacts == HelpLinks.DeviceFacts(vendor: "Google", model: "Pixel 8", connection: "Charging only"))
            } else {
                check("A charging-only device reports “Charging only” (Pixel 8 didn’t appear)", false)
            }
            if pixel?.plugged == false { demo.setPlugged(deviceID: charging, false) }
        }

        app.renameDevice(galaxy, to: previousCustom ?? "")
        if let previousShown, app.session(for: previousShown) != nil { app.showDevice(previousShown) }
        if !wasPlugged { demo.setPlugged(deviceID: galaxy, false) }
        await wait(0.3)
    }

    // MARK: Transfer menu

    private static func transferMenuChecks(app: AppModel, macPath: String?, shot: (String) -> Void) async {
        guard let macPath, let demo = app.demoService else {
            return check("Transfer menu checks need the demo backend and a Mac folder", false)
        }
        let galaxy = DemoDeviceService.galaxyID
        let storage: UInt32 = 0x0001_0001
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: macPath).appendingPathComponent("Menu check")
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let previousMac = app.macPane.location
        let wasPlugged = demo.demoDevices.first { $0.id == galaxy }?.plugged ?? false
        let jobsBefore = Set(app.transfers.jobs.map(\.id))

        demo.setPlugged(deviceID: galaxy, true)
        _ = await until(4) { app.session(for: galaxy) != nil }
        if let session = app.session(for: galaxy), session.isSystemHold { app.release(session) }
        let ready = await until(4) { app.session(for: galaxy)?.isReady == true }

        // Nothing stopped yet.
        let idle = await itemState("Transfer", copyRemainingItem)
        let attentionIdle = await itemState("Transfer", needsAttentionItem)
        let nothingStopped = app.transfers.stoppedCopies.isEmpty
        check("With nothing to continue, Transfer › “Copy the Remaining” is disabled (\(idle.map { "\($0.title), \($0.enabled)" } ?? "missing"))",
              nothingStopped && idle?.title == "Copy the Remaining" && idle?.enabled == false
              && attentionIdle?.enabled == (app.transfers.attentionCount > 0))

        // A copy the cable stops: a small file lands, the large one doesn't.
        let ticket = "Train tickets Porto.pdf", backup = "whatsapp-backup.crypt14"
        let backupPath = DevicePath.join("/Download", backup)
        let originalSize = demo.withLock {
            let node = demo.device(galaxy)?.storage(storage)?.node(at: backupPath)
            let previous = node?.size
            node?.size = 640_000_000
            return previous
        }
        defer {
            if let originalSize {
                demo.withLock { demo.device(galaxy)?.storage(storage)?.node(at: backupPath)?.size = originalSize }
            }
        }
        app.showStorage(deviceID: galaxy, storageID: storage)
        app.devicePane.navigate(to: .device(DeviceLocation(deviceID: galaxy, storageID: storage, path: "/Download")))
        _ = await until(2) { app.devicePane.hasListing }
        app.showMacFolder(folder)
        _ = await until(2) { app.macPane.hasListing }
        let drags = [(ticket, UInt64(310_000)), (backup, UInt64(640_000_000))].map { name, size in
            DeviceDragItem(deviceID: galaxy, storageID: storage, path: DevicePath.join("/Download", name),
                           name: name, isDir: false, size: size)
        }
        let dropped = ready && app.dropDeviceItems(drags, onto: app.macPane, into: nil)
        let jobID = app.transfers.jobs.last?.id
        func job() -> QueuedTransfer? { jobID.flatMap(app.transfers.job) }
        let running = await until(3) { job()?.progress?.currentName == backup && (job()?.progress?.currentBytesDone ?? 0) > 0 }
        demo.setPlugged(deviceID: galaxy, false)
        let stopped = await until(3) { job()?.isActive == false && app.session(for: galaxy) == nil }
        let disconnected = app.transfers.stoppedCopies.contains { $0.id == jobID }
        let offline = await itemState("Transfer", copyRemainingItem)
        check("Transfer › \(offline?.title ?? "Copy the Remaining") names the stopped copy and waits for the device (enabled: \(offline?.enabled ?? true))",
              dropped && running && stopped && disconnected && offline?.title == "Copy the Remaining 1" && offline?.enabled == false)

        // Show Needs Attention opens the drawer there.
        let attentionState = await itemState("Transfer", needsAttentionItem)
        app.showTransfers(false)
        app.transfers.drawerTab = .inProgress
        let chose = await choose("Transfer", needsAttentionItem)
        let opened = await until(2) { app.transfers.drawerExpanded && app.transfers.drawerTab == .attention }
        check("Transfer › Show Needs Attention is enabled and opens Transfers on Needs Attention",
              attentionState?.enabled == true && chose && opened)
        await wait(0.3)
        shot("16-menu-needs-attention")
        app.showTransfers(false)

        // Reconnected: the menu item continues it.
        demo.setPlugged(deviceID: galaxy, true)
        let readyAgain = await until(4) { app.session(for: galaxy)?.isReady == true }
        let online = await itemState("Transfer", copyRemainingItem)
        check("After reconnecting, Transfer › \(online?.title ?? "Copy the Remaining") is enabled",
              readyAgain && online?.title == "Copy the Remaining 1" && online?.enabled == true
              && job().map(app.canCopyRemaining) == true)
        let choseCopy = await choose("Transfer", copyRemainingItem)
        func continuation() -> QueuedTransfer? {
            app.transfers.jobs.first { $0.copyID == jobID && $0.id != jobID }
        }
        let continued = await until(3) { continuation() != nil }
        check("Choosing it starts Copy the Remaining for that copy",
              choseCopy && continued && continuation()?.isContinuation == true && !app.transfers.stoppedCopies.contains { $0.copyID == jobID })
        let finished = await until(30) { continuation()?.isActive == false }
        let backupSize = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(backup).path)[.size] as? NSNumber)?.uint64Value
        check("…and it copies the file that was left (\(String(describing: continuation()?.state)))",
              finished && continuation()?.state == .finished && backupSize == 640_000_000)

        // Put everything back: the jobs, the folder, the panes and the device.
        let added = Set(app.transfers.jobs.map(\.id)).subtracting(jobsBefore)
        app.transfers.removeForSelfCheck(added)
        await wait(0.3)
        let cleared = await itemState("Transfer", copyRemainingItem)
        check("Once the copy is gone, Transfer › Copy the Remaining is disabled again (\(cleared?.title ?? "missing"))",
              app.transfers.stoppedCopies.isEmpty == nothingStopped && cleared?.title == "Copy the Remaining"
              && cleared?.enabled == false)
        if let previousMac { app.macPane.navigate(to: previousMac) }
        try? fm.removeItem(at: folder)
        if !wasPlugged { demo.setPlugged(deviceID: galaxy, false) }
        await wait(0.5)
    }

    // MARK: Troubleshooting window

    private static func troubleshootingChecks(app: AppModel, shot: (String) -> Void) async {
        func window() -> NSWindow? { NSApp.windows.first { $0.title == "Device Troubleshooting" && $0.isVisible } }
        guard let found = menuItem("Help", { $0 == "Device Troubleshooting" }) else {
            return check("Help › Device Troubleshooting exists", false)
        }
        found.menu.performActionForItem(at: found.index)
        let opened = await until(3) { window() != nil }
        guard opened, let window = window() else { return check("Help › Device Troubleshooting opens its window", false) }
        await wait(0.5)
        // SwiftUI's ScrollView doesn't list its text as accessibility children of the window's views, so the
        // page is checked through what it lays out (the scrolled content's height) and the topics it shows.
        let size = window.frame.size
        let content = scrollView(in: window.contentView)?.documentView?.frame.height ?? 0
        let topics = TroubleshootingTopic.all
        let wording = topics.flatMap { [$0.intro, $0.note].compactMap { $0 } + $0.steps }.joined(separator: " ")
        check("Help › Device Troubleshooting opens a \(Int(size.width))×\(Int(size.height)) window whose page scrolls (\(Int(content)) pt of content)",
              abs(size.width - 580) < 2 && abs(size.height - 680) < 2 && content > size.height * 1.5)
        check("Troubleshooting covers the six symptoms in the app’s wording (\(topics.map(\.symptom)))",
              topics.map(\.symptom) == ["The device doesn’t appear", "It says “Charging only”", "macOS is holding the device",
                                       "Copies are slow", "A copy stopped when the cable came out", "Dates look wrong on the device"]
              && wording.contains("Its photo-import service took the USB connection when you plugged in. ReMTP can pause it while the device is connected, and turns it back on when you unplug or quit.")
              && wording.contains("Developer options → Default USB configuration → File transfer")
              && wording.contains("“Charging this device via USB” notification and choose **File transfer**")
              && wording.contains("Switch to File Transfer needs USB debugging")
              && wording.contains("35–42 MB/s") && wording.contains("**Transfers › Needs Attention**"))
        await captureAppearances("16-troubleshooting", shot: shot)
        if let scroll = scrollView(in: window.contentView), let document = scroll.documentView {
            document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : 0))
            await wait(0.3)
            await captureAppearances("16-troubleshooting-end", shot: shot)
        }
        window.performClose(nil)
        let closed = await until(2) { self.window(titled: "Device Troubleshooting") == nil }
        check("The troubleshooting window closes", closed)
        if !closed { window.close() }
        NSApp.windows.first { $0.frame.width > 600 }?.makeKeyAndOrderFront(nil)
        await wait(0.3)
    }

    private static func window(titled title: String) -> NSWindow? {
        NSApp.windows.first { $0.title == title && $0.isVisible }
    }

    private static func scrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

}
#endif
