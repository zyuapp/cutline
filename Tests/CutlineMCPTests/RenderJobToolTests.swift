import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

private func project(_ tag: String, seconds: Double) async throws -> (Toolbox, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let png = dir.appendingPathComponent("still.png")
    try writePNG(png)
    let box = Toolbox()
    #expect(!(await box.call("project_create", ["path": .string(dir.appendingPathComponent("p").path), "open_preview": false])).isError)
    #expect(!(await box.call("media_import", ["paths": [.string(png.path)], "analyze": false])).isError)
    let add = await box.call("clip_add", ["media_id": "still", "duration": .number(seconds)])
    #expect(!add.isError, "\(add.plainText)")
    return (box, dir)
}

private func waitForJob(_ box: Toolbox, _ id: String, seconds: Double = 600) async -> String {
    let deadline = Date().addingTimeInterval(seconds)
    var text = ""
    while Date() < deadline {
        text = (await box.call("analysis_read", ["what": "jobs"])).plainText
        if let line = text.split(separator: "\n").first(where: { $0.contains(id + " ") }), !line.contains(": running") { return text }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    return text
}

@Test func backgroundExportReturnsAJobAndReportsWhenDone() async throws {
    let (box, dir) = try await project("bgexport", seconds: 2)
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("bg.mp4")
    let started = await box.call("export", ["path": .string(out.path), "background": true])
    #expect(!started.isError && started.plainText.contains("Started render1"), "\(started.plainText)")
    let status = await box.call("project_status", [:])
    #expect(status.plainText.contains("render1"), "\(status.plainText)")
    let jobs = await waitForJob(box, "render1")
    #expect(jobs.contains("render1 export bg.mp4: done") && jobs.contains("Exported \(out.path)"), "\(jobs)")
    #expect(FileManager.default.fileExists(atPath: out.path))
    let again = await box.call("analysis_read", ["cancel": "render1"])
    #expect(again.plainText.contains("already done"), "\(again.plainText)")
    let unknown = await box.call("analysis_read", ["cancel": "render9"])
    #expect(unknown.isError)
}

@Test func cancelledBackgroundExportLeavesNoFile() async throws {
    let (box, dir) = try await project("bgcancel", seconds: 120)
    defer { try? FileManager.default.removeItem(at: dir) }
    let out = dir.appendingPathComponent("long.mov")
    let started = await box.call("export", ["path": .string(out.path), "preset": "prores_hq", "background": true])
    #expect(started.plainText.contains("Started render1"), "\(started.plainText)")
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let cancelled = await box.call("analysis_read", ["cancel": "render1"])
    #expect(cancelled.plainText.contains("Cancelled render1"), "\(cancelled.plainText)")
    let jobs = await box.call("analysis_read", ["what": "jobs"])
    #expect(jobs.plainText.contains("render1 export long.mov: cancelled"), "\(jobs.plainText)")
    var gone = false
    for _ in 0..<100 where !gone {
        gone = !FileManager.default.fileExists(atPath: out.path)
        if !gone { try await Task.sleep(nanoseconds: 200_000_000) }
    }
    #expect(gone, "a cancelled export removes its partial file")
}

@Test func backgroundRefusesVariants() async throws {
    let (box, dir) = try await project("bgvariants", seconds: 1)
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("export", ["background": true, "variants": [["name": "a", "ops": []]]])
    #expect(r.isError && r.plainText.contains("foreground"), "\(r.plainText)")
}

@Test func stalledWorkIsAbandonedAfterTheLimit() async throws {
    let started = Date()
    await #expect(throws: RenderStalled.self) {
        _ = try await RenderJobs.watched("stuck", limit: 0.5) { () async throws -> Int in
            // Never resumes and ignores cancellation, like a writer that stopped calling back.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            return 1
        }
    }
    #expect(Date().timeIntervalSince(started) < 240)
    let beating = Heartbeat()
    let finished = Flag(), slept = Flag()
    // Beats come from a thread, as writer callbacks do, until the render returns.
    Thread.detachNewThread {
        let start = Date()
        while !finished.isSet, Date().timeIntervalSince(start) < 300 {
            Thread.sleep(forTimeInterval: 0.05)
            beating.beat()
            if Date().timeIntervalSince(start) > 2.5 { slept.set() }
        }
    }
    defer { finished.set() }
    let value = try await RenderJobs.watched("slow but alive", limit: 1, heartbeat: beating) { () async throws -> Int in
        while !slept.isSet { try await Task.sleep(nanoseconds: 50_000_000) }
        return 7
    }
    #expect(value == 7, "work that keeps beating runs past the limit")
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

@Test func slipOnDetachedSoundKeepsPictureInSyncThroughTools() async throws {
    let (box, dir) = try await project("slip", seconds: 2)
    defer { try? FileManager.default.removeItem(at: dir) }
    // A still has no sound to detach, so link a second picture clip instead; slip still moves both.
    let add = await box.call("clip_add", ["media_id": "still", "duration": 2, "track": "new"])
    #expect(!add.isError, "\(add.plainText)")
    let p = try box.session.project()
    let ids = p.tracks.flatMap(\.clips).map(\.id)
    #expect(ids.count == 2)
    let link = await box.call("clip_update", ["clip_id": .string(ids[0]), "link": [.string(ids[1])]])
    #expect(!link.isError, "\(link.plainText)")
    let resync = await box.call("clip_update", ["clip_id": .string(ids[0]), "resync": true])
    #expect(resync.plainText.contains("already in sync"), "\(resync.plainText)")
}
