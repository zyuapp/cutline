import Foundation
import Testing
@testable import CutlineCore

private func dialogue() -> Project {
    var p = Project(name: "Audio")
    p.media = [
        MediaAsset(id: "m", path: "/tmp/m.mov", name: "M", duration: 30, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true),
        MediaAsset(id: "tone", path: "/tmp/tone.wav", name: "Tone", duration: 10, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
        MediaAsset(id: "still", path: "/tmp/s.png", name: "S", duration: 0, width: 100, height: 100, fps: 0, hasVideo: true, hasAudio: false, isImage: true),
    ]
    p.tracks[0].clips = [
        Clip(id: "a", kind: .media, mediaId: "m", start: 0, duration: 4, sourceIn: 2),
        Clip(id: "b", kind: .media, mediaId: "m", start: 4, duration: 4, sourceIn: 10),
    ]
    return p
}

@Test func audioTrimRollsTheSoundCutWithTheNeighbour() throws {
    var p = dialogue()
    try p.trimAudio("b", edge: .start, delta: -0.5)
    var a = try #require(p.clip("a")), b = try #require(p.clip("b"))
    #expect(b.audioLead == 0.5 && a.audioLag == -0.5)
    #expect(abs(a.audioRange.end - b.audioRange.start) < 1e-9 && abs(b.audioRange.start - 3.5) < 1e-9)
    #expect(a.start == 0 && a.duration == 4 && b.start == 4 && b.duration == 4)

    try p.trimAudio("a", edge: .end, delta: 0.8)
    a = try #require(p.clip("a"))
    b = try #require(p.clip("b"))
    #expect(abs(a.audioLag - 0.3) < 1e-9 && abs(b.audioLead + 0.3) < 1e-9)
    #expect(abs(a.audioRange.end - 4.3) < 1e-9 && abs(b.audioRange.start - 4.3) < 1e-9)
    try p.validate()

    // Rolling can't take more sound than the neighbour has.
    #expect(throws: EditError.self) { try p.trimAudio("b", edge: .start, delta: -4.5) }
}

@Test func audioTrimWithoutATouchingNeighbourOnlyMovesThatSound() throws {
    var p = dialogue()
    p.tracks[0].clips[1].start = 5
    try p.trimAudio("b", edge: .start, delta: -0.5)
    #expect(p.clip("b")?.audioLead == 0.5 && p.clip("a")?.audioLag == 0)
    // Not enough source before the in point.
    #expect(throws: EditError.self) { try p.trimAudio("a", edge: .start, delta: -3) }
    // A neighbour without sound doesn't roll.
    var q = dialogue()
    q.tracks[0].clips[0] = Clip(id: "a", kind: .media, mediaId: "still", start: 0, duration: 4)
    try q.trimAudio("b", edge: .start, delta: -0.5)
    #expect(q.clip("b")?.audioLead == 0.5)
}

@Test func audioCrossfadesSitOnTheSoundCutOfASplitEdit() throws {
    var p = dialogue()
    try p.splitEdit(left: "a", right: "b", offset: 0.5)
    let tr = Transition(id: "tr1", from: "a", to: "b", type: "dissolve", duration: 0.4, part: .audio)
    try p.checkTransition(tr)
    let w = try p.audioWindow(tr)
    #expect(abs(w.start - 3.3) < 1e-9 && abs(w.end - 3.7) < 1e-9)
    #expect(abs(try p.window(tr).start - 3.8) < 1e-9)
    p.transitions = [tr]
    let r = p.resolvingAudioTransitions()
    let a = try #require(r.clip("a")), b = try #require(r.clip("b"))
    #expect(abs(a.audioRange.end - 3.7) < 1e-9 && abs(a.audioFadeOut - 0.4) < 1e-9)
    #expect(abs(b.audioRange.start - 3.3) < 1e-9 && abs(b.audioFadeIn - 0.4) < 1e-9)
    #expect(r.transitions.isEmpty)
    #expect(r.resolvingAudioTransitions() == r)
    try r.validate()

    // Picture and sound together: the dissolve stays on the picture cut.
    let both = Transition(id: "tr1", from: "a", to: "b", type: "dissolve", duration: 0.4)
    try p.checkTransition(both)
    #expect(abs(try p.window(both).start - 3.8) < 1e-9)

    // A crossfade needing more sound than the source has fails with the handle.
    var short = dialogue()
    short.tracks[0].clips[1].sourceIn = 0.6
    try short.splitEdit(left: "a", right: "b", offset: 0.5)
    #expect(throws: EditError.self) { try short.checkTransition(Transition(id: "t", from: "a", to: "b", type: "dissolve", duration: 0.4, part: .audio)) }
}

@Test func roomToneVariesItsSourceAndCrossfades() throws {
    var p = dialogue()
    let source = TimeRange(20, 23)
    let pieces = try p.roomTonePieces(range: TimeRange(1, 9), source: source, crossfade: 0.25)
    #expect(pieces.count > 3)
    #expect(pieces.first?.start == 1 && abs((pieces.last.map { $0.start + $0.duration } ?? 0) - 9) < 1e-9)
    for (x, y) in zip(pieces, pieces.dropFirst()) {
        #expect(abs(x.start + x.duration - y.start) < 1e-9, "pieces touch")
        #expect(abs(x.sourceIn - y.sourceIn) > 0.1, "neighbours read different parts")
    }
    for piece in pieces {
        #expect(piece.sourceIn >= source.start + 0.125 - 1e-9 && piece.sourceIn + piece.duration <= source.end - 0.125 + 1e-6)
    }
    #expect(throws: EditError.self) { try p.roomTonePieces(range: TimeRange(0, 5), source: TimeRange(20, 20.4), crossfade: 0.25) }

    let track = p.addTrack(kind: .audio, name: "Room tone")
    let ids = try p.fillRoomTone(TimeRange(0, 9), mediaId: "m", source: source, trackId: track.id)
    #expect(ids.count == p.tracks[p.trackIndex(track.id)!].clips.count)
    let clips = ids.compactMap { p.clip($0) }
    #expect(clips.first?.audioLead == 0, "no sound before the timeline starts")
    #expect(clips.dropFirst().allSatisfy { $0.audioLead == 0.125 && $0.audioLag == 0.125 && $0.audioFadeIn == 0.25 && $0.audioFadeOut == 0.25 })
    try p.validate()
    #expect(throws: EditError.self) { try p.fillRoomTone(TimeRange(0, 1), mediaId: "still", source: source, trackId: track.id) }
}

@Test func soundGapsAreFoundBetweenDialogue() throws {
    var p = dialogue()
    p.tracks[0].clips[1].start = 5
    p.tracks[0].clips.append(Clip(id: "c", kind: .media, mediaId: "m", start: 9, duration: 2, sourceIn: 20))
    p.tracks[0].clips.append(Clip(id: "d", kind: .media, mediaId: "m", start: 11.02, duration: 1, sourceIn: 20))
    let gaps = try p.soundGaps(trackId: "V1", minGap: 0.04)
    #expect(gaps == [TimeRange(4, 5)])
    // A J cut closes part of a gap.
    p.tracks[0].clips[1].audioLead = 0.4
    #expect(abs(try p.soundGaps(trackId: "V1", minGap: 0.04)[0].end - 4.6) < 1e-9)
}

@Test func loopPiecesRepeatTheSourceToFill() throws {
    let p = dialogue()
    let pieces = try p.loopPieces(start: 2, duration: 5, source: TimeRange(1, 3))
    #expect(pieces.map(\.start) == [2, 4, 6])
    #expect(pieces.map(\.duration) == [2, 2, 1])
    #expect(pieces.allSatisfy { $0.sourceIn == 1 })
    #expect(throws: EditError.self) { try p.loopPieces(start: 0, duration: 5, source: TimeRange(1, 1.01)) }
}

@Test func retimingSoundWarnsAndRefusesExtremeStretch() throws {
    #expect(Clip.retimeWarning(speed: 1.05, hasAudio: true) == nil)
    #expect(Clip.retimeWarning(speed: 0.04, hasAudio: true)?.contains("slowed to 0.04×") == true)
    #expect(Clip.retimeWarning(speed: 2, hasAudio: true)?.contains("sped up") == true)
    #expect(Clip.retimeWarning(speed: 0.5, hasAudio: false) == nil)
    let p = dialogue()
    #expect(throws: EditError.self) { try Clip.checkAudioStretch(speed: 0.04, media: p.mediaAsset("tone")!, allow: false) }
    try Clip.checkAudioStretch(speed: 0.04, media: p.mediaAsset("tone")!, allow: true)
    try Clip.checkAudioStretch(speed: 0.04, media: p.mediaAsset("m")!, allow: false)
}

@Test func channelRoutingIsAClipParameter() throws {
    var c = Clip(id: "c", kind: .media, mediaId: "m", start: 0, duration: 1)
    #expect(c.staticValue("audio.channels") == .string("stereo"))
    try c.set("audio.channels", .string("left"))
    #expect(c.channels == .left)
    #expect(throws: EditError.self) { try c.set("audio.channels", .string("center")) }
    #expect(throws: EditError.self) { try c.animate("audio.channels", keys: [CurveKey(t: 0, v: .string("right"))]) }
    let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c))
    #expect(decoded.channels == .left)
    try c.set("audio.channels", .string("stereo"))
    #expect(c.channels == nil)
}

@Test func restorationEffectsAreListed() {
    let ids = Set(EffectCatalog.listed.map(\.id))
    for id in ["audio.denoise", "audio.deess", "audio.dehum", "audio.declick", "audio.pan", "audio.width", "audio.eq"] {
        #expect(ids.contains(id), "\(id)")
    }
    #expect(EffectCatalog.type("audio.declick")?.spec("sensitivity") != nil)
    #expect(EffectCatalog.listed.contains { $0.summary.lowercased().contains("sibilance") })
}
