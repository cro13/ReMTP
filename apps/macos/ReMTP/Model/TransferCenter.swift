import Foundation
import Observation

/// One job in the app's queue. Jobs on the same device run one after another.
struct QueuedTransfer: Identifiable {
    enum State: Equatable {
        case queued, starting, running, finished, failed(String), cancelled
    }

    struct CopyHistory {
        let id: UUID
        let filesTotal: UInt32?
        let bytesTotal: UInt64?
        let summary: TransferSummaryInfo
        let parts: Int
    }

    let id = UUID()
    let spec: TransferJobSpec
    let deviceID: String
    let deviceName: String
    /// "Lisbon 2026 › Raw → Galaxy S23 › Download › Lisbon 2026 › Raw"
    let route: String
    /// "Galaxy S23 › Download › Lisbon 2026"
    let destinationLabel: String
    let sourceFolder: PaneLocation
    let destinationFolder: PaneLocation
    /// Top-level sources: compare key → is folder.
    let sources: [String: Bool]
    let firstItem: FileItem?
    let linkDescription: String
    let enqueuedAt = Date()

    var state: State = .queued
    var filesTotal: UInt32?
    var bytesTotal: UInt64?
    var progress: TransferProgressInfo?
    var doneKeys: Set<String> = []
    var confirmedFilesCopied: UInt32 = 0
    var confirmedBytesCopied: UInt64 = 0
    var summary: TransferSummaryInfo?
    var startedAt: Date?
    var finishedAt: Date?
    var handle: (any TransferControl)?
    var onFinish: [(TransferSummaryInfo) -> Void] = []
    /// The device went away while this job was active or before it could start.
    var deviceGone = false
    var continuationID: UUID?
    var copyHistory: CopyHistory?
    var pendingSources: [Data: String]?

    var isActive: Bool { state == .queued || state == .starting || state == .running }
    var isPaused: Bool { progress?.paused ?? false }

    var interruptedByDisconnect: Bool {
        guard deviceGone, continuationID == nil else { return false }
        if case .failed = state { return true }
        return isActive
    }

    var filesCopied: UInt32 { summary?.filesCopied ?? confirmedFilesCopied }
    var remainingFileCount: Int? { pendingSources?.count ?? spec.pendingSources?.count }

    var copyID: UUID { copyHistory?.id ?? id }
    var isContinuation: Bool { copyHistory != nil }
    var copyFilesTotal: UInt32? { copyHistory?.filesTotal ?? filesTotal }
    var copyFilesCopied: UInt32 { (copyHistory?.summary.filesCopied ?? 0) + filesCopied }
    var copyBytesTotal: UInt64? { copyHistory?.bytesTotal ?? progress?.bytesTotal ?? bytesTotal }
    var copyBytesDone: UInt64 { (copyHistory?.summary.bytes ?? 0) + (summary?.bytes ?? progress?.bytesDone ?? confirmedBytesCopied) }
    var copyParts: Int { (copyHistory?.parts ?? 0) + (filesCopied > 0 ? 1 : 0) }

    var copySummary: TransferSummaryInfo? {
        guard var summary else { return nil }
        if let previous = copyHistory?.summary {
            summary.filesCopied += previous.filesCopied
            summary.filesSkipped += previous.filesSkipped
            summary.filesFailed += previous.filesFailed
            summary.bytes += previous.bytes
            summary.elapsedMs += previous.elapsedMs
            summary.renamed = previous.renamed + summary.renamed
        }
        return summary
    }

    var copiedFileFraction: Double {
        guard let total = copyFilesTotal, total > 0 else { return 0 }
        return min(1, Double(copyFilesCopied) / Double(total))
    }

    var title: String {
        if sources.count == 1, let item = firstItem {
            if item.isDirectory, let files = copyFilesTotal { return "\(item.name) · \(Format.count(Int(files), "file"))" }
            return item.name
        }
        if let files = copyFilesTotal { return Format.count(Int(files), "file") }
        return Format.count(sources.count, "item")
    }

