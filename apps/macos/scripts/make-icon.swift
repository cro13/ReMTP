// Renders the placeholder app icon into ReMTP/Resources/Assets.xcassets/AppIcon.appiconset.
// Usage (from apps/macos): swift scripts/make-icon.swift
import AppKit

let out = URL(fileURLWithPath: "ReMTP/Resources/Assets.xcassets/AppIcon.appiconset")

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // Body: macOS icon grid (824 pt squircle-ish rounded rect on a 1024 canvas) with a soft shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    NSColor.white.setFill()
    path.fill()
    ctx.restoreGState()
    NSGradient(colors: [NSColor(srgbRed: 0.24, green: 0.56, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 0.53, green: 0.36, blue: 0.94, alpha: 1)])!.draw(in: path, angle: -50)

    // Two panes with list rows.
    for (i, x) in [178.0, 528.0].enumerated() {
        let pane = NSRect(x: x, y: 250, width: 318, height: 470)
        NSColor.white.withAlphaComponent(i == 0 ? 0.95 : 0.88).setFill()
        NSBezierPath(roundedRect: pane, xRadius: 44, yRadius: 44).fill()
        for row in 0..<5 {
            let y = 620 - CGFloat(row) * 78
            NSColor(srgbRed: 0.35, green: 0.42, blue: 0.62, alpha: row == 1 ? 0.55 : 0.22).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 40, y: y, width: row == 1 ? 238 : 200 - CGFloat(row % 2) * 40, height: 30),
                         xRadius: 15, yRadius: 15).fill()
        }
    }

    // Transfer badge: a circle with two arrows.
    let badge = NSRect(x: 382, y: 150, width: 260, height: 260)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: badge).fill()
    ctx.restoreGState()
    let arrow = NSColor(srgbRed: 0.30, green: 0.45, blue: 0.98, alpha: 1)
    arrow.setStroke()
    func line(_ points: [NSPoint]) {
        let p = NSBezierPath()
        p.lineWidth = 26
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.move(to: points[0])
        points.dropFirst().forEach { p.line(to: $0) }
        p.stroke()
    }
    line([NSPoint(x: 444, y: 312), NSPoint(x: 580, y: 312)])
    line([NSPoint(x: 540, y: 352), NSPoint(x: 580, y: 312), NSPoint(x: 540, y: 272)])
    NSColor(srgbRed: 0.53, green: 0.36, blue: 0.94, alpha: 1).setStroke()
    line([NSPoint(x: 580, y: 236), NSPoint(x: 444, y: 236)])
    line([NSPoint(x: 484, y: 276), NSPoint(x: 444, y: 236), NSPoint(x: 484, y: 196)])

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let px = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: out.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(out.path)")
