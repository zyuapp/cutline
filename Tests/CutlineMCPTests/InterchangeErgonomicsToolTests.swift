import CutlineCore
@testable import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// An open project with a 3 s tone ("tone") and, when asked, a multicam clip "mc" of two offline cameras on V1.
private func openProject(multicam: Bool = false) async throws -> (Toolbox, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-ergo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writeTone(dir.appendingPathComponent("tone.caf"))
    var p = Project(name: "Ergo", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.canvasSet = true
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("tone.caf"), id: "tone")]
    p.tracks[0].clips = []
    p.tracks[1].clips = []
    if multicam {
        p.media += ["camA", "camB"].map { MediaAsset(id: $0, path: "/tmp/\($0).mov", name: $0, duration: 60, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true) }
        let seq = try p.createMulticam(name: "Talk", angles: [("A", "camA", 0), ("B", "camB", 0)], audio: ["A"], sync: "marker")
        var c = Clip(id: "mc", kind: .sequence, name: "Talk", mediaId: seq.id, start: 0, duration: 40, sourceIn: 0)
        c.multicam = MulticamSwitch(cuts: [AngleCut(at: 0, angle: "A"), AngleCut(at: 22.17, angle: "B")])
        p.tracks[0].clips = [c]
    }
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, dir)
}

@Test func assembleTakesATopLevelMediaIdForItsSegments() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("assemble", ["media_id": "tone", "segments": [["start": 0, "end": 1], ["start": 2, "end": 2.5], ["media": "tone", "start": 1, "end": 1.5]]])
    #expect(!r.isError, "\(r.plainText)")
    #expect(try box.session.project().tracks[0].clips.map(\.mediaId) == ["tone", "tone", "tone"])
    let missing = await box.call("assemble", ["segments": [["start": 0, "end": 1]]])
    #expect(missing.isError)
}

@Test func timelinesSwitchIgnoresCase() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!(await box.call("timelines", ["action": "new", "name": "Vertical"])).isError)
    let r = await box.call("timelines", ["action": "switch", "name": "main"])
    #expect(!r.isError && r.plainText.contains("Current timeline: Main"), "\(r.plainText)")
}

@Test func audioBusTakesIdAndDecibelKeys() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let add = await box.call("audio_bus", ["id": "MUS", "volume_db_keys": [[0, -6], [2, 0]]])
    #expect(!add.isError, "\(add.plainText)")
    var keys = try #require(try box.session.project().bus("MUS")?.volumeCurve?.keys)
    #expect(keys.compactMap(\.v.number).map { ($0 * 1000).rounded() / 1000 } == [0.501, 1])
    let suffixed = await box.call("audio_bus", ["bus": "MUS", "volume_keys": [[0, "-12dB"], [1, 1]]])
    #expect(!suffixed.isError, "\(suffixed.plainText)")
    keys = try #require(try box.session.project().bus("MUS")?.volumeCurve?.keys)
    #expect(keys.compactMap(\.v.number).map { ($0 * 1000).rounded() / 1000 } == [0.251, 1])
    let unit = await box.call("audio_bus", ["name": "MUS", "unit": "db", "volume_keys": [["t": 0, "v": -20]]])
    #expect(!unit.isError, "\(unit.plainText)")
    keys = try #require(try box.session.project().bus("MUS")?.volumeCurve?.keys)
    #expect(keys.compactMap(\.v.number).map { ($0 * 1000).rounded() / 1000 } == [0.1])
}

@Test func soundRollIsLabelledInHistory() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(!(await box.call("clip_add", ["media_id": "tone", "track": "V1", "start": 0, "duration": 1.5, "as": "a"])).isError)
    #expect(!(await box.call("clip_add", ["media_id": "tone", "track": "V1", "start": 1.5, "duration": 1, "source_in": 1.5, "as": "b"])).isError)
    let ids = try box.session.project().tracks[0].clips.map(\.id)
    let r = await box.call("trim", ["clip_id": .string(ids[0]), "part": "audio", "edge": "end", "by": 0.5])
    #expect(!r.isError, "\(r.plainText)")
    let label = box.session.bundle?.loadHistory().current?.label
    #expect(label == "Roll sound cut \(ids[0])|\(ids[1]) by +0.50s", "\(label ?? "")")
}

@Test func multicamCutReportsSliversAndSwitchFindsTheOnlyMulticam() async throws {
    let (box, dir) = try await openProject(multicam: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let cut = await box.call("multicam_cut", ["clip": "mc", "from": 20, "to": 22, "angle": "B"])
    #expect(!cut.isError && cut.plainText.contains("plays angle 1 A for only 0.17s"), "\(cut.plainText)")
    let r = await box.call("recipe", ["name": "multicam_switch", "args": [:]])
    #expect(!r.plainText.contains("Pass clip"), "\(r.plainText)")
}

@Test func catalogListsTheBezierEase() async {
    let box = Toolbox()
    #expect((await box.call("catalog", [:])).plainText.contains("bezier(x1, y1, x2, y2)"))
    let found = await box.call("catalog", ["search": "graph editor"])
    #expect(found.plainText.contains("bezier("), "\(found.plainText)")
}