    var fraction: Double {
        guard let total = copyBytesTotal, total > 0 else { return state == .finished ? 1 : 0 }
        return min(1, Double(copyBytesDone) / Double(total))
    }

    /// A Finder promise: the core writes into a staging folder that is gone once the promise settles.
    var isPromise: Bool { spec.direction == .fromDevice && destinationFolder.enginePath != spec.destination }
}

struct PendingIssue: Identifiable {
    /// The core numbers issues per job, so a row is identified by its job and the issue ID together.
    struct Key: Hashable {
        let jobID: UUID
        let issueID: UInt64
    }

    var id: Key { Key(jobID: jobID, issueID: info.id) }
    let jobID: UUID
    let info: TransferIssueInfo
    let direction: TransferDirection
    /// The user's answer to a conflict that arrived before the job's transfer handle did. It is delivered
    /// (and the row removed) as soon as the handle arrives; until then it can be changed.
    var queuedAnswer: ConflictResolution?
    /// How a problem's file can be copied again (the core's `retry`); nil for conflicts and Finder promises.
    var retry: TransferRetryInfo?
    var renamedName: String?

    var name: String { renamedName ?? (info.path as NSString).lastPathComponent }
    var renameSource: String? {
        guard renamedName == nil, info.kind == .invalidName || info.kind == .nameTooLong,
              info.incomingSize != nil else { return nil }
        return info.path
    }

    func destinationPath(in job: QueuedTransfer?) -> String? {
        if job?.isPromise == true { return job?.destinationFolder.enginePath }
        return info.destinationFolder ?? retry?.folder ?? job?.destinationFolder.enginePath
    }

    /// Only conflicts can be answered with Replace / Keep Both / Skip. Every other kind is informational:
    /// the core has already left that file out.
    var isConflict: Bool { info.kind == .conflict }
    /// A conflict nobody has answered yet.
    var needsDecision: Bool { isConflict && queuedAnswer == nil }

    /// Short headline for the row.
    var headline: String {
        switch info.kind {
        case .conflict: return "Already exists"
        case .invalidName: return "Name isn’t allowed there"
        case .nameTooLong: return "Name is too long"
        case .tooLargeForStorage: return "Too large for this storage"
        case .noSpace: return "Not enough space"
        case .failed: return "Couldn’t copy"
        }
    }
}

/// What a destination folder should show while files arrive.
struct ArrivalInfo: Equatable {
    var currentName: String?
    var currentSize: UInt64
    var fraction: Double
    var remaining: Int
}

enum DrawerTab: Hashable {
    case inProgress, attention, done
}

/// The app's transfer queue. Survives pane navigation; lives as long as the app.
@Observable
@MainActor
final class TransferCenter {
    var jobs: [QueuedTransfer] = []
    var issues: [PendingIssue] = []
    /// Recent speed samples (bytes/s) per job, ~10 per second, newest last. Per job, so the drawer's graph
    /// shows the job its headline describes (jobs on two devices run at once) and starts fresh for each job.
    private(set) var speedHistory: [UUID: [Double]] = [:]
    var drawerExpanded = false
    var drawerTab: DrawerTab = .inProgress
    private(set) var allPaused = false
    /// Set on quit: nothing new starts.
    private(set) var stopped = false
    /// Bumps when anything that the status column shows changes.
    private(set) var statusGeneration = 0
    @ObservationIgnored weak var app: AppModel?

    // MARK: Queries

    var running: QueuedTransfer? { jobs.first { $0.state == .running || $0.state == .starting } }
    var activeJobs: [QueuedTransfer] { jobs.filter(\.isActive) }
    var queuedCount: Int { jobs.filter { $0.state == .queued }.count }
    var finishedCopies: [QueuedTransfer] { jobs.filter { $0.finishedAt != nil && $0.continuationID == nil } }

