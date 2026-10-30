import Accelerate
import CutlineCore
import Foundation
import Testing
@testable import CutlineEngine

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct Voice {
    var f0: Double
    /// (centre Hz, bandwidth Hz)
    var formants: [(Double, Double)]

    func gain(at f: Double) -> Float {
        let peaks = formants.reduce(0.0) { $0 + 1 / (1 + pow((f - $1.0) / $1.1, 2)) }
        return Float((peaks + 0.03) / pow(f / 100, 0.5))
    }
}

private let low = Voice(f0: 110, formants: [(700, 120), (1200, 150), (2600, 250)])
private let high = Voice(f0: 220, formants: [(400, 100), (2000, 200), (3000, 300)])
private let mid = Voice(f0: 160, formants: [(550, 120), (1700, 180), (2400, 250)])
private let rate = 16_000.0

/// Adds one harmonic "word" with a short pitch glide and raised-cosine edges.
private func addWord(_ out: inout [Float], voice: Voice, start: Double, duration: Double, gainDb: Double, rng: inout SplitMix) {
    let first = Int(start * rate)
    let n = min(Int(duration * rate), out.count - first)
    guard n > 0 else { return }
    let f0 = voice.f0 * Double.random(in: 0.95...1.05, using: &rng)
    let glide = Double.random(in: -0.05...0.05, using: &rng)
    var phase = [Float](repeating: 0, count: n)
    var acc = 0.0
    for i in 0..<n {
        acc += 2 * .pi * f0 * (1 + glide * Double(i) / Double(n)) / rate
        phase[i] = Float(acc)
    }
    var sum = [Float](repeating: 0, count: n)
    var tmp = [Float](repeating: 0, count: n)
    var count = Int32(n)
    var h = 1
    while Double(h) * f0 < 4000 {
        var scale = Float(h)
        var offset = Float.random(in: 0..<(2 * .pi), using: &rng)
        vDSP_vsmsa(phase, 1, &scale, &offset, &tmp, 1, vDSP_Length(n))
        vvsinf(&tmp, tmp, &count)
        var amp = voice.gain(at: Double(h) * f0)
        vDSP_vsma(tmp, 1, &amp, sum, 1, &sum, 1, vDSP_Length(n))
        h += 1
    }
    let peak = vDSP.maximumMagnitude(sum)
    let target = Float(pow(10, (gainDb - 12) / 20)) / max(peak, 1e-6)
    let edge = min(Int(0.015 * rate), n / 2)
    for i in 0..<n {
        var env: Float = 1
        if i < edge { env = 0.5 - 0.5 * cos(.pi * Float(i) / Float(edge)) }
        if i >= n - edge { env = 0.5 - 0.5 * cos(.pi * Float(n - 1 - i) / Float(edge)) }
        out[first + i] += sum[i] * target * env
    }
}

private struct Scene {
    var samples: [Float]
    var transcript: Transcript
    var truth: [Int]
}

/// Alternating turns of 2–4 s with a word every ~0.3 s.
private func conversation(voices: [Voice], turns: Int, seed: UInt64, turnGap: ClosedRange<Double> = 0.6...0.9) -> Scene {
    var rng = SplitMix(state: seed)
    let vocabulary = ["so", "the", "plan", "is", "simple", "really", "we", "cut", "here", "then", "color", "grade", "it"]
    var words: [Word] = []
    var truth: [Int] = []
    var events: [(Voice, Double, Double, Double)] = []
    var t = 0.3
    for turn in 0..<turns {
        let speaker = turn % voices.count
        let end = t + Double.random(in: 2...4, using: &rng)
        while t < end {
            let d = Double.random(in: 0.19...0.25, using: &rng)
            let text = vocabulary.randomElement(using: &rng)!
            words.append(Word(text: text, start: t, end: t + d))
            truth.append(speaker)
            events.append((voices[speaker], t, d, Double.random(in: -3...3, using: &rng)))
            t += d + Double.random(in: 0.06...0.11, using: &rng)
        }
        t += Double.random(in: turnGap, using: &rng)
    }
    var samples = [Float](repeating: 0, count: Int((t + 0.5) * rate))
    for i in samples.indices { samples[i] = Float.random(in: -1...1, using: &rng) * 0.0005 }
    for (voice, start, d, g) in events { addWord(&samples, voice: voice, start: start, duration: d, gainDb: g, rng: &rng) }
    return Scene(samples: samples, transcript: Transcript(mediaId: "m", locale: "en", words: words), truth: truth)
}

