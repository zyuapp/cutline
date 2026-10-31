import Foundation
import Testing
@testable import CutlineCore

@Test func soloPictureKeepsOneClipAndItsEffectsBeforeACut() throws {
    var p = Project(name: "Solo")
    var a = Clip(id: "a", kind: .solid, start: 0, duration: 4, color: .white)
    a.effects = [Effect(id: "match", type: "color.lut"), Effect(id: "warm", type: "color.wheels")]
    a.transform.opacity = 0.4
    a.blend = .screen
    a.fadeIn = 1
    p.tracks[0].clips = [a, Clip(id: "b", kind: .solid, start: 4, duration: 2, color: .black)]
    p.tracks[0].effects = [Effect(id: "trackfx", type: "color.wheels")]
    p.tracks.append(Track(id: "V2", kind: .video, name: "Over", clips: [Clip(id: "adj", kind: .adjustment, start: 0, duration: 6)]))
    p.captions.enabled = true

    let all = try #require(p.soloPicture("a"))
    #expect(all.tracks.flatMap(\.clips).map(\.id) == ["a"] && all.tracks.allSatisfy(\.effects.isEmpty) && !all.captions.enabled)
    let c = try #require(all.clip("a"))
    #expect(c.effects.map(\.id) == ["match", "warm"] && c.transform.opacity == 1 && c.blend == .normal && c.fadeIn == 0)
    #expect(try #require(p.soloPicture("a", effectsBefore: 0)).clip("a")?.effects.isEmpty == true)
    #expect(try #require(p.soloPicture("a", effectsBefore: 1)).clip("a")?.effects.map(\.id) == ["match"])
    #expect(p.soloPicture("nope") == nil)
}

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

@Test func qualifierPickIgnoresSpecksInThePatch() throws {
    // Skin with noise, plus a quarter of the patch in hair, a highlight and background.
    var samples: [SIMD3<Float>] = []
    for i in 0..<300 {
        let t = Double(i % 30) / 29
        samples.append(hsv(18 + t * 8, 0.35 + t * 0.1, 0.6 + t * 0.15))
    }
    for i in 0..<100 {
        switch i % 4 {
        case 0: samples.append(hsv(30, 0.5, 0.08))
        case 1: samples.append(SIMD3(0.98, 0.97, 0.95))
        case 2: samples.append(hsv(210, 0.6, 0.5))
        default: samples.append(hsv(120, 0.5, 0.4))
        }
    }
    #expect(Qualifier.inliers(samples).count <= 310)
    let q = try #require(Qualifier.pick(samples))
    #expect(abs(q.hue - 22) < 4 && q.hueWidth < 40, "\(q.summary)")
    #expect(q.weight(hsv(210, 0.6, 0.5)) == 0 && q.weight(hsv(120, 0.5, 0.4)) == 0 && q.weight(hsv(30, 0.5, 0.08)) == 0, "\(q.summary)")
    #expect(samples.prefix(300).filter { q.weight($0) > 0.9 }.count >= 270, "\(q.summary)")
    #expect(q.denoise >= 0.005 && q.blur >= 0.004 && q.cleanBlack >= 0.15, "sampled keys clean their matte")
    #expect(Qualifier.inliers(Array(samples.prefix(5))).count == 5)
}

@Test func switchingTimelinesSummarizesAsASwitch() throws {
    var p = Project(name: "Show")
    p.tracks[0].clips = (0..<20).map { Clip(id: "c\($0)", kind: .solid, start: Double($0), duration: 1, color: .white) }
    let main = p
    try p.newTimeline("Trailer", duplicate: false)
    let made = p.changes(from: main)
    #expect(made == ["new timeline Trailer, now current (Main kept)"], "\(made)")
    let trailer = p
    try p.switchTimeline(to: "Main")
    #expect(p.changes(from: trailer) == ["switched to timeline Main (from Trailer)"])
    var withMedia = p
    withMedia.media.append(MediaAsset(id: "m", path: "/tmp/m.mov", name: "m", duration: 1, width: 16, height: 9, fps: 25, hasVideo: true, hasAudio: false))
    let lines = withMedia.changes(from: trailer)
    #expect(lines.first == "switched to timeline Main (from Trailer)" && lines.contains("+ media m") && lines.count == 2, "\(lines)")
    var renamed = p
    try renamed.renameTimeline("Main", to: "Master")
    #expect(!renamed.changes(from: p).contains { $0.hasPrefix("switched") })
}
