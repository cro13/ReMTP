import Foundation

/// The Mac side: plain FileManager calls, always run off the main thread by callers.
enum LocalFileSystem {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isHiddenKey,
    ]

    static func list(_ folder: URL, showHidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map(item(for:))
    }

    static func item(for url: URL) -> FileItem {
        let values = try? url.resourceValues(forKeys: Set(keys))
        let isDir = values?.isDirectory ?? false
        return FileItem(name: url.lastPathComponent, isDirectory: isDir, isPackage: values?.isPackage ?? false,
                        size: isDir ? nil : UInt64(values?.fileSize ?? 0), modified: values?.contentModificationDate,
                        created: values?.creationDate, url: url, isHidden: values?.isHidden ?? false)
    }

    static func availableCapacity(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    static func volumeName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? "Macintosh HD"
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        repeat {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    static func createFolder(in folder: URL, name: String = "untitled folder") throws -> URL {
        let url = uniqueURL(in: folder, name: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func rename(_ url: URL, to newName: String) throws -> URL {
        guard !newName.isEmpty, !newName.contains("/"), !newName.contains(":") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    static func trash(_ urls: [URL]) throws {
        for url in urls { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    /// Finder → Mac pane drops. Never overwrites: clashes get "name 2.ext".
    static func copy(_ urls: [URL], into folder: URL) throws {
        for url in urls {
            let target = uniqueURL(in: folder, name: url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: target)
        }
    }

    static func move(_ urls: [URL], into folder: URL) throws {
        for url in urls {
            let target = uniqueURL(in: folder, name: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
        }
    }
}

/// Watches one directory for changes (files added, removed, renamed) and calls back on main.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func watch(_ url: URL?) {
        source?.cancel()
        source = nil
        guard let url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func schedule() {
        pending?.cancel()
        let onChange = self.onChange
        let item = DispatchWorkItem { MainActor.assumeIsolated { onChange() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    deinit { source?.cancel() }
}
