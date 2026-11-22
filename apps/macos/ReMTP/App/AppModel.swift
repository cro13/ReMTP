import AppKit
import Observation
import Quartz
import SwiftUI

struct MacPlace: Identifiable, Hashable {
    var id: URL { url }
    var url: URL
    var title: String
    var systemImage: String
}

enum SidebarItem: Hashable {
    case storage(String, UInt32)
    case device(String)
    case adbOnly(String)
    case mac(URL)
    case syncPair(String)
    case known(String)
}

private struct USBModeChange {
    let token = UUID()
    var sourceID: String
    var name: String
    var mode: DeviceUSBMode
    var adbOnlyDevice: ADBOnlyDeviceRef? = nil
    var targetID: String? = nil
}

/// App state and every user action. Views read it; menus, toolbar and tables call into it.
@Observable
@MainActor
final class AppModel {
    @ObservationIgnored let service: any DeviceService
    let macPane = PaneModel(kind: .mac)
    let devicePane = PaneModel(kind: .device)
    let transfers = TransferCenter()
    /// Known devices and device names. Demo runs keep theirs in `AppDefaults.demoSuiteName`.
    @ObservationIgnored let known: KnownDevices
    /// Where app settings go (view modes): `AppDefaults.demoSuiteName` in demo runs, the standard domain otherwise.
    @ObservationIgnored let defaults: UserDefaults

    var devices: [DeviceSession] = []
    private(set) var adbOnlyDevices: [ADBOnlyDeviceRef] = []
    private var usbModeChange: USBModeChange?
    private var fileTransferProblem: (device: ADBOnlyDeviceRef, message: String, manualSteps: Bool, waitingForReturn: Bool)?
    static let chargingOnEjectKey = "chargingOnlyOnEject.v1"
    private var chargingOnEject: Set<String> = []
    /// The device the device pane is showing (it may be held, ejected or gone).
    var shownDeviceID: String?
    var knownVersion = 0
    var activeKind: PaneKind = .mac
    var swapped = false
    var inspectorVisible = false
    /// True while one of the file tables is first responder (enables list-only shortcuts).
    var tableFocused = false
    var syncPreview: SyncPairDemo?
    /// Devices ReMTP freed from ptpcamerad (`releaseSystemHold`) whose session is still in use. When the
    /// last one is ejected or unplugged and no release is in flight, ptpcamerad gets the USB connection back.
    @ObservationIgnored private var releasedDevices: Set<String> = []
    @ObservationIgnored private var releasesInFlight = 0
    /// A release ran since ptpcamerad was last restored (it may have paused ptpcamerad even if it failed).
    @ObservationIgnored private var systemHoldMayBePaused = false
    /// Session closes of released devices that the next restore waits for.
    @ObservationIgnored private var closesBeforeRestore: [Task<Void, Never>] = []
    /// The latest restore. Releases wait for it, so pausing and restoring ptpcamerad never overlap.
    @ObservationIgnored private var systemHoldRestore: Task<Void, Never>?
    /// Quit cleanup started / finished (sessions closed, ptpcamerad restored).
    @ObservationIgnored private(set) var isShuttingDown = false
    @ObservationIgnored private(set) var isShutDown = false
    @ObservationIgnored private var shutdownWaiters: [() -> Void] = []

    let macPlaces: [MacPlace]

    /// DEBUG ONLY: true while `REMTP_SNAPSHOT_SCREENS` renders the documentation screens (design/app-shots.sh).
    /// Those screens run the demo backend but show the app as it ships: no Sync, no DEMO badge, and the
    /// home folder as "Home" rather than the account's name. Always false in Release builds and with the
    /// real backend.
    let presentsAsShipping: Bool

    /// The home folder's title in the sidebar and the path bar: its name (the account's), or "Home" in
    /// the documentation screens.
    var homeTitle: String {
        presentsAsShipping ? "Home" : FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.lastPathComponent
    }

    init(service: any DeviceService) {
        self.service = service
        let demo = service is DemoDeviceService
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        presentsAsShipping = demo && env["REMTP_SNAPSHOT_DIR"] != nil && env["REMTP_SNAPSHOT_SCREENS"] != nil
        #else
        presentsAsShipping = false
        #endif
        defaults = AppDefaults.store(demo: demo)
        known = KnownDevices(defaults: defaults)
        chargingOnEject = Set(defaults.stringArray(forKey: Self.chargingOnEjectKey) ?? [])
        if demo { known.migrateDemoID(from: DemoDeviceService.legacyGalaxyID, to: DemoDeviceService.galaxyID) }
        // Older demo runs and self-checks wrote their simulated devices into the real app's defaults.
        if !demo, known.purge(DemoDeviceService.deviceIDs) {
            NSLog("ReMTP: removed demo devices from the known devices")
        }
        let fm = FileManager.default
        func place(_ directory: FileManager.SearchPathDirectory, _ title: String, _ image: String) -> MacPlace? {
            fm.urls(for: directory, in: .userDomainMask).first.map { MacPlace(url: $0.standardizedFileURL, title: title, systemImage: image) }
        }
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL
        macPlaces = [
            place(.desktopDirectory, "Desktop", "menubar.dock.rectangle"),
            place(.documentDirectory, "Documents", "doc"),
            place(.downloadsDirectory, "Downloads", "arrow.down.circle"),
            place(.picturesDirectory, "Pictures", "photo"),
            place(.musicDirectory, "Music", "music.note"),
            place(.moviesDirectory, "Movies", "film"),
        ].compactMap { $0 } + [MacPlace(url: home, title: presentsAsShipping ? "Home" : home.lastPathComponent, systemImage: "house")]
        macPane.app = self
        devicePane.app = self
        transfers.app = self
        for pane in [macPane, devicePane] {
            if let raw = defaults.string(forKey: Self.viewModeKey(pane.kind)), let mode = PaneViewMode(rawValue: raw) {
                pane.viewMode = mode
            }
        }
    }

    var isDemo: Bool { service is DemoDeviceService }
    var demoService: DemoDeviceService? { service as? DemoDeviceService }

    /// Sync (the toolbar button, Transfer › Sync…, the sidebar's sync pairs) previews placeholder data: the
    /// sync engine doesn't exist yet. Only the demo backend shows it (not in the documentation screens).
    static func showsSync(for service: any DeviceService) -> Bool { service is DemoDeviceService }
    var showsSync: Bool { Self.showsSync(for: service) && !presentsAsShipping }
    /// The DEMO badge next to Devices (and the demo note in the transfer drawer's help).
    var showsDemoBadge: Bool { isDemo && !presentsAsShipping }

    // MARK: View modes

    static func viewModeKey(_ kind: PaneKind) -> String { "viewMode.\(kind.rawValue)" }

    /// List, columns or icons for `pane` (default: the active pane), remembered per pane.
    func setViewMode(_ mode: PaneViewMode, for pane: PaneModel? = nil) {
        let pane = pane ?? activePane
        guard pane.viewMode != mode else { return }
        // The old view goes away: if it had the keyboard focus, the new one takes it.
        let hadFocus = tableFocused && activeKind == pane.kind
        pane.viewMode = mode
        defaults.set(mode.rawValue, forKey: Self.viewModeKey(pane.kind))
        if hadFocus {
            DispatchQueue.main.async { pane.bridge.focus() }
        }
    }

    // MARK: Startup

    @ObservationIgnored private var started = false
    @ObservationIgnored private var listedDevices = false

    func start() {
        guard !started else { return }
        started = true
        let bridge = DeviceEventBridge(app: self)
        macPane.navigate(to: .mac(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL), recordHistory: false)
        let service = self.service
        Task {
            do {
                let refs = try await offMain {
                    service.setEventObserver(bridge)
                    service.setADBOnlyDeviceObserver(bridge)
                    return try service.listDevices()
                }
                refs.filter { self.session(for: $0.id) == nil }.forEach { self.connect($0) }
            } catch {
                NSLog("ReMTP: listing devices failed: \(error.localizedDescription)")
            }
            self.listedDevices = true
            if self.shownDeviceID == nil { self.shownDeviceID = self.adbOnlyDevices.first?.id }
        }
    }

