import SwiftUI

/// Devices (with storages, free space and eject), Mac locations, and sync pairs.
struct SidebarView: View {
    @Bindable var app: AppModel
    /// The device row whose area a pinnable folder is being dragged over.
    @State private var pinTarget: String?

    var body: some View {
        List(selection: $app.sidebarSelection) {
            Section {
                ForEach(app.devices) { session in
                    DeviceRow(session: session, app: app)
                        .tag(SidebarItem.device(session.id))
                        .modifier(PinDropArea(app: app, deviceID: session.id, target: $pinTarget, highlights: true))
                    if session.isReady {
                        ForEach(session.storages) { storage in
                            StorageRow(storage: storage)
                                .tag(SidebarItem.storage(session.id, storage.id))
                                .modifier(PinDropArea(app: app, deviceID: session.id, target: $pinTarget))
                        }
                    }
                    favoriteRows(underRow: session.id, name: session.name, available: session.isReady, droppable: true)
                }
                ForEach(app.adbOnlyDevices) { device in
                    ADBOnlyDeviceRow(name: app.displayName(forDevice: device.id) ?? device.name)
                        .tag(SidebarItem.adbOnly(device.id))
                        .contextMenu {
                            Button("Switch to File Transfer") { app.switchToFileTransfer(device) }
                                .disabled(app.switchingUSBMode)
                        }
                    favoriteRows(underRow: device.id, name: app.displayName(forDevice: device.id) ?? device.name, available: false)
                }
                ForEach(app.disconnectedDevices) { device in
                    KnownDeviceRow(name: app.displayName(forDevice: device.id) ?? device.name)
                        .tag(SidebarItem.known(device.id))
                        .selectionDisabled()
                        .contextMenu {
                            Button("Rename…") { app.promptRenameDevice(device.id) }
                            Divider()
                            Button("Forget This Device") { app.forget(device.id) }
                        }
                    favoriteRows(underRow: device.id, name: app.displayName(forDevice: device.id) ?? device.name, available: false)
                }
                if app.devices.isEmpty && app.adbOnlyDevices.isEmpty && app.disconnectedDevices.isEmpty {
                    Text("No devices").foregroundStyle(.secondary).selectionDisabled()
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Devices")
                    if app.showsDemoBadge {
                        Text("DEMO")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .help("Demo backend: simulated devices and transfers. The Rust core replaces it.")
                    }
                }
            }

            Section("Mac") {
                ForEach(app.macPlaces) { place in
                    Label(place.title, systemImage: place.systemImage)
                        .tag(SidebarItem.mac(place.url))
                }
            }

            // Placeholder sync pairs (demo data, see SyncPreviewDemo). Hidden until the sync engine exists.
            if app.showsSync {
            Section("Sync Pairs") {
                ForEach(SyncPreviewDemo.pairs) { pair in
                    HStack {
                        Label(pair.title, systemImage: "arrow.triangle.2.circlepath")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let badge = pair.badge, pair.available { CountBadge(count: badge) }
                    }
                    .opacity(pair.available ? 1 : 0.5)
                    .tag(SidebarItem.syncPair(pair.id))
                    .selectionDisabled(!pair.available)
                    .help(pair.available ? "Preview this sync" : "\(pair.deviceName) isn’t connected")
                }
            }
            }
        }
        .listStyle(.sidebar)
    }

    /// The folders pinned under a device row, dimmed (like a device that isn't connected) while they can't open.
    @ViewBuilder
    private func favoriteRows(underRow id: String, name: String, available: Bool, droppable: Bool = false) -> some View {
        ForEach(app.sidebarFavorites(underRow: id)) { favorite in
            FavoriteRow(title: favorite.title, place: app.place(of: favorite, onDevice: id), deviceName: name, available: available)
                .tag(SidebarItem.favorite(id, favorite.id))
                .contextMenu {
                    Button("Remove from Sidebar") { app.removeFavorite(favorite, onDevice: id) }
                }
                .modifier(PinDropArea(app: app, deviceID: id, target: $pinTarget, enabled: droppable))
        }
    }
}

/// A pinned device folder, indented under its device like the storage rows.
private struct FavoriteRow: View {
    let title: String
    let place: String
    let deviceName: String
    let available: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(available ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 16)
                .sidebarFrame("favorite-icon:\(title)")
            Text(title).lineLimit(1).truncationMode(.middle)
                .sidebarFrame("favorite-title:\(title)")
            Spacer(minLength: 0)
        }
        .foregroundStyle(available ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.leading, 12)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(place)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), on \(deviceName)")
        .accessibilityValue(available ? "" : "Not connected")
        .accessibilityHint(place)
    }
}

