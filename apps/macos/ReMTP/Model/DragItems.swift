import AppKit
import UniformTypeIdentifiers

/// A device file on the pasteboard (pane → pane drags and Finder file promises).
struct DeviceDragItem: Codable, Hashable {
    var deviceID: String
    var storageID: UInt32
    var path: String
    var name: String
    var isDir: Bool
    var size: UInt64

    static let pasteboardType = NSPasteboard.PasteboardType("io.github.cro13.remtp.device-item")
    /// The same type for SwiftUI drop targets; declared in Info.plist (UTExportedTypeDeclarations).
    static let contentType = UTType(exportedAs: pasteboardType.rawValue, conformingTo: .data)

    var entry: FileEntry { FileEntry(name: name, isDir: isDir, size: size, modified: nil) }

    static func read(from pasteboard: NSPasteboard) -> [DeviceDragItem] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            item.data(forType: pasteboardType).flatMap { try? JSONDecoder().decode(DeviceDragItem.self, from: $0) }
        }
    }
}

/// Dragging device rows: our own type for drops on the Mac pane, a file promise for Finder.
final class DevicePromiseProvider: NSFilePromiseProvider {
    var dragItem: DeviceDragItem?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [DeviceDragItem.pasteboardType] + super.writableTypes(for: pasteboard)
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == DeviceDragItem.pasteboardType { return [] }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == DeviceDragItem.pasteboardType, let dragItem {
            return try? JSONEncoder().encode(dragItem)
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Finder file promises: the core writes into a private staging folder, then exactly the promised URL is
/// filled from it. All of this does file I/O; call it off the main thread.
enum PromiseDelivery {
    /// A fresh, empty folder on the same volume as `target` (so the final move is a rename).
    static func makeStaging(for target: URL) throws -> URL {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        if let staging = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true) {
            return staging
        }
        let staging = fm.temporaryDirectory.appendingPathComponent("ReMTP-promise-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    static func discard(_ staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }

    /// Moves the staged copy to `target` if the transfer copied it cleanly. Returns nil only when `target`
    /// exists afterwards; otherwise the error for the promise's completion handler. Always removes `staging`.
    static func settle(_ summary: TransferSummaryInfo, staged: URL, to target: URL, staging: URL) -> Error? {
        let fm = FileManager.default
        defer { discard(staging) }
        let name = target.lastPathComponent
        if let error = summary.error {
            return error == "cancelled" ? DeviceServiceError.cancelled : DeviceServiceError.io(message: error)
        }
        if summary.filesFailed > 0 {
            return DeviceServiceError.io(message: "\(Format.count(Int(summary.filesFailed), "file")) of “\(name)” couldn’t be copied.")
        }
        if summary.filesSkipped > 0 {
            return DeviceServiceError.io(message: "\(Format.count(Int(summary.filesSkipped), "file")) of “\(name)” \(summary.filesSkipped == 1 ? "was" : "were") skipped.")
        }
        if !summary.renamed.isEmpty {
            return DeviceServiceError.io(message: "“\(name)” couldn’t be copied under its own name.")
        }
        guard fm.fileExists(atPath: staged.path) else {
            return DeviceServiceError.io(message: "“\(name)” wasn’t copied.")
        }
        // Never overwrite: the promised URL must be ours alone.
        if fm.fileExists(atPath: target.path) { return DeviceServiceError.alreadyExists(path: target.path) }
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            return error
        }
        return fm.fileExists(atPath: target.path) ? nil : DeviceServiceError.io(message: "“\(name)” wasn’t copied.")
    }
}
