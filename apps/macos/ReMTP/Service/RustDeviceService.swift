import Foundation

// `DeviceService` backed by the Rust core through the generated UniFFI bindings
// (`apps/macos/Generated/remtp_ffi.swift`, built by `scripts/build-macos-core.sh`).
// Pure mapping between the FFI types and the app types; no logic lives here.

final class RustDeviceService: DeviceService, @unchecked Sendable {
    private let engine = Engine()
    private let lock = NSLock()
    private var eventBridge: EventBridge?
    private var adbOnlyBridge: ADBOnlyBridge?

    var version: String { engine.version() }

    func listDevices() throws -> [DeviceRef] {
        try bridged { try engine.listDevices().map(DeviceRef.init) }
    }

    func open(deviceID: String) throws -> any DeviceConnection {
        try bridged { RustDeviceConnection(try engine.open(deviceId: deviceID)) }
    }

    func setEventObserver(_ observer: any DeviceEventObserving) {
        let bridge = EventBridge(observer)
        lock.withLock { eventBridge = bridge }
        engine.setEventListener(listener: bridge)
    }

    func accessState(deviceID: String) -> DeviceAccessState {
        DeviceAccessState(engine.accessState(deviceId: deviceID))
    }

    func releaseSystemHold(deviceID: String) throws {
        try bridged { try engine.releaseSystemHold(deviceId: deviceID) }
    }

    func restoreSystemHold() throws {
        try bridged { try engine.restoreSystemHold() }
    }

    func listADBOnlyDevices() throws -> [ADBOnlyDeviceRef] {
        try bridged { try engine.listAdbOnlyDevices().map(ADBOnlyDeviceRef.init) }
    }

    func setADBOnlyDeviceObserver(_ observer: any ADBOnlyDeviceObserving) {
        let bridge = ADBOnlyBridge(observer)
        lock.withLock { adbOnlyBridge = bridge }
        engine.setAdbOnlyDeviceListener(listener: bridge)
    }

    func adbAccess(deviceID: String) -> DeviceADBAccess {
        DeviceADBAccess(engine.adbAccess(deviceId: deviceID))
    }

    func setUSBMode(deviceID: String, mode: DeviceUSBMode) throws -> USBModeSwitchResult {
        try bridged {
            switch try engine.setUsbMode(deviceId: deviceID, mode: mode == .fileTransfer ? .fileTransfer : .chargingOnly) {
            case .switched(let id): return .switched(deviceID: id)
            case .needsApproval: return .needsApproval
            case .unavailable(let reason): return .unavailable(reason: reason)
            }
        }
    }
}

final class RustDeviceConnection: DeviceConnection, @unchecked Sendable {
    private let device: Device

    init(_ device: Device) { self.device = device }

    func details() throws -> DeviceDetailsInfo {
        try bridged { DeviceDetailsInfo(try device.details()) }
    }

    func list(storageID: UInt32, path: String) throws -> [FileEntry] {
        try bridged { try device.list(storageId: storageID, path: path).map(FileEntry.init) }
    }

    func stat(storageID: UInt32, path: String) throws -> FileEntry {
        try bridged { FileEntry(try device.stat(storageId: storageID, path: path)) }
    }

    func createFolder(storageID: UInt32, path: String) throws {
        try bridged { try device.createFolder(storageId: storageID, path: path) }
    }

    func delete(storageID: UInt32, path: String) throws {
        try bridged { try device.delete(storageId: storageID, path: path) }
    }

    func rename(storageID: UInt32, path: String, newName: String) throws {
        try bridged { try device.rename(storageId: storageID, path: path, newName: newName) }
    }

    func thumbnail(storageID: UInt32, path: String) throws -> Data? {
        try bridged { try device.thumbnail(storageId: storageID, path: path) }
    }

    func invalidate(storageID: UInt32, path: String) {
        device.invalidate(storageId: storageID, path: path)
    }

