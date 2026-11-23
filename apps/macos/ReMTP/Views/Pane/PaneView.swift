import SwiftUI

/// One pane: path bar, file list (or device state), footer.
struct PaneView: View {
    let pane: PaneModel
    let app: AppModel

    var body: some View {
        let isActive = app.activeKind == pane.kind
        VStack(spacing: 0) {
            PathBar(pane: pane, app: app, isActive: isActive)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
            if pane.dropBarVisible, pane.kind == .mac || app.devicePaneBrowsable {
                DropBar(pane: pane, app: app)
            }
            PaneFooter(pane: pane, app: app)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane.kind {
        case .mac:
            listing
        case .device:
            if let device = app.shownADBOnlyDevice {
                USBFileTransferPrompt(device: device, app: app)
            } else if let name = app.shownChargingSwitchName {
                PaneMessage(systemImage: "bolt.fill", title: "Switching \(name) to charging only…",
                            detail: "If \(name) asks to allow USB debugging, tap Allow.", busy: true)
            } else if let session = app.shownSession {
                switch session.phase {
                case .ready:
                    listing
                case .connecting:
                    PaneMessage(systemImage: "smartphone", title: "Connecting to \(session.name)…", detail: nil, busy: true)
                case .held, .releasing:
                    if session.promptDismissed {
                        HeldCompactView(session: session, app: app)
                    } else {
                        DeviceAccessPrompt(session: session, app: app)
                    }
                case .ejected:
                    PaneMessage(systemImage: "eject", title: "\(session.name) is ejected",
                                detail: "It’s safe to unplug it now.") {
                        Button("Reconnect") { app.reconnect(session) }
                    }
                case .failed(let message):
                    PaneMessage(systemImage: "exclamationmark.triangle", title: "Couldn’t open \(session.name)", detail: message) {
                        Button("Try Again") { app.reconnect(session) }
                    }
                }
            } else if let id = app.shownDeviceID {
                let name = app.displayName(forDevice: id) ?? "The device"
                let interruption = app.transfers.interruptedCopies.first { $0.deviceID == id && !$0.stopDismissed }
                PaneMessage(systemImage: "cable.connector.slash", title: "\(name) isn’t connected",
                            detail: "Connect it with a USB cable, unlock it and choose “File transfer” in its USB notification.") {
                    if let interruption {
                        Text(InterruptedCopyStatus(interruption).paneMessage)
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        Button("Show Transfers") { app.showTransfers(tab: app.transfers.drawerTab(for: interruption)) }
                    }
                }
            } else {
                PaneMessage(systemImage: "cable.connector", title: "Connect an Android device",
                            detail: "Unlock it and choose “File transfer” in its USB notification.")
            }
        }
    }

    private var listing: some View {
        // The column browser shows the folders above too: an empty or loading open folder is just an
        // empty last column there.
        let columns = pane.viewMode == .columns
        return ZStack {
            PaneTableHost(pane: pane, app: app)
            if pane.isLoading && pane.items.isEmpty {
                if !columns { ProgressView().controlSize(.small) }
            } else if let error = pane.loadError, pane.items.isEmpty {
                PaneMessage(systemImage: "exclamationmark.triangle", title: "Couldn’t read this folder", detail: error) {
                    Button("Try Again") { pane.reload() }
                }
                .background(Color(nsColor: .controlBackgroundColor).opacity(columns ? 0.92 : 0))
            } else if pane.hasListing && pane.items.isEmpty && !columns {
                // Clicks and drops go through to the list underneath.
                Group {
                    if pane.filter.isEmpty {
                        PaneMessage(systemImage: "tray.and.arrow.down", title: "This folder is empty", detail: emptyHint)
                    } else {
                        PaneMessage(systemImage: "magnifyingglass", title: "No matches for “\(pane.filter)”", detail: nil)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// What can be done with an empty folder: files come in by drop or from the other pane.
    private var emptyHint: String {
        guard app.devicePaneBrowsable, app.other(pane).location != nil else { return "Drop files here." }
        let source = pane.kind == .mac ? (app.shownSession?.name ?? "the device") : "the Mac"
        return "Drop files here, or select them on \(source) and press \(app.copyShortcut(into: pane.kind)) to copy them over."
    }
}

/// The pane's list, column browser or icon grid. Isolates their observation so 10 Hz transfer updates
/// only touch the file view.
struct PaneTableHost: View {
    let pane: PaneModel
    let app: AppModel

    var body: some View {
        switch pane.viewMode {
        case .list:
            FileTable(pane: pane, app: app, listingGeneration: pane.listingGeneration, statusToken: app.statusToken(for: pane),
                      arrival: pane.currentArrivals, statusTitle: "On \(app.otherSideName(for: pane))")
        case .columns:
            FileColumns(pane: pane, app: app, location: pane.location, listingGeneration: pane.listingGeneration,
                        statusToken: app.statusToken(for: pane), showHidden: pane.showHidden)
        case .icons:
            FileIconGrid(pane: pane, app: app, listingGeneration: pane.listingGeneration, statusToken: app.statusToken(for: pane))
        }
    }
}

/// Shown while a drag the open folder accepts is over the pane: an always-there target for the open
/// folder, however full of folder rows the list is.
struct DropBar: View {
    let pane: PaneModel
    let app: AppModel

    var body: some View {
        let targeted = pane.dropHighlight == .bar
        HStack(spacing: 6) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 13, weight: .medium))
            Text("Drop here to copy into “\(pane.folderName)”")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(targeted ? Color.white : Color.accentColor)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(targeted ? 0.9 : 0.1)))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.accentColor.opacity(targeted ? 0 : 0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onDrop(of: DragPayload.contentTypes, delegate: PaneDropDelegate(app: app, pane: pane, spot: .bar, zone: .bar))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop here to copy into \(pane.folderName)")
    }
}

struct PaneFooter: View {
    static let height: CGFloat = 28

    let pane: PaneModel
    let app: AppModel

    var body: some View {
        Group {
            if let direction = app.missingStatusDirection(in: pane) {
                let groups = statusGroups
                if groups.isEmpty { plainRow(reason: nil) } else { comparedRow(groups, direction: direction) }
            } else {
                plainRow(reason: app.comparisonUnavailableReason(in: pane))
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(Color.paneBar)
        .overlay(alignment: .top) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { app.activate(pane.kind, focus: true) }
    }

    /// With a comparison its words come first, in the same phrase as everywhere else. As the pane narrows: the
    /// free space steps aside (the sidebar shows it too), then the selection's details, then the item count
    /// (the counts beside it add up to it), then the other device's name shortens to its first word. Marks and
    /// counts alone (words in the tooltip and VoiceOver) are the last resort.
    private func comparedRow(_ groups: [StatusGroup], direction: MissingStatusDirection) -> some View {
        let short = shortOtherName != nil && groups.contains { $0.status.isMissing }
        func summary(_ style: SummaryStyle) -> some View { statusSummary(groups, direction: direction, style: style) }
        return ViewThatFits(in: .horizontal) {
            row(leftText, summary(.full), free: true, tag: "full-1")
            row(leftText, summary(.full), free: false, tag: "full-2")
            row(itemCount, summary(.full), free: false, tag: "full-3")
            row(nil, summary(.full), free: false, tag: "full-4")
            if short {
                row(itemCount, summary(.short), free: false, tag: "short-1")
                row(nil, summary(.short), free: false, tag: "short-2")
            }
            row(leftText, summary(.compact), free: true, tag: "compact-1")
            row(itemCount, summary(.compact), free: true, tag: "compact-2")
            row(itemCount, summary(.compact), free: false, tag: "compact-3")
        }
    }

    private func row(_ left: String?, _ summary: some View, free: Bool, tag: String) -> some View {
        HStack(spacing: 8) {
            if let left { Text(left).fixedSize() }
            Spacer(minLength: 0)
            summary
                #if DEBUG
                .polishFrame("footer.\(pane.kind.rawValue).\(tag)")
                #endif
            if free { rightSide.fixedSize() }
        }
    }

    /// No comparison: the item count and free space come first; a note on why shortens, then steps aside.
    private func plainRow(reason: String?) -> some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                Text(leftText).fixedSize()
                Text(itemCount).fixedSize()
            }
            .layoutPriority(2)
            Spacer(minLength: 0)
            if let reason {
                ViewThatFits(in: .horizontal) {
                    Text(reason).fixedSize()
                    Text("Not compared").fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .foregroundStyle(.secondary)
                .help(reason)
                .accessibilityLabel(reason)
                .layoutPriority(1)
            }
            rightSide.fixedSize().layoutPriority(3)
        }
    }

    /// The other side's name cut to its first word ("Galaxy" for Galaxy S23), for the narrow Mac footer;
    /// nil when that wouldn't be any shorter.
    private var shortOtherName: String? {
        let name = app.otherSideName(for: pane)
        guard let first = name.split(separator: " ").first.map(String.init), first.count < name.count else { return nil }
        return first
    }

    private struct StatusGroup: Identifiable {
        let status: ItemStatus
        let label: String
        let selectionPhrase: String
        var items: [FileItem] = []
        var id: Int { status.rank }
    }

    /// Full wording, then a shortened device name, then just the marks and counts.
    private enum SummaryStyle { case full, short, compact }

    private var statusGroups: [StatusGroup] {
        let otherName = app.otherSideName(for: pane)
        let destination = app.otherFolderText(for: pane)
        let options = [
            StatusGroup(status: .same, label: "same", selectionPhrase: "the same \(destination)"),
            StatusGroup(status: .differs, label: "different", selectionPhrase: "different \(destination)"),
            StatusGroup(status: .folderOnBoth, label: "on both sides", selectionPhrase: "also \(destination)"),
            StatusGroup(status: pane.kind == .mac ? .notOnDevice : .notOnMac,
                        label: "not on \(otherName)", selectionPhrase: "not \(destination)"),
            StatusGroup(status: .queued, label: "queued", selectionPhrase: "queued for copying"),
            StatusGroup(status: .copyingFolder, label: "copying", selectionPhrase: "being copied"),
        ]
        let names = pane.comparisonGroups
        return options.compactMap { option in
            guard let items = names[option.id] else { return nil }
            var group = option
            group.items = items
            return group
        }
    }

    private func statusSummary(_ groups: [StatusGroup], direction: MissingStatusDirection, style: SummaryStyle) -> some View {
        let compact = style == .compact
        return HStack(spacing: compact ? 7 : 9) {
            ForEach(groups) { group in
                if let look = group.status.visibleLook(missingDirection: direction) {
                    let count = group.items.count
                    let noun = group.items.allSatisfy(\.isBrowsable) ? "folder"
                        : group.items.contains(where: \.isBrowsable) ? "item" : "file"
                    let description = "Select the \(Format.count(count, noun)) \(group.selectionPhrase)"
                    Button {
                        app.activate(pane.kind, focus: true)
                        pane.selectAndReveal(Set(group.items.map(\.name)), scrollTo: group.items.first?.name)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: look.mark)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(nsColor: look.color))
                                .accessibilityHidden(true)
                            if compact {
                                Text("\(count)")
                            } else if style == .short, group.status.isMissing, let name = shortOtherName {
                                Text("\(count) not on \(name)")
                            } else {
                                Text("\(count) \(group.label)")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(description)
                    .accessibilityLabel(description)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        #if DEBUG
        .snapshotFrame(style == .full ? .wordFooter(pane.kind) : nil)
        #endif
    }

    private var itemCount: String {
        guard pane.location != nil, pane.kind == .mac || app.devicePaneBrowsable else { return "" }
        return Format.count(pane.items.count, "item")
    }

    private var leftText: String {
        var text = itemCount
        guard !text.isEmpty else { return text }
        let selected = pane.selectedItems
        if !selected.isEmpty {
            text += ", \(selected.count) selected"
            let bytes = selected.reduce(UInt64(0)) { $0 + ($1.size ?? 0) }
            if bytes > 0 { text += " · \(Format.bytes(bytes))" }
        } else {
            let bytes = pane.items.reduce(UInt64(0)) { $0 + ($1.size ?? 0) }
            if bytes > 0 { text += " · \(Format.bytes(bytes))" }
        }
        if let arrival = pane.currentArrivals {
            let arriving = arrival.remaining + (arrival.currentName == nil ? 0 : 1)
            if arriving > 0 { text += " · \(arriving) arriving" }
        }
        return text
    }

    @ViewBuilder
    private var rightSide: some View {
        switch pane.kind {
        case .mac:
            if let bytes = pane.availableBytes { Text("\(Format.bytes(bytes)) free") }
        case .device:
            if app.devicePaneBrowsable, let loc = pane.location?.device, let storage = app.shownSession?.storage(loc.storageID) {
                let free = "\(Format.bytes(storage.freeBytes)) free"
                let capacity = "\(free) of \(Format.bytes(storage.capacityBytes))"
                Text(free).help(capacity).accessibilityLabel(capacity)
            }
        }
    }
}

/// Centered icon + title + detail, used for device states and errors.
struct PaneMessage<Actions: View>: View {
    var systemImage: String
    var title: String
    var detail: String?
    var busy = false
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.regular).padding(.bottom, 4)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
            Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            actions().padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PaneMessage where Actions == EmptyView {
    init(systemImage: String, title: String, detail: String?, busy: Bool = false) {
        self.init(systemImage: systemImage, title: title, detail: detail, busy: busy, actions: { EmptyView() })
    }
}
