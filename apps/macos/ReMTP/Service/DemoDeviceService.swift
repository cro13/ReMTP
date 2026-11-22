import Foundation

// DEMO ONLY. A realistic stand-in for the Rust core so the UI can be built before `remtp-ffi`
// exists. It implements the same `DeviceService` contract a `RustDeviceService` will implement;
// swapping it out happens in `DeviceServiceFactory` and touches no view code.
//
// What it simulates: two connected devices (Galaxy S23, SP3000) with in-memory file trees,
// latency on open/list, hot-plug events, a device held by `ptpcamerad`, and transfers with
// realistic speed (about 214 MB/s on USB 3, 38 MB/s on USB 2.0) and per-file device wait (~30 ms).
// Downloads to the Mac create sparse placeholder files of the right size (all zeros). Photos and videos
// have small generated thumbnails, like a phone's.

final class DemoDevice {
    var ref: DeviceRef
    let linkSpeed: String
    let linkSpeedMbps: UInt32
    let bytesPerSecond: Double
    let deviceWaitMs: Double
    var storages: [DemoStorage]
    var plugged = true
    var heldBy: (process: String, pid: UInt32)?
    /// Bumped on unplug/hold so stale sessions fail with `.disconnected`.
    var session = 0
    /// One session actor per device: transfers on the same device run one after another.
    let transferQueue: DispatchQueue

    init(ref: DeviceRef, linkSpeed: String, mbps: UInt32, bytesPerSecond: Double, deviceWaitMs: Double, storages: [DemoStorage]) {
        self.ref = ref
        self.linkSpeed = linkSpeed
        self.linkSpeedMbps = mbps
        self.bytesPerSecond = bytesPerSecond
        self.deviceWaitMs = deviceWaitMs
        self.storages = storages
        self.transferQueue = DispatchQueue(label: "demo.transfer.\(ref.id)", qos: .userInitiated)
    }

    func storage(_ id: UInt32) -> DemoStorage? { storages.first { $0.info.id == id } }
}

final class DemoStorage {
    var info: StorageRef
    let root: DemoNode

    init(info: StorageRef, root: DemoNode) {
        self.info = info
        self.root = root
    }

    func node(at path: String) -> DemoNode? {
        var node = root
        for part in DevicePath.components(path) {
            guard let next = node.child(part) else { return nil }
            node = next
        }
        return node
    }

    @discardableResult
    func makeFolders(_ path: String) -> DemoNode {
        var node = root
        for part in DevicePath.components(path) {
            node = node.folder(part, modified: DemoLibrary.now)
        }
        return node
    }

    func consume(_ bytes: UInt64) { info.freeBytes = info.freeBytes > bytes ? info.freeBytes - bytes : 0 }
    func reclaim(_ bytes: UInt64) { info.freeBytes = min(info.capacityBytes, info.freeBytes + bytes) }
}

