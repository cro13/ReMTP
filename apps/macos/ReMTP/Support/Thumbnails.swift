import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// QuickLook thumbnails for local images, videos and PDFs, cached by path + modification date. Images and videos
/// on a device get the device's own thumbnail, fetched through its session one request at a time per device and
/// held back while a transfer runs on it.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [NSString: [(NSImage?) -> Void]] = [:]
    /// Device thumbnails as the device sent them; empty when it has none.
    private let deviceData = NSCache<NSString, NSData>()
    private var deviceWaiters: [String: [(Data?) -> Void]] = [:]
    private var deviceQueues: [String: [DeviceRequest]] = [:]
    private var devicesBusy: Set<String> = []
    private var devicesWaiting: Set<String> = []
    /// Devices that sent a thumbnail, and common-image misses on the others. A device that never sends one for
    /// its first `probeLimit` JPEG, HEIC or PNG files doesn't do thumbnails: it isn't asked again.
    private var devicesWithThumbnails: Set<String> = []
    private var deviceMisses: [String: Int] = [:]
    private var devicesWithout: Set<String> = []
    private static let probeLimit = 10
    /// Queued device requests kept per device: older ones are for icons scrolled out of sight by now.
    private static let queueLimit = 64
    /// Device requests wait while one of its transfers runs: MTP does one operation at a time.
    weak var transfers: TransferCenter?

    private struct DeviceRequest {
        let key: String
        let deviceID: String
        let storageID: UInt32
        let path: String
        let probes: Bool
        var urgent: Bool
    }

    init() {
        cache.countLimit = 2_000
        deviceData.totalCostLimit = 48 << 20
    }

    static func canThumbnail(_ item: FileItem) -> Bool {
        guard !item.isDirectory, let type = item.type else { return false }
        if item.url != nil { return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf) }
        guard let deviceID = item.deviceID, item.storageID != nil, item.devicePath != nil else { return false }
        return (item.isImage || item.isMovie) && !shared.devicesWithout.contains(deviceID)
    }

    /// The local path, or device + storage + path + size, with the modification date.
    private func source(_ item: FileItem) -> String? {
        let modified = item.modified?.timeIntervalSince1970 ?? 0
        if let url = item.url { return "\(url.path)|\(modified)" }
        guard let deviceID = item.deviceID, let storageID = item.storageID, let path = item.devicePath else { return nil }
        return "device:\(deviceID)|\(storageID)|\(path)|\(modified)|\(item.size ?? 0)"
    }

    private func key(_ item: FileItem, _ size: CGFloat) -> NSString? {
        source(item).map { "\($0)|\(Int(size))" as NSString }
    }

    func cached(for item: FileItem, size: CGFloat) -> NSImage? {
        key(item, size).flatMap { cache.object(forKey: $0) }
    }

    /// The device already said it has no thumbnail for `item`.
    func knownMissing(_ item: FileItem) -> Bool {
        item.url == nil && source(item).flatMap { deviceData.object(forKey: $0 as NSString) }?.length == 0
    }

    func thumbnail(for item: FileItem, size: CGFloat, scale: CGFloat, urgent: Bool = false) async -> NSImage? {
        await withCheckedContinuation { continuation in
            MainActor.assumeIsolated {
                self.thumbnail(for: item, size: size, scale: scale, urgent: urgent) { continuation.resume(returning: $0) }
            }
        }
    }

    /// `urgent` (the inspector's item) is asked first on a device, and also while a transfer runs on it.
    func thumbnail(for item: FileItem, size: CGFloat, scale: CGFloat, urgent: Bool = false,
                   completion: @escaping (NSImage?) -> Void) {
        guard let key = key(item, size) else { return completion(nil) }
        if let image = cache.object(forKey: key) { return completion(image) }
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            return
        }
        inFlight[key] = [completion]
        let finish: (CGImage?) -> Void = { cgImage in
            let image = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / scale,
                                                                          height: CGFloat($0.height) / scale)) }
            if let image { self.cache.setObject(image, forKey: key) }
            let waiting = self.inFlight.removeValue(forKey: key) ?? []
            waiting.forEach { $0(image) }
        }
        guard let url = item.url else {
            return deviceThumbnail(for: item, urgent: urgent) { data in
                guard let data else { return finish(nil) }
                DispatchQueue.global(qos: .userInitiated).async {
                    let image = Self.decode(data, maxPixels: size * scale)
                    DispatchQueue.main.async { MainActor.assumeIsolated { finish(image) } }
                }
            }
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let cgImage = representation?.cgImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finish(cgImage) }
            }
        }
    }

    /// Downscaled to `maxPixels`, upright (EXIF orientation applied).
    private nonisolated static func decode(_ data: Data, maxPixels: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixels.rounded(.up))),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Device thumbnails

    private func deviceThumbnail(for item: FileItem, urgent: Bool, completion: @escaping (Data?) -> Void) {
        guard let key = source(item), let deviceID = item.deviceID, let storageID = item.storageID,
              let path = item.devicePath else { return completion(nil) }
        if let data = deviceData.object(forKey: key as NSString) { return completion(data.length > 0 ? data as Data : nil) }
        if deviceWaiters[key] != nil {
            deviceWaiters[key]?.append(completion)
            if urgent, let index = deviceQueues[deviceID]?.firstIndex(where: { $0.key == key }) {
                deviceQueues[deviceID]?[index].urgent = true
                pump(deviceID)
            }
            return
        }
        deviceWaiters[key] = [completion]
        let probes = item.type.map { type in [UTType.jpeg, .heic, .heif, .png].contains { type.conforms(to: $0) } } ?? false
        var queue = deviceQueues[deviceID] ?? []
        queue.append(DeviceRequest(key: key, deviceID: deviceID, storageID: storageID, path: path, probes: probes, urgent: urgent))
        var dropped: [DeviceRequest] = []
        while queue.count > Self.queueLimit, let index = queue.firstIndex(where: { !$0.urgent }) {
            dropped.append(queue.remove(at: index))
        }
        deviceQueues[deviceID] = queue
        dropped.forEach { deliver($0.key, nil) }
        pump(deviceID)
    }

    private func pump(_ deviceID: String) {
        guard !devicesBusy.contains(deviceID), var queue = deviceQueues[deviceID], !queue.isEmpty else { return }
        guard let session = DeviceSession.current(deviceID), session.isReady, let connection = session.connection,
              !devicesWithout.contains(deviceID) else { return dropQueue(deviceID) }
        guard let index = queue.firstIndex(where: \.urgent) ?? (isTransferring(deviceID) ? nil : queue.indices.first) else {
            return retryLater(deviceID)
        }
        let request = queue.remove(at: index)
        deviceQueues[deviceID] = queue
        devicesBusy.insert(deviceID)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try connection.thumbnail(storageID: request.storageID, path: request.path) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.answered(request, result) }
            }
        }
    }

    private func answered(_ request: DeviceRequest, _ result: Result<Data?, any Error>) {
        let deviceID = request.deviceID
        devicesBusy.remove(deviceID)
        switch result {
        case .success(let data?) where !data.isEmpty:
            deviceData.setObject(data as NSData, forKey: request.key as NSString, cost: data.count)
            devicesWithThumbnails.insert(deviceID)
            deviceMisses[deviceID] = nil
            deliver(request.key, data)
        case .failure(DeviceServiceError.disconnected):
            deliver(request.key, nil)
            return dropQueue(deviceID)
        case .success:
            deviceData.setObject(NSData(), forKey: request.key as NSString, cost: 1)
            deliver(request.key, nil)
            if request.probes, !devicesWithThumbnails.contains(deviceID) {
                deviceMisses[deviceID, default: 0] += 1
                if deviceMisses[deviceID, default: 0] >= Self.probeLimit { devicesWithout.insert(deviceID) }
            }
        case .failure:
            deviceData.setObject(NSData(), forKey: request.key as NSString, cost: 1)
            deliver(request.key, nil)
        }
        pump(deviceID)
    }

    private func deliver(_ key: String, _ data: Data?) {
        (deviceWaiters.removeValue(forKey: key) ?? []).forEach { $0(data) }
    }

    private func dropQueue(_ deviceID: String) {
        (deviceQueues.removeValue(forKey: deviceID) ?? []).forEach { deliver($0.key, nil) }
    }

    private func isTransferring(_ deviceID: String) -> Bool {
        transfers?.jobs.contains {
            $0.deviceID == deviceID && ($0.state == .starting || $0.state == .running) && !$0.isPaused
        } ?? false
    }

    private func retryLater(_ deviceID: String) {
        guard devicesWaiting.insert(deviceID).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                self.devicesWaiting.remove(deviceID)
                self.pump(deviceID)
            }
        }
    }
}
