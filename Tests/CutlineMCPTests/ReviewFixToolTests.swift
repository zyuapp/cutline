import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// An open project with eight still clips on V1 and two transcribed sentences on A1.
private func openProject() async throws -> (Toolbox, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-fixes-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writePNG(dir.appendingPathComponent("img.png"))
    try writeTone(dir.appendingPathComponent("tone.caf"))
    var p = Project(name: "Fixes", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("img.png"), id: "img"), try await MediaProbe.probe(dir.appendingPathComponent("tone.caf"), id: "tone")]
    p.tracks[0].clips = (0..<8).map { Clip(id: "c\($0)", kind: .media, mediaId: "img", start: Double($0) * 0.375, duration: 0.375) }
    p.tracks[1].name = "Interview"
    p.tracks[1].clips = [Clip(id: "talk", kind: .media, mediaId: "tone", start: 0, duration: 3)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    try b.saveTranscript(Transcript(mediaId: "tone", locale: "en-US", words: [
        Word(text: "Hello", start: 0.2, end: 0.6), Word(text: "there.", start: 0.7, end: 1.2),
        Word(text: "Next", start: 1.7, end: 2.1), Word(text: "part.", start: 2.2, end: 2.6),
    ]))
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, dir)
}

@Test func everySidecarFormatCountsFromTheFilesFirstFrame() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("master.mov")
    let r = await box.call("export", ["path": .string(out.path), "preset": "prores_proxy", "leader": ["bars": 1, "slate": 1, "black": 2, "pop": false],
                                      "subtitles": "both", "subtitle_formats": ["srt", "imsc", "ebu-tt-d"]])
    #expect(!r.isError, "\(r.plainText)")
    #expect(r.plainText.contains("the 4.00s leader included, in every format"), "\(r.plainText)")
    let srt = try String(contentsOf: dir.appendingPathComponent("master.srt"), encoding: .utf8)
    let first = srt.components(separatedBy: "\n")[1].components(separatedBy: " --> ")[0].replacingOccurrences(of: ",", with: ".")
    #expect(first.hasPrefix("00:00:04."), "\(srt)")
    for name in ["master.imsc.ttml", "master.ebu-tt-d.xml"] {
        let xml = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        #expect(xml.contains("begin=\"\(first)\""), "\(name): \(xml)")
    }
}

@Test func bulkEditsSummarizeIdenticalChanges() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fx = await box.call("effect_add", ["target": "V1/*", "type": "color.wheels", "id": "grade"])
    #expect(!fx.isError, "\(fx.plainText)")
    let head = fx.plainText.components(separatedBy: "\nChanges:")[0]
    #expect(head.components(separatedBy: "\n").count == 1 && head.contains("8 clips on V1 (c0, c1 … c7): added grade (color.wheels)"), "\(head)")
    let set = await box.call("param_set", ["target": "V1/*", "set": ["transform.scale": 1.1]])
    let lines = set.plainText.components(separatedBy: "\nChanges:")[0]
    #expect(lines.components(separatedBy: "\n").count == 1 && lines.contains("8 clips on V1") && lines.contains("transform.scale"), "\(lines)")
    let one = await box.call("param_set", ["target": "c0", "set": ["transform.scale": 1.2]])
    #expect(one.plainText.hasPrefix("c0: transform.scale 1.1→1.2"), "\(one.plainText)")
}

@Test func placingALogoOffFrameIsReported() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let off = await box.call("clip_add", ["media_id": "img", "track": "new", "start": 0, "duration": 2, "set": ["transform.scale": 0.2, "transform.x": 0.85, "transform.y": 0.15]])
    #expect(!off.isError && off.plainText.contains("outside the frame") && off.plainText.contains("transform.pos_x"), "\(off.plainText)")
    let on = await box.call("clip_add", ["media_id": "img", "track": "new", "start": 0, "duration": 2, "set": ["transform.scale": 0.2, "transform.pos_x": 0.85, "transform.pos_y": 0.15]])
    #expect(!on.isError && !on.plainText.contains("outside the frame"), "\(on.plainText)")
    let id = try #require(on.plainText.components(separatedBy: " ").first { $0.hasPrefix("clip_") })
    let status = await box.call("project_status", ["target": .string(id)])
    #expect(status.plainText.contains("transform.pos_x") && status.plainText.contains("0.85"), "\(status.plainText)")
}
