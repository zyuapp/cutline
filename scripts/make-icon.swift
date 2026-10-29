// Renders Resources/AppIcon.icns: a graphite tile with a film frame, a cut, and Claude's light.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.45))
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: s * 0.185, cornerHeight: s * 0.185, transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.165, blue: 0.175, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: s * 0.185, cornerHeight: s * 0.185, transform: nil))
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [CGColor(gray: 1, alpha: 0.07), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
    ctx.restoreGState()

    // Two halves of a frame, offset along a diagonal cut.
    let frame = CGRect(x: s * 0.24, y: s * 0.33, width: s * 0.52, height: s * 0.34)
    let light = CGColor(srgbRed: 0.91, green: 0.91, blue: 0.89, alpha: 1)
    func half(_ left: Bool, dx: CGFloat, dy: CGFloat) {
        ctx.saveGState()
        let cut = CGMutablePath()
        let a = CGPoint(x: frame.midX + s * 0.05, y: frame.maxY + s * 0.02), b = CGPoint(x: frame.midX - s * 0.05, y: frame.minY - s * 0.02)
        if left {
            cut.move(to: CGPoint(x: 0, y: s)); cut.addLine(to: CGPoint(x: a.x, y: s)); cut.addLine(to: a); cut.addLine(to: b); cut.addLine(to: CGPoint(x: b.x, y: 0)); cut.addLine(to: .zero)
        } else {
            cut.move(to: CGPoint(x: s, y: s)); cut.addLine(to: CGPoint(x: a.x, y: s)); cut.addLine(to: a); cut.addLine(to: b); cut.addLine(to: CGPoint(x: b.x, y: 0)); cut.addLine(to: CGPoint(x: s, y: 0))
        }
        cut.closeSubpath()
        ctx.translateBy(x: dx, y: dy)
        ctx.addPath(cut)
        ctx.clip()
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: s * 0.03, cornerHeight: s * 0.03, transform: nil))
        ctx.setFillColor(light)
        ctx.fillPath()
        ctx.restoreGState()
    }
    half(true, dx: -s * 0.018, dy: s * 0.012)
    half(false, dx: s * 0.018, dy: -s * 0.012)

    // Claude's light.
    let r = s * 0.045
    let c = CGPoint(x: tile.maxX - s * 0.13, y: tile.maxY - s * 0.13)
    ctx.setShadow(offset: .zero, blur: s * 0.04, color: CGColor(srgbRed: 0.663, green: 0.706, blue: 0.961, alpha: 0.9))
    ctx.setFillColor(CGColor(srgbRed: 0.663, green: 0.706, blue: 0.961, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try render(1024).write(to: out.deletingPathExtension().appendingPathExtension("png"))
try? FileManager.default.removeItem(at: iconset)