    /// Quit cleanup: stops transfers, closes every session, then restores ptpcamerad. The closes and the
    /// restore run off the main thread (closing waits for the request in flight) and are time-boxed, so
    /// quitting never hangs on a device. `completion` runs on the main thread when done, delivered through
    /// the main run loop so it also arrives while AppKit waits for `reply(toApplicationShouldTerminate:)`.
    func shutdown(completion: @escaping () -> Void) {
        if isShutDown { return completion() }
        shutdownWaiters.append(completion)
        guard !isShuttingDown else { return }
        isShuttingDown = true
        transfers.stopAll()
        let connections = devices.compactMap(\.connection)
        for session in devices { session.connection = nil }
        releasedDevices.removeAll()
        closesBeforeRestore.removeAll()
        systemHoldMayBePaused = false
        let service = self.service
        DispatchQueue.global(qos: .userInitiated).async {
            let closing = DispatchGroup()
            for connection in connections {
                DispatchQueue.global(qos: .userInitiated).async(group: closing) { connection.close() }
            }
            if closing.wait(timeout: .now() + 5) == .timedOut {
                NSLog("ReMTP: a device session didn’t close in time; quitting anyway")
            }
            // Always give ptpcamerad back if ReMTP paused it (a no-op otherwise).
            let restoring = DispatchGroup()
            DispatchQueue.global(qos: .userInitiated).async(group: restoring) {
                do {
                    try service.restoreSystemHold()
                } catch {
                    NSLog("ReMTP: restoring ptpcamerad failed: \(error.localizedDescription)")
                }
            }
            if restoring.wait(timeout: .now() + 3) == .timedOut { NSLog("ReMTP: restoring ptpcamerad timed out") }
            onMainRunLoop {
                MainActor.assumeIsolated { self.finishShutdown() }
            }
        }
    }

    private func finishShutdown() {
        isShutDown = true
        let waiters = shutdownWaiters
        shutdownWaiters = []
        waiters.forEach { $0() }
    }

    /// Closes a session off the main thread: the core finishes the request in flight first.
    @discardableResult
    private func closeInBackground(_ connection: (any DeviceConnection)?) -> Task<Void, Never>? {
        guard let connection else { return nil }
        return Task { await offMain { connection.close() } }
    }

    /// `id` no longer needs ptpcamerad out of the way (ejected or unplugged); `close` is its session closing.
    private func releasedDeviceDone(_ id: String, after close: Task<Void, Never>?) {
        guard releasedDevices.remove(id) != nil else { return }
        if let close { closesBeforeRestore.append(close) }
        restoreSystemHoldIfUnneeded()
    }

    /// Gives ptpcamerad back once nothing needs it paused: no device ReMTP released is still connected and
    /// no release is in flight. The decision is made here, synchronously, so each time the last one goes
    /// away exactly one restore is scheduled (deciding after an async close let two overlapping closes both
    /// restore, or a release in flight cancel the restore for good). The restore runs off the main thread
    /// once those devices' sessions have closed.
    private func restoreSystemHoldIfUnneeded() {
        guard systemHoldMayBePaused, releasedDevices.isEmpty, releasesInFlight == 0, !isShuttingDown else { return }
        systemHoldMayBePaused = false
        let closes = closesBeforeRestore
        closesBeforeRestore = []
        let service = self.service
        systemHoldRestore = Task {
            for close in closes { await close.value }
            do {
                try await offMain { try service.restoreSystemHold() }
            } catch {
                NSLog("ReMTP: restoring ptpcamerad failed: \(error.localizedDescription)")
            }
        }
    }

    #if DEBUG
    /// Self-check: waits until the pending session closes and the latest ptpcamerad restore are done.
    func systemHoldSettled() async {
        for close in closesBeforeRestore { await close.value }
        await systemHoldRestore?.value
    }
    #endif

    // MARK: Panes

    var activePane: PaneModel { pane(activeKind) }
    var inactivePane: PaneModel { pane(activeKind == .mac ? .device : .mac) }
    var leftPane: PaneModel { swapped ? devicePane : macPane }
    var rightPane: PaneModel { swapped ? macPane : devicePane }

    func pane(_ kind: PaneKind) -> PaneModel { kind == .mac ? macPane : devicePane }
    func other(_ pane: PaneModel) -> PaneModel { pane === macPane ? devicePane : macPane }

    func activate(_ kind: PaneKind, focus: Bool = false) {
        if activeKind != kind { activeKind = kind }
        if focus { pane(kind).bridge.focus() }
    }

    func switchPane() {
        activate(activeKind == .mac ? .device : .mac, focus: true)
    }

    func swapPanes() { swapped.toggle() }

    var searchText: String {
        get { activePane.filter }
        set { activePane.filter = newValue }
    }

    var windowTitle: String {
        if activeKind == .device, !devicePaneBrowsable {
            return shownChargingSwitchName ?? shownDeviceID.flatMap(displayName(forDevice:)) ?? "No Device"
        }
        return activePane.folderName
    }

    var windowSubtitle: String {
        if activeKind == .device, !devicePaneBrowsable {
            if shownChargingSwitchName != nil { return "Switching USB mode…" }
            if shownADBOnlyDevice != nil { return "Charging only" }
            switch shownSession?.phase {
            case .held?: return "Held by macOS"
            case .releasing?, .connecting?: return "Connecting…"
            case .ejected?: return "Ejected"
            case .failed?: return "Couldn’t connect"
            case .ready?, nil: return shownDeviceID == nil ? "" : "Not connected"
            }
        }
        return activePane.subtitle
    }

    // MARK: Devices

    var shownSession: DeviceSession? { shownDeviceID.flatMap(session(for:)) }

    var shownADBOnlyDevice: ADBOnlyDeviceRef? {
        adbOnlyDevices.first { $0.id == shownDeviceID }
            ?? (usbModeChange?.sourceID == shownDeviceID ? usbModeChange?.adbOnlyDevice : nil)
            ?? (fileTransferProblem?.device.id == shownDeviceID ? fileTransferProblem?.device : nil)
    }

    func session(for id: String) -> DeviceSession? { devices.first { $0.id == id } }

    func connection(for id: String) -> (any DeviceConnection)? {
        guard let session = session(for: id), session.phase == .ready else { return nil }
        return session.connection
    }

