#if DEBUG
import AppKit
import SwiftUI

extension DebugSnapshots {
    /// Frames this file measures (window coordinates, like `layoutFrames`), keyed by name: "speedGraph" and
    /// "speedFacts" in the drawer, "footer.<pane>.<row>" for the comparison footer's status counts (PaneFooter).
    static var polishFrames: [String: CGRect] = [:]

    /// Toast fallback, narrow footers, stopped-bar sliver, one-file drawer.
    static func polishChecks(app: AppModel, macPath: String?, shot: (String) -> Void) async {
        gaugeChecks()
        guard let macPath, let demo = app.demoService, let window = NSApp.windows.first(where: { $0.frame.width > 600 }) else {
            return check("Polish checks need REMTP_SNAPSHOT_MAC_PATH, the demo backend and the main window", false)
        }
        let galaxy = DemoDeviceService.galaxyID, sp3000 = DemoDeviceService.sp3000ID
        let wasPlugged = demo.withLock {
            [galaxy, sp3000, DemoDeviceService.pixelID].map { demo.device($0)?.plugged ?? false }
        }
        let previousMac = app.macPane.location
        let previousDevice = app.shownDeviceID
        let previousFrame = window.frame
        let fixture = URL(fileURLWithPath: macPath, isDirectory: true).appendingPathComponent("Polish checks", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer {
            window.setFrame(previousFrame, display: true)
            app.inspectorVisible = false
            if let previousMac { app.macPane.navigate(to: previousMac) }
            if let previousDevice { app.showDevice(previousDevice) }
            try? FileManager.default.removeItem(at: fixture)
            for (id, plugged) in zip([galaxy, sp3000, DemoDeviceService.pixelChargingID], wasPlugged) {
                demo.setPlugged(deviceID: id, plugged)
            }
        }
        demo.setPlugged(deviceID: galaxy, true)
        demo.setPlugged(deviceID: sp3000, true)
        _ = await until(4) { app.session(for: galaxy)?.isReady == true && app.session(for: sp3000)?.isReady == true }

        await toastChecks(app: app, demo: demo, fixture: fixture, shot: shot)
        await footerChecks(app: app, window: window, fixture: fixture, shot: shot)
        await drawerChecks(app: app, demo: demo, fixture: fixture, shot: shot)
    }

    // MARK: Gauge

    /// Anything above zero shows at least a dot the bar's height wide; zero stays empty.
    private static func gaugeChecks() {
        let stopped = Double(310_000) / Double(2_400_000_000)
        let sliver = BarGauge.segmentWidths(0, stopped, width: 260, minimum: 6)
        let empty = BarGauge.segmentWidths(0, 0, width: 260, minimum: 6)
        let half = BarGauge.segmentWidths(0, 0.5, width: 260, minimum: 6)
        let full = BarGauge.segmentWidths(0.999, stopped, width: 260, minimum: 6)
        let narrow = BarGauge.segmentWidths(0, stopped, width: 4, minimum: 6)
        check("Bar gauge: 310 KB of 2.4 GB draws a \(sliver.second) pt sliver; 0 stays empty; half is half; "
              + "two segments never overflow (\(full)); a 4 pt track caps the sliver (\(narrow))",
              sliver == (0, 6) && empty == (0, 0) && half == (0, 130) && full.first + full.second <= 260
                && full.second == 6 && narrow == (0, 4))
    }

    // MARK: Toast

    private static func toastChecks(app: AppModel, demo: DemoDeviceService, fixture: URL, shot: (String) -> Void) async {
        let sp3000 = DemoDeviceService.sp3000ID, charging = DemoDeviceService.pixelChargingID
        let storage: UInt32 = 0x0001_0001
        let destination = PaneLocation.device(DeviceLocation(deviceID: sp3000, storageID: storage, path: "/Music"))
        guard let connection = app.connection(for: sp3000) else { return check("Toast fallback: SP3000 is ready", false) }
        app.transfers.drawerExpanded = false
        app.showMacFolder(fixture)

        /// Copies a small file to the SP3000 while it is shown (a Mac pane copy goes to the shown device),
        /// then, before the copy reports back, `away` points the device pane somewhere else.
        func copyOne(_ name: String, then away: () -> Void) async -> Bool {
            try? Data(repeating: 7, count: 48_000).write(to: fixture.appendingPathComponent(name))
            app.macPane.reload(quiet: true)
            app.showStorage(deviceID: sp3000, storageID: storage)
            guard await until(3, { app.macPane.item(named: name) != nil && app.shownSession?.id == sp3000 && app.devicePaneBrowsable }),
                  let item = app.macPane.item(named: name) else { return false }
            let previous = app.transfers.jobs.last?.id
            app.copy([item], from: app.macPane, into: destination)
            away()
            let finished = await until(4) {
                guard let job = app.transfers.jobs.last, job.id != previous else { return false }
                return job.finishedAt != nil && job.filesCopied == 1
            }
            _ = await until(1) { layoutFrames[.toast] != nil }
            await wait(0.4)
            return finished
        }
        func toastOverDevicePane() -> Bool {
            guard let pane = layoutFrames[.pane(.device)], let toast = layoutFrames[.toast] else { return false }
            let area = CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: pane.height - PaneFooter.height)
            return area.contains(toast) && abs(toast.midX - pane.midX) < 1
        }
        let idle = app.transfers.activeJobs.isEmpty && app.transfers.issues.isEmpty

        // The critique's case: copying to the SP3000, the user switches the device pane to the Pixel (charging only).
        demo.setPlugged(deviceID: charging, true)
        let chargingShown = await until(3) { app.adbOnlyDevices.contains { $0.id == charging } }
        let first = await copyOne("Polish toast 1.png") { app.sidebarSelection = .adbOnly(charging) }
        check("Toast lands over the device pane when it shows another device (Pixel 8, charging only), not on the divider "
              + "(toast \(layoutFrames[.toast].map { "\($0)" } ?? "none"), pane \(layoutFrames[.pane(.device)].map { "\($0)" } ?? "none"))",
              idle && chargingShown && first && !app.devicePaneBrowsable && app.shownADBOnlyDevice?.id == charging
                && toastOverDevicePane())
        await captureAppearances("17-polish-toast-fallback-charging", shot: shot)

        // Swapped, then the Galaxy opened on the left: still the device side.
        app.swapPanes()
        await wait(0.3)
        let second = await copyOne("Polish toast 2.png") {
            app.showStorage(deviceID: DemoDeviceService.galaxyID, storageID: storage)
        }
        check("Swapped, with the Galaxy open: the SP3000 toast still sits over the device pane",
              second && app.shownDeviceID == DemoDeviceService.galaxyID && toastOverDevicePane()
                && (layoutFrames[.pane(.device)]?.minX ?? 1) < (layoutFrames[.pane(.mac)]?.minX ?? 0))
        await captureAppearances("17-polish-toast-fallback-swapped", shot: shot)
        app.swapPanes()

        try? connection.delete(storageID: storage, path: "/Music/Polish toast 1.png")
        try? connection.delete(storageID: storage, path: "/Music/Polish toast 2.png")
        for name in ["Polish toast 1.png", "Polish toast 2.png"] {
            try? FileManager.default.removeItem(at: fixture.appendingPathComponent(name))
        }
        demo.setPlugged(deviceID: charging, false)
        await wait(4)   // let the toast go
    }