    func startTransfer(_ job: TransferJobSpec, observer: any TransferObserving) throws -> any TransferControl {
        try bridged {
            RustTransferControl(try device.startTransfer(job: TransferJob(job), observer: ObserverBridge(observer)))
        }
    }

    func close() { device.close() }
}

final class RustTransferControl: TransferControl, @unchecked Sendable {
    private let transfer: Transfer

    init(_ transfer: Transfer) { self.transfer = transfer }

    func pause() { transfer.pause() }
    func resume() { transfer.resume() }
    func cancel() { transfer.cancel() }
    func resolve(issueID: UInt64, choice: ConflictResolution) {
        transfer.resolve(issueId: issueID, choice: ConflictChoice(choice))
    }
}

// MARK: - Callback bridges

private final class EventBridge: DeviceEventListener, @unchecked Sendable {
    private let observer: any DeviceEventObserving
    init(_ observer: any DeviceEventObserving) { self.observer = observer }

    func onDeviceAdded(device: DeviceSummary) { observer.deviceAdded(DeviceRef(device)) }
    func onDeviceRemoved(deviceId: String) { observer.deviceRemoved(id: deviceId) }
}

private final class ADBOnlyBridge: AdbOnlyDeviceListener, @unchecked Sendable {
    private let observer: any ADBOnlyDeviceObserving
    init(_ observer: any ADBOnlyDeviceObserving) { self.observer = observer }

    func onAdbOnlyDevicesChanged(devices: [AdbOnlyDevice]) {
        observer.adbOnlyDevicesChanged(devices.map(ADBOnlyDeviceRef.init))
    }
}

private final class ObserverBridge: TransferObserver, @unchecked Sendable {
    private let observer: any TransferObserving
    init(_ observer: any TransferObserving) { self.observer = observer }

    func onPlanned(filesTotal: UInt32, bytesTotal: UInt64) { observer.transferPlanned(filesTotal: filesTotal, bytesTotal: bytesTotal) }
    func onPendingSources(sources: [String]) { observer.transferPendingSources(sources) }
    func onProgress(progress: TransferProgress) { observer.transferProgress(TransferProgressInfo(progress)) }
    func onFileDone(source: String, destination: String, bytes: UInt64) {
        observer.transferFileDone(path: source, destination: destination, bytes: bytes)
    }
    func onFileLeftOut(source: String) { observer.transferFileLeftOut(path: source) }
    func onIssue(issue: TransferIssue) { observer.transferIssue(TransferIssueInfo(issue)) }
    func onFinished(summary: TransferSummary) { observer.transferFinished(TransferSummaryInfo(summary)) }
}

// MARK: - Type mapping

private func bridged<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as RemtpError {
        throw DeviceServiceError(error)
    }
}

private extension DeviceServiceError {
    init(_ error: RemtpError) {
        switch error {
        case .NoDevice: self = .noDevice
        case .DeviceBusy(let holder): self = .deviceBusy(holder: holder)
        case .Disconnected: self = .disconnected
        case .NotFound(let path): self = .notFound(path: path)
        case .AlreadyExists(let path): self = .alreadyExists(path: path)
        case .Cancelled: self = .cancelled
        case .Io(let message): self = .io(message: message)
        case .Protocol(let message): self = .protocol(message: message)
        }
    }
}

private extension DeviceRef {
    init(_ s: DeviceSummary) {
        self.init(id: s.id, manufacturer: s.manufacturer, model: s.model, name: s.name, serial: s.serial)
    }
}

private extension ADBOnlyDeviceRef {
    init(_ device: AdbOnlyDevice) {
        self.init(id: device.id, manufacturer: device.manufacturer, model: device.model, name: device.name,
                  serial: device.serial, adb: DeviceADBAccess(device.adb))
    }
}

private extension DeviceADBAccess {
    init(_ access: AdbAccess) {
        switch access {
        case .off: self = .off
        case .ready: self = .ready
        case .needsApproval: self = .needsApproval
        case .unavailable(let reason): self = .unavailable(reason: reason)
        }
    }
}

