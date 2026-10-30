import Foundation
import Testing
@testable import CutlineCore

@Test func timelinesKeepTheirOwnEditsAndFrame() throws {
    var p = Project(name: "Show")
    p.tracks[0].clips = [Clip(id: "a", kind: .solid, start: 0, duration: 4, color: .white)]
    try p.newTimeline("Vertical", duplicate: true)
    #expect(p.currentTimelineName == "Vertical" && p.tracks[0].clips.map(\.id) == ["a"])
    p.canvas.width = 1080
    p.canvas.height = 1920
    p.tracks[0].clips[0].duration = 2

    try p.newTimeline("Trailer", duplicate: false)
    #expect(p.tracks.allSatisfy(\.clips.isEmpty) && p.canvas.width == 1080)
    #expect(p.timelineNames == ["Trailer", "Main", "Vertical"])

    try p.switchTimeline(to: "Main")
    #expect(p.canvas.width == 1920 && p.tracks[0].clips[0].duration == 4)
    try p.switchTimeline(to: "Vertical")
    #expect(p.canvas.height == 1920 && p.tracks[0].clips[0].duration == 2)

    try p.renameTimeline("Main", to: "Master 16x9")
    try p.deleteTimeline("Trailer")
    #expect(Set(p.timelineNames) == ["Vertical", "Master 16x9"])
    #expect(throws: EditError.self) { try p.deleteTimeline("Vertical") }
    #expect(throws: EditError.self) { try p.newTimeline("Vertical", duplicate: false) }

    let data = try JSONEncoder().encode(p)
    #expect(try JSONDecoder().decode(Project.self, from: data) == p)
}

@Test func adoptedTimelinesReuseMatchingMedia() throws {
    var p = Project(name: "Show")
    p.media = [MediaAsset(id: "a", path: "/x/a.mov", name: "a", duration: 9, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)]
    var other = Project(name: "Offline")
    other.media = [
        MediaAsset(id: "a-cam", path: "/x/a.mov", name: "A cam", duration: 9, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "a", path: "/y/other.mov", name: "other", duration: 9, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
    ]
    other.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "a-cam", start: 0, duration: 2), Clip(id: "c2", kind: .media, mediaId: "a", start: 2, duration: 2)]
    let counts = try p.adoptTimeline(other, name: "Offline cut")
    #expect(counts.matched == 1 && counts.added == 1)
    #expect(p.currentTimelineName == "Offline cut" && p.timelines.map(\.name) == ["Main"])
    #expect(p.tracks[0].clips.map(\.mediaId) == ["a", "a-2"])
    #expect(p.mediaAsset("a-2")?.path == "/y/other.mov")

    let again = try p.adoptTimeline(other, name: "Offline cut")
    #expect(again.name == "Offline cut 2" && p.currentTimelineName == "Offline cut 2")
    #expect(try p.adoptTimeline(other, name: "Offline cut").name == "Offline cut 3")
}

@Test func anAspectChangeKeepsFramedFillPicturesCoveringTheFrame() throws {
    var p = Project(name: "Vertical")
    p.canvas.width = 1080
    p.canvas.height = 1920
    p.media = [MediaAsset(id: "wide", path: "/x/w.mov", name: "w", duration: 9, width: 862, height: 360, fps: 24, hasVideo: true, hasAudio: true)]
    var framed = Clip(id: "f", kind: .media, mediaId: "wide", start: 0, duration: 2)
    framed.transform.fit = .fill
    framed.transform.x = 1.33
    var panned = Clip(id: "p", kind: .media, mediaId: "wide", start: 2, duration: 2)
    panned.transform.fit = .fill
    try panned.animate("transform.x", keys: [CurveKey(t: 0, v: .number(-1.5), ease: .linear), CurveKey(t: 2, v: .number(1.5), ease: .linear)])
    var centered = Clip(id: "c", kind: .media, mediaId: "wide", start: 4, duration: 2)
    centered.transform.fit = .fill
    p.tracks[0].clips = [framed, panned, centered]
    let old = 1080.0 / 1920
    p.canvas.width = 1920
    p.canvas.height = 1080
    #expect(p.frameCoverage(p.clip("f")!, at: 1) < 0.01)
    let changed = p.refitPictures(fromAspect: old)
    #expect(changed.sorted() == ["f", "p"])
    for t in [0.0, 1, 2, 3, 3.99, 5] {
        let c = try #require(p.tracks[0].clip(at: t))
        #expect(p.frameCoverage(c, at: t) > 0.999, "\(c.id) at \(t)")
    }
    // The offset still leans the same way, as far as the new overflow allows.
    #expect(p.clip("f")!.transform.x > 0.1)
    // A face-aware framing wins when it has one.
    var q = p
    q.canvas.width = 1080
    q.canvas.height = 1920
    q.refitPictures(fromAspect: 1920.0 / 1080) { _, _ in (x: 0.4, y: 0) }
    #expect(q.clip("f")!.transform.x == 0.4 && q.clip("p")!.anim["transform.x"] == nil)
}

@Test func effectParamNamesForgiveCommonGuesses() throws {
    let lut = try #require(EffectCatalog.type("color.lut"))
    #expect(lut.paramName(for: "path") == "file")
    #expect(lut.paramName(for: "file") == "file")
    #expect(lut.paramName(for: "mix") == "mix")
    let blur = try #require(EffectCatalog.type("blur.gaussian"))
    #expect(blur.paramName(for: "radus") == "radius")
    #expect(blur.paramName(for: "zzzzzz") == nil)
}
