import Foundation
import Testing
@testable import CutlineCore

/// Two cameras (camB starts 2.5 s later than camA in real time) and a sound recorder.
private func multicamProject() throws -> (Project, Clip) {
    var p = Project(name: "Multicam")
    p.canvas.fps = 25
    p.media = [
        MediaAsset(id: "camA", path: "/tmp/a.mov", name: "Cam A", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "camB", path: "/tmp/b.mov", name: "Cam B", duration: 50, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "rec", path: "/tmp/r.wav", name: "Recorder", duration: 70, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
    ]
    // The shared moment is at camA 10 s, camB 7.5 s, rec 12 s.
    let seq = try p.createMulticam(name: "Interview", angles: [("A", "camA", 10), ("B", "camB", 7.5), ("rec", "rec", 12)], audio: ["rec"], sync: "marker")
    var c = Clip(id: "mc", kind: .sequence, name: "Interview", mediaId: seq.id, start: 0, duration: 40, sourceIn: 5)
    c.multicam = MulticamSwitch(cuts: [AngleCut(at: 0, angle: "A")])
    p.tracks[0].clips = [c]
    return (p, c)
}

@Test func multicamAnglesStaySyncedInsideOneClip() throws {
    let (p, c) = try multicamProject()
    let seq = try #require(p.sequence(c.mediaId!))
    let setup = try #require(seq.multicam)
    // rec starts earliest (12 s before the shared moment), so it is at multicam time 0.
    #expect(setup.angles.map(\.offset) == [-2, -4.5, 0])
    #expect(seq.tracks.map(\.kind) == [.video, .video, .audio])
    #expect(seq.tracks[0].clips[0].start == 2 && seq.tracks[1].clips[0].start == 4.52)
    #expect(setup.angle("2")?.name == "B" && setup.angle("camB")?.name == "B" && setup.audio == ["rec"])
    // Starts snap to frames; the source moves with them, so sync holds.
    #expect(p.multicamOverlap(seq) == TimeRange(4.52, 54.5) && abs(seq.tracks[1].clips[0].sourceIn - 0.02) < 1e-9)
    try p.validate()
}

@Test func switchingKeepsTheAngleStructure() throws {
    var (p, c) = try multicamProject()
    // Timeline 10 s is multicam 15 s.
    try p.switchMulticam("mc", from: 10, angle: "B")
    try p.switchMulticam("mc", from: 20, to: 24, angle: "A")
    var ranges = p.visibleAngleRanges(p.clip("mc")!)
    #expect(ranges.map(\.angle) == ["A", "B", "A", "B"])
    #expect(ranges.map(\.range.start) == [0, 10, 20, 24])
    #expect(ranges.allSatisfy { $0.audio == ["rec"] })
    // Switching a range back to what surrounds it merges the ranges.
    try p.switchMulticam("mc", from: 20, to: 24, angle: "2")
    ranges = p.visibleAngleRanges(p.clip("mc")!)
    #expect(ranges.map(\.angle) == ["A", "B"])
    #expect(throws: EditError.self) { try p.switchMulticam("mc", from: 5, angle: "rec") }

    // What plays: one picture track cut between the angles in sync, and the recorder's sound.
    let inner = try #require(p.contents(of: p.clip("mc")!))
    let picture = inner.tracks[0].clips
    #expect(picture.map(\.mediaId) == ["camA", "camB"])
    // Multicam 15 s is camB source 15 - 4.5 + 0 = 10.5 (source = multicam + offset).
    #expect(abs(picture[1].sourceIn - (15 + -4.5)) < 1e-9 && picture[1].start == 15)
    #expect(picture.allSatisfy { $0.volume == 0 })
    #expect(inner.tracks[1].kind == .audio && inner.tracks[1].clips.map(\.mediaId) == ["rec"])

    // Expanded onto the timeline, the switch lands at timeline 10 s.
    let placed = p.expanded(p.clip("mc")!).filter { $0.kind == .video }.map(\.clip)
    #expect(placed.map(\.mediaId) == ["camA", "camB"] && placed[1].start == 10)

    // Splits and trims keep the switch list, which is in multicam time.
    let (_, right) = try p.splitClip("mc", at: 15)
    #expect(p.visibleAngleRanges(p.clip(right)!).map(\.angle) == ["B"])
    c = p.clip("mc")!
    #expect(p.visibleAngleRanges(c).map(\.angle) == ["A", "B"])
    try p.validate()
}

@Test func soundFollowsPictureOrStaysFixed() throws {
    var (p, _) = try multicamProject()
    try p.switchMulticam("mc", from: 10, angle: "B")
    try p.setMulticamSound("mc", audio: nil, followsVideo: true)
    #expect(p.visibleAngleRanges(p.clip("mc")!).map(\.audio) == [["A"], ["B"]])
    try p.switchMulticam("mc", from: 12, to: 14, angle: nil, audio: ["rec"])
    #expect(p.visibleAngleRanges(p.clip("mc")!).map(\.audio) == [["A"], ["B"], ["rec"], ["B"]])
    let inner = try #require(p.contents(of: p.clip("mc")!))
    #expect(inner.tracks[1].clips.map(\.mediaId) == ["camA", "camB", "rec", "camB"])
}

@Test func multicamRoundTripsAndFlattensForInterchange() throws {
    var (p, _) = try multicamProject()
    try p.switchMulticam("mc", from: 10, angle: "B")
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(Project.self, from: data)
    #expect(back == p)
    let flat = p.flatteningMulticam()
    let c = try #require(flat.clip("mc"))
    #expect(c.multicam == nil && flat.multicamSetup(c) == nil)
    #expect(flat.sequence(c.mediaId!)?.tracks.first?.clips.map(\.mediaId) == ["camA", "camB"])
    #expect(!flat.sequences.contains { $0.multicam != nil })
    let notes = p.interchangeLosses(.otio)
    #expect(notes.contains { $0.contains("multicam clip (3 angles) → a compound clip of its active angles") }, "\(notes)")
    let otio = try p.interchange(.otio)
    #expect(String(decoding: otio.data, as: UTF8.self).contains("Interview (active angles)"))
    // Unnesting a multicam clip lays out its active angles as plain clips.
    let placed = try p.unnest("mc")
    #expect(p.tracks.flatMap(\.clips).filter { placed.contains($0.id) }.compactMap(\.mediaId).sorted() == ["camA", "camB", "rec"])
}
