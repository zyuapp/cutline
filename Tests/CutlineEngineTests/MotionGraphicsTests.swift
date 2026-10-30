import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

/// RGBA8 sRGB, row 0 at the top.
private struct Bitmap {
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
    var opaque: Int { stride(from: 3, to: data.count, by: 4).reduce(0) { $0 + (data[$1] > 8 ? 1 : 0) } }

    /// Columns of row `y` whose alpha exceeds `threshold`.
    func columns(row y: Int, threshold: Int = 128) -> [Int] { (0..<width).filter { alpha($0, y) > threshold } }
}

private let size = CGSize(width: 400, height: 200)

private func shape(_ json: String, _ extra: [String: ParamValue] = [:]) throws -> Bitmap {
    var params = extra
    params["shapes"] = .string(json)
    return Bitmap(try #require(GeneratorRenderer.render(type: "shape", params: params, canvas: size)))
}

@Test func trimPathDrawsTheRightFractionOfTheStroke() throws {
    // A 0.8 frame-height line (160 px) centered at x 200, stroked with butt caps.
    let line = ##"[{"id": "l", "type": "line", "width": 0.8, "stroke": "#FFFFFF", "stroke_width": 0.04, "cap": "butt"}]"##
    let full = try shape(line).columns(row: 100)
    #expect(full.count >= 159 && full.count <= 161, "\(full.count)")
    for (end, expected) in [(0.25, 40), (0.5, 80), (0.75, 120)] {
        let cols = try shape(line, ["l.trim_end": .number(end)]).columns(row: 100)
        #expect(abs(cols.count - expected) <= 1, "trim_end \(end): \(cols.count) px")
        #expect(abs((cols.first ?? 0) - 120) <= 1, "draws from the start")
    }
    let middle = try shape(line, ["l.trim_start": .number(0.25), "l.trim_end": .number(0.75)]).columns(row: 100)
    #expect(abs(middle.count - 80) <= 1 && abs(middle.first! - 160) <= 1)
    // Offset slides the drawn part along the path.
    let shifted = try shape(line, ["l.trim_end": .number(0.25), "l.trim_offset": .number(0.5)]).columns(row: 100)
    #expect(abs(shifted.first! - 200) <= 1 && abs(shifted.count - 40) <= 1)
    #expect(try shape(line, ["l.trim_end": .number(0)]).opaque == 0)
}

@Test func trimmedRingCoversItsShareOfTheCircle() throws {
    // Ring of radius 80 px starting at 12 o'clock and running clockwise.
    let ring = ##"[{"id": "r", "type": "ellipse", "width": 0.8, "height": 0.8, "stroke": "#FFFFFF", "stroke_width": 0.03}]"##
    let quarter = try shape(ring, ["r.trim_end": .number(0.25)])
    #expect(quarter.alpha(200 + 56, 100 - 56) > 200, "upper right is drawn")
    #expect(quarter.alpha(200 - 56, 100 - 56) == 0, "upper left is not")
    #expect(quarter.alpha(200, 100 + 80) == 0, "bottom is not")
    let half = try shape(ring, ["r.trim_end": .number(0.5)])
    #expect(half.alpha(200, 100 + 80) > 100 && half.alpha(200 - 80, 100) == 0)
}

@Test func shapesAreAntialiasedAtTheirEdges() throws {
    let disc = try shape(##"[{"type": "ellipse", "width": 0.6, "height": 0.6, "fill": "#FFFFFF"}]"##)
    var partial = 0, full = 0
    for y in 0..<disc.height {
        for x in 0..<disc.width {
            let a = disc.alpha(x, y)
            if a == 255 { full += 1 } else if a > 0 {
                partial += 1
                // Partly covered pixels lie on the rim only.
                let r = hypot(Double(x) + 0.5 - 200, Double(y) + 0.5 - 100)
                #expect(abs(r - 60) < 1.5, "partial pixel at radius \(r)")
            }
        }
    }
    #expect(partial > 200, "a 60 px circle has a soft rim, got \(partial) partial pixels")
    #expect(abs(Double(full + partial / 2) - Double.pi * 3600) < 60)
}

@Test func shapeFillsGradientsRepeatersAndMorphs() throws {
    let grad = try shape(##"[{"type": "rect", "width": 1.6, "height": 0.5, "fill": {"gradient": "linear", "colors": ["#FF0000", "#0000FF"], "angle": 90}}]"##)
    #expect(grad.px(50, 100)[0] > 200 && grad.px(350, 100)[2] > 200)
    let row = try shape(##"[{"id": "d", "type": "rect", "x": 0.1, "width": 0.1, "height": 0.1, "repeat_count": 3, "repeat_x": 0.5}]"##)
    for x in [40, 140, 240] { #expect(row.alpha(x, 100) == 255, "copy at \(x)") }
    #expect(row.alpha(340, 100) == 0)
    let partial = try shape(##"[{"id": "d", "type": "rect", "x": 0.1, "width": 0.1, "height": 0.1, "repeat_count": 2.5, "repeat_x": 0.5}]"##)
    #expect(partial.alpha(240, 100) > 100 && partial.alpha(240, 100) < 160, "half of the third copy")
    // A horizontal bar morphing into a vertical one.
    let morph = ##"[{"id": "m", "d": "M -0.4 -0.05 L 0.4 -0.05 L 0.4 0.05 L -0.4 0.05 Z", "d_to": "M -0.05 -0.4 L 0.05 -0.4 L 0.05 0.4 L -0.05 0.4 Z"}]"##
    let a = try shape(morph), b = try shape(morph, ["m.morph": .number(1)])
    #expect(a.alpha(130, 100) == 255 && a.alpha(200, 40) == 0)
    #expect(b.alpha(130, 100) == 0 && b.alpha(200, 40) == 255)
}

@Test func particlesAreDeterministicPerSeed() throws {
    let params: [String: ParamValue] = ["rate": .number(120), "sprite": .string("dot"), "turbulence": .number(0.1)]
    func frame(_ t: Double, _ p: [String: ParamValue]) throws -> Bitmap {
        Bitmap(try #require(GeneratorRenderer.render(type: "particles", params: p, canvas: size, time: t, duration: 5)))
    }
    let a = try frame(1.5, params)
    _ = try frame(0.7, params)
    let b = try frame(1.5, params)
    #expect(a.data == b.data, "any frame renders the same on its own")
    #expect(a.opaque > 50)
    var other = params
    other["seed"] = .number(2)
    #expect(try frame(1.5, other).data != a.data)
    #expect(try frame(0, params).opaque == 0, "nothing born yet")
    var warm = params
    warm["prewarm"] = .number(2)
    #expect(try frame(0, warm).opaque > 50)
    let live = ParticleSystem.particles(at: 3, width: 400, height: 200) { k, _ in params[k] ?? GeneratorCatalog.type("particles")!.spec(k)!.defaultValue }
    // About rate × mean lifetime are alive once the emitter is warm.
    #expect(abs(Double(live.count) - 120 * 2.5) < 60, "\(live.count) alive")
}

@Test func titlePresetsBuildOnHoldAndBuildOff() throws {
    let hd = CGSize(width: 640, height: 360)
    for t in GeneratorCatalog.all where t.id.hasPrefix("title.") {
        func frame(_ time: Double) -> CGImage? { GeneratorRenderer.render(type: t.id, params: [:], canvas: hd, time: time, duration: 5) }
        #expect(frame(0).map { Bitmap($0).opaque } ?? 0 == 0, "\(t.id) starts empty")
        #expect(frame(5).map { Bitmap($0).opaque } ?? 0 == 0, "\(t.id) ends empty")
        let mid = Bitmap(try #require(frame(0.3)))
        let hold = Bitmap(try #require(frame(2)))
        #expect(hold.opaque > 400, "\(t.id) shows at hold")
        #expect(mid.data != hold.data, "\(t.id) is still building at 0.3 s")
        #expect(frame(2) === frame(3), "\(t.id) holds one cached image")
    }
    var p: [String: ParamValue] = ["delay": .number(1)]
    #expect(Bitmap(GeneratorRenderer.render(type: "title.card", params: p, canvas: hd, time: 0.8, duration: 5)!).opaque == 0)
    p["in"] = .number(0)
    #expect(Bitmap(GeneratorRenderer.render(type: "title.card", params: p, canvas: hd, time: 1, duration: 5)!).opaque > 400)
}

// MARK: 3D

private func scene(_ clips: [(Clip, String)], camera: [String: ParamValue]? = nil) throws -> RenderScene {
    var p = Project(name: "3D", canvas: Canvas(width: 400, height: 200, fps: 30))
    p.canvas.background = .black
    for (i, (c, _)) in clips.enumerated() {
        let track = i == 0 ? "V1" : p.addTrack(kind: .video, name: "L\(i)").id
        try p.addClip(c, trackId: track, mode: .place)
    }
    if let camera {
        let t = p.addTrack(kind: .video, name: "Camera").id
        try p.addClip(Clip(id: "cam", kind: .generator, start: 0, duration: 5, effects: [Effect(id: "gen", type: "camera", params: camera)]), trackId: t, mode: .place)
    }
    return RenderScene(project: p, captions: [], trackIDs: [:], orientations: [:], images: [:])
}

private func square(_ id: String, color: String, size s: Double = 0.4, z: Double = 0, x: Double = 0, rotateY: Double = 0) -> Clip {
    var c = Clip(id: id, kind: .generator, start: 0, duration: 5, effects: [Effect(id: "gen", type: "shape.rect", params: ["width": .number(s), "height": .number(s), "radius": .number(0), "fill": .string(color)])])
    c.transform.threeD = true
    c.transform.z = z
    c.transform.x = x
    c.transform.rotateY = rotateY
    return c
}

private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

private func frame(_ s: RenderScene, at t: Double = 1) -> Bitmap {
    Bitmap(context.createCGImage(s.render(at: t) { _ in nil }, from: CGRect(x: 0, y: 0, width: 400, height: 200))!)
}

private func width(_ b: Bitmap, row: Int = 100) -> Int { b.columns(row: row, threshold: 0).filter { b.px($0, row)[0] + b.px($0, row)[1] + b.px($0, row)[2] > 200 }.count }

@Test func threeDLayersProjectThroughTheCamera() throws {
    // Without a camera clip, a 3D layer at z 0 looks exactly as in 2D: 80 px.
    #expect(abs(width(frame(try scene([(square("a", color: "#FFFFFF"), "V1")]))) - 80) <= 1)
    // One frame height deeper the default camera (40° field of view) shrinks it by f / (f + H).
    let f = 0.5 / tan(20 * Double.pi / 180)
    let far = width(frame(try scene([(square("a", color: "#FFFFFF", z: 1), "V1")])))
    #expect(abs(Double(far) - 80 * f / (f + 1)) <= 1.5, "\(far)")
    // Dollying the camera to twice the distance halves the z 0 plane.
    let dolly = width(frame(try scene([(square("a", color: "#FFFFFF"), "V1")], camera: ["distance": .number(2 * f)])))
    #expect(abs(dolly - 40) <= 1, "\(dolly)")
    // Zoom 2 doubles it again.
    let zoomed = width(frame(try scene([(square("a", color: "#FFFFFF"), "V1")], camera: ["distance": .number(2 * f), "zoom": .number(2)])))
    #expect(abs(zoomed - 80) <= 1, "\(zoomed)")
    // Orbiting 90° sees the layer edge on.
    let edge = width(frame(try scene([(square("a", color: "#FFFFFF"), "V1")], camera: ["orbit": .number(90)])))
    #expect(edge <= 2, "\(edge)")
    // Panning the target right moves the picture left by the same amount at z 0.
    let panned = frame(try scene([(square("a", color: "#FFFFFF", size: 0.2), "V1")], camera: ["target_x": .number(0.1)]))
    let cols = (0..<400).filter { panned.px($0, 100)[0] > 128 }
    #expect(abs(Double(cols.first! + cols.last!) / 2 - 160) <= 1)
    // A layer turned toward the camera on its right side shows that side larger.
    let turned = frame(try scene([(square("a", color: "#FFFFFF", size: 0.8, rotateY: -40), "V1")]))
    let span = (0..<400).filter { turned.px($0, 100)[0] > 128 }
    let leftH = (0..<200).filter { turned.px(span.first! + 2, $0)[0] > 128 }.count
    let rightH = (0..<200).filter { turned.px(span.last! - 2, $0)[0] > 128 }.count
    #expect(rightH > leftH + 10, "\(leftH) vs \(rightH)")
}

@Test func threeDLayersDrawFarToNear() throws {
    // The red layer sits on the lower track but nearer the camera, so it covers the blue one.
    let near = square("red", color: "#FF0000", z: -0.3), far = square("blue", color: "#0000FF", size: 0.8, z: 0.5)
    let a = frame(try scene([(near, "V1"), (far, "V2")]))
    #expect(a.px(200, 100)[0] > 200 && a.px(200, 100)[2] < 40, "\(a.px(200, 100))")
    // Swap the depths and blue wins.
    let b = frame(try scene([(square("red", color: "#FF0000", z: 0.5), "V1"), (square("blue", color: "#0000FF", size: 0.8, z: -0.3), "V2")]))
    #expect(b.px(200, 100)[2] > 200 && b.px(200, 100)[0] < 40, "\(b.px(200, 100))")
    // A layer behind the camera is hidden.
    #expect(frame(try scene([(square("a", color: "#FFFFFF", z: -3), "V1")])).px(200, 100)[0] < 10)
}

@Test func depthOfFieldBlursOutOfFocusLayers() throws {
    let sharp = frame(try scene([(square("a", color: "#FFFFFF"), "V1")], camera: ["blur": .number(0.02)]))
    let soft = frame(try scene([(square("a", color: "#FFFFFF", z: 2), "V1")], camera: ["blur": .number(0.02)]))
    func ramp(_ b: Bitmap) -> Int { (0..<400).filter { let v = b.px($0, 100)[0]; return v > 20 && v < 230 }.count }
    #expect(ramp(sharp) <= 2)
    #expect(ramp(soft) > 6)
}
