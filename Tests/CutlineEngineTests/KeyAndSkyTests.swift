import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CutlineCore
@testable import CutlineEngine

private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])

/// Red, green, blue and alpha of one pixel, 0–255, with y measured from the top.
private func pixel(_ img: CIImage, _ x: CGFloat, _ yFromTop: CGFloat) -> [Int] {
    var px = [UInt8](repeating: 0, count: 4)
    let e = img.extent
    context.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: e.minX + x, y: e.maxY - yFromTop - 1, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return px.map(Int.init)
}

/// A picture drawn in sRGB with y down, as CIImage.
private func picture(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CIImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return CIImage(cgImage: ctx.makeImage()!)
}

private func fill(_ ctx: CGContext, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    ctx.fill(rect)
}

private func run(_ type: String, _ params: [String: ParamValue], on img: CIImage) -> CIImage {
    let ctx = EffectRenderer.Context(unit: img.extent.height, time: 0, opaque: true)
    return EffectRenderer.apply([Effect(id: "k", type: type, params: params)], to: img, context: ctx) { _, _ in nil }
}

private func matte(_ type: String, _ params: [String: ParamValue], on img: CIImage) -> CIImage? {
    let ctx = EffectRenderer.Context(unit: img.extent.height, time: 0, opaque: true)
    return EffectRenderer.matte([Effect(id: "k", type: type, params: params)], id: "k", to: img, context: ctx) { _, _ in nil }
}

@Test func lumaKeyDropsBlackAndKeepsBrightPixels() {
    let img = picture(200, 100) { c in
        fill(c, 0, 0, 0, CGRect(x: 0, y: 0, width: 100, height: 100))
        fill(c, 0.6, 0.5, 0.4, CGRect(x: 100, y: 0, width: 100, height: 100))
    }
    let out = run("key.luma", [:], on: img)
    #expect(pixel(out, 50, 50)[3] == 0)
    #expect(pixel(out, 150, 50)[3] == 255)
    let inverted = run("key.luma", ["invert": .bool(true)], on: img)
    #expect(pixel(inverted, 50, 50)[3] == 255 && pixel(inverted, 150, 50)[3] == 0)
    let noWhite = run("key.luma", ["low": .number(0), "high": .number(0.3), "softness": .number(0.05)], on: img)
    #expect(pixel(noWhite, 150, 50)[3] == 0 && pixel(noWhite, 50, 50)[3] == 255, "high keys out brighter pixels")
    let m = matte("key.luma", [:], on: img)!
    #expect(pixel(m, 50, 50)[0] < 10 && pixel(m, 150, 50)[0] > 245, "matte view shows the key")
}

@Test func keyCleanupChokesAndFillsTheMatte() {
    let img = picture(200, 200) { c in
        fill(c, 0, 0, 0, CGRect(x: 0, y: 0, width: 200, height: 200))
        fill(c, 1, 1, 1, CGRect(x: 50, y: 50, width: 100, height: 100))
        fill(c, 0.05, 0.05, 0.05, CGRect(x: 95, y: 95, width: 4, height: 4))
    }
    let plain = run("key.luma", ["softness": .number(0.01)], on: img)
    #expect(pixel(plain, 53, 100)[3] == 255)
    #expect(pixel(plain, 96, 96)[3] == 0, "pinhole")
    let choked = run("key.luma", ["softness": .number(0.01), "choke": .number(0.03)], on: img)
    #expect(pixel(choked, 53, 100)[3] < 20, "choke pulls the edge in")
    let cleaned = run("key.luma", ["softness": .number(0.01), "denoise": .number(0.02)], on: img)
    #expect(pixel(cleaned, 96, 96)[3] == 255, "denoise fills the pinhole")
    let chroma = run("key.chroma", ["color": .string("#00FF00"), "choke": .number(0.03)], on: picture(200, 200) { c in
        fill(c, 0, 1, 0, CGRect(x: 0, y: 0, width: 200, height: 200))
        fill(c, 0.8, 0.2, 0.2, CGRect(x: 50, y: 50, width: 100, height: 100))
    })
    #expect(pixel(chroma, 53, 100)[3] < 20 && pixel(chroma, 100, 100)[3] == 255, "chroma key takes the same cleanup")
}

