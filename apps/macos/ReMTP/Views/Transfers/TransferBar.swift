import SwiftUI

/// Bottom of the window: the expanded drawer, or the collapsed transfer bar while anything is queued,
/// running or paused, there are issues, or jobs failed and the drawer hasn't shown them yet. A clean finish
/// leaves no bar: a toast floats over the panes for a few seconds instead.
struct TransferArea<Content: View>: View {
    let app: AppModel
    @ViewBuilder let content: () -> Content
    /// Finished jobs already reported (by a toast or the open drawer); nil until the area first appears.
    @State private var reported: Set<UUID>?
    @State private var toast: TransferToast.Summary?
    @State private var shownFiles: [UUID: CurrentTransferFile] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let transfers = app.transfers
        let files = transfers.activeJobs.compactMap(CurrentTransferFile.init)
        let visibleFiles = files.filter { $0.isSlow || $0.continues(shownFiles[$0.jobID]) }
        let currentToast = toast
        VStack(spacing: 0) {
            content()
            if transfers.drawerExpanded {
                TransferDrawer(app: app, jobsShowingCurrentFile: Set(visibleFiles.map(\.jobID)))
                    .transition(.move(edge: .bottom))
            } else if showsBar(transfers) {
                TransferBar(app: app, reported: reported ?? [])
            }
        }
        .frame(maxWidth: .infinity)
        .overlayPreferenceValue(PaneBoundsKey.self) { bounds in
            GeometryReader { proxy in
                if let toast = currentToast {
                    let panes = app.devicePaneBrowsable ? [app.macPane, app.devicePane] : [app.macPane]
                    let folder = panes.first { toast.destination?.isSameFolder(as: $0.location) == true }?.kind
                    let receiver = panes.first { pane in
                        if pane.kind == .mac { return toast.receiver == .mac }
                        return pane.location?.device.map { toast.receiver == .device($0.deviceID) } ?? false
                    }?.kind
                    let target = (folder ?? receiver).flatMap { bounds[$0] }.map { proxy[$0] }
                    let area = target ?? CGRect(origin: .zero, size: proxy.size)
                    TransferToast(summary: toast) {
                        app.showTransfers(tab: .done)
                    } dismiss: {
                        if self.toast?.id == toast.id { show(nil) }
                    }
                    .id(toast.id)
                    #if DEBUG
                    .snapshotFrame(.toast)
                    #endif
                    .padding(.horizontal, 12)
                    .frame(width: area.width)
                    .position(x: area.midX, y: area.maxY - PaneFooter.height - 12 - TransferToast.height / 2)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                }
            }
        }
        .onChange(of: Trigger(transfers), initial: true) { update(transfers) }
        .onChange(of: files, initial: true) {
            shownFiles = Dictionary(uniqueKeysWithValues: visibleFiles.map { ($0.jobID, $0) })
        }
    }

    /// What `update` depends on.
    private struct Trigger: Equatable {
        let finished: [UUID]
        let idle: Bool
        let drawer: Bool
        let tab: DrawerTab
        let issueJobs: Set<UUID>

        @MainActor init(_ transfers: TransferCenter) {
            finished = transfers.finishedCopies.map(\.id)
            idle = transfers.activeJobs.isEmpty && transfers.issues.isEmpty
            drawer = transfers.drawerExpanded
            tab = transfers.drawerTab
            issueJobs = Set(transfers.issues.map(\.jobID))
        }
    }

    private func showsBar(_ transfers: TransferCenter) -> Bool {
        !transfers.activeJobs.isEmpty || !transfers.issues.isEmpty
            || transfers.interruptedCopies.contains { !$0.isPromise && $0.remainingFileCount != 0 }
            || transfers.finishedCopies.contains { $0.hasProblems && reported?.contains($0.id) == false }
    }

    /// Once the queue is idle, reports the jobs that finished since the last report: a toast when they all
    /// went well; with problems the bar stays until the drawer has been opened.
    private func update(_ transfers: TransferCenter) {
        let finished = transfers.finishedCopies
        guard let seen = reported else {
            reported = Set(finished.map(\.id))
            return
        }
        if transfers.drawerExpanded {
            // An issue row may report a file problem, but only Done Today shows the disconnect itself.
            let issueJobs = Set(transfers.issues.map(\.jobID))
            let shown = finished.filter { job in
                !job.hasProblems || transfers.drawerTab == .done
                    || (!job.interruptedByDisconnect && issueJobs.contains(job.id))
            }
            reported = seen.union(shown.map(\.id))
            show(nil)
            return
        }
        guard transfers.activeJobs.isEmpty, transfers.issues.isEmpty else { return show(nil) }
        let fresh = finished.filter { !seen.contains($0.id) }
        guard !fresh.isEmpty, !fresh.contains(where: \.hasProblems) else { return }
        reported = seen.union(fresh.map(\.id))
        show(TransferToast.Summary(fresh))
    }

    private func show(_ summary: TransferToast.Summary?) {
        guard summary != nil || toast != nil else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.25)) { toast = summary }
        if let summary {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: summary.announcement,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}

