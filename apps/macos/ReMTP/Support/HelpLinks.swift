import AppKit
import Foundation

/// The Help menu's links: the README, and GitHub's issue forms prefilled by field id with facts about the
/// Mac and the shown device. Reports carry the device's maker, model and connection, never the user's name
/// for it (or the name the device reports, which owners often set to their own), file names or paths.
enum HelpLinks {
    static let repository = "https://github.com/cro13/ReMTP"
    static let readme = URL(string: "\(repository)#readme")!

    /// An issue form in `.github/ISSUE_TEMPLATE`.
    enum Report: String {
        case device = "device_report.yml"
        case bug = "bug_report.yml"
    }

    /// What a report says about a device.
    struct DeviceFacts: Equatable {
        var vendor: String
        /// The model it reports ("SM-S911B"); empty when it reports none (then the report names only the maker).
        var model: String
        /// As the sidebar shows it: "USB 3 · MTP", "Charging only", "Held by macOS".
        var connection: String

        /// "Samsung SM-S911B"
        var label: String {
            let vendor = vendor.trimmingCharacters(in: .whitespaces)
            let model = model.trimmingCharacters(in: .whitespaces)
            if vendor.isEmpty || model.localizedCaseInsensitiveContains(vendor) { return model.isEmpty ? vendor : model }
            return model.isEmpty ? vendor : "\(vendor) \(model)"
        }
    }

    /// The app and the Mac it runs on.
    struct System: Equatable {
        /// "0.1.1 (5)"
        var appVersion: String
        /// "macOS 15.6 (24G84)"
        var macOS: String
        /// "Mac14,2"; empty if unknown.
        var macModel: String

        /// "Mac14,2, macOS 15.6 (24G84)", in the forms' "Mac and macOS version" order.
        var mac: String { macModel.isEmpty ? macOS : "\(macModel), \(macOS)" }

        static var current: System {
            let info = Bundle.main.infoDictionary ?? [:]
            let short = info["CFBundleShortVersionString"] as? String ?? "?"
            let build = info["CFBundleVersion"] as? String
            let v = ProcessInfo.processInfo.operatingSystemVersion
            var os = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
            if let osBuild = sysctlString("kern.osversion") { os += " (\(osBuild))" }
            return System(appVersion: build.map { "\(short) (\($0))" } ?? short, macOS: os,
                          macModel: sysctlString("hw.model") ?? "")
        }

        private static func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
            let value = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return value.isEmpty ? nil : value
        }
    }

    /// GitHub's new-issue page for `report`, with the form's fields prefilled. Without a device, only the
    /// app and macOS versions.
    static func reportURL(_ report: Report, device: DeviceFacts?, system: System = .current) -> URL {
        var fields: [(String, String)] = [("template", report.rawValue)]
        switch report {
        case .device:
            if let device {
                fields += [("title", device.label), ("device", device.label)]
            }
            fields.append(("mac", system.mac))
            fields.append(("notes", ["ReMTP \(system.appVersion)", device.map { "Connection: \($0.connection)" }]
                .compactMap { $0 }.joined(separator: "\n")))
        case .bug:
            fields.append(("version", system.appVersion))
            fields.append(("mac", system.mac))
            if let device { fields.append(("device", "\(device.label) · \(device.connection)")) }
        }
        let query = fields.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        return URL(string: "\(repository)/issues/new?\(query)")!
    }

    /// Percent-encodes everything but RFC 3986's unreserved characters, so "&", "+", "=", "#" and spaces in a
    /// value (Astell&Kern) can't end it early. Capped so the URL stays short.
    static func encode(_ value: String) -> String {
        String(value.prefix(120)).addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    @MainActor
    static func openReport(_ report: Report, app: AppModel) {
        NSWorkspace.shared.open(reportURL(report, device: app.reportedDevice))
    }
}

extension AppModel {
    /// Facts about the device the device pane shows, for a report; nil with no device shown.
    var reportedDevice: HelpLinks.DeviceFacts? {
        guard let id = shownDeviceID else { return nil }
        if let session = session(for: id) {
            let ref = session.details?.summary ?? session.ref
            return HelpLinks.DeviceFacts(vendor: ref.manufacturer, model: ref.model,
                                         connection: Self.reportedConnection(session))
        }
        if let device = shownADBOnlyDevice {
            return HelpLinks.DeviceFacts(vendor: device.manufacturer, model: device.model,
                                         connection: "Charging only")
        }
        if let known = known.all[id] {
            let link = Format.shortLink(known.linkSpeed).map { ", last \($0) · MTP" } ?? ""
            return HelpLinks.DeviceFacts(vendor: known.manufacturer, model: known.model,
                                         connection: "Not connected\(link)")
        }
        return nil
    }

    private static func reportedConnection(_ session: DeviceSession) -> String {
        switch session.phase {
        case .ready:
            return [Format.shortLink(session.details?.linkSpeed), "MTP"].compactMap { $0 }.joined(separator: " · ")
        case .held, .releasing:
            return session.isSystemHold ? "Held by macOS" : "In use by \(session.holder?.process ?? "another app")"
        case .connecting: return "Connecting"
        case .ejected: return "Ejected"
        case .failed: return "Couldn’t connect"
        }
    }
}
