import Foundation

enum PaneKind: String, Hashable {
    case mac, device
}

struct DeviceLocation: Hashable {
    var deviceID: String
    var storageID: UInt32
    var path: String
}

enum PaneLocation: Hashable {
    case mac(URL)
    case device(DeviceLocation)

    var macURL: URL? {
        if case .mac(let url) = self { return url }
        return nil
    }

    var device: DeviceLocation? {
        if case .device(let location) = self { return location }
        return nil
    }

    /// The same folder, however a Mac URL is spelled (trailing slash, `/private` prefix).
    func isSameFolder(as other: PaneLocation?) -> Bool {
        switch (self, other) {
        case (.mac(let a), .mac(let b)?):
            return a.standardizedFileURL.path == b.standardizedFileURL.path
        case (.device(let a), .device(let b)?):
            return a.deviceID == b.deviceID && a.storageID == b.storageID
                && DevicePath.components(a.path) == DevicePath.components(b.path)
        default:
            return false
        }
    }

    /// The path the transfer engine uses for this folder (absolute local path or device path).
    var enginePath: String {
        switch self {
        case .mac(let url): return url.standardizedFileURL.path
        case .device(let location): return location.path
        }
    }

    func atTransferPath(_ path: String) -> PaneLocation {
        switch self {
        case .mac: return .mac(URL(fileURLWithPath: path))
        case .device(var location):
            location.path = path
            return .device(location)
        }
    }

    func appending(_ components: [String]) -> PaneLocation {
        switch self {
        case .mac(let url): return .mac(components.reduce(url) { $0.appendingPathComponent($1) })
        case .device(var location):
            location.path = components.reduce(location.path, DevicePath.join)
            return .device(location)
        }
    }

    func relativeComponents(to folder: PaneLocation) -> ArraySlice<String>? {
        let path: [String], root: [String]
        switch (self, folder) {
        case (.mac(let url), .mac(let base)):
            path = url.standardizedFileURL.pathComponents
            root = base.standardizedFileURL.pathComponents
        case (.device(let location), .device(let base))
            where location.deviceID == base.deviceID && location.storageID == base.storageID:
            path = DevicePath.components(location.path)
            root = DevicePath.components(base.path)
        default:
            return nil
        }
        return path.starts(with: root) ? path.dropFirst(root.count) : nil
    }
}

/// A crumb in a pane's path bar.
struct Crumb: Identifiable, Hashable {
    var id: Int
    var title: String
    var systemImage: String?
    var location: PaneLocation
}

/// The "On <other side>" column.
enum ItemStatus: Equatable {
    case none
    case same
    case differs
    case notOnDevice
    case notOnMac
    case folderOnBoth
    case copying(Double)
    case copyingFolder
    case queued
    case arriving(Double)

    var isTransfer: Bool {
        switch self {
        case .copying, .copyingFolder, .queued, .arriving: return true
        default: return false
        }
    }

    /// Not in the other pane’s folder. Views point toward that pane only while the two open folders
    /// share a name; between unrelated folders every row would be "missing" and the marks would be noise.
    var isMissing: Bool { self == .notOnDevice || self == .notOnMac }

    /// Sort order for the status column.
    var rank: Int {
        switch self {
        case .copying, .copyingFolder, .arriving: return 0
        case .queued: return 1
        case .differs: return 2
        case .notOnDevice, .notOnMac: return 3
        case .folderOnBoth: return 4
        case .same: return 5
        case .none: return 6
        }
    }
}

/// Persisted facts about devices seen before, for the "not connected" rows and auto-release.
struct KnownDevice: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var manufacturer: String
    var model: String
    var linkSpeed: String?
    var lastSeen: Date
    var autoRelease: Bool = false
}

enum USBDeviceIdentity {
    static func serialKey(for id: String) -> String? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty, !parts[2].hasPrefix("loc") else { return nil }
        return "\(parts[0]):\(parts[2])"
    }

    /// "vendor:product" for an id made from the USB port ("vendor:product:loc" and 16 hex digits, what the core
    /// uses when a device has no usable serial number); nil for every other id.
    static func portModel(for id: String) -> String? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, parts[2].hasPrefix("loc") else { return nil }
        let location = parts[2].dropFirst(3)
        guard location.count == 16, location.allSatisfy(\.isHexDigit) else { return nil }
        return "\(parts[0]):\(parts[1])"
    }
}

/// Where the app keeps what it learns about devices (known devices, names). Demo runs and the Debug
/// self-check share the real app's bundle id, so they use a domain of their own: simulated devices must
/// never show up in the real app.
enum AppDefaults {
    static let demoSuiteName = "io.github.cro13.ReMTP.demo"

    static func store(demo: Bool) -> UserDefaults {
        // `UserDefaults(suiteName:)` is nil only for the app's own bundle id and the global domain.
        demo ? UserDefaults(suiteName: demoSuiteName)! : .standard
    }
}

