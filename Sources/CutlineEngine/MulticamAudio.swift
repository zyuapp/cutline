import Accelerate
import CutlineCore
import Foundation

/// Per-angle sound levels for multicam switching.
public enum MulticamAudio {
    /// dBFS of 20 ms frames across each word span as heard in `url`, whose time is the reference time plus `offset`;
    /// empty where the file doesn't cover the word.
    public static func wordLevels(url: URL, offset: Seconds, words: [TimeRange], hop: Seconds = 0.02) async throws -> [[Double]] {
        let samples = try await Diarizer.decodeMono(url: url)
        let rate = Diarizer.decodeRate
        let step = Int(hop * rate)
        return samples.withUnsafeBufferPointer { x in
            words.map { w -> [Double] in
                let a = Int(((w.start + offset) * rate).rounded()), b = Int(((w.end + offset) * rate).rounded())
                guard a >= 0, b <= x.count, b - a >= step else { return [] }
                return stride(from: a, to: b - step + 1, by: step).map { i in
                    var ms: Float = 0
                    vDSP_measqv(x.baseAddress! + i, 1, &ms, vDSP_Length(step))
                    return Double(10 * log10(max(ms, 1e-10)))
                }
            }
        }
    }
}
