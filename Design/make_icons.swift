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

func drawAppIcon(_ ctx: CGContext, size S: CGFloat) {
    let k = S / 1024
    ctx.saveGState()
    ctx.scaleBy(x: k, y: k)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 184, cornerHeight: 184, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: rgb(0x000000, 0.4))
    ctx.addPath(shape); ctx.setFillColor(rgb(0x2a3fb8)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    // The cove: a sea-coloured gradient, light at the surface and deep below.
    ctx.drawLinearGradient(gradient([rgb(0x2fe0c0), rgb(0x2d8fe8), rgb(0x4a37d4)], [0.0, 0.45, 1.0]),
                           start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    ctx.drawRadialGradient(gradient([rgb(0xffffff, 0.35), rgb(0xffffff, 0)]),
                           startCenter: CGPoint(x: 512, y: 930), startRadius: 0, endCenter: CGPoint(x: 512, y: 930), endRadius: 560, options: [])
    // Soft ripples around the notch.
    let radii: [CGFloat] = [440, 540, 640]
    for (i, r) in radii.enumerated() {
        ctx.setStrokeColor(rgb(0xffffff, 0.10 - CGFloat(i) * 0.025)); ctx.setLineWidth(5)
        ctx.strokeEllipse(in: CGRect(x: 512 - r, y: 800 - r, width: r * 2, height: r * 2))
    }

    // The notch, opened: black, hanging from the top edge.
    let notch = notchPath(left: 232, right: 792, top: 924, bottom: 520, fillet: 70, radius: 120)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 34, color: rgb(0x050a30, 0.55))
    ctx.addPath(notch); ctx.setFillColor(rgb(0x07080d)); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(notch); ctx.setStrokeColor(rgb(0xffffff, 0.14)); ctx.setLineWidth(3); ctx.strokePath()

    // The tab bar inside it: four tabs, the third one selected.
    let tabs: [(UInt32, CGFloat)] = [(0x5ef0c8, 372), (0x6cc4ff, 462), (0xff8a6b, 562), (0xffd166, 662)]
    for (i, tab) in tabs.enumerated() {
        let c = CGPoint(x: tab.1, y: 800)
        if i == 2 {
            ctx.setFillColor(rgb(0xffffff, 0.10))
            ctx.addPath(CGPath(roundedRect: CGRect(x: c.x - 62, y: c.y - 40, width: 124, height: 80), cornerWidth: 40, cornerHeight: 40, transform: nil)); ctx.fillPath()
        }
        ctx.setFillColor(rgb(tab.0)); ctx.fillEllipse(in: CGRect(x: c.x - 26, y: c.y - 26, width: 52, height: 52))
        ctx.setFillColor(rgb(0xffffff, 0.45)); ctx.fillEllipse(in: CGRect(x: c.x - 11, y: c.y + 2, width: 18, height: 18))
    }

    // Content under the tabs: a card with a few lines, as in an open tab.
    ctx.setFillColor(rgb(0x171925))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 280, y: 585, width: 464, height: 120), cornerWidth: 32, cornerHeight: 32, transform: nil)); ctx.fillPath()
    ctx.setFillColor(rgb(0xff8a6b)); ctx.fillEllipse(in: CGRect(x: 308, y: 622, width: 46, height: 46))
    ctx.setFillColor(rgb(0xffffff, 0.85))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 376, y: 648, width: 230, height: 18), cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.fillPath()
    ctx.setFillColor(rgb(0xffffff, 0.35))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 376, y: 616, width: 160, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil)); ctx.fillPath()
    ctx.setFillColor(rgb(0x5ef0c8))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 640, y: 620, width: 76, height: 46), cornerWidth: 23, cornerHeight: 23, transform: nil)); ctx.fillPath()

    ctx.restoreGState()
    ctx.addPath(shape); ctx.setStrokeColor(rgb(0xffffff, 0.14)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Menu bar template icon (monochrome; the system tints it)

func drawMenuBar(_ ctx: CGContext, size S: CGFloat) {
    let k = S / 100
    ctx.scaleBy(x: k, y: k)
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.addPath(notchPath(left: 14, right: 86, top: 98, bottom: 22, fillet: 12, radius: 22)); ctx.fillPath()
    // Three tabs cut out of the notch, the middle one larger.
    ctx.setBlendMode(.clear)
    for (x, r) in [(CGFloat(33), CGFloat(6.5)), (CGFloat(50), CGFloat(8.5)), (CGFloat(67), CGFloat(6.5))] {
        ctx.fillEllipse(in: CGRect(x: x - r, y: 74 - r, width: r * 2, height: r * 2))
    }
    ctx.addPath(CGPath(roundedRect: CGRect(x: 28, y: 36, width: 44, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil)); ctx.fillPath()
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
