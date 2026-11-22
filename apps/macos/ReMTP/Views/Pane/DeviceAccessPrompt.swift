import AppKit
import SwiftUI

/// Shown in the device pane when another process (usually `ptpcamerad`) holds the device.
struct DeviceAccessPrompt: View {
    let session: DeviceSession
    let app: AppModel
    @State private var detailsExpanded = false
    @State private var copied = false

    private var holder: (process: String, pid: UInt32?) { session.holder ?? ("another app", nil) }
    private var isSystemHold: Bool { session.isSystemHold }
    private var releasing: Bool { if case .releasing = session.phase { return true } else { return false } }

    /// The equivalent Terminal command, with the user's real uid.
    private var command: String {
        "launchctl disable gui/\(getuid())/com.apple.ptpcamerad; pkill ptpcamerad"
    }

    var body: some View {
        DevicePromptLayout {
            VStack(spacing: 12) {
                DevicePromptArt(icon: "lock.fill", tint: .orange)
                Text(isSystemHold ? "macOS is holding your \(session.name)" : "\(holder.process) is using your \(session.name)").promptTitle()
                if isSystemHold {
                    Text("Its photo-import service took the USB connection when you plugged in. ReMTP can pause it while the device is connected, and turns it back on when you unplug or quit.")
                        .paragraph()
                } else {
                    Text("Only one app at a time can talk to the device over MTP. Quit \(holder.process), then try again.")
                        .paragraph()
                }
                HStack(spacing: 8) {
                    if isSystemHold {
                        Button {
                            app.release(session)
                        } label: {
                            HStack(spacing: 6) {
                                if releasing { ProgressView().controlSize(.small) }
                                Text(releasing ? "Releasing…" : "Release \(session.name)")
                            }
                            .padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(releasing)
                    } else {
                        Button("Try Again") { app.reconnect(session) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    Button("Not Now") { session.promptDismissed = true }
                        .controlSize(.large)
                        .disabled(releasing)
                }
                .padding(.top, 6)
                if let error = session.releaseError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                if isSystemHold {
                    Toggle("Always do this for \(session.name)", isOn: Binding(
                        get: { _ = app.knownVersion; return app.known.autoRelease(session.id) },
                        set: { app.setAutoRelease(session, $0) }))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Label {
                        Text("Photos and Image Capture keep working afterwards.").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "checkmark.shield").foregroundStyle(.green)
                    }
                    .font(.system(size: 12))
                    .padding(.top, 6)
                }
                details
            }
        }
    }

    private var details: some View {
        DisclosureGroup(isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("Held by").foregroundStyle(.secondary)
                        Text(holder.pid.map { "\(holder.process) (pid \($0))" } ?? holder.process).monospaced()
                    }
                    if let link = app.known.all[session.id]?.linkSpeed {
                        GridRow {
                            Text("Connection").foregroundStyle(.secondary)
                            Text(Format.shortLink(link) ?? link).monospaced()
                        }
                    }
                    GridRow {
                        Text("Device mode").foregroundStyle(.secondary)
                        Text("File transfer (MTP)").monospaced()
                    }
                }
                .font(.system(size: 12))
                if isSystemHold {
                    Text("To do it yourself in Terminal:")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    HStack(spacing: 8) {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                            .help(command)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .controlSize(.small)
                    }
                    Text("Undo with: launchctl enable gui/\(getuid())/com.apple.ptpcamerad")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Details").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .padding(.top, 8)
    }
}

/// After "Not Now": a compact reminder with a way back to the prompt.
struct HeldCompactView: View {
    let session: DeviceSession
    let app: AppModel

    var body: some View {
        PaneMessage(systemImage: "lock", title: "\(session.name) is held by \(session.holder?.process ?? "another app")",
                    detail: "ReMTP can’t browse it until it’s released.") {
            Button("Show Options…") { session.promptDismissed = false }
        }
    }
}

struct USBFileTransferPrompt: View {
    let device: ADBOnlyDeviceRef
    let app: AppModel

    private var name: String { app.displayName(forDevice: device.id) ?? device.name }
    private var switching: Bool { app.switchingToFileTransfer(device.id) }
    private var canRetry: Bool { app.canRetryFileTransfer(device.id) }

    private var title: String {
        if switching { return "Switching \(name) to file transfer…" }
        return canRetry ? "\(name) is charging only" : "Check \(name)"
    }

    var body: some View {
        DevicePromptLayout {
            VStack(spacing: 12) {
                DevicePromptArt(icon: "bolt.fill", tint: .deviceTint)
                Text(title).promptTitle()
                if switching {
                    Text("If \(name) asks to allow USB debugging, tap Allow.").paragraph()
                    ProgressView().controlSize(.small).accessibilityLabel("Switching USB mode")
                        .padding(.top, 6)
                } else {
                    if canRetry {
                        Text("File transfer is off. ReMTP can turn it on over USB debugging.").paragraph()
                        Button("Switch to File Transfer") { app.switchToFileTransfer(device) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                            .disabled(app.switchingUSBMode)
                            .padding(.top, 6)
                    }
                    if let message = app.fileTransferError(device.id) {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.attentionText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // The way that always works, in plain text: only the reason above needs attention.
                    if app.fileTransferNeedsManualSteps(device.id) {
                        Text("On \(name), tap the “Charging this device via USB” notification and choose File transfer. To make it the default, go to Developer options → Default USB configuration → File transfer.")
                            .paragraph()
                            .padding(.top, 4)
                    }
                }
            }
        }
    }
}

private struct DevicePromptLayout<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: 430)
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct DevicePromptArt: View {
    let icon: String
    let tint: Color

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 92, height: 92)
                .overlay {
                    Image(systemName: "smartphone")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                }
            Circle()
                .fill(tint)
                .frame(width: 32, height: 32)
                .overlay { Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white) }
                .overlay { Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 3) }
                .offset(x: 6, y: 6)
        }
        .accessibilityHidden(true)
    }
}

private extension Text {
    func promptTitle() -> some View {
        self.font(.system(size: 18, weight: .bold))
            .multilineTextAlignment(.center)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

    func paragraph() -> some View {
        self.font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
