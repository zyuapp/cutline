import Foundation
import Testing
@testable import CutlineCore

private let samples: [SIMD3<Float>] = {
    let steps: [Float] = [0, 0.1, 0.25, 0.5, 0.73, 0.9, 1]
    return steps.flatMap { r in steps.flatMap { g in steps.map { b in SIMD3(r, g, b) } } }
}()

private func isIdentity(_ f: ColorMath.Transform, tolerance: Float = 1e-4) -> Bool {
    samples.allSatisfy { c in
        let d = f(c) - c
        return max(abs(d.x), abs(d.y), abs(d.z)) <= tolerance
    }
}

private func gray(_ v: Float) -> SIMD3<Float> { SIMD3(repeating: v) }

@Test func neutralTransformsAreIdentity() throws {
    #expect(isIdentity(ColorMath.grade(lift: 0, gamma: 1, gain: 1,
                                       shadowsTint: nil, shadowsAmount: 0,
                                       midtonesTint: RGBA(hex: "#FF0000"), midtonesAmount: 0,
                                       highlightsTint: nil, highlightsAmount: 1)))
    #expect(isIdentity(try ColorMath.curves(master: nil, red: "", green: nil, blue: nil)))
    #expect(isIdentity(try ColorMath.curves(master: "0,0 1,1", red: "0,0 0.5,0.5 1,1", green: nil, blue: nil)))
    #expect(isIdentity(try ColorMath.hsl(range: "blues", hue: 0, saturation: 0, lightness: 0)))
    for name in ColorMath.looks {
        #expect(isIdentity(try ColorMath.look(name, amount: 0)))
    }
}

@Test func gradeDirections() {
    func g(lift: Float = 0, gamma: Float = 1, gain: Float = 1) -> ColorMath.Transform {
        ColorMath.grade(lift: lift, gamma: gamma, gain: gain, shadowsTint: nil, shadowsAmount: 0,
                        midtonesTint: nil, midtonesAmount: 0, highlightsTint: nil, highlightsAmount: 0)
    }
    #expect(g(lift: 0.1)(gray(0)).x > 0.05)
    #expect(abs(g(lift: 0.1)(gray(1)).x - 1) < 1e-5)
    #expect(g(gain: 0.8)(gray(1)).x < 0.85)
    #expect(g(gain: 0.8)(gray(0)).x == 0)
    #expect(g(gamma: 1.5)(gray(0.5)).x > 0.55)
    #expect(g(gamma: 0.7)(gray(0.5)).x < 0.45)
    #expect(g(gain: 4)(gray(0.9)).x == 1)
}

@Test func splitToningTintsTheRightRangeAndKeepsLuma() {
    let warmHighlights = ColorMath.grade(lift: 0, gamma: 1, gain: 1, shadowsTint: nil, shadowsAmount: 0,
                                         midtonesTint: nil, midtonesAmount: 0,
                                         highlightsTint: RGBA(hex: "#FF8040"), highlightsAmount: 0.5)
    let bright = warmHighlights(gray(0.8)), dark = warmHighlights(gray(0.1))
    #expect(bright.x - bright.z > 0.1)
    #expect(dark.x - dark.z < 0.02)
    #expect(abs(ColorMath.luma(bright) - 0.8) < 0.01)
}

@Test func tealOrangeWarmsSkinAndCoolsShadows() throws {
    let f = try ColorMath.look("teal_orange", amount: 1)
    let skin = SIMD3<Float>(0.85, 0.6, 0.45)
    let s = f(skin)
    #expect(s.x - s.z > skin.x - skin.z)
    let shadow = f(gray(0.15))
    #expect(shadow.y > shadow.x && shadow.z > shadow.x)
}

@Test func looksAreDistinctAndBlend() throws {
    let probe: [SIMD3<Float>] = [gray(0.2), gray(0.5), SIMD3(0.85, 0.6, 0.45), SIMD3(0.2, 0.4, 0.8)]
    let outs = try ColorMath.looks.map { name in try probe.map(ColorMath.look(name, amount: 1)) }
    for i in outs.indices {
        for j in outs.indices where j > i {
            let diff = zip(outs[i], outs[j]).map { ($0 - $1).max() - ($0 - $1).min() + abs(($0 - $1).sum()) }.max()!
            #expect(diff > 0.01, "\(ColorMath.looks[i]) vs \(ColorMath.looks[j])")
        }
    }
    let bw = try ColorMath.look("high_contrast_bw", amount: 1)(SIMD3(0.8, 0.2, 0.1))
    #expect(bw.x == bw.y && bw.y == bw.z)
    let half = try ColorMath.look("noir", amount: 0.5)(SIMD3(0.8, 0.2, 0.1))
    let full = try ColorMath.look("noir", amount: 1)(SIMD3(0.8, 0.2, 0.1))
    #expect(abs(half.x - (0.8 + full.x) / 2) < 1e-4)
    #expect(throws: EditError.self) { try ColorMath.look("sepia_dream", amount: 1) }
}

@Test func curvesAreMonotoneAndHitTheirPoints() throws {
    let f = try ColorMath.curves(master: "1,1 0,0 0.25,0.18 0.75,0.82", red: nil, green: nil, blue: nil)
    #expect(abs(f(gray(0.25)).x - 0.18) < 1e-5)
    #expect(abs(f(gray(0.75)).x - 0.82) < 1e-5)
    let steep = try ColorMath.curves(master: "0,0 0.1,0.6 0.2,0.62 1,1", red: nil, green: nil, blue: nil)
    for curve in [f, steep] {
        var last: Float = -1
        for i in 0...200 {
            let y = curve(gray(Float(i) / 200)).x
            #expect(y >= last - 1e-6)
            last = y
        }
    }
    let clampedEnds = try ColorMath.curves(master: "0.2,0.1 0.8,0.9", red: nil, green: nil, blue: nil)
    #expect(abs(clampedEnds(gray(0)).x - 0.1) < 1e-6 && abs(clampedEnds(gray(1)).x - 0.9) < 1e-6)
}

