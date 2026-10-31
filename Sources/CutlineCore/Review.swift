import Foundation

extension CommentsFile {
    /// What the human last said on each open note: their latest reply, or the note itself when they wrote it.
    /// Keyed by that note or reply id, so a new reply on an old note counts as new.
    public var humanMarks: [(key: String, comment: Comment)] {
        comments.filter { $0.status == .open }.compactMap { c in
            if let r = c.replies.last(where: { $0.author == .human }) { return (r.id, c) }
            return c.author == .human ? (c.id, c) : nil
        }
    }

    /// Open notes with something from the human the agent hasn't seen, oldest first.
    public func unseenHuman(_ seen: Set<String>) -> [Comment] {
        humanMarks.filter { !seen.contains($0.key) }.map(\.comment).sorted { $0.time < $1.time }
    }

    /// Open notes where the human spoke last, so the agent still owes a reply, oldest first.
    public var awaitingReply: [Comment] {
        comments.filter { $0.status == .open && ($0.replies.last?.author ?? $0.author) == .human }.sorted { $0.time < $1.time }
    }
}

/// The notes the preview pins when the human finishes reviewing.
public enum ReviewDone {
    public static let text = "Looks good. I'm done reviewing for now."
    public static let exportText = "Looks good. Export it."
}

/// What the agent is doing about the human's notes, written by the MCP server to `agent.json` for the preview.
public struct AgentPresence: Codable, Equatable, Sendable {
    public var pid: Int32
    /// Waiting for the next note.
    public var listening: Bool
    /// Notes the agent picked up and hasn't answered yet.
    public var working: [String]
    public var updatedAt: Date

    public init(pid: Int32, listening: Bool, working: [String] = [], updatedAt: Date = Date()) {
        self.pid = pid
        self.listening = listening
        self.working = working
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        listening = try c.decode(Bool.self, forKey: .listening)
        working = try c.decodeIfPresent([String].self, forKey: .working) ?? []
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    var processAlive: Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// True while the writing process is alive and has said it is listening in the last three minutes.
    public var isLive: Bool { listening && Date().timeIntervalSince(updatedAt) < 180 && processAlive }

    /// Notes being worked on, while the writer is alive and picked them up in the last 20 minutes.
    public func workingNotes(now: Date = Date()) -> [String] {
        guard !working.isEmpty, now.timeIntervalSince(updatedAt) < 1200, processAlive else { return [] }
        return working
    }
}

extension ProjectBundle {
    public var presenceURL: URL { url.appendingPathComponent("agent.json") }

    public func loadPresence() -> AgentPresence? {
        guard let data = try? Data(contentsOf: presenceURL) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(AgentPresence.self, from: data)
    }

    public func writePresence(_ p: AgentPresence?) {
        guard let p else { try? FileManager.default.removeItem(at: presenceURL); return }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try? e.encode(p).write(to: presenceURL, options: .atomic)
    }
}

/// The latest export, written by the MCP server to `export.json` so a preview that opens later still shows it.
public struct ExportRecord: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case started, finished, failed }
    public var state: State
    public var path: String
    public var pid: Int32
    public var historyId: String?
    public var updatedAt: Date

    public init(state: State, path: String, pid: Int32, historyId: String?, updatedAt: Date = Date()) {
        self.state = state
        self.path = path
        self.pid = pid
        self.historyId = historyId
        self.updatedAt = updatedAt
    }

    /// A started export whose server is still alive.
    public var isLive: Bool { state != .started || kill(pid, 0) == 0 || errno == EPERM }

    /// The export was made from the timeline as it is now.
    public func isCurrent(history: History) -> Bool { historyId == history.current?.id }
}

extension ProjectBundle {
    public var exportRecordURL: URL { url.appendingPathComponent("export.json") }

    public func loadExportRecord() -> ExportRecord? {
        guard let data = try? Data(contentsOf: exportRecordURL) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(ExportRecord.self, from: data)
    }

    public func writeExportRecord(_ r: ExportRecord) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try? e.encode(r).write(to: exportRecordURL, options: .atomic)
    }
}
