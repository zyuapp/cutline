import Foundation
import simd
import Testing
@testable import CutlineCore

private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tol: Float = 0.01) -> Bool { simd_distance(a, b) <= tol }

private func wheels(_ params: [String: Double]) -> ColorMath.Transform {
    let spec = EffectCatalog.type("color.wheels")!
    return ColorMath.wheels(ColorMath.Wheels { params[$0] ?? spec.spec($0)?.defaultValue.number ?? 0 })
}

@Test func wheelsAreNeutralByDefault() {
    let f = wheels([:])
    for c in [SIMD3<Float>(0, 0, 0), SIMD3(0.3, 0.5, 0.7), SIMD3(1, 1, 1)] { #expect(close(f(c), c, 1e-5)) }
    #expect(EffectCatalog.wheelSpecs.allSatisfy { $0.name == "pivot" || $0.defaultValue == .number(0) })
}

@Test func wheelsLiftGammaGainOffset() {
    let black = SIMD3<Float>(0, 0, 0), white = SIMD3<Float>(1, 1, 1), mid = SIMD3<Float>(repeating: 0.5)
    let lift = wheels(["lift": 0.1])
    #expect(close(lift(black), SIMD3(repeating: 0.1)))
    #expect(close(lift(white), white))
    let gain = wheels(["gain": -0.2])
    #expect(close(gain(black), black) && close(gain(white), SIMD3(repeating: 0.8)))
    #expect(wheels(["gamma": 0.5])(mid).x > 0.55)
    #expect(wheels(["gamma": -0.5])(mid).x < 0.45)
    #expect(close(wheels(["offset": 0.05])(mid), SIMD3(repeating: 0.55)))
    // Channel wheels add to the master: cool blacks, warm whites.
    let balance = wheels(["lift_b": 0.06, "gain_r": -0.1, "gain_b": -0.2])
    #expect(close(balance(black), SIMD3(0, 0, 0.048)), "lift scaled by the blue gain")
    let w = balance(white)
    #expect(w.x > w.z && close(w, SIMD3(0.9, 1, 0.8)))
}

@Test func wheelsContrastPivotSaturationAndBalance() {
    let contrast = wheels(["contrast": 0.5, "pivot": 0.4])
    #expect(close(contrast(SIMD3(repeating: 0.4)), SIMD3(repeating: 0.4)))
    #expect(contrast(SIMD3(repeating: 0.6)).x > 0.69)
    #expect(contrast(SIMD3(repeating: 0.2)).x < 0.11)
    let gray = wheels(["saturation": -1])(SIMD3(0.8, 0.4, 0.2))
    #expect(abs(gray.x - gray.y) < 1e-4 && abs(gray.y - gray.z) < 1e-4)
    let warm = wheels(["temperature": 50])(SIMD3(repeating: 0.5))
    #expect(warm.x > 0.53 && warm.z < 0.47)
    let magenta = wheels(["tint": 50])(SIMD3(repeating: 0.5))
    #expect(magenta.y < magenta.x && magenta.y < magenta.z)
}

@Test func wheelsShadowsAndHighlightsRecovery() {
    let open = wheels(["shadows": 1])
    #expect(open(SIMD3(repeating: 0.2)).x > 0.3)
    #expect(close(open(SIMD3(repeating: 0)), SIMD3(repeating: 0)))
    #expect(close(open(SIMD3(repeating: 1)), SIMD3(repeating: 1)))
    let recover = wheels(["highlights": -1])
    #expect(recover(SIMD3(repeating: 0.8)).x < 0.72)
    #expect(abs(recover(SIMD3(repeating: 0.1)).x - 0.1) < 0.02)
}

@Test func secondariesCanCombineWindowAndQualifier() {
    let limit = EffectCatalog.type("color.wheels")!.spec("limit")!
    guard case .choice(let values) = limit.kind else { Issue.record("limit is a choice"); return }
    #expect(values.contains("ellipse+qualifier") && values.contains("rect+qualifier"))
    #expect(EffectCatalog.type("color.adjust")!.spec("limit_x")!.summary.contains("face:"))
}

/// Letterboxed frame: `bars` rows of black at top and bottom around a textured picture.
private func letterboxed(width w: Int, height h: Int, bars: Int, color: @escaping (Int, Int) -> SIMD3<Float>) -> (Int, Int) -> SIMD3<Float> {
    { x, y in y < bars || y >= h - bars ? .zero : color(x, y) }
}

@Test func pictureAreaFindsLetterboxAndPillarbox() {
    let texture: (Int, Int) -> SIMD3<Float> = { x, y in SIMD3(Float((x * 7 + y * 3) % 50) / 100 + 0.2, 0.4, 0.3) }
    let lb = PictureArea.active(width: 200, height: 120, pixel: letterboxed(width: 200, height: 120, bars: 15, color: texture))
    #expect(lb == PictureArea.Rect(x: 0, y: 15, width: 200, height: 90))
    let pb = PictureArea.active(width: 200, height: 120) { x, y in x < 30 || x >= 170 ? SIMD3(0.01, 0.01, 0.01) : texture(x, y) }
    #expect(pb == PictureArea.Rect(x: 30, y: 0, width: 140, height: 120))
    // A dark band on one side only is picture, unless it is the canvas background.
    let oneSide: (Int, Int) -> SIMD3<Float> = { x, y in y < 20 ? .zero : texture(x, y) }
    #expect(PictureArea.active(width: 200, height: 120, pixel: oneSide).height == 120)
    let bg = SIMD3<Float>(0.5, 0.2, 0.6)
    let shifted = PictureArea.active(width: 200, height: 120, background: bg) { x, y in y < 20 ? bg : texture(x, y) }
    #expect(shifted == PictureArea.Rect(x: 0, y: 20, width: 200, height: 100))
    // Flat frames are measured whole.
    #expect(PictureArea.active(width: 200, height: 120) { _, _ in .zero }.height == 120)
}

/// Pixels with a given lightness spread and saturation around a hue, as sRGB.
private func shot(level: Float, spread: Float, saturation: Float, cast: SIMD3<Float> = .zero, count: Int = 900) -> [SIMD3<Float>] {
    (0..<count).map { i in
        let t = Float(i % 30) / 29 - 0.5, hue = Float(i / 30) / 30 * 2 * .pi
        let v = level + t * spread
        let c = SIMD3(cos(hue), cos(hue - 2.1), cos(hue + 2.1)) * saturation * v
        return simd_clamp(SIMD3(repeating: v) + c + cast, .zero, SIMD3(repeating: 1))
    }
}

private func meanSaturation(_ px: [SIMD3<Float>]) -> Float {
    px.map { $0.max() > 0 ? ($0.max() - $0.min()) / $0.max() : 0 }.reduce(0, +) / Float(px.count)
}

@Test func colorMatchLandsNearTheReferenceWithoutOversaturating() {
    let reference = shot(level: 0.5, spread: 0.5, saturation: 0.18)
    let dull = shot(level: 0.4, spread: 0.4, saturation: 0.15, cast: SIMD3(0.02, 0.02, -0.03))
    let f = ColorMatch.transform(from: ColorMatch.stats(dull), to: ColorMatch.stats(reference))
    let matched = dull.map(f)
    let target = meanSaturation(reference)
    #expect(abs(meanSaturation(matched) - target) < 0.06, "matched \(meanSaturation(matched)) vs reference \(target), source \(meanSaturation(dull))")
    let m = ColorMatch.stats(matched), r = ColorMatch.stats(reference)
    #expect(abs(m.mean.x - r.mean.x) < 3, "L \(m.mean.x) vs \(r.mean.x)")
    #expect(abs(m.mean.y - r.mean.y) < 2 && abs(m.mean.z - r.mean.z) < 2)

    // A nearly gray shot is not pushed to the reference's full colorfulness.
    let gray = shot(level: 0.5, spread: 0.5, saturation: 0.03)
    let g = ColorMatch.stats(gray.map(ColorMatch.transform(from: ColorMatch.stats(gray), to: ColorMatch.stats(reference))))
    #expect(g.chroma <= ColorMatch.stats(gray).chroma * 1.3)

    // Black bars and pure white stay neutral.
    #expect(simd_length(f(.zero)) < 0.01)
    #expect(simd_distance(f(SIMD3(repeating: 1)), SIMD3(repeating: 1)) < 0.02)
}

@Test func colorMatchStatsShrugOffOutliers() {
    var px = shot(level: 0.5, spread: 0.3, saturation: 0.1)
    let clean = ColorMatch.stats(px)
    px += Array(repeating: SIMD3<Float>(1, 0, 1), count: 40)
    let noisy = ColorMatch.stats(px)
    #expect(abs(noisy.mean.y - clean.mean.y) < 1.5 && abs(noisy.chroma - clean.chroma) < 2, "\(clean) vs \(noisy)")
}
