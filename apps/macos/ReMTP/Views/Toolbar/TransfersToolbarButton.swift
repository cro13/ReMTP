import SwiftUI

/// Shows or hides the Transfers drawer (⌥⌘T). While anything is copying, the icon's circle is a progress
/// ring for the running jobs' bytes; an orange dot means Needs Attention has something (an issue or a
/// stopped copy).
struct TransfersToolbarButton: View {
    let app: AppModel

    var body: some View {
        let transfers = app.transfers
        let active = transfers.activeJobs.filter { !$0.interruptedByDisconnect }
        let started = active.filter { $0.state != .queued }
        let running = started.filter { !$0.isPaused }
        let paused = started.count - running.count + (transfers.allPaused ? active.count - started.count : 0)
        let queued = active.count - running.count - paused
        let fraction = Self.fraction(started)
        let attention = transfers.issues.count
        let stopped = transfers.stoppedCopies.count
        let value = Self.status(running: running.count, fraction: fraction, paused: paused, queued: queued,
                                attention: attention, stopped: stopped)
        Toggle(isOn: Binding(get: { transfers.drawerExpanded }, set: { app.showTransfers($0) })) {
            Label {
                Text("Transfers")
            } icon: {
                TransfersIcon(fraction: started.isEmpty ? nil : (fraction ?? 0), paused: running.isEmpty,
                              attention: transfers.attentionCount > 0)
            }
        }
        .accessibilityLabel("Transfers")
        .accessibilityValue(value)
        .help("\(value). Show or hide Transfers (Option-Command-T).")
    }

    private static func status(running: Int, fraction: Double?, paused: Int, queued: Int,
                               attention: Int, stopped: Int) -> String {
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if paused > 0 { parts.append("\(paused) paused") }
        if let fraction { parts.append("\(Int(fraction * 100)) percent") }
        if queued > 0 { parts.append("\(queued) queued") }
        if attention > 0 { parts.append("\(attention) need\(attention == 1 ? "s" : "") attention") }
        if stopped > 0 { parts.append("\(Format.count(stopped, "copy", "copies")) stopped") }
        return parts.isEmpty ? "No active transfers" : parts.joined(separator: ", ")
    }

    private static func fraction(_ jobs: [QueuedTransfer]) -> Double? {
        // Whole-copy bytes, so the ring doesn't drop back when "Copy the Remaining" starts a new run.
        let total = jobs.reduce(0.0) { $0 + Double($1.copyBytesTotal ?? 0) }
        let done = jobs.reduce(0.0) { $0 + Double($1.copyBytesDone) }
        return total > 0 ? min(0.99, done / total) : nil
    }
}

/// Up and down arrows in a circle that fills like a progress ring while copying, with an orange dot cut
/// into it when something needs attention.
private struct TransfersIcon: View {
    let fraction: Double?
    let paused: Bool
    let attention: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let fraction {
                Circle().stroke(.tertiary, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 0.15), value: fraction)
            } else {
                Circle().stroke(lineWidth: 1.4)
            }
            Image(systemName: "arrow.up.arrow.down").resizable().scaledToFit().fontWeight(.bold).frame(width: 9.5, height: 10.5)
        }
        .padding(0.5)
        .frame(width: 17, height: 17)
        .mask {
            Rectangle()
                .overlay(alignment: .topTrailing) {
                    if attention { Circle().frame(width: 9, height: 9).offset(x: 3, y: -3).blendMode(.destinationOut) }
                }
                .compositingGroup()
        }
        .overlay(alignment: .topTrailing) {
            if attention { Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 1.5, y: -1.5) }
        }
    }
}
