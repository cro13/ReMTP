import Foundation

// The app-side mirror of the `remtp-ffi` contract (docs/ARCHITECTURE.md).
//
// Every type and method here maps 1:1 onto the UniFFI API. The names are deliberately different
// from the generated UniFFI names (`Engine`, `Device`, `Entry`, `TransferJob`, …) so the generated
// bindings can live in the same module later. A `RustDeviceService` will wrap the generated
// `Engine` and conform to `DeviceService`; views never see either implementation directly.
//
//   remtp-ffi                       app
//   ─────────────────────────────── ───────────────────────────────
//   RemtpError                      DeviceServiceError
//   DeviceSummary                   DeviceRef
//   StorageInfo                     StorageRef
//   DeviceDetails                   DeviceDetailsInfo
//   Entry                           FileEntry
//   Vec<u8> (thumbnails)            Data
//   AccessState                     DeviceAccessState
//   DeviceEventListener             DeviceEventObserving
//   UsbMode                         DeviceUSBMode
//   AdbAccess                       DeviceADBAccess
//   AdbOnlyDevice                   ADBOnlyDeviceRef
//   UsbModeSwitch                   USBModeSwitchResult
//   AdbOnlyDeviceListener           ADBOnlyDeviceObserving
//   Engine                          DeviceService
//   Device                          DeviceConnection
//   Direction                       TransferDirection
//   ConflictPolicy                  TransferConflictPolicy
//   VerifyMode                      TransferVerifyMode
//   ConflictChoice                  ConflictResolution
//   IssueKind                       TransferIssueKind
//   TransferJob                     TransferJobSpec
//   TransferProgress                TransferProgressInfo
//   TransferIssue                   TransferIssueInfo
//   IssueRetry                      TransferRetryInfo
//   RenamedFile                     RenamedFileInfo
//   TransferSummary                 TransferSummaryInfo
//   TransferObserver                TransferObserving
//   Transfer                        TransferControl
//
// Device paths are `/`-separated and relative to a storage root (`/` is the root). Local paths are
// absolute POSIX paths. Times are Unix seconds. All methods may block; call them off the main thread.

// MARK: - Errors

enum DeviceServiceError: Error, Equatable, LocalizedError {
    case noDevice
    case deviceBusy(holder: String)
    case disconnected
    case notFound(path: String)
    case alreadyExists(path: String)
    case cancelled
    case io(message: String)
    case `protocol`(message: String)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "No such device."
        case .deviceBusy(let holder): return "The device is held by \(holder)."
        case .disconnected: return "The device was disconnected."
        case .notFound(let path): return "“\(path)” wasn’t found on the device."
        case .alreadyExists(let path): return "“\(path)” already exists."
        case .cancelled: return "Cancelled."
        case .io(let message): return message
        case .protocol(let message): return message
        }
    }
}

// MARK: - Records

/// `DeviceSummary`. `id` includes the USB vendor, product and serial (or USB location without a serial).
/// `name` is the friendly name if the device has one, else the model.
struct DeviceRef: Hashable, Sendable, Identifiable {
    var id: String
    var manufacturer: String
    var model: String
    var name: String
    var serial: String
}

struct ADBOnlyDeviceRef: Hashable, Sendable, Identifiable {
    var id: String
    var manufacturer: String
    var model: String
    var name: String
    var serial: String
    var adb: DeviceADBAccess
}

/// `StorageInfo`.
struct StorageRef: Hashable, Sendable, Identifiable {
    var id: UInt32
    var description: String
    var capacityBytes: UInt64
    var freeBytes: UInt64
    var removable: Bool

    /// "Internal storage" → "Internal" for compact places (sidebar, location chip).
    var shortName: String {
        let trimmed = description.replacingOccurrences(of: " storage", with: "", options: [.caseInsensitive, .backwards, .anchored])
        return trimmed.isEmpty ? description : trimmed
    }

    var usedFraction: Double {
        guard capacityBytes > 0 else { return 0 }
        return min(1, max(0, Double(capacityBytes - min(freeBytes, capacityBytes)) / Double(capacityBytes)))
    }
}

