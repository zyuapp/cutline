import Foundation
import Testing
@testable import CutlineCore

private func media(_ id: String) -> MediaAsset {
    MediaAsset(id: id, path: "/tmp/\(id).mov", name: id, duration: 120, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)
}

/// V1: a (0–5) and b (5–10); A3: room tone 6–8; A4: a music bed 0–12.
private func edit() -> Project {
    var p = Project(name: "Sync lock")
    p.media = [media("m"), media("tone"), media("music")]
    p.tracks[0].clips = [
        Clip(id: "a", kind: .media, mediaId: "m", start: 0, duration: 5, sourceIn: 10),
        Clip(id: "b", kind: .media, mediaId: "m", start: 5, duration: 5, sourceIn: 30),
    ]
    p.addTrack(kind: .audio, name: "Room tone")
    p.tracks[p.tracks.count - 1].clips = [Clip(id: "rt", kind: .media, mediaId: "tone", start: 6, duration: 2)]
    p.addTrack(kind: .audio, name: "Bed")
    p.tracks[p.tracks.count - 1].clips = [Clip(id: "bed", kind: .media, mediaId: "music", start: 0, duration: 12)]
    return p
}

private func track(_ p: Project, _ name: String) -> Int { p.tracks.firstIndex { $0.name == name }! }

@Test func rippleOnEveryTrackMovesLaterClipsAndCutsSpanningOnes() throws {
    var p = edit()
    let line = try p.trim("a", mode: .ripple, edge: .end, delta: -1, allTracks: true)
    #expect(p.clip("b")?.start == 4 && p.clip("rt")?.start == 5, "room tone after the edit moves: \(line)")
    let bed = p.tracks[track(p, "Bed")].clips
    #expect(bed.count == 2 && bed[0].end == 4 && bed[1].start == 4 && bed[1].end == 11 && bed[1].sourceIn == 5, "the bed loses the trimmed second: \(bed)")
    #expect(line.contains("\(p.tracks[track(p, "Room tone")].id): 1 clip moved −1.00s") && line.contains("cut bed"), "\(line)")

    var q = edit()
    q.tracks[track(q, "Bed")].syncLock = false
    let kept = try q.trim("a", mode: .ripple, edge: .end, delta: -1, allTracks: true)
    #expect(q.clip("bed")?.start == 0 && q.clip("bed")?.duration == 12 && q.clip("rt")?.start == 5)
    #expect(kept.contains("(sync lock off) left in place"), "\(kept)")

    // A head trim takes out the clip's first second everywhere: room tone over b stays over the same picture.
    var h = edit()
    try h.trim("b", mode: .ripple, edge: .start, delta: 1, allTracks: true)
    #expect(h.clip("b")?.start == 5 && h.clip("b")?.sourceIn == 31 && h.clip("rt")?.start == 5)
}

@Test func insertSplitsAndPushesEverySyncLockedTrack() throws {
    var p = edit()
    let (sa, _) = try p.detachAudio("a")
    let (_, notes) = try p.addClipReporting(Clip(id: "ins", kind: .media, mediaId: "m", start: 2.5, duration: 1, sourceIn: 60), trackId: "V1", mode: .insert)
    let bed = p.tracks[track(p, "Bed")].clips
    #expect(bed.count == 2 && bed[0].end == 2.5 && bed[1].start == 3.5 && bed[1].duration == 9.5, "\(bed)")
    #expect(p.clip("rt")?.start == 7 && p.clip("b")?.start == 6)
    let sound = p.tracks.first { $0.clips.contains { $0.id == sa.id } }!.clips
    #expect(sound.count == 2 && sound[1].start == 3.5, "a's detached sound splits and moves with a")
    #expect(p.linkSyncIssues().isEmpty && p.linkRangeIssues().isEmpty)
    #expect(notes.contains { $0.contains("split bed") }, "\(notes)")

    var q = edit()
    q.tracks[track(q, "Bed")].syncLock = false
    try q.addClip(Clip(id: "ins", kind: .media, mediaId: "m", start: 2.5, duration: 1, sourceIn: 60), trackId: "V1", mode: .insert)
    #expect(q.clip("bed")?.start == 0 && q.clip("bed")?.duration == 12 && q.clip("rt")?.start == 7)
}

