import CoreImage
import CoreVideo
import Foundation
import Metal
import Testing
@testable import CutlineCore
@testable import CutlineEngine

/// Renders like the compositor does: Metal context, Rec. 709 output, into a BGRA pixel buffer.
private let compositorContext = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.cacheIntermediates: false, .outputColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!])
private let plain = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

private func buffer(_ w: Int, _ h: Int, _ format: OSType) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, format, [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
    return pb!
}

/// A video-range 4:2:0 frame, as decoders hand to the compositor: a colored picture with a darker left edge.
private func videoFrame(_ w: Int, _ h: Int) -> CVPixelBuffer {
    let pb = buffer(w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    let picture = CIImage(color: CIColor(red: 0.8, green: 0.5, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    let edge = CIImage(color: CIColor(red: 0.3, green: 0.6, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: w / 4, height: h))
    compositorContext.render(edge.composited(over: picture), to: pb, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.itur_709)!)
    return pb
}

/// BGRA bytes of `image` rendered into a canvas-sized pixel buffer; row 0 is the top.
private func rendered(_ image: CIImage, _ w: Int, _ h: Int) -> (bytes: [UInt8], rowBytes: Int) {
    let out = buffer(w, h, kCVPixelFormatType_32BGRA)
    compositorContext.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpace(name: CGColorSpace.itur_709)!)
    CVPixelBufferLockBaseAddress(out, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
    let row = CVPixelBufferGetBytesPerRow(out)
    let base = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
    return (Array(UnsafeBufferPointer(start: base, count: row * h)), row)
}

private func writeCube(_ f: ColorMath.Transform, size: Int = 17) throws -> String {
    let data = ColorMath.cubeData(size: size, f)
    var text = "LUT_3D_SIZE \(size)\n"
    for i in 0..<(size * size * size) { text += "\(data[i * 4]) \(data[i * 4 + 1]) \(data[i * 4 + 2])\n" }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-test-\(UUID().uuidString).cube")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

private func letterboxScene(_ effects: [Effect]) -> RenderScene {
    var p = Project(name: "Letterbox", canvas: Canvas(width: 1920, height: 1080, fps: 30))
    p.media = [MediaAsset(id: "m", path: "/dev/null", name: "scope", duration: 10, width: 862, height: 360, fps: 30, hasVideo: true, hasAudio: false)]
    p.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "m", start: 0, duration: 5, effects: effects)]
    return RenderScene(project: p, captions: [], trackIDs: [:], orientations: [:], images: [:])
}

@Test func letterboxBarsStayBlackUnderMatchLUTAndEffects() throws {
    let frame = videoFrame(862, 360)
    let lift = try writeCube { $0 * 0.75 + 0.25 }
    defer { try? FileManager.default.removeItem(atPath: lift) }
    // A match LUT built the way recipe match_color builds one, from a dark shot toward a bright one.
    let dark = ColorMatch.stats((0..<400).map { i in SIMD3<Float>(repeating: Float(i % 20) / 60) })
    let bright = ColorMatch.stats((0..<400).map { i in SIMD3<Float>(0.4 + Float(i % 20) / 50, 0.35 + Float(i % 20) / 50, 0.3 + Float(i % 20) / 50) })
    let match = try writeCube(ColorMatch.transform(from: dark, to: bright, strength: 1))
    defer { try? FileManager.default.removeItem(atPath: match) }
    let stacks: [[Effect]] = [
        [Effect(id: "match", type: "color.lut", params: ["file": .string(lift)])],
        [Effect(id: "match", type: "color.lut", params: ["file": .string(match)]), Effect(id: "w", type: "color.wheels", params: ["lift": .number(0.2), "offset_b": .number(0.1)])],
        [Effect(id: "b", type: "blur.gaussian", params: ["radius": .number(0.05)]), Effect(id: "g", type: "stylize.glow", params: ["amount": .number(1.5)])],
        [Effect(id: "look", type: "color.look", params: ["look": .string("vintage_fade")]), Effect(id: "v", type: "stylize.vignette"), Effect(id: "s", type: "blur.sharpen")],
        [Effect(id: "q", type: "color.adjust", params: ["exposure": .number(1), "limit": .string("ellipse+qualifier"), "q_hue": .number(30)])],
    ]
    for stack in stacks {
        let scene = letterboxScene(stack)
        let (px, row) = rendered(scene.render(at: 1) { _ in frame }, 1920, 1080)
        // The picture is 1920×802, rows 139…940; check the bars well clear of the edge and right next to it.
        for y in [5, 70, 136, 944, 1075] {
            for x in [0, 300, 960, 1919] {
                let o = y * row + x * 4
                #expect(px[o] < 3 && px[o + 1] < 3 && px[o + 2] < 3, "\(stack.map(\.type)) bar pixel \(x),\(y) is \(px[o + 2]),\(px[o + 1]),\(px[o])")
            }
        }
        let o = 540 * row + 1400 * 4
        #expect(Int(px[o]) + Int(px[o + 1]) + Int(px[o + 2]) > 60, "\(stack.map(\.type)) picture went dark")
    }
}

@Test func adjustmentLayersAndTrackEffectsLeaveBlackBarsBlack() throws {
    let frame = videoFrame(862, 360)
    var p = letterboxScene([]).project
    p.tracks[0].effects = [Effect(id: "tl", type: "color.look", params: ["look": .string("pastel")])]
    let adj = p.addTrack(kind: .video, name: "Look")
    try p.addClip(Clip(id: "adj", kind: .adjustment, start: 0, duration: 5, effects: [Effect(id: "look", type: "color.look", params: ["look": .string("vintage_fade")])]), trackId: adj.id, mode: .place)
    let scene = RenderScene(project: p, captions: [], trackIDs: [:], orientations: [:], images: [:])
    let (px, row) = rendered(scene.render(at: 1) { _ in frame }, 1920, 1080)
    let bar = 40 * row + 960 * 4, picture = 540 * row + 960 * 4
    #expect(px[bar] < 3 && px[bar + 1] < 3 && px[bar + 2] < 3, "bar \(px[bar + 2]),\(px[bar + 1]),\(px[bar])")
    #expect(Int(px[picture]) + Int(px[picture + 1]) + Int(px[picture + 2]) > 60)
}

@Test func pictureStatsIgnoreLetterboxBars() {
    let w = 192, h = 108
    var bgra = [UInt8](repeating: 0, count: w * h * 4)
    for y in 14..<94 {
        for x in 0..<w {
            let o = (y * w + x) * 4
            let v = UInt8(100 + (x + y) % 40)
            bgra[o] = v; bgra[o + 1] = v; bgra[o + 2] = v; bgra[o + 3] = 255
        }
    }
    let s = bgra.withUnsafeBufferPointer { PictureMeter.stats($0.baseAddress!, width: w, height: h, rowBytes: w * 4, time: 0) }
    #expect(s.crushed == 0, "crushed \(s.crushed)")
    #expect(abs(s.picture - 80.0 / 108) < 0.02, "picture \(s.picture)")
    #expect(s.luma > 0.38 && s.luma < 0.56, "luma \(s.luma)")

    // A frame that fades to black is all black, not all bars.
    let black = [UInt8](repeating: 0, count: w * h * 4)
    let f = black.withUnsafeBufferPointer { PictureMeter.stats($0.baseAddress!, width: w, height: h, rowBytes: w * 4, time: 0) }
    #expect(f.crushed > 0.99 && f.picture == 1)

    // Scopes: a pillarboxed frame on a gray canvas background.
    let picture = CIImage(color: CIColor(red: 0.6, green: 0.5, blue: 0.4)).cropped(to: CGRect(x: 240, y: 0, width: 400, height: 360))
    let canvas = picture.composited(over: CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360)))
    let stats = Scopes.stats(canvas, context: plain, background: RGBA(r: 0.2, g: 0.2, b: 0.2))
    #expect(stats.map { abs($0.picture - 400.0 / 640) < 0.03 } == true, "\(String(describing: stats?.picture))")
    #expect(stats.map { $0.parade.red.low > 0.5 } == true, "\(String(describing: stats?.parade.red))")
}

