import Foundation
import Testing
@testable import CutlineCore

@Test func unseenHumanCountsNewNotesAndNewRepliesOnce() {
    var file = CommentsFile(comments: [
        Comment(id: "c1", time: 2, text: "Tighten", author: .human),
        Comment(id: "c2", time: 1, text: "Question for you", author: .agent),
        Comment(id: "c3", time: 3, text: "Done", author: .human, status: .resolved),
    ])
    #expect(file.unseenHuman([]).map(\.id) == ["c1"])
    let seen = Set(file.humanMarks.map(\.key))
    #expect(file.unseenHuman(seen).isEmpty)

    file.comments[1].replies.append(CommentReply(id: "r1", author: .human, text: "Keep it"))
    #expect(file.unseenHuman(seen).map(\.id) == ["c2"])
    file.comments[0].replies.append(CommentReply(id: "r2", author: .agent, text: "Tightened"))
    #expect(file.unseenHuman(seen.union(["r1"])).isEmpty)
    file.comments[0].replies.append(CommentReply(id: "r3", author: .human, text: "Still long"))
    #expect(file.unseenHuman(seen.union(["r1"])).map(\.id) == ["c1"])
    #expect(file.awaitingReply.map(\.id) == ["c2", "c1"])
}

@Test func presenceRoundTripsAndDiesWithItsProcess() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-presence-\(UUID().uuidString).cutline")
    try ProjectBundle.create(at: dir, project: Project(name: "P"))
    defer { try? FileManager.default.removeItem(at: dir) }
    let b = ProjectBundle(url: dir)
    #expect(b.loadPresence() == nil)
    b.writePresence(AgentPresence(pid: ProcessInfo.processInfo.processIdentifier, listening: true))
    #expect(b.loadPresence()?.isLive == true)
    b.writePresence(AgentPresence(pid: 999_999, listening: true))
    #expect(b.loadPresence()?.isLive == false)
    b.writePresence(AgentPresence(pid: ProcessInfo.processInfo.processIdentifier, listening: true, updatedAt: Date().addingTimeInterval(-600)))
    #expect(b.loadPresence()?.isLive == false)
    b.writePresence(AgentPresence(pid: ProcessInfo.processInfo.processIdentifier, listening: false, working: ["c1"]))
    #expect(b.loadPresence()?.workingNotes() == ["c1"])
    b.writePresence(nil)
    #expect(b.loadPresence() == nil)
}
