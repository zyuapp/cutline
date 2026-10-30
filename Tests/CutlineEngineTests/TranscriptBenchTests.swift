import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

/// Transcribes $CUTLINE_BENCH the way analysis does and writes "start end text confidence" lines to
/// $CUTLINE_BENCH_OUT. $CUTLINE_BENCH_VOCABULARY is a comma-separated vocabulary; $CUTLINE_BENCH_MODE=single runs
/// only the first pass.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CUTLINE_BENCH"] != nil))
func transcriptBench() async throws {
    let env = ProcessInfo.processInfo.environment
    let url = URL(fileURLWithPath: env["CUTLINE_BENCH"]!)
    let media = try await MediaProbe.probe(url, id: "bench")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cl-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let pcm = dir.appendingPathComponent("bench.caf")
    let a = try await AudioAnalyzer.analyze(media: media, pcmURL: pcm)
    let clock = ContinuousClock.now
    let bounds = Transcriber.chunkBounds(duration: media.duration, silences: a.silences)
    let vocabulary = (env["CUTLINE_BENCH_VOCABULARY"] ?? "").split(separator: ",").map(String.init)
    var raw: Transcript
    if env["CUTLINE_BENCH_MODE"] == "single" {
        raw = try await Transcriber.transcribe(pcmURL: pcm, mediaId: "bench", locale: "en-US", vocabulary: vocabulary, bounds: bounds, checkpoint: nil)
    } else {
        let r = try await Transcriber.analyze(pcmURL: pcm, mediaId: "bench", locale: "en-US", vocabulary: vocabulary, bounds: bounds, checkpoints: nil)
        print("BENCH steps: \(r.notes)")
        raw = r.transcript
    }
    let t = Transcriber.tighten(raw, audio: a)
    print("BENCH words=\(t.words.count) low-confidence=\(t.words.filter(\.isLowConfidence).count) time=\(ContinuousClock.now - clock)")
    let out = t.words.map { "\(String(format: "%.2f", $0.start))\t\(String(format: "%.2f", $0.end))\t\($0.text)\t\($0.confidence ?? -1)" }.joined(separator: "\n")
    try out.write(toFile: env["CUTLINE_BENCH_OUT"] ?? "/tmp/cl-bench.tsv", atomically: true, encoding: .utf8)
}