/// `DeviceDetails`. `linkSpeed` is e.g. "USB 2.0" or "USB 3.2 Gen 1".
struct DeviceDetailsInfo: Hashable, Sendable {
    var summary: DeviceRef
    var linkSpeed: String?
    var linkSpeedMbps: UInt32?
    var storages: [StorageRef]
}

/// `Entry`.
struct FileEntry: Hashable, Sendable {
    var name: String
    var isDir: Bool
    var size: UInt64
    var modified: Int64?
}

/// `AccessState`.
enum DeviceAccessState: Hashable, Sendable {
    case free
    case heldBy(process: String, pid: UInt32?)
    case unknown
}

enum DeviceUSBMode: Hashable, Sendable { case fileTransfer, chargingOnly }

enum DeviceADBAccess: Hashable, Sendable {
    case off
    case ready
    case needsApproval
    case unavailable(reason: String)
}

enum USBModeSwitchResult: Hashable, Sendable {
    case switched(deviceID: String?)
    case needsApproval
    case unavailable(reason: String)
}

enum TransferDirection: Hashable, Sendable { case toDevice, fromDevice }
enum TransferConflictPolicy: Hashable, Sendable { case ask, replace, keepBoth, skip, skipIfSame }
enum TransferVerifyMode: Hashable, Sendable { case none, size, checksum }
enum ConflictResolution: Hashable, Sendable { case replace, keepBoth, skip }
enum TransferIssueKind: Hashable, Sendable { case conflict, invalidName, nameTooLong, tooLargeForStorage, noSpace, failed }

/// `TransferJob`.
struct TransferJobSpec: Hashable, Sendable {
    var direction: TransferDirection
    var storageID: UInt32
    /// ToDevice: local paths; FromDevice: device paths. Folders recurse.
    var sources: [String]
    /// ToDevice: device folder; FromDevice: local folder.
    var destination: String
    var conflict: TransferConflictPolicy
    var verify: TransferVerifyMode
    /// Default true when the storage is removable.
    var cardSafeNames: Bool
    var pendingSources: [String]? = nil
}

/// `TransferProgress`. Delivered about 10 times per second.
struct TransferProgressInfo: Hashable, Sendable {
    var filesDone: UInt32
    var filesTotal: UInt32
    var bytesDone: UInt64
    var bytesTotal: UInt64
    var currentName: String
    var currentBytesDone: UInt64
    var currentBytesTotal: UInt64
    /// Smoothed over about 2 seconds.
    var speedBytesPerSec: UInt64
    var avgMsPerFile: UInt32
    var deviceWaitMsAvg: UInt32
    var idleMsAvg: UInt32
    var readAheadFiles: UInt32
    var readAheadBytes: UInt64
    var paused: Bool
}

/// `TransferIssue`.
struct TransferIssueInfo: Hashable, Sendable, Identifiable {
    var id: UInt64
    var path: String
    var kind: TransferIssueKind
    var message: String
    var existingSize: UInt64?
    var incomingSize: UInt64?
    var destinationFolder: String? = nil
    var existingModified: Date? = nil
    var incomingModified: Date? = nil
    /// How the file can be copied again on its own, when that can work.
    var retry: TransferRetryInfo? = nil
    var conflictSource: String? = nil
}

/// `IssueRetry`. Copy `source` again on its own into the destination folder `folder`.
struct TransferRetryInfo: Hashable, Sendable {
    var source: String
    var folder: String
    /// Copy it with `cardSafeNames`, under this name: its own name is what failed.
    var cardSafeName: String?
    /// Copy it with Keep Both: the name is taken by something that can't be replaced.
    var keepBoth: Bool
}

/// `RenamedFile`.
struct RenamedFileInfo: Hashable, Sendable {
    var from: String
    var to: String
}

/// `TransferSummary`. `error` is set when the whole job stopped (disconnect, cancel).
struct TransferSummaryInfo: Hashable, Sendable {
    var filesCopied: UInt32
    var filesSkipped: UInt32
    var filesFailed: UInt32
    var bytes: UInt64
    var elapsedMs: UInt64
    var renamed: [RenamedFileInfo]
    var error: String?
}