    var doneToday: [QueuedTransfer] {
        let calendar = Calendar.current
        return finishedCopies.filter { $0.finishedAt.map(calendar.isDateInToday) == true }.reversed()
    }

    var interruptedCopies: [QueuedTransfer] {
        let calendar = Calendar.current
        let interrupted = jobs.reversed().filter { job in
            job.interruptedByDisconnect && (job.isActive || job.finishedAt.map(calendar.isDateInToday) == true)
        }
        return interrupted.filter { $0.startedAt != nil || $0.isContinuation }
            + interrupted.filter { $0.startedAt == nil && !$0.isContinuation }
    }

    var hasAnything: Bool { !jobs.isEmpty }

    func job(_ id: UUID) -> QueuedTransfer? { jobs.first { $0.id == id } }

    /// Opens the drawer on the tab that has something in it.
    func showDrawer() {
        if !activeJobs.isEmpty {
            drawerTab = .inProgress
        } else if !issues.isEmpty {
            drawerTab = .attention
        } else if !doneToday.isEmpty {
            drawerTab = .done
        }
        drawerExpanded = true
    }

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    /// Transfer state for an item in the pane it is being copied from.
    func sourceStatus(for item: FileItem, in location: PaneLocation) -> ItemStatus? {
        for job in jobs where job.isActive && job.sourceFolder == location {
            guard let isDir = job.sources[item.compareKey] else { continue }
            if job.state != .running { return .queued }
            if job.doneKeys.contains(item.compareKey) { return nil }
            if isDir { return .copyingFolder }
            if let p = job.progress, FileItem.compareKey(p.currentName) == item.compareKey {
                return .copying(p.currentBytesTotal > 0 ? Double(p.currentBytesDone) / Double(p.currentBytesTotal) : 0)
            }
            return .queued
        }
        return nil
    }

    func arrivals(in location: PaneLocation, existing: [String: FileItem]) -> ArrivalInfo? {
        var info = ArrivalInfo(currentName: nil, currentSize: 0, fraction: 0, remaining: 0)
        var any = false
        for job in jobs where job.isActive && job.destinationFolder == location {
            any = true
            if job.state == .running, let p = job.progress {
                var remaining = Int(p.filesTotal) - Int(p.filesDone)
                let key = FileItem.compareKey(p.currentName)
                if !p.currentName.isEmpty, job.sources[key] == false, existing[key] == nil, p.currentBytesDone < p.currentBytesTotal {
                    info.currentName = p.currentName
                    info.currentSize = p.currentBytesTotal
                    info.fraction = p.currentBytesTotal > 0 ? Double(p.currentBytesDone) / Double(p.currentBytesTotal) : 0
                    remaining -= 1
                }
                info.remaining += max(0, remaining)
            } else {
                info.remaining += Int(job.filesTotal ?? UInt32(job.sources.count))
            }
        }
        return any ? info : nil
    }

    // MARK: Queue control

    func enqueue(_ job: QueuedTransfer) {
        jobs.append(job)
        statusGeneration &+= 1
        pump()
    }

    func enqueueContinuation(_ job: QueuedTransfer, of id: UUID) -> UUID? {
        guard let oldIndex = index(id) else { return nil }
        let previous = jobs[oldIndex]
        guard previous.interruptedByDisconnect, let summary = previous.copySummary else { return nil }
        var job = job
        job.copyHistory = .init(id: previous.copyID, filesTotal: previous.copyFilesTotal,
                                bytesTotal: previous.copyBytesTotal, summary: summary, parts: previous.copyParts)
        job.doneKeys = previous.doneKeys
        jobs[oldIndex].continuationID = job.id
        jobs[oldIndex].pendingSources = nil
        enqueue(job)
        return job.id
    }

    private func pump() {
        guard !allPaused, !stopped else { return }
        var busy = Set(jobs.filter { $0.state == .running || $0.state == .starting }.map(\.deviceID))
        for i in jobs.indices where jobs[i].state == .queued && !busy.contains(jobs[i].deviceID) {
            busy.insert(jobs[i].deviceID)
            start(jobs[i].id)
        }
    }

