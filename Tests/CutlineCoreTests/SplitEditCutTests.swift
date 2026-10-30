import Foundation
import Testing
@testable import CutlineCore

/// V1: a (m 0–10 s), b (n from 5, 10–20), c (m from 20, 20–30), with an L cut between a and b (a's sound runs to 10.4).
private func lCut() throws -> Project {
    var p = Project(name: "Cuts")
    p.canvas.fps = 25
    p.media = [
        MediaAsset(id: "m", path: "/tmp/m.mov", name: "M", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "n", path: "/tmp/n.mov", name: "N", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
    ]
    p.tracks[0].clips = [
        Clip(id: "a", kind: .media, mediaId: "m", start: 0, duration: 10, sourceIn: 0),
        Clip(id: "b", kind: .media, mediaId: "n", start: 10, duration: 10, sourceIn: 5),
        Clip(id: "c", kind: .media, mediaId: "m", start: 20, duration: 10, sourceIn: 20),
    ]
    try p.splitEdit(left: "a", right: "b", offset: -0.4)
    return p
}

/// Timeline spans each clip on V1 is heard over.
private func audible(_ p: Project) -> [(id: String, range: TimeRange, source: TimeRange, media: String)] {
    p.tracks[0].clips.filter { $0.audioRange.duration > 1e-6 }.map { ($0.id, $0.audioRange, $0.audioSourceRange, $0.mediaId ?? "") }
}

private func expectNoOverlap(_ p: Project, sourceLocation: SourceLocation = #_sourceLocation) {
    let heard = audible(p)
    for (i, x) in heard.enumerated() {
        for y in heard[(i + 1)...] {
            let o = x.range.intersection(y.range)?.duration ?? 0
            #expect(o < 1e-6, "\(x.id) and \(y.id) both play \(o)s", sourceLocation: sourceLocation)
        }
    }
}

private func expectSilent(_ p: Project, in r: TimeRange, sourceLocation: SourceLocation = #_sourceLocation) {
    for h in audible(p) {
        let o = h.range.intersection(r)?.duration ?? 0
        #expect(o < 1e-6, "\(h.id) plays \(o)s inside \(r.start)–\(r.end)", sourceLocation: sourceLocation)
    }
}

/// No clip plays source that was cut.
private func expectNotHeard(_ p: Project, media: String, source r: TimeRange, sourceLocation: SourceLocation = #_sourceLocation) {
    for h in audible(p) where h.media == media {
        let o = h.source.intersection(r)?.duration ?? 0
        #expect(o < 1e-6, "\(h.id) still plays \(o)s of cut source \(r.start)–\(r.end)", sourceLocation: sourceLocation)
    }
}

@Test func liftInsideAnLCutClipSilencesTheRange() throws {
    var p = try lCut()
    p.deleteRange(TimeRange(5, 5.6), ripple: false)
    expectSilent(p, in: TimeRange(5, 5.6))
    expectNoOverlap(p)
    let clips = p.tracks[0].clips
    #expect(clips[0].audioLag == 0)
    // The tail piece keeps the L cut into b.
    #expect(abs(clips[1].audioRange.end - 10.4) < 1e-9)
    #expect(abs(p.clip("b")!.audioRange.start - 10.4) < 1e-9)
    try p.validate()
}

@Test func rippleDeleteInsideAnLCutClipDropsThatSound() throws {
    var p = try lCut()
    p.deleteRange(TimeRange(5, 5.6), ripple: true)
    expectNotHeard(p, media: "m", source: TimeRange(5, 5.6))
    expectNoOverlap(p)
    let heard = TimeRange.merged(audible(p).map(\.range))
    #expect(heard.count == 1 && heard[0].start == 0 && abs(heard[0].end - 29.4) < 1e-6, "\(heard)")
}

@Test func deletingAcrossASplitEditLeavesStraightCuts() throws {
    for ripple in [false, true] {
        var p = try lCut()
        p.deleteRange(TimeRange(9.8, 10.2), ripple: ripple)
        if !ripple { expectSilent(p, in: TimeRange(9.8, 10.2)) }
        expectNotHeard(p, media: "m", source: TimeRange(9.8, 10.4))
        expectNoOverlap(p)
        let clips = p.tracks[0].clips
        #expect(clips[0].audioLag == 0 && clips[1].audioLead == 0)
    }
}

@Test func deletingAClipTakesItsNeighboursSplitSoundWithIt() throws {
    var p = try lCut()
    try p.deleteClips(["b"], ripple: false)
    expectSilent(p, in: TimeRange(10, 20))
    #expect(p.clip("a")!.audioLag == 0)

    // b's own L cut into c: deleting b gives c its sound back from its first frame.
    var q = try lCut()
    try q.splitEdit(left: "b", right: "c", offset: -0.5)
    try q.deleteClips(["b"], ripple: true)
    expectNoOverlap(q)
    let c = q.clip("c")!
    #expect(c.start == 10 && c.audioLead == 0)
    #expect(TimeRange.merged(audible(q).map(\.range)).count == 1)

    // A range covering exactly one clip behaves the same.
    var r = try lCut()
    r.deleteRange(TimeRange(10, 20), ripple: false)
    expectSilent(r, in: TimeRange(10, 20))
}

@Test func splittingInsideASplitEditOverlapDoesNotDoubleTheSound() throws {
    var p = try lCut()
    // 10.0–10.4 is a's sound under b's picture.
    let (left, right) = try p.splitClip("b", at: 10.2)
    expectNoOverlap(p)
    #expect(p.clip(left)!.audioRange.duration < 1e-6)
    #expect(abs(p.clip(right)!.audioRange.start - 10.4) < 1e-9)
    // Splitting a, the head keeps no lag and the tail keeps the L cut.
    let (h, t) = try p.splitClip("a", at: 5)
    #expect(p.clip(h)!.audioLag == 0 && abs(p.clip(t)!.audioRange.end - 10.4) < 1e-9)
    expectNoOverlap(p)
    try p.validate()
}

@Test func overwriteAndInsertKeepSoundOutOfTheNewClip() throws {
    var p = try lCut()
    let insert = Clip(id: "x", kind: .media, mediaId: "m", start: 10, duration: 2, sourceIn: 40)
    try p.addClip(insert, trackId: "V1", mode: .overwrite)
    for h in audible(p) where h.id != "x" {
        #expect((h.range.intersection(TimeRange(10, 12))?.duration ?? 0) < 1e-6, "\(h.id) plays over the overwrite")
    }
    expectNoOverlap(p)

    var q = try lCut()
    try q.addClip(Clip(id: "y", kind: .media, mediaId: "m", start: 10, duration: 2, sourceIn: 40), trackId: "V1", mode: .insert)
    for h in audible(q) where h.id != "y" {
        #expect((h.range.intersection(TimeRange(10, 12))?.duration ?? 0) < 1e-6, "\(h.id) plays over the insert")
    }
    expectNoOverlap(q)
    #expect(q.clip("a")!.audioLag == 0 && q.clip("b")!.audioLead == 0)
}

@Test func sourceCutsAndSilenceCutsNeverPlayCutSound() throws {
    var p = try lCut()
    // The end of a's L-cut sound and the start of its picture tail.
    p.cutSourceRanges(mediaId: "m", ranges: [TimeRange(9.6, 10.2)])
    expectNotHeard(p, media: "m", source: TimeRange(9.6, 10.2))
    expectNoOverlap(p)
    try p.validate()
}

@Test func cutsLeaveClipsWithoutSplitEditsStraight() throws {
    var p = try lCut()
    p.tracks[0].clips.append(Clip(id: "t", kind: .text, start: 30, duration: 5, text: TextSpec(text: "Title")))
    p.deleteRange(TimeRange(2.03, 3.07), ripple: false)
    p.deleteRange(TimeRange(31.01, 32.33), ripple: true)
    _ = try p.splitClip("c", at: 24.37)
    let straight = p.tracks[0].clips.filter { !["a", "b"].contains($0.id) && $0.start > 10.5 || $0.end < 9 }
    #expect(straight.allSatisfy { $0.audioLead == 0 && $0.audioLag == 0 }, "\(straight.map { ($0.id, $0.audioLead, $0.audioLag) })")
    try p.validate()
}

@Test func trimsKeepSplitEditsWithoutDoubledSound() throws {
    var p = try lCut()
    try p.trim("a", mode: .roll, edge: .end, delta: -1)
    expectNoOverlap(p)
    #expect(abs(p.clip("a")!.audioRange.end - 9.4) < 1e-9 && abs(p.clip("b")!.audioRange.start - 9.4) < 1e-9)
    try p.trim("a", mode: .ripple, edge: .end, delta: -1)
    expectNoOverlap(p)
    try p.validate()
}