    /// Known devices that aren't connected right now.
    var disconnectedDevices: [KnownDevice] {
        _ = knownVersion
        let connected = Set(devices.map(\.id))
        let adbOnlyKeys = Set(adbOnlyDevices.compactMap { USBDeviceIdentity.serialKey(for: $0.id) })
        return known.all.values.filter { device in
            !connected.contains(device.id) && !(USBDeviceIdentity.serialKey(for: device.id).map(adbOnlyKeys.contains) ?? false)
        }.sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Opens a device. `reveal` shows it in the device pane (hot-plugged devices); otherwise it is only
    /// shown when the pane has no device yet.
    func connect(_ ref: DeviceRef, reveal: Bool = false) {
        guard !isShuttingDown, usbModeChange?.sourceID != ref.id else { return }
        let session: DeviceSession
        if let existing = self.session(for: ref.id) {
            session = existing
            session.ref = ref
        } else {
            session = DeviceSession(ref: ref, customName: known.customName(ref.id))
            let index = devices.firstIndex { $0.name.localizedStandardCompare(session.name) == .orderedDescending } ?? devices.endIndex
            devices.insert(session, at: index)
        }
        session.phase = .connecting
        session.releaseError = nil
        if reveal || shouldShowConnectedDevice { shownDeviceID = ref.id }
        let service = self.service
        // Alongside the open, not before it: without an adb server this is a USB handshake.
        Task {
            let adbAccess = await offMain { service.adbAccess(deviceID: ref.id) }
            guard self.session(for: ref.id) === session, !self.isShuttingDown else { return }
            session.adbAccess = adbAccess
        }
        session.opening = Task {
            do {
                let (connection, details) = try await offMain { () throws -> (any DeviceConnection, DeviceDetailsInfo) in
                    let connection = try service.open(deviceID: ref.id)
                    return (connection, try connection.details())
                }
                guard self.session(for: ref.id) === session, session.phase != .ejected, !self.isShuttingDown else {
                    // Unplugged, ejected or quitting meanwhile. Closed before this task ends: an eject waits for it.
                    await offMain { connection.close() }
                    return
                }
                session.connection = connection
                session.details = details
                session.ref = details.summary
                session.phase = .ready
                session.promptDismissed = false
                self.known.remember(details.summary, linkSpeed: details.linkSpeed)
                self.knownVersion &+= 1
                self.deviceBecameReady(session)
            } catch DeviceServiceError.deviceBusy(let holder) {
                let state = await offMain { service.accessState(deviceID: ref.id) }
                var process = holder
                var pid: UInt32?
                if case .heldBy(let p, let id) = state {
                    process = p
                    pid = id
                }
                guard self.session(for: ref.id) === session, session.phase != .ejected else { return }
                session.phase = .held(process: process, pid: pid)
                self.known.remember(ref, linkSpeed: nil)
                self.knownVersion &+= 1
                if self.known.autoRelease(ref.id), process.hasPrefix("ptpcamera") { self.release(session) }
            } catch {
                guard self.session(for: ref.id) === session, session.phase != .ejected else { return }
                session.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func deviceBecameReady(_ session: DeviceSession) {
        if shouldShowConnectedDevice { shownDeviceID = session.id }
        guard shownDeviceID == session.id else { return }
        if let loc = devicePane.location?.device, loc.deviceID == session.id, session.storage(loc.storageID) != nil {
            devicePane.reload()
        } else if let storage = session.storages.first {
            devicePane.navigate(to: .device(DeviceLocation(deviceID: session.id, storageID: storage.id, path: "/")),
                                recordHistory: false)
        }
    }

    private var shouldShowConnectedDevice: Bool {
        shownDeviceID == nil || (shownSession == nil && shownADBOnlyDevice == nil && shownChargingSwitchName == nil)
    }

    func deviceAdded(_ ref: DeviceRef) {
        guard !isShuttingDown else { return }
        if session(for: ref.id) == nil {
            connect(ref, reveal: shownADBOnlyDevice == nil && shownChargingSwitchName == nil)
        }
        completeUSBModeChangeIfPresent()
        selectLateFileTransferDeviceIfPresent()
    }

    func adbOnlyDevicesChanged(_ refs: [ADBOnlyDeviceRef]) {
        guard !isShuttingDown else { return }
        let previous = adbOnlyDevices
        adbOnlyDevices = refs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        completeUSBModeChangeIfPresent()
        if listedDevices && shownDeviceID == nil {
            shownDeviceID = adbOnlyDevices.first?.id
        } else if shownADBOnlyDevice == nil, previous.contains(where: { $0.id == shownDeviceID }) {
            shownDeviceID = devices.first(where: \.isReady)?.id ?? devices.first?.id ?? adbOnlyDevices.first?.id
            if let session = shownSession, session.isReady { deviceBecameReady(session) }
        }
    }

    /// Unplugged (possibly mid-transfer). The session is retired first so nothing new starts on it; its
    /// jobs fail, the device pane drops the listing, and the close runs off the main thread.
    func deviceRemoved(_ id: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        let session = devices.remove(at: index)
        let connection = session.connection
        session.connection = nil
        transfers.deviceDisconnected(id, name: session.name)
        releasedDeviceDone(id, after: closeInBackground(connection))
        if devicePane.location?.device?.deviceID == id { devicePane.invalidateListing() }
        knownVersion &+= 1
        if shownDeviceID == id, usbModeChange?.sourceID != id {
            if let next = devices.first(where: \.isReady) {
                shownDeviceID = next.id
                deviceBecameReady(next)
            } else if let next = adbOnlyDevices.first {
                shownDeviceID = next.id
            }
        }
    }

    func release(_ session: DeviceSession) {
        // Not while a release is already running for it.
        guard case .held(let process, let pid) = session.phase else { return }
        session.phase = .releasing(process: process, pid: pid)
        session.releaseError = nil
        let service = self.service
        let id = session.id
        let restore = systemHoldRestore
        releasesInFlight += 1
        systemHoldMayBePaused = true
        Task {
            defer {
                self.releasesInFlight -= 1
                // A restore held back while this release ran (or due because it failed) is decided now.
                self.restoreSystemHoldIfUnneeded()
            }
            await restore?.value
            do {
                try await offMain { try service.releaseSystemHold(deviceID: id) }
                self.releasedDevices.insert(id)
                guard self.session(for: id) === session, session.phase != .ejected else {
                    // Unplugged or ejected while ptpcamerad was being paused.
                    self.releasedDeviceDone(id, after: nil)
                    return
                }
                self.connect(session.ref, reveal: self.shownDeviceID == id)
            } catch {
                guard self.session(for: id) === session, session.phase != .ejected else { return }
                session.phase = .held(process: process, pid: pid)
                session.releaseError = error.localizedDescription
            }
        }
    }

    func eject(_ session: DeviceSession) {
        if session.adbAccess != .off && switchesToChargingOnEject(session) {
            switchToChargingOnly(session)
        } else if usbModeChange?.sourceID != session.id {
            _ = ejectSession(session)
        }
    }

    private func ejectSession(_ session: DeviceSession) -> Task<Void, Never>? {
        if transfers.activeJobs.contains(where: { $0.deviceID == session.id }) {
            showMessage("Transfers to \(session.name) are still running.",
                        detail: "Wait for them to finish or cancel them in the Transfers drawer, then eject.")
            return nil
        }
        let connection = session.connection
        let opening = session.opening  // still running if ejected while connecting; it closes what it opens
        session.connection = nil
        session.phase = .ejected
        if devicePane.location?.device?.deviceID == session.id { devicePane.invalidateListing() }
        let close = closeInBackground(connection)
        let closed = Task {
            await opening?.value
            await close?.value
        }
        releasedDeviceDone(session.id, after: closed)
        return closed
    }

    func reconnect(_ session: DeviceSession) {
        connect(session.ref, reveal: true)
    }

    // MARK: USB modes

    var switchingUSBMode: Bool { usbModeChange != nil }

    var shownChargingSwitchName: String? {
        guard let change = usbModeChange, change.mode == .chargingOnly, change.sourceID == shownDeviceID else { return nil }
        return change.name
    }

    func switchingToFileTransfer(_ id: String) -> Bool { usbModeChange?.adbOnlyDevice?.id == id }
    func fileTransferError(_ id: String) -> String? { fileTransferProblem?.device.id == id ? fileTransferProblem?.message : nil }
    /// Whether the failure for `id` should also say how to switch on the device itself.
    func fileTransferNeedsManualSteps(_ id: String) -> Bool { fileTransferProblem?.device.id == id && fileTransferProblem?.manualSteps == true }
    func canRetryFileTransfer(_ id: String) -> Bool { adbOnlyDevices.contains { $0.id == id } }

    func switchesToChargingOnEject(_ session: DeviceSession) -> Bool {
        USBDeviceIdentity.serialKey(for: session.id).map(chargingOnEject.contains) ?? false
    }

    func setSwitchToChargingOnEject(_ session: DeviceSession, _ on: Bool) {
        guard let key = USBDeviceIdentity.serialKey(for: session.id) else { return }
        if on { chargingOnEject.insert(key) } else { chargingOnEject.remove(key) }
        defaults.set(chargingOnEject.sorted(), forKey: Self.chargingOnEjectKey)
    }

    func switchToFileTransfer(_ device: ADBOnlyDeviceRef) {
        guard !switchingUSBMode, !isShuttingDown, canRetryFileTransfer(device.id) else { return }
        showDevice(device.id)
        fileTransferProblem = nil
        changeUSBMode(USBModeChange(sourceID: device.id, name: displayName(forDevice: device.id) ?? device.name,
                                    mode: .fileTransfer, adbOnlyDevice: device))
    }

    func switchToChargingOnly(_ session: DeviceSession) {
        guard !switchingUSBMode, !isShuttingDown, session.adbAccess != .off, self.session(for: session.id) === session else { return }
        if case .releasing = session.phase { return }
        guard let closed = ejectSession(session) else { return }
        changeUSBMode(USBModeChange(sourceID: session.id, name: session.name, mode: .chargingOnly), after: closed)
    }

    private func changeUSBMode(_ change: USBModeChange, after closed: Task<Void, Never>? = nil) {
        usbModeChange = change
        let service = self.service
        Task {
            await closed?.value
            guard !isShuttingDown else { return }
            do {
                let result = try await offMain { try service.setUSBMode(deviceID: change.sourceID, mode: change.mode) }
                guard !isShuttingDown else { return }
                switch result {
                case .switched(let id?):
                    usbModeChange?.targetID = id
                    completeUSBModeChangeIfPresent()
                    if usbModeChange != nil {
                        try? await Task.sleep(for: .seconds(5))
                        if !isShuttingDown, usbModeChange?.token == change.token { usbModeDeviceDidNotReturn(change) }
                    }
                case .switched(nil): usbModeDeviceDidNotReturn(change)
                case .needsApproval:
                    usbModeChangeFailed(change, detail: "Tap Allow on \(change.name) to allow USB debugging, then try again.")
                case .unavailable(let reason): usbModeChangeFailed(change, detail: reason, showManualSteps: true)
                }
            } catch {
                if !isShuttingDown { usbModeChangeFailed(change, detail: error.localizedDescription, showManualSteps: true) }
            }
        }
    }

    private func completeUSBModeChangeIfPresent() {
        guard let change = usbModeChange, let id = change.targetID else { return }
        switch change.mode {
        case .fileTransfer:
            guard session(for: id) != nil else { return }
            usbModeChange = nil
            showDevice(id)
        case .chargingOnly:
            guard adbOnlyDevices.contains(where: { $0.id == id }) else { return }
            usbModeChange = nil
            if shownDeviceID == change.sourceID { shownDeviceID = id }
        }
    }

    private func usbModeDeviceDidNotReturn(_ change: USBModeChange) {
        usbModeChangeFailed(change, detail: "\(change.name) didn’t come back yet. Check its screen; it may need unlocking.",
                            waitingForReturn: true)
        selectLateFileTransferDeviceIfPresent()
    }

    private func selectLateFileTransferDeviceIfPresent() {
        guard let problem = fileTransferProblem, problem.waitingForReturn, shownDeviceID == problem.device.id,
              let key = USBDeviceIdentity.serialKey(for: problem.device.id),
              let target = devices.first(where: { USBDeviceIdentity.serialKey(for: $0.id) == key }) else { return }
        fileTransferProblem = nil
        showDevice(target.id)
    }

    private func usbModeChangeFailed(_ change: USBModeChange, detail: String, showManualSteps: Bool = false,
                                     waitingForReturn: Bool = false) {
        usbModeChange = nil
        if let device = change.adbOnlyDevice {
            fileTransferProblem = (device, detail, showManualSteps, waitingForReturn)
        } else {
            showMessage("Couldn’t switch \(change.name) to charging only.", detail: detail)
        }
    }

    func setAutoRelease(_ session: DeviceSession, _ on: Bool) {
        known.setAutoRelease(session.id, ref: session.ref, on)
        knownVersion &+= 1
    }

    func forget(_ id: String) {
        known.forget(id)
        session(for: id)?.customName = nil
        // The device pane was showing it as not connected: show another device, or none.
        if shownDeviceID == id, session(for: id) == nil {
            if let next = devices.first(where: \.isReady) {
                shownDeviceID = next.id
                deviceBecameReady(next)
            } else {
                shownDeviceID = devices.first?.id
            }
        }
        knownVersion &+= 1
    }

    // MARK: Device names

    /// The name shown for a device: the user's name for it, else its own (connected or remembered).
    func displayName(forDevice id: String) -> String? {
        _ = knownVersion
        if let session = session(for: id) { return session.name }
        if let device = shownADBOnlyDevice, device.id == id { return known.customName(matchingUSBDevice: id) ?? device.name }
        if let device = adbOnlyDevices.first(where: { $0.id == id }) { return known.customName(matchingUSBDevice: id) ?? device.name }
        return known.customName(id) ?? known.all[id]?.name
    }

    /// The device's own name (what it reports), for placeholders and "reset".
    func ownName(forDevice id: String) -> String? {
        session(for: id)?.ref.name ?? known.all[id]?.name
    }

    /// Sets the name shown for a device. Empty (or the device's own name) goes back to the device's name.
    func renameDevice(_ id: String, to name: String) {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == ownName(forDevice: id) { trimmed = "" }
        known.setCustomName(trimmed, for: id)
        session(for: id)?.customName = known.customName(id)
        knownVersion &+= 1
    }

    /// "Rename…" in the sidebar.
    func promptRenameDevice(_ id: String) {
        guard let current = displayName(forDevice: id) else { return NSSound.beep() }
        let own = ownName(forDevice: id) ?? current
        let alert = NSAlert()
        alert.messageText = "Rename “\(current)”"
        alert.informativeText = "The name is only used in ReMTP. Leave it empty to use the device’s own name, “\(own)”."
        let field = NSTextField(string: current)
        field.placeholderString = own
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        presentAlert(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.renameDevice(id, to: field.stringValue)
        }
    }

    func refreshDetails(_ session: DeviceSession) {
        guard let connection = session.connection else { return }
        Task {
            if let details = try? await offMain({ try connection.details() }) {
                session.details = details
            }
        }
    }

    // MARK: Sidebar navigation

    var sidebarSelection: SidebarItem? {
        get {
            switch activeKind {
            case .device:
                if let loc = devicePane.location?.device, loc.deviceID == shownDeviceID, shownSession?.isReady == true {
                    return .storage(loc.deviceID, loc.storageID)
                }
                if let device = shownADBOnlyDevice { return .adbOnly(device.id) }
                return shownDeviceID.map(SidebarItem.device)
            case .mac:
                guard let url = macPane.location?.macURL?.standardizedFileURL else { return nil }
                return macPlaces.first { $0.url == url }.map { .mac($0.url) }
            }
        }
        set {
            switch newValue {
            case .storage(let device, let storage)?: showStorage(deviceID: device, storageID: storage)
            case .device(let device)?, .adbOnly(let device)?: showDevice(device)
            case .mac(let url)?: showMacFolder(url)
            case .syncPair(let id)?: if showsSync { syncPreview = SyncPreviewDemo.pair(id) }
            case .known, nil: break
            }
        }
    }

    func showStorage(deviceID: String, storageID: UInt32) {
        shownDeviceID = deviceID
        if session(for: deviceID)?.isReady == true {
            let current = devicePane.location?.device
            if current?.deviceID != deviceID || current?.storageID != storageID {
                devicePane.navigate(to: .device(DeviceLocation(deviceID: deviceID, storageID: storageID, path: "/")))
            }
        }
        activate(.device, focus: true)
    }

    func showDevice(_ id: String) {
        shownDeviceID = id
        if let session = session(for: id), session.isReady, devicePane.location?.device?.deviceID != id,
           let storage = session.storages.first {
            devicePane.navigate(to: .device(DeviceLocation(deviceID: id, storageID: storage.id, path: "/")))
        }
        activate(.device, focus: shownADBOnlyDevice == nil)
    }

    func showMacFolder(_ url: URL) {
        macPane.navigate(to: .mac(url))
        activate(.mac, focus: true)
    }

    /// Whether the device pane currently shows a browsable listing.
    var devicePaneBrowsable: Bool {
        guard let session = shownSession, session.isReady, let loc = devicePane.location?.device else { return false }
        return loc.deviceID == session.id
    }

    // MARK: Compare

    /// "On Galaxy S23" / "On Mac".
    func otherSideName(for pane: PaneModel) -> String {
        pane.kind == .mac ? (shownSession?.name ?? "Device") : "Mac"
    }

    func status(for item: FileItem, in pane: PaneModel) -> ItemStatus {
        // The open folder itself (a row of the column before it) isn't in the folders being compared.
        if pane.openFolderItem != nil, pane.isOpenFolder(item) { return .none }
        if let location = pane.location, let transfer = transfers.sourceStatus(for: item, in: location) { return transfer }
        let other = other(pane)
        guard other.hasListing, other.kind == .mac || devicePaneBrowsable, pane.kind == .device || devicePaneBrowsable else {
            return .none
        }
        guard let match = other.index[item.compareKey] else { return pane.kind == .mac ? .notOnDevice : .notOnMac }
        if match.isBrowsable != item.isBrowsable { return .differs }
        if item.isBrowsable { return .folderOnBoth }
        return match.size == item.size ? .same : .differs
    }

    /// Changes whenever statuses in `pane` may have changed.
    /// "Not in “View check” on this Mac". Statuses compare `pane`'s folder with the folder open in the other
    /// pane, not with the whole other side, and the wording says so.
    func missingText(in pane: PaneModel) -> String {
        "Not \(otherFolderText(for: pane))"
    }

    /// The status in words, for tooltips and VoiceOver.
    func statusText(_ status: ItemStatus, in pane: PaneModel) -> String? {
        switch status {
        case .none: return nil
        case .notOnDevice, .notOnMac: return missingText(in: pane)
        case .same: return "Same \(otherFolderText(for: pane))"
        case .differs: return "Different \(otherFolderText(for: pane))"
        case .folderOnBoth: return "Also \(otherFolderText(for: pane)); the contents aren’t compared"
        case .queued, .copying, .copyingFolder, .arriving: return status.look?.text
        }
    }

    @ObservationIgnored private var overlapCache: (mac: Int, device: Int, overlaps: Bool)?

    /// Whether `pane`'s folder and the folder open in the other pane have any name in common. When they
    /// don't, the panes show unrelated folders and "not in the other folder" tells the user nothing.
    func foldersOverlap(_ pane: PaneModel) -> Bool {
        let mac = macPane.contentGeneration
        let device = devicePane.contentGeneration
        if let cached = overlapCache, cached.mac == mac, cached.device == device {
            return cached.overlaps
        }
        let otherIndex = other(pane).index
        let overlaps = pane.index.keys.contains { otherIndex[$0] != nil }
        overlapCache = (mac, device, overlaps)
        return overlaps
    }

    /// "in “View check” on this Mac"
    func otherFolderText(for pane: PaneModel) -> String {
        let side = pane.kind == .mac ? (shownSession?.name ?? "the device") : "this Mac"
        return "in “\(other(pane).folderName)” on \(side)"
    }

    func statusToken(for pane: PaneModel) -> Int {
        let other = other(pane)
        return other.contentGeneration &* 1_000_003 &+ transfers.statusGeneration &+ (devicePaneBrowsable ? 7 : 0)
    }

    // MARK: Commands

    var canCopy: Bool {
        devicePaneBrowsable && !activePane.targetItems.isEmpty && macPane.location != nil
    }

    func open(_ item: FileItem, in pane: PaneModel) {
        if item.isBrowsable, let location = pane.location(of: item) {
            pane.navigate(to: location)
        } else if let url = item.url {
            NSWorkspace.shared.open(url)
        } else {
            offerCopyToMac(item, from: pane)
        }
    }

    /// A device file can't be opened where it is: offers to copy it into the Mac pane's folder.
    private func offerCopyToMac(_ item: FileItem, from pane: PaneModel) {
        let alert = NSAlert()
        alert.messageText = "“\(item.name)” is on \(shownSession?.name ?? "the device")."
        alert.informativeText = "Copy it to the Mac to open it. The copy goes into “\(macPane.folderName)”, the folder open in the Mac pane."
        alert.addButton(withTitle: "Copy to Mac")
        alert.addButton(withTitle: "Cancel")
        presentAlert(alert) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.copy([item], from: pane, into: self.macPane.location)
        }
    }

    func openSelection() {
        let pane = activePane
        let items = pane.targetItems
        guard !items.isEmpty else { return NSSound.beep() }
        // Columns: the open folder is already open; go into its column.
        if items.count == 1, pane.isOpenFolder(items[0]) {
            if let enter = pane.bridge.enterOpenFolder { enter() } else { pane.bridge.focus() }
            return
        }
        if items.count == 1 { return open(items[0], in: pane) }
        let urls = items.compactMap { $0.isBrowsable ? nil : $0.url }
        if !urls.isEmpty { urls.forEach { NSWorkspace.shared.open($0) } } else { NSSound.beep() }
    }

    func goUp() { activePane.goUp() }
    func goBack() { activePane.goBack() }
    func goForward() { activePane.goForward() }

    func goHome() {
        showMacFolder(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
    }

    func refresh() {
        let pane = activePane
        if let loc = pane.location?.device, let session = session(for: loc.deviceID), let connection = session.connection {
            Task {
                await offMain { connection.invalidate(storageID: loc.storageID, path: loc.path) }
                pane.reload()
            }
            refreshDetails(session)
        } else {
            pane.reload()
        }
    }

    func toggleInspector() { inspectorVisible.toggle() }

    /// Opens the Transfers drawer on `tab` (by default the tab with something in it), or closes it.
    func showTransfers(_ show: Bool = true, tab: DrawerTab? = nil) {
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .snappy(duration: 0.2)) {
            if !show {
                transfers.drawerExpanded = false
            } else if let tab {
                transfers.drawerTab = tab
                transfers.drawerExpanded = true
            } else {
                transfers.showDrawer()
            }
        }
    }

    /// Sync preview for the shown device's pair (placeholder data, see SyncPreviewDemo). Demo backend only.
    func openSync() {
        guard showsSync else { return }
        let name = shownSession?.ref.name
        syncPreview = SyncPreviewDemo.pairs.first { $0.available && $0.deviceName == name } ?? SyncPreviewDemo.pairs.first
    }

    func toggleHiddenFiles() {
        activePane.showHidden.toggle()
    }

    func newFolder() {
        let pane = activePane
        switch pane.location {
        case .mac(let url):
            Task {
                do {
                    let created = try await offMain { try LocalFileSystem.createFolder(in: url) }
                    pane.navigateSelectAndRename(created.lastPathComponent)
                } catch {
                    self.showError("Couldn’t create a folder.", error)
                }
            }
        case .device(let loc):
            guard let connection = connection(for: loc.deviceID) else { return NSSound.beep() }
            var name = "untitled folder"
            var n = 2
            while pane.item(named: name) != nil {
                name = "untitled folder \(n)"
                n += 1
            }
            let path = DevicePath.join(loc.path, name)
            let finalName = name
            Task {
                do {
                    try await offMain { try connection.createFolder(storageID: loc.storageID, path: path) }
                    pane.navigateSelectAndRename(finalName)
                } catch {
                    self.showError("Couldn’t create a folder on the device.", error)
                }
            }
        case nil:
            NSSound.beep()
        }
    }

    func beginRename() {
        let pane = activePane
        guard let item = pane.targetItems.first, pane.targetItems.count == 1 else { return NSSound.beep() }
        pane.bridge.beginRename?(item.name, nil)
    }

    func renameSource(of issue: PendingIssue) {
        guard let source = issue.renameSource, let job = transfers.job(issue.jobID), !job.isPromise else { return }
        let folder: PaneLocation
        let name: String
        let pane: PaneModel
        switch issue.direction {
        case .toDevice:
            let url = URL(fileURLWithPath: source)
            name = url.lastPathComponent
            folder = .mac(url.deletingLastPathComponent().standardizedFileURL)
            pane = macPane
        case .fromDevice:
            guard connection(for: job.deviceID) != nil else { return }
            name = DevicePath.lastComponent(source)
            folder = .device(DeviceLocation(deviceID: job.deviceID, storageID: job.spec.storageID, path: DevicePath.parent(source)))
            pane = devicePane
        }
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return }
        pane.filter = ""
        if name.hasPrefix(".") { pane.showHidden = true }
        activate(pane.kind)
        pane.navigateSelectAndRename(name, in: folder) { [weak self] path in
            self?.transfers.retryRenamedSource(of: issue, at: path)
        }
    }

    func rename(_ item: FileItem, to newName: String, in pane: PaneModel, onRenamed: RenameCompletion? = nil) {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name else { return }
        // Columns: renaming the open folder itself moves the pane along with it.
        let renamedLocation = pane.isOpenFolder(item) ? pane.renamedOpenFolder(newName) : nil
        func done(_ path: String) {
            if let renamedLocation {
                pane.navigate(to: renamedLocation, recordHistory: false)
            } else {
                pane.reloadSelecting(newName)
            }
            onRenamed?(path)
        }
        if let url = item.url {
            Task {
                do {
                    let renamed = try await offMain { try LocalFileSystem.rename(url, to: newName) }
                    done(renamed.path)
                } catch {
                    self.showError("Couldn’t rename “\(item.name)”.", error)
                }
            }
        } else if let path = item.devicePath, let loc = pane.location?.device, let connection = connection(for: loc.deviceID) {
            guard !newName.contains("/") else {
                return showMessage("“\(newName)” isn’t a valid name.", detail: "Names can’t contain “/”.")
            }
            Task {
                do {
                    try await offMain { try connection.rename(storageID: loc.storageID, path: path, newName: newName) }
                    done(DevicePath.join(DevicePath.parent(path), newName))
                } catch {
                    self.showError("Couldn’t rename “\(item.name)”.", error)
                }
            }
        }
    }

    func deleteSelection() {
        let pane = activePane
        let items = pane.targetItems
        guard !items.isEmpty else { return NSSound.beep() }
        // Columns: deleting the open folder itself leaves the pane in its parent.
        let parent = items.contains(where: pane.isOpenFolder) ? pane.parentLocation : nil
        func done() {
            if let parent { pane.navigate(to: parent, recordHistory: false) } else { pane.reload(quiet: true) }
        }
        switch pane.location {
        case .mac:
            let urls = items.compactMap(\.url)
            Task {
                do {
                    try await offMain { try LocalFileSystem.trash(urls) }
                    done()
                } catch {
                    self.showError("Couldn’t move the items to the Trash.", error)
                }
            }
        case .device(let loc):
            guard let session = session(for: loc.deviceID), let connection = session.connection else { return NSSound.beep() }
            // What the user is agreeing to delete, as it is now. Each item is checked against this again
            // right before it is deleted.
            let targets = items.compactMap { DeviceDeleteTarget($0, storageID: loc.storageID) }
            guard !targets.isEmpty else { return NSSound.beep() }
            let what = targets.count == 1 ? "“\(targets[0].name)”" : "\(targets.count) items"
            let alert = NSAlert()
            alert.messageText = "Delete \(what) from \(session.name)?"
            alert.informativeText = "This can’t be undone. \(session.name) has no Trash, so deleted files are gone for good."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            presentAlert(alert) { response in
                guard response == .alertFirstButtonReturn else { return }
                Task {
                    let outcome = await self.deleteOnDevice(targets, connection: connection)
                    if let message = outcome.report { self.showMessage(message.title, detail: message.detail) }
                    if parent != nil, outcome.deleted.isEmpty { pane.reload(quiet: true) } else { done() }
                    self.refreshDetails(session)
                }
            }
        case nil:
            NSSound.beep()
        }
    }

    /// Deletes `targets` off the main thread, each only if it still matches what was confirmed.
    func deleteOnDevice(_ targets: [DeviceDeleteTarget], connection: any DeviceConnection) async -> DeviceDeleteOutcome {
        await offMain { DeviceDeleteTarget.delete(targets, on: connection) }
    }

    func quickLook() {
        guard activeKind == .mac, !macPane.targetItems.isEmpty else { return NSSound.beep() }
        QuickLookController.shared.toggle(pane: macPane)
    }

    func copyPaths() {
        let items = activePane.targetItems
        let text = items.map { $0.url?.path ?? $0.devicePath ?? $0.name }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func showInFinder() {
        let urls = macPane.targetItems.compactMap(\.url)
        if urls.isEmpty, let url = macPane.location?.macURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    // MARK: Copying

    /// Where the active pane's selection would be copied: the device's name, or "Mac".
    var copyTargetName: String {
        activeKind == .mac ? (shownSession?.name ?? "Device") : "Mac"
    }

    /// An arrow pointing at the pane the files go to.
    var copyArrowSymbol: String {
        let targetIsRight = activeKind == .mac ? !swapped : swapped
        return targetIsRight ? "arrow.right" : "arrow.left"
    }

    /// The shortcut that copies the other pane's selection into `pane`: ⌘⇧→ when `pane` is on the right,
    /// ⌘⇧← when it is on the left, pointing the same way as the Copy button's arrow. F5 does the same, but
    /// on Apple keyboards it is Dictation unless fn is held, so this is the shortcut the UI teaches.
    func copyShortcut(into pane: PaneKind) -> String {
        let isRight = pane == .device ? !swapped : swapped
        return isRight ? "⌘⇧→" : "⌘⇧←"
    }

    /// The shortcut that copies the active pane's selection to the other pane.
    var copyShortcut: String { copyShortcut(into: activeKind == .mac ? .device : .mac) }

    /// The active pane's targets that an active transfer is already copying to the other pane's folder. Copying
    /// leaves them out; with nothing else to copy, the toolbar button shows "Copying N…".
    var copyTargetsInFlight: [FileItem] {
        let items = activePane.targetItems
        guard canCopy, let route = copyRoute(items, from: activePane) else { return [] }
        return transfers.inFlight(items, from: route.source, to: route.destination)
    }

    /// Where the transfer already copying the active pane's targets is going ("Mac › Pictures › Lisbon 2026").
    var copyInFlightDestination: String? {
        guard let route = copyRoute(activePane.targetItems, from: activePane) else { return nil }
        return transfers.activeJobs(from: route.source, to: route.destination).first?.destinationLabel
    }

    private func copyRoute(_ items: [FileItem], from pane: PaneModel) -> (source: PaneLocation, destination: PaneLocation)? {
        guard let source = pane.folder(containing: items), let destination = other(pane).location else { return nil }
        return (source, destination)
    }

    /// `items` without those an active transfer is already copying from `source` into `destination`. Nil when
    /// that is all of them: nothing is queued, and the drawer shows the transfer under way.
    private func notInFlight(_ items: [FileItem], from source: PaneLocation, to destination: PaneLocation) -> [FileItem]? {
        let inFlight = Set(transfers.inFlight(items, from: source, to: destination).map(\.compareKey))
        guard !inFlight.isEmpty else { return items }
        let pending = items.filter { !inFlight.contains($0.compareKey) }
        guard pending.isEmpty else { return pending }
        NSSound.beep()
        showTransfers()
        return nil
    }

    func copyToOtherPane() { copySelection(from: activePane) }
    func copyLeftToRight() { copySelection(from: leftPane) }
    func copyRightToLeft() { copySelection(from: rightPane) }

    func copySelection(from pane: PaneModel) {
        let items = pane.targetItems
        guard !items.isEmpty else { return NSSound.beep() }
        copy(items, from: pane, into: nil)
    }

    /// Queues a transfer of `items` (from `pane`'s current folder) into `destination` or the other pane's folder.
    func copy(_ items: [FileItem], from pane: PaneModel, into destination: PaneLocation?) {
        // Usually the open folder; its parent when the open folder itself is copied (columns view).
        guard let source = pane.folder(containing: items) else { return NSSound.beep() }
        switch pane.kind {
        case .mac:
            guard let session = shownSession, session.isReady else {
                return showMessage("No device to copy to.", detail: "Connect a device and pick a folder in the device pane.")
            }
            guard let loc = (destination ?? devicePane.location)?.device else { return NSSound.beep() }
            guard let items = notInFlight(items, from: source, to: .device(loc)) else { return }
            enqueueToDevice(urls: items.compactMap(\.url), items: items, sourceFolder: source, session: session, destination: loc)
        case .device:
            guard let loc = source.device, let session = session(for: loc.deviceID), session.isReady else { return NSSound.beep() }
            guard let folder = (destination ?? macPane.location)?.macURL else { return NSSound.beep() }
            guard let items = notInFlight(items, from: source, to: .mac(folder)) else { return }
            enqueueFromDevice(paths: items.compactMap(\.devicePath), items: items, source: loc, session: session, into: folder)
        }
    }

    private func macLabel(_ url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents.dropFirst()
        return parts.isEmpty ? LocalFileSystem.volumeName(url) : parts.suffix(2).joined(separator: " › ")
    }

    private func deviceLabel(_ session: DeviceSession, _ loc: DeviceLocation) -> String {
        let parts = DevicePath.components(loc.path)
        if parts.isEmpty { return "\(session.name) › \(session.storage(loc.storageID)?.description ?? "Storage")" }
        return ([session.name] + parts).joined(separator: " › ")
    }

    private func enqueueToDevice(urls: [URL], items: [FileItem], sourceFolder: PaneLocation, session: DeviceSession,
                                 destination: DeviceLocation) {
        guard !urls.isEmpty else { return NSSound.beep() }
        let removable = session.storage(destination.storageID)?.removable ?? false
        let spec = TransferJobSpec(direction: .toDevice, storageID: destination.storageID,
                                   sources: urls.map { $0.standardizedFileURL.path }, destination: destination.path,
                                   conflict: .ask, verify: .size, cardSafeNames: removable)
        let single = items.count == 1 ? " › \(items[0].name)" : ""
        let sourceName = sourceFolder.macURL.map { FileManager.default.displayName(atPath: $0.path) } ?? "Mac"
        let destLabel = deviceLabel(session, destination)
        let job = QueuedTransfer(
            spec: spec, deviceID: session.id, deviceName: session.name,
            route: "\(sourceName)\(single) → \(destLabel)\(items.count == 1 && items[0].isDirectory ? single : "")",
            destinationLabel: destLabel, sourceFolder: sourceFolder, destinationFolder: .device(destination),
            sources: Dictionary(items.map { ($0.compareKey, $0.isDirectory) }, uniquingKeysWith: { a, _ in a }),
            firstItem: items.first, linkDescription: session.linkDescription)
        transfers.enqueue(job)
    }

    /// `writeInto` (Finder promises) makes the core write somewhere other than `folder`, the folder the
    /// transfer is shown as going to.
    @discardableResult
    private func enqueueFromDevice(paths: [String], items: [FileItem], source: DeviceLocation, session: DeviceSession,
                                   into folder: URL, writeInto: URL? = nil, conflict: TransferConflictPolicy = .ask,
                                   onFinish: ((TransferSummaryInfo) -> Void)? = nil) -> UUID? {
        guard !paths.isEmpty else {
            NSSound.beep()
            return nil
        }
        let spec = TransferJobSpec(direction: .fromDevice, storageID: source.storageID, sources: paths,
                                   destination: (writeInto ?? folder).standardizedFileURL.path, conflict: conflict,
                                   verify: .size, cardSafeNames: false)
        let single = items.count == 1 ? " › \(items[0].name)" : ""
        let destLabel = "Mac › " + macLabel(folder)
        let sourceName = DevicePath.isRoot(source.path)
            ? (session.storage(source.storageID)?.description ?? session.name) : DevicePath.lastComponent(source.path)
        var job = QueuedTransfer(
            spec: spec, deviceID: session.id, deviceName: session.name,
            route: "\(session.name) › \(sourceName)\(single) → \(destLabel)\(items.count == 1 && items[0].isDirectory ? single : "")",
            destinationLabel: destLabel, sourceFolder: .device(source), destinationFolder: .mac(folder.standardizedFileURL),
            sources: Dictionary(items.map { ($0.compareKey, $0.isDirectory) }, uniquingKeysWith: { a, _ in a }),
            firstItem: items.first, linkDescription: session.linkDescription)
        if let onFinish { job.onFinish.append(onFinish) }
        transfers.enqueue(job)
        return job.id
    }

    func canCopyRemaining(_ job: QueuedTransfer) -> Bool {
        guard job.interruptedByDisconnect, !job.isActive, !job.isPromise, job.remainingFileCount != 0,
              let session = session(for: job.deviceID), session.isReady else { return false }
        return session.storage(job.spec.storageID) != nil
    }

    @discardableResult
    func copyRemaining(_ id: UUID) -> UUID? {
        guard let stopped = transfers.job(id), canCopyRemaining(stopped),
              let session = session(for: stopped.deviceID) else { return nil }
        var spec = stopped.spec
        if let pendingSources = stopped.pendingSources { spec.pendingSources = Array(pendingSources.values) }
        let continuation = QueuedTransfer(
            spec: spec, deviceID: stopped.deviceID, deviceName: session.name,
            route: stopped.route, destinationLabel: stopped.destinationLabel,
            sourceFolder: stopped.sourceFolder, destinationFolder: stopped.destinationFolder,
            sources: stopped.sources, firstItem: stopped.firstItem, linkDescription: session.linkDescription)
        return transfers.enqueueContinuation(continuation, of: id)
    }

    // MARK: Drag and drop

    /// What dropping `drag` into `destination` (a folder in `pane`) would do; empty if it isn't allowed.
    /// The device pane takes local files while it shows a folder of the shown device; the Mac pane takes
    /// device rows, Finder files (copied) and its own rows (moved, copied with Option). Moving or copying
    /// device rows within the device isn't supported by the core, and drops that would change nothing
    /// (items already in that folder) or put a folder inside itself are refused.
    func dropOperation(_ drag: DragPayload, into destination: PaneLocation, in pane: PaneModel) -> NSDragOperation {
        switch pane.kind {
        case .device:
            guard devicePaneBrowsable, let target = destination.device, let session = shownSession, target.deviceID == session.id,
                  session.storage(target.storageID) != nil, drag.source != .device, drag.deviceItems.isEmpty, !drag.urls.isEmpty
            else { return [] }
            return .copy
        case .mac:
            guard pane.location != nil, let folder = destination.macURL?.standardizedFileURL else { return [] }
            if let first = drag.deviceItems.first {
                return session(for: first.deviceID)?.isReady == true ? .copy : []
            }
            let sources = drag.urls.map(\.standardizedFileURL)
            guard !sources.isEmpty,
                  !sources.contains(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }),
                  sources.contains(where: { $0.deletingLastPathComponent().standardizedFileURL != folder })
            else { return [] }
            return drag.source == .mac && drag.allowsMove ? .move : .copy
        }
    }

    /// Drops `drag` into `destination`, a folder in `pane` (see `dropOperation`).
    @discardableResult
    func performDrop(_ drag: DragPayload, into destination: PaneLocation, in pane: PaneModel) -> Bool {
        let operation = dropOperation(drag, into: destination, in: pane)
        guard !operation.isEmpty else { return false }
        activate(pane.kind)
        if !drag.deviceItems.isEmpty { return dropDeviceItems(drag.deviceItems, onto: pane, into: destination) }
        return dropFiles(drag.urls, onto: pane, into: destination, move: operation.contains(.move))
    }

    /// A drag ended: both panes drop their drag hover state (drop bar, highlights).
    func dragEnded() {
        macPane.dragEnded()
        devicePane.dragEnded()
    }

    /// Files from Finder or the Mac pane dropped into `destination` (nil: the pane's open folder).
    func dropFiles(_ urls: [URL], onto pane: PaneModel, into destination: PaneLocation?, move: Bool) -> Bool {
        guard !urls.isEmpty else { return false }
        switch pane.kind {
        case .device:
            guard let session = shownSession, session.isReady, let loc = (destination ?? pane.location)?.device,
                  loc.deviceID == session.id else { return false }
            let parent = urls[0].deletingLastPathComponent().standardizedFileURL
            // A drop can mix folders (Finder search results, Recents): each item is checked against copies
            // already running from its own folder, so "A/photo.jpg" in flight doesn't drop "B/photo.jpg".
            // The drop's order is kept (the first item is the job's thumbnail).
            let all = urls.map(LocalFileSystem.item(for:))
            var keep = [Bool](repeating: true, count: all.count)
            for (folder, indices) in Dictionary(grouping: all.indices, by: { urls[$0].deletingLastPathComponent().standardizedFileURL }) {
                let inFlight = Set(transfers.inFlight(indices.map { all[$0] }, from: .mac(folder), to: .device(loc)).map(\.compareKey))
                for i in indices where inFlight.contains(all[i].compareKey) { keep[i] = false }
            }
            let items = all.indices.filter { keep[$0] }.map { all[$0] }
            guard !items.isEmpty else {
                NSSound.beep()
                showTransfers()
                return false
            }
            enqueueToDevice(urls: items.compactMap(\.url), items: items, sourceFolder: .mac(parent), session: session, destination: loc)
            return true
        case .mac:
            guard let target = (destination ?? pane.location)?.macURL else { return false }
            // Skip the target itself and items already in the target folder (a drop there is a no-op).
            let folder = target.standardizedFileURL
            let sources = urls.filter {
                $0.standardizedFileURL != folder && $0.deletingLastPathComponent().standardizedFileURL != folder
            }
            guard !sources.isEmpty else { return false }
            Task {
                do {
                    try await offMain {
                        if move { try LocalFileSystem.move(sources, into: target) } else { try LocalFileSystem.copy(sources, into: target) }
                    }
                    pane.reload(quiet: true)
                } catch {
                    self.showError(move ? "Couldn’t move the items." : "Couldn’t copy the items.", error)
                }
            }
            return true
        }
    }

    /// Device rows dropped on the Mac pane, into `destination` (nil: the pane's open folder).
    func dropDeviceItems(_ dragged: [DeviceDragItem], onto pane: PaneModel, into destination: PaneLocation?) -> Bool {
        guard pane.kind == .mac, let first = dragged.first, let session = session(for: first.deviceID), session.isReady,
              let target = (destination ?? pane.location)?.macURL else { return false }
        let source = DeviceLocation(deviceID: first.deviceID, storageID: first.storageID, path: DevicePath.parent(first.path))
        let dropped = dragged.map { FileItem.device($0.entry, folder: DevicePath.parent($0.path)) }
        guard let items = notInFlight(dropped, from: .device(source), to: .mac(target)) else { return false }
        enqueueFromDevice(paths: items.compactMap(\.devicePath), items: items, source: source, session: session, into: target)
        return true
    }

    /// Finder asked for a promised device file at exactly `url`. The core copies it into a private staging
    /// folder on the same volume; only a clean copy (nothing skipped, failed or renamed) is moved to `url`.
    /// The promise succeeds only if `url` exists afterwards; `completion` gets an error otherwise.
    func fulfillPromise(_ item: DeviceDragItem, to url: URL, completion: @escaping (Error?) -> Void) {
        let target = url.standardizedFileURL
        let folder = target.deletingLastPathComponent()
        Task {
            let staging: URL
            do {
                staging = try await offMain { try PromiseDelivery.makeStaging(for: target) }
            } catch {
                return completion(error)
            }
            guard let session = self.session(for: item.deviceID), session.isReady else {
                await offMain { PromiseDelivery.discard(staging) }
                return completion(DeviceServiceError.disconnected)
            }
            let source = DeviceLocation(deviceID: item.deviceID, storageID: item.storageID, path: DevicePath.parent(item.path))
            let staged = staging.appendingPathComponent(item.name)
            let id = self.enqueueFromDevice(
                paths: [item.path], items: [FileItem.device(item.entry, folder: source.path)], source: source,
                session: session, into: folder, writeInto: staging, conflict: .skip
            ) { summary in
                Task {
                    let error = await offMain { PromiseDelivery.settle(summary, staged: staged, to: target, staging: staging) }
                    completion(error)
                    if error == nil, self.macPane.location?.macURL?.standardizedFileURL == folder {
                        self.macPane.reload(quiet: true)
                    }
                }
            }
            if id == nil {
                await offMain { PromiseDelivery.discard(staging) }
                completion(DeviceServiceError.cancelled)
            }
        }
    }

    // MARK: Transfer bookkeeping

    func transferWrote(_ target: PaneLocation, bytes: UInt64, from source: PaneLocation) {
        let pane = target.macURL == nil ? devicePane : macPane
        let origin = other(pane)
        let original: FileItem?
        if let folder = origin.location, let path = source.relativeComponents(to: folder),
           path.count == 1, let name = path.first {
            original = origin.item(named: name)
        } else {
            original = nil
        }
        pane.recordTransferWrite(target, bytes: bytes, original: original)
    }

    func transferFinished(_ job: QueuedTransfer) {
        let pane = job.destinationFolder.macURL == nil ? devicePane : macPane
        if let location = pane.location, location.relativeComponents(to: job.destinationFolder) != nil {
            pane.reload(quiet: true)
        }
        for pane in [macPane, devicePane] { pane.bridge.folderChanged?(job.destinationFolder) }
        if let session = session(for: job.deviceID) { refreshDetails(session) }
    }

    // MARK: Alerts

    func presentAlert(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    func showMessage(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        presentAlert(alert) { _ in }
    }

    func showError(_ message: String, _ error: Error) {
        showMessage(message, detail: error.localizedDescription)
    }

    // MARK: Search field

    func focusSearch() {
        // No window is key or main while another app is active: then the window with the panes.
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? macPane.bridge.view?.window else { return }
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for sub in view.subviews { if let field = find(sub) { return field } }
            return nil
        }
        for item in window.toolbar?.items ?? [] {
            if let search = item as? NSSearchToolbarItem {
                search.beginSearchInteraction()
                if !(window.firstResponder is NSTextView) { window.makeFirstResponder(search.searchField) }
                return
            }
            if let view = item.view, let field = find(view) {
                window.makeFirstResponder(field)
                return
            }
        }
        if let frame = window.contentView?.superview, let field = find(frame) { window.makeFirstResponder(field) }
    }
}

extension PaneModel {
    func navigateSelectAndRename(_ name: String, in folder: PaneLocation? = nil, onRenamed: RenameCompletion? = nil) {
        if let folder, !folder.isSameFolder(as: location) {
            navigate(to: folder)
        } else {
            reload(quiet: true)
        }
        selectAfterReload(name, rename: true, onRenamed: onRenamed)
    }

    func reloadSelecting(_ name: String) {
        reload(quiet: true)
        selectAfterReload(name, rename: false, onRenamed: nil)
    }

    private func selectAfterReload(_ name: String, rename: Bool, onRenamed: RenameCompletion?) {
        let location = self.location
        Task { [weak self] in
            // Wait for the listing to contain the item, then select (and edit) it.
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, self.location == location else { return }
                if (!rename || self.bridge.beginRename != nil), self.items.contains(where: { $0.name == name }) {
                    self.selectAndReveal([name])
                    self.bridge.focus()
                    if rename { self.bridge.beginRename?(name, onRenamed) }
                    return
                }
            }
        }
    }
}

/// Hot-plug callbacks from the service, forwarded to the main actor.
final class DeviceEventBridge: DeviceEventObserving, ADBOnlyDeviceObserving, @unchecked Sendable {
    private weak var app: AppModel?

    init(app: AppModel) { self.app = app }

    func deviceAdded(_ device: DeviceRef) {
        onMain { [self] in app?.deviceAdded(device) }
    }

    func deviceRemoved(id: String) {
        onMain { [self] in app?.deviceRemoved(id) }
    }

    func adbOnlyDevicesChanged(_ devices: [ADBOnlyDeviceRef]) {
        onMain { [self] in app?.adbOnlyDevicesChanged(devices) }
    }
}
