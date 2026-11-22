import AppKit
import AudioToolbox
import ImageIO
import os
import UniformTypeIdentifiers

/// One row in a pane: a local file (with `url`) or a device file (with `devicePath`).
struct FileItem: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    /// Packages (.app, .photoslibrary) are folders on disk but files to the user.
    let isPackage: Bool
    /// nil when unknown (local folders).
    let size: UInt64?
    let modified: Date?
    let created: Date?
    let url: URL?
    let devicePath: String?
    /// The device and storage a device item is on (nil for local items, and for device rows made without them).
    let deviceID: String?
    let storageID: UInt32?
    let isHidden: Bool
    /// NFC + case-folded name, used to match items across panes.
    let compareKey: String
    let kind: String
    let type: UTType?

    var id: String { name }

    /// Folders the user can browse into.
    var isBrowsable: Bool { isDirectory && !isPackage }

    init(name: String, isDirectory: Bool, isPackage: Bool = false, size: UInt64?, modified: Date?, created: Date? = nil,
         url: URL? = nil, devicePath: String? = nil, isHidden: Bool = false, deviceID: String? = nil, storageID: UInt32? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.size = size
        self.modified = modified
        self.created = created
        self.url = url
        self.devicePath = devicePath
        self.deviceID = deviceID
        self.storageID = storageID
        self.isHidden = isHidden
        self.compareKey = FileItem.compareKey(name)
        let type = FileKinds.type(for: name, isDirectory: isDirectory && !isPackage)
        self.type = type
        self.kind = FileKinds.describe(name: name, isDirectory: isDirectory && !isPackage, type: type)
    }

    static func compareKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func device(_ entry: FileEntry, folder: String, deviceID: String? = nil, storageID: UInt32? = nil) -> FileItem {
        FileItem(name: entry.name, isDirectory: entry.isDir, size: entry.isDir ? nil : entry.size,
                 modified: entry.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                 devicePath: DevicePath.join(folder, entry.name), isHidden: entry.name.hasPrefix("."),
                 deviceID: deviceID, storageID: storageID)
    }

    /// A row of the listing of `folder`, knowing its device and storage (device thumbnails need them).
    static func device(_ entry: FileEntry, in folder: DeviceLocation) -> FileItem {
        device(entry, folder: folder.path, deviceID: folder.deviceID, storageID: folder.storageID)
    }

    var isImage: Bool { type?.conforms(to: .image) ?? false }
    var isMovie: Bool { type?.conforms(to: .movie) ?? false || type?.conforms(to: .video) ?? false }
    var isAudio: Bool { type?.conforms(to: .audio) ?? false }
}

enum FileKinds {
    nonisolated(unsafe) private static var typeCache: [String: UTType] = [:]
    private static let lock = NSLock()

    static func type(for name: String, isDirectory: Bool) -> UTType? {
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .data }
        lock.lock()
        defer { lock.unlock() }
        if let cached = typeCache[ext] { return cached }
        let type = UTType(filenameExtension: ext) ?? .data
        typeCache[ext] = type
        return type
    }

    /// Common formats use the name readers recognize at a glance.
    private static let overrides: [String: String] = [
        "jpg": "JPEG", "jpeg": "JPEG", "heic": "HEIC", "heif": "HEIF", "png": "PNG",
        "gif": "GIF", "tif": "TIFF", "tiff": "TIFF", "webp": "WebP", "bmp": "BMP", "svg": "SVG",
        "dng": "DNG", "cr2": "CR2", "cr3": "CR3", "nef": "NEF", "arw": "ARW", "raf": "RAF",
        "pdf": "PDF", "txt": "Plain text", "md": "Markdown", "csv": "CSV", "log": "Log",
        "xlsx": "XLSX", "xls": "XLS", "docx": "DOCX", "doc": "DOC", "pptx": "PPTX",
        "zip": "ZIP", "apk": "APK", "crypt14": "WhatsApp backup", "m3u8": "M3U8", "m3u": "M3U",
        "flac": "FLAC", "dsf": "DSD", "dff": "DSD", "wav": "WAV", "aiff": "AIFF", "aif": "AIFF",
        "caf": "CAF", "mp3": "MP3", "m4a": "M4A", "aac": "AAC", "opus": "Opus", "ogg": "Ogg",
        "mov": "MOV", "mp4": "MP4", "m4v": "M4V", "mkv": "MKV", "webm": "WebM", "avi": "AVI",
    ]

    static func describe(name: String, isDirectory: Bool, type: UTType?) -> String {
        if isDirectory { return "Folder" }
        let ext = (name as NSString).pathExtension.lowercased()
        if let override = overrides[ext] { return override }
        if let description = type?.localizedDescription, type != .data, !description.isEmpty {
            return description.prefix(1).uppercased() + description.dropFirst()
        }
        return ext.isEmpty ? "Document" : "\(ext.uppercased()) file"
    }
}

