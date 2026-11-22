// Draws the Cove app icon and menu bar icon with CoreGraphics.
//   swift Design/make_icons.swift <output-dir>
// Writes icon_<px>.png (app icon sizes) and menubar_<px>.png (template, black on clear).
import AppKit
import CoreGraphics
import Foundation

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

/// A petal pointing along +y from the origin: narrow base, round shoulders, a small cleft at the tip.
func petalPath(width w: CGFloat, length l: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: .zero)
    p.addCurve(to: CGPoint(x: -w * 0.50, y: l * 0.72), control1: CGPoint(x: -w * 0.30, y: l * 0.10), control2: CGPoint(x: -w * 0.64, y: l * 0.42))
    p.addCurve(to: CGPoint(x: -w * 0.12, y: l), control1: CGPoint(x: -w * 0.40, y: l * 0.93), control2: CGPoint(x: -w * 0.26, y: l * 1.03))
    p.addQuadCurve(to: CGPoint(x: w * 0.12, y: l), control: CGPoint(x: 0, y: l * 0.89))
    p.addCurve(to: CGPoint(x: w * 0.50, y: l * 0.72), control1: CGPoint(x: w * 0.26, y: l * 1.03), control2: CGPoint(x: w * 0.40, y: l * 0.93))
    p.addCurve(to: .zero, control1: CGPoint(x: w * 0.64, y: l * 0.42), control2: CGPoint(x: w * 0.30, y: l * 0.10))
    p.closeSubpath()
    return p
}

func leafPath(width w: CGFloat, length l: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: .zero)
    p.addQuadCurve(to: CGPoint(x: 0, y: l), control: CGPoint(x: w, y: l * 0.45))
    p.addQuadCurve(to: .zero, control: CGPoint(x: -w, y: l * 0.45))
    p.closeSubpath()
    return p
}

struct Ring { let count: Int; let length: CGFloat; let width: CGFloat; let offset: CGFloat; let base: UInt32; let tip: UInt32 }

// MARK: - App icon

/// The notch as it hangs from the top edge when open: concave fillets at the top, round corners at the bottom.
func notchPath(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat, fillet: CGFloat, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: left - fillet, y: top))
    p.addQuadCurve(to: CGPoint(x: left, y: top - fillet), control: CGPoint(x: left, y: top))
    p.addLine(to: CGPoint(x: left, y: bottom + radius))
    p.addQuadCurve(to: CGPoint(x: left + radius, y: bottom), control: CGPoint(x: left, y: bottom))
    p.addLine(to: CGPoint(x: right - radius, y: bottom))
    p.addQuadCurve(to: CGPoint(x: right, y: bottom + radius), control: CGPoint(x: right, y: bottom))
    p.addLine(to: CGPoint(x: right, y: top - fillet))
    p.addQuadCurve(to: CGPoint(x: right + fillet, y: top), control: CGPoint(x: right, y: top))
    p.closeSubpath()
    return p
}

/// An open ring, its gap at the top where the notch sits. Centred on (cx, cy).
func ringPath(cx: CGFloat, cy: CGFloat, radius r: CGFloat, gap: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let top = CGFloat.pi / 2
    p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: top - gap, endAngle: top + gap, clockwise: true)
    return p
}

func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> UInt32 {
    func ch(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat((v >> s) & 0xFF) }
    func m(_ s: UInt32) -> UInt32 { UInt32(ch(a, s) + (ch(b, s) - ch(a, s)) * t) << s }
    return m(16) | m(8) | m(0)
}

/// Spectrum across the fan, left to right.
func spectrum(_ t: CGFloat) -> UInt32 {
    let stops: [UInt32] = [0xff5fa2, 0xb05cff, 0x4f7dff, 0x2fd8f0, 0x5dffc2]
    let x = min(max(t, 0), 1) * CGFloat(stops.count - 1)
    let i = min(Int(x), stops.count - 2)
    return mix(stops[i], stops[i + 1], x - CGFloat(i))
}

/// A headland on the left; `mirror` flips it about the vertical centre line so the cove stays symmetric.
func headland(_ pts: [(CGFloat, CGFloat)], mirror: Bool) -> CGPath {
    func X(_ x: CGFloat) -> CGFloat { mirror ? 1024 - x : x }
    let p = CGMutablePath()
    p.move(to: CGPoint(x: X(pts[0].0), y: pts[0].1))
    var i = 1
    while i + 2 < pts.count + 0 {
        p.addCurve(to: CGPoint(x: X(pts[i + 2].0), y: pts[i + 2].1),
                   control1: CGPoint(x: X(pts[i].0), y: pts[i].1), control2: CGPoint(x: X(pts[i + 1].0), y: pts[i + 1].1))
        i += 3
    }
    p.closeSubpath()
    return p
}

