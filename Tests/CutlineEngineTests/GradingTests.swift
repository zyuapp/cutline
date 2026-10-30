import AVFoundation
import CoreImage
import Foundation
import Testing
import Vision
@testable import CutlineCore
@testable import CutlineEngine

private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
private let context = CIContext(options: [.cacheIntermediates: false])

/// Working-space values of `img` (linear light), row 0 at the top.
private func floats(_ img: CIImage) -> (px: [Float], w: Int, h: Int) {
    let e = img.extent.integral
    let w = Int(e.width), h = Int(e.height)
    var px = [Float](repeating: 0, count: w * h * 4)
    context.render(img, toBitmap: &px, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: linear)
    return (px, w, h)
}

private func value(_ f: (px: [Float], w: Int, h: Int), _ x: Int, _ yFromTop: Int) -> SIMD3<Float> {
    let o = (yFromTop * f.w + x) * 4
    return SIMD3(f.px[o], f.px[o + 1], f.px[o + 2])
}

private func srgb(_ r: Double, _ g: Double, _ b: Double) -> CIColor {
    CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
}

private func swatches(_ colors: [CIColor], size: CGFloat = 20) -> CIImage {
    var img = CIImage.empty()
    for (i, c) in colors.enumerated() {
        img = CIImage(color: c).cropped(to: CGRect(x: CGFloat(i) * size, y: 0, width: size, height: size)).composited(over: img)
    }
    return img
}

private func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

@Test func qualifierKeyFollowsRangesAndSoftnessOnThePicture() {
    // Hues 0, 30, 45 and 90 at HSV saturation 0.6, value 0.8; hue 30 ± 10 with 10° softness.
    let colors = [srgb(0.8, 0.32, 0.32), srgb(0.8, 0.56, 0.32), srgb(0.8, 0.68, 0.32), srgb(0.56, 0.8, 0.32)]
    let img = swatches(colors)
    let q = Qualifier(hue: 30, hueWidth: 20, hueSoft: 10, satLow: 0.2, satHigh: 1, satSoft: 0.05, blur: 0, denoise: 0)
    let key = floats(EffectRenderer.qualifierKey(img, q, unit: 20))
    let w = (0..<4).map { value(key, $0 * 20 + 10, 10).x }
    #expect(w[0] < 0.02 && w[3] < 0.02, "\(w)")
    #expect(w[1] > 0.97, "\(w)")
    // Hue 45 sits 5° past the range's edge, halfway through the softness.
    #expect(abs(w[2] - 0.5) < 0.12, "\(w)")

    // Clean white pushes the half-strength swatch up; clean black pulls it down.
    var cleaned = q
    cleaned.cleanWhite = 0.49
    #expect(value(floats(EffectRenderer.qualifierKey(img, cleaned, unit: 20)), 50, 10).x > 0.9)
    cleaned = q
    cleaned.cleanBlack = 0.45
    #expect(value(floats(EffectRenderer.qualifierKey(img, cleaned, unit: 20)), 50, 10).x < 0.15)
}

@Test func qualifierDenoiseDropsSpecksAndBlurSoftensTheEdge() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let gray = CIImage(color: srgb(0.5, 0.5, 0.5)).cropped(to: frame)
    let red = srgb(0.8, 0.2, 0.2)
    // A red block on the left and one-pixel red specks on the right.
    var img = CIImage(color: red).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 100)).composited(over: gray)
    for (x, y) in [(70, 20), (80, 60), (90, 85)] { img = CIImage(color: red).cropped(to: CGRect(x: x, y: y, width: 1, height: 1)).composited(over: img) }
    var q = Qualifier(hue: 0, hueWidth: 30, satLow: 0.3, blur: 0, denoise: 0)
    let raw = floats(EffectRenderer.qualifierKey(img, q, unit: 100))
    #expect(value(raw, 70, 79).x > 0.9, "a speck qualifies without cleanup")
    q.denoise = 0.02
    let clean = floats(EffectRenderer.qualifierKey(img, q, unit: 100))
    #expect([(70, 79), (80, 39), (90, 14)].allSatisfy { value(clean, $0.0, $0.1).x < 0.05 }, "specks are opened away")
    #expect(value(clean, 25, 50).x > 0.95, "the block survives")
    q.blur = 0.06
    let soft = floats(EffectRenderer.qualifierKey(img, q, unit: 100))
    let edge = value(soft, 51, 50).x
    #expect(edge > 0.2 && edge < 0.8, "blurred edge \(edge)")
}

