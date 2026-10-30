import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// An open project with a still on V1 and one transcribed sound on A1 ("Interview") and, from later in the file,
/// on A2 ("Room tone") under the first line.
private func openProject(fps: Double = 30, _ body: (inout Project) -> Void = { _ in }) async throws -> (Toolbox, ProjectBundle, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-surface-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writePNG(dir.appendingPathComponent("img.png"))
    try writeTone(dir.appendingPathComponent("tone.caf"))
    var p = Project(name: "Surface", canvas: Canvas(width: 320, height: 180, fps: fps))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("img.png"), id: "img"), try await MediaProbe.probe(dir.appendingPathComponent("tone.caf"), id: "tone")]
    p.tracks[0].clips = [Clip(id: "pic", kind: .media, mediaId: "img", start: 0, duration: 3)]
    p.tracks[1].name = "Interview"
    p.tracks[1].clips = [Clip(id: "talk1", kind: .media, mediaId: "tone", start: 0, duration: 1.5), Clip(id: "talk2", kind: .media, mediaId: "tone", start: 1.5, duration: 1.5, sourceIn: 1.5)]
    p.tracks.append(Track(id: "A2", kind: .audio, name: "Room tone", clips: [Clip(id: "amb", kind: .media, mediaId: "tone", start: 0, duration: 1.5, sourceIn: 1.5)]))
    body(&p)
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    try b.saveTranscript(Transcript(mediaId: "tone", locale: "en-US", words: [
        Word(text: "Hello", start: 0.2, end: 0.6), Word(text: "there.", start: 0.7, end: 1.2), Word(text: "Next", start: 1.7, end: 2.1), Word(text: "part.", start: 2.2, end: 2.6),
    ]))
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, b, dir)
}

@Test func timelineTranscriptReadsDialogueTracksWithOneHeaderPerClip() async throws {
    let (box, _, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("timeline_transcript", [:])
    let text = r.plainText
    #expect(!text.contains("── amb") && text.contains("Not read: A2 \"Room tone\""), "\(text)")
    #expect(text.components(separatedBy: "── talk1").count == 2 && text.components(separatedBy: "── talk2").count == 2, "\(text)")
    #expect(text.contains("4 words"), "\(text)")
    let all = await box.call("timeline_transcript", ["all_tracks": true])
    #expect(all.plainText.contains("── amb on A2"), "\(all.plainText)")
    #expect(all.plainText.components(separatedBy: "\n").filter { $0.hasPrefix("── ") }.count == Set(all.plainText.components(separatedBy: "\n").filter { $0.hasPrefix("── ") }).count, "headers repeat: \(all.plainText)")
}

@Test func strictExportRefusesWhenThePlatformCheckFails() async throws {
    let (box, b, dir) = try await openProject(fps: 24)
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("out.mov")
    let strict = await box.call("export", ["platform": "broadcast_eu", "strict": true, "path": .string(out.path)])
    #expect(strict.isError && strict.plainText.contains("Not exported") && strict.plainText.contains("fps"), "\(strict.plainText)")
    #expect(!FileManager.default.fileExists(atPath: out.path))
    let noPlatform = await box.call("export", ["strict": true])
    #expect(noPlatform.isError && noPlatform.plainText.contains("strict needs a platform"), "\(noPlatform.plainText)")

    let loose = await box.call("export", ["platform": "broadcast_eu", "path": .string(out.path)])
    #expect(!loose.isError, "\(loose.plainText)")
    let first = loose.plainText.components(separatedBy: "\n").first ?? ""
    #expect(first.contains("check:") && first.contains("exported anyway"), "\(loose.plainText)")
    #expect(loose.plainText.contains("Exported \(out.path)"))
    _ = b
}

@Test func mediaOrganizeSetsTheCameraLog() async throws {
    let (box, _, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("media_organize", ["media_ids": ["img"], "log": "slog3", "signal_range": "full"])
    #expect(!r.isError && r.plainText.contains("log slog3"), "\(r.plainText)")
    var m = try #require(try box.session.project().mediaAsset("img"))
    #expect(m.log == .slog3 && m.signalRange == .full)
    let bad = await box.call("media_organize", ["media_ids": ["img"], "log": "slog9"])
    #expect(bad.isError && bad.plainText.contains("Invalid value 'slog9' for 'log' (did you mean slog3"), "\(bad.plainText)")
    let audio = await box.call("media_organize", ["media_ids": ["tone"], "log": "slog3"])
    #expect(audio.isError && audio.plainText.contains("no picture"), "\(audio.plainText)")
    let old = await box.call("media_analyze", ["media_id": "img", "log": "none"])
    #expect(!old.isError, "\(old.plainText)")
    m = try #require(try box.session.project().mediaAsset("img"))
    #expect(m.log == nil)
}

@Test func projectStatusCountsShotsLikeShotAnalysis() async throws {
    let (box, b, dir) = try await openProject { p in
        p.media[0] = MediaAsset(id: "img", path: p.media[0].path, name: "cam", duration: 30, width: 320, height: 180, fps: 30, hasVideo: true, hasAudio: false)
    }
    defer { try? FileManager.default.removeItem(at: dir) }
    // One cut 20 s in: the 20 s shot splits every 8 s, as shot anchors and shot analysis count them.
    try b.saveVisualAnalysis(VisualAnalysis(mediaId: "img", sceneCuts: [20]))
    let status = await box.call("project_status", [:])
    #expect(status.plainText.contains("\(Shot.spans(cuts: [20], duration: 30).count) shots from 1 scene cuts"), "\(status.plainText)")
}