    // MARK: Footer

    /// The doc screen 01-main-inspector: a 1440 pt window with the inspector open and a comparison on both sides.
    private static func footerChecks(app: AppModel, window: NSWindow, fixture: URL, shot: (String) -> Void) async {
        let galaxy = DemoDeviceService.galaxyID
        let storage: UInt32 = 0x0001_0001
        let folder = "/Download"
        app.showStorage(deviceID: galaxy, storageID: storage)
        app.devicePane.navigate(to: .device(DeviceLocation(deviceID: galaxy, storageID: storage, path: folder)))
        guard await until(3, { app.devicePaneBrowsable && app.devicePane.hasListing }) else {
            return check("Footer words: the Galaxy's Download folder loads", false)
        }
        // One file the same, one different, six only on the Mac.
        let files = app.devicePane.items.filter { !$0.isDirectory && ($0.size ?? 0) > 0 }.prefix(2)
        guard files.count == 2 else { return check("Footer words: two device files to compare", false) }
        let fm = FileManager.default
        for (index, item) in files.enumerated() {
            let size = Int(item.size ?? 0) + (index == 0 ? 0 : 1)
            fm.createFile(atPath: fixture.appendingPathComponent(item.name).path, contents: Data(count: size))
        }
        let onlyHere = (1...6).map { "Only on the Mac \($0).txt" }
        for name in onlyHere { try? Data(repeating: 3, count: 24_000).write(to: fixture.appendingPathComponent(name)) }
        app.showMacFolder(fixture)
        _ = await until(3) { app.macPane.items.count == 8 }
        app.macPane.selectAndReveal(Set(onlyHere.prefix(3)))
        window.setContentSize(NSSize(width: 1440, height: 880))
        app.inspectorVisible = true
        await wait(1.2)

        /// The footer row the pane shows ("full-4": the full words alone), and the words' frame.
        func footer(_ kind: PaneKind) -> (tag: String, frame: CGRect)? {
            let prefix = "footer.\(kind.rawValue)."
            return polishFrames.first { $0.key.hasPrefix(prefix) }.map { (String($0.key.dropFirst(prefix.count)), $0.value) }
        }
        func describe(_ kind: PaneKind) -> String {
            "\(footer(kind)?.tag ?? "none"), \(Int(footer(kind)?.frame.width ?? 0)) of \(Int(layoutFrames[.pane(kind)]?.width ?? 0)) pt"
        }
        func showsWords(_ kind: PaneKind, fullOnly: Bool) -> Bool {
            guard let pane = layoutFrames[.pane(kind)], let words = footer(kind),
                  polishFrames.keys.filter({ $0.hasPrefix("footer.\(kind.rawValue).") }).count == 1 else { return false }
            let inside = pane.insetBy(dx: -0.5, dy: -0.5).contains(words.frame) && words.frame.minY >= pane.maxY - PaneFooter.height
            return inside && (words.tag.hasPrefix("full") || (!fullOnly && words.tag.hasPrefix("short")))
        }
        // The critique's screen: "✓ 1 ◐ 1 → 6 · 303 GB free" on the Mac side. The counts add up to the item count,
        // so the words stay whole once the free space, the selection and the item count have stepped aside.
        check("Inspector open, 1440 pt window: the Mac footer keeps the full words (\(describe(.mac)))",
              showsWords(.mac, fullOnly: true) && app.otherSideName(for: app.macPane) == (app.shownSession?.name ?? ""))
        check("Inspector open, 1440 pt window: the device footer keeps its words (\(describe(.device)))",
              showsWords(.device, fullOnly: true))
        await captureAppearances("17-polish-footer-inspector", shot: shot)
        app.inspectorVisible = false
        await wait(0.8)
        check("Inspector closed: both footers show the full words with the free space (\(describe(.mac)); \(describe(.device)))",
              showsWords(.mac, fullOnly: true) && showsWords(.device, fullOnly: true)
                && footer(.mac)?.tag == "full-1" && footer(.device)?.tag == "full-1")
        for item in files { try? fm.removeItem(at: fixture.appendingPathComponent(item.name)) }
        for name in onlyHere { try? fm.removeItem(at: fixture.appendingPathComponent(name)) }
        app.macPane.selectAndReveal([])
    }

