import Foundation
import Testing
@testable import CutlineCore

/// An sRGB color from HSV.
private func hsv(_ h: Double, _ s: Double, _ v: Double) -> SIMD3<Float> {
    let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
    let (r, g, b): (Double, Double, Double) = switch h {
    case 0..<60: (c, x, 0)
    case 60..<120: (x, c, 0)
    case 120..<180: (0, c, x)
    case 180..<240: (0, x, c)
    case 240..<300: (x, 0, c)
    default: (c, 0, x)
    }
    return SIMD3(Float(r + m), Float(g + m), Float(b + m))
}

@Test func qualifierRangesHaveSoftEdges() {
    let q = Qualifier(hue: 120, hueWidth: 40, hueSoft: 20, satLow: 0.3, satHigh: 0.8, satSoft: 0.1, lumaLow: 0, lumaHigh: 1, lumaSoft: 0)
    #expect(q.weight(hsv(120, 0.6, 0.8)) == 1)
    #expect(q.weight(hsv(139, 0.6, 0.8)) == 1, "inside ±20°")
    #expect(abs(q.weight(hsv(150, 0.6, 0.8)) - 0.5) < 0.02, "halfway through the 20° softness")
    #expect(q.weight(hsv(165, 0.6, 0.8)) == 0)
    #expect(abs(q.weight(hsv(120, 0.25, 0.8)) - 0.5) < 0.02, "saturation softness")
    #expect(q.weight(hsv(120, 0.95, 0.8)) == 0)
    #expect(q.weight(SIMD3(0.5, 0.5, 0.5)) == 0, "neutral gray has no hue")

    // Hue wraps around red.
    let red = Qualifier(hue: 355, hueWidth: 20, hueSoft: 5, satLow: 0.1)
    #expect(red.weight(hsv(3, 0.6, 0.8)) == 1)
    #expect(red.weight(hsv(30, 0.6, 0.8)) == 0)

    // Luma is Rec. 709 luma: a dark and a bright orange of the same hue and saturation.
    let mid = Qualifier(hue: 30, hueWidth: 30, satLow: 0.2, lumaLow: 0.3, lumaHigh: 0.7, lumaSoft: 0.05)
    #expect(mid.weight(hsv(30, 0.5, 0.2)) == 0)
    #expect(mid.weight(hsv(30, 0.5, 0.7)) == 1)

    // Near-black noise doesn't read as saturated.
    #expect(Qualifier.components(SIMD3(0.04, 0.02, 0.02)).sat < 0.2)
}

@Test func qualifierReadsPresetsLegacySoftnessAndOverrides() {
    #expect(Qualifier(params: [:]) == Qualifier())
    let skin = Qualifier(params: ["q_preset": .string("skin"), "q_luma_min": .number(0.05)])
    #expect(skin.hue == Qualifier.skin.hue && skin.satHigh == Qualifier.skin.satHigh)
    #expect(skin.lumaLow == 0.05, "explicit parameters refine the preset")
    let legacy = Qualifier(params: ["q_softness": .number(0.2), "q_sat_soft": .number(0.01)])
    #expect(legacy.hueSoft == 18 && legacy.lumaSoft == 0.2 && legacy.satSoft == 0.01)
    #expect(Qualifier(params: Qualifier.skin.params) == Qualifier.skin)
    // Every q_* parameter is in the catalog with the qualifier's default.
    let wheels = EffectCatalog.type("color.wheels")!
    for (name, path) in Qualifier.names {
        #expect(wheels.spec(name)?.defaultValue == .number(Qualifier()[keyPath: path]), "\(name)")
    }
    #expect(Qualifier().clean(0.05) == 0.05)
    var c = Qualifier()
    c.cleanBlack = 0.2
    c.cleanWhite = 0.2
    #expect(c.clean(0.15) == 0 && c.clean(0.85) == 1 && abs(c.clean(0.5) - 0.5) < 1e-9)
}

@Test func qualifierPickCoversTheSampledColors() throws {
    var samples: [SIMD3<Float>] = []
    for i in 0..<200 {
        let t = Double(i % 20) / 19
        samples.append(hsv(20 + t * 10, 0.3 + t * 0.15, 0.55 + t * 0.2))
    }
    let q = try #require(Qualifier.pick(samples))
    #expect(abs(q.hue - 25) < 3, "\(q.summary)")
    let covered = samples.filter { q.weight($0) > 0.9 }.count
    #expect(covered >= 180, "covers \(covered) of 200: \(q.summary)")
    #expect(q.weight(hsv(200, 0.5, 0.6)) == 0)
    #expect(q.weight(hsv(25, 0.9, 0.6)) == 0, "much more saturated colors stay out")
    #expect(Qualifier.pick((0..<50).map { _ in SIMD3<Float>(0.5, 0.5, 0.5) }) == nil, "gray has no hue to pick")
}