/// Reads format details only for local files whose Kind cells are requested.
@MainActor
final class FileKindDetails {
    struct Key: Hashable, Sendable {
        let url: URL
        let size: UInt64?
        let modified: Date?
        let isImage: Bool

        init?(_ item: FileItem) {
            guard let url = item.url, !item.isDirectory,
                  item.isImage || ["FLAC", "WAV", "AIFF", "M4A", "CAF"].contains(item.kind) else { return nil }
            self.url = url
            size = item.size
            modified = item.modified
            isImage = item.isImage
        }
    }

    /// A bounded cache also remembers files with unavailable details.
    private final class Result {
        let suffix: String?
        init(_ suffix: String?) { self.suffix = suffix }
    }

    static let shared = FileKindDetails()
    private let cache = NSCache<WrappedKey, Result>()
    private let queue = DispatchQueue(label: "ReMTP.KindDetails", qos: .utility)
    /// Who waits for each key's details, by request token.
    private var pending: [Key: [UUID: (String?) -> Void]] = [:]
    /// Keys queued for probing that nobody waits for any more (their rows scrolled away, the folder
    /// changed): the queue skips them, so a slow volume doesn't keep old rows ahead of the visible ones.
    private let unwanted = OSAllocatedUnfairLock(initialState: Set<Key>())

    private final class WrappedKey: NSObject {
        let value: Key
        init(_ value: Key) { self.value = value }
        override var hash: Int { value.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? WrappedKey)?.value == value }
    }

    private init() { cache.countLimit = 2_048 }

    /// Calls `completion` with the details (at once when cached). The token, while it waits, is for `cancel`.
    @discardableResult
    func load(_ key: Key, completion: @escaping (String?) -> Void) -> UUID? {
        if let result = cache.object(forKey: WrappedKey(key)) {
            completion(result.suffix)
            return nil
        }
        let token = UUID()
        if pending[key] != nil {
            pending[key]?[token] = completion
            unwanted.withLock { _ = $0.remove(key) }
            return token
        }
        pending[key] = [token: completion]
        start(key)
        return token
    }

    /// The request `token` no longer wants `key`'s details. When nobody else does, the probe is skipped.
    func cancel(_ key: Key, _ token: UUID) {
        guard pending[key]?.removeValue(forKey: token) != nil, pending[key]?.isEmpty == true else { return }
        unwanted.withLock { _ = $0.insert(key) }
    }

    private func start(_ key: Key) {
        let unwanted = unwanted
        queue.async {
            guard !unwanted.withLock({ $0.remove(key) != nil }) else {
                DispatchQueue.main.async {
                    // Wanted again since it was skipped: queue it again; else forget it.
                    if self.pending[key]?.isEmpty == false { self.start(key) } else { self.pending[key] = nil }
                }
                return
            }
            let suffix = Self.probe(key)
            DispatchQueue.main.async {
                self.cache.setObject(Result(suffix), forKey: WrappedKey(key))
                unwanted.withLock { _ = $0.remove(key) }  // cancelled while it ran: moot now
                self.pending.removeValue(forKey: key)?.values.forEach { $0(suffix) }
            }
        }
    }

    nonisolated private static func probe(_ key: Key) -> String? {
        if key.isImage {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(key.url as CFURL, options),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return "\(width)×\(height)"
        }

        var file: AudioFileID?
        guard AudioFileOpenURL(key.url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr else { return nil }

        let bits: UInt32
        switch format.mFormatID {
        case kAudioFormatLinearPCM:
            bits = format.mBitsPerChannel
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            switch format.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: bits = 16
            case kAppleLosslessFormatFlag_20BitSourceData: bits = 20
            case kAppleLosslessFormatFlag_24BitSourceData: bits = 24
            case kAppleLosslessFormatFlag_32BitSourceData: bits = 32
            default: return nil
            }
        default: return nil
        }
        let rate = format.mSampleRate / 1_000
        guard bits > 0, rate.isFinite, rate > 0 else { return nil }
        let khz = rate.formatted(.number.precision(.fractionLength(0...3)).grouping(.never))
        return "\(bits)/\(khz)"
    }
}

enum FileIcons {
    private static let cache = NSCache<NSString, NSImage>()