@Test func differenceKeyKeepsWhatIsNotOnThePlate() throws {
    let plateImg = picture(160, 90) { c in
        fill(c, 0.45, 0.5, 0.55, CGRect(x: 0, y: 0, width: 160, height: 90))
        fill(c, 0.2, 0.3, 0.2, CGRect(x: 0, y: 60, width: 160, height: 30))
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diffkey-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("plate.png")
    let cg = context.createCGImage(plateImg, from: plateImg.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    #expect(CGImageDestinationFinalize(dest))
    // The shot is the plate at twice the size with a person-like red block in front.
    let shot = picture(320, 180) { c in
        fill(c, 0.45, 0.5, 0.55, CGRect(x: 0, y: 0, width: 320, height: 180))
        fill(c, 0.2, 0.3, 0.2, CGRect(x: 0, y: 120, width: 320, height: 60))
        fill(c, 0.8, 0.3, 0.25, CGRect(x: 120, y: 40, width: 80, height: 130))
    }
    let out = run("key.difference", ["plate": .string(url.path)], on: shot)
    #expect(pixel(out, 160, 100)[3] == 255, "subject kept")
    #expect(pixel(out, 30, 30)[3] == 0, "empty set keyed out")
    #expect(pixel(out, 30, 160)[3] == 0, "ground keyed out")
    let m = try #require(matte("key.difference", ["plate": .string(url.path)], on: shot))
    #expect(pixel(m, 160, 100)[0] > 245 && pixel(m, 30, 30)[0] < 10)
    #expect(pixel(run("key.difference", [:], on: shot), 30, 30)[3] == 255, "no plate leaves the picture alone")
}

/// A landscape: blue sky gradient, a building against it, textured green ground and a white wall standing on it.
private func landscape(overcast: Bool = false) -> CIImage {
    picture(384, 216) { c in
        for y in 0..<100 {
            let f = CGFloat(y) / 100
            if overcast { fill(c, 0.78 + 0.1 * f, 0.8 + 0.1 * f, 0.82 + 0.1 * f, CGRect(x: 0, y: y, width: 384, height: 1)) }
            else { fill(c, 0.3 + 0.35 * f, 0.5 + 0.25 * f, 0.9, CGRect(x: 0, y: y, width: 384, height: 1)) }
        }
        var seed: UInt64 = 7
        for y in stride(from: 100, to: 216, by: 2) {
            for x in stride(from: 0, to: 384, by: 2) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let v = CGFloat((seed >> 33) % 100) / 100
                fill(c, 0.15 + 0.2 * v, 0.35 + 0.25 * v, 0.1 + 0.1 * v, CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        fill(c, 0.35, 0.22, 0.15, CGRect(x: 250, y: 40, width: 70, height: 70))
        fill(c, 0.97, 0.97, 0.97, CGRect(x: 40, y: 150, width: 90, height: 40))
    }
}

@Test func skyMaskFindsTheSkyConnectedToTheTop() throws {
    for overcast in [false, true] {
        let img = landscape(overcast: overcast)
        let m = try #require(matte("mask.sky", [:], on: img))
        let label = overcast ? "overcast" : "blue"
        #expect(pixel(m, 100, 20)[0] > 220, "\(label): sky at the top")
        #expect(pixel(m, 100, 85)[0] > 200, "\(label): sky down to the horizon")
        #expect(pixel(m, 285, 75)[0] < 40, "\(label): building isn't sky")
        #expect(pixel(m, 200, 160)[0] < 30, "\(label): ground isn't sky")
        #expect(pixel(m, 85, 170)[0] < 30, "\(label): a white wall away from the sky isn't sky")
        let kept = run("mask.sky", ["invert": .bool(true)], on: img)
        #expect(pixel(kept, 100, 20)[3] < 30 && pixel(kept, 200, 160)[3] == 255, "\(label): invert keeps the foreground")
    }
    let night = picture(384, 216) { c in fill(c, 0.03, 0.03, 0.08, CGRect(x: 0, y: 0, width: 384, height: 216)) }
    #expect(pixel(try #require(matte("mask.sky", [:], on: night)), 100, 20)[0] < 20, "dark frames have no sky")
}

@Test func skyEstimateLimitsToBottom() {
    let w = 64, h = 36
    var rgb = [Float](repeating: 0, count: w * h * 3)
    for i in 0..<(w * h) { rgb[i * 3] = 0.45; rgb[i * 3 + 1] = 0.6; rgb[i * 3 + 2] = 0.92 }
    let all = SkyMask.estimate(rgb: rgb, width: w, height: h, settings: SkyMask.Settings(bottom: 0.5))
    #expect(all[5 * w + 10] > 0.9)
    #expect(all[30 * w + 10] == 0, "nothing below bottom")
}

private let film = "/tmp/cl-real/downloads/tears_of_steel_720p.mp4"

/// Sky mattes of Tears of Steel frames written to /tmp/cutline-sky for a look.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CUTLINE_SLOW"] != nil && FileManager.default.fileExists(atPath: film)))
func skyMaskOnTearsOfSteel() async throws {
    let media = MediaAsset(id: "tos", path: film, name: "tos", duration: 734, width: 1280, height: 534, fps: 24, hasVideo: true, hasAudio: true)
    let times: [Double] = [20, 30, 222, 300, 310, 350]
    let frames = try await Frames.media(media, times: times, maxSize: CGSize(width: 1280, height: 720))
    let out = URL(fileURLWithPath: "/tmp/cutline-sky")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var top: [Double] = []
    for (t, f) in zip(times, frames) {
        let img = CIImage(cgImage: try #require(f.image))
        let m = try #require(SkyMask.matte(img))
        let over = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: img.extent), kCIInputMaskImageKey: m.applyingFilter("CIColorInvert")])
        let cg = context.createCGImage(over, from: img.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        let dest = CGImageDestinationCreateWithURL(out.appendingPathComponent("sky-\(Int(t)).jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        top.append(Double(pixel(m, img.extent.width * 0.9, 8)[0]) / 255)
        let sunset = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: img.extent.height), "inputPoint1": CIVector(x: 0, y: 0), "inputColor0": CIColor(red: 0.25, green: 0.3, blue: 0.6), "inputColor1": CIColor(red: 1, green: 0.6, blue: 0.3)])!.outputImage!.cropped(to: img.extent)
        let kept = run("mask.sky", ["invert": .bool(true), "feather": .number(0.003), "expand": .number(0.004)], on: img)
        let replaced = kept.composited(over: sunset)
        let rcg = context.createCGImage(replaced, from: img.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!
        let rdest = CGImageDestinationCreateWithURL(out.appendingPathComponent("replaced-\(Int(t)).jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(rdest, rcg, nil)
        CGImageDestinationFinalize(rdest)
    }
    print("sky at the top right:", zip(times, top).map { "\(Int($0.0))s \(String(format: "%.2f", $0.1))" })
    #expect(top[0] > 0.8, "the skyline at 20 s has open sky at the top")
    #expect(top[4] < 0.2, "the close-up at 310 s has none")
}

