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
    for (tool, args) in [("recipe", ["name": "template", "args": ["values": ["anything": "x"]]] as JSON),
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

/// Jobs a runner ran, in order, with the steps they had already finished.
private final class Ran: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(id: String, done: [String])] = []
    func add(_ id: String, _ done: [String]) { lock.withLock { list.append((id, done)) } }
    var all: [(id: String, done: [String])] { lock.withLock { list } }
}

@Test func oneRunnerContinuesWhatAnotherLeft() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var stale = JobBoard.Job(id: "job2", mediaId: "a", features: ["transcript", "shots"], status: "running", progress: 0.4, pid: 999_999)
    stale.done = ["transcript"]
    stale.notes = ["transcript: 3 words"]
    let jobs: [JobBoard.Job] = [
        .init(id: "job1", mediaId: "a", features: ["shots"], status: "done", progress: 1),
        stale,
        .init(id: "job3", mediaId: "b", features: ["sounds"], status: "queued", progress: 0),
    ]
    try JSONEncoder().encode(jobs).write(to: dir.appendingPathComponent("jobs.json"))
    let ran = Ran()
    let board = JobBoard()
    board.factory = { ctx in
        { ran.add(ctx.job.id, ctx.job.done ?? []); ctx.finished("shots", ["shots: fine"]); ctx.progress(0.2); return "ok" }
    }
    // Another runner holds the worker lock: nothing runs here until it lets go.
    let other = try #require(FileLock(dir.appendingPathComponent(".worker.lock"), wait: false))
    #expect(board.attach(dir).map(\.id) == ["job2", "job3"])
    try await Task.sleep(nanoseconds: 600_000_000)
    #expect(ran.all.isEmpty)
    #expect(board.active.count == 2)
    other.release()
    #expect(await board.wait(timeout: 30))
    #expect(ran.all.map(\.id) == ["job2", "job3"])
    #expect(ran.all.first?.done == ["transcript"])
    let saved = try JSONDecoder().decode([JobBoard.Job].self, from: Data(contentsOf: dir.appendingPathComponent("jobs.json")))
    #expect(saved.allSatisfy { $0.status == "done" })
    let two = try #require(saved.first { $0.id == "job2" })
    #expect(two.done == ["transcript", "shots"] && two.notes == ["transcript: 3 words", "shots: fine"] && two.progress == 1)
    #expect(two.message?.contains("ok") == true)
    #expect(board.enqueue("d", [.sounds], bundle: dir) == "job4")
}

/// The debug cutline-mcp next to the test bundle, when it was built.
private func builtServer() -> URL? {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return [".build/debug/cutline-mcp", ".build/arm64-apple-macosx/debug/cutline-mcp"].map { root.appendingPathComponent($0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

@Test func detachedWorkerFinishesJobsWithoutTheServer() async throws {
    guard let exe = builtServer() else { return }
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = dir.appendingPathComponent("tone.caf")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: audio, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    for i in 0..<48_000 { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
    try file.write(from: buffer)
    var project = Project(name: "Worker")
    project.media = [try await MediaProbe.probe(audio, id: "tone")]
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("w.cutline"), project: project)
    let queued = [JobBoard.Job(id: "job1", mediaId: "tone", features: ["sounds"], status: "queued", progress: 0, explicit: true)]
    try JSONEncoder().encode(queued).write(to: bundle.url.appendingPathComponent("jobs.json"))

    #expect(JobBoard.spawnWorker(exe, bundle: bundle.url))
    let board = JobBoard()
    board.attach(bundle.url, run: false)
    let deadline = Date().addingTimeInterval(120)
    while board.all.contains(where: \.isPending), Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
    let job = try #require(board.all.first)
    #expect(job.status == "done", "\(job)")
    #expect(job.pid != nil && job.pid != ProcessInfo.processInfo.processIdentifier)
    #expect(bundle.analysis(SoundEvents.self, "tone", "sounds") != nil)
    // A second worker for a bundle with nothing pending exits at once.
    #expect(JobBoard.spawnWorker(exe, bundle: bundle.url))
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