    private func start(_ id: UUID) {
        guard let i = index(id) else { return }
        guard let connection = app?.connection(for: jobs[i].deviceID) else {
            jobs[i].deviceGone = true
            fail(id, message: "\(jobs[i].deviceName) isn’t connected.")
            return
        }
        jobs[i].state = .starting
        jobs[i].startedAt = Date()
        let spec = jobs[i].spec
        let observer = TransferObserverBridge(jobID: id, center: self)
        Task {
            do {
                let handle = try await offMain { try connection.startTransfer(spec, observer: observer) }
                self.attach(handle, to: id)
            } catch {
                if error as? DeviceServiceError == .disconnected, let i = self.index(id), self.jobs[i].finishedAt == nil {
                    self.jobs[i].deviceGone = true
                }
                self.fail(id, message: error.localizedDescription)
            }
        }
    }

    /// The core's handle for a started job. Answers the user gave before it existed are delivered now.
    func attach(_ handle: any TransferControl, to id: UUID) {
        guard let i = index(id), jobs[i].finishedAt == nil else {
            handle.cancel()
            return
        }
        if jobs[i].state == .cancelled || jobs[i].deviceGone || stopped {
            handle.cancel()
            return
        }
        jobs[i].handle = handle
        if jobs[i].state == .starting { jobs[i].state = .running }
        for issue in issues where issue.jobID == id {
            if let answer = issue.queuedAnswer {
                handle.resolve(issueID: issue.info.id, choice: answer)
                if answer == .skip, let source = issue.info.conflictSource { settleSource(id, path: source) }
            }
        }
        issues.removeAll { $0.jobID == id && $0.queuedAnswer != nil }
        statusGeneration &+= 1
    }

    private func fail(_ id: UUID, message: String) {
        guard let job = job(id) else { return }
        let summary = TransferSummaryInfo(filesCopied: job.confirmedFilesCopied, filesSkipped: 0, filesFailed: 0,
                                          bytes: job.confirmedBytesCopied, elapsedMs: 0, renamed: [], error: message)
        finished(id, summary)
    }

    func pause(_ id: UUID) {
        guard let i = index(id) else { return }
        jobs[i].handle?.pause()
        jobs[i].progress?.paused = true
    }

    func resume(_ id: UUID) {
        guard let i = index(id) else { return }
        jobs[i].handle?.resume()
        jobs[i].progress?.paused = false
    }

    func cancel(_ id: UUID) {
        guard let i = index(id) else { return }
        switch jobs[i].state {
        case .queued:
            finished(id, TransferSummaryInfo(filesCopied: 0, filesSkipped: 0, filesFailed: 0, bytes: 0, elapsedMs: 0,
                                             renamed: [], error: "cancelled"))
        case .starting, .running:
            jobs[i].handle?.cancel()
            if jobs[i].handle == nil { jobs[i].state = .cancelled }
        default:
            break
        }
    }

    func pauseAll() {
        allPaused = true
        for job in jobs where job.state == .running { pause(job.id) }
    }

    func resumeAll() {
        allPaused = false
        for job in jobs where job.state == .running { resume(job.id) }
        pump()
    }

    func cancelAll() {
        for job in jobs where job.isActive { cancel(job.id) }
    }

