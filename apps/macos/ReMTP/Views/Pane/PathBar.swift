import SwiftUI

/// Location pill + breadcrumbs. The pill names where the pane is (the Mac's volume or home folder, or the
/// device and its storage) and stands for the path's root; the crumbs are the folders below it. The
/// active pane gets an accent edge, tint and an accent-filled pill.
/// Long paths collapse their first crumbs into a "…" menu. The pill and every crumb take drops: the last
/// one into the open folder, earlier ones into that ancestor.
struct PathBar: View {
    let pane: PaneModel
    let app: AppModel
    let isActive: Bool

    var body: some View {
        HStack(spacing: 1) {
            // Long device names truncate in the pill instead of pushing the crumbs away.
            CappedWidth(max: 240) { pill }
            crumbArea
            // Same test as the filtering itself (`PaneModel.applySortAndFilter` trims): spaces filter nothing.
            if !pane.filter.trimmingCharacters(in: .whitespaces).isEmpty {
                Spacer(minLength: 4)
                filterChip
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(isActive ? Color.accentColor.opacity(0.07) : Color.paneBar)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.accentColor).frame(height: 2).opacity(isActive ? 1 : 0)
        }
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { app.activate(pane.kind, focus: true) }
    }

    private var filterChip: some View {
        let label = "Filtered by “\(pane.filter)”. Clear filter."
        return Button {
            pane.filter = ""
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                Text("“\(pane.filter)”").lineLimit(1).truncationMode(.middle)
                Image(systemName: "xmark")
            }
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 148)
        .layoutPriority(1)
        .help(label)
        .accessibilityLabel(label)
    }

    /// The crumbs the pill stands for: the Mac's first crumb, the device and storage crumbs.
    private var rootCrumbs: Int { pane.kind == .device ? 2 : 1 }
    private var pillStyle: LocationPill.Style { isActive ? .active : .inactive }

    // MARK: Pill

    @ViewBuilder
    private var pill: some View {
        let crumbs = pane.crumbs
        switch pane.kind {
        case .mac:
            if let root = crumbs.first {
                rootButton(root) {
                    LocationPill(text: root.title, systemImage: root.systemImage ?? "internaldrive", style: pillStyle,
                                 dropTargeted: pane.dropHighlight == .crumb(root.id))
                }
            }
        case .device:
            if let name = app.shownChargingSwitchName {
                LocationPill(text: name, detail: "switching USB mode", systemImage: "smartphone", style: pillStyle)
            } else if let device = app.shownADBOnlyDevice {
                LocationPill(text: app.displayName(forDevice: device.id) ?? device.name,
                             detail: app.switchingToFileTransfer(device.id) ? "switching USB mode" : "charging only",
                             systemImage: "smartphone", style: pillStyle)
            } else if let session = app.shownSession {
                if app.devicePaneBrowsable, let loc = pane.location?.device, crumbs.count >= 2 {
                    let root = crumbs[1]
                    let label = LocationPill(text: session.name, detail: session.storage(loc.storageID)?.shortName,
                                             systemImage: "smartphone", showsMenu: session.storages.count > 1, style: pillStyle,
                                             dropTargeted: pane.dropHighlight == .crumb(root.id))
                    if session.storages.count > 1 {
                        // The pill switches between storages (Internal / microSD).
                        Menu {
                            ForEach(session.storages) { storage in
                                Button(storage.description) { app.showStorage(deviceID: loc.deviceID, storageID: storage.id) }
                            }
                        } label: {
                            label
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .help("Switch storage")
                        .onDrop(of: DragPayload.contentTypes,
                                delegate: PaneDropDelegate(app: app, pane: pane, spot: .crumb(root.location), zone: .crumb(root.id)))
                    } else {
                        rootButton(root) { label }
                    }
                } else {
                    // Nothing to browse: name the device and say why.
                    let (state, held): (String?, Bool) = switch session.phase {
                    case .ready: (nil, false)
                    case .connecting, .releasing: ("connecting", false)
                    case .held: ("held by macOS", true)
                    case .ejected: ("ejected", false)
                    case .failed: ("error", false)
                    }
                    LocationPill(text: session.name, detail: state, systemImage: held ? "lock.fill" : "smartphone",
                                 style: held ? .attention : pillStyle)
                }
            } else {
                LocationPill(text: app.shownDeviceID.flatMap(app.displayName(forDevice:)) ?? "No device", systemImage: "smartphone",
                             style: .inactive)
            }
        }
    }

    /// The pill as a button to the root folder, which also takes drops.
    private func rootButton(_ root: Crumb, @ViewBuilder label: () -> LocationPill) -> some View {
        Button { go(root) } label: { label() }
            .buttonStyle(.plain)
            .onDrop(of: DragPayload.contentTypes,
                    delegate: PaneDropDelegate(app: app, pane: pane, spot: .crumb(root.location), zone: .crumb(root.id)))
    }

    // MARK: Crumbs

    @ViewBuilder
    private var crumbArea: some View {
        let crumbs = Array(pane.crumbs.dropFirst(rootCrumbs))
        if !crumbs.isEmpty, pane.kind == .mac || app.devicePaneBrowsable {
            ViewThatFits(in: .horizontal) {
                row(crumbs, hidden: [])
                if crumbs.count > 2 {
                    row(Array(crumbs.suffix(2)), hidden: Array(crumbs.dropLast(2)))
                }
                row(Array(crumbs.suffix(1)), hidden: Array(crumbs.dropLast()), compressible: true)
            }
        }
    }

    /// `hidden` crumbs go into a "…" menu right after the pill.
    /// `compressible`: the last resort, whose crumb truncates instead of overflowing.
    @ViewBuilder
    private func row(_ shown: [Crumb], hidden: [Crumb], compressible: Bool = false) -> some View {
        let row = HStack(spacing: 1) {
            if !hidden.isEmpty {
                separator
                overflowMenu(hidden)
            }
            ForEach(shown) { crumb in
                separator
                crumbView(crumb, isLast: crumb.id == shown.last?.id)
                    .onDrop(of: DragPayload.contentTypes,
                            delegate: PaneDropDelegate(app: app, pane: pane, spot: .crumb(crumb.location), zone: .crumb(crumb.id)))
            }
        }
        if compressible { row } else { row.fixedSize() }
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 1)
    }

    private func overflowMenu(_ hidden: [Crumb]) -> some View {
        Menu {
            ForEach(hidden) { crumb in
                Button(crumb.title) { go(crumb) }
            }
        } label: {
            Text("…").font(.system(size: 12)).foregroundStyle(.primary).padding(.horizontal, 4)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func go(_ crumb: Crumb) {
        pane.navigate(to: crumb.location)
        app.activate(pane.kind, focus: true)
    }

    private func crumbView(_ crumb: Crumb, isLast: Bool) -> some View {
        let dropTargeted = pane.dropHighlight == .crumb(crumb.id)
        return Button { go(crumb) } label: {
            CappedWidth(max: 200) { Text(crumb.title).lineLimit(1).truncationMode(.middle) }
                .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(dropTargeted ? 0.2 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(dropTargeted ? 0.6 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The path bar's location pill: symbol, name, "· detail" (storage or state) and a menu chevron. A long
/// `text` truncates in the middle; the detail always shows in full.
struct LocationPill: View {
    enum Style {
        /// The active pane's: filled with the accent colour.
        case active
        case inactive
        /// The device can't be browsed until the user does something (held by macOS).
        case attention
    }

    var text: String
    var detail: String?
    var systemImage: String
    var showsMenu = false
    var style: Style
    var dropTargeted = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)).foregroundStyle(symbolColor)
            Text(text).lineLimit(1).truncationMode(.middle)
            if let detail { Text("· \(detail)").font(.system(size: 11, weight: .medium)).lineLimit(1).fixedSize() }
            if showsMenu { Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.8) }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(background))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(dropTargeted && style != .active ? 0.7 : 0), lineWidth: 1.5))
        .overlay(Capsule().strokeBorder(Color.white.opacity(dropTargeted && style == .active ? 0.8 : 0), lineWidth: 1.5))
        .contentShape(Capsule())
        .help(detail.map { "\(text) · \($0)" } ?? text)
    }

    private var foreground: Color {
        switch style {
        case .active: .white
        case .inactive: .primary
        case .attention: .primary
        }
    }

    private var symbolColor: Color { style == .attention ? .attentionText : foreground }

    private var background: Color {
        switch style {
        case .active: .accentColor
        case .inactive: .primary.opacity(0.07)
        case .attention: .orange.opacity(0.16)
        }
    }
}
