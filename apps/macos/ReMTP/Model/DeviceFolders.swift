import Foundation
import Observation

/// A device folder pinned in the sidebar ("Add to Sidebar"), shown under its device.
struct DeviceFavorite: Codable, Hashable, Identifiable {
    var storageID: UInt32
    /// Absolute on the storage, never the root ("/DCIM/Camera").
    var path: String
    /// The storage's short name when it was last seen ("Internal"), for the tooltip while the device is away.
    var storageName: String

    var id: String { "\(storageID):\(path)" }
    var title: String { DevicePath.lastComponent(path) }

    /// "Internal › DCIM › Camera".
    func place(storageName current: String? = nil) -> String {
        ([current ?? storageName] + DevicePath.components(path)).joined(separator: " › ")
    }
}

/// What ReMTP remembers about device folders, per device (`USBDeviceIdentity.folderKey`): the folder the device
/// pane last showed on each storage (and which storage that was), and the folders pinned in the sidebar. Kept
/// in `AppDefaults.store(demo:)`, next to the known devices.
@Observable
@MainActor
final class DeviceFolders {
    static let lastKey = "deviceFolders.last.v1"
    static let favoritesKey = "deviceFolders.favorites.v1"

    private struct Last: Codable, Equatable {
        /// The storage the device pane showed last.
        var storageID: UInt32
        /// The last folder per storage, keyed by the storage id in decimal.
        var paths: [String: String]
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var last: [String: Last] = [:]
    /// Pinned folders by `folderKey`, in the order they were added.
    private(set) var favorites: [String: [DeviceFavorite]] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: Self.lastKey), let decoded = try? decoder.decode([String: Last].self, from: data) {
            last = decoded
        }
        if let data = defaults.data(forKey: Self.favoritesKey),
           let decoded = try? decoder.decode([String: [DeviceFavorite]].self, from: data) {
            favorites = decoded.filter { !$0.value.isEmpty }
        }
    }

    private static func key(_ deviceID: String) -> String { USBDeviceIdentity.folderKey(for: deviceID) }

    /// "/DCIM/Camera" however it is spelled ("DCIM/Camera/", "//DCIM/Camera").
    static func normalized(_ path: String) -> String { "/" + DevicePath.components(path).joined(separator: "/") }

    private func saveLast() {
        if last.isEmpty {
            defaults.removeObject(forKey: Self.lastKey)
        } else if let data = try? JSONEncoder().encode(last) {
            defaults.set(data, forKey: Self.lastKey)
        }
    }

    private func saveFavorites() {
        if favorites.isEmpty {
            defaults.removeObject(forKey: Self.favoritesKey)
        } else if let data = try? JSONEncoder().encode(favorites) {
            defaults.set(data, forKey: Self.favoritesKey)
        }
    }

    // MARK: Last folders

    /// The storage the device pane last showed for `deviceID`.
    func lastStorage(of deviceID: String) -> UInt32? { last[Self.key(deviceID)]?.storageID }

    /// The folder the device pane last showed on `storageID` of `deviceID`.
    func lastPath(of deviceID: String, storageID: UInt32) -> String? { last[Self.key(deviceID)]?.paths[String(storageID)] }

    /// The device pane shows `location`: it opens there next time (also after a relaunch).
    func remember(_ location: DeviceLocation) {
        let key = Self.key(location.deviceID)
        var entry = last[key] ?? Last(storageID: location.storageID, paths: [:])
        entry.storageID = location.storageID
        entry.paths[String(location.storageID)] = Self.normalized(location.path)
        guard last[key] != entry else { return }
        last[key] = entry
        saveLast()
    }

    // MARK: Favourites

    func favorites(of deviceID: String) -> [DeviceFavorite] { favorites[Self.key(deviceID)] ?? [] }

    func favorite(at location: DeviceLocation) -> DeviceFavorite? {
        let id = "\(location.storageID):\(Self.normalized(location.path))"
        return favorites(of: location.deviceID).first { $0.id == id }
    }

    func isPinned(_ location: DeviceLocation) -> Bool { favorite(at: location) != nil }

    /// Pins `location` under its device. False for a storage root (the storage row is already there) and for a
    /// folder that is pinned already.
    @discardableResult
    func pin(_ location: DeviceLocation, storageName: String) -> Bool {
        let path = Self.normalized(location.path)
        guard !DevicePath.isRoot(path), !isPinned(location) else { return false }
        favorites[Self.key(location.deviceID), default: []].append(
            DeviceFavorite(storageID: location.storageID, path: path, storageName: storageName))
        saveFavorites()
        return true
    }

    func unpin(_ favoriteID: String, of deviceID: String) {
        let key = Self.key(deviceID)
        guard let list = favorites[key], list.contains(where: { $0.id == favoriteID }) else { return }
        let kept = list.filter { $0.id != favoriteID }
        favorites[key] = kept.isEmpty ? nil : kept
        saveFavorites()
    }

    /// Keeps the tooltips' storage names current while the device is connected.
    func updateStorageNames(of deviceID: String, _ names: [UInt32: String]) {
        let key = Self.key(deviceID)
        guard let list = favorites[key] else { return }
        let updated = list.map { favorite in
            var favorite = favorite
            if let name = names[favorite.storageID] { favorite.storageName = name }
            return favorite
        }
        guard updated != list else { return }
        favorites[key] = updated
        saveFavorites()
    }

    /// A folder on the device was renamed from `oldPath` to `newPath`: favourites and last folders in it move along.
    func moved(_ deviceID: String, storageID: UInt32, from oldPath: String, to newPath: String) {
        let key = Self.key(deviceID)
        let old = DevicePath.components(oldPath), new = DevicePath.components(newPath)
        func relocate(_ path: String) -> String? {
            let parts = DevicePath.components(path)
            guard !old.isEmpty, parts.starts(with: old) else { return nil }
            return "/" + (new + parts.dropFirst(old.count)).joined(separator: "/")
        }
        if let list = favorites[key] {
            var seen: Set<String> = []
            let updated = list.compactMap { favorite -> DeviceFavorite? in
                var favorite = favorite
                if favorite.storageID == storageID, let moved = relocate(favorite.path) { favorite.path = moved }
                return seen.insert(favorite.id).inserted ? favorite : nil
            }
            if updated != list {
                favorites[key] = updated
                saveFavorites()
            }
        }
        if var entry = last[key], let path = entry.paths[String(storageID)], let moved = relocate(path) {
            entry.paths[String(storageID)] = moved
            last[key] = entry
            saveLast()
        }
    }

    /// Folders on the device were deleted: their favourites (and those of folders inside them) go.
    func removed(_ deviceID: String, storageID: UInt32, paths: [String]) {
        let key = Self.key(deviceID)
        guard let list = favorites[key], !paths.isEmpty else { return }
        let gone = paths.map(DevicePath.components).filter { !$0.isEmpty }
        let kept = list.filter { favorite in
            favorite.storageID != storageID || !gone.contains { DevicePath.components(favorite.path).starts(with: $0) }
        }
        guard kept != list else { return }
        favorites[key] = kept.isEmpty ? nil : kept
        saveFavorites()
    }

    /// "Forget This Device": its folders go with it.
    func forget(_ deviceID: String) {
        let key = Self.key(deviceID)
        if last.removeValue(forKey: key) != nil { saveLast() }
        if favorites.removeValue(forKey: key) != nil { saveFavorites() }
    }
}

#if DEBUG
extension DeviceFolders {
    /// Self-check: this class's keys in the real app's defaults domain when the app started, and now.
    static var standardAtLaunch: [String: Data] = [:]

    static func standardSnapshot() -> [String: Data] {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        var keys: [String: Data] = [:]
        for key in [lastKey, favoritesKey] { keys[key] = domain[key] as? Data }
        return keys
    }

    /// Self-check: the remembered folders, to put back after the checks.
    var lastFoldersSnapshot: Data? { try? JSONEncoder().encode(last) }

    func restoreLastFolders(_ snapshot: Data?) {
        last = snapshot.flatMap { try? JSONDecoder().decode([String: Last].self, from: $0) } ?? [:]
        saveLast()
    }
}
#endif