@Test func nodesGroupByLabelAndReadModes() {
    func fx(_ id: String, _ params: [String: ParamValue] = [:], type: String = "color.wheels") -> Effect { Effect(id: id, type: type, params: params) }
    let stack = [
        fx("match", type: "color.lut"),
        fx("skin", ["node": .string("face"), "node_mode": .string("parallel"), "limit": .string("ellipse+qualifier")]),
        fx("skin2", ["node": .string("face")], type: "color.hsl"),
        fx("sky", ["node_mode": .string("parallel")], type: "color.hsl"),
        fx("bg", ["node_mode": .string("outside")]),
        fx("glow", ["node_mode": .string("layer"), "node_blend": .string("screen"), "node_opacity": .number(0.4)], type: "stylize.glow"),
        fx("m", type: "mask.rect"),
    ]
    let nodes = EffectNodes.nodes(stack)
    #expect(nodes.map(\.label) == ["match", "face", "sky", "bg", "glow", "m"])
    #expect(nodes.map(\.mode) == [.serial, .parallel, .parallel, .outside, .layer, .serial])
    #expect(nodes[1].effects == [1, 2] && nodes[1].key == 1)
    #expect(nodes[4].blend == .screen && nodes[4].opacityFrom == 5)
    #expect(!EffectNodes.takesNodes("mask.rect") && !EffectNodes.takesNodes("stylize.drop_shadow") && EffectNodes.takesNodes("color.cdl"))
    let text = try! #require(EffectNodes.describe(stack))
    #expect(text.contains("parallel mixer") && text.contains("face: skin color.wheels [key: ellipse+qualifier], skin2 color.hsl"))
    #expect(text.contains("sky has no key"), "the outside node after an unkeyed node says it does nothing")
    #expect(text.contains("glow (screen at 40%, inside the whole picture)"))
    #expect(EffectNodes.isChain([fx("a"), fx("b", ["node_mode": .string("serial")])]))
}

@Test func deltaE2000MatchesPublishedPairs() {
    // Sharma, Wu and Dalal's test data.
    #expect(abs(ColorMatch.deltaE2000(SIMD3(50, 2.6772, -79.7751), SIMD3(50, 0, -82.7485)) - 2.0425) < 1e-3)
    #expect(abs(ColorMatch.deltaE2000(SIMD3(50, 2.5, 0), SIMD3(73, 25, -18)) - 27.1492) < 1e-3)
    #expect(abs(ColorMatch.deltaE2000(SIMD3(2.0776, 0.0795, -1.135), SIMD3(0.9033, -0.0636, -0.5514)) - 0.9082) < 1e-3)
    #expect(ColorMatch.deltaE2000(SIMD3(40, 10, 10), SIMD3(40, 10, 10)) == 0)
}

@Test func matchingADarkShotToABrightOneIsCappedAndFlagged() {
    // A dark, nearly colorless CGI shot and a bright, warm live-action one.
    let dark = (0..<600).map { i in SIMD3<Float>(repeating: 0.12 + Float(i % 30) / 150) }
    let bright = (0..<600).map { i -> SIMD3<Float> in
        let t = Float(i % 30) / 30
        return SIMD3(0.62 + t * 0.35, 0.55 + t * 0.35, 0.45 + t * 0.3)
    }
    let d = ColorMatch.stats(dark), b = ColorMatch.stats(bright)
    let cmp = ColorMatch.compare(d, to: b)
    #expect(cmp.lightnessGap > 35)
    #expect(cmp.warnings.contains { $0.contains("median lightness differs") }, "\(cmp.warnings)")
    #expect(cmp.warnings.contains { $0.contains("distributed very differently") }, "\(cmp.warnings)")
    #expect(ColorMatch.compare(b, to: b).warnings.isEmpty)
    #expect(ColorMatch.compare(b, to: b, contentDistance: 1.1).warnings.count == 1)

    let capped = ColorMatch.stats(dark.map(ColorMatch.transform(from: d, to: b, strength: 1)))
    #expect(capped.mean.x - d.mean.x <= ColorMatch.maxLightnessShift + 1.5, "moved \(capped.mean.x - d.mean.x) L")
    #expect(abs(ColorMatch.matchedLightness(from: d, to: b, strength: 1) - capped.mean.x) < 2)
    let free = ColorMatch.stats(dark.map(ColorMatch.transform(from: d, to: b, strength: 1, maxLightnessShift: nil)))
    #expect(free.mean.x > capped.mean.x + 2, "allow_large moves further: \(free.mean.x) vs \(capped.mean.x)")
}