    /// Moves a queued job to the front of its device's queue.
    func moveToFront(_ id: UUID) {
        guard let i = index(id), jobs[i].state == .queued else { return }
        let job = jobs.remove(at: i)
        let firstQueued = jobs.firstIndex { $0.state == .queued } ?? jobs.endIndex
        jobs.insert(job, at: firstQueued)
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    /// Answers a conflict, or changes an answer that is still queued. Other kinds can't be answered (the core
    /// never asked); they are only dismissed.
    func resolve(_ issue: PendingIssue, _ choice: ConflictResolution) {
        guard let i = issues.firstIndex(where: { $0.id == issue.id }) else { return }
        guard issues[i].isConflict else {
            issues.remove(at: i)
            return
        }
        guard let job = job(issue.jobID), job.finishedAt == nil else {
            issues.remove(at: i)
            return
        }
        if let handle = job.handle {
            handle.resolve(issueID: issue.info.id, choice: choice)
            if choice == .skip, let source = issue.info.conflictSource { settleSource(job.id, path: source) }
            issues.remove(at: i)
        } else {
            // The issue arrived before `startTransfer` returned: keep the row and deliver on `attach`.
            issues[i].queuedAnswer = choice
        }
    }

    func resolveAll(_ choice: ConflictResolution) {
        for issue in issues where issue.needsDecision { resolve(issue, choice) }
    }

    /// The row's close button: skips a conflict, dismisses anything else.
    func dismiss(_ issue: PendingIssue) {
        if issue.isConflict {
            resolve(issue, .skip)
        } else {
            issues.removeAll { $0.id == issue.id }
        }
    }

    /// Clears every informational row (not conflicts).
    func dismissProblems() {
        issues.removeAll { !$0.isConflict }
    }

    func retryRenamedSource(of issue: PendingIssue, at source: String) {
        guard let i = issues.firstIndex(where: { $0.id == issue.id }), issues[i].renameSource != nil,
              let job = job(issue.jobID), !job.isPromise,
              let folder = issues[i].destinationPath(in: job) else { return }
        issues[i].renamedName = (source as NSString).lastPathComponent
        issues[i].retry = TransferRetryInfo(source: source, folder: folder, cardSafeName: nil, keepBoth: false)
        if app?.connection(for: job.deviceID) != nil { retry(issues[i]) }
    }

    /// Copies a problem row's file again as a job of its own (under its card-safe name when that is what
    /// failed, with Keep Both when its name is taken), behind the device's other jobs, and removes the row.
    func retry(_ issue: PendingIssue) {
        guard let i = issues.firstIndex(where: { $0.id == issue.id }), let retry = issues[i].retry,
              let job = job(issue.jobID) else { return }
        let toDevice = job.spec.direction == .toDevice
        var spec = job.spec
        spec.sources = [retry.source]
        spec.destination = retry.folder
        spec.pendingSources = nil
        if retry.cardSafeName != nil { spec.cardSafeNames = true }
        if retry.keepBoth { spec.conflict = .keepBoth }
        let name = toDevice ? (retry.source as NSString).lastPathComponent : DevicePath.lastComponent(retry.source)
        let parent = toDevice ? (retry.source as NSString).deletingLastPathComponent : DevicePath.parent(retry.source)
        func location(_ path: String, local: Bool) -> PaneLocation {
            local ? .mac(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
                : .device(DeviceLocation(deviceID: job.deviceID, storageID: spec.storageID, path: path))
        }
        let topLevel = parent == job.sourceFolder.enginePath
        let originalName = issues[i].renamedName == nil ? name : (issues[i].info.path as NSString).lastPathComponent
        let isDirectory = topLevel ? job.sources[FileItem.compareKey(originalName)] ?? false : false
        let item = FileItem(name: name, isDirectory: isDirectory, size: isDirectory ? nil : issues[i].info.incomingSize, modified: nil,
                            url: toDevice ? URL(fileURLWithPath: retry.source) : nil, devicePath: toDevice ? nil : retry.source)
        let sourceFolder = topLevel ? job.sourceFolder : location(parent, local: toDevice)
        let destinationFolder = retry.folder == job.spec.destination ? job.destinationFolder : location(retry.folder, local: !toDevice)
        func label(_ folder: PaneLocation) -> String {
            switch folder {
            case .mac(let url):
                return (["Mac"] + url.pathComponents.dropFirst().suffix(2)).joined(separator: " › ")
            case .device(let loc):
                let storageName = app?.session(for: loc.deviceID)?.storage(loc.storageID)?.shortName ?? "Storage"
                let parts = DevicePath.isRoot(loc.path) ? [storageName] : DevicePath.components(loc.path)
                return ([job.deviceName] + parts).joined(separator: " › ")
            }
        }
        let destinationLabel = label(destinationFolder)
        let route = "\(label(sourceFolder)) › \(name) → \(destinationLabel)"
        let again = QueuedTransfer(
            spec: spec, deviceID: job.deviceID, deviceName: job.deviceName, route: route,
            destinationLabel: destinationLabel, sourceFolder: sourceFolder, destinationFolder: destinationFolder,
            sources: [item.compareKey: isDirectory], firstItem: item, linkDescription: job.linkDescription)
        issues.remove(at: i)
        enqueue(again)
    }

    // MARK: Device lifecycle

    /// `deviceID` was unplugged. Queued jobs fail now. Running jobs stop and fail when the core reports
    /// back (closing the session ends them), or after a grace period if it never does.
    func deviceDisconnected(_ deviceID: String, name: String) {
        let message = "\(name) was disconnected."
        for job in jobs where job.deviceID == deviceID && job.isActive {
            guard let i = index(job.id), jobs[i].isActive else { continue }
            jobs[i].deviceGone = true
            switch jobs[i].state {
            case .queued:
                fail(job.id, message: message)
            default:
                jobs[i].handle?.cancel()
                let id = job.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let job = self.job(id), job.finishedAt == nil else { return }
                        self.fail(id, message: message)
                    }
                }
            }
        }
        // Nobody can answer these any more.
        issues.removeAll { issue in issue.isConflict && jobs.contains { $0.id == issue.jobID && $0.deviceID == deviceID } }
        statusGeneration &+= 1
    }

