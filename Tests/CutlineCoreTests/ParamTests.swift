import Foundation
import Testing
@testable import CutlineCore

private func project() -> Project {
    var p = Project(name: "T")
    p.media = [MediaAsset(id: "talk", path: "/tmp/t.mov", name: "Talk", duration: 20, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)]
    return p
}

@Test func formatOneKeyframesMigrateToCurves() throws {
    let json = """
    {"id":"c1","kind":"media","mediaId":"talk","start":0,"duration":4,"sourceIn":0,"speed":1,"volume":1,
     "audioFadeIn":0,"audioFadeOut":0,"fadeIn":0,"fadeOut":0,
     "transform":{"fit":"fit","scale":1,"x":0,"y":0,"rotation":0,"opacity":1,"crop":{"left":0,"top":0,"right":0,"bottom":0}},
     "keyframes":[{"time":0,"scale":1,"easing":"linear"},{"time":4,"scale":1.2,"x":0.1,"easing":"easeOut"}]}
    """
    let c = try JSONDecoder().decode(Clip.self, from: Data(json.utf8))
    #expect(c.anim["transform.scale"]?.keys.count == 2)
    #expect(c.anim["transform.x"]?.keys.count == 1)
    #expect(c.effects.isEmpty && c.blend == .normal)
    let round = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
    #expect(round == c)
}

@Test func pathsSetValidateAndAlias() throws {
    var c = Clip(id: "c", kind: .media, mediaId: "talk", start: 0, duration: 4)
    try c.set("opacity", .number(0.5))
    #expect(c.transform.opacity == 0.5)
    try c.set("blend", .string("screen"))
    #expect(c.blend == .screen)
    #expect(throws: EditError.self) { try c.set("transform.scale", .string("big")) }
    #expect(throws: EditError.self) { try c.set("transform.opacity", .number(2)) }
    #expect(throws: EditError.self) { try c.set("text.size", .number(0.1)) }
    #expect(throws: EditError.self) { try c.set("transfrom.scale", .number(1)) }
}

@Test func effectParamsDefaultSetAndAnimate() throws {
    var c = Clip(id: "c", kind: .media, mediaId: "talk", start: 0, duration: 4)
    c.effects.append(Effect(id: c.nextEffectId("blur.gaussian"), type: "blur.gaussian"))
    #expect(c.effects[0].id == "blur1")
    #expect(c.value("fx.blur1.radius", at: 0) == .number(0.01))
    try c.set("fx.blur1.radius", .number(0.05))
    #expect(c.effects[0].params["radius"] == .number(0.05))
    try c.animate("fx.blur1.radius", keys: [CurveKey(t: 0, v: .number(0), ease: .linear), CurveKey(t: 2, v: .number(0.1), ease: .linear)])
    #expect(abs((c.value("fx.blur1.radius", at: 1)?.number ?? 0) - 0.05) < 1e-9)
    #expect(throws: EditError.self) { try c.set("fx.blur1.size", .number(1)) }
    try c.removeEffect("blur1")
    #expect(c.anim.isEmpty && c.effects.isEmpty)
}

@Test func colorsInterpolate() {
    let curve = Curve(keys: [CurveKey(t: 0, v: .string("#000000"), ease: .linear), CurveKey(t: 1, v: .string("#FFFFFF"), ease: .linear)])
    #expect(curve.value(at: 0.5) == .string("#808080"))
}

@Test func trimsCarryAnimation() throws {
    var p = project()
    var c = Clip(id: "c", kind: .media, mediaId: "talk", start: 0, duration: 10)
    try c.animate("transform.scale", keys: [CurveKey(t: 2, v: .number(1)), CurveKey(t: 8, v: .number(2))])
    try p.addClip(c, trackId: "V1", mode: .place)
    p.deleteRange(TimeRange(0, 1), ripple: true)
    #expect(p.tracks[0].clips[0].anim["transform.scale"]?.keys.first?.t == 1)
}

