import SwiftUI

/// Recent speed on a zero-based scale, with the peak marked for reference.
struct SpeedGraph: View {
    var samples: [Double]

    var body: some View {
        let peak = samples.max() ?? 0
        let peakLabel = Format.speed(peak)
        let hasReference = peak > 0
        HStack(spacing: 6) {
            Canvas { context, size in
                let baseline = size.height - 0.5
                func y(_ value: Double) -> CGFloat {
                    baseline - CGFloat(value / max(peak, 1)) * max(0, baseline - 8)
                }
                func rule(at y: CGFloat) -> Path {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    }
                }
                context.stroke(rule(at: baseline), with: .color(.primary.opacity(0.14)), lineWidth: 1)
                if hasReference {
                    context.stroke(rule(at: y(peak)), with: .color(.primary.opacity(0.14)), lineWidth: 1)
                }
                guard samples.count > 1 else { return }
                let step = size.width / CGFloat(samples.count - 1)
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(samples[0])))
                for i in 1..<samples.count {
                    line.addLine(to: CGPoint(x: CGFloat(i) * step, y: y(samples[i])))
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: baseline))
                area.addLine(to: CGPoint(x: 0, y: baseline))
                area.closeSubpath()
                context.fill(area, with: .color(.accentColor.opacity(0.08)))
                context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            Text(peakLabel)
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .opacity(hasReference ? 1 : 0)
                .frame(width: 76, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 2)
        }
        .help(samples.isEmpty ? "No speed samples yet" : "Recent transfer speed · peak \(peakLabel)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent transfer speed")
        .accessibilityValue(samples.isEmpty ? "No speed samples yet" : "Peak \(peakLabel)")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