    /// Quit: cancel everything and start nothing new.
    func stopAll() {
        stopped = true
        cancelAll()
    }

    #if DEBUG
    /// Self-check only: adds a job as if `startTransfer` were still running for it (no handle yet).
    func insertStartingForSelfCheck(_ job: QueuedTransfer) {
        var job = job
        job.state = .starting
        jobs.append(job)
    }

    /// Self-check only: removes jobs and their rows without finishing them.
    func removeForSelfCheck(_ ids: Set<UUID>) {
        jobs.removeAll { ids.contains($0.id) }
        issues.removeAll { ids.contains($0.jobID) }
        statusGeneration &+= 1
    }
    #endif

    // MARK: Observer events (main thread)

    fileprivate func planned(_ id: UUID, files: UInt32, bytes: UInt64) {
        guard let i = index(id) else { return }
        jobs[i].filesTotal = files
        jobs[i].bytesTotal = bytes
        if jobs[i].state == .starting { jobs[i].state = .running }
        statusGeneration &+= 1
    }

    fileprivate func setPendingSources(_ id: UUID, paths: [String]) {
        guard let i = index(id), jobs[i].finishedAt == nil else { return }
        jobs[i].pendingSources = Dictionary(paths.map { (Data($0.utf8), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func settleSource(_ id: UUID, path: String) {
        guard let i = index(id) else { return }
        jobs[i].pendingSources?.removeValue(forKey: Data(path.utf8))
    }

    fileprivate func progressed(_ id: UUID, _ progress: TransferProgressInfo) {
        guard let i = index(id) else { return }
        if jobs[i].state == .starting { jobs[i].state = .running }
        jobs[i].progress = progress
        if !progress.paused {
            var samples = speedHistory[id] ?? []
            samples.append(Double(progress.speedBytesPerSec))
            if samples.count > 300 { samples.removeFirst(samples.count - 300) }
            speedHistory[id] = samples
        }
        statusGeneration &+= 1
    }

    fileprivate func fileDone(_ id: UUID, path: String, destination: String? = nil, bytes: UInt64 = 0) {
        guard let i = index(id), jobs[i].finishedAt == nil else { return }
        settleSource(id, path: path)
        if destination != nil {
            jobs[i].confirmedFilesCopied += 1
            jobs[i].confirmedBytesCopied += bytes
        }
        let job = jobs[i]
        let source = job.sourceFolder.atTransferPath(path)
        if let relative = source.relativeComponents(to: job.sourceFolder), relative.count == 1, let name = relative.first {
            let key = FileItem.compareKey(name)
            if job.sources[key] == false { jobs[i].doneKeys.insert(key) }
        }
        if !job.isPromise, let destination {
            let target = job.destinationFolder.atTransferPath(destination)
            app?.transferWrote(target, bytes: bytes, from: source)
        }
        statusGeneration &+= 1
    }

    fileprivate func issue(_ id: UUID, _ info: TransferIssueInfo) {
        guard let job = job(id), job.finishedAt == nil else { return }
        var issue = PendingIssue(jobID: id, info: info, direction: job.spec.direction)
        if issue.isConflict && job.deviceGone { return }
        if !issue.isConflict, !job.isPromise { issue.retry = info.retry }
        issues.removeAll { $0.id == issue.id }
        issues.append(issue)
    }

    fileprivate func finished(_ id: UUID, _ summary: TransferSummaryInfo) {
        // A job ends once (a disconnected job may have been failed locally before the core reported).
        guard let i = index(id), jobs[i].finishedAt == nil else { return }
        speedHistory[id] = nil
        var summary = summary
        if let error = summary.error,
           error == "device disconnected" || error.hasPrefix("device disconnected;")
               || error == DeviceServiceError.disconnected.localizedDescription {
            jobs[i].deviceGone = true
        }
        if jobs[i].deviceGone, summary.error != nil, jobs[i].startedAt != nil {
            summary.error = "\(jobs[i].deviceName) was disconnected."
        }
        jobs[i].summary = summary
        jobs[i].finishedAt = Date()
        jobs[i].handle = nil
        switch summary.error {
        case nil: jobs[i].state = .finished
        case "cancelled"?: jobs[i].state = .cancelled
        case let message?: jobs[i].state = .failed(message)
        }
        if !jobs[i].interruptedByDisconnect { jobs[i].pendingSources = nil }
        let callbacks = jobs[i].onFinish
        jobs[i].onFinish = []
        callbacks.forEach { $0(summary) }
        issues.removeAll { $0.jobID == id && $0.isConflict }
        statusGeneration &+= 1
        app?.transferFinished(jobs[i])
        pump()
    }
}

/// Receives core callbacks on arbitrary threads and forwards them, in order, to the main actor.
final class TransferObserverBridge: TransferObserving, @unchecked Sendable {
    private let jobID: UUID
    private weak var center: TransferCenter?

    init(jobID: UUID, center: TransferCenter) {
        self.jobID = jobID
        self.center = center
    }

    func transferPlanned(filesTotal: UInt32, bytesTotal: UInt64) {
        onMain { [self] in center?.planned(jobID, files: filesTotal, bytes: bytesTotal) }
    }

    func transferPendingSources(_ sources: [String]) {
        onMain { [self] in center?.setPendingSources(jobID, paths: sources) }
    }

    func transferProgress(_ progress: TransferProgressInfo) {
        onMain { [self] in center?.progressed(jobID, progress) }
    }

    func transferFileDone(path: String, destination: String, bytes: UInt64) {
        onMain { [self] in center?.fileDone(jobID, path: path, destination: destination, bytes: bytes) }
    }

    func transferFileLeftOut(path: String) {
        onMain { [self] in center?.fileDone(jobID, path: path) }
    }

    func transferIssue(_ issue: TransferIssueInfo) {
        onMain { [self] in center?.issue(jobID, issue) }
    }

    func transferFinished(_ summary: TransferSummaryInfo) {
        onMain { [self] in center?.finished(jobID, summary) }
    }
}