/// A device's rows take folders dragged from the device pane: dropping one pins it under the device. While a
/// drag that would pin something is over any of them, the device row highlights.
private struct PinDropArea: ViewModifier {
    let app: AppModel
    let deviceID: String
    @Binding var target: String?
    var highlights = false
    var enabled = true

    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrop(of: [DeviceDragItem.contentType],
                        delegate: SidebarPinDropDelegate(app: app, deviceID: deviceID, target: $target))
                .background {
                    if highlights && target == deviceID {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.18))
                            .padding(.horizontal, -6)
                    }
                }
        } else {
            content
        }
    }
}

@MainActor
struct SidebarPinDropDelegate: DropDelegate {
    let app: AppModel
    let deviceID: String
    @Binding var target: String?

    private var pinnable: Bool { !app.foldersToPin(.current(), onDevice: deviceID).isEmpty }

    func validateDrop(info: DropInfo) -> Bool { pinnable }

    func dropEntered(info: DropInfo) {
        if pinnable { target = deviceID }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: pinnable ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) {
        if target == deviceID { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        target = nil
        defer { app.dragEnded() }
        return app.pinDropped(.current(), onDevice: deviceID)
    }
}

private struct DeviceRow: View {
    let session: DeviceSession
    let app: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "smartphone")
                .font(.system(size: 15))
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    .help(session.customName == nil ? session.name : "\(session.name) (\(session.ref.name))")
                subtitle
            }
            Spacer(minLength: 4)
            if session.isReady {
                Button {
                    app.eject(session)
                } label: {
                    Image(systemName: "eject").font(.system(size: 11, weight: .medium))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Eject \(session.name)")
                .accessibilityLabel("Eject \(session.name)")
                .disabled(app.switchingUSBMode && app.switchesToChargingOnEject(session))
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if session.isReady {
                Button("Eject") { app.eject(session) }
                    .disabled(app.switchingUSBMode && app.switchesToChargingOnEject(session))
            } else {
                Button("Reconnect") { app.reconnect(session) }
            }
            if session.adbAccess != .off {
                Divider()
                Button("Switch to Charging Only") { app.switchToChargingOnly(session) }
                    .disabled(app.switchingUSBMode || releasing)
                Toggle("Switch to Charging Only on Eject", isOn: Binding(
                    get: { app.switchesToChargingOnEject(session) },
                    set: { app.setSwitchToChargingOnEject(session, $0) }))
                    .disabled(USBDeviceIdentity.serialKey(for: session.id) == nil)
            }
            Divider()
            Button("Rename…") { app.promptRenameDevice(session.id) }
        }
    }

    private var releasing: Bool {
        if case .releasing = session.phase { return true }
        return false
    }

    @ViewBuilder
    private var subtitle: some View {
        switch session.phase {
        case .held, .releasing:
            HStack(spacing: 3) {
                Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
                Text(session.isSystemHold ? "Held by macOS" : "In use by \(session.holder?.process ?? "another app")")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        case .connecting:
            Text("Connecting…").font(.system(size: 10)).foregroundStyle(.secondary)
        case .ejected:
            Text("Ejected · safe to unplug").font(.system(size: 10)).foregroundStyle(.secondary)
        case .failed:
            Text("Couldn’t connect").font(.system(size: 10)).foregroundStyle(.secondary)
        case .ready:
            Text(session.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

private struct ADBOnlyDeviceRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "smartphone")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                Text("Charging only").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .help(name)
        .accessibilityElement(children: .combine)
    }
}

private struct StorageRow: View {
    let storage: StorageRef

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: storage.removable ? "sdcard" : "internaldrive")
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                    .sidebarFrame("storage-icon:\(storage.shortName)")
                Text(storage.shortName).lineLimit(1).layoutPriority(1)
                    .sidebarFrame("storage-title:\(storage.shortName)")
                Spacer(minLength: 4)
                Text("\(Format.bytes(storage.freeBytes)) free")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            BarGauge(fraction: storage.usedFraction, height: 4)
                .padding(.leading, 24)
        }
        .padding(.leading, 12)
        .padding(.vertical, 2)
    }
}

private struct KnownDeviceRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "smartphone").font(.system(size: 15)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Text("Not connected").font(.system(size: 10))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }
}

extension View {
    /// DEBUG self-check: records where a sidebar row's icon and title are (`SidebarFrames`). Nothing otherwise.
    @ViewBuilder
    func sidebarFrame(_ key: String) -> some View {
        #if DEBUG
        if SidebarFrames.enabled {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SidebarFrames.frames[key] = $0 }
                .onDisappear { SidebarFrames.frames.removeValue(forKey: key) }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG
@MainActor
enum SidebarFrames {
    static let enabled = ProcessInfo.processInfo.environment["REMTP_SNAPSHOT_DIR"] != nil
    static var frames: [String: CGRect] = [:]
}
#endif
