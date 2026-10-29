import Foundation

public enum CommentAuthor: String, Codable, Sendable {
    case human
    case agent
}

public enum CommentStatus: String, Codable, Sendable {
    case open
    case resolved
}

public struct CommentReply: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var author: CommentAuthor
    public var text: String
    public var createdAt: Date

    public init(id: String = IDs.make("r"), author: CommentAuthor, text: String, createdAt: Date = Date()) {
        self.id = id
        self.author = author
        self.text = text
        self.createdAt = createdAt
    }
}

/// Feedback pinned to a timeline time and optionally a point on the frame.
public struct Comment: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var time: Seconds
    /// Fractions of the frame, origin top-left.
    public var x: Double?
    public var y: Double?
    public var text: String
    public var author: CommentAuthor
    public var status: CommentStatus
    public var createdAt: Date
    public var replies: [CommentReply]
    /// The history entry the comment was made on.
    public var historyId: String?

    public init(id: String = IDs.make("c"), time: Seconds, x: Double? = nil, y: Double? = nil, text: String, author: CommentAuthor, status: CommentStatus = .open, createdAt: Date = Date(), replies: [CommentReply] = [], historyId: String? = nil) {
        self.id = id
        self.time = time
        self.x = x
        self.y = y
        self.text = text
        self.author = author
        self.status = status
        self.createdAt = createdAt
        self.replies = replies
        self.historyId = historyId
    }
}

public struct CommentsFile: Codable, Equatable, Sendable {
    public var comments: [Comment]

    public init(comments: [Comment] = []) {
        self.comments = comments
    }
}

public enum IDs {
    public static func make(_ prefix: String) -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        let suffix = String((0..<6).map { _ in alphabet.randomElement()! })
        return "\(prefix)_\(suffix)"
    }
}
