import SwiftUI

/// Expanded transfers: speed graph and facts, the queue grouped by job, issues, history. As tall as its
/// content, up to about half the window (the panes above take the rest).
struct TransferDrawer: View {
    let app: AppModel
    let jobsShowingCurrentFile: Set<UUID>
    /// The list's natural height.
    @State private var contentHeight: CGFloat = 120

    var body: some View {
        let transfers = app.transfers
        VStack(spacing: 0) {
            header(transfers)
            Divider()
            if transfers.drawerTab == .inProgress, let job = transfers.running, !job.interruptedByDisconnect {
                SpeedSection(job: job, issues: transfers.issues, samples: transfers.speedHistory[job.id] ?? [])
                Divider()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    switch transfers.drawerTab {
                    case .inProgress: inProgress(transfers)
                    case .attention: attention(transfers)
                    case .done: done(transfers)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(maxHeight: contentHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .shadow(color: .black.opacity(0.06), radius: 9, y: -4)
    }

    private func header(_ transfers: TransferCenter) -> some View {
        HStack(spacing: 12) {
            Text("Transfers").font(.system(size: 15, weight: .bold))
                .help("Transfers to the same device run one after another. The queue keeps going while you browse."
                    + (app.showsDemoBadge ? " Demo backend: copies are simulated." : ""))
            HStack(spacing: 1) {
                tab("In Progress", .inProgress, count: inProgressJobs(transfers).count, transfers)
                tab("Needs Attention", .attention, count: transfers.attentionCount,
                    tint: transfers.attentionCount == 0 ? nil : .orange, transfers)
                tab("Done Today", .done, count: transfers.doneToday.count, transfers)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Show")
            Spacer()
            if transfers.drawerTab == .done {
                Button("Clear") { transfers.clearFinished() }
                    .controlSize(.small)
                    .disabled(transfers.doneToday.isEmpty)
            } else {
                Button {
                    if transfers.allPaused { transfers.resumeAll() } else { transfers.pauseAll() }
                } label: {
                    Label(transfers.allPaused ? "Resume All" : "Pause All",
                          systemImage: transfers.allPaused ? "play.fill" : "pause.fill")
                }
                .controlSize(.small)
                .disabled(transfers.activeJobs.isEmpty)
            }
            Button {
                app.showTransfers(false)
            } label: {
                Image(systemName: "chevron.down").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Hide Transfers")
            .accessibilityLabel("Hide Transfers")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 46)
    }

    /// A segment of the tab control: title and a count badge (orange when the count needs the user).
    private func tab(_ title: String, _ tab: DrawerTab, count: Int, tint: Color? = nil, _ transfers: TransferCenter) -> some View {
        let selected = transfers.drawerTab == tab
        return Button { transfers.drawerTab = tab } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? HierarchicalShapeStyle.primary : .secondary)
                if count > 0 { CountBadge(count: count, tint: tint) }
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlColor))
                        .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Active jobs, less a stopped copy still winding down: Needs Attention lists that one.
    private func inProgressJobs(_ transfers: TransferCenter) -> [QueuedTransfer] {
        let stopped = Set(transfers.stoppedCopies.map(\.id))
        return transfers.activeJobs.filter { !stopped.contains($0.id) }
    }

    @ViewBuilder
    private func inProgress(_ transfers: TransferCenter) -> some View {
        let active = inProgressJobs(transfers)
        if active.isEmpty && transfers.issues.isEmpty {
            emptyText("Nothing is being copied. Select files and press \(app.copyShortcut), or drag them to the other pane.")
        }
        ForEach(active, id: \.copyID) { job in
            JobRow(job: job, transfers: transfers)
            if job.state == .running, !job.interruptedByDisconnect, let p = job.progress {
                CurrentFileRows(progress: p, showsCurrentFile: jobsShowingCurrentFile.contains(job.id))
            }
        }
        issueGroups(transfers)
    }

    /// Stopped copies first (the whole copy waits), then conflicts and problems with single files.
    @ViewBuilder
    private func attention(_ transfers: TransferCenter) -> some View {
        let stopped = transfers.stoppedCopies
        if transfers.issues.isEmpty && stopped.isEmpty { emptyText("No conflicts or problems.") }
        if !stopped.isEmpty {
            groupHeader("Disconnected", detail: "\(Format.count(stopped.count, "copy", "copies")) stopped") {
                EmptyView()
            }
            ForEach(stopped) { job in StoppedCopyRow(app: app, job: job) }
        }
        issueGroups(transfers)
    }

    /// Issues by what there is to do: conflicts wait for a choice, the rest are reports. Each group has
    /// one control for all of its rows.
    @ViewBuilder
    private func issueGroups(_ transfers: TransferCenter) -> some View {
        let conflicts = transfers.issues.filter(\.isConflict)
        let problems = transfers.issues.filter { !$0.isConflict }
        let waiting = conflicts.filter(\.needsDecision).count
        if !conflicts.isEmpty {
            groupHeader("Already exists", detail: waiting > 0
                ? "\(Format.count(waiting, "file")) wait\(waiting == 1 ? "s" : "") for your choice"
                : "\(Format.count(conflicts.count, "file")) · waiting for the copy to start") {
                if waiting > 1 {
                    Text(waiting < conflicts.count ? "For the rest:" : waiting == 2 ? "For both:" : "For all:")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ChoiceButtons { transfers.resolveAll($0) }
                }
            }
            ForEach(conflicts) { issue in IssueRow(issue: issue, app: app) }
        }
        if !problems.isEmpty {
            groupHeader("Couldn’t be copied", detail: Format.count(problems.count, "file")) {
                if problems.count > 1 {
                    Button("Dismiss All") { transfers.dismissProblems() }.controlSize(.small)
                }
            }
            ForEach(problems) { issue in IssueRow(issue: issue, app: app) }
        }
    }

    private func groupHeader<Actions: View>(_ title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 6) {
            (Text(title).fontWeight(.semibold) + Text(" · \(detail)"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            actions()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .frame(minHeight: 34)
    }

    @ViewBuilder
    private func done(_ transfers: TransferCenter) -> some View {
        let jobs = transfers.doneToday
        if jobs.isEmpty { emptyText("Finished transfers appear here.") }
        ForEach(jobs, id: \.copyID) { job in DoneRow(app: app, job: job) }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }
}

/// Replace / Keep Both / Skip for the whole group.
private struct ChoiceButtons: View {
    let choose: (ConflictResolution) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button("Replace") { choose(.replace) }
            Button("Keep Both") { choose(.keepBoth) }
            Button("Skip") { choose(.skip) }
        }
        .controlSize(.small)
    }
}

/// The time left and bytes copied lead. Per-file timings explain the speed.
private struct SpeedSection: View {
    let job: QueuedTransfer
    let issues: [PendingIssue]
    let samples: [Double]

    var body: some View {
        let p = job.progress
        let readAheadValue = readAhead(p)
        // Per-file timings mean something once two files have finished in this run; before that they read 0 ms
        // (or one big file's whole time), so their rows stay empty, as Read-ahead's does.
        let perFile = (p?.filesDone ?? 0) >= 2
        // A run that can't reach two files has no column for them: the graph takes the width from the start.
        let showsFacts = Self.reservesFacts(job)
        let status = RunningTransferStatus(job: job, issues: issues)
        let speed = p.flatMap { !$0.paused && $0.speedBytesPerSec > 0 ? Format.speed(Double($0.speedBytesPerSec)) : nil }
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.timeLeft ?? status.title)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(status.detail ?? " ")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(status.detail == nil)
            }
            .frame(width: 248, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(speed ?? "—")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 96, alignment: .leading)
                        .accessibilityLabel("Transfer speed")
                        .accessibilityValue(speed ?? "Unavailable")
                    Label(job.linkDescription, systemImage: "cable.connector")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                SpeedGraph(samples: samples).frame(height: 48)
            }
            .frame(maxWidth: .infinity)
            #if DEBUG
            .polishFrame("speedGraph")
            #endif
            if showsFacts {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    fact("Average per file", p.map { Format.milliseconds($0.avgMsPerFile) } ?? " ", visible: perFile)
                    fact("Device wait per file", p.map { Format.milliseconds($0.deviceWaitMsAvg) } ?? " ", visible: perFile)
                    fact("Idle between files", p.map { Format.milliseconds($0.idleMsAvg) } ?? " ", visible: perFile)
                    fact("Read-ahead", readAheadValue ?? " ", visible: readAheadValue != nil)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 250)
                #if DEBUG
                .polishFrame("speedFacts")
                #endif
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Files this run copies: the plan's count once it is scanned; before that the remaining files of a
    /// continuation, or the top-level sources when none is a folder. Nil when not known yet.
    static func runFileCount(_ job: QueuedTransfer) -> Int? {
        if let p = job.progress { return Int(p.filesTotal) }
        if let total = job.filesTotal { return Int(total) }
        if let pending = job.spec.pendingSources { return pending.count }
        return job.sources.values.contains(true) ? nil : job.sources.count
    }

    /// The per-file column stays (as a stable placeholder until it fills in) unless this run can't reach two files.
    static func reservesFacts(_ job: QueuedTransfer) -> Bool { (runFileCount(job) ?? 2) >= 2 }

    private func fact(_ label: String, _ value: String, visible: Bool = true) -> some View {
        GridRow {
            Text(label)
                .opacity(visible ? 1 : 0)
                .accessibilityHidden(!visible)
            Text(value)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .opacity(visible ? 1 : 0)
                .accessibilityHidden(!visible)
        }
    }

    private func readAhead(_ p: TransferProgressInfo?) -> String? {
        guard let p, p.readAheadFiles > 0 else { return nil }
        return "\(Format.count(Int(p.readAheadFiles), "file")) · \(Format.bytes(p.readAheadBytes))"
    }
}

/// A job in the queue: icon, title, route, progress, pause/cancel.
private struct JobRow: View {
    let job: QueuedTransfer
    let transfers: TransferCenter

    private var subtitle: String {
        // The bytes are under the bar.
        if job.interruptedByDisconnect { return "Disconnected · \(InterruptedCopyStatus.copiedDetail(job))" }
        guard job.isContinuation else { return job.route }
        let phase = if job.isPaused || (job.state == .queued && transfers.allPaused) {
            "Paused"
        } else if job.state == .queued {
            "Queued"
        } else {
            "Continuing"
        }
        return "\(phase) · \(InterruptedCopyStatus.copiedDetail(job))"
    }

    var body: some View {
        let interrupted = job.interruptedByDisconnect
        HStack(spacing: 12) {
            JobIcon(job: job, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(job.route)
            VStack(spacing: 4) {
                TransferBarGauge(fraction: interrupted ? InterruptedCopyStatus(job).fraction : job.fraction,
                                 tint: interrupted ? .orange : .accentColor)
                HStack {
                    if job.isContinuation || interrupted {
                        if let total = job.copyBytesTotal { Text(Format.bytesOf(job.copyBytesDone, total)) }
                        Spacer()
                    } else if job.state == .running, let p = job.progress {
                        Text(Format.bytesOf(p.bytesDone, p.bytesTotal))
                        Spacer()
                        Text("\(p.filesDone) of \(Format.count(Int(p.filesTotal), "file"))")
                    } else {
                        Text(job.state == .starting ? "Starting…" : "Queued")
                        Spacer()
                        if let bytes = job.bytesTotal { Text(Format.bytes(bytes)) }
                    }
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .frame(width: 260)
            HStack(spacing: 10) {
                if job.state == .queued {
                    Button { transfers.moveToFront(job.id) } label: { Image(systemName: "arrow.up.to.line") }
                        .help("Move to Front")
                        .accessibilityLabel("Move \(job.title) to Front")
                } else {
                    Button {
                        if job.isPaused { transfers.resume(job.id) } else { transfers.pause(job.id) }
                    } label: {
                        Image(systemName: job.isPaused ? "play.fill" : "pause.fill")
                    }
                    .help(job.isPaused ? "Resume" : "Pause")
                    .accessibilityLabel(job.isPaused ? "Resume \(job.title)" : "Pause \(job.title)")
                    .disabled(job.state != .running || interrupted)
                }
                Button { transfers.cancel(job.id) } label: { Image(systemName: "xmark") }
                    .help("Cancel")
                    .accessibilityLabel("Cancel \(job.title)")
            }
            .buttonStyle(.borderless)
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(job.state == .running ? Color.accentColor.opacity(0.1) : .clear))
    }
}

/// A copy a disconnect stopped, in Needs Attention: where it was going, how far it got (the same bar and
/// counts as the collapsed bar), and Copy the Remaining once the device is back. Dismissing it moves it to
/// Done Today.
private struct StoppedCopyRow: View {
    let app: AppModel
    let job: QueuedTransfer

    var body: some View {
        let status = InterruptedCopyStatus(job)
        HStack(spacing: 12) {
            JobIcon(job: job, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(job.route).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(job.route)
            VStack(alignment: .leading, spacing: 4) {
                TransferBarGauge(fraction: status.fraction, tint: .orange)
                Text(status.detail)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(status.detail)
            }
            .frame(width: 260)
            HStack(spacing: 6) {
                if app.canCopyRemaining(job) {
                    CopyRemainingButton(app: app, job: job).fixedSize()
                } else {
                    let hint = status.waitingHint(job, app: app)
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(hint)
                }
                Button { app.transfers.dismissStop(job.id) } label: {
                    Image(systemName: "xmark").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Dismiss. It stays in Done Today.")
                .accessibilityLabel("Dismiss the stopped copy of \(job.title)")
            }
            .frame(width: 240, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .padding(.vertical, 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.title). \(job.title), \(status.detail)")
    }
}

/// Under the running job: the file on the wire and the files already read ahead.
private struct CurrentFileRows: View {
    let progress: TransferProgressInfo
    let showsCurrentFile: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsCurrentFile {
                row(icon: "doc", name: progress.currentName) {
                    TransferBarGauge(fraction: progress.currentBytesTotal > 0
                        ? Double(progress.currentBytesDone) / Double(progress.currentBytesTotal) : 0)
                } trailing: {
                    Text(Format.bytesOf(progress.currentBytesDone, progress.currentBytesTotal))
                }
            }
            if progress.readAheadFiles > 0 {
                row(icon: "doc.on.doc", name: "Next \(Format.count(Int(progress.readAheadFiles), "file"))") {
                    Label {
                        Text("Read ahead · ready to send")
                    } icon: {
                        Image(systemName: "checkmark").foregroundStyle(.green)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } trailing: {
                    Text(Format.bytes(progress.readAheadBytes))
                }
            }
        }
    }

    private func row<Middle: View, Trailing: View>(icon: String, name: String, @ViewBuilder middle: () -> Middle,
                                                   @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 34, height: 1)
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18)
            Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            middle().frame(width: 260)
            trailing()
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

/// A conflict or problem. Only conflicts offer Replace / Keep Both / Skip (Skip is how one is turned down);
/// an answer given before the copy has started shows as a pop-up and can still be changed. Other problems
/// (bad name, too large, no space, failed) are reports: the core already left the file out, so they say what
/// to do and, where it can work, offer copying the file again (under its card-safe name, or once there is
/// room); they can be dismissed. Text is in the normal colours; the warning symbol carries the orange, and
/// conflicts, which only wait for a choice, get a neutral one.
private struct IssueRow: View {
    let issue: PendingIssue
    let app: AppModel
    /// Free space and name of the Mac volume a copy from the device was going to (read off the main thread).
    @State private var macVolume: (free: Int64?, name: String)?

    var body: some View {
        let transfers = app.transfers
        let job = transfers.job(issue.jobID)
        let connected = job.flatMap { app.session(for: $0.deviceID) }?.isReady == true
        let canRename = job?.isPromise == false && issue.renameSource != nil && (issue.direction == .toDevice || connected)
        let retry = issue.retry
        HStack(spacing: 10) {
            Image(systemName: issue.isConflict ? "doc.on.doc" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(issue.isConflict ? Color.secondary : .orange)
                .frame(width: 16)
            let item = FileItem(name: issue.name, isDirectory: false, size: issue.info.incomingSize,
                                modified: issue.info.incomingModified,
                                url: issue.direction == .toDevice ? (issue.renameSource ?? issue.retry?.source).map(URL.init(fileURLWithPath:)) : nil)
            FileIconView(item: item, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                title(job)
                Text(detail(job, connected: connected))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            if issue.isConflict {
                if let answer = issue.queuedAnswer {
                    Picker("Choice for \(issue.name)", selection: Binding(get: { answer }, set: { transfers.resolve(issue, $0) })) {
                        Text("Replace").tag(ConflictResolution.replace)
                        Text("Keep Both").tag(ConflictResolution.keepBoth)
                        Text("Skip").tag(ConflictResolution.skip)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("Choice for \(issue.name)")
                    .help("Used when the copy starts. You can still change it.")
                } else {
                    Menu("Choose") {
                        Button("Replace") { transfers.resolve(issue, .replace) }
                            .accessibilityLabel("Replace \(issue.name)")
                        Button("Keep Both") { transfers.resolve(issue, .keepBoth) }
                            .accessibilityLabel("Keep both copies of \(issue.name)")
                        Button("Skip") { transfers.resolve(issue, .skip) }
                            .accessibilityLabel("Skip \(issue.name)")
                    }
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel("Choose what to do with \(issue.name)")
                    .help("Choose what to do with \(issue.name)")
                }
            } else {
                HStack(spacing: 6) {
                    if let retry { retryButton(retry).disabled(!connected) }
                    if canRename && retry != nil {
                        Menu("More") {
                            renameButton(job)
                            Button("Dismiss") { transfers.dismiss(issue) }
                                .accessibilityLabel("Dismiss \(issue.name)")
                        }
                        .fixedSize()
                        .accessibilityLabel("More actions for \(issue.name)")
                        .help("More actions for \(issue.name)")
                    } else {
                        if canRename { renameButton(job) }
                        Button { transfers.dismiss(issue) } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                            .buttonStyle(.borderless)
                            .help("Dismiss \(issue.name)")
                            .accessibilityLabel("Dismiss \(issue.name)")
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .padding(.vertical, 1)
        .task(id: macFolder) {
            guard let url = macFolder.map(URL.init(fileURLWithPath:)) else { return }
            macVolume = await offMain { (LocalFileSystem.availableCapacity(url), LocalFileSystem.volumeName(url)) }
        }
    }

    /// The Mac folder a copy from the device ran out of space in.
    private var macFolder: String? {
        issue.info.kind == .noSpace && issue.direction == .fromDevice ? app.transfers.job(issue.jobID)?.spec.destination : nil
    }

    private func renameButton(_ job: QueuedTransfer?) -> some View {
        let destination = issue.direction == .toDevice ? job?.deviceName ?? "the device" : "this Mac"
        let action = "Rename \(issue.name), then copy it to \(destination)"
        return Button("Rename…") { app.renameSource(of: issue) }
            .accessibilityLabel(action)
            .help(action)
    }

    @ViewBuilder
    private func title(_ job: QueuedTransfer?) -> some View {
        let name = Text(issue.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(.primary)
        if let path = issue.destinationPath(in: job) {
            let folder = Text("in \(folderTail(path, job: job))")
                .lineLimit(1)
                .truncationMode(.head)
                .help("Destination folder: \(path)")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    name
                    folder
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 2) {
                    name
                    folder
                }
            }
        } else {
            name
        }
    }

    private func folderTail(_ path: String, job: QueuedTransfer?) -> String {
        let parts = path.split(separator: "/")
        if parts.isEmpty {
            if issue.direction == .fromDevice { return "Mac root" }
            return job.flatMap { app.session(for: $0.deviceID)?.storage($0.spec.storageID)?.shortName } ?? "storage root"
        }
        return parts.suffix(2).joined(separator: " › ")
    }

    private func connectionHint(_ job: QueuedTransfer?) -> String? {
        let device = job?.deviceName ?? "the device"
        if let retry = issue.retry { return "Connect \(device) to \(retryAction(retry))." }
        if job?.isPromise == false, issue.direction == .fromDevice, issue.renameSource != nil {
            return "Connect \(device) to rename it, then copy it to this Mac."
        }
        return nil
    }

    private func retryAction(_ retry: TransferRetryInfo) -> String {
        if let name = retry.cardSafeName { return "copy it as “\(name)”" }
        return retry.keepBoth ? "copy it under a different name" : "copy it again"
    }

    /// "Copy as “name”", "Keep Both" or "Try Again"; only while the device is connected.
    private func retryButton(_ retry: TransferRetryInfo) -> some View {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let title = retry.cardSafeName.map { "Copy as “\(Format.middleTruncated($0, width: 200, font: font))”" }
            ?? (retry.keepBoth ? "Keep Both" : "Try Again")
        let action = retryAction(retry)
        let help = action.prefix(1).uppercased() + action.dropFirst()
        return Button(title) { app.transfers.retry(issue) }
            .accessibilityLabel(retry.cardSafeName.map { "Copy \(issue.name) as \($0)" }
                ?? (retry.keepBoth ? "Keep both copies of \(issue.name)" : "Try copying \(issue.name) again"))
            .help(help)
    }

    private func fileDetails(size: UInt64?, modified: Date?) -> String? {
        let parts = [modified.map(Format.day), size.map(Format.bytes)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// A conflict says what differs ("2.9 MB on Galaxy S23 · 3.1 MB incoming"); a problem says what went
    /// wrong and, where the row has no button for it, what to do.
    private func detail(_ job: QueuedTransfer?, connected: Bool) -> String {
        let message = issue.info.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = job?.deviceName ?? "the device"
        if let name = issue.renamedName {
            let renamed = "Renamed to “\(name)”."
            return connected ? renamed : "\(renamed) Connect \(device) to copy it."
        }
        let place = issue.direction == .toDevice ? device : "this Mac"
        let size = issue.info.incomingSize.map(Format.bytes)
        let session = job.flatMap { app.session(for: $0.deviceID) }
        let storage = job.flatMap { session?.storage($0.spec.storageID) }
        let hint = connected ? "" : connectionHint(job).map { " \($0)" } ?? ""
        switch issue.info.kind {
        case .conflict:
            let existing = fileDetails(size: issue.info.existingSize, modified: issue.info.existingModified)
            let incoming = fileDetails(size: issue.info.incomingSize, modified: issue.info.incomingModified)
            if existing != nil || incoming != nil {
                let onDestination = existing.map { "\($0) on \(place)" } ?? "Already on \(place)"
                let sameSize = issue.info.existingSize != nil && issue.info.existingSize == issue.info.incomingSize
                return onDestination + (incoming.map { " · \($0) incoming" } ?? "") + (sameSize ? " (same size)" : "")
            }
            return message.isEmpty ? "A file with this name is already on \(place)." : message
        case .invalidName:
            return "This name isn’t allowed on \(place)." + hint
        case .nameTooLong:
            return "The name is too long for \(place)." + hint
        case .tooLargeForStorage:
            guard let size else { return "It’s larger than the whole storage on \(place)." + hint }
            guard let capacity = storage?.capacityBytes, capacity > 0 else {
                return "\(size) is larger than the whole storage on \(place)." + hint
            }
            return "\(size) is larger than the \(Format.bytes(capacity)) storage on \(place)." + hint
        case .noSpace:
            let free: UInt64?, volume: String
            if issue.direction == .toDevice {
                free = job?.finishedAt == nil ? nil : storage?.freeBytes
                volume = (session?.storages.count ?? 0) > 1 ? "\(device) (\(storage?.shortName ?? "storage"))" : device
            } else {
                free = macVolume?.free.map { UInt64(max(0, $0)) }
                volume = macVolume?.name ?? place
            }
            let fix = if !connected, issue.direction == .toDevice {
                "Connect \(device) and free up space, then copy it again."
            } else if !connected {
                "Free up space on \(volume) and connect \(device), then copy it again."
            } else if issue.retry == nil {
                "Free up space on \(volume), then copy it again."
            } else {
                "Free up space on \(volume)."
            }
            guard let free else {
                let reason = size.map { "Needs \($0)." } ?? "Not enough space on \(volume)."
                return "\(reason) \(fix)"
            }
            let needs = size.map { "Needs \($0) · " } ?? ""
            let fits = issue.info.incomingSize.map { free >= $0 } ?? false
            return "\(needs)\(Format.bytes(free)) free on \(volume)." + (fits ? hint : " \(fix)")
        case .failed:
            if issue.retry?.keepBoth == true { return "The destination name is taken." + hint }
            let reason = message.isEmpty ? issue.headline : "\(issue.headline) · \(message)"
            return reason + (reason.hasSuffix(".") ? "" : ".") + hint
        }
    }
}

/// A finished job in "Done Today".
private struct DoneRow: View {
    let app: AppModel
    let job: QueuedTransfer

    var body: some View {
        HStack(spacing: 12) {
            JobIcon(job: job, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(job.route).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Label {
                    Text(outcome)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                .help(outcome)
                if app.canCopyRemaining(job) { CopyRemainingButton(app: app, job: job).fixedSize() }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 340, alignment: .trailing)
            Text(job.finishedAt.map { Format.time.string(from: $0) } ?? "")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private var outcome: String {
        // Same file count as the bar and the device pane: "Disconnected · 1 of 2 files copied".
        if job.interruptedByDisconnect { return "Disconnected · \(InterruptedCopyStatus.copiedDetail(job))" }
        guard let s = job.copySummary else { return "" }
        switch job.state {
        case .cancelled: return "Cancelled after \(Format.count(Int(s.filesCopied), "file"))"
        case .failed(let message): return message
        default:
            // A row titled with the file's own name doesn't need "1 file".
            let namedFile = job.sources.count == 1 && job.firstItem?.isDirectory == false && s.filesCopied == 1
            var parts = [namedFile ? Format.bytes(s.bytes) : "\(Format.count(Int(s.filesCopied), "file")) · \(Format.bytes(s.bytes))"]
            if job.copyParts > 1 {
                parts.append(job.copyParts == 2 ? "copied in two parts" : "copied in \(job.copyParts.formatted()) parts")
            } else {
                let elapsedMs = job.summary?.elapsedMs ?? s.elapsedMs
                parts.append(elapsedMs < 500 ? "in under a second" : "in \(Format.duration(Double(elapsedMs) / 1_000))")
            }
            if s.filesSkipped > 0 { parts.append("\(s.filesSkipped) skipped") }
            if s.filesFailed > 0 { parts.append("\(s.filesFailed) failed") }
            if !s.renamed.isEmpty { parts.append("\(s.renamed.count) renamed for the card") }
            return parts.joined(separator: " · ")
        }
    }

    private var symbol: String {
        switch job.state {
        case .cancelled: return "xmark.circle"
        case .failed: return "exclamationmark.triangle"
        default: return (job.copySummary?.filesFailed ?? 0) > 0 ? "exclamationmark.circle" : "checkmark.circle"
        }
    }

    private var tint: Color {
        switch job.state {
        case .cancelled: return .secondary
        case .failed: return .orange
        default: return (job.copySummary?.filesFailed ?? 0) > 0 ? .orange : .green
        }
    }
}

/// The job's first item as a thumbnail/icon. Once a copy to the Mac has finished, the thumbnail comes from the
/// copy on the Mac: Quick Look covers more kinds than the device does (PDFs, documents), it needs no device
/// request, and it still works after the device is unplugged.
private struct JobIcon: View {
    let job: QueuedTransfer
    let size: CGFloat

    private var item: FileItem? {
        guard let item = job.firstItem else { return nil }
        guard job.state == .finished, job.spec.direction == .fromDevice, !job.isPromise, !item.isDirectory else { return item }
        let copy = URL(fileURLWithPath: job.spec.destination).appendingPathComponent(item.name)
        return FileItem(name: item.name, isDirectory: false, size: item.size, modified: item.modified, url: copy)
    }

    var body: some View {
        if let item {
            FileIconView(item: item, size: size)
        } else {
            Image(systemName: "doc.on.doc").font(.system(size: 20)).frame(width: size, height: size)
        }
    }
}
