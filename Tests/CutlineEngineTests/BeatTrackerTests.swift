import AVFoundation
import CutlineCore
import Foundation
import Testing
@testable import CutlineEngine

/// Deterministic noise source.
private struct SplitMix {
    var state: UInt64
    mutating func next() -> Float {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24) * 2 - 1
    }
}

/// Kick on every beat (accented on each bar's first beat), hi-hat on the off-beats and
/// background noise. Returns the samples and the true beat times.
private func drumTrack(bpm: Double, seconds: Double, start: Double = 0.3, sampleRate: Double = 22_050) -> (samples: [Float], beats: [Double]) {
    var rng = SplitMix(state: UInt64(bpm * 1000))
    let count = Int(seconds * sampleRate)
    var x = (0..<count).map { _ in 0.02 * rng.next() }
    let period = 60 / bpm
    var beats: [Double] = []
    var t = start
    while t < seconds - 0.2 {
        beats.append(t)
        t += period
    }
    for (i, b) in beats.enumerated() {
        let amp: Float = i % 4 == 0 ? 0.9 : 0.5
        let s0 = Int(b * sampleRate)
        var phase = 0.0
        for k in 0..<Int(0.2 * sampleRate) where s0 + k < count {
            let dt = Double(k) / sampleRate
            phase += 2 * .pi * (50 + 100 * exp(-dt / 0.03)) / sampleRate
            let click: Float = k < 110 ? 0.3 * rng.next() : 0
            x[s0 + k] += amp * (Float(sin(phase) * exp(-dt / 0.06)) + click)
        }
        let h0 = Int((b + period / 2) * sampleRate)
        var last: Float = 0
        for k in 0..<Int(0.04 * sampleRate) where h0 + k < count {
            let w = rng.next()
            x[h0 + k] += 0.12 * (w - last) * Float(exp(-Double(k) / sampleRate / 0.01))
            last = w
        }
    }
    return (x, beats)
}

/// Fraction of `truth` with a detection within `tolerance`, and the mean signed error.
private func matchRate(_ detected: [Double], _ truth: [Double], tolerance: Double = 0.05) -> (rate: Double, meanError: Double) {
    var hits = 0
    var errors: [Double] = []
    for t in truth {
        guard let d = detected.min(by: { abs($0 - t) < abs($1 - t) }), abs(d - t) <= tolerance else { continue }
        hits += 1
        errors.append(d - t)
    }
    return (Double(hits) / Double(max(1, truth.count)), errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count))
}

@Test(arguments: [120.0, 96.0])
func tracksSyntheticDrums(bpm: Double) {
    let (samples, truth) = drumTrack(bpm: bpm, seconds: 20)
    let r = BeatTracker.analyze(samples: samples, sampleRate: 22_050, mediaId: "drums")

    #expect(abs(r.tempo - bpm) <= 2, "tempo \(r.tempo)")
    #expect(r.energy.count == r.beats.count)
    #expect(r.energy.allSatisfy { (0...1).contains($0) })

    let beats = matchRate(r.beats, truth)
    #expect(beats.rate >= 0.9, "beat match \(beats.rate)")
    #expect(abs(beats.meanError) < 0.02, "beat bias \(beats.meanError)")
    #expect(abs(r.beats.count - truth.count) <= 1, "\(r.beats.count) beats for \(truth.count)")
    let intervals = zip(r.beats.dropFirst(), r.beats).map { $0 - $1 }
    #expect(intervals.allSatisfy { abs($0 - 60 / bpm) < 0.05 }, "intervals \(intervals)")

    let onsets = matchRate(r.onsets, truth)
    #expect(onsets.rate >= 0.9, "onset match \(onsets.rate)")

    let trueDownbeats = stride(from: 0, to: truth.count, by: 4).map { truth[$0] }
    let downbeats = matchRate(r.downbeats, trueDownbeats)
    #expect(downbeats.rate >= 0.9, "downbeat match \(downbeats.rate)")
    let bar = zip(r.downbeats.dropFirst(), r.downbeats).map { $0 - $1 }
    #expect(bar.allSatisfy { abs($0 - 4 * 60 / bpm) < 0.1 }, "bars \(bar)")
    print("bpm \(bpm): tempo \(r.tempo), beats \(beats), onsets \(onsets), downbeats \(downbeats)")
}

@Test func analyzesAudioFile() async throws {
    let (samples, truth) = drumTrack(bpm: 110, seconds: 12, sampleRate: 44_100)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("beats-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData![0].update(from: samples, count: samples.count)
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)

    let r = try await BeatTracker.analyze(url: url, mediaId: "file")
    #expect(abs(r.tempo - 110) <= 2, "tempo \(r.tempo)")
    #expect(matchRate(r.beats, truth).rate >= 0.9)
}

@Test func silenceHasNoBeats() {
    let r = BeatTracker.analyze(samples: [Float](repeating: 0, count: 22_050 * 5), sampleRate: 22_050, mediaId: "quiet")
    #expect(r.tempo == 0)
    #expect(r.beats.isEmpty && r.downbeats.isEmpty && r.onsets.isEmpty && r.energy.isEmpty)
    #expect(BeatTracker.analyze(samples: [], sampleRate: 22_050, mediaId: "empty").beats.isEmpty)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CUTLINE_PERF"] != nil)) func fiveMinuteTrackIsFast() {
    let (samples, _) = drumTrack(bpm: 128, seconds: 300)
    let clock = ContinuousClock()
    var r: BeatAnalysis?
    let elapsed = clock.measure { r = BeatTracker.analyze(samples: samples, sampleRate: 22_050, mediaId: "long") }
    print("5 min analysis: \(elapsed)")
    #expect(abs((r?.tempo ?? 0) - 128) <= 2)
    #expect(elapsed < .seconds(5))
}

@Test func beatHelpers() {
    let a = BeatAnalysis(mediaId: "m", tempo: 120, beats: [0.5, 1, 1.5, 2], downbeats: [0.5], onsets: [], energy: [1, 1, 1, 1])
    #expect(a.beats(in: TimeRange(1, 2)) == [1, 1.5])
    #expect(a.beats(in: TimeRange(3, 4)).isEmpty)
    #expect(a.nearestBeat(to: 1.2) == 1)
    #expect(a.nearestBeat(to: 1.3) == 1.5)
    #expect(a.nearestBeat(to: -1) == 0.5)
    #expect(a.nearestBeat(to: 9) == 2)
    #expect(BeatAnalysis(mediaId: "m", tempo: 0, beats: [], downbeats: [], onsets: [], energy: []).nearestBeat(to: 1) == nil)
}
