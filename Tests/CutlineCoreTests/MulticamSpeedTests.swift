import Foundation
import Testing
@testable import CutlineCore

/// Two cameras and a recorder; the multicam clip plays at 1.25×, lasting 24 s over multicam 6–36 s, switched
/// A → B → A → B.
private func spedMulticamEdit() throws -> Project {
    var p = Project(name: "Multicam")
    p.canvas.fps = 25
    p.media = [
        MediaAsset(id: "camA", path: "/tmp/a.mov", name: "Cam A", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "camB", path: "/tmp/b.mov", name: "Cam B", duration: 50, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "rec", path: "/tmp/r.wav", name: "Recorder", duration: 70, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
    ]
    let seq = try p.createMulticam(name: "Interview", angles: [("A", "camA", 10), ("B", "camB", 7.5), ("rec", "rec", 12)], audio: ["rec"], sync: "marker")
    var c = Clip(id: "mc", kind: .sequence, mediaId: seq.id, start: 2, duration: 24, sourceIn: 6, speed: 1.25)
    c.multicam = MulticamSwitch(cuts: [AngleCut(at: 0, angle: "A")])
    p.tracks[0].clips = [c]
    try p.switchMulticam("mc", from: 10, angle: "B")
    try p.switchMulticam("mc", from: 18, to: 22, angle: "A")
    try p.validate()
    return p
}

private func summary(_ p: Project) throws -> (clip: Clip, ranges: [String], offsets: [Seconds]) {
    let clips = p.tracks.filter { $0.kind == .video }.flatMap(\.clips)
    #expect(clips.count == 1, "\(clips.map(\.id))")
    let c = try #require(clips.first)
    let setup = try #require(p.multicamSetup(c), "not a multicam clip")
    let ranges = p.visibleAngleRanges(c).map { "\(Int(($0.range.start * 25).rounded()))-\(Int(($0.range.end * 25).rounded())) \($0.angle) \($0.audio.joined(separator: "+"))" }
    return (c, ranges, setup.angles.map(\.offset))
}

@Test func spedMulticamPlaysItsAnglesAtItsSpeed() throws {
    let p = try spedMulticamEdit()
    let c = try #require(p.clip("mc"))
    // Timeline 10 s is 8 s into the clip: multicam 6 + 8 × 1.25 = 16.
    #expect(abs(Project.multicamTime(c, timeline: 10) - 16) < 1e-9)
    #expect(p.visibleAngleRanges(c).map(\.range.start) == [2, 10, 18, 22])
    let placed = p.expanded(c).filter { $0.kind == .video }.map(\.clip)
    #expect(placed.map(\.mediaId) == ["camA", "camB", "camA", "camB"])
    #expect(placed.allSatisfy { abs($0.speed - 1.25) < 1e-9 })
    #expect(abs(placed[1].start - 10) < 1e-9 && abs(placed.last!.end - 26) < 1e-9)
    // camB at timeline 10 s shows multicam 16 s.
    let b = try #require(p.multicamSetup(c)?.angle("B"))
    #expect(abs(placed[1].sourceIn - (16 + b.offset)) < 0.03)
}

@Test(arguments: [InterchangeFormat.fcpxml, .xml])
func spedMulticamRoundTripsWithItsSpeed(format: InterchangeFormat) throws {
    let p = try spedMulticamEdit()
    let want = try summary(p)
    let made = try p.interchange(format)
    let text = String(decoding: made.data, as: UTF8.self)
    let back: Project
    if format == .fcpxml {
        #expect(text.components(separatedBy: "<mc-clip ").count == 5 && text.components(separatedBy: "<timeMap>").count == 5, "\(text)")
        back = try Importer.fcpxml(made.data, relativeTo: nil).project
    } else {
        #expect(text.contains("<effectid>timeremap</effectid>"), "\(text)")
        back = try Importer.xmeml(made.data, relativeTo: nil).project
    }
    let got = try summary(back)
    #expect(got.ranges == want.ranges)
    for (a, b) in zip(got.offsets, want.offsets) { #expect(abs(a - b) < 0.021) }
    #expect(abs(got.clip.speed - 1.25) < 1e-6 && abs(got.clip.sourceIn - 6) < 0.021 && abs(got.clip.duration - 24) < 0.021, "\(got.clip)")
    var host = Project(name: "Host")
    host.media = p.media
    _ = try host.adoptTimeline(back, name: "Back")
    try host.validate()
}

@Test func spedMulticamGoesToAAFAsSpedAnglePieces() throws {
    let p = try spedMulticamEdit()
    let want = p.expanded(try #require(p.clip("mc"))).filter { $0.kind == .video }.map(\.clip)
    let back = try Importer.aaf(try p.interchange(.aaf).data, relativeTo: nil).project
    let pictures = back.tracks.filter { $0.kind == .video }.flatMap(\.clips).sorted { $0.start < $1.start }
    #expect(pictures.count == want.count)
    for (g, w) in zip(pictures, want) {
        #expect(abs(g.speed - 1.25) < 1e-6, "\(g)")
        #expect(abs(g.start - w.start) < 0.041 && abs(g.duration - w.duration) < 0.041, "\(g) vs \(w)")
        #expect(abs(g.sourceIn - w.sourceIn) < 0.041, "\(g.sourceIn) vs \(w.sourceIn)")
    }
    try back.validate()
}

@Test func spedMulticamCutOffTheFrameGridReadsBackAsOneClip() throws {
    var p = try spedMulticamEdit()
    p.canvas.fps = 24
    let seq = try #require(p.sequences.first)
    var c = Clip(id: "mc", kind: .sequence, mediaId: seq.id, start: 0, duration: 20, sourceIn: 6, speed: 1.25)
    // Multicam 9 s is timeline 2.4 s, between frames 57 and 58.
    c.multicam = MulticamSwitch(cuts: [AngleCut(at: 0, angle: "A"), AngleCut(at: 9, angle: "B")])
    p.tracks[0].clips = [c]
    let back = try Importer.xmeml(try p.interchange(.xml).data, relativeTo: nil).project
    let clips = back.tracks.filter { $0.kind == .video }.flatMap(\.clips)
    #expect(clips.count == 1 && clips.allSatisfy { $0.speed == 1.25 }, "\(clips.map { ($0.start, $0.duration, $0.speed) })")
}

@Test func aafMediaKeepTheirWholeLength() throws {
    var p = Project(name: "Lengths")
    p.canvas.fps = 24
    p.media = [MediaAsset(id: "camr", path: "/tmp/camr.mov", name: "camr", duration: 30.75, width: 1920, height: 1080, fps: 24, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "camr", start: 0, duration: 3, sourceIn: 10)]
    let back = try Importer.aaf(try p.interchange(.aaf).data, relativeTo: nil).project
    let m = try #require(back.media.first)
    #expect(abs(m.duration - 30.75) < 0.05, "\(m.duration)")
}