/// Share of words matching ground truth under the best label permutation.
private func accuracy(_ result: SpeakerAnalysis, _ scene: Scene, speakers: Int) -> Double {
    func permutations(_ a: [Int]) -> [[Int]] {
        a.count <= 1 ? [a] : a.indices.flatMap { i -> [[Int]] in
            var rest = a
            let x = rest.remove(at: i)
            return permutations(rest).map { [x] + $0 }
        }
    }
    let labels = result.wordSpeakers.map { $0.flatMap { result.speakers.firstIndex(of: $0) } ?? -1 }
    let best = permutations(Array(0..<speakers)).map { p in
        zip(labels, scene.truth).filter { $0 >= 0 && $0 < speakers && p[$0] == $1 }.count
    }.max()!
    return Double(best) / Double(scene.truth.count)
}

@Test func twoVoicesAreSeparated() {
    let scene = conversation(voices: [low, high], turns: 14, seed: 7)
    let result = Diarizer.analyze(samples: scene.samples, sampleRate: rate, transcript: scene.transcript)
    #expect(result.speakers == ["S1", "S2"])
    #expect(result.wordSpeakers.count == scene.truth.count)
    let score = accuracy(result, scene, speakers: 2)
    print("two-voice accuracy \(score) over \(scene.truth.count) words")
    #expect(score >= 0.85)
    #expect(result.segments.count >= 10)
    for (a, b) in zip(result.segments, result.segments.dropFirst()) {
        #expect(a.end <= b.start)
        #expect(a.speaker != b.speaker)
    }
    let w = scene.transcript.words[3]
    #expect(result.speaker(at: (w.start + w.end) / 2) == result.wordSpeakers[3])
}

@Test func turnsWithoutPausesAreSplit() {
    let scene = conversation(voices: [low, high], turns: 14, seed: 3, turnGap: 0.1...0.4)
    let result = Diarizer.analyze(samples: scene.samples, sampleRate: rate, transcript: scene.transcript)
    #expect(result.speakers == ["S1", "S2"])
    let score = accuracy(result, scene, speakers: 2)
    print("no-pause accuracy \(score) over \(scene.truth.count) words")
    #expect(score >= 0.85)
}

@Test func threeVoicesAreSeparated() {
    let scene = conversation(voices: [low, high, mid], turns: 15, seed: 4)
    let result = Diarizer.analyze(samples: scene.samples, sampleRate: rate, transcript: scene.transcript)
    #expect(result.speakers == ["S1", "S2", "S3"])
    let score = accuracy(result, scene, speakers: 3)
    print("three-voice accuracy \(score) over \(scene.truth.count) words")
    #expect(score >= 0.85)
}

@Test func singleVoiceIsOneSpeaker() {
    let scene = conversation(voices: [low], turns: 12, seed: 11)
    let result = Diarizer.analyze(samples: scene.samples, sampleRate: rate, transcript: scene.transcript)
    #expect(result.speakers == ["S1"])
    #expect(result.segments.count == 1)
    #expect(result.wordSpeakers.allSatisfy { $0 == "S1" })

    let other = conversation(voices: [high], turns: 12, seed: 12)
    #expect(Diarizer.analyze(samples: other.samples, sampleRate: rate, transcript: other.transcript).speakers == ["S1"])
}

