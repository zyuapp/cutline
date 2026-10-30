import Accelerate
import CutlineCore
import Foundation

/// Per-angle sound levels for multicam switching.
public enum MulticamAudio {
    /// Level in dBFS of each word span as heard in `url`, whose time is the reference time plus `offset`; nil where
    /// the file doesn't cover the word.
    public static func wordLevels(url: URL, offset: Seconds, words: [TimeRange]) async throws -> [Double?] {
        let samples = try await Diarizer.decodeMono(url: url)
        let rate = Diarizer.decodeRate
        return samples.withUnsafeBufferPointer { x in
            words.map { w -> Double? in
                let a = Int(((w.start + offset) * rate).rounded()), b = Int(((w.end + offset) * rate).rounded())
                guard a >= 0, b <= x.count, b - a >= 160 else { return nil }
                var ms: Float = 0
                vDSP_measqv(x.baseAddress! + a, 1, &ms, vDSP_Length(b - a))
                return Double(10 * log10(max(ms, 1e-10)))
            }
        }
    }
}
