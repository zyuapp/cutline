import CutlineCore
import Foundation
import Testing

private func cameraProject() -> Project {
    var p = Project(name: "Freeze", canvas: Canvas(width: 1920, height: 1080, fps: 25))
    p.media = [MediaAsset(id: "cam", path: "/tmp/cam.mov", name: "cam", duration: 60, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "cam", start: 0, duration: 4), Clip(id: "c2", kind: .media, mediaId: "cam", start: 4, duration: 4, sourceIn: 10)]
    return p
}

@Test func freezeFrameLeavesNoFlashFramePieces() throws {
    let frame = 1.0 / 25
    // Two frames before c1's end: the tail becomes part of the hold.
    var p = cameraProject()
    let note = try p.freezeFrame(at: 4 - 2 * frame, trackId: nil, duration: 1, zoom: 1)
    let v1 = p.tracks[0].clips
    #expect(v1.allSatisfy { $0.duration >= 3 * frame - 1e-6 }, "\(v1.map { ($0.id, $0.duration) })")
    #expect(abs(p.clip("c2")!.start - 5) < 1e-6, "everything after moves by the hold only")
    let held = try #require(v1.first { $0.id != "c1" && $0.id != "c2" })
    #expect(abs(held.start - (4 - 2 * frame)) < 1e-6 && abs(held.end - 5) < 1e-6, "\(held.start)–\(held.end)")
    #expect(note.contains("last 2 frame(s)"), "\(note)")

    // Two frames after c2's start: the freeze starts on c2's first frame.
    var q = cameraProject()
    let moved = try q.freezeFrame(at: 4 + 2 * frame, trackId: nil, duration: 1, zoom: 1)
    #expect(q.tracks[0].clips.allSatisfy { $0.duration >= 3 * frame - 1e-6 }, "\(q.tracks[0].clips.map { ($0.id, $0.duration) })")
    let frozen = try #require(q.tracks[0].clips.first { $0.id != "c1" && $0.id != "c2" })
    #expect(abs(frozen.start - 4) < 1e-6 && abs(frozen.sourceIn - 10) < 1e-6)
    #expect(moved.contains("first frame"), "\(moved)")

    // Mid-clip freezes still split normally.
    var r = cameraProject()
    _ = try r.freezeFrame(at: 2, trackId: nil, duration: 1, zoom: 1)
    #expect(r.tracks[0].clips.count == 4)
}

@Test func negativeSpeedPointsAtReverse() {
    #expect(throws: Never.self) { try Clip.checkSpeed(2) }
    do {
        try Clip.checkSpeed(-1)
        Issue.record("negative speed accepted")
    } catch {
        #expect("\(error)".contains("time.reverse"), "\(error)")
    }
}

@Test func mastersPlanAConformAndSocialTargetsDont() throws {
    var p = Project(name: "Wide", canvas: Canvas(width: 862, height: 360, fps: 24))
    p.master.loudnessTarget = -18
    let us = try #require(Platform.named("broadcast_us"))
    #expect(us.isMastering && Platform.named("netflix_master")!.isMastering && Platform.named("broadcast_uk_dpp")!.isMastering)
    #expect(!Platform.named("youtube")!.isMastering && !Platform.named("tiktok")!.isMastering)
    let plan = us.conformPlan(p)
    #expect(plan.size?.width == 1920 && plan.size?.height == 1080)
    #expect(abs((plan.fps ?? 0) - 30000.0 / 1001) < 1e-9 && plan.loudness == -24 && plan.ceiling == -2)
    #expect(plan.steps.contains { $0.contains("letterboxed") } && plan.steps.contains { $0.contains("nearest frame") }, "\(plan.steps)")
    let delivered = plan.delivered(p)
    #expect(us.check(delivered).isEmpty, "\(us.check(delivered))")
    let rendered = plan.rendered(p)
    #expect(rendered.canvas.width == 862 && rendered.master.loudnessTarget == -24)
    let dpp = Platform.named("broadcast_uk_dpp")!.conformPlan(p)
    #expect(dpp.timecodeStart == "10:00:00:00")
}

@Test func preservingHistoryKeepsUndoAndRedo() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: cameraProject())
    var p = try b.loadProject()
    p.name = "Two"
    try b.commit(p, label: "Two")
    p.name = "Three"
    try b.commit(p, label: "Three")
    _ = try b.undo()
    let before = b.loadHistory()
    #expect(before.canRedo)
    try await b.preservingHistory {
        var v = try b.loadProject()
        v.canvas.width = 1080
        try b.commit(v, label: "Variant")
        try b.commit(v, label: "Variant 2")
    }
    #expect(b.loadHistory() == before)
    #expect(try b.loadProject().name == "Two" && b.loadProject().canvas.width == 1920)
    let (redone, _) = try b.redo()
    #expect(redone.name == "Three" && redone.canvas.width == 1920)
}