@Test func insertAtACutCarriesTheIncomingJCutSoundWhole() throws {
    var p = edit()
    let (sb, _) = try p.detachAudio("b")
    try p.splitEdit(left: "a", right: "b", offset: 0.5)
    #expect(p.clip(sb.id)?.start == 4.5)
    try p.addClip(Clip(id: "ins", kind: .media, mediaId: "m", start: 5, duration: 1, sourceIn: 60), trackId: "V1", mode: .insert)
    #expect(p.clip("b")?.start == 6 && p.clip(sb.id)?.start == 5.5 && p.clip(sb.id)?.duration == 5.5, "\(String(describing: p.clip(sb.id)))")
    #expect(p.linkSyncIssues().isEmpty)
}

@Test func rangeDeleteSparesTracksWithSyncLockOff() {
    var p = edit()
    p.tracks[track(p, "Bed")].syncLock = false
    let notes = p.deleteRange(TimeRange(1, 2), ripple: true)
    #expect(p.clip("bed")?.duration == 12 && p.clip("b")?.start == 4 && p.clip("rt")?.start == 5)
    #expect(notes.contains { $0.contains("(sync lock off)") }, "\(notes)")
}

@Test func syncLockRoundTripsAndDefaultsOn() throws {
    var p = edit()
    p.tracks[track(p, "Bed")].syncLock = false
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(Project.self, from: data)
    #expect(back.tracks.map(\.syncLock) == p.tracks.map(\.syncLock))
    #expect(!String(decoding: try JSONEncoder().encode(edit().tracks[0]), as: UTF8.self).contains("syncLock"))
}

@Test func overwriteCutsThePictureAndItsDetachedSoundAlike() throws {
    var p = edit()
    let (sa, _) = try p.detachAudio("a")
    try p.addClip(Clip(id: "o", kind: .media, mediaId: "m", start: 2, duration: 1, sourceIn: 80), trackId: "V1", mode: .overwrite)
    let sound = p.tracks.first { $0.clips.contains { $0.id == sa.id } }!.clips
    #expect(sound.map(\.start) == [0, 3] && sound.map(\.end) == [2, 5], "\(sound)")
    let right = p.tracks[0].clips.first { $0.start == 3 }!
    #expect(right.link != nil && right.link != p.clip("a")?.link && p.linked(right.id) == [sound[1].id])
    #expect(p.linkSyncIssues().isEmpty && p.linkRangeIssues().isEmpty)
}

@Test func rollCarriesTheNeighboursLinkedSound() throws {
    var p = edit()
    let (sa, _) = try p.detachAudio("a")
    _ = try p.trim("b", mode: .roll, edge: .start, delta: -0.5)
    #expect(p.clip("a")?.end == 4.5 && p.clip(sa.id)?.end == 4.5)
}

@Test func driftedSoundEdgesAreReportedAndResynced() throws {
    var p = edit()
    let (sa, _) = try p.detachAudio("a")
    let l = p.locateClip(sa.id)!
    p.tracks[l.track].clips[l.clip].duration = 5.3
    let over = p.linkRangeIssues()
    #expect(over.count == 1 && over[0].clip == sa.id && over[0].edge == .end && abs(over[0].overlap - 0.3) < 1e-9, "\(over)")
    #expect(p.qualityIssues(transcripts: [:]).contains { $0.contains("plays 0.30s over b's sound") && $0.contains("resync:true") })

    // An L cut, where b's sound yields, is not drift.
    var lcut = p
    lcut.tracks[0].clips[1].audioLead = -0.3
    #expect(lcut.linkRangeIssues().isEmpty)

    p.tracks[l.track].clips[l.clip].duration = 4.7
    #expect(p.linkRangeIssues().first?.overlap ?? 0 < -0.29, "a hole before b's sound")
    let notes = try p.resyncLinked("a")
    #expect(p.clip(sa.id)?.end == 5 && p.linkRangeIssues().isEmpty, "\(notes)")
}
