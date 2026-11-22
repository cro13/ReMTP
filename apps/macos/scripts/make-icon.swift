// Renders the app icon into ReMTP/Resources/Assets.xcassets/AppIcon.appiconset (or into the directory given as the
// first argument, for previews).
// Usage (from apps/macos): swift scripts/make-icon.swift [out-dir]
//
// The design ("Files in transit", design/icon/mono-iterations.html): a USB-C port on a black body, with three files
// moving through it toward an arrowhead. It is drawn on a 1024 design canvas (y down, as in the mockup) and fitted
// into the macOS icon grid: an 824 px body with a drop shadow on a 1024 px canvas.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "ReMTP/Resources/Assets.xcassets/AppIcon.appiconset")

func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: alpha)
}

let bodyTop = hex(0x2E2F33), bodyBottom = hex(0x08080A)
let shellTop = hex(0xECECF0), shellBottom = hex(0x8E8E93)
let cavity = hex(0x000000)
let fadeStart = hex(0x8E8E93), fadeEnd = hex(0xFFFFFF)
let fold = hex(0xFFFFFF, 0.5)

/// The icon body: a rounded square with continuous-curvature corners (the curve of Apple's icon shape, as published
/// by PaintCode), filling the 1024 design canvas. The radius is the template's 185.4 px on an 824 px body.
func iconShape() -> CGPath {
    let r: CGFloat = 185.4 * 1024 / 824, size: CGFloat = 1024
    // One corner, in units of r: (distance along the edge it starts on, distance in from that edge).
    let start = (1.52866471, 0.0)
    let segments: [(to: (Double, Double), c1: (Double, Double)?, c2: (Double, Double)?)] = [
        ((0.66993427, 0.06549600), (1.08849323, 0), (0.86840689, 0)),
        ((0.63149399, 0.07491100), nil, nil),
        ((0.07491100, 0.63149399), (0.37282392, 0.16905899), (0.16905899, 0.37282392)),
        ((0.06549600, 0.66993427), nil, nil),
        ((0, 1.52866471), (0, 0.86840689), (0, 1.08849323)),
    ]
    // Maps corner-local coordinates to the canvas for the top-right, bottom-right, bottom-left and top-left corners,
    // walking clockwise (y down).
    let corners: [(Double, Double) -> CGPoint] = [
        { a, b in CGPoint(x: size - a * r, y: b * r) },
        { a, b in CGPoint(x: size - b * r, y: size - a * r) },
        { a, b in CGPoint(x: a * r, y: size - b * r) },
        { a, b in CGPoint(x: b * r, y: a * r) },
    ]
    let path = CGMutablePath()
    path.move(to: corners[3](start.1, start.0))
    for map in corners {
        path.addLine(to: map(start.0, start.1))
        for s in segments {
            if let c1 = s.c1, let c2 = s.c2 {
                path.addCurve(to: map(s.to.0, s.to.1), control1: map(c1.0, c1.1), control2: map(c2.0, c2.1))
            } else {
                path.addLine(to: map(s.to.0, s.to.1))
            }
        }
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

extension CGContext {
    /// Fills `path` with a linear gradient between two points in design space.
    func fill(_ path: CGPath, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
        saveGState()
        addPath(path)
        clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        restoreGState()
    }

    func fill(_ path: CGPath, _ color: CGColor) {
        addPath(path)
        setFillColor(color)
        fillPath()
    }
}

/// The files and the arrowhead share one left-to-right fade, from gray to white.
let fade = (colors: [fadeStart, fadeEnd], from: CGPoint(x: 220, y: 0), to: CGPoint(x: 800, y: 0))

/// A page with its top-right corner folded over. `opacity` fades the pages behind the leading one.
func page(_ ctx: CGContext, x: CGFloat, opacity: CGFloat) {
    let y: CGFloat = 446, w: CGFloat = 104, h: CGFloat = 132, f: CGFloat = 36, e: CGFloat = 10
    ctx.saveGState()
    ctx.setAlpha(opacity)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.fill(roundedRect(x, y, w, h, 18), fade.colors, from: fade.from, to: fade.to)
    // Cut the corner along the fold's diagonal, then lay the folded flap over it.
    let cut = CGMutablePath()
    cut.addLines(between: [CGPoint(x: x + w - f - e, y: y - e), CGPoint(x: x + w + e, y: y - e), CGPoint(x: x + w + e, y: y + f + e)])
    cut.closeSubpath()
    ctx.fill(cut, cavity)
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: x + w - f, y: y))
    flap.addLine(to: CGPoint(x: x + w - f, y: y + f - 8))
    flap.addQuadCurve(to: CGPoint(x: x + w - f + 8, y: y + f), control: CGPoint(x: x + w - f, y: y + f))
    flap.addLine(to: CGPoint(x: x + w, y: y + f))
    flap.closeSubpath()
    ctx.fill(flap, fold)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// The body's background, on the 1024 design canvas (y down).
func drawBackground(_ ctx: CGContext) {
    ctx.fill(CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), transform: nil), [bodyTop, bodyBottom],
             from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 1024))
}

