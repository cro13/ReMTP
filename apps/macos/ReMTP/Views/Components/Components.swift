import SwiftUI

/// Thin rounded progress bar (pane footers, transfer rows).
struct BarGauge: View {
    var fraction: Double
    var secondFraction: Double = 0
    var height: CGFloat = 5
    var tint: Color = .accentColor
    var track: Color = Color.primary.opacity(0.1)
    var fill: Color = Color.secondary.opacity(0.55)

    var body: some View {
        GeometryReader { geo in
            let widths = Self.segmentWidths(fraction, secondFraction, width: geo.size.width, minimum: height)
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                HStack(spacing: 0) {
                    Rectangle().fill(fill).frame(width: widths.first)
                    Rectangle().fill(tint).frame(width: widths.second)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: height)
        .accessibilityElement()
        // Both segments: the transfer bars draw their progress in the second one.
        .accessibilityValue("\(Int(Self.clamp(fraction + secondFraction) * 100)) percent")
    }

    /// The two segments' widths in a `width`-point track. A segment above zero is at least `minimum` wide
    /// (the bar's height, so it reads as a dot): 310 KB of 2.4 GB would otherwise draw an empty track. Zero
    /// stays empty, and the two never overflow the track (the wider one gives way).
    static func segmentWidths(_ first: Double, _ second: Double, width: CGFloat,
                              minimum: CGFloat) -> (first: CGFloat, second: CGFloat) {
        let width = max(0, width)
        func segment(_ fraction: Double) -> CGFloat {
            let f = clamp(fraction)
            return f > 0 ? max(width * f, min(minimum, width)) : 0
        }
        let a = segment(first), b = segment(second)
        let overflow = max(0, a + b - width)
        return a >= b ? (max(0, a - overflow), b) : (a, max(0, b - overflow))
    }

    private static func clamp(_ v: Double) -> Double { min(1, max(0, v.isFinite ? v : 0)) }
}

/// Accent progress bar for transfers.
struct TransferBarGauge: View {
    var fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        BarGauge(fraction: 0, secondFraction: fraction, height: height, tint: tint)
            .accessibilityLabel("Progress")
    }
}

/// Circular progress (collapsed transfer bar).
struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0.02, fraction)))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.15), value: fraction)
        }
    }
}

/// Caps a view's width without stretching it: the content is offered at most `max` points and keeps
/// its own, smaller width below that (`.frame(maxWidth:)` takes all of `max` when offered more).
struct CappedWidth: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = Swift.min(proposal.width ?? .infinity, max)
        return child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Count badge: neutral grey for plain counts (sync pairs, transfer tabs), a `tint` (orange) for counts
/// that need the user.
struct CountBadge: View {
    var count: Int
    var tint: Color?

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: tint == nil ? .semibold : .bold))
            .monospacedDigit()
            // Primary, not secondary: on a selected drawer tab secondary text drops to ~2:1 in dark mode.
            .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.black))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(Capsule().fill(tint ?? Color.primary.opacity(0.1)))
    }
}

/// An NSImage-backed file icon/thumbnail for SwiftUI.
struct FileIconView: View {
    let item: FileItem
    var size: CGFloat
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? FileIcons.icon(for: item))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: thumbnail == nil ? 0 : size * 0.12))
            .task(id: item.url) {
                thumbnail = nil
                guard Thumbnails.canThumbnail(item) else { return }
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                Thumbnails.shared.thumbnail(for: item, size: size, scale: scale) { image in thumbnail = image }
            }
    }
}

extension Color {
    static let paneBar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.135, alpha: 1) : NSColor(white: 0.98, alpha: 1)
    })

    /// Orange text that stays readable on its own tinted background (the plain system orange doesn't in
    /// light mode).
    static let attentionText = Color(nsColor: NSColor(name: "attentionText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .systemOrange : (NSColor.systemOrange.blended(withFraction: 0.35, of: .black) ?? .systemOrange)
    })

    /// Device chips and device-side statuses: the system accent (blue unless the user picked another),
    /// darkened in light mode and lightened in dark mode so text on its own tinted background stays readable.
    static let deviceTint = Color(nsColor: .deviceTint)
}

extension NSColor {
    static let deviceTint = NSColor(name: "deviceTint") { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var accent = NSColor.systemBlue
        appearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.systemBlue
        }
        return (dark ? accent.blended(withFraction: 0.25, of: .white) : accent.blended(withFraction: 0.3, of: .black)) ?? accent
    }
}
