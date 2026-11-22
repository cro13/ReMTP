import SwiftUI

/// Devices (with storages, free space and eject), Mac locations, and sync pairs.
struct SidebarView: View {
    @Bindable var app: AppModel

    var body: some View {
        List(selection: $app.sidebarSelection) {
            Section {
                ForEach(app.devices) { session in
                    DeviceRow(session: session, app: app)
                        .tag(SidebarItem.device(session.id))
                    if session.isReady {
                        ForEach(session.storages) { storage in
                            StorageRow(storage: storage)
                                .tag(SidebarItem.storage(session.id, storage.id))
                        }
                    }
                }
                ForEach(app.adbOnlyDevices) { device in
                    ADBOnlyDeviceRow(name: app.displayName(forDevice: device.id) ?? device.name)
                        .tag(SidebarItem.adbOnly(device.id))
                        .contextMenu {
                            Button("Switch to File Transfer") { app.switchToFileTransfer(device) }
                                .disabled(app.switchingUSBMode)
                        }
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
                Text(storage.shortName).lineLimit(1).layoutPriority(1)
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
