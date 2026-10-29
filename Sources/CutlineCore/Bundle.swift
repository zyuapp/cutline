import Foundation

public struct HistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var createdAt: Date

    public init(id: String, label: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
    }
}

public struct History: Codable, Equatable, Sendable {
    public var entries: [HistoryEntry]
    /// Index of the entry `project.json` currently matches.
    public var cursor: Int

    public init(entries: [HistoryEntry] = [], cursor: Int = -1) {
        self.entries = entries
        self.cursor = cursor
    }

    public var current: HistoryEntry? { entries.indices.contains(cursor) ? entries[cursor] : nil }
    public var canUndo: Bool { cursor > 0 }
    public var canRedo: Bool { cursor < entries.count - 1 }
}

/// A `.cutline` directory: the project, its edit history, comments and media analysis.
///
///     project.json    current timeline
///     history.json    entries and cursor; snapshots live in history/<id>.json
///     comments.json   written by both the preview app and the agent under a lock
///     analysis/       per-media transcript, audio and visual analysis
///     exports/        default render destination
public final class ProjectBundle: @unchecked Sendable {
    public static let fileExtension = "cutline"
    public static let historyLimit = 300

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var projectURL: URL { url.appendingPathComponent("project.json") }
    public var historyURL: URL { url.appendingPathComponent("history.json") }
    public var commentsURL: URL { url.appendingPathComponent("comments.json") }
    public var snapshotsURL: URL { url.appendingPathComponent("history", isDirectory: true) }
    public var analysisURL: URL { url.appendingPathComponent("analysis", isDirectory: true) }
    public var exportsURL: URL { url.appendingPathComponent("exports", isDirectory: true) }
    public var cacheURL: URL { url.appendingPathComponent("cache", isDirectory: true) }
    var lockURL: URL { url.appendingPathComponent(".lock") }

    public static func isBundle(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path)
    }

    @discardableResult
    public static func create(at url: URL, project: Project) throws -> ProjectBundle {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("project.json").path) {
            throw EditError("A project already exists at \(url.path)")
        }
        let bundle = ProjectBundle(url: url)
        for dir in [url, bundle.snapshotsURL, bundle.analysisURL, bundle.exportsURL, bundle.cacheURL] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try bundle.write(CommentsFile(), to: bundle.commentsURL)
        try bundle.commit(project, label: "Create project")
        return bundle
    }

    // MARK: Project and history

    /// Older formats decode with defaults for new fields; the next commit writes the current format.
    public func loadProject() throws -> Project {
        var p = try read(Project.self, from: projectURL)
        if p.formatVersion < Project.currentFormat { p.formatVersion = Project.currentFormat }
        return p
    }

    public func loadHistory() -> History {
        (try? read(History.self, from: historyURL)) ?? History()
    }

    @discardableResult
    public func commit(_ project: Project, label: String) throws -> HistoryEntry {
        try project.validate()
        var history = loadHistory()
        if history.cursor < history.entries.count - 1 {
            for dropped in history.entries[(history.cursor + 1)...] { try? FileManager.default.removeItem(at: snapshotURL(dropped.id)) }
            history.entries.removeSubrange((history.cursor + 1)...)
        }
        let entry = HistoryEntry(id: String(format: "h%04d_%@", history.entries.count + 1, String(IDs.make("x").dropFirst(2))), label: label)
        try FileManager.default.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
        try write(project, to: snapshotURL(entry.id))
        history.entries.append(entry)
        history.cursor = history.entries.count - 1
        if history.entries.count > Self.historyLimit {
            let overflow = history.entries.count - Self.historyLimit
            for old in history.entries.prefix(overflow) { try? FileManager.default.removeItem(at: snapshotURL(old.id)) }
            history.entries.removeFirst(overflow)
            history.cursor -= overflow
        }
        try write(project, to: projectURL)
        try write(history, to: historyURL)
        return entry
    }

    /// Moves the history cursor to an entry and restores its snapshot.
    @discardableResult
    public func checkout(_ id: String) throws -> Project {
        var history = loadHistory()
        guard let i = history.entries.firstIndex(where: { $0.id == id }) else { throw EditError("No history entry \(id)") }
        let project = try read(Project.self, from: snapshotURL(id))
        history.cursor = i
        try write(project, to: projectURL)
        try write(history, to: historyURL)
        return project
    }

    public func undo() throws -> (Project, HistoryEntry) {
        let history = loadHistory()
        guard history.canUndo else { throw EditError("Nothing to undo") }
        let undone = history.entries[history.cursor]
        return (try checkout(history.entries[history.cursor - 1].id), undone)
    }

    public func redo() throws -> (Project, HistoryEntry) {
        let history = loadHistory()
        guard history.canRedo else { throw EditError("Nothing to redo") }
        let entry = history.entries[history.cursor + 1]
        return (try checkout(entry.id), entry)
    }

    public func snapshot(_ id: String) throws -> Project {
        try read(Project.self, from: snapshotURL(id))
    }

    func snapshotURL(_ id: String) -> URL { snapshotsURL.appendingPathComponent("\(id).json") }

    // MARK: Comments

    public func loadComments() -> CommentsFile {
        (try? read(CommentsFile.self, from: commentsURL)) ?? CommentsFile()
    }

    /// Read-modify-write of comments.json, serialized across processes.
    @discardableResult
    public func updateComments<T>(_ body: (inout CommentsFile) throws -> T) throws -> T {
        try withLock {
            var file = loadComments()
            let result = try body(&file)
            try write(file, to: commentsURL)
            return result
        }
    }

    // MARK: Analysis

    public func transcript(_ mediaId: String) -> Transcript? {
        try? read(Transcript.self, from: analysisURL.appendingPathComponent("\(mediaId).transcript.json"))
    }

    public func saveTranscript(_ t: Transcript) throws {
        try write(t, to: analysisURL.appendingPathComponent("\(t.mediaId).transcript.json"), pretty: false)
    }

    public func audioAnalysis(_ mediaId: String) -> AudioAnalysis? {
        try? read(AudioAnalysis.self, from: analysisURL.appendingPathComponent("\(mediaId).audio.json"))
    }

    public func saveAudioAnalysis(_ a: AudioAnalysis) throws {
        try write(a, to: analysisURL.appendingPathComponent("\(a.mediaId).audio.json"), pretty: false)
    }

    public func visualAnalysis(_ mediaId: String) -> VisualAnalysis? {
        try? read(VisualAnalysis.self, from: analysisURL.appendingPathComponent("\(mediaId).visual.json"))
    }

    public func saveVisualAnalysis(_ v: VisualAnalysis) throws {
        try write(v, to: analysisURL.appendingPathComponent("\(v.mediaId).visual.json"), pretty: false)
    }

    public func transcripts(for project: Project) -> [String: Transcript] {
        var out: [String: Transcript] = [:]
        for m in project.media { if let t = transcript(m.id) { out[m.id] = t } }
        return out
    }

    // MARK: IO

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try Self.decoder.decode(type, from: Data(contentsOf: url))
    }

    func write<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true) throws {
        let data = try (pretty ? Self.encoder : Self.compactEncoder).encode(value)
        try data.write(to: url, options: .atomic)
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw EditError("Cannot open lock file in \(url.path)") }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