private func pixel(_ img: CIImage, _ x: CGFloat, _ yFromTop: CGFloat, height: CGFloat) -> [Int] {
    var px = [UInt8](repeating: 0, count: 4)
    plain.render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: height - yFromTop - 1, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return px.map(Int.init)
}

@Test func windowAndQualifierIntersect() {
    // Red on the left half, green on the right; a centered window covering x 50…150.
    let red = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
    let img = red.composited(over: CIImage(color: CIColor(red: 0.1, green: 0.8, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100)))
    let fx = Effect(id: "inv", type: "color.invert", params: [
        "limit": .string("rect+qualifier"), "limit_width": .number(0.5), "limit_height": .number(1.2), "limit_feather": .number(0),
        "q_hue": .number(0), "q_hue_width": .number(40), "q_softness": .number(0.05),
    ])
    let ctx = EffectRenderer.Context(unit: 100, time: 0, opaque: true)
    let out = EffectRenderer.apply([fx], to: img, context: ctx) { _, _ in nil }
    #expect(pixel(out, 75, 50, height: 100)[0] < 60, "red inside the window is inverted: \(pixel(out, 75, 50, height: 100))")
    #expect(pixel(out, 25, 50, height: 100)[0] > 200, "red outside the window is untouched")
    #expect(pixel(out, 125, 50, height: 100)[1] > 180 && pixel(out, 125, 50, height: 100)[0] < 60, "green inside the window is untouched")

    let matte = EffectRenderer.matte([fx], id: "inv", to: img, context: ctx) { _, _ in nil }!
    #expect(pixel(matte, 75, 50, height: 100)[0] > 230)
    #expect(pixel(matte, 25, 50, height: 100)[0] < 25)
    #expect(pixel(matte, 125, 50, height: 100)[0] < 25)

    var inverted = fx
    inverted.params["limit_invert"] = .bool(true)
    let outside = EffectRenderer.apply([inverted], to: img, context: ctx) { _, _ in nil }
    #expect(pixel(outside, 75, 50, height: 100)[0] > 200)
    #expect(pixel(outside, 125, 50, height: 100)[1] < 100, "everything outside the intersection is inverted")
}