final class DemoDeviceService: DeviceService, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var devices: [DemoDevice]
    private var observer: (any DeviceEventObserving)?
    private var adbOnlyObserver: (any ADBOnlyDeviceObserving)?
    private var releasedHolds: Set<String> = []

    static let legacyGalaxyID = "R5CW30ABCDE"
    static let galaxyID = "04e8:6860:\(legacyGalaxyID)"
    static let sp3000ID = "SP3K-0A1B2C3D"
    static let pixelID = "18d1:4ee2:DEMO-PIXEL8"
    static let pixelChargingID = "18d1:4ee7:DEMO-PIXEL8"
    private static let chargingIDs = [galaxyID: "04e8:6865:\(legacyGalaxyID)", pixelID: pixelChargingID]
    private var chargingOnly: Set<String> = [pixelID]
    private var switchingUSB: Set<String> = []
    /// Every id this backend uses. The real app drops known devices with these ids at launch (older demo
    /// runs wrote them into the real app's defaults).
    static let deviceIDs = Set([legacyGalaxyID, galaxyID, sp3000ID, pixelID] + Array(chargingIDs.values))

    init() {
        let galaxy = DemoDevice(
            ref: DeviceRef(id: Self.galaxyID, manufacturer: "Samsung", model: "SM-S911B", name: "Galaxy S23", serial: Self.legacyGalaxyID),
            linkSpeed: "USB 3.2 Gen 1", mbps: 5_000, bytesPerSecond: 214_000_000, deviceWaitMs: 30,
            storages: [DemoStorage(
                info: StorageRef(id: 0x0001_0001, description: "Internal storage", capacityBytes: 256 * DemoLibrary.GB,
                                 freeBytes: 182 * DemoLibrary.GB, removable: false),
                root: DemoLibrary.galaxyInternal())])
        let sp3000 = DemoDevice(
            ref: DeviceRef(id: Self.sp3000ID, manufacturer: "Astell&Kern", model: "SP3000", name: "SP3000", serial: Self.sp3000ID),
            linkSpeed: "USB 2.0", mbps: 480, bytesPerSecond: 37_600_000, deviceWaitMs: 34,
            storages: [
                DemoStorage(info: StorageRef(id: 0x0001_0001, description: "Internal", capacityBytes: 512 * DemoLibrary.GB,
                                             freeBytes: 318 * DemoLibrary.GB, removable: false),
                            root: DemoLibrary.sp3000Internal()),
                DemoStorage(info: StorageRef(id: 0x0002_0001, description: "microSD", capacityBytes: 1_000 * DemoLibrary.GB,
                                             freeBytes: 412 * DemoLibrary.GB, removable: true),
                            root: DemoLibrary.sp3000Card()),
            ])
        let pixel = DemoDevice(
            ref: DeviceRef(id: Self.pixelID, manufacturer: "Google", model: "Pixel 8", name: "Pixel 8", serial: "DEMO-PIXEL8"),
            linkSpeed: "USB 3.2 Gen 1", mbps: 5_000, bytesPerSecond: 188_000_000, deviceWaitMs: 32,
            storages: [DemoStorage(
                info: StorageRef(id: 0x0001_0001, description: "Internal storage", capacityBytes: 128 * DemoLibrary.GB,
                                 freeBytes: 72 * DemoLibrary.GB, removable: false),
                root: DemoLibrary.galaxyInternal())])
        devices = [galaxy, sp3000, pixel]
    }

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func device(_ id: String) -> DemoDevice? { devices.first { $0.ref.id == id } }

    private func isFileTransfer(_ device: DemoDevice) -> Bool {
        device.plugged && !chargingOnly.contains(device.ref.id) && !switchingUSB.contains(device.ref.id)
    }

    private func adbOnlyDevices() -> [ADBOnlyDeviceRef] {
        devices.compactMap { device in
            let ref = device.ref
            guard device.plugged, chargingOnly.contains(ref.id), !switchingUSB.contains(ref.id),
                  let id = Self.chargingIDs[ref.id] else { return nil }
            return ADBOnlyDeviceRef(id: id, manufacturer: ref.manufacturer, model: ref.model,
                                    name: ref.model, serial: ref.serial, adb: .ready)
        }
    }

    private func visibleDevice(_ id: String) -> DemoDevice? {
        devices.first { device in
            let key = device.ref.id
            guard device.plugged, !switchingUSB.contains(key) else { return false }
            return chargingOnly.contains(key) ? Self.chargingIDs[key] == id : key == id
        }
    }

    // MARK: DeviceService

    var version: String { "0.1.0 (demo backend)" }

    func listDevices() throws -> [DeviceRef] {
        Thread.sleep(forTimeInterval: 0.05)
        return withLock { devices.filter(isFileTransfer).map(\.ref) }
    }

    func open(deviceID: String) throws -> any DeviceConnection {
        Thread.sleep(forTimeInterval: 0.35)  // claim the interface, OpenSession, GetDeviceInfo
        return try withLock {
            guard let device = device(deviceID), isFileTransfer(device) else { throw DeviceServiceError.noDevice }
            if let holder = device.heldBy { throw DeviceServiceError.deviceBusy(holder: holder.process) }
            return DemoConnection(service: self, deviceID: deviceID, session: device.session)
        }
    }

    func setEventObserver(_ observer: any DeviceEventObserving) {
        withLock { self.observer = observer }
    }

    func listADBOnlyDevices() throws -> [ADBOnlyDeviceRef] {
        withLock { adbOnlyDevices() }
    }

    func setADBOnlyDeviceObserver(_ observer: any ADBOnlyDeviceObserving) {
        withLock {
            adbOnlyObserver = observer
            observer.adbOnlyDevicesChanged(adbOnlyDevices())
        }
    }

    func adbAccess(deviceID: String) -> DeviceADBAccess {
        withLock {
            guard let device = visibleDevice(deviceID), Self.chargingIDs[device.ref.id] != nil else { return .off }
            return .ready
        }
    }

    func setUSBMode(deviceID: String, mode: DeviceUSBMode) throws -> USBModeSwitchResult {
        Thread.sleep(forTimeInterval: 0.35)
        let transition: (String, String)? = try withLock {
            guard let device = visibleDevice(deviceID) else { throw DeviceServiceError.noDevice }
            guard let chargingID = Self.chargingIDs[device.ref.id] else { return nil }
            let key = device.ref.id
            let toCharging = mode == .chargingOnly
            let newID = toCharging ? chargingID : key
            guard newID != deviceID else { return (key, newID) }
            switchingUSB.insert(key)
            device.session += 1
            if toCharging { observer?.deviceRemoved(id: key) } else { adbOnlyObserver?.adbOnlyDevicesChanged(adbOnlyDevices()) }
            return (key, newID)
        }
        guard let (key, newID) = transition else { return .unavailable(reason: "USB debugging is off.") }
        guard newID != deviceID else { return .switched(deviceID: newID) }
        Thread.sleep(forTimeInterval: 0.35)
        return withLock {
            switchingUSB.remove(key)
            guard device(key)?.plugged == true else { return .switched(deviceID: nil) }
            if mode == .chargingOnly {
                chargingOnly.insert(key)
                adbOnlyObserver?.adbOnlyDevicesChanged(adbOnlyDevices())
            } else {
                chargingOnly.remove(key)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                    withLock {
                        if let device = self.device(key), isFileTransfer(device) { observer?.deviceAdded(device.ref) }
                    }
                }
            }
            return .switched(deviceID: newID)
        }
    }

    func accessState(deviceID: String) -> DeviceAccessState {
        withLock {
            guard let device = device(deviceID) else { return .unknown }
            if let holder = device.heldBy { return .heldBy(process: holder.process, pid: holder.pid) }
            return .free
        }
    }

    func releaseSystemHold(deviceID: String) throws {
        Thread.sleep(forTimeInterval: 0.9)  // launchctl disable + pkill + re-enumeration
        try withLock {
            guard let device = device(deviceID) else { throw DeviceServiceError.noDevice }
            guard let holder = device.heldBy else { return }
            guard holder.process == "ptpcamerad" else {
                throw DeviceServiceError.io(message: "ReMTP can only pause ptpcamerad. Quit \(holder.process) and try again.")
            }
            device.heldBy = nil
            releasedHolds.insert(deviceID)
        }
    }

    func restoreSystemHold() throws {
        withLock {
            releasedHolds.removeAll()
            restoreCount += 1
        }
    }

    private var restoreCount = 0
    /// How often `restoreSystemHold` ran (self-check).
    var restoreCalls: Int { withLock { restoreCount } }

    // MARK: Debug controls (Debug menu)

    var demoDevices: [(id: String, name: String, plugged: Bool, held: Bool)] {
        withLock {
            devices.filter { !switchingUSB.contains($0.ref.id) }.map { device in
                let id = device.ref.id
                let chargingID = chargingOnly.contains(id) ? Self.chargingIDs[id] : nil
                return (chargingID ?? id, device.ref.name, device.plugged, chargingID == nil && device.heldBy != nil)
            }
        }
    }

    /// Simulates macOS's photo-import service grabbing the device when it is plugged in.
    func simulateSystemHold(deviceID: String) {
        let ref: DeviceRef? = withLock {
            guard let device = device(deviceID), isFileTransfer(device) else { return nil }
            device.heldBy = ("ptpcamerad", 812)
            device.session += 1
            return device.ref
        }
        guard let ref else { return }
        let observer = withLock { self.observer }
        observer?.deviceRemoved(id: deviceID)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { observer?.deviceAdded(ref) }
    }

    func setPlugged(deviceID: String, _ plugged: Bool) {
        withLock {
            guard let device = device(deviceID) ?? devices.first(where: { Self.chargingIDs[$0.ref.id] == deviceID }),
                  !switchingUSB.contains(device.ref.id), device.plugged != plugged else { return }
            device.plugged = plugged
            device.session += 1
            if chargingOnly.contains(device.ref.id) {
                adbOnlyObserver?.adbOnlyDevicesChanged(adbOnlyDevices())
            } else if plugged {
                observer?.deviceAdded(device.ref)
            } else {
                observer?.deviceRemoved(id: device.ref.id)
            }
        }
    }
}