@MainActor
final class KnownDevices {
    static let key = "knownDevices.v1"
    static let namesKey = "deviceNames.v1"
    private let defaults: UserDefaults
    private(set) var all: [String: KnownDevice] = [:]
    /// Names the user gave devices ("Rename…"), by device id.
    private(set) var customNames: [String: String] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let decoded = try? JSONDecoder().decode([String: KnownDevice].self, from: data) {
            all = decoded
        }
        customNames = defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }

    private func saveNames() {
        if customNames.isEmpty {
            defaults.removeObject(forKey: Self.namesKey)
        } else {
            defaults.set(customNames, forKey: Self.namesKey)
        }
    }

    func remember(_ ref: DeviceRef, linkSpeed: String?) {
        var entry = all[ref.id] ?? KnownDevice(id: ref.id, name: ref.name, manufacturer: ref.manufacturer, model: ref.model,
                                               linkSpeed: linkSpeed, lastSeen: Date())
        entry.name = ref.name
        entry.lastSeen = Date()
        if let linkSpeed { entry.linkSpeed = linkSpeed }
        all[ref.id] = entry
        save()
    }

    func forget(_ id: String) {
        all[id] = nil
        customNames[id] = nil
        save()
        saveNames()
    }

    /// Drops entries for `ids` (the demo backend's devices, written by older demo runs). True if any were there.
    @discardableResult
    func purge(_ ids: Set<String>) -> Bool {
        let stale = ids.filter { all[$0] != nil || customNames[$0] != nil }
        guard !stale.isEmpty else { return false }
        for id in stale {
            all[id] = nil
            customNames[id] = nil
        }
        save()
        saveNames()
        return true
    }

    /// A device without a usable serial number is known by its USB port, so on another port, cable or hub it
    /// comes back with a new id, and each old one stayed behind as a "Not connected" row. ReMTP can't tell
    /// such devices of one model apart, so it keeps one entry per vendor and product: the newest, moved to
    /// `id` when that is the device connecting now (its name and auto-release go with it). Entries in
    /// `connected` stay, since those devices are plugged in. True if anything changed.
    @discardableResult
    func mergePortIDs(into id: String? = nil, connected: Set<String> = []) -> Bool {
        let connected = connected.subtracting(id.map { [$0] } ?? [])
        var groups: [String: [KnownDevice]] = [:]
        for entry in all.values where !connected.contains(entry.id) {
            if let model = USBDeviceIdentity.portModel(for: entry.id) { groups[model, default: []].append(entry) }
        }
        var changed = false
        for (model, entries) in groups {
            guard let newest = entries.max(by: { $0.lastSeen < $1.lastSeen }) else { continue }
            let keep = id.flatMap { USBDeviceIdentity.portModel(for: $0) == model ? $0 : nil } ?? newest.id
            guard entries.contains(where: { $0.id != keep }) else { continue }
            if newest.id != keep {
                var entry = all[keep] ?? newest
                entry.id = keep
                entry.autoRelease = newest.autoRelease
                // The link speed belongs to the old port; the new one's is recorded when the device opens.
                if all[keep] == nil { entry.linkSpeed = nil }
                all[keep] = entry
                customNames[keep] = customNames[newest.id]
            }
            for entry in entries where entry.id != keep {
                all[entry.id] = nil
                customNames[entry.id] = nil
            }
            changed = true
        }
        if changed {
            save()
            saveNames()
        }
        return changed
    }

    func customName(_ id: String) -> String? { customNames[id] }

    func customName(matchingUSBDevice id: String) -> String? {
        if let exact = customName(id) { return exact }
        guard let key = USBDeviceIdentity.serialKey(for: id) else { return nil }
        return all.values.filter { USBDeviceIdentity.serialKey(for: $0.id) == key && customNames[$0.id] != nil }
            .max { $0.lastSeen < $1.lastSeen }.flatMap { customNames[$0.id] }
    }

    func migrateDemoID(from oldID: String, to newID: String) {
        if var entry = all[oldID], all[newID] == nil {
            entry.id = newID
            all[newID] = entry
        }
        if customNames[newID] == nil { customNames[newID] = customNames[oldID] }
        purge([oldID])
    }

    /// nil (or empty) goes back to the device's own name.
    func setCustomName(_ name: String?, for id: String) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        customNames[id] = trimmed.isEmpty ? nil : trimmed
        saveNames()
    }

    func autoRelease(_ id: String) -> Bool { all[id]?.autoRelease ?? false }

    func setAutoRelease(_ id: String, ref: DeviceRef, _ on: Bool) {
        if all[id] == nil { remember(ref, linkSpeed: nil) }
        all[id]?.autoRelease = on
        save()
    }
}