@Test func matteViewShowsWhereAMaskKeeps() {
    var p = Project(name: "Matte", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.tracks[0].clips = [Clip(id: "s", kind: .solid, start: 0, duration: 3, effects: [Effect(id: "m", type: "mask.ellipse", params: ["width": .number(0.5), "height": .number(0.5)])], color: RGBA(r: 0.2, g: 0.4, b: 0.8))]
    let scene = RenderScene(project: p, captions: [], trackIDs: [:], orientations: [:], images: [:])
    scene.matteView = RenderScene.MatteView(clip: "s", effect: "m")
    let img = scene.render(at: 1) { _ in nil }
    #expect(pixel(img, 160, 90, height: 180)[0] > 240)
    #expect(pixel(img, 10, 10, height: 180)[0] < 10)
    #expect(pixel(img, 160, 90, height: 180)[2] == pixel(img, 160, 90, height: 180)[0], "gray, not the clip's color")
}

@Test func personMaskHardeningMakesTheSubjectOpaque() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.9)).cropped(to: frame)
    // Vision-style soft matte: 0.7 over the subject, 0.3 haze beside it, 0 elsewhere.
    let subject = CIImage(color: CIColor(red: 0.7, green: 0.7, blue: 0.7)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 100))
    let haze = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 50, y: 0, width: 25, height: 100))
    let soft = subject.composited(over: haze).composited(over: CIImage(color: .black).cropped(to: frame))
    let raw = Segmentation.apply(mask: soft, to: image)
    #expect(pixel(raw, 25, 50, height: 100)[3] < 200, "raw matte is see-through: \(pixel(raw, 25, 50, height: 100))")
    let hard = Segmentation.apply(mask: soft, to: image, threshold: 0.5)
    #expect(pixel(hard, 25, 50, height: 100)[3] == 255)
    #expect(pixel(hard, 60, 50, height: 100)[3] == 0)
    #expect(pixel(hard, 90, 50, height: 100)[3] == 0)

    // mask.person passes expand − choke, so a choke pulls the hardened edge in.
    let choked = Segmentation.apply(mask: soft, to: image, expand: -5, threshold: 0.5)
    #expect(pixel(choked, 47, 50, height: 100)[3] == 0)
    #expect(pixel(choked, 25, 50, height: 100)[3] == 255)
    #expect(EffectCatalog.type("mask.person")?.spec("threshold")?.defaultValue == .number(0.5))
}
