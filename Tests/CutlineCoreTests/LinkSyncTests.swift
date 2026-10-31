import Foundation
import Testing
@testable import CutlineCore

private func media(_ id: String) -> MediaAsset {
    MediaAsset(id: id, path: "/tmp/\(id).mov", name: id, duration: 120, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)
}

/// a (0–5) then b (5–10) on V1, b's sound detached to an audio track.
private func detached() throws -> (Project, sound: String) {
    var p = Project(name: "Link")
    p.media = [media("m")]
    p.tracks[0].clips = [
        Clip(id: "a", kind: .media, mediaId: "m", start: 0, duration: 5, sourceIn: 10),
        Clip(id: "b", kind: .media, mediaId: "m", start: 5, duration: 5, sourceIn: 30),
    ]
    let (sound, _) = try p.detachAudio("b")
    return (p, sound.id)
}

private func inSync(_ p: Project, _ pic: String, _ sound: String) -> Bool {
    guard let a = p.clip(pic), let b = p.clip(sound), let off = p.linkSyncOffset(b, reference: a) else { return false }
    return abs(off) < 1e-6
}

@Test func slipAndSlideMoveLinkedSoundToo() throws {
    var (p, s) = try detached()
    try p.trim("b", mode: .slip, edge: .end, delta: 2)
    #expect(p.clip(s)?.sourceIn == 32 && p.clip("b")?.sourceIn == 32)
    #expect(inSync(p, "b", s) && p.linkSyncIssues().isEmpty)

    try p.trim(s, mode: .slip, edge: .end, delta: -1)
    #expect(p.clip("b")?.sourceIn == 31, "slipping the sound slips its picture")

    try p.trim("b", mode: .slide, edge: .end, delta: -1)
    #expect(p.clip("b")?.start == 4 && p.clip(s)?.start == 4 && p.clip("a")?.duration == 4)
    #expect(inSync(p, "b", s))
}

@Test func rollRippleAndPlainTrimsMoveTheLinkedEdge() throws {
    var (p, s) = try detached()
    try p.trim("b", mode: .ripple, edge: .end, delta: -1)
    #expect(p.clip(s)?.end == 9 && p.clip("b")?.end == 9 && inSync(p, "b", s))

    try p.trim("b", mode: .roll, edge: .start, delta: 1)
    #expect(p.clip("b")?.start == 6 && p.clip(s)?.start == 6 && p.clip("a")?.end == 6 && inSync(p, "b", s))

    try p.trim("b", mode: .plain, edge: .start, delta: 0.5)
    #expect(p.clip(s)?.start == 6.5 && inSync(p, "b", s))

    // A split edit's sound edge isn't where the picture edge was, so it stays.
    var q = try detached().0
    let sound = q.linked("b")[0]
    q.tracks[q.locateClip(sound)!.track].clips[0] = Project.extendedLeft(q.clip(sound)!, by: 1)
    try q.trim("b", mode: .plain, edge: .start, delta: 0.5)
    #expect(q.clip(sound)?.start == 4 && inSync(q, "b", sound))
}

@Test func rippleCarriesLaterLinkedSound() throws {
    var p = Project(name: "Ripple")
    p.media = [media("m")]
    p.tracks[0].clips = [
        Clip(id: "a", kind: .media, mediaId: "m", start: 0, duration: 5, sourceIn: 10),
        Clip(id: "b", kind: .media, mediaId: "m", start: 5, duration: 5, sourceIn: 30),
    ]
    let (sb, _) = try p.detachAudio("b")
    try p.trim("a", mode: .ripple, edge: .end, delta: -2)
    #expect(p.clip("b")?.start == 3 && p.clip(sb.id)?.start == 3, "b's detached sound moves with b")
    #expect(p.linkSyncIssues().isEmpty)
}

@Test func outOfSyncLinkedSoundIsReportedAndResynced() throws {
    var (p, s) = try detached()
    let l = p.locateClip(s)!
    p.tracks[l.track].clips[l.clip].sourceIn += 2
    let issues = p.linkSyncIssues()
    #expect(issues.count == 1 && issues[0].clip == s && issues[0].reference == "b" && issues[0].frames == -60, "\(issues)")
    #expect(p.qualityIssues(transcripts: [:]).contains { $0.contains("out of sync with linked b by −60 frames") && $0.contains("resync:true") })

    let notes = try p.resyncLinked("b")
    #expect(notes.count == 1 && p.linkSyncIssues().isEmpty && p.clip(s)?.sourceIn == 30 && p.clip(s)?.start == 5)
    #expect(try p.resyncLinked(s).isEmpty)
}

@Test func speedAndSourceChangesKeepLinkedSoundInSync() throws {
    var (p, s) = try detached()
    let old = p.clip("b")!
    var sped = old
    sped.speed = 1.25
    sped.duration = 4
    try p.replaceClip(sped)
    try p.followLinked(old: old, new: p.clip("b")!)
    #expect(p.clip(s)?.speed == 1.25 && p.clip(s)?.duration == 4 && inSync(p, "b", s))

    let before = p.clip("b")!
    var headTrim = before
    headTrim.sourceIn += 1
    headTrim.duration -= 0.8
    try p.replaceClip(headTrim)
    try p.followLinked(old: before, new: p.clip("b")!)
    #expect(p.clip(s)?.sourceIn == 31 && abs((p.clip(s)?.end ?? 0) - (p.clip("b")?.end ?? 1)) < 1e-6 && inSync(p, "b", s))
}