@Test func matteViewShowsQualifierWeights() {
    let img = swatches([srgb(0.8, 0.56, 0.32), srgb(0.8, 0.68, 0.32), srgb(0.2, 0.3, 0.8)])
    let fx = Effect(id: "q", type: "color.adjust", params: ["exposure": .number(1), "limit": .string("qualifier"), "q_hue": .number(30), "q_hue_width": .number(20), "q_hue_soft": .number(10), "q_sat_min": .number(0.2), "q_blur": .number(0), "q_denoise": .number(0)])
    let ctx = EffectRenderer.Context(unit: 20, time: 0, opaque: true)
    let m = EffectRenderer.matte([fx], id: "q", to: img, context: ctx) { _, _ in nil }!
    // Rendered for display (sRGB), the matte shows the weight itself: full, about half, none.
    var px = [UInt8](repeating: 0, count: 60 * 20 * 4)
    context.render(m, toBitmap: &px, rowBytes: 60 * 4, bounds: CGRect(x: 0, y: 0, width: 60, height: 20), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    let at = { (x: Int) in Int(px[(10 * 60 + x) * 4]) }
    #expect(at(10) > 245)
    #expect(abs(at(30) - 128) < 35, "\(at(30))")
    #expect(at(50) < 8)
}

// MARK: Nodes

/// A CDL effect, which works on sRGB-encoded values: out = in × slope + offset.
private func cdl(_ id: String, slope: Double = 1, offset: Double = 0, _ extra: [String: ParamValue] = [:]) -> Effect {
    var p: [String: ParamValue] = ["slope_r": .number(slope), "slope_g": .number(slope), "slope_b": .number(slope), "offset_r": .number(offset), "offset_g": .number(offset), "offset_b": .number(offset)]
    p.merge(extra) { $1 }
    return Effect(id: id, type: "color.cdl", params: p)
}

@Test func parallelNodesAddTheirChangesFromOneInput() {
    let x = 0.3
    let img = CIImage(color: srgb(x, x, x)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    let ctx = EffectRenderer.Context(unit: 8, time: 0, opaque: true)
    let double = cdl("a", slope: 2), lift = cdl("b", offset: 0.1)
    let serial = value(floats(EffectRenderer.apply([double, lift], to: img, context: ctx) { _, _ in nil }), 4, 4).x
    #expect(abs(Double(serial) - lin(2 * x + 0.1)) < 0.01)
    var p1 = double, p2 = lift
    p1.params["node_mode"] = .string("parallel")
    p2.params["node_mode"] = .string("parallel")
    let parallel = value(floats(EffectRenderer.apply([p1, p2], to: img, context: ctx) { _, _ in nil }), 4, 4).x
    // Each branch sees the same input; their changes (in linear light) add up.
    let expected = lin(2 * x) + lin(x + 0.1) - lin(x)
    #expect(abs(Double(parallel) - expected) < 0.01, "parallel \(parallel), expected \(expected)")

    // node_opacity scales a branch's change.
    p2.params["node_opacity"] = .number(0.5)
    let half = value(floats(EffectRenderer.apply([p1, p2], to: img, context: ctx) { _, _ in nil }), 4, 4).x
    #expect(abs(Double(half) - (lin(2 * x) + (lin(x + 0.1) - lin(x)) / 2)) < 0.012)

    // Effects sharing a node label run in order inside one branch.
    var g1 = cdl("g1", offset: 0.1), g2 = cdl("g2", slope: 2)
    for i in [0, 1] {
        var e = [g1, g2][i]
        e.params["node"] = .string("grp")
        e.params["node_mode"] = .string("parallel")
        if i == 0 { g1 = e } else { g2 = e }
    }
    var other = cdl("o", offset: 0.05)
    other.params["node_mode"] = .string("parallel")
    let grouped = value(floats(EffectRenderer.apply([g1, g2, other], to: img, context: ctx) { _, _ in nil }), 4, 4).x
    let groupedExpected = lin(2 * (x + 0.1)) + lin(x + 0.05) - lin(x)
    #expect(abs(Double(grouped) - groupedExpected) < 0.012, "grouped \(grouped) expected \(groupedExpected)")
    #expect(EffectNodes.nodes([g1, g2, other]).map(\.effects) == [[0, 1], [2]])
}

@Test func layerNodesCompositeInsideTheirKeysWithBlendAndOpacity() {
    let frame = CGRect(x: 0, y: 0, width: 20, height: 10)
    let img = CIImage(color: srgb(0.4, 0.4, 0.4)).cropped(to: frame)
    let ctx = EffectRenderer.Context(unit: 10, time: 0, opaque: true)
    // Bottom layer: the whole frame to 0.8. Top layer: the left half to black, at half opacity.
    var bright = cdl("bright", slope: 2)
    bright.params["node_mode"] = .string("layer")
    var dark = cdl("dark", slope: 0)
    dark.params.merge(["node_mode": .string("layer"), "node_opacity": .number(0.5), "limit": .string("rect"), "limit_x": .number(0.25), "limit_width": .number(0.5), "limit_height": .number(2), "limit_feather": .number(0)]) { $1 }
    let out = floats(EffectRenderer.apply([bright, dark], to: img, context: ctx) { _, _ in nil })
    #expect(abs(Double(value(out, 15, 5).x) - lin(0.8)) < 0.01, "outside the top layer's key: the bottom layer")
    #expect(abs(Double(value(out, 5, 5).x) - lin(0.8) / 2) < 0.01, "inside: half black over the bottom layer \(value(out, 5, 5).x)")

    // Multiply: a 0.5 layer over the 0.8 bottom layer gives their product in linear light.
    var mult = cdl("m", slope: 1.25)
    mult.params.merge(["node_mode": .string("layer"), "node_blend": .string("multiply")]) { $1 }
    let product = floats(EffectRenderer.apply([bright, mult], to: img, context: ctx) { _, _ in nil })
    #expect(abs(Double(value(product, 15, 5).x) - lin(0.8) * lin(0.5)) < 0.01, "\(value(product, 15, 5).x)")
}

@Test func outsideNodeGradesTheInverseOfThePreviousKey() {
    let frame = CGRect(x: 0, y: 0, width: 20, height: 10)
    let img = CIImage(color: srgb(0.4, 0.4, 0.4)).cropped(to: frame)
    let ctx = EffectRenderer.Context(unit: 10, time: 0, opaque: true)
    let face = cdl("face", slope: 2, ["limit": .string("rect"), "limit_x": .number(0.25), "limit_width": .number(0.5), "limit_height": .number(2), "limit_feather": .number(0)])
    let background = cdl("bg", slope: 0.5, ["node_mode": .string("outside")])
    let effects = [face, background]
    let out = floats(EffectRenderer.apply(effects, to: img, context: ctx) { _, _ in nil })
    #expect(abs(Double(value(out, 5, 5).x) - lin(0.8)) < 0.01, "inside the key: only the first node")
    #expect(abs(Double(value(out, 15, 5).x) - lin(0.2)) < 0.01, "outside: only the outside node")
    let matte = floats(EffectRenderer.matte(effects, id: "bg", to: img, context: ctx) { _, _ in nil }!)
    #expect(value(matte, 5, 5).x < 0.02 && value(matte, 15, 5).x > 0.98)
    #expect(EffectNodes.describe(effects)?.contains("outside face's key") == true)
    #expect(EffectNodes.describe([face]) == nil, "a plain chain has no node graph")
}

@Test func serialStacksRenderAsBefore() {
    let img = swatches([srgb(0.8, 0.3, 0.2), srgb(0.2, 0.5, 0.7)])
    let ctx = EffectRenderer.Context(unit: 20, time: 0, opaque: true)
    let stack = [cdl("a", slope: 1.2), Effect(id: "b", type: "color.adjust", params: ["saturation": .number(0.4)], ), cdl("c", offset: -0.05)]
    var labelled = stack
    for i in labelled.indices { labelled[i].params["node_mode"] = .string("serial") }
    let a = floats(EffectRenderer.apply(stack, to: img, context: ctx) { _, _ in nil }), b = floats(EffectRenderer.apply(labelled, to: img, context: ctx) { _, _ in nil })
    for x in [10, 30] { #expect(simd_distance(value(a, x, 10), value(b, x, 10)) < 1e-4) }
}

@Test func ellipseWindowIsSolidInside() {
    let e = CGRect(x: 0, y: 0, width: 400, height: 200)
    let mask = floats(EffectRenderer.maskImage("mask.ellipse", extent: e, unit: 200, n: { ["center_x": 0.5, "center_y": 0.5, "width": 0.6, "height": 0.8, "feather": 0][$0] ?? 0 }, invert: false))
    // The ellipse spans x 80…320 and y 20…180; 85% of the way to its edge is still fully inside.
    #expect(value(mask, 200, 100).x > 0.99)
    #expect(value(mask, 200 + 102, 100).x > 0.99, "\(value(mask, 302, 100).x)")
    #expect(value(mask, 200, 100 + 68).x > 0.99, "\(value(mask, 200, 168).x)")
    #expect(value(mask, 330, 100).x < 0.01)
}

// MARK: Real footage

private let film = "/tmp/cl-real/downloads/tears_of_steel_720p.mp4"

@Test(.enabled(if: FileManager.default.fileExists(atPath: film)))
func skinPresetQualifiesFacesOnRealFootage() async throws {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: film)))
    gen.maximumSize = CGSize(width: 640, height: 640)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let fx = Effect(id: "skin", type: "color.wheels", params: ["limit": .string("qualifier"), "q_preset": .string("skin")])
    let type = try #require(EffectCatalog.type(fx.type))
    var inside: [Float] = [], ring: [Float] = []
    var faces = 0
    for t in stride(from: 20.0, to: 720, by: 6) {
        guard let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
        // Vision waits on its own queues, so it runs off the cooperative pool.
        let boxes = try await runBlocking { _ -> [CGRect] in
            let req = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            return (req.results ?? []).filter { $0.confidence > 0.8 && $0.boundingBox.width > 0.06 }.map(\.boundingBox)
        }
        guard !boxes.isEmpty else { continue }
        faces += 1
        let img = CIImage(cgImage: cg)
        let ctx = EffectRenderer.Context(unit: img.extent.height, time: 0, opaque: true)
        let key = floats(EffectRenderer.limitMask(img, ctx, EffectRenderer.values(fx, type) { _, _ in nil }, fx)!)
        for y in stride(from: 0, to: key.h, by: 2) {
            for x in stride(from: 0, to: key.w, by: 2) {
                let p = CGPoint(x: Double(x) / Double(key.w), y: 1 - Double(y) / Double(key.h))
                let w = value(key, x, y).x
                // The middle of each face box, against the surroundings an ellipse window around the face would take in.
                if boxes.contains(where: { $0.insetBy(dx: $0.width * 0.2, dy: $0.height * 0.2).contains(p) }) { inside.append(w) }
                else if !boxes.contains(where: { $0.insetBy(dx: -$0.width * 0.3, dy: -$0.height * 0.5).contains(p) }),
                        boxes.contains(where: { $0.insetBy(dx: -$0.width, dy: -$0.height * 0.8).contains(p) }) { ring.append(w) }
            }
        }
    }
    try #require(faces >= 5, "found \(faces) frames with faces")
    let hit = Double(inside.filter { $0 > 0.5 }.count) / Double(inside.count)
    let spill = Double(ring.filter { $0 > 0.5 }.count) / Double(ring.count)
    print("skin preset over \(faces) face frames: \(Int(hit * 100))% of face pixels qualify, \(Int(spill * 100))% of their surroundings")
    #expect(hit > 0.65, "face pixels qualifying: \(hit)")
    #expect(spill < 0.2, "surrounding pixels qualifying: \(spill)")
}