    // MARK: Drawer

    /// One big file: the graph takes the facts column's width from the start. Two files: the column stays,
    /// and a stop after the small one leaves a visible sliver in the orange bar.
    private static func drawerChecks(app: AppModel, demo: DemoDeviceService, fixture: URL, shot: (String) -> Void) async {
        let galaxy = DemoDeviceService.galaxyID
        let storage: UInt32 = 0x0001_0001
        guard app.session(for: galaxy)?.isReady == true else { return check("Drawer: the Galaxy is ready", false) }
        let ticket = ("Train tickets Porto.pdf", UInt64(310_000))
        let backupPath = "/Download/whatsapp-backup.crypt14"
        let backup = ("whatsapp-backup.crypt14", UInt64(2_400_000_000))
        let original = demo.withLock {
            let node = demo.device(galaxy)?.storage(storage)?.node(at: backupPath)
            let previous = node?.size
            node?.size = backup.1
            return previous
        }
        defer {
            if let original { demo.withLock { demo.device(galaxy)?.storage(storage)?.node(at: backupPath)?.size = original } }
        }
        let fm = FileManager.default
        func drags(_ files: [(String, UInt64)]) -> [DeviceDragItem] {
            files.map { DeviceDragItem(deviceID: galaxy, storageID: storage, path: "/Download/\($0.0)", name: $0.0, isDir: false, size: $0.1) }
        }
        func clearFixture() {
            for name in (try? fm.contentsOfDirectory(atPath: fixture.path)) ?? [] {
                try? fm.removeItem(at: fixture.appendingPathComponent(name))
            }
            app.macPane.reload(quiet: true)
        }
        app.showStorage(deviceID: galaxy, storageID: storage)
        app.showMacFolder(fixture)
        clearFixture()
        app.showTransfers(tab: .inProgress)

        // One file.
        guard app.dropDeviceItems(drags([backup]), onto: app.macPane, into: nil), let oneID = app.transfers.jobs.last?.id else {
            return check("Drawer: one-file copy starts", false)
        }
        let appeared = await until(3) { polishFrames["speedGraph"] != nil }
        let factsAtStart = polishFrames["speedFacts"] != nil
        let startWidth = polishFrames["speedGraph"]?.width ?? 0
        _ = await until(3) { (app.transfers.job(oneID)?.progress?.speedBytesPerSec ?? 0) > 0 }
        await wait(0.6)
        let oneWidth = polishFrames["speedGraph"]?.width ?? 0
        let oneFacts = polishFrames["speedFacts"] != nil
        await captureAppearances("17-polish-drawer-one-file", shot: shot)
        app.transfers.cancel(oneID)
        _ = await until(3) { app.transfers.job(oneID)?.isActive != true }
        clearFixture()

        // Two files, then unplugged during the big one.
        guard app.dropDeviceItems(drags([ticket, backup]), onto: app.macPane, into: nil), let twoID = app.transfers.jobs.last?.id else {
            return check("Drawer: two-file copy starts", false)
        }
        let running = await until(4) {
            let p = app.transfers.job(twoID)?.progress
            return p?.currentName == backup.0 && (p?.currentBytesDone ?? 0) > 0 && (p?.speedBytesPerSec ?? 0) > 0
        }
        await wait(0.4)
        let twoWidth = polishFrames["speedGraph"]?.width ?? 0
        let twoFacts = polishFrames["speedFacts"]
        await captureAppearances("17-polish-drawer-two-files", shot: shot)
        check("One-file run: no facts column at any point, the graph takes its width from the start "
              + "(\(Int(startWidth)) → \(Int(oneWidth)) pt; two files: \(Int(twoWidth)) pt and a \(Int(twoFacts?.width ?? 0)) pt column)",
              appeared && !factsAtStart && !oneFacts && abs(startWidth - oneWidth) < 1 && running
                && twoFacts != nil && oneWidth >= twoWidth + 250)

        app.showTransfers(false)
        demo.setPlugged(deviceID: galaxy, false)
        let stopped = await until(3) { app.transfers.stoppedCopies.contains { $0.id == twoID } }
        await wait(0.5)
        let fraction = app.transfers.job(twoID).map { InterruptedCopyStatus($0).fraction } ?? 0
        check("Stopped at 310 KB of 2.4 GB: a fraction above zero (\(fraction)) that the bar draws as a sliver",
              stopped && fraction > 0 && fraction < 0.001
                && BarGauge.segmentWidths(0, fraction, width: 260, minimum: 6).second == 6)
        await captureAppearances("17-polish-stopped-bar", shot: shot)
        app.showTransfers(tab: .attention)
        await wait(0.4)
        await captureAppearances("17-polish-stopped-drawer", shot: shot)
        app.showTransfers(false)
        app.transfers.dismissStop(twoID)
        demo.setPlugged(deviceID: galaxy, true)
        _ = await until(4) { app.session(for: galaxy)?.isReady == true }
        clearFixture()
    }
}

extension View {
    /// Records this view's frame in `DebugSnapshots.polishFrames` under `key` during a self-check run, while
    /// it is on screen. `ViewThatFits` keeps its candidates alive, and a candidate shown again at its old
    /// frame gets no geometry change, so appearing records the last frame again.
    @ViewBuilder
    func polishFrame(_ key: String?) -> some View {
        if let key, ProcessInfo.processInfo.environment["REMTP_SNAPSHOT_DIR"] != nil {
            modifier(PolishFrame(key: key))
        } else {
            self
        }
    }
}

private struct PolishFrame: ViewModifier {
    let key: String
    @State private var last: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                last = frame
                DebugSnapshots.polishFrames[key] = frame
            }
            .onAppear { if let last { DebugSnapshots.polishFrames[key] = last } }
            .onDisappear { DebugSnapshots.polishFrames.removeValue(forKey: key) }
    }
}
#endif