func drawAppIcon(_ ctx: CGContext, size S: CGFloat) {
    let k = S / 1024
    ctx.saveGState()
    ctx.scaleBy(x: k, y: k)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 184, cornerHeight: 184, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.45))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x0a0a28)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let horizon: CGFloat = 520

    // Night sky, warming to violet and rose at the horizon.
    ctx.drawLinearGradient(gradient([rgb(0x0d0a2e), rgb(0x24195f), rgb(0x6a3a9c), rgb(0xd77aa8)], [0, 0.45, 0.8, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: horizon), options: [])
    // Stars, kept off the centre so the moon reads alone.
    let stars: [(CGFloat, CGFloat, CGFloat)] = [(210, 800, 5), (300, 700, 4), (170, 640, 3), (380, 770, 3), (150, 740, 4),
                                                 (800, 790, 5), (720, 690, 4), (860, 650, 3), (650, 780, 3), (880, 730, 4), (250, 590, 3), (780, 600, 3)]
    for (x, y, r) in stars {
        ctx.setFillColor(rgb(0xffffff, 0.8)); ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    // Moon with a wide halo.
    let moon = CGPoint(x: 512, y: 690)
    ctx.drawRadialGradient(gradient([rgb(0xdfe6ff, 0.55), rgb(0xa99cff, 0.18), rgb(0xa99cff, 0)], [0, 0.4, 1]),
                           startCenter: moon, startRadius: 0, endCenter: moon, endRadius: 300, options: [])
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: moon.x - 82, y: moon.y - 82, width: 164, height: 164)); ctx.clip()
    ctx.drawLinearGradient(gradient([rgb(0xffffff), rgb(0xd9e0ff)]), start: CGPoint(x: moon.x, y: moon.y + 82), end: CGPoint(x: moon.x, y: moon.y - 82), options: [])
    ctx.restoreGState()

    // Sea.
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 100, y: 100, width: 824, height: horizon - 100))
    ctx.drawLinearGradient(gradient([rgb(0x3c3fa0), rgb(0x1a2275), rgb(0x080b2a)], [0, 0.4, 1]),
                           start: CGPoint(x: 512, y: horizon), end: CGPoint(x: 512, y: 100), options: [])
    // The moon's path on the water: bars that narrow and fade downwards.
    for i in 0..<12 {
        let t = CGFloat(i) / 12
        let w = 190 * (1 - t * 0.55) * (i % 2 == 0 ? 1 : 0.7)
        let y = horizon - 22 - t * 330
        ctx.setFillColor(rgb(0xdfe6ff, 0.75 * (1 - t)))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 512 - w / 2, y: y, width: w, height: 11), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)); ctx.fillPath()
    }
    ctx.restoreGState()

    // Headlands closing round the water: a far pair at the horizon, a near pair in the corners.
    let far: [(CGFloat, CGFloat)] = [(100, 430), (100, 600), (200, 585), (330, 560), (360, 520), (400, 520), (330, 470), (210, 430), (100, 430)]
    for m in [false, true] {
        ctx.addPath(headland([(100, 440), (100, 610), (210, 600), (330, 565), (390, 545), (430, 530), (440, 515), (400, 500), (380, 470), (300, 450), (200, 440), (100, 440)], mirror: m))
        ctx.setFillColor(rgb(0x1b1553)); ctx.fillPath()
    }
    _ = far
    for m in [false, true] {
        ctx.addPath(headland([(100, 100), (100, 400), (200, 390), (300, 330), (340, 260), (390, 160), (410, 130), (430, 100), (100, 100)], mirror: m))
        ctx.setFillColor(rgb(0x06051b)); ctx.fillPath()
    }

    // Glass sheen, then the notch.
    ctx.drawLinearGradient(gradient([rgb(0xffffff, 0.10), rgb(0xffffff, 0)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 700), options: [])
    let notch = notchPath(left: 392, right: 632, top: 924, bottom: 836, fillet: 0, radius: 44)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 22, color: rgb(0xb9c4ff, 0.5))
    ctx.addPath(notch); ctx.setFillColor(rgb(0x030208)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(notch); ctx.setStrokeColor(rgb(0xffffff, 0.45)); ctx.setLineWidth(3); ctx.strokePath()

    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(rgb(0xffffff, 0.2)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Menu bar template icon (monochrome; the system tints it)

func drawMenuBar(_ ctx: CGContext, size S: CGFloat) {
    // The app icon in one colour: the frame, the notch hanging from its top edge, the moon, and its path on the water.
    // The frame spans 8...92 both ways, so the glyph is centred in the square canvas.
    let k = S / 100
    ctx.scaleBy(x: k, y: k)
    let ink = CGColor(gray: 0, alpha: 1)
    ctx.setFillColor(ink); ctx.setStrokeColor(ink)
    ctx.setLineWidth(6.5)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 11, y: 11, width: 78, height: 78), cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.strokePath()
    ctx.addPath(notchPath(left: 36, right: 64, top: 89, bottom: 71, fillet: 0, radius: 9)); ctx.fillPath()
    ctx.fillEllipse(in: CGRect(x: 50 - 10.5, y: 55 - 10.5, width: 21, height: 21))
    for (y, w) in [(CGFloat(36), CGFloat(30)), (CGFloat(27), CGFloat(20)), (CGFloat(19), CGFloat(10))] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: 50 - w / 2, y: y, width: w, height: 4.5), cornerWidth: 2.25, cornerHeight: 2.25, transform: nil)); ctx.fillPath()
    }
}

// MARK: - Output

func render(_ px: Int, to path: String, _ draw: (CGContext, CGFloat) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.cgContext.setAllowsAntialiasing(true)
    ctx.cgContext.interpolationQuality = .high
    draw(ctx.cgContext, CGFloat(px))
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] { render(px, to: "\(out)/icon_\(px).png", drawAppIcon) }
for px in [18, 36, 54] { render(px, to: "\(out)/menubar_\(px).png", drawMenuBar) }
render(256, to: "\(out)/menubar_preview.png", drawMenuBar)
print("wrote icons to \(out)")