private extension QueuedTransfer {
    /// Failed, or finished with files that couldn't be copied.
    var hasProblems: Bool {
        if case .failed = state { return true }
        return (summary?.filesFailed ?? 0) > 0
    }
}

/// Keep showing a slow file until the current file changes or its byte count resets.
private struct CurrentTransferFile: Equatable {
    let jobID: UUID
    let name: String
    let total: UInt64
    let copied: UInt64
    let isSlow: Bool

    init?(_ job: QueuedTransfer) {
        guard job.state == .running, let p = job.progress, !p.currentName.isEmpty, p.currentBytesTotal > 0 else { return nil }
        jobID = job.id
        name = p.currentName
        total = p.currentBytesTotal
        copied = p.currentBytesDone
        isSlow = copied < total && p.speedBytesPerSec > 0 && total >= p.speedBytesPerSec
    }

    func continues(_ previous: Self?) -> Bool {
        guard let previous else { return false }
        return name == previous.name && total == previous.total && copied >= previous.copied
    }
}

/// The same transfer status leads in both the drawer and the collapsed bar.
struct RunningTransferStatus {
    let title: String
    let detail: String?
    let timeLeft: String?

    /// `held`: Pause All is holding the queue, so a queued job won't start.
    init(job: QueuedTransfer, issues: [PendingIssue], held: Bool = false) {
        let p = job.progress
        let waiting = issues.filter { $0.jobID == job.id && $0.needsDecision }.count
        let copied = job.copyBytesTotal.map { Format.bytesOf(job.copyBytesDone, $0) }
        if job.state == .running, !job.isPaused, !job.interruptedByDisconnect,
           let p, p.speedBytesPerSec > 0, p.bytesTotal > p.bytesDone {
            timeLeft = Format.timeLeft(Double(p.bytesTotal - p.bytesDone) / Double(p.speedBytesPerSec)) + " left"
        } else {
            timeLeft = nil
        }
        if job.state == .queued {
            title = held ? "Paused" : "Queued"
            detail = job.isContinuation ? copied : job.bytesTotal.map(Format.bytes)
        } else if job.isPaused {
            title = "Paused"
            detail = copied
        } else if waiting > 0 && (p?.speedBytesPerSec ?? 0) == 0 {
            title = "Waiting for you"
            detail = "\(Format.count(waiting, "file")) need\(waiting == 1 ? "s" : "") a choice"
        } else if job.isContinuation {
            title = "Continuing · \(InterruptedCopyStatus.copiedDetail(job))"
            detail = copied
        } else if let timeLeft {
            title = timeLeft
            detail = copied
        } else if let p {
            title = p.bytesTotal > 0 && p.bytesDone >= p.bytesTotal ? "Finishing…" : "Copying…"
            detail = copied
        } else {
            title = "Planning…"
            detail = nil
        }
    }
}

struct InterruptedCopyStatus {
    let title: String
    let detail: String
    let fraction: Double
    let actionTitle: String
    let reconnectHint: String
    let accessHint: String
    let paneMessage: String

