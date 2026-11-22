import Foundation

// DEMO ONLY. Simulates the core's transfer engine: plan first (folders created up front, space
// checked, conflicts surfaced), then one file at a time with Mac-side read-ahead, per-file device
// wait and idle gaps, progress throttled to ~10 per second, pause/resume/cancel and `.ask` issues
// that wait for `resolve` while other files continue.

final class DemoTransfer: TransferControl, @unchecked Sendable {
    private struct PlannedFile {
        var source: String       // local path (to device) or device path (from device)
        var destFolder: String   // device folder (to device) or local folder (from device)
        var name: String
        var size: UInt64
        var modified: Int64?
    }

    private let service: DemoDeviceService
    private let deviceID: String
    private let session: Int
    private let job: TransferJobSpec
    private let observer: any TransferObserving

    private let cond = NSCondition()
    private var paused = false
    private var cancelled = false
    private var resolutions: [UInt64: ConflictResolution] = [:]
    nonisolated(unsafe) private static var nextIssueID: UInt64 = 1
    private static let issueLock = NSLock()

    // Metrics (only touched on the transfer thread).
    private var filesTotal: UInt32 = 0
    private var filesDone: UInt32 = 0
    private var bytesTotal: UInt64 = 0
    private var bytesDone: UInt64 = 0
    private var currentName = ""
    private var currentDone: UInt64 = 0
    private var currentTotal: UInt64 = 0
    private var samples: [(TimeInterval, UInt64)] = []
    private var fileMs: [Double] = []
    private var waitMs: [Double] = []
    private var idleMs: [Double] = []
    private var lastEmit: TimeInterval = 0
    private var readAhead: (files: UInt32, bytes: UInt64) = (0, 0)
    private var copied: UInt32 = 0
    private var bytesCopied: UInt64 = 0
    private var skipped: UInt32 = 0
    private var failed: UInt32 = 0
    private var renamed: [RenamedFileInfo] = []
    private let started = Date()

    init(service: DemoDeviceService, deviceID: String, session: Int, job: TransferJobSpec, observer: any TransferObserving) {
        self.service = service
        self.deviceID = deviceID
        self.session = session
        self.job = job
        self.observer = observer
    }

    // MARK: TransferControl

    func pause() { cond.lock(); paused = true; cond.unlock() }
    func resume() { cond.lock(); paused = false; cond.broadcast(); cond.unlock() }
    func cancel() { cond.lock(); cancelled = true; cond.broadcast(); cond.unlock() }

    func resolve(issueID: UInt64, choice: ConflictResolution) {
        cond.lock()
        resolutions[issueID] = choice
        cond.broadcast()
        cond.unlock()
    }

    // MARK: Run

    private var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

    private var isCancelled: Bool { cond.lock(); defer { cond.unlock() }; return cancelled }

    private var isLive: Bool {
        service.withLock {
            guard let device = service.device(deviceID) else { return false }
            return device.plugged && device.session == session
        }
    }

    private var device: DemoDevice? { service.withLock { service.device(deviceID) } }

    /// Blocks while paused. Returns false when the job must stop.
    private func waitWhilePaused() -> Bool {
        cond.lock()
        while paused && !cancelled {
            cond.unlock()
            emit(force: true, paused: true)
            cond.lock()
            _ = cond.wait(until: Date().addingTimeInterval(0.25))
        }
        let stop = cancelled
        cond.unlock()
        return !stop && isLive
    }

