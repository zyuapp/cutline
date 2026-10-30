import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// An open 320×180 project with three butted still clips on V1 and a tone on A1.
private func openProject(_ extra: (inout Project) -> Void = { _ in }) async throws -> (Toolbox, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-r9-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writePNG(dir.appendingPathComponent("img.png"))
    try writeTone(dir.appendingPathComponent("tone.caf"))
    var p = Project(name: "Round9", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.canvasSet = true
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("img.png"), id: "img"), try await MediaProbe.probe(dir.appendingPathComponent("tone.caf"), id: "tone")]
    p.tracks[0].clips = (0..<3).map { Clip(id: "c\($0)", kind: .media, mediaId: "img", start: Double($0), duration: 1) }
    p.tracks[1].clips = [Clip(id: "talk", kind: .media, mediaId: "tone", start: 0, duration: 3)]
    extra(&p)
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, dir)
}

@Test func speedChangesKeepButtedClipsButted() async throws {
    let (box, dir) = try await openProject { p in
        p.media.append(MediaAsset(id: "cam", path: "/tmp/cam.mov", name: "cam", duration: 30, width: 320, height: 180, fps: 30, hasVideo: true, hasAudio: false))
        p.tracks[0].clips = [Clip(id: "a", kind: .media, mediaId: "cam", start: 0, duration: 3), Clip(id: "b", kind: .media, mediaId: "cam", start: 3, duration: 2, sourceIn: 10)]
    }
    defer { try? FileManager.default.removeItem(at: dir) }
    let fast = await box.call("clip_update", ["clip_id": "a", "speed": 1.5])
    #expect(!fast.isError && fast.plainText.contains("Later clips on V1 moved 1.00s earlier"), "\(fast.plainText)")
    #expect(try box.session.project().clip("b")?.start == 2)
    let slow = await box.call("clip_update", ["clip_id": "a", "speed": 1])
    #expect(!slow.isError && slow.plainText.contains("moved 1.00s later"), "\(slow.plainText)")
    #expect(try box.session.project().clip("b")?.start == 3)
    let gap = await box.call("clip_update", ["clip_id": "a", "speed": 1.5, "ripple": false])
    #expect(!gap.isError && gap.plainText.contains("leaves a 1.00s gap") && gap.plainText.contains("ripple:true closes it"), "\(gap.plainText)")
    #expect(try box.session.project().clip("b")?.start == 3)
}

@Test func matchColorSaysWhyThereIsNothingToMatch() async throws {
    let (box, dir) = try await openProject { p in p.tracks[0].clips = [p.tracks[0].clips[0]] }
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("recipe", ["name": "match_color", "args": ["reference": "c0", "track": "V1"]])
    #expect(r.isError && r.plainText.contains("track V1 has only the reference clip c0"), "\(r.plainText)")
}

@Test func maskPointsGivenAsAListAreStoredAsPoints() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("effect_add", ["target": "c0", "type": "mask.shape", "params": ["points": [[0.1, 0.1], [0.9, 0.1], [0.5, 0.9]]]])
    #expect(!r.isError, "\(r.plainText)")
    #expect(try box.session.project().clip("c0")?.effects.first?.params["points"] == .string("0.1,0.1 0.9,0.1 0.5,0.9"))
    let bad = await box.call("effect_add", ["target": "c1", "type": "mask.shape", "params": ["points": "a triangle"]])
    #expect(bad.isError && bad.plainText.contains("\"x,y x,y …\""), "\(bad.plainText)")
    let wrong = await box.call("param_set", ["target": "c0", "set": ["fx.shape1.invert": "yes"]])
    #expect(wrong.isError && wrong.plainText.contains("true or false"), "\(wrong.plainText)")
}

@Test func soundDetachesToALinkedClipAndBack() async throws {
    let (box, dir) = try await openProject { p in
        p.media.append(MediaAsset(id: "cam", path: "/tmp/cam.mov", name: "cam", duration: 30, width: 320, height: 180, fps: 30, hasVideo: true, hasAudio: true))
        var pic = Clip(id: "pic", kind: .media, mediaId: "cam", start: 3, duration: 2, sourceIn: 5)
        pic.audioLag = 1
        p.tracks[0].clips.append(pic)
        p.tracks[1].clips = []
    }
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("clip_update", ["clip_id": "pic", "detach_audio": true])
    #expect(!r.isError && r.plainText.contains("Detached pic's sound to") && r.plainText.contains("lags 1.00s"), "\(r.plainText)")
    let p = try box.session.project()
    let sound = try #require(p.tracks.filter { $0.kind == .audio }.flatMap(\.clips).first { $0.mediaId == "cam" })
    #expect(sound.start == 3 && sound.duration == 3 && sound.link != nil && sound.link == p.clip("pic")?.link)
    #expect(p.clip("pic")?.volume == 0)
    let back = await box.call("clip_update", ["clip_id": .string(sound.id), "attach_audio": true])
    #expect(!back.isError && back.plainText.contains("as a split edit"), "\(back.plainText)")
    #expect(try box.session.project().clip("pic")?.audioLag == 1)
}

@Test func perTrackLoudnessIncludesNestedTracks() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let nest = await box.call("sequence_nest", ["clips": ["talk"]])
    #expect(!nest.isError, "\(nest.plainText)")
    let m = await box.call("timeline_measure", ["what": ["sound"], "tracks": true])
    #expect(!m.isError && m.plainText.contains("  A1 \""), "\(m.plainText)")
}

@Test func aVariantsPathPicksItsContainer() async throws {
    let (box, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("export", ["path": .string(dir.appendingPathComponent("base.mov").path), "container": "mov", "end": 1,
                                      "variants": [["name": "web", "path": .string(dir.appendingPathComponent("web.mp4").path)]]])
    #expect(!r.isError, "\(r.plainText)")
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("web.mp4").path), "\(r.plainText)")
}

@Test func identicalPendingJobsAreQueuedOnce() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-jobs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // Another runner holds the worker lock, so the jobs stay queued.
    let other = try #require(FileLock(dir.appendingPathComponent(".worker.lock"), wait: false))
    defer { other.release() }
    let board = JobBoard()
    board.attach(dir, run: false)
    let first = board.enqueue("m", [.transcript, .shots], bundle: dir)
    #expect(board.enqueue("m", [.shots, .transcript], bundle: dir) == first)
    #expect(board.enqueue("m", [.transcript, .shots], bundle: dir, explicit: true) == first)
    #expect(board.all.count == 1 && board.all.first?.explicit == true)
    #expect(board.enqueue("m", [.sounds], bundle: dir) != first)
    #expect(board.enqueue("other", [.transcript, .shots], bundle: dir) != first)
    #expect(board.all.count == 3)
}
