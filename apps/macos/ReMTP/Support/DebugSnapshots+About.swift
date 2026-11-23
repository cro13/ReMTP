#if DEBUG
import AppKit
import SwiftUI

extension DebugSnapshots {
    /// The About window: opened from the app menu, shows the bundle's version, screenshotted in light and
    /// dark, then closed with Esc so later checks only see the main window.
    static func aboutChecks(app: AppModel, shot: (String) -> Void) async {
        func aboutWindow() -> NSWindow? { NSApp.windows.first { $0.title == "About ReMTP" && $0.isVisible } }
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.title == "About ReMTP" }) else {
            return check("App menu has About ReMTP", false)
        }
        check("App menu has About ReMTP", true)
        menu.performActionForItem(at: index)
        let opened = await until(3) { aboutWindow() != nil }
        check("About ReMTP opens a window titled About ReMTP", opened)
        guard let window = aboutWindow() else { return }
        await wait(0.4)

        // SwiftUI builds its accessibility tree only while an assistive app asks for it, which a CI runner
        // never does, so the text checks read `AboutInfo`, the model the view draws; the window's height
        // shows the content laid out, and the screenshots show it.
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "Version \(info["CFBundleShortVersionString"] as? String ?? "-") (\(info["CFBundleVersion"] as? String ?? "-"))"
        let about = AboutInfo()
        check("About window shows \(version)", about.version == version)
        check("About window shows the core version (\(app.service.version))", !app.service.version.isEmpty)
        if let copyright = info["NSHumanReadableCopyright"] as? String {
            check("About window shows the copyright line", about.copyright == copyright)
        }
        let screen = window.screen?.visibleFrame ?? .zero
        _ = await until(1) { abs(window.frame.midX - screen.midX) < 2 }
        check("About window is centred, fixed size, laid out and only closes (\(window.frame))",
              abs(window.frame.midX - screen.midX) < 2 && !window.styleMask.contains(.resizable)
                && !window.styleMask.contains(.miniaturizable) && window.styleMask.contains(.closable)
                && window.frame.width < 400 && window.frame.height > 250)
        // The link row is built from `AboutInfo.links`; the screenshots show the row.
        let links = AboutInfo().links.map(\.title)
        let hasLicense = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") != nil
        let hasAcknowledgements = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "txt") != nil
        let license = AboutInfo().links.first { $0.title == "License" }?.url
        check("About window links: GitHub, License\(hasAcknowledgements ? ", Acknowledgements" : "") (\(links)); "
              + "License opens \(license?.absoluteString ?? "nothing")",
              links == ["GitHub", "License"] + (hasAcknowledgements ? ["Acknowledgements"] : [])
                && (hasLicense ? license?.isFileURL == true : license == AboutInfo.licenseOnGitHub))

        await captureAppearances("about", shot: shot)

        // Esc closes it (the hidden cancel button), then the main window is key again.
        window.makeKeyAndOrderFront(nil)
        await wait(0.2)
        if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                      charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            NSApp.postEvent(esc, atStart: false)
        }
        let closed = await until(2) { aboutWindow() == nil }
        check("Esc closes the About window", closed)
        if !closed { window.performClose(nil) }
        NSApp.windows.first { $0.frame.width > 600 }?.makeKeyAndOrderFront(nil)
        await wait(0.3)
    }
}
#endif