@Test func anchorsResolve() throws {
    var p = project()
    try p.addClip(Clip(id: "a", kind: .media, mediaId: "talk", start: 0, duration: 3), trackId: "V1", mode: .place)
    try p.addClip(Clip(id: "b", kind: .media, mediaId: "talk", start: 3, duration: 5, sourceIn: 10), trackId: "V1", mode: .place)
    p.markers = [Marker(id: "m_1", time: 4, label: "Intro")]
    let words = (0..<20).map { Word(text: "w\($0)", start: Double($0), end: Double($0) + 0.5) }
    let tr = ["talk": Transcript(mediaId: "talk", locale: "en", words: words)]
    #expect(try p.resolveTime("1:02.5", transcripts: tr) == 62.5)
    #expect(try p.resolveTime("talk.w11", transcripts: tr) == 4)
    #expect(try p.resolveTime("talk.w11.end+0.25", transcripts: tr) == 4.75)
    #expect(try p.resolveTime("b.start-1", transcripts: tr) == 2)
    #expect(try p.resolveTime("marker:intro", transcripts: tr) == 4)
    #expect(try p.resolveTime("end", transcripts: tr) == 8)
    #expect(throws: EditError.self) { try p.resolveTime("talk.w5", transcripts: tr) }
}

@Test func diffDescribesChanges() throws {
    var p = project()
    try p.addClip(Clip(id: "a", kind: .media, mediaId: "talk", start: 0, duration: 3), trackId: "V1", mode: .place)
    let before = p
    try p.tracks[0].clips[0].set("transform.scale", .number(1.5))
    p.tracks[0].clips[0].effects.append(Effect(id: "glow1", type: "stylize.glow"))
    let lines = p.changes(from: before)
    #expect(lines.contains { $0.contains("transform.scale 1→1.5") })
    #expect(lines.contains { $0.contains("+fx glow1") })
}

@Test func catalogParamsAreConsistent() {
    for type in EffectCatalog.all {
        for p in type.params {
            if case .number = p.kind { #expect(p.defaultValue.number != nil, "\(type.id).\(p.name)") }
            if let lo = p.min, let hi = p.max, let d = p.defaultValue.number { #expect(d >= lo && d <= hi, "\(type.id).\(p.name)") }
        }
    }
}

@Test func duckWritesDipsUnderSpeech() throws {
    var p = project()
    p.media.append(MediaAsset(id: "music", path: "/tmp/m.m4a", name: "Music", duration: 60, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true))
    try p.addClip(Clip(id: "song", kind: .media, mediaId: "music", start: 0, duration: 20), trackId: "A1", mode: .place)
    let dips = try p.duck(clipIds: ["song"], under: [TimeRange(5, 8), TimeRange(8.5, 10)], amountDb: 12, attack: 0.3, release: 0.8)
    #expect(dips == 1)
    let c = p.clip("song")!
    #expect(abs(c.number("audio.volume", at: 7) - 0.251) < 0.01)
    #expect(c.number("audio.volume", at: 2) == 1)
    #expect(c.number("audio.volume", at: 15) == 1)
}

@Test func splitEditShiftsSoundAcrossTheCut() throws {
    var p = project()
    try p.addClip(Clip(id: "a", kind: .media, mediaId: "talk", start: 0, duration: 4, sourceIn: 2), trackId: "V1", mode: .place)
    try p.addClip(Clip(id: "b", kind: .media, mediaId: "talk", start: 4, duration: 4, sourceIn: 10), trackId: "V1", mode: .place)
    try p.splitEdit(left: "a", right: "b", offset: 1)
    #expect(p.clip("b")!.audioRange == TimeRange(3, 8))
    #expect(p.clip("b")!.audioSourceRange.start == 9)
    #expect(p.clip("a")!.audioRange == TimeRange(0, 3))
    #expect(throws: EditError.self) { try p.splitEdit(left: "a", right: "b", offset: 5) }
}