// MARK: - Callback interfaces (foreign traits)

/// `DeviceEventListener` (hot-plug). Called on an arbitrary thread.
protocol DeviceEventObserving: AnyObject, Sendable {
    func deviceAdded(_ device: DeviceRef)
    func deviceRemoved(id: String)
}

/// `AdbOnlyDeviceListener`. Receives the full list on registration and on change, on any thread.
protocol ADBOnlyDeviceObserving: AnyObject, Sendable {
    func adbOnlyDevicesChanged(_ devices: [ADBOnlyDeviceRef])
}

/// `TransferObserver`. Called on an arbitrary thread, in order.
protocol TransferObserving: AnyObject, Sendable {
    func transferPlanned(filesTotal: UInt32, bytesTotal: UInt64)
    func transferPendingSources(_ sources: [String])
    func transferProgress(_ progress: TransferProgressInfo)
    func transferFileDone(path: String, destination: String, bytes: UInt64)
    func transferFileLeftOut(path: String)
    /// With `.ask` the file waits for `resolve`; other files continue.
    func transferIssue(_ issue: TransferIssueInfo)
    func transferFinished(_ summary: TransferSummaryInfo)
}

// MARK: - Objects

/// `Engine`.
protocol DeviceService: AnyObject, Sendable {
    var version: String { get }
    func listDevices() throws -> [DeviceRef]
    /// Throws `.deviceBusy` if another process holds the device.
    func open(deviceID: String) throws -> any DeviceConnection
    func setEventObserver(_ observer: any DeviceEventObserving)
    func accessState(deviceID: String) -> DeviceAccessState
    /// Opt-in: suppresses `ptpcamerad`, then the device can be opened.
    func releaseSystemHold(deviceID: String) throws
    /// Undoes only what ReMTP changed.
    func restoreSystemHold() throws
    func listADBOnlyDevices() throws -> [ADBOnlyDeviceRef]
    func setADBOnlyDeviceObserver(_ observer: any ADBOnlyDeviceObserving)
    func adbAccess(deviceID: String) -> DeviceADBAccess
    func setUSBMode(deviceID: String, mode: DeviceUSBMode) throws -> USBModeSwitchResult
}

/// `Device`: one open session. All operations are serialized by the core.
protocol DeviceConnection: AnyObject, Sendable {
    /// Refreshes free space.
    func details() throws -> DeviceDetailsInfo
    func list(storageID: UInt32, path: String) throws -> [FileEntry]
    func stat(storageID: UInt32, path: String) throws -> FileEntry
    /// Like `mkdir -p`.
    func createFolder(storageID: UInt32, path: String) throws
    /// Recursive.
    func delete(storageID: UInt32, path: String) throws
    func rename(storageID: UInt32, path: String, newName: String) throws
    /// The device's own thumbnail of an image or video (usually a small JPEG); nil for other files and when the
    /// device has none. Each request is a device operation: ask one at a time, not while a transfer runs.
    func thumbnail(storageID: UInt32, path: String) throws -> Data?
    /// Drops a cached listing.
    func invalidate(storageID: UInt32, path: String)
    func startTransfer(_ job: TransferJobSpec, observer: any TransferObserving) throws -> any TransferControl
    func close()
}

/// `Transfer`.
protocol TransferControl: AnyObject, Sendable {
    func pause()
    func resume()
    func cancel()
    func resolve(issueID: UInt64, choice: ConflictResolution)
}

// MARK: - Device paths

enum DevicePath {
    static let root = "/"

    static func join(_ folder: String, _ name: String) -> String {
        folder == "/" || folder.isEmpty ? "/" + name : folder + "/" + name
    }

    static func parent(_ path: String) -> String {
        let parts = components(path)
        guard parts.count > 1 else { return "/" }
        return "/" + parts.dropLast().joined(separator: "/")
    }

    static func lastComponent(_ path: String) -> String {
        components(path).last ?? ""
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func isRoot(_ path: String) -> Bool { components(path).isEmpty }
}