    init(_ job: QueuedTransfer) {
        let started = job.startedAt != nil || job.isContinuation
        title = "\(started ? "Copy stopped" : "Copy didn’t start"): \(job.deviceName) disconnected"
        detail = Self.copiedDetail(job)
        fraction = job.isPromise ? 0 : job.copiedFileFraction
        actionTitle = job.remainingFileCount.map { "Copy the Remaining \($0.formatted())" } ?? "Copy Remaining Files"
        if job.isPromise {
            reconnectHint = "Reconnect to copy again"
            accessHint = "Allow file access to copy again"
        } else if let remaining = job.remainingFileCount {
            reconnectHint = remaining == 0 ? "No files left to copy" : "Reconnect to copy the remaining \(remaining.formatted())"
            accessHint = remaining == 0 ? reconnectHint : "Allow file access to copy the remaining \(remaining.formatted())"
        } else {
            reconnectHint = "Reconnect to copy the remaining files"
            accessHint = "Allow file access to copy the remaining files"
        }
        paneMessage = "\(started ? "A copy stopped" : "A copy didn’t start"). \(detail). \(reconnectHint)."
    }

    static func copiedDetail(_ job: QueuedTransfer) -> String {
        let copied = job.isPromise ? 0 : job.copyFilesCopied
        if let total = job.copyFilesTotal, total > 0 {
            return "\(copied.formatted()) of \(Format.count(Int(total), "file")) copied"
        }
        return copied == 0 ? "No files copied" : "\(Format.count(Int(copied), "file")) copied"
    }
}

struct CopyRemainingButton: View {
    let app: AppModel
    let job: QueuedTransfer

    var body: some View {
        Button(InterruptedCopyStatus(job).actionTitle) { app.copyRemaining(job.id) }
            .controlSize(.small)
            .help("Copy only the files left in this transfer to the original destination.")
    }
}

/// The collapsed bar leads with transfer status and keeps the pause and expand controls close.
struct TransferBar: View {
    let app: AppModel
    let reported: Set<UUID>

