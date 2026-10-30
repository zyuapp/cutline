import Foundation
import Testing
@testable import CutlineCore

private func power(_ g: [Double]) -> Double { g.reduce(0) { $0 + $1 * $1 } }

@Test func surroundPannerKeepsConstantPower() {
    for layout in [AudioLayout.surround51, .surround71] {
        for x in stride(from: -1.0, through: 1.0, by: 0.25) {
            for y in stride(from: -1.0, through: 1.0, by: 0.25) {
                for c in [0.0, 0.5, 1.0] {
                    let g = SurroundPanner.gains(x: x, y: y, center: c, layout: layout)
                    #expect(g.count == layout.channelCount)
                    #expect(abs(power(g) - 1) < 1e-9, "\(layout) (\(x), \(y)) c=\(c): \(power(g))")
                    #expect(g[3] == 0)
                    #expect(g.allSatisfy { $0 >= 0 })
                }
            }
        }
    }
}

@Test func surroundPannerPlacesCornersOnSpeakers() {
    func only(_ g: [Double], _ ch: Int) -> Bool { g.enumerated().allSatisfy { i, v in i == ch ? abs(v - 1) < 1e-9 : abs(v) < 1e-9 } }
    for layout in [AudioLayout.surround51, .surround71] {
        #expect(only(SurroundPanner.gains(x: -1, y: 1, layout: layout), 0), "hard left front is L")
        #expect(only(SurroundPanner.gains(x: 1, y: 1, layout: layout), 1), "hard right front is R")
        #expect(only(SurroundPanner.gains(x: 0, y: 1, layout: layout), 2), "front center is C")
    }
    #expect(only(SurroundPanner.gains(x: -1, y: -1, layout: .surround51), 4), "rear left is Ls in 5.1")
    #expect(only(SurroundPanner.gains(x: 1, y: -1, layout: .surround51), 5))
    #expect(only(SurroundPanner.gains(x: -1, y: -1, layout: .surround71), 6), "rear left is Lrs in 7.1")
    #expect(only(SurroundPanner.gains(x: 1, y: -1, layout: .surround71), 7))

    // Partway down the left side sits between L and Ls.
    let side = SurroundPanner.gains(x: -1, y: 0, layout: .surround51)
    #expect(side[0] > 0.3 && side[4] > 0.3 && side[1] == 0 && side[2] == 0 && side[5] == 0)
    // The middle of the room feeds every main speaker equally.
    let middle = SurroundPanner.gains(x: 0, y: 0, layout: .surround51)
    #expect(middle.enumerated().allSatisfy { i, v in i == 3 ? v == 0 : abs(v - 0.2.squareRoot()) < 1e-9 })
}

@Test func surroundCenterShareSpreadsToPhantomCenter() {
    let half = SurroundPanner.gains(x: 0, y: 1, center: 0.5, layout: .surround51)
    #expect(abs(half[2] * half[2] - 0.5) < 1e-9)
    #expect(abs(half[0] - half[1]) < 1e-12 && abs(half[0] * half[0] - 0.25) < 1e-9)
    let phantom = SurroundPanner.gains(x: 0, y: 1, center: 0, layout: .surround51)
    #expect(phantom[2] == 0 && abs(phantom[0] - 0.5.squareRoot()) < 1e-9 && abs(phantom[1] - 0.5.squareRoot()) < 1e-9)
}

@Test func stereoSourcesKeepTheirWidth() {
    let p = SurroundPanner.pairGains(x: 0, y: 1, layout: .surround51)
    #expect(abs(p.left[0] - 1) < 1e-9 && abs(p.right[1] - 1) < 1e-9)
    let back = SurroundPanner.pairGains(x: 0, y: -1, layout: .surround51)
    #expect(abs(back.left[4] - 1) < 1e-9 && abs(back.right[5] - 1) < 1e-9)
}

@Test func downmixMatricesFollowBS775() {
    let h = 0.5.squareRoot()
    let m = AudioLayout.surround51.downmixMatrix(to: .stereo)
    #expect(m == [[1, 0, h, 0, h, 0], [0, 1, h, 0, 0, h]])
    let m7 = AudioLayout.surround71.downmixMatrix(to: .stereo)
    #expect(m7[0] == [1, 0, h, 0, h, 0, h, 0])
    #expect(AudioLayout.surround71.downmixMatrix(to: .surround51)[4] == [0, 0, 0, 0, 1, 0, h, 0])
    #expect(AudioLayout.stereo.downmixMatrix(to: .mono) == [[0.5, 0.5]])
    #expect(AudioLayout.mono.downmixMatrix(to: .stereo) == [[1], [1]])
    #expect(AudioLayout.surround51.loudnessWeights == [1, 1, 1, 0, 1.41, 1.41])
    #expect(AudioLayout.surround71.loudnessWeights == [1, 1, 1, 0, 1.41, 1.41, 1, 1])
    #expect(AudioLayout(name: "5.1") == .surround51 && AudioLayout(name: "surround71") == .surround71)
}

@Test func surroundParamsAreClipParameters() throws {
    var c = Clip(id: "c", kind: .media, mediaId: "m", start: 0, duration: 4)
    #expect(try c.spec("audio.pan_x").defaultValue == .number(0))
    #expect(c.staticValue("audio.pan_y") == .number(1))
    try c.set("audio.pan_x", .number(-1))
    try c.set("audio.lfe", .number(0.5))
    #expect(c.surround == SurroundPan(x: -1, lfe: 0.5))
    #expect(throws: (any Error).self) { try c.set("audio.pan_y", .number(2)) }
    try c.animate("audio.pan_y", keys: [CurveKey(t: 0, v: .number(1), ease: .linear), CurveKey(t: 4, v: .number(-1), ease: .linear)])
    #expect(abs(c.number("audio.pan_y", at: 2) - 0) < 1e-9)

    let data = try JSONEncoder().encode(c)
    #expect(try JSONDecoder().decode(Clip.self, from: data) == c)
    try c.set("audio.pan_x", .number(0))
    try c.set("audio.lfe", .number(0))
    #expect(c.surround == nil)
    #expect(!String(decoding: try JSONEncoder().encode(c), as: UTF8.self).contains("surround"))

    let seq = Clip(id: "s", kind: .sequence, mediaId: "seq", start: 0, duration: 4)
    #expect(seq.fixedSpecs.contains { $0.name == "audio.center" })
}

@Test func masterLayoutDecodesAndEncodesCompactly() throws {
    let old = try JSONDecoder().decode(MasterAudio.self, from: Data(#"{"gainDb": -3, "effects": []}"#.utf8))
    #expect(old.layout == .stereo && old.gainDb == -3)
    #expect(!String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("layout"))
    var p = Project(name: "Mix")
    p.master.layout = .surround51
    let back = try JSONDecoder().decode(Project.self, from: try JSONEncoder().encode(p))
    #expect(back.master.layout == .surround51)
    #expect(back.changes(from: Project(name: "Mix")).contains { $0.contains("master layout stereo→5.1") })
}