    func run() {
        guard let device, let storageName = service.withLock({ device.storage(job.storageID)?.info.description }) else {
            return finish(error: "device disconnected")
        }
        if isCancelled { return finish(error: "cancelled") }

        let plan: [PlannedFile]
        let folders: [String]
        do {
            (plan, folders) = try makePlan()
        } catch {
            return finish(error: error.localizedDescription)
        }
        filesTotal = UInt32(plan.count)
        bytesTotal = plan.reduce(0) { $0 + $1.size }
        observer.transferPlanned(filesTotal: filesTotal, bytesTotal: bytesTotal)
        observer.transferPendingSources(plan.map(\.source))

        if job.direction == .toDevice {
            let free = service.withLock { device.storage(job.storageID)?.info.freeBytes ?? 0 }
            if bytesTotal > free {
                let issue = TransferIssueInfo(id: Self.issueID(), path: job.destination, kind: .noSpace,
                                              message: "Needs \(Self.bytes(bytesTotal)); \(storageName) has \(Self.bytes(free)) free.",
                                              existingSize: nil, incomingSize: bytesTotal, destinationFolder: job.destination)
                observer.transferIssue(issue)
                return finish(error: "Not enough space on \(device.ref.name) \(storageName).")
            }
        }

        // Rule 3: create every destination folder before any byte moves.
        do {
            try createFolders(folders)
        } catch {
            return finish(error: error.localizedDescription)
        }

        var pending: [(UInt64, PlannedFile)] = []
        for (index, file) in plan.enumerated() {
            guard waitWhilePaused() else { return finish(error: isCancelled ? "cancelled" : "device disconnected") }
            updateReadAhead(plan, after: index)
            var name = file.name
            if job.direction == .toDevice, job.cardSafeNames {
                let safe = Self.cardSafe(name)
                if safe != name {
                    renamed.append(RenamedFileInfo(from: file.source, to: DevicePath.join(file.destFolder, safe)))
                    name = safe
                }
            }
            if let existing = existingFile(file.destFolder, name) {
                switch job.conflict {
                case .ask:
                    let id = Self.issueID()
                    let sameSize = existing.size == file.size
                    let place = job.direction == .toDevice ? "on \(device.ref.name)" : "on this Mac"
                    let message = sameSize
                        ? "Already \(place) with the same size (\(Self.bytes(existing.size)))."
                        : "Already \(place) with a different size (\(Self.bytes(existing.size)) there, \(Self.bytes(file.size)) here)."
                    let folder = destinationFolder(file.destFolder)
                    let target = job.direction == .toDevice ? DevicePath.join(folder, name) : (folder as NSString).appendingPathComponent(name)
                    observer.transferIssue(TransferIssueInfo(id: id, path: target, kind: .conflict, message: message,
                                                             existingSize: existing.size, incomingSize: file.size,
                                                             destinationFolder: folder,
                                                             existingModified: existing.modified,
                                                             incomingModified: file.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                                                             conflictSource: file.source))
                    var waiting = file
                    waiting.name = name
                    pending.append((id, waiting))
                    continue
                case .skip:
                    skip(file)
                    continue
                case .skipIfSame where existing.size == file.size:
                    skip(file)
                    continue
                case .keepBoth:
                    name = uniqueName(file.destFolder, name)
                case .replace, .skipIfSame:
                    break
                }
            }
            guard send(file, as: name) else { return finish(error: isCancelled ? "cancelled" : "device disconnected") }
        }

        // Files that wait for a decision. Other files have already been copied.
        readAhead = (0, 0)
        while !pending.isEmpty {
            guard waitWhilePaused() else { return finish(error: isCancelled ? "cancelled" : "device disconnected") }
            cond.lock()
            let decided = pending.compactMap { item in resolutions[item.0].map { (item, $0) } }
            if decided.isEmpty { _ = cond.wait(until: Date().addingTimeInterval(0.2)) }
            cond.unlock()
            if decided.isEmpty { emit(force: true); continue }
            for ((id, file), choice) in decided {
                pending.removeAll { $0.0 == id }
                switch choice {
                case .skip:
                    skip(file)
                case .replace:
                    guard send(file, as: file.name) else { return finish(error: isCancelled ? "cancelled" : "device disconnected") }
                case .keepBoth:
                    guard send(file, as: uniqueName(file.destFolder, file.name)) else {
                        return finish(error: isCancelled ? "cancelled" : "device disconnected")
                    }
                }
            }
        }
        finish(error: nil)
    }

    private func skip(_ file: PlannedFile) {
        skipped += 1
        filesDone += 1
        bytesDone += file.size
        observer.transferFileLeftOut(path: file.source)
        emit(force: false)
    }

    // MARK: Planning

