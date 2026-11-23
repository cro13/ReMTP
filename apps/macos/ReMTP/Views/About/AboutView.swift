import AppKit
import SwiftUI

/// App menu › About ReMTP.
struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About ReMTP") { openWindow(id: "about") }
    }
}

/// What the About window shows, read from the bundle so it never drifts from the build.
struct AboutInfo {
    static let repository = URL(string: "https://github.com/cro13/ReMTP")!
    /// License page on GitHub, for builds without a bundled LICENSE.txt (Debug).
    static let licenseOnGitHub = URL(string: "https://github.com/cro13/ReMTP/blob/main/LICENSE")!
    /// README.md's tagline.
    static let tagline = "A fast, native file manager for Android devices over USB."

    struct Link: Identifiable {
        var title: String
        /// VoiceOver hint and tooltip.
        var hint: String
        var url: URL
        var id: String { title }
    }

    var version: String
    var copyright: String?
    /// GitHub and License always; Acknowledgements only when the bundle has THIRD_PARTY_LICENSES.txt.
    /// Release builds bundle LICENSE.txt and THIRD_PARTY_LICENSES.txt in Contents/Resources
    /// (scripts/ci/build-macos.sh); Debug builds don't, so License falls back to GitHub there.
    var links: [Link]

    init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String
        version = build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
        copyright = info["NSHumanReadableCopyright"] as? String
        links = [Link(title: "GitHub", hint: "Opens the ReMTP repository on GitHub", url: Self.repository)]
        if let license = bundle.url(forResource: "LICENSE", withExtension: "txt") {
            links.append(Link(title: "License", hint: "Opens the MIT License", url: license))
        } else {
            links.append(Link(title: "License", hint: "Opens the MIT License on GitHub", url: Self.licenseOnGitHub))
        }
        if let notices = bundle.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "txt") {
            links.append(Link(title: "Acknowledgements",
                              hint: "Opens the licenses of the open-source components ReMTP uses", url: notices))
        }
    }
}

/// The About window: icon, name, version, the README's tagline, links and the copyright line, centred
/// like Apple's own About panels.
struct AboutView: View {
    /// The Rust core's version, shown below the app's own.
    var coreVersion: String?

    @Environment(\.dismiss) private var dismiss
    private let info = AboutInfo()

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
                .padding(.bottom, 10)

            Text("ReMTP")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 4)

            // Selectable, so the version can be pasted into a bug report.
            VStack(spacing: 2) {
                Text(info.version)
                    .font(.callout)
                if let coreVersion {
                    Text("Core \(coreVersion)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.bottom, 12)

            Text(AboutInfo.tagline)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 240)
                .padding(.bottom, 14)

            HStack(spacing: 16) {
                ForEach(info.links) { link in
                    // Web pages go to the browser, the bundled .txt files to the default text app.
                    Button(link.title) { NSWorkspace.shared.open(link.url) }
                        .buttonStyle(.link)
                        .accessibilityHint(link.hint)
                        .accessibilityAddTraits(.isLink)
                        .help(link.hint)
                }
            }
            .font(.callout)
            .padding(.bottom, 14)

            if let copyright = info.copyright {
                Text(copyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(width: 280)
        .padding(.horizontal, 20)
        // The hidden title bar still keeps its height above the content.
        .padding(.top, 4)
        .padding(.bottom, 20)
        .background {
            // Esc closes the window, like Apple's About panels (⌘W comes from File › Close).
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .accessibilityHidden(true)
        }
        .background(AboutWindowConfigurator())
    }
}

/// An About panel only closes: no minimise or zoom, and it isn't restored at the next launch. It stays
/// centred: SwiftUI places the window before the content sets its size, and keeps that origin when it
/// shrinks to fit.
private struct AboutWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowHook() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowHook: NSView {
        private var resizeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resizeObserver.map(NotificationCenter.default.removeObserver)
            resizeObserver = nil
            guard let window else { return }
            window.styleMask.remove(.miniaturizable)
            window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.collectionBehavior.insert(.fullScreenNone)
            window.isRestorable = false
            window.center()
            // The window can't be resized by hand, so every resize is the content fitting itself.
            resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                                    queue: .main) { note in
                MainActor.assumeIsolated { (note.object as? NSWindow)?.center() }
            }
        }

        deinit { resizeObserver.map(NotificationCenter.default.removeObserver) }
    }
}
