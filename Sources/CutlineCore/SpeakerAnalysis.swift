import Foundation

/// A source-time span attributed to one speaker.
public struct SpeakerSegment: Codable, Equatable, Sendable {
    public var start: Seconds
    public var end: Seconds
    public var speaker: String

    public init(start: Seconds, end: Seconds, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// Who speaks when in one media file, and how strongly each word is stressed.
public struct SpeakerAnalysis: Codable, Equatable, Sendable {
    public var mediaId: String
    /// "S1", "S2"… in order of first appearance.
    public var speakers: [String]
    /// Sorted, non-overlapping; adjacent segments have different speakers.
    public var segments: [SpeakerSegment]
    /// Parallel to the transcript's words.
    public var wordSpeakers: [String?]
    /// Parallel to the transcript's words, 0…1. Fillers are 0.
    public var emphasis: [Float]

    public init(mediaId: String, speakers: [String], segments: [SpeakerSegment], wordSpeakers: [String?], emphasis: [Float]) {
        self.mediaId = mediaId
        self.speakers = speakers
        self.segments = segments
        self.wordSpeakers = wordSpeakers
        self.emphasis = emphasis
    }

    /// The speaker of the segment containing `t`, if any.
    public func speaker(at t: Seconds) -> String? {
        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].end <= t { lo = mid + 1 } else { hi = mid }
        }
        guard lo < segments.count, segments[lo].start <= t else { return nil }
        return segments[lo].speaker
    }
}