@Test func loudLongWordIsEmphasized() {
    var rng = SplitMix(state: 3)
    var words: [Word] = []
    var samples = [Float](repeating: 0, count: Int(8 * rate))
    var t = 0.3
    for i in 0..<20 {
        let stressed = i == 10
        let d = stressed ? 0.45 : 0.22
        words.append(Word(text: i == 4 ? "um" : "word", start: t, end: t + d))
        addWord(&samples, voice: low, start: t, duration: d, gainDb: stressed ? 10 : Double.random(in: -1...1, using: &rng), rng: &rng)
        t += d + 0.08
    }
    let result = Diarizer.analyze(samples: samples, sampleRate: rate, transcript: Transcript(mediaId: "m", locale: "en", words: words))
    #expect(result.emphasis.count == words.count)
    #expect(result.emphasis[4] == 0)
    let others = result.emphasis.enumerated().filter { $0.offset != 10 }.map(\.element)
    print("emphasis stressed \(result.emphasis[10]), others max \(others.max()!)")
    #expect(result.emphasis[10] > 0.8)
    #expect(result.emphasis[10] > others.max()! + 0.3)
    #expect(result.emphasis.allSatisfy { (0...1).contains($0) })
}

@Test func pitchTracksSyntheticVoices() {
    var rng = SplitMix(state: 5)
    for voice in [low, high] {
        var samples = [Float](repeating: 0, count: Int(1.2 * rate))
        addWord(&samples, voice: Voice(f0: voice.f0, formants: voice.formants), start: 0.1, duration: 1.0, gainDb: 0, rng: &rng)
        let features = FrameFeatures(samples: samples, sampleRate: rate)
        let voiced = features.f0[features.frames(start: 0.2, end: 1.0)].filter { !$0.isNaN }
        let hz = voiced.map { 100 * pow(2, Double($0) / 12) }.sorted()
        #expect(voiced.count > 60)
        let median = hz[hz.count / 2]
        #expect(abs(median / voice.f0 - 1) < 0.1, "median F0 \(median) for \(voice.f0)")
    }
}

@Test func emptyInputsAreHandled() {
    let empty = Diarizer.analyze(samples: [], sampleRate: rate, transcript: Transcript(mediaId: "m", locale: "en", words: [Word(text: "hi", start: 0, end: 0.2)]))
    #expect(empty.speakers.isEmpty)
    #expect(empty.wordSpeakers == [nil])
    let none = Diarizer.analyze(samples: [Float](repeating: 0, count: 16_000), sampleRate: rate, transcript: Transcript(mediaId: "m", locale: "en", words: []))
    #expect(none.speakers.isEmpty && none.emphasis.isEmpty)
}

@Test func resamplingKeepsSpeechBandAndIgnoresChunking() {
    func resample(_ x: [Float], chunk: Int) -> [Float] {
        var r = Resampler(from: 44_100, to: 16_000)
        var out: [Float] = []
        var i = 0
        while i < x.count {
            x[i..<min(x.count, i + chunk)].withUnsafeBufferPointer { r.push($0, into: &out) }
            i += chunk
        }
        r.finish(into: &out)
        return out
    }
    func rms(_ x: [Float]) -> Float { (x[200..<(x.count - 200)].map { $0 * $0 }.reduce(0, +) / Float(x.count - 400)).squareRoot() }
    let speech = (0..<44_100).map { Float(sin(Double($0) * 2 * .pi * 1_000 / 44_100)) }
    let above = (0..<44_100).map { Float(sin(Double($0) * 2 * .pi * 12_000 / 44_100)) }
    let a = resample(speech, chunk: 4_096), b = resample(speech, chunk: 1_000)
    #expect(a.count == 16_000 && a == b)
    #expect(abs(rms(a) - 0.7071) < 0.01)
    #expect(rms(resample(above, chunk: 4_096)) < 0.001)
}
