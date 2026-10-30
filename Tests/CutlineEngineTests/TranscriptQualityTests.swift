import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private let script = [
    "Thom and Celia met at the old harbor before sunrise.", "Celia carried the camera while Thom checked the light.",
    "The fishing boats came back slowly with their nets full.", "Thom asked whether the drone had enough battery left.",
    "She said the second battery was still charging in the van.", "They filmed the gulls circling over the grey water.",
    "By noon the wind had picked up and the waves grew taller.", "Celia packed the lenses and Thom carried the tripod home.",
]

/// Word error rate of `words` against `reference`: substitutions, insertions and deletions over reference words.
func wordErrorRate(_ words: [String], reference: [String]) -> Double {
    let a = reference.flatMap(Vocabulary.tokens), b = words.flatMap(Vocabulary.tokens)
    guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
    var row = Array(0...b.count)
    for i in 1...a.count {
        var prev = row[0]
        row[0] = i
        for j in stride(from: 1, through: b.count, by: 1) {
            let cur = row[j]
            row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
            prev = cur
        }
    }
    return Double(row[b.count]) / Double(a.count)
}

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-wer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// 16 kHz mono samples transcribed by one pass (`prepass` isolates the voice first), or the way analysis does
/// (`Transcriber.analyze`).
private func transcribe(_ samples: [Float], vocabulary: [String] = [], prepass: Bool = false, full: Bool = true) async throws -> Transcript {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let pcm = dir.appendingPathComponent("say.caf")
    try AudioDSP.write([prepass ? try Transcriber.isolateVoice(samples, sampleRate: 16_000) : samples], sampleRate: 16_000, to: pcm)
    if full { return try await Transcriber.analyze(pcmURL: pcm, mediaId: "say", locale: "en-US", vocabulary: vocabulary, bounds: [], checkpoints: nil).transcript }
    return try await Transcriber.transcribe(pcmURL: pcm, mediaId: "say", locale: "en-US", vocabulary: vocabulary)
}

@Test(.enabled(if: voicesAvailable(["Samantha", "Daniel"])))
func syntheticSpeechIsTranscribedWithConfidence() async throws {
    let scene = try await spokenScene(voices: ["Samantha", "Daniel"], lines: script)
    let plain = try await transcribe(scene.samples)
    let named = try await transcribe(scene.samples, vocabulary: ["Thom", "Celia"])
    let wer = wordErrorRate(plain.words.map(\.text), reference: script)
    let werNamed = wordErrorRate(named.words.map(\.text), reference: script)
    print("say WER \(String(format: "%.3f", wer)) plain, \(String(format: "%.3f", werNamed)) with vocabulary; \(plain.words.count) words, \(plain.words.filter(\.isLowConfidence).count) low-confidence")
    #expect(wer <= 0.15)
    #expect(werNamed <= wer)
    #expect(plain.words.allSatisfy { $0.confidence != nil })
    #expect(named.words.filter { $0.normalized == "thom" }.count >= 3, "\(named.words.map(\.text))")
}

/// The music-only stretch of Tears of Steel (62–116 s) under the synthetic dialogue, 6 and 10 dB louder than it.
@Test(.enabled(if: voicesAvailable(["Samantha", "Daniel"]) && FileManager.default.fileExists(atPath: tearsOfSteelPath)))
func speechUnderMusicKeepsMostWords() async throws {
    let scene = try await spokenScene(voices: ["Samantha", "Daniel"], lines: script)
    let film = try await Diarizer.decodeMono(url: URL(fileURLWithPath: tearsOfSteelPath))
    let bed = Array(film[Int(62 * 16_000)..<Int(116 * 16_000)])
    func rms(_ x: [Float]) -> Float { (x.map { $0 * $0 }.reduce(0, +) / Float(max(1, x.count))).squareRoot() }
    let voiced = scene.samples.filter { abs($0) > 0.01 }
    var report: [String] = []
    for snr in [-6.0, -10.0] {
        let gain = rms(voiced) / rms(bed) / Float(pow(10, snr / 20))
        let mixed = scene.samples.enumerated().map { i, s in s + bed[i % bed.count] * gain }
        var wers: [Double] = []
        for (prepass, full) in [(false, false), (true, false), (false, true)] {
            let t = try await transcribe(mixed, prepass: prepass, full: full)
            wers.append(wordErrorRate(t.words.map(\.text), reference: script))
        }
        report.append("SNR \(Int(snr)) dB: WER one pass \(String(format: "%.3f", wers[0])), isolated pass \(String(format: "%.3f", wers[1])), analysis \(String(format: "%.3f", wers[2]))")
        #expect(wers[2] <= wers[0] + 0.02)
    }
    print("music bed " + report.joined(separator: "; "))
}
