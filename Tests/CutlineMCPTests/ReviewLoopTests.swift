import CutlineCore
@testable import CutlineMCP
import CutlineUpdate
import Foundation
import Testing

private func makeBox() async throws -> (Toolbox, ProjectBundle, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-review-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let box = Toolbox()
    let r = await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false, "width": 320, "height": 180])
    #expect(!r.isError, "\(r.plainText)")
    return (box, try #require(box.session.bundle), dir)
}

@Test func newNotesRideOnTheNextToolResultOnce() async throws {
    let (box, b, dir) = try await makeBox()
    defer { try? FileManager.default.removeItem(at: dir) }
    try b.updateComments { $0.comments.append(Comment(id: "c_one", time: 1.5, text: "Logo bigger", author: .human)) }
    let first = await box.call("project_status", [:])
    #expect(first.plainText.contains("New from the human in the preview (1): c_one @ 1.50s “Logo bigger”"), "\(first.plainText)")
    let second = await box.call("project_status", [:])
    #expect(!second.plainText.contains("New from the human"), "\(second.plainText)")

    try b.updateComments { $0.comments[0].replies.append(CommentReply(author: .human, text: "Even bigger")) }
    _ = await box.call("comments_list", ["frames": false])
    let third = await box.call("project_status", [:])
    #expect(!third.plainText.contains("New from the human"), "comments_list already showed it: \(third.plainText)")
}

@Test func commentsWaitReturnsTheNoteThatArrivesAndMarksItInHand() async throws {
    let (box, b, dir) = try await makeBox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let wait = Task { await box.call("comments_wait", ["timeout": 300]) }
    try await Task.sleep(nanoseconds: 700_000_000)
    #expect(b.loadPresence()?.isLive == true)
    try b.updateComments { $0.comments.append(Comment(id: "c_two", time: 0.5, text: "Cut this pause", author: .human)) }
    let r = await wait.value
    #expect(!r.isError && r.plainText.contains("1 note(s) waiting for your reply") && r.plainText.contains("c_two"), "\(r.plainText)")
    #expect(b.loadPresence()?.workingNotes() == ["c_two"] && b.loadPresence()?.isLive == false)
    let after = await box.call("project_status", [:])
    #expect(!after.plainText.contains("New from the human"), "\(after.plainText)")

    // Until Claude replies, the note is still owed, so the next wait returns it at once.
    let again = await box.call("comments_wait", ["timeout": 300])
    #expect(again.plainText.contains("c_two"), "\(again.plainText)")
    _ = await box.call("comment_reply", ["comment_id": "c_two", "text": "Cut it"])
    #expect(b.loadPresence() == nil)
}

@Test func notesMentionedInPassingStillReachTheWait() async throws {
    let (box, b, dir) = try await makeBox()
    defer { try? FileManager.default.removeItem(at: dir) }
    try b.updateComments { $0.comments.append(Comment(id: "c_b", time: 2, text: "Louder music", author: .human)) }
    let status = await box.call("project_status", [:])
    #expect(status.plainText.contains("c_b"))
    let r = await box.call("comments_wait", ["timeout": 5])
    #expect(r.plainText.contains("waiting for your reply") && r.plainText.contains("c_b"), "\(r.plainText)")
}

@Test func doneAndExportEndTheReviewWithoutAQuestion() async throws {
    let (box, b, dir) = try await makeBox()
    defer { try? FileManager.default.removeItem(at: dir) }
    try b.updateComments { $0.comments.append(Comment(id: "c_d", time: 1, text: ReviewDone.text, author: .human)) }
    let done = await box.call("comments_wait", ["timeout": 5])
    #expect(done.plainText.contains("done reviewing for now") && done.plainText.contains("stop waiting"), "\(done.plainText)")
    _ = await box.call("comment_reply", ["comment_id": "c_d", "text": "Thanks"])
    try b.updateComments { $0.comments.append(Comment(time: 1, text: ReviewDone.exportText, author: .human)) }
    let export = await box.call("comments_wait", ["timeout": 5])
    #expect(export.plainText.contains("wants it exported") && export.plainText.contains("without asking"), "\(export.plainText)")
}

@Test func exportRecordFollowsTheTimeline() async throws {
    let (box, b, dir) = try await makeBox()
    defer { try? FileManager.default.removeItem(at: dir) }
    _ = await box.call("text_add", ["text": "Hi", "start": 0, "duration": 1])
    try box.session.sendPreview(["action": "export", "state": "finished", "path": "/tmp/out.mp4"])
    let record = try #require(b.loadExportRecord())
    #expect(record.state == .finished && record.path == "/tmp/out.mp4" && record.isCurrent(history: b.loadHistory()))
    _ = await box.call("text_add", ["text": "Again", "start": 1, "duration": 1])
    #expect(!record.isCurrent(history: b.loadHistory()))
}

@Test func commentsWaitStopsWhenCancelledOrTimedOut() async throws {
    let (box, b, dir) = try await makeBox()
    defer { try? FileManager.default.removeItem(at: dir) }
    let timedOut = await box.call("comments_wait", ["timeout": 1])
    #expect(timedOut.plainText.contains("No new notes yet. Call comments_wait again"), "\(timedOut.plainText)")
    let wait = Task { await box.call("comments_wait", ["timeout": 30]) }
    try await Task.sleep(nanoseconds: 300_000_000)
    wait.cancel()
    let r = await wait.value
    #expect(r.plainText.contains("Stopped waiting because Claude Code cancelled"), "\(r.plainText)")
    #expect(b.loadPresence() == nil)
}

@Test func humanIdleCountsPreviewActivityAndNotes() async throws {
    let (_, b, dir) = try await makeBox()
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(Toolbox.humanIdle(b.url) > 1e6)
    let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
    try Data(#"{"pid":1,"updatedAt":"\#(stale)"}"#.utf8).write(to: b.url.appendingPathComponent("preview.json"))
    #expect(abs(Toolbox.humanIdle(b.url) - 3600) < 5)
    try b.updateComments { $0.comments.append(Comment(time: 1, text: "Hi", author: .human)) }
    #expect(Toolbox.humanIdle(b.url) < 5)
}

@Test func stagedUpdateInstallsOnlyWhenNewer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-update-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func makeApp(_ url: URL, version: String) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    let app = root.appendingPathComponent("Cutline.app")
    try makeApp(app, version: "0.1.2")
    #expect(ReleaseUpdate.staged(for: app) == nil)
    try makeApp(root.appendingPathComponent(".cutline-update/0.1.1/Cutline.app"), version: "0.1.1")
    #expect(ReleaseUpdate.staged(for: app) == nil)
    try makeApp(root.appendingPathComponent(".cutline-update/0.1.3/Cutline.app"), version: "0.1.3")
    #expect(ReleaseUpdate.staged(for: app)?.version == "0.1.3")
    #expect(try ReleaseUpdate.install(into: app) == "0.1.3")
    #expect(ReleaseUpdate.version(of: app) == "0.1.3")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".cutline-update/0.1.3").path))
    #expect(try ReleaseUpdate.install(into: app) == nil)
}
