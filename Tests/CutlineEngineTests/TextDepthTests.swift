import CoreImage
import CutlineCore
@testable import CutlineEngine
import Foundation
import Testing

private struct RGBAImage {
    let width: Int
    let height: Int
    let data: [UInt8]

    init(_ img: CGImage) {
        width = img.width
        height = img.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
        data = bytes
    }

    func px(_ x: Int, _ y: Int) -> [Int] { let i = (y * width + x) * 4; return data[i..<i + 4].map(Int.init) }
    func alpha(_ x: Int, _ y: Int) -> Int { Int(data[(y * width + x) * 4 + 3]) }

    /// Pixels with alpha above `threshold`, as (x, y).
    func covered(_ threshold: Int = 128) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for y in 0..<height { for x in 0..<width where alpha(x, y) > threshold { out.append((x, y)) } }
        return out
    }
}

private let canvas = CGSize(width: 640, height: 360)

private func values(_ type: String, _ params: [String: ParamValue]) -> GeneratorRenderer.Values {
    let spec = GeneratorCatalog.type(type)!
    var map: [String: ParamValue] = [:]
    for p in spec.params { map[p.name] = params[p.name] ?? p.defaultValue }
    return GeneratorRenderer.Values(map: map, spec: spec)
}

@Test func textOnACircleSetsEachGlyphOnTheCircle() throws {
    let params: [String: ParamValue] = ["text": .string("AROUND THE WORLD"), "radius": .number(0.3), "size": .number(0.06)]
    let glyphs = PathText.layout(values("text.path", params), W: canvas.width, H: canvas.height)
    #expect(glyphs.count == 16)
    let c = CGPoint(x: 320, y: 180), r: CGFloat = 0.3 * 360
    var worstRadius: CGFloat = 0, worstTangent: CGFloat = 0
    var polar: [CGFloat] = []
    for g in glyphs {
        let dx = g.center.x - c.x, dy = g.center.y - c.y
        worstRadius = max(worstRadius, abs(hypot(dx, dy) - r))
        // The baseline runs along the circle: the glyph's direction is perpendicular to the radius.
        worstTangent = max(worstTangent, abs((cos(g.angle) * dx + sin(g.angle) * dy) / r))
        polar.append(atan2(dx, -dy))
    }
    print("text on circle: \(glyphs.count) glyphs, worst radius error \(String(format: "%.3f", worstRadius)) px, worst tangent cosine \(String(format: "%.4f", worstTangent))")
    #expect(worstRadius < 0.25)
    #expect(worstTangent < 0.01)
    // Clockwise from the top, spaced by their advances along the arc.
    #expect(abs(polar[0] - glyphs[0].advance / 2 / r) < 0.01)
    for (k, (a, b)) in zip(polar, polar.dropFirst()).enumerated() {
        let arc = (b - a) * r
        let expected = (glyphs[k].advance + glyphs[k + 1].advance) / 2
        #expect(abs(arc - expected) < 0.6, "glyph \(k): arc \(arc) vs advance \(expected)")
    }
    // The letters stand outside the circle and nothing is drawn inside it.
    let img = RGBAImage(try #require(GeneratorRenderer.render(type: "text.path", params: params, canvas: canvas)))
    let ink = img.covered(64)
    #expect(ink.count > 500)
    let radii = ink.map { hypot(CGFloat($0.0) - c.x, CGFloat($0.1) - c.y) }
    #expect(radii.min()! > r - 3 && radii.max()! < r + 0.06 * 360 * 1.1, "ink radii \(radii.min()!)…\(radii.max()!)")
    // flip runs the text inside the circle.
    var inside = params
    inside["flip"] = .bool(true)
    let flipped = RGBAImage(try #require(GeneratorRenderer.render(type: "text.path", params: inside, canvas: canvas))).covered(64).map { hypot(CGFloat($0.0) - c.x, CGFloat($0.1) - c.y) }
    #expect(flipped.max()! < r + 3 && flipped.min()! > r - 0.06 * 360 * 1.1)
}

@Test func pathTextOffsetRunsAlongAndRevealTypesOn() {
    let base: [String: ParamValue] = ["text": .string("ABCDEFGH"), "path": .string("line"), "width": .number(1.2), "y": .number(0.5)]
    let a = PathText.layout(values("text.path", base), W: canvas.width, H: canvas.height)
    var moved = base
    moved["offset"] = .number(0.25)
    let b = PathText.layout(values("text.path", moved), W: canvas.width, H: canvas.height)
    #expect(a.count == 8 && b.count == 8)
    // A quarter of the 1.2-frame-height line is 108 px.
    #expect(abs((b[0].center.x - a[0].center.x) - 108) < 0.5)
    #expect(a.allSatisfy { abs($0.center.y - 180) < 1e-6 && abs($0.angle) < 1e-6 })
    var half = base
    half["reveal"] = .number(0.5)
    #expect(PathText.layout(values("text.path", half), W: canvas.width, H: canvas.height).count == 4)
    // An SVG path: a straight "M" path behaves like the line.
    var svg = base
    svg["path"] = .string("svg")
    svg["d"] = .string("M -0.6 0 L 0.6 0")
    let c = PathText.layout(values("text.path", svg), W: canvas.width, H: canvas.height)
    #expect(zip(a, c).allSatisfy { abs($0.center.x - $1.center.x) < 1e-6 })
}

@Test func pathTextFollowsAShapeLayerPath() throws {
    var p = Project(name: "Path", canvas: Canvas(width: 640, height: 360, fps: 30))
    let ring = ##"[{"id": "ring", "type": "ellipse", "x": 0.4, "y": 0.45, "width": 0.5, "height": 0.5, "stroke": "#FFFFFF"}]"##
    try p.addClip(Clip(id: "shp", kind: .generator, start: 0, duration: 5, effects: [Effect(id: "gen", type: "shape", params: ["shapes": .string(ring)])]), trackId: "V1", mode: .place)
    let t = p.addTrack(kind: .video, name: "Text").id
    try p.addClip(Clip(id: "txt", kind: .generator, start: 0, duration: 5, effects: [Effect(id: "gen", type: "text.path", params: ["text": .string("RING TEXT"), "d": .string("shape:shp.ring")])]), trackId: t, mode: .place)
    let scene = RenderScene(project: p, captions: [], trackIDs: [:], orientations: [:], images: [:])
    let clip = try #require(p.clip("txt"))
    let v = scene.generatorValues(clip, clip.effects[0], at: 1)
    #expect(v("path").string == "svg" && v("x").number == 0.4 && v("y").number == 0.45)
    let spec = GeneratorCatalog.type("text.path")!
    var map: [String: ParamValue] = [:]
    for s in spec.params { map[s.name] = v(s.name) }
    let glyphs = PathText.layout(GeneratorRenderer.Values(map: map, spec: spec), W: 640, H: 360)
    #expect(glyphs.count == 9)
    for g in glyphs { #expect(abs(hypot(g.center.x - 256, g.center.y - 162) - 90) < 0.3, "\(g.center)") }
}

@Test func extrudedTextShowsItsDepth() throws {
    let flat: [String: ParamValue] = ["text": .string("DEPTH"), "depth": .number(0), "size": .number(0.2), "bevel": .number(0)]
    var deep = flat
    deep["depth"] = .number(0.06)
    let a = RGBAImage(try #require(GeneratorRenderer.render(type: "text.extruded", params: flat, canvas: canvas)))
    let b = RGBAImage(try #require(GeneratorRenderer.render(type: "text.extruded", params: deep, canvas: canvas)))
    func box(_ img: RGBAImage) -> (Int, Int, Int, Int) {
        let pts = img.covered()
        return (pts.map(\.0).min()!, pts.map(\.1).min()!, pts.map(\.0).max()!, pts.map(\.1).max()!)
    }
    let fa = box(a), fb = box(b)
    // 0.06 of 360 px toward 135° (down-right): 15.3 px right and down.
    let shift = 0.06 * 360 * sin(Double.pi / 4)
    print("extrusion: bounds grow \(fb.2 - fa.2) px right, \(fb.3 - fa.3) px down (expected \(String(format: "%.1f", shift)))")
    #expect(abs(Double(fb.2 - fa.2) - shift) <= 2 && abs(Double(fb.3 - fa.3) - shift) <= 2)
    #expect(fb.0 == fa.0 && fb.1 == fa.1)
    // The extra pixels are the side color (darkened or lit), not the face's yellow.
    let face = RGBA(hex: "#FFD60A")!
    var sides = 0
    for (x, y) in b.covered(200) where a.alpha(x, y) < 10 {
        let p = b.px(x, y)
        if abs(Double(p[0]) / 255 - face.r) > 0.15 || abs(Double(p[1]) / 255 - face.g) > 0.15 { sides += 1 }
    }
    #expect(sides > 800, "side pixels \(sides)")
    // Sides facing the light (top left) are brighter than sides facing away.
    let lit = PathText.lit(CGPoint(x: -1, y: 0), PathText.direction(315)), dark = PathText.lit(CGPoint(x: 1, y: 0), PathText.direction(315))
    #expect(lit > 0 && dark < 0)
}

@Test func extrudedTextStacksInDepthOnA3DLayer() throws {
    func frame(depth: Double, rotateY: Double) throws -> RGBAImage {
        var p = Project(name: "3D text", canvas: Canvas(width: 640, height: 360, fps: 30))
        p.canvas.background = .black
        var c = Clip(id: "t", kind: .generator, start: 0, duration: 5, effects: [Effect(id: "gen", type: "text.extruded", params: ["text": .string("3D"), "size": .number(0.4), "depth": .number(depth), "side_color": .string("#2060FF"), "color": .string("#FFFFFF"), "bevel": .number(0)])])
        c.transform.threeD = true
        c.transform.rotateY = rotateY
        try p.addClip(c, trackId: "V1", mode: .place)
        let scene = RenderScene(project: p, captions: [], trackIDs: [:], orientations: [:], images: [:])
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        return RGBAImage(ctx.createCGImage(scene.render(at: 1) { _ in nil }, from: CGRect(x: 0, y: 0, width: 640, height: 360))!)
    }
    func blue(_ img: RGBAImage) -> Int {
        var n = 0
        for y in 0..<img.height { for x in 0..<img.width { let p = img.px(x, y); if p[2] > 80 && p[2] > p[0] + 40 { n += 1 } } }
        return n
    }
    let flatTurned = try frame(depth: 0, rotateY: 40), deepTurned = try frame(depth: 0.15, rotateY: 40), deepFront = try frame(depth: 0.15, rotateY: 0)
    let (b0, b1, b2) = (blue(flatTurned), blue(deepTurned), blue(deepFront))
    print("3D extrusion: side pixels flat \(b0), deep turned \(b1), deep facing \(b2)")
    #expect(b0 == 0)
    // Turned 40°, the sides show broadly; facing the camera only a perspective rim shows.
    #expect(b1 > 3000)
    #expect(b2 > 0 && b2 < b1 / 2)
}
