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

        let info = Bundle.main.infoDictionary ?? [:]
        let version = "Version \(info["CFBundleShortVersionString"] as? String ?? "-") (\(info["CFBundleVersion"] as? String ?? "-"))"
        let texts = staticTexts(in: window)
        check("About window shows \(version)", texts.contains(version))
        check("About window shows the core version (\(app.service.version))", texts.contains("Core \(app.service.version)"))
        if let copyright = info["NSHumanReadableCopyright"] as? String {
            check("About window shows the copyright line", texts.contains(copyright))
        }
        let screen = window.screen?.visibleFrame ?? .zero
        _ = await until(1) { abs(window.frame.midX - screen.midX) < 2 }
        check("About window is centred, fixed size and only closes (\(window.frame))",
              abs(window.frame.midX - screen.midX) < 2 && !window.styleMask.contains(.resizable)
                && !window.styleMask.contains(.miniaturizable) && window.styleMask.contains(.closable)
                && window.frame.width < 400)
        // The link row is built from `AboutInfo.links` (SwiftUI's buttons aren't in the in-process
        // accessibility tree, so the check reads the model and the screenshots show the row).
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

    /// Accessibility values of the static texts in `window`.
    private static func staticTexts(in window: NSWindow) -> [String] {
        accessibilityElements(in: window).filter { $0.accessibilityRole() == .staticText }
            .compactMap { $0.accessibilityValue() as? String ?? $0.accessibilityLabel() }
    }

    private static func accessibilityElements(in window: NSWindow) -> [any NSAccessibilityProtocol] {
        var found: [any NSAccessibilityProtocol] = []
        func visit(_ element: Any, depth: Int) {
            guard depth < 40, let element = element as? any NSAccessibilityProtocol else { return }
            found.append(element)
            for child in element.accessibilityChildren() ?? [] { visit(child, depth: depth + 1) }
        }
        if let content = window.contentView { visit(content, depth: 0) }
        return found
    }
}
#endif
