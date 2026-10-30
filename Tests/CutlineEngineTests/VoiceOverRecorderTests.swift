import Accelerate
import AVFoundation
import CutlineCore
import Foundation
import Testing
@testable import CutlineEngine

/// Gaussian-windowed chirps at irregular times: one sharp cross-correlation peak, defined at any sample rate.
private func chirps(rate: Double, seconds: Double = 3.6) -> [Float] {
    let at = [0.3, 0.75, 1.1, 1.62, 2.05, 2.4, 2.83, 3.3]
    return (0..<Int(seconds * rate)).map { i in
        let t = Double(i) / rate
        var v = 0.0
        for c in at where abs(t - c) < 0.04 {
            let u = t - c
            v += 0.5 * exp(-(u / 0.008) * (u / 0.008)) * sin(2 * .pi * (600 * u + 40_000 * u * u))
        }
        return Float(v)
    }
}

private func write(_ samples: [Float], rate: Double, to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buf)
}

private func read(_ url: URL) throws -> (samples: [Float], file: AVAudioFile) {
    let file = try AVAudioFile(forReading: url)
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    return (Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))), file)
}

/// The offset in samples, 0..<maxLag, at which `reference` best lines up inside `signal`.
private func lag(of reference: [Float], in signal: [Float], maxLag: Int) -> Int {
    let padded = signal + [Float](repeating: 0, count: max(0, maxLag + reference.count - signal.count))
    var out = [Float](repeating: 0, count: maxLag)
    vDSP_conv(padded, 1, reference, 1, &out, 1, vDSP_Length(maxLag), vDSP_Length(reference.count))
    return out.indices.max { out[$0] < out[$1] }!
}

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-vo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func resamplingKeepsTheSoundInPlace() throws {
    let source = chirps(rate: 44_100, seconds: 1.5)
    let out = try VoiceOverSession.resample(source, from: 44_100, to: 48_000)
    #expect(out.count == Int((Double(source.count) * 48_000 / 44_100).rounded()))
    let reference = chirps(rate: 48_000, seconds: 1.5)
    let pad = 480
    let found = lag(of: reference, in: [Float](repeating: 0, count: pad) + out, maxLag: 2 * pad)
    #expect(abs(found - pad) <= 1, "resampler moved the sound by \(found - pad) samples")
}

@Test func takesAreWrittenAs48kHz24BitMono() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("t.wav")
    let frames = try VoiceOverSession.writeWAV(chirps(rate: 96_000, seconds: 0.5), sampleRate: 96_000, to: url)
    #expect(frames == 24_000)
    let f = try AVAudioFile(forReading: url)
    #expect(f.fileFormat.sampleRate == 48_000 && f.fileFormat.channelCount == 1 && f.length == 24_000)
    #expect(f.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24 && f.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool == false)
}

/// A session recording a 44.1 kHz test file as a microphone 50 ms late: the take lines up with the timeline.
@Test func recordedTakeLinesUpWithTheProgramAfterLatency() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("line.wav")
    try write(chirps(rate: 44_100), rate: 44_100, to: input)
    let request = VoiceOverRequest(id: "vo1", start: 1.0, end: 2.5, countdown: 0, preroll: 0.5, postroll: 0.3, testInput: input.path, testLatency: 0.05)
    let session = VoiceOverSession(request: request, directory: dir, transport: SilentProgram(), environment: [:])
    var phases: [VoiceOverSession.Phase] = []
    let lock = NSLock()
    session.onState = { s in lock.withLock { if phases.last != s.phase { phases.append(s.phase) } } }
    let result = await session.run()
    #expect(result.status == .done, "\(result)")
    let t = try #require(result.takes.first)
    #expect(result.takes.count == 1 && t.take == 1 && abs(t.inputLatency - 0.05) < 1e-9 && t.device.contains("line.wav"))
    #expect(t.start == 1.0 && abs(t.duration - 1.5) < 0.01)
    // The head is the preroll, the tail the postroll.
    #expect(abs(t.sourceIn - 0.5) < 0.01 && abs(t.fileDuration - 2.3) < 0.02, "\(t)")
    #expect(phases.contains(.recording) && phases.last == .done, "\(phases)")
    let saved = VoiceOver.read(VoiceOverResult.self, from: VoiceOver.resultURL(dir))
    #expect(saved?.status == .done && saved?.takes == result.takes)

    // File time sourceIn is timeline 1.0, which the performer heard 0.5 s into the roll.
    let (samples, file) = try read(URL(fileURLWithPath: t.file))
    #expect(file.fileFormat.sampleRate == 48_000)
    let reference = chirps(rate: 48_000)
    let pad = 4800
    let found = lag(of: reference, in: [Float](repeating: 0, count: pad) + samples, maxLag: 2 * pad)
    let expected = Double(pad) + (t.sourceIn - 0.5) * 48_000
    let error = (Double(found) - expected) / 48_000
    #expect(abs(error) < 0.002, "take is \(error * 1000) ms off")
    // Levels are measured over the line only.
    let line = samples[Int(t.sourceIn * 48_000)..<Int((t.sourceIn + t.duration) * 48_000)]
    let peak = line.map { abs($0) }.max() ?? 0
    #expect(abs(t.levels.peakDB - 20 * log10(Double(peak))) < 0.2 && t.levels.warnings.isEmpty, "\(t.levels)")
}

@Test func stopKeepsThePartialTakeAndRetakeRecordsAgain() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("line.wav")
    try write(chirps(rate: 48_000), rate: 48_000, to: input)
    let request = VoiceOverRequest(id: "vo2", start: 0.4, end: 2.4, countdown: 0, preroll: 0.2, postroll: 0.2, takes: 2, testInput: input.path)
    let session = VoiceOverSession(request: request, directory: dir, transport: SilentProgram(), environment: [:])
    let lock = NSLock()
    var retook = false
    var stoppedAt: Seconds?
    session.onState = { s in
        lock.withLock {
            // Throw the first take away as it rolls, then stop the second take 0.6 s into its line.
            if s.take == 1, s.phase == .preroll || s.phase == .recording, !retook { retook = true; session.retake() }
            if s.take == 2, let t = s.timeline, t > 1.0, stoppedAt == nil { stoppedAt = t; session.stop() }
        }
    }
    let result = await session.run()
    #expect(result.status == .done && result.takes.map(\.take) == [1, 2], "\(result)")
    let partial = try #require(result.takes.last)
    let stop = try #require(stoppedAt)
    #expect(retook && stop < 2.3)
    #expect(abs(partial.duration - (stop - 0.4)) < 0.1, "stopped at \(stop): \(partial)")
}

@Test func testInputComesFromTheRequestOrTheEnvironment() {
    let r = VoiceOverRequest(id: "vo1", start: 0, end: 1)
    #expect(VoiceOverSession.testInput(r, environment: [:]) == nil)
    let env = VoiceOverSession.testInput(r, environment: [VoiceOver.testInputEnvironment: "/tmp/a.wav", VoiceOver.testLatencyEnvironment: "0.02"])
    #expect(env?.path == "/tmp/a.wav" && env?.latency == 0.02)
    var asked = r
    asked.testInput = "/tmp/b.wav"
    #expect(VoiceOverSession.testInput(asked, environment: [VoiceOver.testInputEnvironment: "/tmp/a.wav"])?.path == "/tmp/b.wav")
}