private extension StorageRef {
    init(_ s: StorageInfo) {
        self.init(id: s.id, description: s.description, capacityBytes: s.capacityBytes, freeBytes: s.freeBytes, removable: s.removable)
    }
}

private extension DeviceDetailsInfo {
    init(_ d: DeviceDetails) {
        self.init(summary: DeviceRef(d.summary), linkSpeed: d.linkSpeed, linkSpeedMbps: d.linkSpeedMbps, storages: d.storages.map(StorageRef.init))
    }
}

private extension FileEntry {
    init(_ e: Entry) {
        self.init(name: e.name, isDir: e.isDir, size: e.size, modified: e.modified)
    }
}

private extension DeviceAccessState {
    init(_ s: AccessState) {
        switch s {
        case .free: self = .free
        case .heldBy(let process, let pid): self = .heldBy(process: process, pid: pid)
        case .unknown: self = .unknown
        }
    }
}

private extension TransferJob {
    init(_ j: TransferJobSpec) {
        let direction: Direction = j.direction == .toDevice ? .toDevice : .fromDevice
        let conflict: ConflictPolicy = switch j.conflict {
        case .ask: .ask
        case .replace: .replace
        case .keepBoth: .keepBoth
        case .skip: .skip
        case .skipIfSame: .skipIfSame
        }
        let verify: VerifyMode = switch j.verify {
        case .none: .none
        case .size: .size
        case .checksum: .checksum
        }
        self.init(direction: direction, storageId: j.storageID, sources: j.sources, destination: j.destination,
                  conflict: conflict, verify: verify, cardSafeNames: j.cardSafeNames, pendingSources: j.pendingSources)
    }
}

private extension ConflictChoice {
    init(_ c: ConflictResolution) {
        switch c {
        case .replace: self = .replace
        case .keepBoth: self = .keepBoth
        case .skip: self = .skip
        }
    }
}

private extension TransferProgressInfo {
    init(_ p: TransferProgress) {
        self.init(filesDone: p.filesDone, filesTotal: p.filesTotal, bytesDone: p.bytesDone, bytesTotal: p.bytesTotal,
                  currentName: p.currentName, currentBytesDone: p.currentBytesDone, currentBytesTotal: p.currentBytesTotal,
                  speedBytesPerSec: p.speedBytesPerSec, avgMsPerFile: p.avgMsPerFile, deviceWaitMsAvg: p.deviceWaitMsAvg,
                  idleMsAvg: p.idleMsAvg, readAheadFiles: p.readAheadFiles, readAheadBytes: p.readAheadBytes, paused: p.paused)
    }
}

private extension TransferIssueInfo {
    init(_ i: TransferIssue) {
        let kind: TransferIssueKind = switch i.kind {
        case .conflict: .conflict
        case .invalidName: .invalidName
        case .nameTooLong: .nameTooLong
        case .tooLargeForStorage: .tooLargeForStorage
        case .noSpace: .noSpace
        case .failed: .failed
        }
        self.init(id: i.id, path: i.path, kind: kind, message: i.message, existingSize: i.existingSize, incomingSize: i.incomingSize,
                  destinationFolder: i.destinationFolder,
                  existingModified: i.existingModified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                  incomingModified: i.incomingModified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                  retry: i.retry.map { TransferRetryInfo(source: $0.source, folder: $0.folder, cardSafeName: $0.cardSafeName, keepBoth: $0.keepBoth) },
                  conflictSource: i.conflictSource)
    }
}

private extension TransferSummaryInfo {
    init(_ s: TransferSummary) {
        self.init(filesCopied: s.filesCopied, filesSkipped: s.filesSkipped, filesFailed: s.filesFailed, bytes: s.bytes,
                  elapsedMs: s.elapsedMs, renamed: s.renamed.map { RenamedFileInfo(from: $0.from, to: $0.to) }, error: s.error)
    }
}