// MARK: - Connection

final class DemoConnection: DeviceConnection, @unchecked Sendable {
    private let service: DemoDeviceService
    private let deviceID: String
    private let session: Int
    private var closed = false

    init(service: DemoDeviceService, deviceID: String, session: Int) {
        self.service = service
        self.deviceID = deviceID
        self.session = session
    }

    /// Runs `body` under the service lock with a live device, or throws `.disconnected`.
    private func live<T>(_ body: (DemoDevice) throws -> T) throws -> T {
        try service.withLock {
            guard !closed, let device = service.device(deviceID), device.plugged, device.session == session else {
                throw DeviceServiceError.disconnected
            }
            return try body(device)
        }
    }

    private func storage(_ device: DemoDevice, _ id: UInt32) throws -> DemoStorage {
        guard let storage = device.storage(id) else { throw DeviceServiceError.notFound(path: "storage \(id)") }
        return storage
    }

    func details() throws -> DeviceDetailsInfo {
        Thread.sleep(forTimeInterval: 0.04)
        return try live { device in
            DeviceDetailsInfo(summary: device.ref, linkSpeed: device.linkSpeed, linkSpeedMbps: device.linkSpeedMbps,
                              storages: device.storages.map(\.info))
        }
    }

    func list(storageID: UInt32, path: String) throws -> [FileEntry] {
        let entries: [FileEntry] = try live { device in
            let storage = try storage(device, storageID)
            guard let node = storage.node(at: path) else { throw DeviceServiceError.notFound(path: path) }
            guard node.isDir else { throw DeviceServiceError.io(message: "“\(path)” is not a folder.") }
            return node.sortedChildren.map(\.entry)
        }
        // A bulk GetObjectPropList: roughly 0.1 ms per object plus a round trip.
        Thread.sleep(forTimeInterval: 0.03 + Double(entries.count) * 0.000_1)
        return entries
    }

