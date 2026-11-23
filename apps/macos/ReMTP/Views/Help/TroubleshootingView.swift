import SwiftUI

/// Help › Device Troubleshooting: one section per symptom, each with what to do. The wording follows what the
/// app itself says in the device pane, the access prompt and the Transfers drawer.
struct TroubleshootingView: View {
    let app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Device Troubleshooting")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Find what you’re seeing, then follow the steps. Most problems come down to the device’s USB mode, the cable, or another app using the device.")
                        .foregroundStyle(.secondary)
                }
                ForEach(TroubleshootingTopic.all) { topic in
                    TroubleshootingSection(topic: topic)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Still not working?")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Tell us about your device on GitHub. The report starts with its maker, model and connection and the ReMTP and macOS versions, never your files or the name you gave it.")
                        .foregroundStyle(.secondary)
                    Button("Report a Device Problem…") { HelpLinks.openReport(.device, app: app) }
                        .controlSize(.large)
                        .padding(.top, 4)
                }
            }
            .font(.system(size: 13))
            .lineSpacing(2.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 500, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, 28)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 420, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TroubleshootingSection: View {
    let topic: TroubleshootingTopic

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: topic.symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(topic.symptom)
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let intro = topic.intro {
                    Text(.init(intro)).foregroundStyle(.secondary)
                }
                if !topic.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(index + 1).")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 16, alignment: .trailing)
                                    .accessibilityHidden(true)
                                Text(.init(step))
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                if let note = topic.note {
                    Text(.init(note))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
    }
}

/// A symptom and what to do about it. Markdown in `intro`, `steps` and `note` (bold for what's on screen).
struct TroubleshootingTopic: Identifiable {
    let symbol: String
    let symptom: String
    var intro: String?
    var steps: [String] = []
    var note: String?

    var id: String { symptom }

    static let all: [TroubleshootingTopic] = [
        TroubleshootingTopic(
            symbol: "smartphone",
            symptom: "The device doesn’t appear",
            intro: "Most Android devices start in charging only each time you plug them in. Without file transfer, a Mac can’t see them.",
            steps: [
                "Connect it with a USB cable and unlock it.",
                "Tap the “Charging this device via USB” notification and choose **File transfer**.",
                "To make it the default, go to **Developer options → Default USB configuration → File transfer**.",
            ]),
        TroubleshootingTopic(
            symbol: "bolt",
            symptom: "It says “Charging only”",
            intro: "ReMTP can see the device over USB debugging, but file transfer is off. ReMTP can turn it on.",
            steps: [
                "Select the device in the sidebar and click **Switch to File Transfer**.",
                "If the device asks to allow USB debugging, tap **Allow**.",
            ],
            note: "Switch to File Transfer needs USB debugging (in Developer options). Without it, choose File transfer on the device as above."),
        TroubleshootingTopic(
            symbol: "lock",
            symptom: "macOS is holding the device",
            intro: "Its photo-import service took the USB connection when you plugged in. ReMTP can pause it while the device is connected, and turns it back on when you unplug or quit.",
            steps: [
                "Click **Release** in the device pane.",
                "To do this every time, turn on **Always do this for** the device.",
            ],
            note: "Photos and Image Capture keep working afterwards. If another app is using the device instead, quit it, then try again: only one app at a time can talk to the device over MTP."),
        TroubleshootingTopic(
            symbol: "gauge.with.dots.needle.33percent",
            symptom: "Copies are slow",
            intro: "A USB 2 link tops out around 35–42 MB/s, however fast the device is. The sidebar shows the link under the device’s name, such as “USB 3 · MTP”.",
            steps: [
                "If it says USB 2, try a USB 3 cable. Many cables that come with chargers are USB 2 only.",
                "Plug it straight into a USB 3 port on the Mac, not a hub or a keyboard.",
            ],
            note: "Many small files copy more slowly than a few large ones: each file costs the device a moment of its own."),
        TroubleshootingTopic(
            symbol: "cable.connector",
            symptom: "A copy stopped when the cable came out",
            intro: "ReMTP keeps track of which files arrived.",
            steps: [
                "Reconnect the device and unlock it.",
                "Open **Transfers › Needs Attention** and click **Copy the Remaining**.",
            ],
            note: "Only the files left in the copy go to the original destination. Transfer › Copy the Remaining (⌥⌘R) does the same."),
        TroubleshootingTopic(
            symbol: "calendar",
            symptom: "Dates look wrong on the device",
            intro: "Some devices drop file dates over MTP: a file copied to them shows when it was copied, not when it was last changed. The file itself is intact, and the original on your Mac keeps its date."),
    ]
}
