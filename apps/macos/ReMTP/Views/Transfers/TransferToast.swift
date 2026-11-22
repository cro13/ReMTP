import SwiftUI

/// A clean finish, for a few seconds over the bottom of the panes: what was copied where. It stays while
/// the pointer is on it; Show opens Done Today.
struct TransferToast: View {
    static let height: CGFloat = 36

    /// What a run of finished jobs copied.
    struct Summary: Identifiable {
        enum Receiver: Equatable {
            case mac, device(String)

            init(_ destination: PaneLocation) {
                switch destination {
                case .mac: self = .mac
                case .device(let location): self = .device(location.deviceID)
                }
            }
        }

        let id = UUID()
        let title: String
        let detail: String
        let destination: PaneLocation?
        let receiver: Receiver?

        /// Nil when none of `jobs` copied anything (all cancelled).
        init?(_ jobs: [QueuedTransfer]) {
            let copied = jobs.filter { $0.state == .finished }
            guard !copied.isEmpty else { return nil }
            let files = copied.reduce(0) { $0 + Int($1.summary?.filesCopied ?? 0) }
            let skipped = copied.reduce(0) { $0 + Int($1.summary?.filesSkipped ?? 0) }
            let bytes = copied.reduce(UInt64(0)) { $0 + ($1.summary?.bytes ?? 0) }
            let places = Set(copied.map { $0.spec.direction == .toDevice ? $0.deviceName : "this Mac" })
            let receiving = copied.filter { $0.filesCopied > 0 }
            if let first = receiving.first?.destinationFolder,
               receiving.allSatisfy({ first.isSameFolder(as: $0.destinationFolder) }) {
                destination = first
            } else {
                destination = nil
            }
            if let first = receiving.first.map({ Receiver($0.destinationFolder) }),
               receiving.allSatisfy({ Receiver($0.destinationFolder) == first }) {
                receiver = first
            } else {
                receiver = nil
            }
            if files == 0, skipped > 0 {
                title = "Skipped \(Format.count(skipped, "file"))"
            } else {
                title = "Copied \(Format.count(files, "file"))" + (places.count == 1 ? " to \(places.first!)" : "")
            }
            detail = [bytes > 0 ? Format.bytes(bytes) : nil, files > 0 && skipped > 0 ? "\(skipped) skipped" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        }

        var announcement: String { detail.isEmpty ? title : "\(title), \(detail)" }
    }

    let summary: Summary
    let show: () -> Void
    let dismiss: () -> Void
    @State private var hovering = false
    @FocusState private var showFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.green)
            // A long device name truncates here instead of pushing Show out of the window.
            CappedWidth(max: 360) {
                Text(summary.title).font(.system(size: 13, weight: .semibold)).monospacedDigit().truncationMode(.middle)
            }
            if !summary.detail.isEmpty {
                Text(summary.detail).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
            }
            Button("Show", action: show)
                .controlSize(.small)
                .fixedSize()
                .padding(.leading, 6)
                .help("Show in Done Today")
                .focused($showFocused)
        }
        .lineLimit(1)
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(height: Self.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.16), radius: 10, y: 3)
        .onHover { hovering = $0 }
        // It stays while the pointer is on it or Show has keyboard focus.
        .task(id: hovering || showFocused) {
            guard !hovering, !showFocused else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { dismiss() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary.announcement)
    }
}
