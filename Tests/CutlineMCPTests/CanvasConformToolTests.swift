import CutlineCore
@testable import CutlineMCP
import Foundation
import Testing

@Test func canvasSetConformsCutsToTheNewFrameRate() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-conform-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var p = Project(name: "Rate", canvas: Canvas(fps: 24))
    p.media = [MediaAsset(id: "a", path: dir.appendingPathComponent("a.mov").path, name: "a", duration: 60, width: 1920, height: 1080, fps: 24, hasVideo: true, hasAudio: false)]
    p.tracks[0].clips = [
        Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 315.0 / 24),
        Clip(id: "c2", kind: .media, mediaId: "a", start: 315.0 / 24, duration: 282.0 / 24, sourceIn: 20),
    ]
    let url = dir.appendingPathComponent("p.cutline")
    _ = try ProjectBundle.create(at: url, project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(url.path), "open_preview": false])
    let r = await box.call("canvas_set", ["fps": 25])
    #expect(!r.isError && r.plainText.contains("Conformed 24→25 fps") && r.plainText.contains("no gaps or overlaps"), "\(r.plainText)")
    let q = try box.session.project()
    #expect(q.tracks[0].clips.map { ($0.start * 25).rounded() } == [0, 328])
    #expect(q.tracks[0].clips[0].end == q.tracks[0].clips[1].start)

    let kept = await box.call("canvas_set", ["fps": 30, "conform": "keep_frames"])
    #expect(kept.plainText.contains("keeping frame counts"), "\(kept.plainText)")
    #expect(try box.session.project().tracks[0].clips.map { ($0.start * 30).rounded() } == [0, 328])
}
