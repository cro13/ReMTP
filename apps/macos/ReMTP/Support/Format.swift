import AppKit

enum Format {
    private static func decimals(_ digits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = digits
        f.maximumFractionDigits = digits
        return f
    }

    private static let digits = [decimals(0), decimals(1), decimals(2)]

    /// Finder-style decimal sizes, with the precision the mockups use:
    /// "3 KB", "2.8 MB", "38.5 MB", "212 MB", "1.2 GB", "182 GB", "1.21 TB".
    static func bytes(_ value: UInt64) -> String {
        if value == 0 { return "Zero bytes" }
        if value < 1_000 { return value == 1 ? "1 byte" : "\(value) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var v = Double(value) / 1_000
        var unit = 0
        while v >= 999.5, unit < units.count - 1 {
            v /= 1_000
            unit += 1
        }
        let fraction: Int
        switch units[unit] {
        case "KB": fraction = 0
        case "TB", "PB": fraction = v < 10 ? 2 : (v < 100 ? 1 : 0)
        default: fraction = v < 99.95 ? 1 : 0
        }
        return "\(digits[fraction].string(from: NSNumber(value: v)) ?? "\(v)") \(units[unit])"
    }

    static func bytes(_ value: Int64) -> String {
        bytes(UInt64(max(0, value)))
    }

    /// "2.1 of 3.2 GB": the unit is shown once when both sides share it. Nothing yet is "0 of 3.2 GB".
    static func bytesOf(_ done: UInt64, _ total: UInt64) -> String {
        let a = bytes(done), b = total == 0 ? "0 bytes" : bytes(total)
        if done == 0 { return "0 of \(b)" }
        let aParts = a.split(separator: " "), bParts = b.split(separator: " ")
        if aParts.count == 2, bParts.count == 2, aParts[1] == bParts[1] {
            return "\(aParts[0]) of \(b)"
        }
        return "\(a) of \(b)"
    }

    /// (value, unit), e.g. ("214", "MB/s").
    static func speedParts(_ bytesPerSecond: Double) -> (String, String) {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(0, bytesPerSecond)
        var unit = 0
        while value >= 1_000, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        let text = value >= 100 || unit == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return (text, units[unit])
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        let (v, u) = speedParts(bytesPerSecond)
        return "\(v) \(u)"
    }

    /// "About 6 s", "About 2 min", "About 1 h 5 min", "More than a day" (a stalled rate would otherwise
    /// promise thousands of hours).
    static func timeLeft(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 1 { return "Less than a second" }
        if seconds >= 86_400 { return "More than a day" }
        if seconds < 60 { return "About \(Int(seconds.rounded())) s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "About \(minutes) min" }
        return "About \(minutes / 60) h \(minutes % 60) min"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total >= 3_600 { return String(format: "%d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Always in ms ("38 ms", "1,250 ms"): the drawer's per-file stats sit in one column and compare by eye.
    static func milliseconds(_ ms: UInt32) -> String {
        "\(digits[0].string(from: NSNumber(value: ms)) ?? "\(ms)") ms"
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        let number = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return "\(number) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateTime.string(from: date)
    }

    /// File lists: "Today, 21:14", "10 Nov 2026, 03:59". Shorter than `date` ("10 Nov 2026 at 03:59"), so
    /// Date Modified leaves the names more room in a narrow pane.
    /// The day and the time are formatted apart: the locale's combined pattern joins them with "at".
    static func listDate(_ date: Date) -> String {
        "\(day(date)), \(time.string(from: date))"
    }

    /// "Today", "Yesterday", otherwise "10 Nov 2026".
    static func day(_ date: Date) -> String { listDay.string(from: date) }

    private static let listDay: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    /// "USB 3.2 Gen 1" → "USB 3" for compact rows.
    static func shortLink(_ link: String?) -> String? {
        guard let link else { return nil }
        if link.hasPrefix("USB 3") { return "USB 3" }
        if link.hasPrefix("USB 4") { return "USB 4" }
        return link
    }

    /// "5 Gb/s" from 5000 Mbps.
    static func linkRate(_ mbps: UInt32?) -> String? {
        guard let mbps, mbps > 0 else { return nil }
        if mbps >= 1_000 {
            let g = Double(mbps) / 1_000
            return g == g.rounded() ? "\(Int(g)) Gb/s" : String(format: "%.1f Gb/s", g)
        }
        return "\(mbps) Mb/s"
    }

    /// `text` shortened in the middle ("Astell&…SP3000") to fit `width` points in `font`, for labels that
    /// can't truncate themselves (toolbar buttons, menu items).
    static func middleTruncated(_ text: String, width: CGFloat, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        func fits(_ s: String) -> Bool { (s as NSString).size(withAttributes: attributes).width <= width }
        guard !fits(text) else { return text }
        let characters = Array(text)
        // The longest head + "…" + tail that fits (the tail gets the extra character).
        var low = 0, high = characters.count
        while low < high {
            let keep = (low + high + 1) / 2
            let head = keep / 2, tail = keep - head
            if fits(String(characters.prefix(head)) + "…" + String(characters.suffix(tail))) { low = keep } else { high = keep - 1 }
        }
        let head = low / 2, tail = low - head
        return String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
    }
}
