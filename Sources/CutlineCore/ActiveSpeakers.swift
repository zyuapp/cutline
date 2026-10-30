import Foundation

/// Which on-screen face is talking: speaker turns matched to face tracks by lip movement.
public struct ActiveSpeakers: Codable, Equatable, Sendable {
    public struct Span: Codable, Equatable, Sendable {
        public var start: Seconds
        public var end: Seconds
        public var speaker: String
        /// Face track id from shot analysis; nil when the talker is off screen.
        public var face: Int?
        /// Lip movement of that face during the span, relative to its size.
        public var activity: Double
        /// `activity` over the next most active face's; nil when only one face was measured.
        public var margin: Double?

        public init(start: Seconds, end: Seconds, speaker: String, face: Int?, activity: Double, margin: Double? = nil) {
            self.start = start
            self.end = end
            self.speaker = speaker
            self.face = face
            self.activity = activity
            self.margin = margin
        }

        /// The lips clearly moved and clearly more than any other face's.
        public var isConfident: Bool { face != nil && activity >= 0.02 && (margin ?? 2) >= 1.5 }
    }

    public var mediaId: String
    public var spans: [Span]
    /// The face each speaker most often has, by speaker label.
    public var speakerFaces: [String: Int]

    public init(mediaId: String, spans: [Span], speakerFaces: [String: Int]) {
        self.mediaId = mediaId
        self.spans = spans
        self.speakerFaces = speakerFaces
    }

    /// The face talking at a source time, if known.
    public func face(at t: Seconds) -> Int? {
        spans.first { t >= $0.start && t < $0.end }?.face
    }
}
