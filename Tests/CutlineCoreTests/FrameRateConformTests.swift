import Foundation
import Testing
@testable import CutlineCore

/// 24 fps: c1 0–315 frames, c2 315–597 (sound 7 frames early), c3 597–720, dissolving into c3 over 15 frames;
/// a fade, a keyframe, a marker, a ranged marker and a caption offset off the 25 fps grid.
private func project24() -> Project {
    var p = Project(name: "Rate", canvas: Canvas(fps: 24))
    p.media = [
        MediaAsset(id: "a", path: "/tmp/rate/a.mov", name: "a", duration: 120, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "b", path: "/tmp/rate/b.mov", name: "b", duration: 120, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
    ]
    func f(_ n: Int) -> Seconds { Double(n) / 24 }
    var c1 = Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: f(315), sourceIn: f(49))
    c1.audioFadeOut = f(5)
    c1.anim["audio.volume"] = Curve(keys: [CurveKey(t: f(13), v: .number(1), ease: .linear), CurveKey(t: f(101), v: .number(0.5), ease: .linear)])
    p.tracks[0].clips = [c1,
                         Clip(id: "c2", kind: .media, mediaId: "b", start: f(315), duration: f(282), sourceIn: f(100)),
                         Clip(id: "c3", kind: .media, mediaId: "a", start: f(597), duration: f(123), sourceIn: f(500))]
    try! p.splitEdit(left: "c1", right: "c2", offset: f(7))
    p.transitions = [Transition(id: "tr1", from: "c2", to: "c3", type: "dissolve", duration: f(15))]
    p.markers = [Marker(id: "m1", time: f(77), label: "Beat")]
    var ranged = Marker(id: "m2", time: f(400), label: "Range")
    ranged.duration = f(31)
    p.markers.append(ranged)
    p.captions.edits = [CaptionEdit(mediaId: "a", fromWord: 1, toWord: 2, startOffset: f(3))]
    try! p.validate()
    return p
}

private func onGrid(_ t: Seconds, _ fps: Double) -> Bool { abs(t * fps - (t * fps).rounded()) < 1e-6 }

@Test func changingTheFrameRateSnapsEveryTimeToTheNewGrid() throws {
    var p = project24()
    let before = p
    p.canvas.fps = 25
    let report = p.conformFrameRate(from: 24)
    #expect(report.moved > 0 && report.maxShift <= 0.5 / 25 + 1e-9, "\(report.summary)")
    #expect(report.removed.isEmpty && report.trimmed.isEmpty && report.droppedTransitions.isEmpty)
    let clips = p.tracks[0].clips
    for c in clips {
        for (what, t) in [("start", c.start), ("duration", c.duration), ("source in", c.sourceIn), ("lead", c.audioLead), ("lag", c.audioLag), ("fade", c.audioFadeOut)] {
            #expect(onGrid(t, 25), "\(c.id) \(what) \(t * 25) frames")
        }
        for k in c.anim.values.flatMap(\.keys) { #expect(onGrid(c.start + k.t, 25)) }
    }
    // The cuts that met still meet, at the nearest 25 fps frame: 328.125 → 328, 621.875 → 622.
    #expect(clips.map { Int(($0.start * 25).rounded()) } == [0, 328, 622])
    #expect(clips[0].end == clips[1].start && clips[1].end == clips[2].start)
    // The J cut's sound cut and the picture stay in sync.
    #expect(abs(clips[0].audioRange.end - clips[1].audioRange.start) < 1e-9)
    #expect(abs((clips[1].sourceIn - clips[1].start) - (before.tracks[0].clips[1].sourceIn - before.tracks[0].clips[1].start)) <= 0.5 / 25 + 1e-9)
    #expect(onGrid(p.transitions[0].duration, 25) && p.transitions[0].duration > 0)
    #expect(p.markers.allSatisfy { onGrid($0.time, 25) && onGrid($0.duration ?? 0, 25) })
    #expect(onGrid(p.captions.edits[0].startOffset ?? 0, 25))
    #expect(abs(p.duration - before.duration) < 0.5 / 25)
    try p.validate()
    for tr in p.transitions { try p.checkTransition(tr) }
    // Already on the grid: nothing moves.
    var again = p
    #expect(again.conformFrameRate(from: 25).moved == 0)
    #expect(again == p)
}

@Test func keepingFrameCountsRetimesTheEdit() throws {
    var p = project24()
    let before = p
    p.canvas.fps = 25
    let report = p.conformFrameRate(from: 24, mode: .keepFrames)
    #expect(report.mode == .keepFrames && abs(report.newDuration - 720.0 / 25) < 1e-9, "\(report.summary)")
    for (a, b) in zip(before.tracks[0].clips, p.tracks[0].clips) {
        #expect(Int((b.start * 25).rounded()) == Int((a.start * 24).rounded()) && Int((b.duration * 25).rounded()) == Int((a.duration * 24).rounded()))
        #expect(b.sourceIn == a.sourceIn && Int((b.audioLead * 25).rounded()) == Int((a.audioLead * 24).rounded()))
    }
    #expect(Int((p.markers[0].time * 25).rounded()) == 77)
    try p.validate()
}

@Test func broadcastCheckDescribesTheConform() {
    let p = project24()
    let issues = Platform.named("broadcast_eu")!.check(p)
    let rate = issues.first { $0.contains("fps") } ?? ""
    #expect(rate.contains("canvas_set fps:25") && rate.contains("keep_frames") && !rate.contains("re-times cuts"))
}