    /// Finder's icon for the item's type. Local packages and apps use their own icon.
    @MainActor
    static func icon(for item: FileItem) -> NSImage {
        if let url = item.url, item.isPackage || item.type?.conforms(to: .application) == true {
            let key = url.path as NSString
            if let cached = cache.object(forKey: key) { return cached }
            let image = NSWorkspace.shared.icon(forFile: url.path)
            cache.setObject(image, forKey: key)
            return image
        }
        let type = item.type ?? .data
        let key = ("type:" + type.identifier) as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(for: type)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A device item as it was when the user confirmed deleting it.
struct DeviceDeleteTarget: Hashable, Sendable {
    let storageID: UInt32
    let path: String
    let name: String
    let isDir: Bool
    /// nil for folders (their size isn't compared).
    let size: UInt64?
    let modified: Int64?

    init(storageID: UInt32, path: String, name: String, isDir: Bool, size: UInt64?, modified: Int64?) {
        self.storageID = storageID
        self.path = path
        self.name = name
        self.isDir = isDir
        self.size = size
        self.modified = modified
    }

    init?(_ item: FileItem, storageID: UInt32) {
        guard let path = item.devicePath else { return nil }
        self.init(storageID: storageID, path: path, name: item.name, isDir: item.isDirectory,
                  size: item.isDirectory ? nil : item.size,
                  modified: item.modified.map { Int64($0.timeIntervalSince1970.rounded()) })
    }

    /// Whether `entry` (a fresh `stat` of `path`) is still the object the user chose.
    func matches(_ entry: FileEntry) -> Bool {
        entry.name == name && entry.isDir == isDir && entry.modified == modified && (isDir || entry.size == size)
    }

    /// Deletes each target that still matches; anything gone or changed is skipped. Each delete is tried
    /// once: a failed delete is never retried, since the path may name a different object by then.
    /// Blocking; call off the main thread.
    static func delete(_ targets: [DeviceDeleteTarget], on connection: any DeviceConnection) -> DeviceDeleteOutcome {
        var outcome = DeviceDeleteOutcome()
        // Drop cached listings so the checks see the device as it is now.
        var refreshed: Set<String> = []
        for target in targets {
            let folder = DevicePath.parent(target.path)
            if refreshed.insert("\(target.storageID):\(folder)").inserted {
                connection.invalidate(storageID: target.storageID, path: folder)
            }
        }
        for (index, target) in targets.enumerated() {
            let current: FileEntry
            do {
                current = try connection.stat(storageID: target.storageID, path: target.path)
            } catch DeviceServiceError.notFound {
                outcome.skipped.append((target.name, "It’s no longer there."))
                continue
            } catch DeviceServiceError.disconnected {
                outcome.stopped(at: targets[index...], reason: DeviceServiceError.disconnected.localizedDescription)
                break
            } catch {
                outcome.skipped.append((target.name, "It couldn’t be checked: \(error.localizedDescription)"))
                continue
            }
            guard target.matches(current) else {
                outcome.skipped.append((target.name, "It changed after you chose to delete it."))
                continue
            }
            do {
                try connection.delete(storageID: target.storageID, path: target.path)
                outcome.deleted.append(target.name)
            } catch DeviceServiceError.disconnected {
                outcome.failed.append((target.name, DeviceServiceError.disconnected.localizedDescription))
                outcome.stopped(at: targets[(index + 1)...], reason: DeviceServiceError.disconnected.localizedDescription)
                break
            } catch {
                outcome.failed.append((target.name, error.localizedDescription))
            }
        }
        return outcome
    }
}

struct DeviceDeleteOutcome: Sendable {
    var deleted: [String] = []
    /// Not deleted because it was gone or had changed (or couldn't be checked).
    var skipped: [(name: String, reason: String)] = []
    var failed: [(name: String, message: String)] = []

    fileprivate mutating func stopped(at rest: ArraySlice<DeviceDeleteTarget>, reason: String) {
        for target in rest { skipped.append((target.name, reason)) }
    }

    /// A message for anything that wasn't deleted, or nil when everything was.
    var report: (title: String, detail: String)? {
        let problems = failed.map { "“\($0.name)”: \($0.message)" } + skipped.map { "“\($0.name)” was skipped. \($0.reason)" }
        guard !problems.isEmpty else { return nil }
        let notDeleted = failed.count + skipped.count
        let title = deleted.isEmpty
            ? (notDeleted == 1 ? "Nothing was deleted." : "None of the items were deleted.")
            : "\(Format.count(deleted.count, "item")) deleted, \(notDeleted) not."
        var lines = Array(problems.prefix(6))
        if problems.count > lines.count { lines.append("…and \(problems.count - lines.count) more.") }
        return (title, lines.joined(separator: "\n"))
    }
}
