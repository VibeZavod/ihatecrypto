// Draws ihatecrypto's app icon — the ridged orange coin rolling its eyes on a warm-white macOS squircle — into
// Sources/IhatecryptoApp/Assets.xcassets/AppIcon.appiconset at every size macOS asks for.
// Run from App/:  swift Xcode/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalog = root.appending(path: "Sources/IhatecryptoApp/Assets.xcassets")
let iconSet = catalog.appending(path: "AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let orange = rgb(0xFF7A2F), ink = rgb(0x111111), white = rgb(0xFFFFFF)

/// The macOS icon shape: a superellipse, not a rounded rectangle.
func squircle(_ r: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(x: r.midX + r.width / 2 * copysign(pow(abs(c), 2 / n), c),
                        y: r.midY + r.height / 2 * copysign(pow(abs(s), 2 / n), s))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

/// One icon on the 1024 grid (Big Sur template: an 824-point body with 100 around it for the shadow).
func draw(_ ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)
    // Top-left origin, like the brand boards; shadow offsets stay in device space, so they're scaled by hand.
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    let shape = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 22 * s, color: rgb(0x000000, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(white)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let ground = CGGradient(colorsSpace: srgb, colors: [rgb(0xFFFFFF), rgb(0xF1ECE6)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(ground, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(0x000000, 0.08))
    ctx.setLineWidth(2)
    ctx.strokePath()

    // The coin on the brand's 140-point grid, 600 across.
    let k: CGFloat = 600 / 128
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 512 + (x - 70) * k, y: 512 + (y - 70) * k) }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect {
        CGRect(x: 512 + (x - 70 - r) * k, y: 512 + (y - 70 - r) * k, width: 2 * r * k, height: 2 * r * k)
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -16 * s), blur: 34 * s, color: rgb(0x9A3B08, 0.32))
    ctx.setFillColor(orange)
    ctx.fillEllipse(in: circle(70, 70, 64))
    ctx.restoreGState()
    // The ridged edge.
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(9 * k)
    ctx.setLineDash(phase: 0, lengths: [7 * k, 7 * k])
    ctx.strokeEllipse(in: circle(70, 70, 62))
    ctx.setLineDash(phase: 0, lengths: [])
    // Eyes rolled up and to the side.
    for x in [50.0, 90.0] {
        ctx.setFillColor(white)
        ctx.fillEllipse(in: circle(x, 62, 17))
        ctx.setLineWidth(5 * k)
        ctx.strokeEllipse(in: circle(x, 62, 17))
        ctx.setFillColor(ink)
        ctx.fillEllipse(in: circle(x + 4, 52, 8))
    }
    let mouth = CGMutablePath()
    mouth.move(to: p(54, 98))
    mouth.addQuadCurve(to: p(86, 96), control: p(70, 92))
    ctx.addPath(mouth)
    ctx.setLineWidth(8 * k)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

var images: [[String: String]] = []
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    draw(ctx, size: CGFloat(pixels))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: iconSet.appending(path: name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let info = ["author": "xcode", "version": 1] as [String: Any]
try JSONSerialization.data(withJSONObject: ["images": images, "info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appending(path: "Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: catalog.appending(path: "Contents.json"))
print("wrote \(images.count) icons to \(iconSet.path)")