    func stat(storageID: UInt32, path: String) throws -> FileEntry {
        try live { device in
            let storage = try storage(device, storageID)
            guard let node = storage.node(at: path) else { throw DeviceServiceError.notFound(path: path) }
            return node.entry
        }
    }

    func createFolder(storageID: UInt32, path: String) throws {
        Thread.sleep(forTimeInterval: 0.03)
        try live { device in
            let storage = try storage(device, storageID)
            if let existing = storage.node(at: path), !existing.isDir { throw DeviceServiceError.alreadyExists(path: path) }
            storage.makeFolders(path)
        }
    }

    func delete(storageID: UInt32, path: String) throws {
        Thread.sleep(forTimeInterval: 0.05)
        try live { device in
            let storage = try storage(device, storageID)
            guard !DevicePath.isRoot(path), let node = storage.node(at: path),
                  let parent = storage.node(at: DevicePath.parent(path)) else { throw DeviceServiceError.notFound(path: path) }
            storage.reclaim(node.totalBytes)
            parent.remove(node.name)
        }
    }

    func rename(storageID: UInt32, path: String, newName: String) throws {
        Thread.sleep(forTimeInterval: 0.03)
        try live { device in
            let storage = try storage(device, storageID)
            guard !newName.isEmpty, !newName.contains("/") else {
                throw DeviceServiceError.io(message: "“\(newName)” isn’t a valid name.")
            }
            guard let node = storage.node(at: path), let parent = storage.node(at: DevicePath.parent(path)) else {
                throw DeviceServiceError.notFound(path: path)
            }
            if let other = parent.child(newName), other !== node {
                throw DeviceServiceError.alreadyExists(path: DevicePath.join(DevicePath.parent(path), newName))
            }
            parent.remove(node.name)
            node.name = newName
            parent.insert(node)
        }
    }

    func thumbnail(storageID: UInt32, path: String) throws -> Data? {
        let isFile: Bool = try live { device in
            let storage = try storage(device, storageID)
            guard let node = storage.node(at: path) else { throw DeviceServiceError.notFound(path: path) }
            return !node.isDir
        }
        guard isFile else { return nil }
        // GetThumb: one round trip and a few KB.
        Thread.sleep(forTimeInterval: 0.012)
        return DemoLibrary.thumbnail(for: path)
    }

    func invalidate(storageID: UInt32, path: String) {}

    func startTransfer(_ job: TransferJobSpec, observer: any TransferObserving) throws -> any TransferControl {
        let queue: DispatchQueue = try live { device in
            _ = try storage(device, job.storageID)
            return device.transferQueue
        }
        let transfer = DemoTransfer(service: service, deviceID: deviceID, session: session, job: job, observer: observer)
        queue.async { transfer.run() }
        return transfer
    }

    func close() {
        service.withLock { closed = true }
    }
}