    private func makePlan() throws -> ([PlannedFile], [String]) {
        var files: [PlannedFile] = []
        var folders: [String] = [job.destination]
        let fm = FileManager.default
        switch job.direction {
        case .toDevice:
            for source in job.sources {
                let url = URL(fileURLWithPath: source)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: source, isDirectory: &isDir) else { throw DeviceServiceError.notFound(path: source) }
                if !isDir.boolValue {
                    files.append(PlannedFile(source: source, destFolder: job.destination, name: url.lastPathComponent,
                                             size: Self.localSize(url), modified: Self.localDate(url)))
                    continue
                }
                let top = DevicePath.join(job.destination, url.lastPathComponent)
                folders.append(top)
                let base = url.resolvingSymlinksInPath().standardizedFileURL.path
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                while let item = walker?.nextObject() as? URL {
                    let path = item.resolvingSymlinksInPath().standardizedFileURL.path
                    guard path.hasPrefix(base + "/") else { continue }
                    let relative = DevicePath.components(String(path.dropFirst(base.count)))
                    let values = try? item.resourceValues(forKeys: Set(keys))
                    let folder = ([top] + relative.dropLast()).reduce("") { $0.isEmpty ? $1 : DevicePath.join($0, $1) }
                    if values?.isDirectory == true {
                        folders.append(DevicePath.join(folder, relative.last ?? ""))
                    } else {
                        files.append(PlannedFile(source: path, destFolder: folder, name: item.lastPathComponent,
                                                 size: UInt64(values?.fileSize ?? 0),
                                                 modified: values?.contentModificationDate.map { Int64($0.timeIntervalSince1970) }))
                    }
                }
            }
        case .fromDevice:
            let nodes: [(String, DemoNode)] = try service.withLock {
                guard let storage = service.device(deviceID)?.storage(job.storageID) else { throw DeviceServiceError.disconnected }
                return try job.sources.map { path in
                    guard let node = storage.node(at: path) else { throw DeviceServiceError.notFound(path: path) }
                    return (path, node)
                }
            }
            func walk(_ node: DemoNode, devicePath: String, localFolder: String) {
                if node.isDir {
                    let folder = (localFolder as NSString).appendingPathComponent(node.name)
                    folders.append(folder)
                    for child in node.sortedChildren {
                        walk(child, devicePath: DevicePath.join(devicePath, child.name), localFolder: folder)
                    }
                } else {
                    files.append(PlannedFile(source: devicePath, destFolder: localFolder, name: node.name,
                                             size: node.size, modified: node.modified))
                }
            }
            service.withLock {
                for (path, node) in nodes { walk(node, devicePath: path, localFolder: job.destination) }
            }
        }
        guard let remaining = job.pendingSources else { return (files, folders) }
        let paths = Set(remaining.map { Data($0.utf8) })
        files.removeAll { !paths.contains(Data($0.source.utf8)) }
        var neededFolders: Set<String> = [job.destination]
        for file in files {
            var folder = file.destFolder
            while neededFolders.insert(folder).inserted {
                let parent = job.direction == .toDevice ? DevicePath.parent(folder) : (folder as NSString).deletingLastPathComponent
                if parent == folder || parent.isEmpty { break }
                folder = parent
            }
        }
        return (files, folders.filter { neededFolders.contains($0) })
    }

    private func createFolders(_ folders: [String]) throws {
        switch job.direction {
        case .toDevice:
            try service.withLock {
                guard let storage = service.device(deviceID)?.storage(job.storageID) else { throw DeviceServiceError.disconnected }
                for folder in folders {
                    let parts = DevicePath.components(folder).map { job.cardSafeNames ? Self.cardSafe($0) : $0 }
                    storage.makeFolders("/" + parts.joined(separator: "/"))
                }
            }
        case .fromDevice:
            for folder in folders {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
        }
    }

    private func destinationFolder(_ folder: String) -> String {
        job.direction == .toDevice && job.cardSafeNames
            ? "/" + DevicePath.components(folder).map(Self.cardSafe).joined(separator: "/") : folder
    }

    private func existingFile(_ folder: String, _ name: String) -> (size: UInt64, modified: Date?)? {
        switch job.direction {
        case .toDevice:
            return service.withLock {
                let path = destinationFolder(folder)
                guard let node = service.device(deviceID)?.storage(job.storageID)?.node(at: path)?.child(name) else { return nil }
                return (node.isDir ? 0 : node.size, node.modified.map { Date(timeIntervalSince1970: TimeInterval($0)) })
            }
        case .fromDevice:
            let path = (folder as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (UInt64(values?.fileSize ?? 0), values?.contentModificationDate)
        }
    }

    private func uniqueName(_ folder: String, _ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if existingFile(folder, candidate) == nil { return candidate }
            n += 1
        }
    }

    private func updateReadAhead(_ plan: [PlannedFile], after index: Int) {
        guard job.direction == .toDevice else { readAhead = (0, 0); return }
        var files: UInt32 = 0
        var bytes: UInt64 = 0
        for file in plan.dropFirst(index + 1) {
            guard files < 8, bytes + file.size <= 256 * 1_048_576 else { break }
            files += 1
            bytes += file.size
        }
        readAhead = (files, bytes)
    }

    // MARK: Sending one file

    private func send(_ file: PlannedFile, as name: String) -> Bool {
        guard let device else { return false }
        // Idle between files: the next file is already read ahead, so this stays tiny.
        let idle = 0.002 + Double(DemoLibrary.hash(file.source) % 30) / 10_000
        Thread.sleep(forTimeInterval: idle)
        idleMs.append(idle * 1_000)

        let fileStart = now
        currentName = name
        currentDone = 0
        currentTotal = file.size
        emit(force: true)
        while currentDone < file.size {
            guard waitWhilePaused() else { return false }
            let t = now
            let wobble = 1 + 0.025 * sin(t * 1.7) + 0.02 * sin(t * 0.43) + 0.01 * cos(t * 2.9)
            let rate = device.bytesPerSecond * wobble * (job.direction == .fromDevice ? 1.08 : 1)
            let chunk = min(file.size - currentDone, UInt64(rate * 0.05))
            Thread.sleep(forTimeInterval: Double(chunk) / rate)
            currentDone += chunk
            bytesDone += chunk
            emit(force: false)
        }
        // Device wait: last chunk handed over → the device answers (media scan on Android).
        let wait = (job.direction == .toDevice ? device.deviceWaitMs : 6) * (0.85 + Double(DemoLibrary.hash(name) % 30) / 100)
        Thread.sleep(forTimeInterval: wait / 1_000)
        waitMs.append(wait)

        do {
            try commit(file, as: name)
            copied += 1
            bytesCopied += file.size
            let folder = destinationFolder(file.destFolder)
            let destination = job.direction == .toDevice ? DevicePath.join(folder, name) : (folder as NSString).appendingPathComponent(name)
            observer.transferFileDone(path: file.source, destination: destination, bytes: file.size)
        } catch {
            failed += 1
            observer.transferIssue(TransferIssueInfo(id: Self.issueID(), path: file.source, kind: .failed,
                                                     message: error.localizedDescription, existingSize: nil, incomingSize: file.size,
                                                     destinationFolder: destinationFolder(file.destFolder)))
            observer.transferFileLeftOut(path: file.source)
        }
        filesDone += 1
        fileMs.append((now - fileStart) * 1_000 + idle * 1_000)
        emit(force: true)
        return true
    }

    private func commit(_ file: PlannedFile, as name: String) throws {
        switch job.direction {
        case .toDevice:
            try service.withLock {
                guard let storage = service.device(deviceID)?.storage(job.storageID) else { throw DeviceServiceError.disconnected }
                let folderPath = destinationFolder(file.destFolder)
                let folder = storage.makeFolders(folderPath)
                if let old = folder.child(name) {
                    storage.reclaim(old.totalBytes)
                    folder.remove(name)
                }
                folder.file(name, file.size, modified: file.modified ?? DemoLibrary.now)
                storage.consume(file.size)
            }
        case .fromDevice:
            // Sparse placeholder of the right size. A replaced file goes to the Trash first, so
            // the demo never destroys real data.
            let fm = FileManager.default
            let url = URL(fileURLWithPath: file.destFolder).appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try fm.trashItem(at: url, resultingItemURL: nil) }
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw DeviceServiceError.io(message: "Couldn’t create “\(name)”.")
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: file.size)
            try handle.close()
            if let modified = file.modified {
                try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(modified))], ofItemAtPath: url.path)
            }
        }
    }

    // MARK: Progress

    private func emit(force: Bool, paused: Bool = false) {
        let t = now
        guard force || t - lastEmit >= 0.1 else { return }
        lastEmit = t
        samples.append((t, bytesDone))
        samples.removeAll { t - $0.0 > 2.0 }
        var speed: Double = 0
        if !paused, let first = samples.first, t - first.0 > 0.05 {
            speed = Double(bytesDone - first.1) / (t - first.0)
        }
        func avg(_ values: [Double]) -> UInt32 {
            let recent = values.suffix(20)
            return recent.isEmpty ? 0 : UInt32(recent.reduce(0, +) / Double(recent.count))
        }
        observer.transferProgress(TransferProgressInfo(
            filesDone: filesDone, filesTotal: filesTotal, bytesDone: bytesDone, bytesTotal: bytesTotal,
            currentName: currentName, currentBytesDone: currentDone, currentBytesTotal: currentTotal,
            speedBytesPerSec: UInt64(speed), avgMsPerFile: avg(fileMs), deviceWaitMsAvg: avg(waitMs), idleMsAvg: avg(idleMs),
            readAheadFiles: readAhead.files, readAheadBytes: readAhead.bytes, paused: paused))
    }

    private func finish(error: String?) {
        observer.transferFinished(TransferSummaryInfo(
            filesCopied: copied, filesSkipped: skipped, filesFailed: failed, bytes: bytesCopied,
            elapsedMs: UInt64(Date().timeIntervalSince(started) * 1_000), renamed: renamed, error: error))
    }

    // MARK: Helpers

    private static func issueID() -> UInt64 {
        issueLock.lock()
        defer { issueLock.unlock() }
        nextIssueID += 1
        return nextIssueID
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    private static func localSize(_ url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private static func localDate(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Int64($0.timeIntervalSince1970) }
    }

    /// Card-safe names (the core's `names` module does this for real).
    static func cardSafe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "\"*/:<>?\\|").union(.controlCharacters)
        var out = String(String.UnicodeScalarView(name.unicodeScalars.map { bad.contains($0) ? "_" : $0 }))
        while let last = out.last, last == "." || last == " " { out.removeLast() }
        return out.isEmpty ? "_" : out.precomposedStringWithCanonicalMapping
    }
}
