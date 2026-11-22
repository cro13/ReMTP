import Foundation
import Observation

/// One connected device as the app sees it: its open session (if any) and access state.
@Observable
@MainActor
final class DeviceSession: Identifiable {
    enum Phase: Equatable {
        case connecting
        case ready
        case held(process: String, pid: UInt32?)
        case releasing(process: String, pid: UInt32?)
        case ejected
        case failed(String)
    }

    let id: String
    var ref: DeviceRef
    /// The user's name for the device ("Rename…" in the sidebar), if any.
    var customName: String?
    var phase: Phase = .connecting
    var adbAccess: DeviceADBAccess = .off
    var details: DeviceDetailsInfo?
    /// "Not Now" on the access prompt: show the compact message instead.
    var promptDismissed = false
    var releaseError: String?
    @ObservationIgnored var connection: (any DeviceConnection)?
    /// The latest `AppModel.connect` attempt (open + details).
    @ObservationIgnored var opening: Task<Void, Never>?

    /// The newest session for each device ID, for code that only has an item's device ID (device thumbnails).
    private static let registry = NSMapTable<NSString, DeviceSession>.strongToWeakObjects()

    static func current(_ id: String) -> DeviceSession? { registry.object(forKey: id as NSString) }

    init(ref: DeviceRef, customName: String? = nil) {
        self.id = ref.id
        self.ref = ref
        self.customName = customName
        Self.registry.setObject(self, forKey: ref.id as NSString)
    }

    /// The name shown everywhere: the user's name for the device, else its own.
    var name: String { customName ?? ref.name }
    var storages: [StorageRef] { details?.storages ?? [] }
    var isReady: Bool { phase == .ready && connection != nil }

    var holder: (process: String, pid: UInt32?)? {
        switch phase {
        case .held(let process, let pid), .releasing(let process, let pid): return (process, pid)
        default: return nil
        }
    }

    /// Held by macOS's own camera daemon (ptpcamerad), which ReMTP can pause; any other holder is an app
    /// the user has to quit.
    var isSystemHold: Bool { holder?.process.hasPrefix("ptpcamera") == true }

    /// "Samsung · USB 3 · MTP"
    var subtitle: String {
        var parts: [String] = []
        if !ref.manufacturer.isEmpty { parts.append(ref.manufacturer) }
        if let link = Format.shortLink(details?.linkSpeed) { parts.append(link) }
        parts.append("MTP")
        return parts.joined(separator: " · ")
    }

    /// "USB 3 · 5 Gb/s · MTP"
    var linkDescription: String {
        [Format.shortLink(details?.linkSpeed), Format.linkRate(details?.linkSpeedMbps), "MTP"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    func storage(_ id: UInt32) -> StorageRef? { storages.first { $0.id == id } }
}