@Test func channelCurvesApplyAfterMaster() throws {
    let f = try ColorMath.curves(master: "0,0.2 1,1", red: "0,0 1,0.5", green: nil, blue: nil)
    let v = f(gray(0))
    #expect(abs(v.x - 0.1) < 1e-5 && abs(v.y - 0.2) < 1e-5 && abs(v.z - 0.2) < 1e-5)
}

@Test func badCurvesThrow() {
    for bad in ["0,0", "0,0 1", "0,0 1,1.5", "0,0 x,1", "0,0 0.5;0.5 1,1", "0,0 0.5,0.2 0.5,0.8 1,1"] {
        #expect(throws: EditError.self) { try ColorMath.curves(master: bad, red: nil, green: nil, blue: nil) }
    }
}

@Test func hslShiftsOnlyItsRange() throws {
    let f = try ColorMath.hsl(range: "blues", hue: 60, saturation: 0, lightness: 0)
    let blue = SIMD3<Float>(0.1, 0.2, 0.9), red = SIMD3<Float>(0.9, 0.1, 0.1)
    let shifted = f(blue)
    #expect(ColorMath.rgbToHSL(shifted).0 > ColorMath.rgbToHSL(blue).0 + 40)
    #expect(f(red) == red)
    #expect(f(gray(0.5)) == gray(0.5))

    let desat = try ColorMath.hsl(range: "reds", hue: 0, saturation: -1, lightness: 0)(red)
    #expect(desat.max() - desat.min() < 1e-4)
    let darker = try ColorMath.hsl(range: "reds", hue: 0, saturation: 0, lightness: -0.5)(red)
    #expect(ColorMath.luma(darker) < ColorMath.luma(red))

    let mutedBlue = SIMD3<Float>(0.45, 0.47, 0.55)
    let strong = ColorMath.rgbToHSL(f(blue)).0 - ColorMath.rgbToHSL(blue).0
    let weak = ColorMath.rgbToHSL(f(mutedBlue)).0 - ColorMath.rgbToHSL(mutedBlue).0
    #expect(weak < strong)
    #expect(throws: EditError.self) { try ColorMath.hsl(range: "browns", hue: 10, saturation: 0, lightness: 0) }
}

@Test func hslRoundTrips() {
    for c in samples {
        let (h, s, l) = ColorMath.rgbToHSL(c)
        let back = ColorMath.hslToRGB(h, s, l)
        #expect(abs((back - c).max()) < 1e-5 && abs((back - c).min()) < 1e-5)
    }
}

@Test func parsesSmallCube() throws {
    let text = """
    # Generated by test
    TITLE "Swap"
    LUT_3D_SIZE 2
    DOMAIN_MIN 0 0 0
    DOMAIN_MAX 1 1 1

    0 0 0
    0 0 1
    0 1 0
    0 1 1
    1 0 0
    1 0 1   # trailing comment
    1 1 0
    1 1 1
    """
    let cube = try ColorMath.parseCube(text)
    #expect(cube.size == 2)
    #expect(cube.rgba.count == 32)
    #expect(Array(cube.rgba[4..<8]) == [0, 0, 1, 1])
    #expect(Array(cube.rgba[28..<32]) == [1, 1, 1, 1])
    #expect(cube.domainMin == SIMD3(0, 0, 0) && cube.domainMax == SIMD3(1, 1, 1))

    let ranged = try ColorMath.parseCube("LUT_3D_SIZE 2\r\nLUT_3D_INPUT_RANGE 0 2\r\n" + String(repeating: "0.5 0.5 0.5\r\n", count: 8))
    #expect(ranged.domainMax == SIMD3(2, 2, 2))
}

@Test func badCubesThrow() {
    let row = "0 0 0\n"
    let cases = [
        "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n",
        "LUT_3D_SIZE 2\n" + String(repeating: row, count: 7),
        "LUT_3D_SIZE 2\n" + String(repeating: row, count: 9),
        "LUT_3D_SIZE 66\n" + row,
        String(repeating: row, count: 8),
        "LUT_3D_SIZE 2\n0 0\n" + String(repeating: row, count: 7),
    ]
    for text in cases {
        #expect(throws: EditError.self) { try ColorMath.parseCube(text) }
    }
}

@Test func cubeDataLayoutAndIdentityCorners() {
    let n = 5
    let data = ColorMath.cubeData(size: n) { $0 }
    #expect(data.count == n * n * n * 4)
    func entry(_ r: Int, _ g: Int, _ b: Int) -> [Float] {
        let i = ((b * n + g) * n + r) * 4
        return Array(data[i..<i + 4])
    }
    #expect(entry(0, 0, 0) == [0, 0, 0, 1])
    #expect(entry(n - 1, 0, 0) == [1, 0, 0, 1])
    #expect(entry(0, n - 1, 0) == [0, 1, 0, 1])
    #expect(entry(0, 0, n - 1) == [0, 0, 1, 1])
    #expect(entry(n - 1, n - 1, n - 1) == [1, 1, 1, 1])
    #expect(entry(2, 1, 0) == [0.5, 0.25, 0, 1])
    #expect(ColorMath.cubeData { $0 }.count == 33 * 33 * 33 * 4)
}