    var body: some View {
        let transfers = app.transfers
        let active = transfers.activeJobs.filter { !$0.interruptedByDisconnect }
        let interrupted = transfers.interruptedCopies.filter {
            !reported.contains($0.id) || (!$0.isPromise && $0.remainingFileCount != 0)
        }
        HStack(spacing: 12) {
            // No job running while some are queued: Pause All is holding the queue (cancelling the running
            // job doesn't start the next one then). That's paused, not done.
            if let job = active.first(where: { $0.state != .queued }) ?? active.first {
                runningContent(job, transfers: transfers)
            } else if let job = interrupted.first(where: app.canCopyRemaining) ?? interrupted.first {
                interruptedContent(job, transfers: transfers)
            } else {
                doneContent(transfers)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 58)
        .background(Color.paneBar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private func runningContent(_ job: QueuedTransfer, transfers: TransferCenter) -> some View {
        let p = job.progress
        let held = job.state == .queued && transfers.allPaused
        let paused = job.isPaused || held
        let status = RunningTransferStatus(job: job, issues: transfers.issues, held: held)
        let fraction = min(0.99, job.fraction)
        ProgressRing(fraction: fraction).frame(width: 26, height: 26)
        VStack(alignment: .leading, spacing: 2) {
            Text(status.timeLeft != nil && !job.isContinuation ? "Copying…" : status.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(context(job, transfers))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
        attentionBadge(transfers)
        VStack(spacing: 5) {
            TransferBarGauge(fraction: fraction)
            HStack {
                if let detail = status.detail {
                    Text([detail, status.timeLeft].compactMap { $0 }.joined(separator: " · "))
                }
                Spacer()
                if let p, !paused, p.speedBytesPerSec > 0 {
                    Text(Format.speed(Double(p.speedBytesPerSec)))
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .frame(width: 420)
        HStack(spacing: 2) {
            Button {
                if held { transfers.resumeAll() } else if job.isPaused { transfers.resume(job.id) } else { transfers.pause(job.id) }
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill").frame(width: 22, height: 22)
            }
            .help(held ? "Resume All" : paused ? "Resume" : "Pause")
            .accessibilityLabel(held ? "Resume All" : paused ? "Resume" : "Pause")
            // A queued job that nothing holds starts by itself.
            .disabled(job.state == .queued && !held)
            expandButton()
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func interruptedContent(_ job: QueuedTransfer, transfers: TransferCenter) -> some View {
        let status = InterruptedCopyStatus(job)
        Image(systemName: "exclamationmark.circle")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(.orange)
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
            Text(status.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .help(status.title)
            Text(status.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        attentionBadge(transfers)
        VStack(spacing: 5) {
            TransferBarGauge(fraction: status.fraction, tint: .orange)
            HStack {
                if app.canCopyRemaining(job) {
                    CopyRemainingButton(app: app, job: job)
                } else {
                    let session = app.session(for: job.deviceID)
                    let hint = if session?.isReady == true, session?.storage(job.spec.storageID) == nil, job.remainingFileCount != 0 {
                        "Make the original storage available to continue"
                    } else {
                        session == nil ? status.reconnectHint : status.accessHint
                    }
                    Text(hint).lineLimit(1).help(hint)
                }
                Spacer()
                if let date = job.finishedAt { Text("Today, \(Format.time.string(from: date))") }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .frame(width: 420)
        expandButton(tab: job.isActive ? .inProgress : .done).buttonStyle(.borderless)
    }

    @ViewBuilder
    private func doneContent(_ transfers: TransferCenter) -> some View {
        let done = transfers.doneToday
        let failed = done.filter { if case .failed = $0.state { return true } else { return false } }.count
        let errors = done.reduce(0) { $0 + Int($1.copySummary?.filesFailed ?? 0) } + failed
        let bytes = done.reduce(UInt64(0)) { $0 + ($1.copySummary?.bytes ?? 0) }
        let elapsed = done.reduce(0.0) { $0 + Double($1.copySummary?.elapsedMs ?? 0) / 1_000 }
        let unfinished = done.filter { $0.hasProblems || ($0.copySummary?.filesFailed ?? 0) > 0 || $0.state == .cancelled }
        let fraction = unfinished.isEmpty && transfers.issues.isEmpty
            ? 1 : min(0.99, unfinished.first?.copiedFileFraction ?? 0)
        Image(systemName: errors == 0 ? "checkmark.circle" : "exclamationmark.circle")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(errors == 0 ? .green : .orange)
            .frame(width: 26, height: 26)
        VStack(alignment: .leading, spacing: 2) {
            Text(errors == 0 ? "All transfers complete" : "Transfers finished with problems")
                .font(.system(size: 13, weight: .semibold))
            Text("\(Format.count(done.count, "transfer")) · \(Format.bytes(bytes)) copied today")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        attentionBadge(transfers)
        VStack(spacing: 5) {
            TransferBarGauge(fraction: fraction, tint: errors == 0 ? .green : .orange)
            HStack {
                Text("Average ") + Text(elapsed > 0 ? Format.speed(Double(bytes) / elapsed) : "—").fontWeight(.semibold)
                Spacer()
                Text(errors == 0 ? "0 errors" : Format.count(errors, "error"))
                Spacer()
                Text(done.first?.finishedAt.map { "Today, \(Format.time.string(from: $0))" } ?? "")
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .frame(width: 420)
        expandButton().buttonStyle(.borderless)
    }

    @ViewBuilder
    private func attentionBadge(_ transfers: TransferCenter) -> some View {
        let count = transfers.issues.count
        if count > 0 {
            Button {
                app.showTransfers(tab: .attention)
            } label: {
                Label {
                    Text("\(count) need\(count == 1 ? "s" : "") attention")
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
            }
            .buttonStyle(.plain)
            .help("Show transfers that need attention")
        }
    }

    private func expandButton(tab: DrawerTab? = nil) -> some View {
        Button {
            app.showTransfers(tab: tab)
        } label: {
            Image(systemName: "chevron.up").frame(width: 22, height: 22)
        }
        .help("Show Transfers")
        .accessibilityLabel("Show Transfers")
    }

    private func context(_ job: QueuedTransfer, _ transfers: TransferCenter) -> String {
        let route = "\(job.title) to \(job.destinationLabel)"
        let queued = transfers.queuedCount
        return queued > 0 ? "\(route) · \(Format.count(queued, "more job")) queued" : route
    }
}