/// The port and its contents, on the 1024 design canvas (y down).
func drawPort(_ ctx: CGContext) {
    ctx.fill(roundedRect(122, 362, 780, 300, 150), [shellTop, shellBottom], from: CGPoint(x: 0, y: 362), to: CGPoint(x: 0, y: 662))
    ctx.fill(roundedRect(164, 404, 696, 216, 108), cavity)
    for (x, opacity) in [(222.0, 0.4), (374.0, 0.7), (526.0, 1.0)] {
        page(ctx, x: x, opacity: opacity)
    }
    let chevron = CGMutablePath()
    chevron.addLines(between: [CGPoint(x: 690, y: 452), CGPoint(x: 750, y: 512), CGPoint(x: 690, y: 572)])
    let stroke = chevron.copy(strokingWithWidth: 44, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.fill(stroke, fade.colors, from: fade.from, to: fade.to)
}

/// The port at 16 and 32 px, in pixel coordinates (y down). Scaled down from the design, the ring would be half a
/// pixel wide and the files a smudge, so each shape is placed on whole pixels instead: a 1 px ring and the files as
/// solid blocks in the design's gray steps. At 32 px each file is missing its top-right pixel (the folded corner) and
/// the arrowhead follows; at 16 px there is no room for either.
func drawHintedPort(_ ctx: CGContext, _ px: Int) {
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
        CGPath(rect: CGRect(x: x, y: y, width: w, height: h), transform: nil)
    }
    let steps = [hex(0x3D3D3F), hex(0x7F7F82), hex(0xD4D4D7)], arrow = hex(0xEFEFF1)
    if px <= 16 {
        // Two pixels taller than the design's proportions, so a dark row stays above and below the files.
        ctx.fill(roundedRect(3, 5, 10, 6, 3), [shellTop, shellBottom], from: CGPoint(x: 0, y: 5), to: CGPoint(x: 0, y: 11))
        ctx.fill(roundedRect(4, 6, 8, 4, 2), cavity)
        // No room for the arrowhead: next to the ring's end it only made the ring look thicker.
        for (x, color) in zip([6.0, 8.0, 10.0], steps) {
            ctx.fill(rect(x, 7, 1, 2), color)
        }
    } else {
        ctx.fill(roundedRect(6, 12, 20, 8, 4), [shellTop, shellBottom], from: CGPoint(x: 0, y: 12), to: CGPoint(x: 0, y: 20))
        ctx.fill(roundedRect(7, 13, 18, 6, 3), cavity)
        for (x, color) in zip([9.0, 13.0, 17.0], steps) {
            ctx.fill(rect(x, 14, 3, 4), color)
            ctx.fill(rect(x + 2, 14, 1, 1), cavity)
        }
        let chevron = CGMutablePath()
        chevron.addLines(between: [CGPoint(x: 21, y: 13.75), CGPoint(x: 23.25, y: 16), CGPoint(x: 21, y: 18.25)])
        ctx.fill(chevron.copy(strokingWithWidth: 1.6, lineCap: .round, lineJoin: .round, miterLimit: 10), arrow)
    }
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024

    // Work in pixels with y down; `design` fits the 1024 design into the 824 body of the macOS icon grid.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: 1, y: -1)
    var design = CGAffineTransform(scaleX: s, y: s).translatedBy(x: 100, y: 100).scaledBy(x: 824 / 1024, y: 824 / 1024)
    let body = iconShape().copy(using: &design)!

    // Shadow offsets and blur are in device pixels, so they scale with the output size.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: hex(0x000000, 0.3))
    ctx.fill(body, bodyBottom)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.saveGState()
    ctx.concatenate(design)
    drawBackground(ctx)
    if px > 32 { drawPort(ctx) }
    ctx.restoreGState()
    if px <= 32 { drawHintedPort(ctx, px) }
    ctx.restoreGState()

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
