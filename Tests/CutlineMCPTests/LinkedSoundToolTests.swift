import CutlineCore
@testable import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// An open project with a 440 Hz tone as picture clips "pic" (0–1.5 s) and "mute" (1.5–2.5 s, muted, nothing linked) on V1.
private func openProject() async throws -> (Toolbox, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-linked-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Bursts of 440 Hz with pauses between, like lines of dialogue.
    let burst = (0..<144_000).map { i -> Float in (i / 16_800) % 2 == 0 ? Float(0.2 * sin(2 * Double.pi * 440 * Double(i) / 48_000)) : 0 }
    try AudioDSP.write([burst], sampleRate: 48_000, to: dir.appendingPathComponent("tone.caf"))
    var p = Project(name: "Linked", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.canvasSet = true
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("tone.caf"), id: "tone")]
    var mute = Clip(id: "mute", kind: .media, mediaId: "tone", start: 1.5, duration: 1, sourceIn: 1.5)
    mute.volume = 0
    p.tracks[0].clips = [Clip(id: "pic", kind: .media, mediaId: "tone", start: 0, duration: 1.5), mute]
    p.tracks[1].clips = []
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, dir)
}

@Test func gainRideOnATrackRidesDetachedSoundAndSkipsSilentClips() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!(await box.call("clip_update", ["clip_id": "pic", "detach_audio": true])).isError)
    let sound = try #require(box.session.project().linked("pic").first)
    let r = await box.call("recipe", ["name": "clip_gain_ride", "args": ["track": "V1", "target_lufs": -30]])
    #expect(!r.isError, "\(r.plainText)")
    #expect(r.plainText.contains("pic is muted; rode its linked sound \(sound) instead") && r.plainText.contains("mute is muted and has no linked sound; skipped"), "\(r.plainText)")
    let p = try box.session.project()
    #expect(p.clip("pic")?.volume == 0 && (p.clip(sound)?.volume ?? 1) < 0.9, "the sound clip is ridden down to −30 LUFS")
}

@Test func syncLockIsSetPerTrackAndReported() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!(await box.call("clip_add", ["media_id": "tone", "track": "A1", "start": 0, "duration": 2.5])).isError)
    let off = await box.call("track_update", ["track": "A1", "sync_lock": false])
    #expect(!off.isError, "\(off.plainText)")
    #expect(try box.session.project().tracks[1].syncLock == false)
    #expect((await box.call("project_status", [:])).plainText.contains("sync lock off"))
    let ins = await box.call("clip_add", ["media_id": "tone", "track": "V1", "start": 0.5, "duration": 0.5, "mode": "insert"])
    #expect(!ins.isError && ins.plainText.contains("A1 (sync lock off) left in place"), "\(ins.plainText)")
    #expect(try box.session.project().tracks[1].clips.map(\.duration) == [2.5])
    #expect(!(await box.call("track_update", ["track": "A1", "sync_lock": true])).isError)
    let again = await box.call("clip_add", ["media_id": "tone", "track": "V1", "start": 0.5, "duration": 0.5, "mode": "insert"])
    #expect(again.plainText.contains("A1: split"), "\(again.plainText)")
}
