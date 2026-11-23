#if DEBUG
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// DEBUG ONLY. Renders the app's own windows to PNGs while driving a short demo scenario, so the
/// UI can be checked without Screen Recording permission (the app draws itself; nothing is captured
/// from the screen). Enabled with `REMTP_SNAPSHOT_DIR=/some/dir`; `REMTP_SNAPSHOT_MAC_PATH` picks the
/// Mac pane's folder. With `REMTP_SNAPSHOT_SCREENS=1` it writes the documentation screens and checks their
/// layout instead of running the full self-check.
@MainActor
enum DebugSnapshots {
    private static var running = false
    /// Keeps App Nap from throttling timers while the self-check runs in the background.
    private static var activity: NSObjectProtocol?
    /// FAIL lines printed so far. If any, the process exits with status 1 when the app terminates, so
    /// scripts and CI see the failure without parsing the output.
    private static var failures = 0

    static func runIfRequested(app: AppModel) {
        guard !running else { return }
        running = true
        guard let dir = ProcessInfo.processInfo.environment["REMTP_SNAPSHOT_DIR"] else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            // Runs after the app delegate's `applicationWillTerminate`; AppKit would exit with 0 next.
            MainActor.assumeIsolated {
                if failures > 0 { exit(1) }
            }
        }
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let macPath = ProcessInfo.processInfo.environment["REMTP_SNAPSHOT_MAC_PATH"]
        if let macPath, let problem = claimFixtureFolder(macPath) {
            check(problem, false)
            NSApp.terminate(nil)
            return
        }
        // What the real app's defaults hold now; the run must leave them alone (it writes to the demo domain).
        let standardBefore = standardDeviceDefaults()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "ReMTP self-check")
        if ProcessInfo.processInfo.environment["REMTP_SNAPSHOT_SCREENS"] != nil {
            Task { @MainActor in
                await documentationScreens(app: app, out: out, macPath: macPath)
                print("ReMTP screens written to \(out.path) (\(Date()))")
                fflush(stdout)
                NSApp.terminate(nil)
            }
            return
        }
        Task { @MainActor in
            func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
            @MainActor func shot(_ name: String) {
                for (i, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 300 {
                    write(window, to: out.appendingPathComponent("\(name)\(i == 0 ? "" : "-\(i)").png"))
                    if let sheet = window.attachedSheet { write(sheet, to: out.appendingPathComponent("\(name)-sheet.png")) }
                }
            }
            await wait(2.5)
            // Menu key equivalents, to spot clashes.
            var seen: [String: String] = [:]
            func walk(_ menu: NSMenu, _ path: String) {
                for item in menu.items {
                    if let sub = item.submenu { walk(sub, path + item.title + " > ") }
                    guard !item.keyEquivalent.isEmpty else { continue }
                    let key = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
                    let name = path + item.title
                    if let other = seen[key] { print("MENU CLASH \(name) vs \(other)") }
                    seen[key] = name
                }
            }
            if let main = NSApp.mainMenu { walk(main, "") }
            print("MENU F5 → \(seen.first { $0.key.hasSuffix(String(UnicodeScalar(NSF5FunctionKey)!)) }?.value ?? "missing")")
            NSApp.windows.first { $0.frame.width > 600 }?.setContentSize(NSSize(width: 1440, height: 880))
            if let macPath { app.macPane.navigate(to: .mac(URL(fileURLWithPath: macPath))) }
            app.devicePane.navigate(to: .device(DeviceLocation(deviceID: DemoDeviceService.galaxyID, storageID: 0x0001_0001,
                                                               path: "/Download/Lisbon 2026")))
            app.activate(.device)
            await wait(1.5)
            app.devicePane.selectAndReveal(["IMG_0413.HEIC"])
            await wait(0.5)
            shot("01-main")
            // Self-checks with synthetic key events (printed as PASS/FAIL).
            @MainActor func check(_ name: String, _ ok: Bool) { Self.check(name, ok) }
            @MainActor func mainWindow() -> NSWindow? { NSApp.windows.first { $0.frame.width > 600 } }
            /// Keyboard checks run with ReMTP active and its window key. Started from a background shell, another
            /// app stays frontmost and `NSApp.activate()` is only a request it may turn down, so this forces it
            /// (again on every poll, in case another app takes the front meanwhile) until AppKit reports the
            /// window key. The checks also set and verify first responders themselves.
            @MainActor func makeWindowKey() async {
                guard let window = mainWindow() else { return }
                let key = await until(3) {
                    if NSApp.isActive && window.isKeyWindow { return true }
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                    return false
                }
                print("INFO window key=\(key) active=\(NSApp.isActive)")
            }
            await makeWindowKey()
            await toolbarChecks(app: app, window: mainWindow(), shot: shot)
            @MainActor func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
                guard let window = NSApp.windows.first(where: { $0.frame.width > 600 }),
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: chars,
                                                   charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return }
                window.sendEvent(event)
            }
            app.macPane.bridge.focus()
            await wait(0.2)
            check("table focus activates Mac pane", app.activeKind == .mac && app.tableFocused)
            key(48, "\t")
            await wait(0.2)
            check("Tab switches to device pane", app.activeKind == .device && app.tableFocused)
            app.devicePane.selectAndReveal(["Boarding pass.pdf"])
            key(36, "\r")
            await wait(0.3)
            let editing = NSApp.windows.first { $0.frame.width > 600 }?.firstResponder is NSTextView
            check("Return starts inline rename", editing && !app.tableFocused)
            key(53, "\u{1b}")
            await wait(0.3)
            check("Escape cancels rename and refocuses the list", app.tableFocused && app.devicePane.item(named: "Boarding pass.pdf") != nil)
            key(126, String(UnicodeScalar(NSUpArrowFunctionKey)!), .command)
            await wait(0.6)
            check("⌘↑ goes to the parent folder", app.devicePane.location?.device?.path == "/Download"
                  && app.devicePane.selection == ["Lisbon 2026"])
            key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), .command)
            await wait(0.6)
            check("⌘↓ opens the selected folder", app.devicePane.location?.device?.path == "/Download/Lisbon 2026")
            app.newFolder()
            await wait(1.0)
            check("New folder on the device", app.devicePane.item(named: "untitled folder") != nil)
            key(53, "\u{1b}")
            await wait(0.2)
            if let macPath {
                app.devicePane.selectAndReveal(["Screenshot_20261103.png"])
                app.copySelection(from: app.devicePane)
                await wait(1.5)
                let copied = URL(fileURLWithPath: macPath).appendingPathComponent("Screenshot_20261103.png")
                let size = (try? copied.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                check("Device → Mac copy writes the file (\(size) bytes)", size == 1_100_000)
                await wait(0.8)
                let status = app.macPane.item(named: "Screenshot_20261103.png").map { app.status(for: $0, in: app.macPane) }
                check("Compare shows Same after the copy (\(String(describing: status)))", status == .same)
            }
            @MainActor func menuKey(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) -> Bool {
                guard let window = NSApp.windows.first(where: { $0.frame.width > 600 }),
                      let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: chars,
                                                   charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { return false }
                return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
            }
            /// The toolbar search field's editor is first responder.
            @MainActor func searchHasFocus() -> Bool {
                guard let window = mainWindow(), let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                      let field = window.toolbar?.items.lazy.compactMap({ ($0 as? NSSearchToolbarItem)?.searchField }).first
                else { return false }
                return (editor.delegate as AnyObject?) === field
            }
            /// The device list is first responder and the app knows it (list-only shortcuts are enabled).
            @MainActor func deviceListHasFocus() -> Bool {
                guard let table = app.devicePane.bridge.tableView else { return false }
                return mainWindow()?.firstResponder === table && app.tableFocused && app.activeKind == .device
            }
            @MainActor func devicePath() -> String? { app.devicePane.location?.device?.path }
            let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
            // Focus is set up explicitly and verified before each key equivalent.
            await makeWindowKey()
            app.focusSearch()
            let searchFocused = await until(2) { searchHasFocus() && !app.tableFocused }
            let fromField = devicePath()
            _ = menuKey(126, up, .command)
            await wait(0.4)  // nothing may change: give a deferred navigation or focus change time to show
            check("⌘↑ in the search field stays in the field", searchFocused && fromField == "/Download/Lisbon 2026"
                  && devicePath() == fromField && searchHasFocus())
            app.devicePane.bridge.focus()
            let listFocused = await until(2) { deviceListHasFocus() }
            let fromList = devicePath()
            let handled = menuKey(126, up, .command)
            let wentUp = await until(2) { devicePath() == "/Download" }
            check("⌘↑ via the menu goes up when the list has focus",
                  listFocused && fromList == "/Download/Lisbon 2026" && handled && wentUp)
            app.devicePane.goBack()
            await wait(0.5)

            if let edited = app.macPane.item(named: "Edited") {
                app.copy([edited], from: app.macPane, into: nil)
                await wait(1.5)
                let connection = app.connection(for: DemoDeviceService.galaxyID)
                let names = (try? connection?.list(storageID: 0x0001_0001, path: "/Download/Lisbon 2026/Edited"))?.map(\.name) ?? []
                check("Folder copy to the device recurses (\(names.joined(separator: ", ")))", names.contains("a.jpg"))
            }
            app.devicePane.goBack()
            await wait(0.3)

            // A transfer from the Mac pane, drawer open.
            let companion = macPath.map {
                URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Z - ReMTP comparison check.dat")
            }
            if let companion {
                try? Data(count: 24 * 1_048_576).write(to: companion)
                app.macPane.reload(quiet: true)
                _ = await until(2) { app.macPane.item(named: companion.lastPathComponent) != nil }
            }
            app.activate(.mac)
            let pics = app.macPane.items.filter { !$0.isDirectory }
            app.macPane.selectAndReveal(Set(pics.prefix(18).map(\.name)))
            app.copySelection(from: app.macPane)
            let jobs = app.transfers.jobs.count
            let inFlight = app.copyTargetsInFlight.count
            app.copySelection(from: app.macPane)
            check("Copying files that are already on their way queues nothing (\(app.transfers.jobs.count - jobs) new jobs, "
                  + "\(inFlight) of \(min(18, pics.count)) in flight)",
                  app.transfers.jobs.count == jobs && inFlight == min(18, pics.count))
            let comparedJob = app.transfers.activeJobs.last?.id
            if macPath != nil {
                _ = await until(3) {
                    guard let job = comparedJob.flatMap(app.transfers.job) else { return false }
                    return job.isActive && job.confirmedFilesCopied > 0 && Int(job.confirmedFilesCopied) < job.sources.count
                }
                transferComparisonChecks(app: app, jobID: comparedJob, during: true)
            }
            app.transfers.drawerExpanded = false
            _ = await until(5) { app.transfers.activeJobs.isEmpty }
            await wait(0.5)
            if macPath != nil { transferComparisonChecks(app: app, jobID: comparedJob, during: false) }
            check("Copy completion toast is centered above the destination folder's footer", toastFits(in: .device))
            await captureAppearances("02-transfer-bar", shot: shot)
            app.swapPanes()
            app.inspectorVisible = true
            await wait(0.4)
            check("Copy completion toast follows the destination folder after Swap with the inspector open", toastFits(in: .device))
            await captureAppearances("02-transfer-bar-swapped", shot: shot)
            app.inspectorVisible = false
            app.swapPanes()
            app.transfers.showDrawer()
            await wait(1.5)
            await captureAppearances("03-transfers", shot: shot)
            app.transfers.drawerExpanded = false
            if let companion { try? FileManager.default.removeItem(at: companion) }

            await nameChecks(app: app, shot: shot)
            portIDChecks()
            await dropChecks(app: app, macPath: macPath, shot: shot)
            await viewModeChecks(app: app, macPath: macPath, shot: shot)
            syncVisibilityCheck(app: app)

            // Inspector on the SP3000.
            app.showStorage(deviceID: DemoDeviceService.sp3000ID, storageID: 0x0001_0001)
            await wait(0.8)
            app.devicePane.navigate(to: .device(DeviceLocation(deviceID: DemoDeviceService.sp3000ID, storageID: 0x0001_0001,
                                                               path: "/Music/Miles Davis")))
            await wait(1.0)
            app.devicePane.selectAndReveal(["1959 - Kind of Blue"])
            app.inspectorVisible = true
            await wait(1.2)
            shot("05-inspector")
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await wait(0.8)
            shot("05-inspector-dark")
            app.inspectorVisible = false

            await usbModeChecks(app: app, out: out) { key(36, "\r") }

            // Device held by ptpcamerad.
            let galaxy = DemoDeviceService.galaxyID
            app.demoService?.simulateSystemHold(deviceID: galaxy)
            let holdDetected = await until(3) { app.session(for: galaxy)?.holder != nil }
            app.showDevice(galaxy)
            await wait(0.6)
            shot("06-access-dark")
            NSApp.appearance = NSAppearance(named: .aqua)
            await wait(0.6)
            shot("06-access-light")

            let previousMacLocation = app.macPane.location
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let sampleName = "Rename sample.txt"
            try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            try? Data().write(to: fixture.appendingPathComponent(sampleName))
            app.showMacFolder(fixture)
            let sampleListed = await until(3) { app.macPane.item(named: sampleName) != nil }
            app.macPane.selectAndReveal([sampleName])
            app.macPane.bridge.focus()
            let macFocused = await until(2) {
                guard let table = app.macPane.bridge.tableView else { return false }
                return mainWindow()?.firstResponder === table && app.activeKind == .mac && app.tableFocused
            }
            key(36, "\r")
            let renameStarted = await until(1) {
                (mainWindow()?.firstResponder as? NSTextView)?.isFieldEditor == true && !app.tableFocused
            }
            let stillHeld: Bool
            if case .held? = app.session(for: galaxy)?.phase { stillHeld = true } else { stillHeld = false }
            check("Return in the Mac list starts a rename and leaves the held device alone",
                  holdDetected && sampleListed && macFocused && renameStarted && stillHeld)
            key(53, "\u{1b}")
            // The control: with no list focused, the same Return reaches the prompt's default button and
            // releases the device. Without it the check above would also pass if Return reached nothing.
            mainWindow()?.makeFirstResponder(nil)
            _ = await until(1) { !app.tableFocused }
            key(36, "\r")
            let releasedByReturn = await until(3) {
                if case .held? = app.session(for: galaxy)?.phase { return false }
                return true
            }
            check("Return outside the file lists releases the held device (the prompt’s default button)",
                  stillHeld && releasedByReturn)
            if let previousMacLocation { app.macPane.navigate(to: previousMacLocation) }
            try? FileManager.default.removeItem(at: fixture)
            if !stillHeld || releasedByReturn {
                _ = await until(4) { app.session(for: galaxy)?.isReady == true }
                app.demoService?.simulateSystemHold(deviceID: galaxy)
                _ = await until(3) { app.session(for: galaxy)?.holder != nil }
            }
            app.showDevice(galaxy)

            // Sync preview sheet.
            app.syncPreview = SyncPreviewDemo.pairs.first
            await wait(1.2)
            shot("04-sync")
            app.syncPreview = nil
            await wait(0.5)
            // Swapped panes, then no devices at all.
            app.swapPanes()
            app.showMacFolder(app.macPlaces.last?.url ?? URL(fileURLWithPath: "/"))
            await wait(1.0)
            shot("07-swapped")
            app.swapPanes()
            app.demoService?.setPlugged(deviceID: DemoDeviceService.galaxyID, false)
            app.demoService?.setPlugged(deviceID: DemoDeviceService.sp3000ID, false)
            app.demoService?.setPlugged(deviceID: DemoDeviceService.pixelChargingID, false)
            await wait(0.8)
            await captureAppearances("08-unplugged", shot: shot)
            await notBrowsableDropCheck(app: app, macPath: macPath)

            await lifecycleChecks(app: app, macPath: macPath, shot: shot)

            // Checks kept in their own files (DebugSnapshots+*.swift). Each sets up the devices and panes it
            // needs and puts back what it changes.
            await folderChecks(app: app, macPath: macPath, shot: shot)
            await menuChecks(app: app, macPath: macPath, shot: shot)
            await aboutChecks(app: app, shot: shot)
            await polishChecks(app: app, macPath: macPath, shot: shot)

            app.transfers.cancelAll()
            await wait(0.5)
            prefsCheck(app: app, before: standardBefore)
            print("ReMTP snapshots written to \(out.path) (\(Date()))")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    static func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    static func captureAppearances(_ name: String, shot: (String) -> Void) async {
        shot(name)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for (variant, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            await wait(0.15)
            shot("\(name)-\(variant)")
        }
    }

    static func check(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name)")
        fflush(stdout)
    }

    private static func transferComparisonChecks(app: AppModel, jobID: UUID?, during: Bool) {
        let phase = during ? "during copy" : "after copy"
        let job = jobID.flatMap(app.transfers.job)
        let source = job?.spec.direction == .fromDevice ? app.devicePane : app.macPane
        let destination = app.other(source)
        let done = source.items.filter { job?.doneKeys.contains($0.compareKey) == true }
        let same = done.filter { item in
            guard let peer = destination.item(named: item.name), destination.items.contains(peer) else { return false }
            return app.status(for: item, in: source) == .same && app.status(for: peer, in: destination) == .same
        }
        check("Confirmed files have a visible Same row on both sides \(phase) (\(same.count) of \(done.count))",
              job?.isActive == during && (job?.confirmedFilesCopied ?? 0) > 0 &&
              done.count >= Int(job?.confirmedFilesCopied ?? 0) && same.count == done.count)
        for pane in [source, destination] {
            let groups = pane.comparisonGroups
            let grouped = groups.values.flatMap { $0 }
            let names = Set(grouped.map(\.name))
            let arrival = pane.currentArrivals
            let arriving = (arrival?.remaining ?? 0) + (arrival?.currentName == nil ? 0 : 1)
            let currentAlreadyListed = arrival?.currentName.map { pane.item(named: $0) != nil } ?? false
            let buckets = groups.keys.sorted().map { "\($0):\(groups[$0]?.count ?? 0)" }.joined(separator: ", ")
            check("\(pane.kind.rawValue) footer totals match its rows \(phase) (\(pane.items.count) items, "
                  + "\(arriving) arriving; \(buckets))",
                  grouped.count == pane.items.count && names.count == grouped.count && !currentAlreadyListed
                    && (during || arrival == nil))
        }
    }

    enum LayoutElement: Hashable {
        case pane(PaneKind), wordFooter(PaneKind), toast
    }

    static var layoutFrames: [LayoutElement: CGRect] = [:]

    private static func toastFits(in kind: PaneKind) -> Bool {
        guard let pane = layoutFrames[.pane(kind)], let toast = layoutFrames[.toast] else { return false }
        let area = CGRect(x: pane.minX, y: pane.minY, width: pane.width, height: pane.height - PaneFooter.height)
        return area.contains(toast) && abs(toast.midX - pane.midX) < 1
    }

    private static func toolbarChecks(app: AppModel, window: NSWindow?, shot: (String) -> Void) async {
        guard let toolbar = window?.toolbar else { return check("Main window toolbar installed", false) }
        let oldMode = toolbar.displayMode, oldAutosave = toolbar.autosavesConfiguration
        let oldInspector = app.inspectorVisible
        toolbar.autosavesConfiguration = false
        defer {
            toolbar.displayMode = oldMode
            toolbar.autosavesConfiguration = oldAutosave
            app.inspectorVisible = oldInspector
        }
        let menu = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
        check("View menu offers toolbar commands", menu?.items.contains { $0.title.hasPrefix("Customize Toolbar") } == true
              && menu?.items.contains { $0.title.hasSuffix(" Toolbar") } == true)
        for (mode, name) in [(NSToolbar.DisplayMode.iconAndLabel, "icon-and-text"), (.labelOnly, "text-only")] {
            toolbar.displayMode = mode
            for inspector in [false, true] {
                app.inspectorVisible = inspector
                await wait(0.5)
                let visible = toolbar.visibleItems ?? []
                let labels = visible.map(\.label)
                // The Copy button already says the whole sentence, so its label is just "Copy".
                let required = ["Back", "Forward", "View", "Swap Panes", "New Folder", "Copy", "Transfers", "Inspector", "Filter"]
                    + (app.showsSync ? ["Sync"] : [])
                // AppKit turns Text Only back into Icon and Text for this toolbar (macOS 15); either way every
                // label has to be on screen.
                let settled = toolbar.displayMode == mode || (mode == .labelOnly && toolbar.displayMode == .iconAndLabel)
                check("Toolbar \(name), inspector \(inspector), mode \(toolbar.displayMode.rawValue): all labels visible (\(labels))",
                      settled && required.allSatisfy(labels.contains) && !labels.contains { $0.hasPrefix("Copy ") })
                shot("01-toolbar-\(name)\(inspector ? "-inspector" : "")")
            }
        }
    }

    /// Waits up to `seconds` for `condition`.
    static func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            await wait(0.05)
        }
        return true
    }

    // MARK: Documentation screens

    /// The screens in `design/screenshots` that show the app itself (main window, inspector, device access,
    /// transfers), each in light and dark, from a fresh demo state. `macPath` is the Mac pane's folder; sample
    /// files are written into it, and the transfer screen copies the Galaxy's camera folder there (the demo
    /// backend writes sparse files).
    private static func documentationScreens(app: AppModel, out: URL, macPath: String?) async {
        await wait(2.5)
        guard let macPath, let window = mainWindow, let demo = app.demoService else {
            return check("ReMTP screens need REMTP_SNAPSHOT_MAC_PATH and the demo backend's main window", false)
        }
        let folder = URL(fileURLWithPath: macPath, isDirectory: true).standardizedFileURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writeViewSamples(into: folder)
        // The same text on every run: sample files dated by the demo's clock (pinned by design/app-shots.sh)
        // and a fixed free space on the Mac.
        let sampleDate = Date(timeIntervalSince1970: TimeInterval(DemoLibrary.now - 7_200))
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            try? FileManager.default.setAttributes([.modificationDate: sampleDate],
                                                   ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        LocalFileSystem.pinnedAvailableCapacity = 303_000_000_000
        let galaxy = DemoDeviceService.galaxyID, sp3000 = DemoDeviceService.sp3000ID
        let storage: UInt32 = 0x0001_0001
        func device(_ id: String, _ path: String) -> PaneLocation {
            .device(DeviceLocation(deviceID: id, storageID: storage, path: path))
        }
        func screen(_ name: String) async {
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                await makeKey(window)
                await wait(0.8)
                // Another app taking the front greys the window out (traffic lights, selection): a shot
                // the docs can't use.
                if !(NSApp.isActive && window.isKeyWindow) { await makeKey(window); await wait(0.8) }
                check("\(name)-\(suffix) is captured with the window active", NSApp.isActive && window.isKeyWindow)
                writeComposited(window, to: out.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
        // A 1× screen, like a CI runner's 1024 × 768, can't take these shots. The Screenshots workflow adds a 2×
        // virtual display; the window goes to the sharpest screen.
        if let sharpest = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }),
           sharpest.backingScaleFactor > window.backingScaleFactor {
            window.setFrameTopLeftPoint(NSPoint(x: sharpest.visibleFrame.minX + 24, y: sharpest.visibleFrame.maxY - 24))
            await wait(0.5)
        }
        window.setContentSize(NSSize(width: 1440, height: 880))
        await wait(0.3)
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        check("Screens are shot at 2× in a 1440 × 880 window (\(window.backingScaleFactor)×, \(contentSize))",
              window.backingScaleFactor == 2 && contentSize == NSSize(width: 1440, height: 880))

        // Main window: the same trip on both sides, partly copied already; three pictures selected on the Mac.
        app.showStorage(deviceID: galaxy, storageID: storage)
        app.devicePane.navigate(to: device(galaxy, "/Download/Lisbon 2026"))
        app.showMacFolder(folder)
        _ = await until(3) { app.devicePaneBrowsable && app.devicePane.hasListing && app.macPane.items.count > 3 }
        app.macPane.selectAndReveal(["Belém tower.png", "LX Factory.png", "Tram 28.png"])
        await makeKey(window)
        await wait(1.5)   // the toolbar validates its items a moment after the window becomes key
        await screen("01-main")
        let toolbarIDs = window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        let menuTitles = NSApp.mainMenu?.items.flatMap { $0.submenu?.items.map(\.title) ?? [] } ?? []
        let username = FileManager.default.homeDirectoryForCurrentUser.lastPathComponent
        check("Screens show the shipping app: no Sync, no DEMO badge, home folder as Home (toolbar \(toolbarIDs))",
              app.presentsAsShipping && !app.showsSync && !app.showsDemoBadge
                && !toolbarIDs.contains { $0.lowercased().contains("sync") } && !menuTitles.contains("Sync…")
                && app.macPlaces.last?.title == "Home" && !app.macPlaces.contains { $0.title == username })
        check("Both default-size comparison footers use words", [PaneKind.mac, .device].allSatisfy {
            guard let pane = layoutFrames[.pane($0)], let words = layoutFrames[.wordFooter($0)] else { return false }
            return words.width > 0 && pane.contains(words) && words.minY >= pane.maxY - PaneFooter.height
        })
        func visibleColumns(in pane: PaneModel) -> [String] {
            pane.bridge.coordinator?.tableView.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue) ?? []
        }
        let macColumns = visibleColumns(in: app.macPane), deviceColumns = visibleColumns(in: app.devicePane)
        check("Device keeps Kind over Date Modified while Mac keeps Date Modified (\(macColumns), \(deviceColumns))",
              macColumns.contains(NSUserInterfaceItemIdentifier.modifiedColumn.rawValue)
                && !macColumns.contains(NSUserInterfaceItemIdentifier.kindColumn.rawValue)
                && deviceColumns.contains(NSUserInterfaceItemIdentifier.kindColumn.rawValue)
                && !deviceColumns.contains(NSUserInterfaceItemIdentifier.modifiedColumn.rawValue))
        app.inspectorVisible = true
        await screen("01-main-inspector")
        let inspectorColumns = visibleColumns(in: app.devicePane)
        check("Device keeps Name, status, Size and Kind with the inspector open (\(inspectorColumns))",
              inspectorColumns == ["name", "status", "size", "kind"])
        app.inspectorVisible = false

        // Inspector: an album on the SP3000.
        app.showStorage(deviceID: sp3000, storageID: storage)
        app.devicePane.navigate(to: device(sp3000, "/Music/Miles Davis"))
        _ = await until(3) { app.devicePaneBrowsable && app.devicePane.items.contains { $0.name == "1959 - Kind of Blue" } }
        app.activate(.device, focus: true)
        app.devicePane.selectAndReveal(["1959 - Kind of Blue"])
        app.inspectorVisible = true
        await wait(1.2)
        await screen("05-inspector")
        app.inspectorVisible = false

        // Device access: the Galaxy held by ptpcamerad.
        demo.simulateSystemHold(deviceID: galaxy)
        _ = await until(3) { app.session(for: galaxy)?.holder != nil }
        app.showDevice(galaxy)
        await screen("06-access")

        // Transfers: the Galaxy's camera folder on its way to the Mac, drawer open.
        if let held = app.session(for: galaxy), held.holder != nil { app.release(held) }
        _ = await until(4) { app.session(for: galaxy)?.isReady == true }
        app.showStorage(deviceID: galaxy, storageID: storage)
        app.devicePane.navigate(to: device(galaxy, "/DCIM/Camera"))
        _ = await until(3) { app.devicePaneBrowsable && app.devicePane.items.count > 20 }
        app.activate(.device, focus: true)
        app.devicePane.selectAndReveal(Set(app.devicePane.items.map(\.name)), scrollTo: app.devicePane.items.first?.name)
        // On simulated time, held at the same point every run, so the numbers and the graph repeat.
        let hold: UInt64 = 470_000_000
        DemoTransfer.screenshotHold = hold
        app.copySelection(from: app.devicePane)
        let held = await until(15) { (app.transfers.running?.progress?.bytesDone ?? 0) >= hold }
        check("The copy holds after \(hold) bytes for the transfers screen", held)
        app.transfers.showDrawer()
        await wait(2.5)
        await screen("03-transfers")
        app.transfers.cancelAll()
        DemoTransfer.screenshotHold = nil
        NSApp.appearance = nil
        await wait(0.5)
    }

    /// The window as the window server composites it: the accent colour on sidebar icons, vibrancy and
    /// rounded corners, which `write` (the view hierarchy drawn into a bitmap) leaves out. An app can read
    /// its own windows without Screen Recording permission. The call is deprecated (its replacement,
    /// ScreenCaptureKit, needs that permission), so it is looked up at run time; without it, this is `write`.
    private static func writeComposited(_ window: NSWindow, to url: URL) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let image = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage").flatMap { symbol in
            unsafeBitCast(symbol, to: CreateImage.self)(
                .null, CGWindowListOption.optionIncludingWindow.rawValue, CGWindowID(window.windowNumber),
                CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue)?.takeRetainedValue()
        }
        guard let image else {
            print("INFO no composited capture for \(url.lastPathComponent): drawn by the app instead (sidebar icons lose their tint)")
            return write(window, to: url)
        }
        try? NSBitmapImageRep(cgImage: sRGB(image)).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The image converted to sRGB, the profile browsers assume. The display's own profile would be embedded
    /// otherwise, and a virtual display (CI's) gets a new one, dated, every run: new PNG bytes for the same pixels.
    private static func sRGB(_ image: CGImage) -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    // MARK: Fixture folder

    /// Left in a Mac folder the self-check has used, so later runs may use it again.
    private static let fixtureMarker = ".remtp-selfcheck"

    /// The run writes sample files into the Mac folder (replacing same-named ones), renames and deletes
    /// there: it only takes a folder that is empty or that an earlier run marked. Nil when the folder is
    /// usable, else why not.
    private static func claimFixtureFolder(_ path: String) -> String? {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let marker = folder.appendingPathComponent(fixtureMarker)
        if fm.fileExists(atPath: marker.path) { return nil }
        let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        guard contents.allSatisfy({ $0 == ".DS_Store" }) else {
            return "REMTP_SNAPSHOT_MAC_PATH must be an empty folder: the self-check writes, renames and deletes files in it (\(folder.path))"
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: marker)
        } catch {
            return "Couldn’t prepare \(folder.path): \(error.localizedDescription)"
        }
        return nil
    }

    // MARK: Demo defaults

    /// The device keys of the real app's defaults domain, as stored (nil when absent).
    private static func standardDeviceDefaults() -> [String: Data] {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        var keys: [String: Data] = [:]
        for key in [KnownDevices.key, KnownDevices.namesKey, AppModel.viewModeKey(.mac), AppModel.viewModeKey(.device),
                    AppModel.chargingOnEjectKey, DeviceFolders.lastKey, DeviceFolders.favoritesKey] {
            if let value = domain[key] {
                keys[key] = (value as? Data) ?? (try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0))
            }
        }
        return keys
    }

    /// Demo runs keep known devices, names and view modes in their own domain, never in the real app's.
    private static func prefsCheck(app: AppModel, before: [String: Data]) {
        let after = standardDeviceDefaults()
        let standardKnown = after[KnownDevices.key].flatMap { try? JSONDecoder().decode([String: KnownDevice].self, from: $0) } ?? [:]
        let demoData = AppDefaults.store(demo: true).data(forKey: KnownDevices.key)
        let demoKnown = demoData.flatMap { try? JSONDecoder().decode([String: KnownDevice].self, from: $0) } ?? [:]
        let usedMTPIDs: Set<String> = [DemoDeviceService.galaxyID, DemoDeviceService.sp3000ID, DemoDeviceService.pixelID]
        // Compares before and after rather than asserting the real domain has no demo IDs: builds from before
        // the demo got its own domain may have left some there, and the real app purges them on its next launch.
        let state = after[KnownDevices.key] == nil ? "absent" : "\(standardKnown.count) entries"
        check("Demo devices and view modes are kept in \(AppDefaults.demoSuiteName); the run leaves the app’s defaults unchanged (\(KnownDevices.key): \(state))",
              after == before && usedMTPIDs.isSubset(of: Set(demoKnown.keys)) && app.isDemo)
    }

    private static func usbModeChecks(app: AppModel, out: URL, pressReturn: () -> Void) async {
        let chargingID = DemoDeviceService.pixelChargingID, fileTransferID = DemoDeviceService.pixelID
        let observed = await until(2) { app.adbOnlyDevices.contains { $0.id == chargingID && $0.adb == .ready } }
        app.sidebarSelection = .adbOnly(chargingID)
        check("USB modes: the charging-only row is present and selectable",
              observed && app.session(for: fileTransferID) == nil && app.shownADBOnlyDevice?.id == chargingID
              && app.sidebarSelection == .adbOnly(chargingID) && !app.devicePaneBrowsable)
        check("USB modes: Galaxy offers the mode controls; SP3000 does not",
              app.session(for: DemoDeviceService.galaxyID)?.adbAccess == .ready
              && app.session(for: DemoDeviceService.sp3000ID)?.adbAccess == DeviceADBAccess.off)

        if let window = mainWindow {
            let previousAppearance = NSApp.appearance
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                await makeKey(window)
                await wait(0.65)
                writeComposited(window, to: out.appendingPathComponent("09-charging-only-\(suffix).png"))
            }
            NSApp.appearance = previousAppearance
            window.makeFirstResponder(nil)
            _ = await until(1) { !app.tableFocused }
        }

        pressReturn()
        let selected = await until(4) {
            app.shownDeviceID == fileTransferID && app.devicePaneBrowsable && app.devicePane.hasListing
                && !app.adbOnlyDevices.contains { $0.id == chargingID }
        }
        check("USB modes: Return switches to File Transfer and selects the returning device", selected)
        guard let session = app.session(for: fileTransferID) else {
            check("USB modes: eject switches back to Charging Only", false)
            check("USB modes: the charging-only row keeps the custom name without a duplicate", false)
            return
        }

        let name = "Travel Pixel"
        app.renameDevice(fileTransferID, to: name)
        app.setSwitchToChargingOnEject(session, true)
        let serialKey = USBDeviceIdentity.serialKey(for: session.id)
        let savedKeys = AppDefaults.store(demo: true).stringArray(forKey: AppModel.chargingOnEjectKey) ?? []
        check("USB modes: the eject option is saved by vendor and serial in demo defaults",
              app.switchesToChargingOnEject(session) && serialKey == USBDeviceIdentity.serialKey(for: chargingID)
              && serialKey.map { savedKeys.contains($0) } == true
              && USBDeviceIdentity.serialKey(for: "18d1:4ee7:loc0000000000000001") == nil)
        app.eject(session)
        let cameBack = await until(4) {
            app.session(for: fileTransferID) == nil && app.shownADBOnlyDevice?.id == chargingID && !app.switchingUSBMode
        }
        check("USB modes: eject switches back to Charging Only", cameBack)
        check("USB modes: the charging-only row keeps the custom name without a duplicate",
              cameBack && app.known.all[fileTransferID] != nil && app.displayName(forDevice: chargingID) == name
              && !app.disconnectedDevices.contains { $0.id == fileTransferID })
        app.renameDevice(fileTransferID, to: "")
        app.setSwitchToChargingOnEject(session, false)
    }

    // MARK: Device names

    private static func nameChecks(app: AppModel, shot: (String) -> Void) async {
        let sp3000 = DemoDeviceService.sp3000ID
        let storage: UInt32 = 0x0001_0001
        app.showStorage(deviceID: sp3000, storageID: storage)
        _ = await until(2) { app.devicePaneBrowsable && app.devicePane.hasListing }
        let long = "Astell&Kern SP3000 Copper Limited Edition (living room)"
        app.renameDevice(sp3000, to: "  \(long)  ")
        let session = app.session(for: sp3000)
        let stored = AppDefaults.store(demo: true).dictionary(forKey: KnownDevices.namesKey)?[sp3000] as? String
        let titled = MainToolbar.copyTitle(long)
        let counted = MainToolbar.copyTitle(long, count: 1)
        check("Rename… names the device everywhere (\(app.otherSideName(for: app.macPane)))",
              session?.name == long && app.otherSideName(for: app.macPane) == long && app.devicePane.crumbs.first?.title == long
              && app.devicePane.subtitle == long && stored == long && session?.ref.name == "SP3000")
        check("A name too long for the toolbar’s copy button reads “Device” there, never a cut name (\(titled), \(counted))",
              titled == "Copy to Device" && counted == "Copy 1 to Device"
              && MainToolbar.copyTitle("Galaxy S23") == "Copy to Galaxy S23"
              && MainToolbar.copyTitle("Galaxy S23", count: 1_200) == "Copy \(NumberFormatter.localizedString(from: 1_200, number: .decimal)) to Galaxy S23")
        app.activate(.mac)
        app.macPane.selectAndReveal(Set(app.macPane.items.prefix(1).map(\.name)))
        await wait(0.8)
        shot("12-long-device-name")
        app.renameDevice(sp3000, to: "SP3000")
        let sameAsOwn = session?.customName == nil
        app.renameDevice(sp3000, to: "Player")
        let renamed = session?.name == "Player"
        app.renameDevice(sp3000, to: "   ")
        check("Renaming to its own name or to nothing goes back to the device’s name",
              sameAsOwn && renamed && session?.name == "SP3000" && session?.customName == nil
              && AppDefaults.store(demo: true).dictionary(forKey: KnownDevices.namesKey)?[sp3000] == nil)
    }

    /// A device without a serial number is known by its USB port: on another port it is still one known device.
    private static func portIDChecks() {
        let suite = "io.github.cro13.ReMTP.selfcheck-ports"
        guard let defaults = UserDefaults(suiteName: suite) else { return check("Port ids: a scratch defaults suite", false) }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        func player(_ location: String) -> DeviceRef {
            DeviceRef(id: "4102:1232:loc\(location)", manufacturer: "Dreamus Company", model: "SP3000", name: "SP3000", serial: "")
        }
        let usb2 = player("c513c4f9edcecb55"), usb3 = player("e8b984f0e31dbf26"), hub = player("0000000000000003")
        let phone = DeviceRef(id: "04e8:6860:R5CW30ABCDE", manufacturer: "Samsung", model: "SM-S911B", name: "Galaxy", serial: "R5CW30ABCDE")
        let known = KnownDevices(defaults: defaults)
        known.remember(usb2, linkSpeed: "USB 2.0")
        known.setCustomName("Player", for: usb2.id)
        known.setAutoRelease(usb2.id, ref: usb2, true)
        known.remember(phone, linkSpeed: nil)
        known.mergePortIDs(into: usb3.id)
        let moved = Set(known.all.keys) == [usb3.id, phone.id] && known.customName(usb3.id) == "Player"
            && known.autoRelease(usb3.id) && known.all[usb3.id]?.linkSpeed == nil && known.customName(usb2.id) == nil
        known.remember(usb3, linkSpeed: "USB 3.2 Gen 1")
        known.mergePortIDs(into: hub.id, connected: [usb3.id])
        known.remember(hub, linkSpeed: nil)
        let bothPlugged = known.all[usb3.id] != nil && known.all[hub.id] != nil
        // The entries of earlier versions, one per port, collapse to the newest on launch.
        let relaunched = KnownDevices(defaults: defaults)
        relaunched.mergePortIDs()
        let portEntries = relaunched.all.keys.filter { USBDeviceIdentity.portModel(for: $0) != nil }
        check("Port ids: on another port, a device without a serial number keeps its name and settings and leaves no “Not connected” twin; two plugged in at once both stay; older twins collapse on launch",
              moved && bothPlugged && portEntries.count == 1 && relaunched.all[phone.id] != nil
              && USBDeviceIdentity.portModel(for: usb2.id) == "4102:1232" && USBDeviceIdentity.portModel(for: phone.id) == nil
              && USBDeviceIdentity.portModel(for: "4102:1232:locus-1234") == nil)
    }

    // MARK: Drag and drop

    /// A drag pasteboard of its own, so the checks never touch the system's.
    private static func dragPasteboard(urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.cro13.ReMTP.selfcheck-drag"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        return pasteboard
    }

    /// Drop-target resolution (drop bar, path bar, rows), what each drop does, and real drops through the
    /// table's and SwiftUI's dragging-destination code, in a device folder full of folders.
    private static func dropChecks(app: AppModel, macPath: String?, shot: (String) -> Void) async {
        guard let macPath, let window = NSApp.windows.first(where: { $0.frame.width > 600 }) else { return }
        PaneModel.watchesMouseDuringDrags = false
        defer {
            PaneModel.watchesMouseDuringDrags = true
            DragPayload.dragPasteboard = NSPasteboard(name: .drag)
            DragTracker.source = nil
            app.dragEnded()
        }
        let sp3000 = DemoDeviceService.sp3000ID
        let storage: UInt32 = 0x0001_0001
        let fm = FileManager.default
        let mac = URL(fileURLWithPath: macPath).standardizedFileURL
        app.showMacFolder(mac)
        app.showStorage(deviceID: sp3000, storageID: storage)
        app.devicePane.navigate(to: .device(DeviceLocation(deviceID: sp3000, storageID: storage, path: "/Music")))
        _ = await until(3) { app.devicePane.hasListing && !app.devicePane.items.isEmpty }
        let device = app.devicePane
        guard let open = device.location, let folder = device.items.first, let connection = app.connection(for: sp3000) else {
            return check("Drop checks (SP3000 /Music didn’t load)", false)
        }
        let folderLocation = device.location(of: folder)
        let root = PaneLocation.device(DeviceLocation(deviceID: sp3000, storageID: storage, path: "/"))
        let file = FileItem(name: "Late night.m3u8", isDirectory: false, size: 2_800, modified: nil, devicePath: "/Music/Late night.m3u8")
        let crumbs = device.crumbs
        check("Drop targets: bar → open folder, last crumb → open folder, earlier crumb → that folder",
              device.dropTarget(.bar) == .openFolder(open) && crumbs.last.map { device.dropTarget(.crumb($0.location)) } == .openFolder(open)
              && device.dropTarget(.crumb(root)) == .ancestor(root) && device.items.allSatisfy(\.isBrowsable))
        check("Drop targets: on a folder row → that folder; between rows, on a file, on empty space → open folder",
              folderLocation != nil && device.dropTarget(.row(folder, on: true)) == folderLocation.map { .folder(folder, $0) }
              && device.dropTarget(.row(folder, on: false)) == .openFolder(open)
              && device.dropTarget(.row(file, on: true)) == .openFolder(open)
              && device.dropTarget(.row(nil, on: false)) == .openFolder(open))

        // What drops do: Mac files copy to the device; device rows don't go back onto the device; the Mac
        // pane moves its own rows (copies with Option) and refuses no-op drops into the folder they're in.
        let sample = mac.appendingPathComponent("ReMTP drop check.txt")
        let sub = mac.appendingPathComponent("Drop check folder", isDirectory: true)
        let inner = sub.appendingPathComponent("Moved by drop.txt")
        try? fm.removeItem(at: sub)
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try? Data(repeating: 7, count: 4_096).write(to: sample)
        try? Data(repeating: 8, count: 2_048).write(to: inner)
        let fromMac = DragPayload(source: .mac, deviceItems: [], urls: [sample], allowsMove: true)
        let fromFinder = DragPayload(source: nil, deviceItems: [], urls: [sample], allowsMove: true)
        let deviceRow = DeviceDragItem(deviceID: sp3000, storageID: storage, path: "/Playlists/Miles.m3u8", name: "Miles.m3u8",
                                       isDir: false, size: 4_100)
        let fromDevice = DragPayload(source: .device, deviceItems: [deviceRow], urls: [], allowsMove: true)
        let innerDrag = DragPayload(source: .mac, deviceItems: [], urls: [inner], allowsMove: true)
        var copyDrag = innerDrag
        copyDrag.allowsMove = false
        check("Drop operations: Mac/Finder → device copies, device → device refused, Mac → Mac moves (Option copies), no-ops refused",
              app.dropOperation(fromMac, into: open, in: device) == .copy
              && app.dropOperation(fromFinder, into: folderLocation ?? open, in: device) == .copy
              && app.dropOperation(fromDevice, into: open, in: device).isEmpty
              && app.dropOperation(fromDevice, into: .mac(mac), in: app.macPane) == .copy
              && app.dropOperation(innerDrag, into: .mac(mac), in: app.macPane) == .move
              && app.dropOperation(copyDrag, into: .mac(mac), in: app.macPane) == .copy
              && app.dropOperation(innerDrag, into: .mac(sub), in: app.macPane).isEmpty
              && app.dropOperation(DragPayload(source: .mac, deviceItems: [], urls: [sub], allowsMove: true),
                                   into: .mac(sub.appendingPathComponent("x")), in: app.macPane).isEmpty)

        // The table: `.on` a folder row → that folder, `.above` or below the rows → the open folder.
        if let coordinator = device.bridge.coordinator {
            let onRow = coordinator.tableDrop(fromMac, row: 0, dropOperation: .on)
            let between = coordinator.tableDrop(fromMac, row: 1, dropOperation: .above)
            let below = coordinator.tableDrop(fromMac, row: device.items.count, dropOperation: .above)
            check("Table drops: on a folder row → that folder, between rows and below them → open folder",
                  onRow?.0 == folderLocation.map { .folder(folder, $0) } && onRow?.1 == .copy
                  && between?.0 == .openFolder(open) && between?.1 == .copy && below?.0 == .openFolder(open))
        } else {
            check("Table drops (no table)", false)
        }

        // Real drops through AppKit's dragging-destination calls (the table and the SwiftUI drop bar / path bar).
        guard let table = device.bridge.tableView, let scroll = table.enclosingScrollView,
              let macTable = app.macPane.bridge.tableView, let macScroll = macTable.enclosingScrollView else {
            return check("Simulated drags (no tables)", false)
        }
        DragPayload.dragPasteboard = dragPasteboard(urls: [sample])
        let finderDrag = SimulatedDrag(window: window, pasteboard: DragPayload.dragPasteboard, source: nil)
        let listRect = scroll.convert(scroll.bounds, to: nil)
        let firstRow = table.convert(table.rect(ofRow: 0), to: nil)
        let icon = (table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NameCellView)
            .map { $0.iconView.convert($0.iconView.bounds, to: nil) } ?? firstRow
        // Resting on a folder row (here: on its icon) targets it and, after a second, opens it (spring-loading).
        let onFolder = finderDrag.move(to: NSPoint(x: icon.midX, y: icon.midY))
        let barShown = await until(1) { device.dropBarVisible }
        let springs = device.bridge.coordinator?.springTarget == folderLocation
        await wait(0.3)
        shot("13-drop-bar")
        let sprung = await until(2) { device.location == folderLocation }
        check("Dragging over the list shows the drop bar; resting on a folder row (on its icon) opens it after \(FileTableCoordinator.springDelay) s",
              onFolder == .copy && barShown && springs && sprung)
        device.goBack()
        _ = await until(2) { device.location == open && device.hasListing }
        await wait(0.3)
        // Onto the drop bar, right under the (now shorter) list: copies into the open folder, not into a folder row.
        let shortList = scroll.convert(scroll.bounds, to: nil)
        _ = listRect
        let bar = NSPoint(x: shortList.midX, y: shortList.minY - 20)
        let overBar = finderDrag.move(to: bar)
        let barTargeted = await until(1) { device.dropHighlight == .bar }
        await wait(0.3)
        shot("13-drop-bar-targeted")
        let droppedOnBar = finderDrag.drop()
        let arrived = await until(5) { (try? connection.stat(storageID: storage, path: "/Music/\(sample.lastPathComponent)")) != nil }
        let notInFolder = (try? connection.stat(storageID: storage, path: DevicePath.join(folder.devicePath ?? "/", sample.lastPathComponent))) == nil
        check("Dropping on the drop bar copies into the open folder (\(overBar.rawValue), bar targeted: \(barTargeted))",
              overBar == .copy && barTargeted && droppedOnBar && arrived && notInFolder)
        await wait(0.5)
        check("The drop bar goes away after the drop", !device.dropBarVisible && device.dropHighlight == nil)
        try? connection.delete(storageID: storage, path: "/Music/\(sample.lastPathComponent)")

        // Onto the middle of a folder row: into that folder.
        if device.items.count > 1, let rowFolder = device.items[1].devicePath {
            let row = table.convert(table.rect(ofRow: 1), to: nil)
            let rowDrag = SimulatedDrag(window: window, pasteboard: DragPayload.dragPasteboard, source: nil)
            let overRow = rowDrag.move(to: NSPoint(x: row.midX, y: row.midY))
            let droppedOnRow = rowDrag.drop()
            let path = DevicePath.join(rowFolder, sample.lastPathComponent)
            let inRow = await until(5) { (try? connection.stat(storageID: storage, path: path)) != nil }
            check("Dropping on a folder row copies into that folder (\(path))", overRow == .copy && droppedOnRow && inRow)
            try? connection.delete(storageID: storage, path: path)
            await wait(0.4)
        }

        // Mac pane: a row dragged within the pane onto an earlier path bar segment moves it there.
        app.showMacFolder(sub)
        _ = await until(2) { app.macPane.location == .mac(sub) && app.macPane.hasListing }
        await wait(0.3)
        DragPayload.dragPasteboard = dragPasteboard(urls: [inner])
        DragTracker.source = .mac
        let selfDrag = SimulatedDrag(window: window, pasteboard: DragPayload.dragPasteboard, source: macTable)
        let macRect = macScroll.convert(macScroll.bounds, to: nil)
        let barNotShown = selfDrag.move(to: NSPoint(x: macRect.midX, y: macRect.midY)).isEmpty
        await wait(0.2)
        let noBar = !app.macPane.dropBarVisible
        let parentCrumb = app.macPane.crumbs.dropLast().last
        var found = false
        var x = macRect.minX + 6
        while x < macRect.maxX - 40, !found, let parentCrumb {
            let operation = selfDrag.move(to: NSPoint(x: x, y: macRect.maxY + 18))
            await wait(0.02)
            found = app.macPane.dropHighlight == .crumb(parentCrumb.id) && operation == .move
            if !found { x += 6 }
        }
        let droppedOnCrumb = found && selfDrag.drop()
        let moved = await until(3) { fm.fileExists(atPath: mac.appendingPathComponent(inner.lastPathComponent).path) }
        check("Dragging a Mac row onto an earlier path bar segment moves it there (no drop bar for its own folder)",
              barNotShown && noBar && found && droppedOnCrumb && moved && !fm.fileExists(atPath: inner.path))
        DragTracker.source = nil
        try? fm.removeItem(at: sub)
        try? fm.removeItem(at: sample)
        try? fm.removeItem(at: mac.appendingPathComponent(inner.lastPathComponent))
        app.showMacFolder(mac)
        _ = await until(2) { app.macPane.location == .mac(mac) && app.macPane.hasListing }
        await wait(0.3)

        // A device row onto the Mac pane's drop bar (SwiftUI drop target, the exported device-item type).
        let rowPasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.cro13.ReMTP.selfcheck-drag"))
        rowPasteboard.clearContents()
        let rowItem = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(deviceRow) { rowItem.setData(data, forType: DeviceDragItem.pasteboardType) }
        rowPasteboard.writeObjects([rowItem])
        DragPayload.dragPasteboard = rowPasteboard
        DragTracker.source = .device
        let rowDrag = SimulatedDrag(window: window, pasteboard: rowPasteboard, source: table)
        let overMac = rowDrag.move(to: NSPoint(x: macRect.midX, y: macRect.midY))
        let macBarShown = await until(1) { app.macPane.dropBarVisible }
        await wait(0.3)
        let macList = macScroll.convert(macScroll.bounds, to: nil)
        let overMacBar = rowDrag.move(to: NSPoint(x: macList.midX, y: macList.minY - 20))
        let macBarTargeted = await until(1) { app.macPane.dropHighlight == .bar }
        let rowDropped = rowDrag.drop()
        let copied = mac.appendingPathComponent(deviceRow.name)
        let rowArrived = await until(5) { ((try? copied.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) == Int(deviceRow.size) }
        check("Dropping a device row on the Mac pane’s drop bar copies it into the open folder",
              overMac == .copy && macBarShown && overMacBar == .copy && macBarTargeted && rowDropped && rowArrived)
        DragTracker.source = nil
        try? fm.removeItem(at: copied)
        await wait(0.3)
    }

    // MARK: View modes

    private static var mainWindow: NSWindow? { NSApp.windows.first { $0.frame.width > 600 } }

    /// A key press as AppKit delivers it: ⌘ keys go through NSApp (key equivalents of the views, then the menu
    /// bar, then the first responder), others straight to the window.
    private static func sendKey(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
        guard let window = mainWindow,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
        if flags.contains(.command) { NSApp.sendEvent(event) } else { window.sendEvent(event) }
    }

    private static func sendMenuKey(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> Bool {
        guard let window = mainWindow,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    private static func arrow(_ code: UInt16) {
        let scalar: Int = switch code {
        case 123: NSLeftArrowFunctionKey
        case 124: NSRightArrowFunctionKey
        case 125: NSDownArrowFunctionKey
        default: NSUpArrowFunctionKey
        }
        sendKey(code, String(UnicodeScalar(scalar)!), [.numericPad, .function])
    }

    /// The toolbar's List / Columns / Icons control.
    private static func viewModeControl(in window: NSWindow) -> NSSegmentedControl? {
        func find(_ view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl, control.segmentCount == 3,
               control.toolTip(forSegment: 0)?.hasPrefix("List") == true { return control }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        let roots = [window.contentView?.superview].compactMap { $0 } + (window.toolbar?.items.compactMap(\.view) ?? [])
        return roots.lazy.compactMap(find).first
    }

    /// Images (QuickLook thumbnails), a folder, a long name, and files matching the Galaxy's Lisbon folder.
    private static func writeViewSamples(into folder: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder.appendingPathComponent("Albums", isDirectory: true), withIntermediateDirectories: true)
        let samples: [(String, NSColor, NSColor)] = [
            ("Alfama at sunset, panorama from the Miradouro de Santa Luzia.png", .systemOrange, .systemPink),
            ("Belém tower.png", .systemTeal, .systemBlue),
            ("Tram 28.png", .systemYellow, .systemRed),
            ("LX Factory.png", .systemGreen, .systemTeal),
            ("Time Out Market.png", .systemBrown, .systemOrange),
        ]
        for (name, from, to) in samples {
            let image = NSImage(size: NSSize(width: 320, height: 240), flipped: false) { rect in
                NSGradient(starting: from, ending: to)?.draw(in: rect, angle: 35)
                NSColor.white.withAlphaComponent(0.4).setFill()
                NSBezierPath(ovalIn: NSRect(x: 196, y: 128, width: 84, height: 84)).fill()
                return true
            }
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: folder.appendingPathComponent(name))
        }
        // Same name and size as on the Galaxy (Same), same name, other size (Differs).
        try? Data(repeating: 1, count: 182_000).write(to: folder.appendingPathComponent("Boarding pass.pdf"))
        try? Data(repeating: 2, count: 90_000).write(to: folder.appendingPathComponent("Hotel confirmation.pdf"))
    }

    /// List / Columns / Icons in both panes: switching (toolbar, ⌘1–3), remembering, opening folders, the
    /// icon grid's selection, type-select, rename and drops, the column browser's selection, arrow keys and
    /// drops, and screenshots of both views in light and dark mode.
    private static func viewModeChecks(app: AppModel, macPath: String?, shot: (String) -> Void) async {
        guard let macPath, let window = mainWindow else { return }
        PaneModel.watchesMouseDuringDrags = false
        let fm = FileManager.default
        let viewFolder = URL(fileURLWithPath: macPath).appendingPathComponent("View check", isDirectory: true).standardizedFileURL
        defer {
            PaneModel.watchesMouseDuringDrags = true
            DragPayload.dragPasteboard = NSPasteboard(name: .drag)
            DragTracker.source = nil
            app.dragEnded()
            app.setViewMode(.list, for: app.macPane)
            app.setViewMode(.list, for: app.devicePane)
            NSApp.appearance = nil
            try? fm.removeItem(at: viewFolder)
        }
        try? fm.removeItem(at: viewFolder)
        writeViewSamples(into: viewFolder)
        let sp3000 = DemoDeviceService.sp3000ID, galaxy = DemoDeviceService.galaxyID
        let storage: UInt32 = 0x0001_0001
        let mac = app.macPane, device = app.devicePane
        func sp(_ path: String) -> PaneLocation { .device(DeviceLocation(deviceID: sp3000, storageID: storage, path: path)) }
        func devicePath() -> String? { device.location?.device?.path }
        func installed(_ pane: PaneModel, _ mode: PaneViewMode) -> Bool {
            let bridge = pane.bridge
            guard pane.viewMode == mode, let view = bridge.view, view.window === window else { return false }
            switch mode {
            case .list: return bridge.coordinator != nil && bridge.owner === bridge.coordinator && view is PaneTableView
            case .columns: return bridge.columnCoordinator != nil && bridge.owner === bridge.columnCoordinator && view is PaneTableView
            case .icons: return bridge.iconCoordinator != nil && bridge.owner === bridge.iconCoordinator && view is PaneCollectionView
            }
        }
        app.showMacFolder(viewFolder)
        app.showStorage(deviceID: sp3000, storageID: storage)
        device.navigate(to: sp("/Music/Miles Davis"))
        _ = await until(3) { mac.hasListing && device.hasListing && devicePath() == "/Music/Miles Davis" }
        guard let connection = app.connection(for: sp3000) else { return check("View modes (SP3000 didn’t load)", false) }

        // Switching, in both panes.
        var failed: [String] = []
        for pane in [mac, device] {
            for mode in [PaneViewMode.icons, .columns, .list] {
                app.setViewMode(mode, for: pane)
                if !(await until(2) { installed(pane, mode) }) { failed.append("\(pane.kind.rawValue) \(mode.rawValue)") }
            }
        }
        check("View modes switch in both panes: List, Columns, Icons (failed: \(failed))", failed.isEmpty)

        if let macTable = mac.bridge.coordinator?.tableView, let deviceTable = device.bridge.coordinator?.tableView,
           let macStatus = macTable.tableColumn(withIdentifier: .statusColumn),
           let deviceStatus = deviceTable.tableColumn(withIdentifier: .statusColumn),
           let size = macTable.tableColumn(withIdentifier: .sizeColumn) {
            let unpaired = await until(2) {
                [macStatus, deviceStatus].allSatisfy { $0.isHidden && $0.headerToolTip == "Not compared: different folders" }
            }
            let originalWidth = size.width
            size.width = originalWidth + 8
            app.showStorage(deviceID: galaxy, storageID: storage)
            device.navigate(to: .device(DeviceLocation(deviceID: galaxy, storageID: storage, path: "/Download/Lisbon 2026")))
            func missingCell(in table: NSTableView) -> StatusCellView? {
                let column = table.column(withIdentifier: .statusColumn)
                guard column >= 0 else { return nil }
                return (0..<table.numberOfRows).lazy.compactMap { row in
                    table.view(atColumn: column, row: row, makeIfNecessary: false) as? StatusCellView
                }.first { $0.status.isMissing }
            }
            func arrowsPointAcross() -> Bool {
                let macDirection: MissingStatusDirection = app.leftPane === mac ? .right : .left
                let deviceDirection: MissingStatusDirection = macDirection == .right ? .left : .right
                let macCell = missingCell(in: macTable), deviceCell = missingCell(in: deviceTable)
                return !macStatus.isHidden && !deviceStatus.isHidden && macCell?.missingDirection == macDirection
                    && deviceCell?.missingDirection == deviceDirection && macCell?.text?.hasPrefix("Not ") == true
                    && deviceCell?.text?.hasPrefix("Not ") == true
            }
            let compared = await until(3) { arrowsPointAcross() }
            app.swapPanes()
            let switched = await until(2) { arrowsPointAcross() }
            app.swapPanes()
            check("List: comparison column returns and missing arrows follow pane order", compared && switched)
            app.showStorage(deviceID: sp3000, storageID: storage)
            device.navigate(to: sp("/Music/Miles Davis"))
            let hiddenAgain = await until(3) { device.hasListing && [macStatus, deviceStatus].allSatisfy(\.isHidden) }
            check("List: unrelated folders hide status, explain why, and preserve metadata widths",
                  unpaired && hiddenAgain && abs(size.width - originalWidth - 8) < 0.5)
            size.width = originalWidth
        }

        // ⌘2 / ⌘3 / ⌘1 act on the active pane; the toolbar control follows and the new view keeps the focus.
        await makeKey(window)
        device.bridge.focus()
        _ = await until(1) { app.tableFocused && app.activeKind == .device }
        let control = viewModeControl(in: window)
        var shortcuts: [String] = []
        for (mode, code) in [(PaneViewMode.columns, UInt16(19)), (.icons, 20), (.list, 18)] {
            let handled = sendMenuKey(code, String(mode.shortcut), .command)
            let segment = PaneViewMode.allCases.firstIndex(of: mode)
            let ok = await until(2) { installed(device, mode) && control?.selectedSegment == segment }
            let focused = await until(1) { app.tableFocused && window.firstResponder === device.bridge.view }
            if !(handled && ok && focused) {
                shortcuts.append("\(mode.rawValue) (handled: \(handled), view and control: \(ok), focus: \(focused))")
            }
        }
        check("⌘1 / ⌘2 / ⌘3 switch the active pane’s view, the toolbar control follows, the focus stays (failed: \(shortcuts))",
              control != nil && shortcuts.isEmpty && mac.viewMode == .list)

        // Remembered per pane, in the demo domain (prefsCheck: never in the app's own).
        app.setViewMode(.icons, for: mac)
        app.setViewMode(.icons, for: device)
        let store = AppDefaults.store(demo: true)
        check("View modes are remembered per pane in \(AppDefaults.demoSuiteName)",
              store.string(forKey: AppModel.viewModeKey(.mac)) == "icons" && store.string(forKey: AppModel.viewModeKey(.device)) == "icons")

        // Icons: opening, selection, type-select, rename, badges.
        await makeKey(window)
        _ = await until(2) { installed(device, .icons) && installed(mac, .icons) }
        guard let icons = device.bridge.iconCoordinator, let grid = icons.collectionView,
              let macIcons = mac.bridge.iconCoordinator else { return check("Icons view (not installed)", false) }
        await wait(0.4)
        let listed = icons.items.map(\.name) == device.items.map(\.name) && grid.numberOfItems(inSection: 0) == device.items.count
        let milestones = "1958 - Milestones"
        func gridSelection() -> Set<String> { Set(grid.selectionIndexPaths.map { icons.items[$0.item].name }) }
        device.selectAndReveal([milestones])
        device.bridge.focus()
        let gridFocused = await until(1) { window.firstResponder === grid && app.tableFocused }
        let shownSelected = gridSelection() == [milestones]
        sendKey(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), .command)
        let opened = await until(2) { devicePath() == "/Music/Miles Davis/\(milestones)" && device.hasListing }
        await wait(0.3)
        let tracks = icons.items.count == device.items.count && icons.items.contains { $0.name.hasSuffix(".flac") }
        sendKey(126, String(UnicodeScalar(NSUpArrowFunctionKey)!), .command)
        let back = await until(2) { devicePath() == "/Music/Miles Davis" && device.selection == [milestones] && gridSelection() == [milestones] }
        check("Icons: ⌘↓ opens the selected folder, ⌘↑ comes back with it selected",
              listed && gridFocused && shownSelected && opened && tracks && back)
        for (character, code) in [("1", UInt16(18)), ("9", 25), ("5", 23), ("9", 25)] { sendKey(code, character) }
        let typed = await until(1) { device.selection == ["1959 - Kind of Blue"] && gridSelection() == ["1959 - Kind of Blue"] }
        sendKey(36, "\r")
        let editing = await until(1) { window.firstResponder is NSTextView }
        sendKey(53, "\u{1b}")
        let cancelled = await until(1) { window.firstResponder === grid && device.item(named: "1959 - Kind of Blue") != nil }
        let unmatched = grid.item(at: IndexPath(item: 0, section: 0)) as? IconItem
        let badgeHidden = (unmatched?.view as? IconItemView)?.badgeView.isHidden == true
        check("Icons: type-select, Return renames inline, Escape cancels, unrelated folders have no badge",
              typed && editing && cancelled && unmatched?.status == .notOnMac && badgeHidden)
        let untitled = "untitled folder"
        app.newFolder()
        let iconNewFolder = await until(2) {
            gridSelection() == [untitled] && device.selection == [untitled] && window.firstResponder is NSTextView
        }
        sendKey(53, "\u{1b}")
        _ = await until(1) { window.firstResponder === grid }
        try? connection.delete(storageID: storage, path: "/Music/Miles Davis/\(untitled)")
        device.reload(quiet: true)
        _ = await until(2) { device.item(named: untitled) == nil && icons.items.count == device.items.count }

        // Icons: a drop on a folder icon goes into that folder; between icons, into the open folder.
        let sample = URL(fileURLWithPath: macPath).appendingPathComponent("ReMTP icon drop.txt")
        try? Data(repeating: 9, count: 4_096).write(to: sample)
        defer { try? fm.removeItem(at: sample) }  // again, in case a check returned early
        DragPayload.dragPasteboard = dragPasteboard(urls: [sample])
        let open = "/Music/Miles Davis"
        if icons.items.count > 3, let folderPath = icons.items[2].devicePath, let frame = icons.windowFrame(ofItem: 2),
           let last = icons.windowFrame(ofItem: icons.items.count - 1) {
            let onFolder = SimulatedDrag(window: window, pasteboard: DragPayload.dragPasteboard, source: nil)
            let overFolder = onFolder.move(to: NSPoint(x: frame.midX, y: frame.midY))
            let targeted = icons.dropTargetIndex == 2 && !icons.isWholeViewDropHighlighted
                && icons.springTarget == device.location(of: icons.items[2])
            let barShown = await until(1) { device.dropBarVisible }
            shot("14-icons-drop-on-folder")
            let dropped = onFolder.drop()
            let inFolder = DevicePath.join(folderPath, sample.lastPathComponent)
            let arrived = await until(5) { (try? connection.stat(storageID: storage, path: inFolder)) != nil }
            let notInOpen = (try? connection.stat(storageID: storage, path: DevicePath.join(open, sample.lastPathComponent))) == nil
            check("Icons: dropping on a folder icon copies into that folder (\(inFolder))",
                  overFolder == .copy && targeted && barShown && dropped && arrived && notInOpen && devicePath() == open)
            try? connection.delete(storageID: storage, path: inFolder)
            await wait(0.4)

            let visible = grid.convert(grid.visibleRect, to: nil)
            let empty = NSPoint(x: visible.midX, y: max(visible.minY + 8, last.minY - 30))
            let between = SimulatedDrag(window: window, pasteboard: DragPayload.dragPasteboard, source: nil)
            let overEmpty = between.move(to: empty)
            let whole = icons.isWholeViewDropHighlighted && icons.dropTargetIndex == nil
            let droppedEmpty = between.drop()
            let inOpen = DevicePath.join(open, sample.lastPathComponent)
            let arrivedOpen = await until(5) { (try? connection.stat(storageID: storage, path: inOpen)) != nil }
            check("Icons: dropping between icons copies into the open folder (whole grid highlighted: \(whole))",
                  overEmpty == .copy && whole && droppedEmpty && arrivedOpen)
            try? connection.delete(storageID: storage, path: inOpen)
            device.reload(quiet: true)
            await wait(0.4)
        } else {
            check("Icons drops (no items)", false)
        }

        // Screenshots: icons with thumbnails (Mac) and type icons with status badges (Galaxy).
        app.showStorage(deviceID: galaxy, storageID: storage)
        device.navigate(to: .device(DeviceLocation(deviceID: galaxy, storageID: storage, path: "/Download/Lisbon 2026")))
        _ = await until(3) { device.hasListing && devicePath() == "/Download/Lisbon 2026" }
        device.selectAndReveal(["IMG_0413.HEIC"])
        mac.selectAndReveal(["Tram 28.png"])
        device.bridge.focus()
        NSApp.appearance = NSAppearance(named: .aqua)
        await wait(1.5)
        let labelledBadge = grid.visibleItems().contains { item in
            guard let icon = item as? IconItem, icon.status.isMissing, let view = icon.view as? IconItemView else { return false }
            return !view.badgeView.isHidden && view.badgeView.image != nil && view.accessibilityLabel()?.contains("Not ") == true
        }
        check("Icons: overlapping folders show a badge with status in words", labelledBadge)
        let iconDestination = PaneLocation.device(DeviceLocation(deviceID: galaxy, storageID: storage, path: "/Download"))
        await toastFallbackCheck(app: app, destination: iconDestination, view: "Icons")
        shot("14-icons-light")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await wait(0.8)
        shot("14-icons-dark")
        NSApp.appearance = nil
        try? app.connection(for: galaxy)?.delete(storageID: storage, path: "/Download/Tram 28.png")
        let photo = device.item(named: "IMG_0413.HEIC")
        check("Device photos show their thumbnails in Icons view",
              photo.flatMap { Thumbnails.shared.cached(for: $0, size: IconItem.iconSize) } != nil)

        // Icons, Mac pane: a file dropped on a folder icon of its own pane moves into it.
        if let albums = macIcons.items.firstIndex(where: { $0.name == "Albums" }), let frame = macIcons.windowFrame(ofItem: albums),
           let file = macIcons.items.first(where: { $0.name == "LX Factory.png" }), let url = file.url {
            DragPayload.dragPasteboard = dragPasteboard(urls: [url])
            DragTracker.source = .mac
            let selfDrag = SimulatedDrag(window: window, pasteboard: DragPayload.dragPasteboard, source: macIcons.collectionView)
            let operation = selfDrag.move(to: NSPoint(x: frame.midX, y: frame.midY))
            let dropped = selfDrag.drop()
            let target = viewFolder.appendingPathComponent("Albums").appendingPathComponent(file.name)
            let moved = await until(3) { fm.fileExists(atPath: target.path) && !fm.fileExists(atPath: url.path) }
            check("Icons: a Mac file dropped on a folder icon in its own pane moves into it", operation == .move && dropped && moved)
            DragTracker.source = nil
        } else {
            check("Icons: Mac pane drop (no Albums folder)", false)
        }

        // Columns, device pane: selecting a folder opens it in the next column and makes it the open folder.
        app.setViewMode(.columns, for: device)
        app.setViewMode(.columns, for: mac)
        app.showStorage(deviceID: sp3000, storageID: storage)
        device.navigate(to: sp("/Music"))
        _ = await until(3) { installed(device, .columns) && device.hasListing && devicePath() == "/Music" }
        guard let browser = device.bridge.columnCoordinator else { return check("Columns view (not installed)", false) }
        let built = await until(2) {
            browser.columns.count == 2 && browser.columns[0].items.firstIndex { $0.name == "Music" } == browser.columns[0].table.selectedRow
                && browser.columns[1].items.count == device.items.count
        }
        let musicColumn = browser.columns[1]
        window.makeFirstResponder(musicColumn.table)
        if let miles = musicColumn.items.firstIndex(where: { $0.name == "Miles Davis" }) {
            musicColumn.table.selectRowIndexes(IndexSet(integer: miles), byExtendingSelection: false)  // as a click does
        }
        let opened3 = await until(2) {
            devicePath() == "/Music/Miles Davis" && browser.columns.count == 3 && device.hasListing
                && browser.columns[2].items.count == device.items.count
        }
        let followed = device.crumbs.last?.title == "Miles Davis" && device.openFolderItem?.name == "Miles Davis"
            && device.targetItems.map(\.name) == ["Miles Davis"] && app.canCopy
        check("Columns: selecting a folder opens it in the next column; it is the open folder (commands act on it) and the path bar follows",
              built && opened3 && followed)

        // → enters the open folder's column (its first album opens in a fourth column); ↓ picks the next album;
        // → again selects its first track; ← goes back to the album, then to the artist.
        let walkin = "/Music/Miles Davis/1954 - Walkin'", midnight = "/Music/Miles Davis/1956 - 'Round About Midnight"
        arrow(124)
        let entered = await until(2) { browser.columns.count == 4 && devicePath() == walkin && window.firstResponder === browser.columns[2].table }
        arrow(125)
        let nextAlbum = await until(2) {
            devicePath() == midnight && device.hasListing && browser.columns.count == 4 && browser.columns[3].items.count == device.items.count
        }
        arrow(124)
        let firstTrack = "01 - 'Round Midnight.flac"
        let onTrack = await until(2) { window.firstResponder === browser.columns[3].table && device.selection == [firstTrack] }
        let trackTarget = device.targetItems.map(\.name) == [firstTrack] && devicePath() == midnight
        arrow(123)
        let onAlbum = await until(2) {
            window.firstResponder === browser.columns[2].table && device.selection.isEmpty && devicePath() == midnight
                && device.targetItems.map(\.name) == ["1956 - 'Round About Midnight"]
        }
        arrow(123)
        let onArtist = await until(2) { devicePath() == "/Music/Miles Davis" && browser.columns.count == 3 && window.firstResponder === musicColumn.table }
        check("Columns: → / ← move between columns, ↓ within one; the open folder is the deepest selected folder (\(devicePath() ?? "-"))",
              entered && nextAlbum && onTrack && trackTarget && onAlbum && onArtist)
        app.newFolder()
        let columnNewFolder = await until(2) {
            browser.columns.last?.items.contains { $0.name == untitled } == true && device.selection == [untitled]
                && window.firstResponder is NSTextView && devicePath() == "/Music/Miles Davis"
        }
        sendKey(53, "\u{1b}")
        _ = await until(1) { window.firstResponder === browser.columns.last?.table }
        try? connection.delete(storageID: storage, path: "/Music/Miles Davis/\(untitled)")
        device.reload(quiet: true)
        _ = await until(2) { device.item(named: untitled) == nil }
        check("New Folder makes the folder in the open folder, selects it and starts renaming it (icons: \(iconNewFolder), columns: \(columnNewFolder))",
              iconNewFolder && columnNewFolder)

        // Columns: a drop on a folder row goes into it; anywhere else in a column into that column's folder.
        DragPayload.dragPasteboard = dragPasteboard(urls: [sample])
        if let row = musicColumn.items.firstIndex(where: { $0.name == "Daft Punk" }) {
            let rowRect = musicColumn.table.convert(musicColumn.table.rect(ofRow: row), to: nil)
            let onRow = SimulatedDrag(window: window, pasteboard: DragPayload.dragPasteboard, source: nil)
            let overRow = onRow.move(to: NSPoint(x: rowRect.midX, y: rowRect.midY))
            let droppedRow = onRow.drop()
            let inRow = "/Music/Daft Punk/\(sample.lastPathComponent)"
            let arrivedRow = await until(5) { (try? connection.stat(storageID: storage, path: inRow)) != nil }
            // The column before the deepest one (the browser scrolls by whole columns to keep the deepest visible).
            let earlierColumn = browser.columns[browser.columns.count - 2]
            let clip = earlierColumn.scroll.enclosingScrollView?.contentView
            let columnRect = earlierColumn.scroll.convert(earlierColumn.scroll.bounds, to: nil)
                .intersection(clip.map { $0.convert($0.bounds, to: nil) } ?? .infinite)
            let lastRow = earlierColumn.table.convert(earlierColumn.table.rect(ofRow: earlierColumn.items.count - 1), to: nil)
            let below = SimulatedDrag(window: window, pasteboard: DragPayload.dragPasteboard, source: nil)
            let overBelow = below.move(to: NSPoint(x: columnRect.midX, y: max(columnRect.minY + 8, lastRow.minY - 40)))
            let droppedBelow = below.drop()
            let inEarlier = "/Music/\(sample.lastPathComponent)"
            let arrivedEarlier = await until(5) { (try? connection.stat(storageID: storage, path: inEarlier)) != nil }
            // The earlier column re-lists its folder once the transfer is done.
            let listedInColumn = await until(2) { earlierColumn.items.contains { $0.name == sample.lastPathComponent } }
            check("Columns: dropping on a folder row copies into it, below an earlier column’s rows into that column’s folder (and it shows there)",
                  overRow == .copy && droppedRow && arrivedRow && overBelow == .copy && droppedBelow && arrivedEarlier && listedInColumn
                  && devicePath() == "/Music/Miles Davis")
            try? connection.delete(storageID: storage, path: inRow)
            try? connection.delete(storageID: storage, path: inEarlier)
            try? fm.removeItem(at: sample)
        } else {
            check("Columns drops (no Daft Punk row)", false)
        }

        // Columns, Mac pane: every folder above the open one has its row selected, hidden ones (/tmp) too.
        let macChain = ColumnBrowserCoordinator.chain(for: mac)
        let macColumns = await until(3) {
            guard let browser = mac.bridge.columnCoordinator, browser.columns.count == macChain.count, macChain.count > 1 else { return false }
            return browser.columns.dropLast().allSatisfy { $0.loaded && $0.table.selectedRowIndexes.count == 1 }
        }
        check("Columns: the Mac pane shows \(macChain.count) levels down to “\(viewFolder.lastPathComponent)”, each folder selected in its parent",
              macColumns && installed(mac, .columns))

        // Screenshots: a track selected on the SP3000, an image on the Mac.
        device.navigate(to: sp("/Music/Miles Davis/1959 - Kind of Blue"), selecting: ["03 - Blue in Green.flac"])
        _ = await until(3) { device.hasListing && device.selection == ["03 - Blue in Green.flac"] }
        mac.selectAndReveal(["Tram 28.png"])
        device.bridge.focus()
        NSApp.appearance = NSAppearance(named: .aqua)
        await wait(1.2)
        await toastFallbackCheck(app: app, destination: sp("/Music"), view: "Columns")
        shot("15-columns-light")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await wait(0.8)
        shot("15-columns-dark")
        try? connection.delete(storageID: storage, path: "/Music/Tram 28.png")
    }

    private static func toastFallbackCheck(app: AppModel, destination: PaneLocation, view: String) async {
        guard let item = app.macPane.item(named: "Tram 28.png") else { return check("\(view) toast sample loaded", false) }
        let previous = app.transfers.jobs.last?.id
        app.copy([item], from: app.macPane, into: destination)
        let finished = await until(3) {
            guard let job = app.transfers.jobs.last, job.id != previous else { return false }
            return job.finishedAt != nil && job.filesCopied == 1
        }
        await wait(0.35)
        check("\(view): completion toast falls back to the destination device when another folder is open",
              finished && !destination.isSameFolder(as: app.devicePane.location) && toastFits(in: .device))
    }

    @MainActor private static func makeKey(_ window: NSWindow) async {
        _ = await until(3) {
            if NSApp.isActive && window.isKeyWindow { return true }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return false
        }
    }

    /// Sync previews placeholder data: only the demo backend shows its entry points.
    private static func syncVisibilityCheck(app: AppModel) {
        let transfer = NSApp.mainMenu?.items.first { $0.title == "Transfer" }?.submenu
        let menuHasSync = transfer?.items.contains { $0.title == "Sync…" } ?? false
        check("Sync is hidden with any backend but the demo one (real: \(AppModel.showsSync(for: StubDeviceService())), demo: \(app.showsSync))",
              !AppModel.showsSync(for: StubDeviceService()) && AppModel.showsSync(for: app.service) && app.showsSync && menuHasSync)
    }

    /// While the device pane shows nothing to browse, nothing can be dropped on it.
    private static func notBrowsableDropCheck(app: AppModel, macPath: String?) async {
        guard let macPath, let window = NSApp.windows.first(where: { $0.frame.width > 600 }),
              let location = app.devicePane.location, let scroll = app.macPane.bridge.tableView?.enclosingScrollView else { return }
        PaneModel.watchesMouseDuringDrags = false
        defer {
            PaneModel.watchesMouseDuringDrags = true
            DragPayload.dragPasteboard = NSPasteboard(name: .drag)
            app.dragEnded()
        }
        let url = URL(fileURLWithPath: macPath)
        let drag = DragPayload(source: nil, deviceItems: [], urls: [url.appendingPathComponent("x")], allowsMove: true)
        DragPayload.dragPasteboard = dragPasteboard(urls: [url.appendingPathComponent("x")])
        let simulated = SimulatedDrag(window: window, pasteboard: DragPayload.dragPasteboard, source: nil)
        // The device pane sits next to the Mac pane (panes aren't swapped here).
        let macRect = scroll.convert(scroll.bounds, to: nil)
        let operation = simulated.move(to: NSPoint(x: macRect.maxX + macRect.width / 2, y: macRect.midY))
        await wait(0.3)
        simulated.cancel()
        check("The device pane refuses drops while it has nothing to browse",
              !app.devicePaneBrowsable && app.dropOperation(drag, into: location, in: app.devicePane).isEmpty
              && operation.isEmpty && !app.devicePane.dropBarVisible)
    }

    /// Delete revalidation, Finder promises, unplug mid-transfer, ptpcamerad restore, issue-row keying.
    /// Runs after the screenshots, with both demo devices unplugged.
    private static func lifecycleChecks(app: AppModel, macPath: String?, shot: (String) -> Void) async {
        guard let demo = app.demoService else { return }
        let galaxy = DemoDeviceService.galaxyID, sp3000 = DemoDeviceService.sp3000ID
        let storage: UInt32 = 0x0001_0001
        demo.setPlugged(deviceID: galaxy, true)
        // Still held by the simulated ptpcamerad from the access screenshots: release it first.
        _ = await until(3) { app.session(for: galaxy).map { $0.isReady || $0.holder != nil } == true }
        if let g = app.session(for: galaxy), g.holder != nil { app.release(g) }
        _ = await until(4) { app.session(for: galaxy)?.isReady == true }

        // Delete: each item is checked against what was confirmed, right before it is deleted.
        if let connection = app.connection(for: galaxy) {
            let folder = "/Download/Lisbon 2026"
            func target(_ name: String) -> DeviceDeleteTarget? {
                (try? connection.stat(storageID: storage, path: DevicePath.join(folder, name)))
                    .flatMap { DeviceDeleteTarget(FileItem.device($0, folder: folder), storageID: storage) }
            }
            let confirmed = ["IMG_0416.HEIC", "IMG_0421.HEIC", "IMG_0458.HEIC"].compactMap(target)
            // After confirming: another object takes IMG_0416's path, IMG_0421 is deleted elsewhere.
            try? connection.rename(storageID: storage, path: DevicePath.join(folder, "IMG_0416.HEIC"), newName: "IMG_0416 original.HEIC")
            try? connection.rename(storageID: storage, path: DevicePath.join(folder, "Hotel confirmation.pdf"), newName: "IMG_0416.HEIC")
            try? connection.delete(storageID: storage, path: DevicePath.join(folder, "IMG_0421.HEIC"))
            let outcome = await app.deleteOnDevice(confirmed, connection: connection)
            let replacement = try? connection.stat(storageID: storage, path: DevicePath.join(folder, "IMG_0416.HEIC"))
            let original = try? connection.stat(storageID: storage, path: DevicePath.join(folder, "IMG_0416 original.HEIC"))
            let gone = (try? connection.stat(storageID: storage, path: DevicePath.join(folder, "IMG_0458.HEIC"))) == nil
            check("Delete re-checks each item: deleted \(outcome.deleted), skipped \(outcome.skipped.map(\.name))",
                  confirmed.count == 3 && outcome.deleted == ["IMG_0458.HEIC"] && gone
                  && Set(outcome.skipped.map(\.name)) == ["IMG_0416.HEIC", "IMG_0421.HEIC"] && outcome.failed.isEmpty
                  && replacement?.size == 96_000 && original != nil && outcome.report != nil)
        } else {
            check("Delete re-checks each item (Galaxy S23 didn’t reconnect)", false)
        }

        // Finder promise: written to exactly the promised URL, or failed.
        if let macPath, app.session(for: galaxy)?.isReady == true {
            let url = URL(fileURLWithPath: macPath).appendingPathComponent("ReMTP promise check.pdf")
            let fm = FileManager.default
            try? fm.removeItem(at: url)
            let item = DeviceDragItem(deviceID: galaxy, storageID: storage, path: "/Download/Lisbon 2026/Boarding pass.pdf",
                                      name: "Boarding pass.pdf", isDir: false, size: 182_000)
            func promise() async -> Error?? {
                var result: Error??
                app.fulfillPromise(item, to: url) { result = .some($0) }
                _ = await until(5) { result != nil }
                return result
            }
            let first = await promise()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let strays = ((try? fm.contentsOfDirectory(atPath: macPath)) ?? []).filter { $0.hasPrefix("Boarding pass") }
            check("Finder promise writes exactly the promised URL (\(size) bytes)",
                  first.map { $0 == nil } == true && size == 182_000 && strays.isEmpty)
            let second = await promise()
            let after = ((try? fm.contentsOfDirectory(atPath: macPath)) ?? []).filter { $0.hasPrefix("ReMTP promise check") }
            check("Finder promise fails instead of renaming when the URL is taken (\(String(describing: second ?? nil)))",
                  second.map { $0 != nil } == true && after == ["ReMTP promise check.pdf"])
            try? fm.removeItem(at: url)
        }

        // Unplugged mid-transfer: the job fails, the session is retired, the pane drops its listing.
        if let macPath, app.session(for: galaxy)?.isReady == true {
            let ticket = "Train tickets Porto.pdf"
            let ticketBytes: UInt64 = 310_000
            let backup = "whatsapp-backup.crypt14"
            let backupPath = DevicePath.join("/Download", backup)
            let backupBytes: UInt64 = 2_400_000_000
            let originalBackupBytes = demo.withLock {
                let node = demo.device(galaxy)?.storage(storage)?.node(at: backupPath)
                let previous = node?.size
                node?.size = backupBytes
                return previous
            }
            defer {
                if let originalBackupBytes {
                    demo.withLock { demo.device(galaxy)?.storage(storage)?.node(at: backupPath)?.size = originalBackupBytes }
                }
            }
            app.showStorage(deviceID: galaxy, storageID: storage)
            app.devicePane.navigate(to: .device(DeviceLocation(deviceID: galaxy, storageID: storage, path: "/Download")))
            _ = await until(2) { app.devicePane.hasListing }
            app.showMacFolder(URL(fileURLWithPath: macPath))
            let drags = [(ticket, ticketBytes), (backup, backupBytes)].map { name, size in
                DeviceDragItem(deviceID: galaxy, storageID: storage, path: DevicePath.join("/Download", name),
                               name: name, isDir: false, size: size)
            }
            let dropped = app.dropDeviceItems(drags, onto: app.macPane, into: nil)
            let jobID = app.transfers.jobs.last?.id
            func job() -> QueuedTransfer? { jobID.flatMap { app.transfers.job($0) } }
            let running = await until(2) {
                job()?.progress?.currentName == backup && (job()?.progress?.currentBytesDone ?? 0) > 0
            }
            demo.setPlugged(deviceID: galaxy, false)
            let ended = await until(3) { job()?.isActive == false }
            let state = job()?.state
            var disconnected = false
            if case .failed(let message)? = state { disconnected = message.contains("disconnected") }
            let fm = FileManager.default
            let partial = fm.fileExists(atPath: (macPath as NSString).appendingPathComponent(backup))
            app.activate(.device)
            await wait(0.3)
            check("Unplugging mid-transfer fails the job and retires the session (\(String(describing: state)))",
                  dropped && running && ended && disconnected && app.session(for: galaxy) == nil && !partial)
            check("…and the device pane drops its listing and shows the device as disconnected (\(app.windowSubtitle))",
                  app.devicePane.items.isEmpty && !app.devicePane.hasListing && app.shownDeviceID == galaxy
                  && !app.devicePaneBrowsable && app.windowSubtitle == "Not connected")
            let interruption = app.transfers.interruptedCopies.first { $0.id == jobID }
            let status = interruption.map(InterruptedCopyStatus.init)
            let copyBytes = ticketBytes + backupBytes
            let stoppedDetail = "1 of 2 files · \(Format.bytesOf(ticketBytes, copyBytes)) copied"
            check("Interrupted copy counts the published file, by files and by bytes (\(status?.detail ?? "none"))",
                  fm.fileExists(atPath: (macPath as NSString).appendingPathComponent(ticket))
                  && status?.detail == stoppedDetail && status?.fraction == Double(ticketBytes) / Double(copyBytes)
                  && interruption?.remainingFileCount == 1 && status?.reconnectHint == "Reconnect to copy the remaining 1"
                  && interruption.map(app.canCopyRemaining) == false)
            let opensOnAttention = app.transfers.defaultDrawerTab == .attention
            check("A stopped copy waits in Needs Attention, not Done Today, and the drawer opens there",
                  app.transfers.stoppedCopies.map(\.id) == [jobID].compactMap { $0 }
                  && app.transfers.attentionCount == app.transfers.issues.count + 1
                  && !app.transfers.doneToday.contains { $0.copyID == jobID }
                  && interruption.map { app.transfers.drawerTab(for: $0) } == .attention && opensOnAttention)
            await captureAppearances("09-unplugged-mid-transfer", shot: shot)
            let jobsBeforeReconnect = app.transfers.jobs.count
            demo.setPlugged(deviceID: galaxy, true)
            let readyAgain = await until(3) { app.session(for: galaxy)?.isReady == true }
            check("Reconnecting does not restart an interrupted copy",
                  readyAgain && job()?.state == state && app.transfers.jobs.count == jobsBeforeReconnect
                  && job().map(app.canCopyRemaining) == true)
            await captureAppearances("09-reconnected-copy-remaining", shot: shot)
            app.showTransfers()
            await wait(0.25)
            await captureAppearances("09-attention-copy-remaining", shot: shot)
            app.showTransfers(false)
            let stoppedFraction = job()?.fraction ?? 1
            let resumedID = jobID.flatMap(app.copyRemaining)
            func resumed() -> QueuedTransfer? { resumedID.flatMap(app.transfers.job) }
            let pending = [backupPath]
            let restarted = await until(2) { (resumed()?.progress?.speedBytesPerSec ?? 0) > 0 }
            let activeCopy = app.transfers.activeJobs.filter { $0.copyID == jobID }
            let runningStatus = activeCopy.first.map { RunningTransferStatus(job: $0, issues: app.transfers.issues) }
            check("A continuation shows one In Progress row with combined file and byte counts",
                  restarted && activeCopy.map(\.id) == [resumedID].compactMap { $0 }
                  && activeCopy.first?.title == "2 files" && activeCopy.first?.copyFilesCopied == 1
                  && activeCopy.first?.copyFilesTotal == 2 && activeCopy.first?.copyBytesTotal == ticketBytes + backupBytes
                  && (activeCopy.first?.copyBytesDone ?? 0) > ticketBytes
                  && runningStatus?.title == "Continuing · 1 of 2 files copied"
                  && !app.transfers.doneToday.contains { $0.copyID == jobID }
                  && !app.transfers.stoppedCopies.contains { $0.copyID == jobID })
            check("Continuing doesn't move the bar backwards (\(stoppedFraction) → \(activeCopy.first?.fraction ?? -1))",
                  (activeCopy.first?.fraction ?? -1) >= stoppedFraction)
            check("The collapsed bar has an estimate while copying, not while paused", runningStatus?.timeLeft != nil
                  && resumed().map { job in
                      var paused = job
                      paused.progress?.paused = true
                      return RunningTransferStatus(job: paused, issues: []).timeLeft == nil
                  } == true)
            await captureAppearances("09-continuing-bar", shot: shot)
            demo.setPlugged(deviceID: galaxy, false)
            let stoppedAgain = await until(3) { resumed()?.isActive == false && app.session(for: galaxy) == nil }
            let secondInterruption = app.transfers.interruptedCopies.filter { $0.copyID == jobID }
            let secondStatus = secondInterruption.first.map(InterruptedCopyStatus.init)
            await captureAppearances("09-unplugged-again", shot: shot)
            demo.setPlugged(deviceID: galaxy, true)
            let readyOnceMore = await until(3) { app.session(for: galaxy)?.isReady == true }
            check("A second interruption keeps one row with the original total and offers Copy the Remaining again",
                  stoppedAgain && readyOnceMore && secondInterruption.map(\.id) == [resumedID].compactMap { $0 }
                  && secondStatus?.detail == stoppedDetail && secondStatus?.actionTitle == "Copy the Remaining 1"
                  && secondStatus?.fraction == stoppedFraction
                  && resumed()?.copyBytesDone == ticketBytes && resumed()?.spec.pendingSources == pending
                  && app.transfers.stoppedCopies.filter { $0.copyID == jobID }.count == 1
                  && !app.transfers.doneToday.contains { $0.copyID == jobID }
                  && secondInterruption.first.map(app.canCopyRemaining) == true)
            let finalID = resumedID.flatMap(app.copyRemaining)
            func finalRun() -> QueuedTransfer? { finalID.flatMap(app.transfers.job) }
            app.showTransfers(tab: .inProgress)
            _ = await until(2) { (finalRun()?.progress?.speedBytesPerSec ?? 0) > 0 }
            await captureAppearances("09-continuing-drawer", shot: shot)
            app.showTransfers(false)
            var sawConflict = false
            // 2.4 GB at the demo's ~230 MB/s is ~10 s in 50 ms sleeps; shared CI runners oversleep, so allow plenty.
            let copiedRemaining = await until(45) {
                if app.transfers.issues.contains(where: { $0.jobID == finalID && $0.isConflict }) { sawConflict = true }
                return sawConflict || finalRun()?.isActive == false
            }
            let backupSize = (try? fm.attributesOfItem(atPath: (macPath as NSString).appendingPathComponent(backup))[.size] as? NSNumber)?.uint64Value
            check("Copy the Remaining writes only the unfinished file without an Already exists issue",
                  copiedRemaining && !sawConflict && finalRun()?.summary?.filesCopied == 1
                  && finalRun()?.spec.pendingSources == pending && finalRun()?.state == .finished && backupSize == backupBytes
                  && fm.fileExists(atPath: (macPath as NSString).appendingPathComponent(ticket)))
            check("Copy the Remaining clears the stopped prompt",
                  !app.transfers.interruptedCopies.contains { $0.copyID == jobID })
            let finishedCopy = app.transfers.doneToday.filter { $0.copyID == jobID }
            check("Done Today shows one finished copy with totals from both parts",
                  finishedCopy.map(\.id) == [finalID].compactMap { $0 }
                  && finishedCopy.first?.title == "2 files" && finishedCopy.first?.copySummary?.filesCopied == 2
                  && finishedCopy.first?.copySummary?.bytes == ticketBytes + backupBytes && finishedCopy.first?.copyParts == 2)
            check("The completion toast counts only files copied by the final run",
                  TransferToast.Summary(finishedCopy)?.title == "Copied 1 file to this Mac")
            await wait(0.25)
            await captureAppearances("09-copy-remaining-toast", shot: shot)
            app.showTransfers(tab: .done)
            await wait(0.25)
            await captureAppearances("09-copy-remaining-finished", shot: shot)
            app.showTransfers(false)
        }

        // ptpcamerad comes back once no released device is still connected, exactly once each time. Counts
        // are read after `systemHoldSettled`, which waits for the session closes and the restore the app
        // scheduled, and every setup step must have completed.
        func ready(_ id: String) -> Bool { app.session(for: id)?.isReady == true }
        func held(_ id: String) -> Bool {
            if case .held? = app.session(for: id)?.phase { return true }
            return false
        }
        demo.setPlugged(deviceID: galaxy, true)
        demo.setPlugged(deviceID: sp3000, true)
        let plugged = await until(3) { ready(galaxy) && ready(sp3000) }
        demo.simulateSystemHold(deviceID: galaxy)
        demo.simulateSystemHold(deviceID: sp3000)
        let heldBoth = await until(3) { held(galaxy) && held(sp3000) }
        if let g = app.session(for: galaxy), let s = app.session(for: sp3000) {
            app.release(g)
            app.release(s)
        }
        let released = await until(4) { ready(galaxy) && ready(sp3000) }
        await app.systemHoldSettled()
        let base = demo.restoreCalls
        if let g = app.session(for: galaxy) { app.eject(g) }
        await app.systemHoldSettled()
        let afterFirstEject = demo.restoreCalls - base
        check("Ejecting one released device keeps ptpcamerad paused while another is connected (\(afterFirstEject) restores)",
              plugged && heldBoth && released && afterFirstEject == 0)
        demo.setPlugged(deviceID: sp3000, false)
        let removed = await until(2) { app.session(for: sp3000) == nil }  // the unplug event reached the app
        await app.systemHoldSettled()
        let afterUnplug = demo.restoreCalls - base
        check("Unplugging the last released device restores ptpcamerad (\(afterUnplug) restores)", removed && afterUnplug == 1)
        if let g = app.session(for: galaxy) { app.reconnect(g) }
        let reconnected = await until(3) { ready(galaxy) }
        demo.simulateSystemHold(deviceID: galaxy)
        let heldAgain = await until(3) { held(galaxy) }
        if let g = app.session(for: galaxy) { app.release(g) }
        let releasedAgain = await until(4) { ready(galaxy) }
        if let g = app.session(for: galaxy) { app.eject(g) }
        await app.systemHoldSettled()
        let onEject = demo.restoreCalls - base - afterUnplug
        check("Ejecting the last released device restores ptpcamerad (\(onEject) restores)",
              reconnected && heldAgain && releasedAgain && onEject == 1)
        // Both go at once: the unplug is handled while the eject's close is still running (it is queued on the
        // main thread before the close can finish), so the two closes overlap. Still exactly one restore.
        demo.setPlugged(deviceID: sp3000, true)
        if let g = app.session(for: galaxy) { app.reconnect(g) }
        let pluggedBoth = await until(3) { ready(galaxy) && ready(sp3000) }
        demo.simulateSystemHold(deviceID: galaxy)
        demo.simulateSystemHold(deviceID: sp3000)
        let heldPair = await until(3) { held(galaxy) && held(sp3000) }
        if let g = app.session(for: galaxy), let s = app.session(for: sp3000) {
            app.release(g)
            app.release(s)
        }
        let releasedPair = await until(4) { ready(galaxy) && ready(sp3000) }
        await app.systemHoldSettled()
        let pairBase = demo.restoreCalls
        if let g = app.session(for: galaxy) { app.eject(g) }
        demo.setPlugged(deviceID: sp3000, false)
        let removedTogether = await until(2) { app.session(for: sp3000) == nil }
        await app.systemHoldSettled()
        let together = demo.restoreCalls - pairBase
        check("Ejecting and unplugging the last two released devices together restores ptpcamerad once (\(together) restores)",
              pluggedBoth && heldPair && releasedPair && removedTogether && together == 1)

        await issueRowChecks(app, shot: shot)
        await issueRenameCopyChecks(app, demo: demo, shot: shot)
        demo.setPlugged(deviceID: galaxy, false)
        await wait(0.3)
    }

    /// Ask-policy rows: keyed by (job, issue ID); answers before the handle exists are queued, not dropped, and
    /// can still be changed; only conflicts are ever answered. Problem rows trace their file back to its source and
    /// the folder it was going to (bad names report the source path, the rest the destination path; folder renames
    /// count once the job has finished) and copy it again on its own.
    private static func issueRowChecks(_ app: AppModel, shot: (String) -> Void) async {
        let center = app.transfers
        func job(_ sources: [String] = ["/tmp/a"]) -> QueuedTransfer {
            let spec = TransferJobSpec(direction: .toDevice, storageID: 1, sources: sources, destination: "/",
                                       conflict: .ask, verify: .size, cardSafeNames: false)
            return QueuedTransfer(spec: spec, deviceID: "self-check", deviceName: "Self-check", route: "a → b",
                                  destinationLabel: "b", sourceFolder: .mac(URL(fileURLWithPath: "/tmp")),
                                  destinationFolder: .device(DeviceLocation(deviceID: "self-check", storageID: 1, path: "/")),
                                  sources: Dictionary(uniqueKeysWithValues: sources.map {
                                      (FileItem.compareKey(($0 as NSString).lastPathComponent), false)
                                  }),
                                  firstItem: nil, linkDescription: "")
        }
        func issue(_ id: UInt64, _ kind: TransferIssueKind, path: String? = nil, folder: String? = nil,
                   retry: TransferRetryInfo? = nil) -> TransferIssueInfo {
            TransferIssueInfo(id: id, path: path ?? "/tmp/file\(id)", kind: kind, message: "self-check", existingSize: 1,
                              incomingSize: 2, destinationFolder: folder,
                              existingModified: kind == .conflict ? Date().addingTimeInterval(-9 * 86_400) : nil,
                              incomingModified: kind == .conflict ? Date() : nil, retry: retry)
        }
        func retry(_ source: String, cardSafe: String? = nil, keepBoth: Bool = false) -> TransferRetryInfo {
            TransferRetryInfo(source: source, folder: "/", cardSafeName: cardSafe, keepBoth: keepBoth)
        }
        let badName = "/tmp/Notes\\2026.txt"
        let renameFolder = FileManager.default.temporaryDirectory.appendingPathComponent("remtp-rename-\(UUID())", isDirectory: true)
        let renameFile = renameFolder.appendingPathComponent("Trip\\notes.txt")
        try? FileManager.default.createDirectory(at: renameFolder, withIntermediateDirectories: false)
        try? Data("Rename me".utf8).write(to: renameFile)
        defer { try? FileManager.default.removeItem(at: renameFolder) }
        let a = job(["/tmp/a", badName]), b = job(["/tmp/file3"])
        center.insertStartingForSelfCheck(a)
        center.insertStartingForSelfCheck(b)
        // Through the same bridge the core's callbacks use (it hops to the main actor).
        let bridgeA = TransferObserverBridge(jobID: a.id, center: center)
        let bridgeB = TransferObserverBridge(jobID: b.id, center: center)
        bridgeA.transferIssue(issue(1, .conflict, path: "/Download/Lisbon 2026/file1", folder: "/Download/Lisbon 2026"))
        bridgeB.transferIssue(issue(1, .conflict, path: "/Download/Archive/file1", folder: "/Download/Archive"))
        bridgeA.transferIssue(issue(2, .invalidName, path: renameFile.path, folder: "/Download"))
        bridgeB.transferIssue(issue(3, .noSpace, path: "/file3", retry: retry("/tmp/file3")))
        do {
            await wait(0.2)
            func rows() -> [PendingIssue] { center.issues.filter { $0.jobID == a.id || $0.jobID == b.id } }
            func row(_ job: QueuedTransfer, _ id: UInt64) -> PendingIssue? {
                center.issues.first { $0.id == PendingIssue.Key(jobID: job.id, issueID: id) }
            }
            check("Issue rows are keyed by job and issue ID (\(rows().count) rows, same ID in two jobs)",
                  rows().count == 4 && Set(rows().map(\.id)).count == 4)
            check("Same-named conflicts retain distinct destination folders and both dates",
                  row(a, 1)?.name == row(b, 1)?.name && row(a, 1)?.destinationPath(in: a) == "/Download/Lisbon 2026"
                  && row(b, 1)?.destinationPath(in: b) == "/Download/Archive"
                  && row(a, 1)?.info.existingModified != nil && row(a, 1)?.info.incomingModified != nil)
            bridgeA.transferIssue(issue(5, .invalidName, path: badName, retry: retry(badName, cardSafe: "Notes_2026.txt")))
            let c = job(["/tmp/c"])
            center.insertStartingForSelfCheck(c)
            TransferObserverBridge(jobID: c.id, center: center).transferIssue(issue(1, .conflict, retry: retry("/tmp/c")))
            await wait(0.2)
            check("Problem rows keep the core's retry, conflicts never get one (bad name: \(String(describing: row(a, 5)?.retry)), "
                  + "no space: \(String(describing: row(b, 3)?.retry)))",
                  row(a, 5)?.retry == retry(badName, cardSafe: "Notes_2026.txt") && row(b, 3)?.retry == retry("/tmp/file3")
                  && row(a, 2)?.retry == nil && row(a, 1)?.retry == nil && row(c, 1) != nil && row(c, 1)?.retry == nil)
            center.removeForSelfCheck([c.id])
            center.drawerTab = .attention
            center.drawerExpanded = true
            await wait(0.6)
            await captureAppearances("10-issues", shot: shot)
            let previousFolder = app.macPane.location
            if let bad = row(a, 2) { app.renameSource(of: bad) }
            let editing = await until(3) {
                app.macPane.location?.macURL?.standardizedFileURL.path == renameFolder.standardizedFileURL.path
                    && app.macPane.selection == [renameFile.lastPathComponent]
                    && (mainWindow?.firstResponder as? NSTextView)?.string == renameFile.lastPathComponent
            }
            check("Rename from an issue reveals its source folder and opens the inline editor", editing)
            let jobsBeforeRename = Set(center.jobs.map(\.id))
            if editing { sendKey(53, "\u{1b}") }
            let cancelled = await until(1) { !(mainWindow?.firstResponder is NSTextView) }
            check("Escape leaves the issue, source file and copy queue unchanged",
                  editing && cancelled && row(a, 2)?.renameSource == renameFile.path
                  && FileManager.default.fileExists(atPath: renameFile.path) && Set(center.jobs.map(\.id)) == jobsBeforeRename)
            if let bad = row(a, 2) { app.renameSource(of: bad) }
            let editingAgain = await until(3) { (mainWindow?.firstResponder as? NSTextView)?.string == renameFile.lastPathComponent }
            if editingAgain { sendKey(36, "\r") }
            let unchanged = await until(1) { !(mainWindow?.firstResponder is NSTextView) }
            check("Returning the same name leaves the issue and copy queue unchanged",
                  editingAgain && unchanged && row(a, 2)?.renameSource == renameFile.path && Set(center.jobs.map(\.id)) == jobsBeforeRename)
            if let previousFolder { app.macPane.navigate(to: previousFolder) }
            let before = Set(center.jobs.map(\.id))
            if let a5 = row(a, 5) { center.retry(a5) }
            let again = center.jobs.filter { !before.contains($0.id) }
            check("Copy as a card-safe name queues exactly that file again, card-safe, and removes the row "
                  + "(\(again.map(\.spec.sources)), card-safe: \(again.map(\.spec.cardSafeNames)))",
                  again.count == 1 && again.first?.spec.sources == [badName] && again.first?.spec.cardSafeNames == true
                  && again.first?.spec.destination == "/" && again.first?.deviceID == a.deviceID
                  && again.first?.state == .queued && row(a, 5) == nil)
            center.removeForSelfCheck(Set(again.map(\.id)))
            bridgeA.transferIssue(issue(7, .failed, path: "/a", retry: retry("/tmp/a", keepBoth: true)))
            await wait(0.2)
            let beforeKeep = Set(center.jobs.map(\.id))
            if let a7 = row(a, 7) { center.retry(a7) }
            let kept = center.jobs.filter { !beforeKeep.contains($0.id) }
            check("Keep Both queues the file again with Keep Both (\(kept.map(\.spec.conflict)))",
                  kept.count == 1 && kept.first?.spec.conflict == .keepBoth && kept.first?.spec.sources == ["/tmp/a"]
                  && kept.first?.spec.cardSafeNames == false && row(a, 7) == nil)
            center.removeForSelfCheck(Set(kept.map(\.id)))
            if let a1 = row(a, 1) { center.resolve(a1, .keepBoth) }
            if let a1 = row(a, 1) { center.resolve(a1, .replace) }
            if let b1 = row(b, 1) { center.resolve(b1, .skip) }
            if let a2 = row(a, 2) { center.resolve(a2, .replace) }   // not a conflict: dismissed, never answered
            if let b3 = row(b, 3) { center.dismiss(b3) }
            center.resolveAll(.keepBoth)
            check("Answers before the transfer handle exists are queued and the rows kept",
                  row(a, 1)?.queuedAnswer == .replace && row(b, 1)?.queuedAnswer == .skip && rows().count == 2)
            await wait(0.4)
            await captureAppearances("11-issues-queued", shot: shot)
            center.drawerExpanded = false
            let controlA = RecordingControl(), controlB = RecordingControl()
            center.attach(controlA, to: a.id)
            check("Queued answers are delivered once the handle arrives (A: \(controlA.answers), B: none yet)",
                  controlA.answers == ["1:replace"] && controlB.answers.isEmpty && row(a, 1) == nil && row(b, 1) != nil)
            check("A queued answer can be changed until then, and only the last one is delivered (A: \(controlA.answers))",
                  controlA.answers == ["1:replace"])
            center.attach(controlB, to: b.id)
            bridgeA.transferIssue(issue(4, .conflict))
            await wait(0.2)
            if let a4 = row(a, 4) { center.resolve(a4, .keepBoth) }
            check("Only conflicts are answered; later answers go straight to the handle (A: \(controlA.answers), B: \(controlB.answers))",
                  controlA.answers == ["1:replace", "4:keepBoth"] && controlB.answers == ["1:skip"] && rows().isEmpty)
            center.removeForSelfCheck([a.id, b.id])
        }
        do {
            let spec = TransferJobSpec(direction: .fromDevice, storageID: 1, sources: ["/DCIM/a.jpg"], destination: "/tmp/staging",
                                       conflict: .ask, verify: .size, cardSafeNames: false)
            let promise = QueuedTransfer(spec: spec, deviceID: "self-check", deviceName: "Self-check", route: "", destinationLabel: "",
                                         sourceFolder: .device(DeviceLocation(deviceID: "self-check", storageID: 1, path: "/DCIM")),
                                         destinationFolder: .mac(URL(fileURLWithPath: "/tmp/out")), sources: ["a.jpg": false],
                                         firstItem: nil, linkDescription: "")
            center.insertStartingForSelfCheck(promise)
            TransferObserverBridge(jobID: promise.id, center: center)
                .transferIssue(issue(1, .noSpace, path: "/tmp/staging/a.jpg", retry: retry("/DCIM/a.jpg")))
            await wait(0.2)
            let row = center.issues.first { $0.jobID == promise.id }
            check("Finder promise rows offer no retry (their staging folder is gone)", row != nil && row?.retry == nil)
            center.removeForSelfCheck([promise.id])
        }
        let metricsJob = job(["/tmp/a", "/tmp/b"])
        center.insertStartingForSelfCheck(metricsJob)
        let metricsBridge = TransferObserverBridge(jobID: metricsJob.id, center: center)
        var progress = TransferProgressInfo(filesDone: 0, filesTotal: 2, bytesDone: 1_000_000, bytesTotal: 8_000_000,
                                            currentName: "a", currentBytesDone: 1_000_000, currentBytesTotal: 4_000_000,
                                            speedBytesPerSec: 4_000_000, avgMsPerFile: 54, deviceWaitMsAvg: 8, idleMsAvg: 12,
                                            readAheadFiles: 0, readAheadBytes: 0, paused: false)
        center.drawerTab = .inProgress
        center.drawerExpanded = true
        metricsBridge.transferProgress(progress)
        await wait(0.4)
        shot("03-transfers-no-read-ahead")
        progress.readAheadFiles = 1
        progress.readAheadBytes = 4_000_000
        metricsBridge.transferProgress(progress)
        await wait(0.4)
        shot("03-transfers-with-read-ahead")
        center.drawerExpanded = false
        center.removeForSelfCheck([metricsJob.id])
    }

    private static func issueRenameCopyChecks(_ app: AppModel, demo: DemoDeviceService, shot: (String) -> Void) async {
        let center = app.transfers, deviceID = DemoDeviceService.galaxyID
        let storage: UInt32 = 0x0001_0001
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remtp-rename-copy-\(UUID())", isDirectory: true)
            .standardizedFileURL
        let mac = PaneLocation.mac(folder)
        let device = PaneLocation.device(DeviceLocation(deviceID: deviceID, storageID: storage, path: "/Download"))
        let deviceSource = device.appending(["Lisbon 2026"])
        let previousFolder = app.macPane.location
        let baseline = Set(center.jobs.map(\.id))
        let payload = Data("Rename and copy me".utf8)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer {
            center.drawerExpanded = false
            center.removeForSelfCheck(Set(center.jobs.map(\.id)).subtracting(baseline))
            if let previousFolder { app.macPane.navigate(to: previousFolder) }
            try? FileManager.default.removeItem(at: folder)
        }
        func reconnect() async -> Bool {
            demo.setPlugged(deviceID: deviceID, true)
            _ = await until(3) { app.session(for: deviceID).map { $0.isReady || $0.holder != nil } == true }
            if let session = app.session(for: deviceID), session.holder != nil { app.release(session) }
            return await until(4) { app.connection(for: deviceID) != nil }
        }
        func problem(_ name: String, direction: TransferDirection) async -> PendingIssue? {
            let (sourceFolder, destinationFolder) = direction == .toDevice ? (mac, device) : (deviceSource, mac)
            let source = DevicePath.join(sourceFolder.enginePath, name)
            let spec = TransferJobSpec(direction: direction, storageID: storage, sources: [source], destination: destinationFolder.enginePath,
                                       conflict: .replace, verify: .checksum, cardSafeNames: direction == .fromDevice, pendingSources: [source])
            let job = QueuedTransfer(spec: spec, deviceID: deviceID, deviceName: "Self-check", route: "", destinationLabel: "",
                                     sourceFolder: sourceFolder, destinationFolder: destinationFolder, sources: [FileItem.compareKey(name): false],
                                     firstItem: nil, linkDescription: "")
            center.insertStartingForSelfCheck(job)
            let observer = TransferObserverBridge(jobID: job.id, center: center)
            observer.transferIssue(TransferIssueInfo(id: 1, path: source, kind: .invalidName, message: "Invalid name",
                                                     existingSize: nil, incomingSize: UInt64(payload.count),
                                                     destinationFolder: destinationFolder.enginePath))
            observer.transferFinished(TransferSummaryInfo(filesCopied: 0, filesSkipped: 0, filesFailed: 1, bytes: 0,
                                                         elapsedMs: 1, renamed: [], error: nil))
            _ = await until(2) { center.job(job.id)?.finishedAt != nil }
            return center.issues.first { $0.jobID == job.id }
        }
        func commit(_ issue: PendingIssue?, as name: String) async -> Bool {
            guard let issue else { return false }
            app.renameSource(of: issue)
            guard await until(3, { (mainWindow?.firstResponder as? NSTextView)?.string == issue.name }),
                  let editor = mainWindow?.firstResponder as? NSTextView else { return false }
            editor.insertText(name, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            sendKey(36, "\r")
            return true
        }
        func matchesSource(_ path: String?, _ expected: String, direction: TransferDirection) -> Bool {
            guard let path else { return false }
            if direction == .fromDevice { return path == expected }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
        }
        func copied(_ source: String, from issue: PendingIssue?) async -> Bool {
            guard let issue, let original = center.job(issue.jobID)?.spec else { return false }
            return await until(5) {
                !center.issues.contains { $0.id == issue.id } && center.jobs.contains {
                    $0.spec.sources.count == 1 && matchesSource($0.spec.sources.first, source, direction: original.direction)
                        && $0.summary?.filesCopied == 1 && $0.spec.destination == original.destination
                        && $0.spec.verify == original.verify && $0.spec.cardSafeNames == original.cardSafeNames
                        && $0.spec.conflict == original.conflict && $0.spec.pendingSources == nil
                }
            }
        }
        func jobsDebug() -> String {
            center.jobs.filter { !baseline.contains($0.id) }.map { "\($0.spec.sources): \($0.state), \($0.filesCopied) copied" }
                .joined(separator: "; ")
        }
        demo.setPlugged(deviceID: deviceID, false)
        _ = await until(2) { app.session(for: deviceID) == nil }
        let connected = await reconnect()
        let name = "Trip\\notes.txt", uploadedName = "Trip notes.txt", downloadedName = "Notes from phone.txt"
        try? payload.write(to: folder.appendingPathComponent(name))
        let upload = await problem(name, direction: .toDevice)
        let committedUpload = await commit(upload, as: uploadedName)
        let uploaded = await copied(folder.appendingPathComponent(uploadedName).path, from: upload)
        check("Renaming a Mac source copies just the new path with the original destination and options "
              + "(connected: \(connected), committed: \(committedUpload), \(uploaded ? "copied" : jobsDebug()))",
              connected && committedUpload && uploaded)

        let download = await problem("Boarding pass.pdf", direction: .fromDevice)
        let committedDownload = await commit(download, as: downloadedName)
        let downloaded = await copied(DevicePath.join(deviceSource.enginePath, downloadedName), from: download)
        let downloadedPath = folder.appendingPathComponent(downloadedName).path
        check("Renaming a device source copies the renamed device file to the Mac "
              + "(committed: \(committedDownload), \(downloaded ? "copied" : jobsDebug()))",
              committedDownload && downloaded && FileManager.default.fileExists(atPath: downloadedPath))

        let offlineName = "Offline\\notes.txt", retryName = "Offline notes.txt"
        try? payload.write(to: folder.appendingPathComponent(offlineName))
        let offlineIssue = await problem(offlineName, direction: .toDevice)
        demo.setPlugged(deviceID: deviceID, false)
        let disconnected = await until(2) { app.session(for: deviceID) == nil }
        let committedOffline = await commit(offlineIssue, as: retryName)
        let retriedSource = folder.appendingPathComponent(retryName).path
        func pending() -> PendingIssue? { center.issues.first { $0.id == offlineIssue?.id } }
        let waiting = await until(3) {
            pending()?.renamedName == retryName && matchesSource(pending()?.retry?.source, retriedSource, direction: .toDevice)
        }
        check("Renaming while disconnected leaves a retry for the renamed file and queues no copy "
              + "(disconnected: \(disconnected), committed: \(committedOffline), waiting: \(waiting))",
              disconnected && committedOffline && waiting
              && !center.jobs.contains { $0.spec.sources.contains { matchesSource($0, retriedSource, direction: .toDevice) } })
        center.drawerTab = .attention
        center.drawerExpanded = true
        await wait(0.3)
        await captureAppearances("12-issue-renamed-disconnected", shot: shot)
        let reconnected = await reconnect()
        if reconnected, let issue = pending() { center.retry(issue) }
        let retried = await copied(retriedSource, from: offlineIssue)
        check("Try Again after reconnect copies the renamed file and clears its issue "
              + "(reconnected: \(reconnected), \(retried ? "copied" : jobsDebug()))", reconnected && retried)
    }

    private static func write(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Drives AppKit's dragging-destination calls (the views a real drag would reach) with a stand-in for
/// the dragging info, so drops into the table and the SwiftUI drop targets are checked end to end.
@MainActor
private final class SimulatedDrag {
    private let window: NSWindow
    private let info: SimulatedDraggingInfo
    private var current: NSView?

    init(window: NSWindow, pasteboard: NSPasteboard, source: AnyObject?) {
        self.window = window
        info = SimulatedDraggingInfo(window: window, pasteboard: pasteboard, source: source)
    }

    /// The view a drag at `point` (window coordinates) is delivered to, found the way AppKit does: the
    /// frontmost, deepest visible view under the point registered for one of the dragged types (not by
    /// hit-testing: SwiftUI's drop targets are registered views that don't take clicks).
    private func destination(at point: NSPoint) -> NSView? {
        let types = (info.draggingPasteboard.types ?? []).compactMap { UTType($0.rawValue) }
        // Registered types match by conformance (SwiftUI registers "public.data" and "public.item").
        func accepts(_ view: NSView) -> Bool {
            view.registeredDraggedTypes.contains { registered in
                guard let type = UTType(registered.rawValue) else { return false }
                return types.contains { $0.conforms(to: type) }
            }
        }
        func search(_ view: NSView) -> NSView? {
            guard !view.isHiddenOrHasHiddenAncestor, view.alphaValue > 0,
                  view.convert(view.bounds, to: nil).contains(point) else { return nil }
            for child in view.subviews.reversed() {
                if let found = search(child) { return found }
            }
            return accepts(view) ? view : nil
        }
        return window.contentView?.superview.flatMap(search)
    }

    /// Like AppKit, only sends what the destination implements (the methods are optional).
    private func implements(_ view: NSView, _ selector: Selector) -> Bool { view.responds(to: selector) }

    private func exit(_ view: NSView?) {
        guard let view, implements(view, #selector(NSView.draggingExited(_:))) else { return }
        view.draggingExited(info)
    }

    @discardableResult
    func move(to point: NSPoint) -> NSDragOperation {
        info.draggingLocation = point
        let target = destination(at: point)
        guard let target else {
            exit(current)
            current = nil
            return []
        }
        if target !== current {
            exit(current)
            current = target
            return implements(target, #selector(NSView.draggingEntered(_:))) ? target.draggingEntered(info) : []
        }
        return implements(target, #selector(NSView.draggingUpdated(_:))) ? target.draggingUpdated(info) : []
    }

    func drop() -> Bool {
        guard let target = current else { return false }
        current = nil
        defer { if implements(target, #selector(NSView.draggingEnded(_:))) { target.draggingEnded(info) } }
        if implements(target, #selector(NSView.prepareForDragOperation(_:))), !target.prepareForDragOperation(info) { return false }
        guard implements(target, #selector(NSView.performDragOperation(_:))), target.performDragOperation(info) else { return false }
        if implements(target, #selector(NSView.concludeDragOperation(_:))) { target.concludeDragOperation(info) }
        return true
    }

    func cancel() {
        exit(current)
        current = nil
    }
}

private final class SimulatedDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    var draggingLocation = NSPoint.zero
    var draggingSourceOperationMask: NSDragOperation { draggingSource == nil ? [.copy, .generic] : [.copy, .move] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingSequenceNumber = Int.random(in: 1_000...1_000_000)
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(window: NSWindow, pasteboard: NSPasteboard, source: AnyObject?) {
        draggingDestinationWindow = window
        draggingPasteboard = pasteboard
        draggingSource = source
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let objects = draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        var stop: ObjCBool = false
        for (index, object) in objects.enumerated() {
            guard let writer = object as? NSPasteboardWriting else { continue }
            block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
            if stop.boolValue { break }
        }
    }
    func resetSpringLoading() {}
}

/// A backend that isn't the demo one (the decision to show Sync only looks at the type).
private final class StubDeviceService: DeviceService, @unchecked Sendable {
    var version: String { "self-check" }
    func listDevices() throws -> [DeviceRef] { [] }
    func open(deviceID: String) throws -> any DeviceConnection { throw DeviceServiceError.noDevice }
    func setEventObserver(_ observer: any DeviceEventObserving) {}
    func accessState(deviceID: String) -> DeviceAccessState { .unknown }
    func releaseSystemHold(deviceID: String) throws {}
    func restoreSystemHold() throws {}
    func listADBOnlyDevices() throws -> [ADBOnlyDeviceRef] { [] }
    func setADBOnlyDeviceObserver(_ observer: any ADBOnlyDeviceObserving) { observer.adbOnlyDevicesChanged([]) }
    func adbAccess(deviceID: String) -> DeviceADBAccess { .off }
    func setUSBMode(deviceID: String, mode: DeviceUSBMode) throws -> USBModeSwitchResult { throw DeviceServiceError.noDevice }
}

/// Self-check stand-in for the core's transfer handle: records answers.
private final class RecordingControl: TransferControl, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var answers: [String] { lock.withLock { recorded } }

    func pause() {}
    func resume() {}
    func cancel() {}
    func resolve(issueID: UInt64, choice: ConflictResolution) {
        lock.withLock { recorded.append("\(issueID):\(choice)") }
    }
}
extension View {
    @ViewBuilder
    func snapshotFrame(_ element: DebugSnapshots.LayoutElement?) -> some View {
        if let element, ProcessInfo.processInfo.environment["REMTP_SNAPSHOT_DIR"] != nil {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                DebugSnapshots.layoutFrames[element] = frame
            }
            .onDisappear { DebugSnapshots.layoutFrames.removeValue(forKey: element) }
        } else {
            self
        }
    }
}
#endif
