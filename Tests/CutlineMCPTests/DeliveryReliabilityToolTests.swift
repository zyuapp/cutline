import AVFoundation
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// An open project: a still on V1 and a tone on A1, 3 s at 320×180 24 fps.
private func openProject() async throws -> (Toolbox, ProjectBundle, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-reliable-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writePNG(dir.appendingPathComponent("img.png"))
    try writeTone(dir.appendingPathComponent("tone.caf"))
    var p = Project(name: "Reliable", canvas: Canvas(width: 320, height: 180, fps: 24))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("img.png"), id: "img"), try await MediaProbe.probe(dir.appendingPathComponent("tone.caf"), id: "tone")]
    p.tracks[0].clips = [Clip(id: "pic", kind: .media, mediaId: "img", start: 0, duration: 3)]
    p.tracks[1].clips = [Clip(id: "talk", kind: .media, mediaId: "tone", start: 0, duration: 3)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, b, dir)
}

@Test func exportVariantsLeaveUndoAndRedoAlone() async throws {
    let (box, b, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = await box.call("clip_update", ["clip_id": "pic", "duration": 2.5])
    _ = await box.call("history", ["action": "undo"])
    let before = b.loadHistory()
    #expect(before.canRedo)
    let r = await box.call("export", ["path": .string(dir.appendingPathComponent("base.mp4").path), "base": false,
                                      "variants": [["name": "vertical", "path": .string(dir.appendingPathComponent("v.mp4").path), "ops": [["tool": "canvas_set", "args": ["preset": "vertical"]]]]]])
    #expect(!r.isError, "\(r.plainText)")
    #expect(b.loadHistory() == before, "\(b.loadHistory()) vs \(before)")
    let redo = await box.call("history", ["action": "redo"])
    #expect(!redo.isError, "\(redo.plainText)")
    let p = try b.loadProject()
    #expect(p.canvas.width == 320 && abs(p.clip("pic")!.duration - 2.5) < 1e-6, "redo brings back the user's edit, not the variant's")
}

@Test func broadcastExportsRefuseByDefaultAndAutoConformDelivers() async throws {
    let (box, b, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("us.mov")
    let refused = await box.call("export", ["platform": "broadcast_us", "path": .string(out.path)])
    #expect(refused.isError && refused.plainText.contains("Not exported") && refused.plainText.contains("auto_conform:true"), "\(refused.plainText)")
    #expect(!FileManager.default.fileExists(atPath: out.path))

    let social = await box.call("export", ["platform": "tiktok", "path": .string(dir.appendingPathComponent("tt.mp4").path)])
    #expect(!social.isError && social.plainText.contains("exported anyway"), "\(social.plainText)")

    let conformed = await box.call("export", ["platform": "broadcast_us", "auto_conform": true, "path": .string(out.path)])
    #expect(!conformed.isError, "\(conformed.plainText)")
    let text = conformed.plainText
    #expect(text.contains("Auto-conform") && text.contains("scaled 6.00× to 1920×1080") && text.contains("nearest frame") && text.contains("Loudness target -24.0"), "\(text)")
    #expect(text.contains("Broadcast US (ATSC A/85) check: ready."), "\(text)")
    let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    let rate = try await track.load(.nominalFrameRate)
    #expect(size.width == 1920 && size.height == 1080 && abs(Double(rate) - 29.97) < 0.01, "\(size) \(rate)")
    let p = try b.loadProject()
    #expect(p.canvas.width == 320 && p.canvas.fps == 24 && p.master.loudnessTarget == nil, "the project is unchanged")
}

@Test func negativeClipSpeedNamesReverse() async throws {
    let (box, _, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("clip_update", ["clip_id": "talk", "speed": -1])
    #expect(r.isError && r.plainText.contains("time.reverse") && !r.plainText.contains("shorter than one frame"), "\(r.plainText)")
}
