import AVFoundation
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-mcp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: Argument names

@Test func unknownArgumentIsRejectedWithSuggestion() async {
    let box = Toolbox()
    let r = await box.call("clip_add", ["bogus_arg": true, "media_idd": "a"])
    #expect(r.isError)
    #expect(r.plainText.contains("'bogus_arg'"))
    #expect(r.plainText.contains("'media_idd' (did you mean media_id"))
}

@Test func nestedSchemaPropertiesAreChecked() async {
    let box = Toolbox()
    let r = await box.call("assemble", ["segments": [["media_id": "a", "start": 0, "end": 1, "stat": 2]]])
    #expect(r.plainText.contains("'segments[0].stat'"), "\(r.plainText)")
    let leader = await box.call("export", ["leader": ["bars": 30, "tone": true]])
    #expect(leader.plainText.contains("'leader.tone'"), "\(leader.plainText)")
}

@Test func batchOperationsAreCheckedAgainstTheirTool() async {
    let box = Toolbox()
    let ok = await box.call("batch", ["operations": [["tool": "clip_add", "as": "x", "args": ["media_id": "a"]]]])
    #expect(!ok.plainText.contains("doesn't take"), "\(ok.plainText)")
    let bad = await box.call("batch", ["operations": [["tool": "clip_add", "args": ["media_id": "a", "bogus": 1]]]])
    #expect(bad.plainText.contains("'operations[0].args.bogus'") && bad.plainText.contains("for clip_add"), "\(bad.plainText)")
}

@Test func freeFormObjectsAreNotChecked() async {
    let box = Toolbox()
    for (tool, args) in [("recipe", ["name": "duck", "args": ["anything": 1]] as JSON),
                         ("param_set", ["target": "c", "set": ["transform.scale": 2], "dry_run": true]),
                         ("effect_add", ["target": "c", "type": "blur.gaussian", "params": ["radius": 3]]),
                         ("export", ["leader": true, "variants": [["name": "a", "ops": [], "platform": "youtube"]]])] {
        let r = await box.call(tool, args)
        #expect(!r.plainText.contains("doesn't take"), "\(tool): \(r.plainText)")
    }
}

@Test func everyDeclaredArgumentIsAccepted() throws {
    let box = Toolbox()
    for def in box.definitions {
        let name = try #require(def["name"]?.string)
        let props = def["inputSchema"]?["properties"]?.object ?? [:]
        let args = JSON.object(props.mapValues { _ in .null })
        #expect(throws: Never.self, "\(name)") { try box.checkArguments(name, args, schema: def["inputSchema"]!) }
    }
}

// MARK: Jobs

@Test func restoreClaimsJobsOfExitedServersOnly() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let jobs: [JobBoard.Job] = [
        .init(id: "job1", mediaId: "a", features: ["shots"], status: "done", progress: 1),
        .init(id: "job2", mediaId: "a", features: ["shots"], status: "running", progress: 0.4, pid: 111),
        .init(id: "job3", mediaId: "b", features: ["sounds"], status: "queued", progress: 0, pid: 222),
        .init(id: "job4", mediaId: "c", features: ["proxy"], status: "queued", progress: 0),
    ]
    try JSONEncoder().encode(jobs).write(to: dir.appendingPathComponent("jobs.json"))
    let board = JobBoard()
    let claimed = board.restore(bundle: dir) { $0 == 222 }
    #expect(claimed.map(\.id) == ["job2", "job4"])
    #expect(board.active.map(\.id) == ["job2", "job4"])
    #expect(board.all.first { $0.id == "job3" }?.status == "queued")
    let saved = try JSONDecoder().decode([JobBoard.Job].self, from: Data(contentsOf: dir.appendingPathComponent("jobs.json")))
    #expect(saved.first { $0.id == "job2" }?.pid == board.pid)
    #expect(board.enqueue("d", [.sounds], bundle: dir) { _ in "" } == "job5")
}

@Test func openingAProjectResumesUnfinishedAnalysis() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = dir.appendingPathComponent("tone.caf")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: audio, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    for i in 0..<48_000 { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
    try file.write(from: buffer)

    var project = Project(name: "Resume")
    project.media = [try await MediaProbe.probe(audio, id: "tone")]
    let bundleURL = dir.appendingPathComponent("p.cutline")
    let bundle = try ProjectBundle.create(at: bundleURL, project: project)
    let left: [JobBoard.Job] = [
        .init(id: "job1", mediaId: "tone", features: ["sounds"], status: "running", progress: 0.5, pid: 999_999),
        .init(id: "job2", mediaId: "gone", features: ["sounds"], status: "queued", progress: 0, pid: 999_999),
    ]
    try JSONEncoder().encode(left).write(to: bundleURL.appendingPathComponent("jobs.json"))

    let box = Toolbox()
    let opened = await box.call("project_open", ["path": .string(bundleURL.path)])
    #expect(opened.plainText.contains("Resumed analysis"), "\(opened.plainText)")
    let read = await box.call("analysis_read", ["media_id": "tone", "what": "sounds", "wait": 120])
    #expect(!read.isError && !read.plainText.contains("No sound analysis"), "\(read.plainText)")
    #expect(bundle.analysis(SoundEvents.self, "tone", "sounds") != nil)
    #expect(box.session.jobs.all.first { $0.id == "job2" }?.status == "failed")

    let missing = await box.call("analysis_read", ["media_id": "tone", "what": "beats"])
    #expect(missing.plainText.contains("never run") && missing.plainText.contains("start_missing"), "\(missing.plainText)")
}

// MARK: History labels

@Test func historyLabelsDescribeTheChange() throws {
    var p = Project(name: "Labels")
    var clip = Clip(id: "c1", kind: .media, name: "CamL", mediaId: "camr", start: 0, duration: 2)
    clip.effects = [Effect(id: "match", type: "color.adjust")]
    p.tracks[0].clips = [clip]
    p.media = [MediaAsset(id: "camr", path: "/tmp/camr.mov", name: "CamR", duration: 5, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: false, isImage: false)]

    #expect(Toolbox.describeParamSet(Args(["target": "c1", "set": ["time.reverse": true]]), p) == "Reverse CamL")
    #expect(Toolbox.describeParamSet(Args(["target": "c1", "set": ["time.speed": 2]]), p) == "Set speed of CamL")
    #expect(Toolbox.describeParamSet(Args(["target": "c1", "set": ["audio.pan_x": -1]]), p) == "Set surround panning of CamL")
    #expect(Toolbox.describeParamSet(Args(["target": "c1", "unset": ["fx.match.amount"]]), p) == "Reset effect of CamL")
    #expect(Toolbox.describeEffectEdit(Args(["target": "c1", "id": "match", "enabled": false]), p).hasPrefix("Turn off"))
    #expect(Toolbox.describeEffectEdit(Args(["target": "c1", "type": "stylize.vignette"]), p).hasPrefix("Add"))
    #expect(Toolbox.describeUpdate(Args(["clip_id": "c1", "media_id": "camr"]), p) == "Replace CamL with CamR")
}
