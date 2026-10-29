import Foundation

/// Musical timing of one media file in source time.
public struct BeatAnalysis: Codable, Equatable, Sendable {
    public var mediaId: String
    /// Global tempo in beats per minute; 0 when no beat was found.
    public var tempo: Double
    /// Beat times in seconds, ascending.
    public var beats: [Double]
    /// The first beat of each bar (every 4th beat), a subset of `beats`.
    public var downbeats: [Double]
    /// Note and percussion onset times in seconds, ascending.
    public var onsets: [Double]
    /// Loudness around each beat, 0…1 with 1 the loudest beat; same count as `beats`.
    public var energy: [Float]

    public init(mediaId: String, tempo: Double, beats: [Double], downbeats: [Double], onsets: [Double], energy: [Float]) {
        self.mediaId = mediaId
        self.tempo = tempo
        self.beats = beats
        self.downbeats = downbeats
        self.onsets = onsets
        self.energy = energy
    }

    /// Beats with `range.start <= t < range.end`.
    public func beats(in range: TimeRange) -> [Double] {
        let lo = Self.lowerBound(beats, range.start)
        let hi = Self.lowerBound(beats, range.end)
        return lo < hi ? Array(beats[lo..<hi]) : []
    }

    /// The beat closest to `t`, or nil when there are no beats.
    public func nearestBeat(to t: Double) -> Double? {
        guard !beats.isEmpty else { return nil }
        let i = Self.lowerBound(beats, t)
        if i == 0 { return beats[0] }
        if i == beats.count { return beats[i - 1] }
        return t - beats[i - 1] <= beats[i] - t ? beats[i - 1] : beats[i]
    }

    /// First index whose value is `>= t` in an ascending array.
    static func lowerBound(_ values: [Double], _ t: Double) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
