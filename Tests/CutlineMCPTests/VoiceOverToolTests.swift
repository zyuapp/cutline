import Accelerate
import AVFoundation
import CutlineCore
@testable import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// Gaussian-windowed chirps at irregular times: one sharp cross-correlation peak, defined at any sample rate.
private func chirps(rate: Double, seconds: Double = 3.6, gain: Double = 1) -> [Float] {
    let at = [0.3, 0.75, 1.1, 1.62, 2.05, 2.4, 2.83, 3.3]
    return (0..<Int(seconds * rate)).map { i in
        let t = Double(i) / rate
        var v = 0.0
        for c in at where abs(t - c) < 0.04 {
            let u = t - c
            v += 0.5 * gain * exp(-(u / 0.008) * (u / 0.008)) * sin(2 * .pi * (600 * u + 40_000 * u * u))
        }
        return Float(v)
    }
}

private func writeMono(_ samples: [Float], rate: Double, to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buf)
}

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

/// Stands in for the preview app: hears the tool's "record" notification for one project and records the
/// request with the app's own session, using the request's test input as the microphone.
private final class RecorderStandIn: @unchecked Sendable {
    private var observer: NSObjectProtocol?
    private(set) var sessions: [VoiceOverSession] = []

    init(project: String, latency: Seconds = 0, deny: Bool = false) {
        observer = DistributedNotificationCenter.default().addObserver(forName: PreviewControl.notification, object: nil, queue: nil) { [weak self] note in
            guard let info = note.userInfo, info["project"] as? String == project, info["action"] as? String == "record",
                  let path = info["request"] as? String, let request = VoiceOver.read(VoiceOverRequest.self, from: URL(fileURLWithPath: path)) else { return }
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            if deny {
                try? VoiceOver.write(VoiceOverResult(id: request.id, status: .failed, error: VoiceOver.permissionMessage), to: VoiceOver.resultURL(dir))
                return
            }
            let session = VoiceOverSession(request: request, directory: dir, transport: SilentProgram(), environment: [VoiceOver.testLatencyEnvironment: "\(latency)"])
            self?.sessions.append(session)
            Task.detached { _ = await session.run() }
        }
    }

    deinit {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}

private func makeProject(_ dir: URL) async throws -> Toolbox {
    let box = Toolbox()
    let r = await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false])
    #expect(!r.isError, "\(r.plainText)")
    return box
}

/// tool → notification → recorder → files → import → placement, checked by cross-correlating the timeline's mix
/// with the sound the "microphone" heard.
@Test func voiceOverRecordPlacesTheTakeInSyncWithTheProgram() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("line.wav")
    try writeMono(chirps(rate: 44_100), rate: 44_100, to: input)
    let box = try await makeProject(dir)
    let b = try #require(box.session.bundle)
    let standIn = RecorderStandIn(project: b.url.path, latency: 0.045)
    let r = await box.call("voiceover_record", ["start": 1.0, "duration": 1.5, "preroll": 0.5, "countdown": 0, "script": "Every frame tells.", "test_input": .string(input.path), "analyze": false])
    #expect(!r.isError, "\(r.plainText)")
    #expect(standIn.sessions.count == 1)
    #expect(r.plainText.contains("Placed take 1") && r.plainText.contains("vo1-take1") && r.plainText.contains("input latency 45 ms compensated"), "\(r.plainText)")
    #expect(!r.plainText.contains("Warning"), "\(r.plainText)")

    let p = try b.loadProject()
    let track = try #require(p.tracks.first { $0.name == VoiceOver.trackName })
    #expect(track.kind == .audio && track.clips.count == 1)
    let clip = try #require(track.clips.first)
    #expect(clip.mediaId == "vo1-take1" && clip.start == 1.0 && abs(clip.duration - 1.5) < 1e-9)
    let m = try #require(p.mediaAsset("vo1-take1"))
    #expect(m.path.hasPrefix(b.recordingsURL.path) && m.metadata?["take"] == "1" && m.tags?.first?.label == "vo1 take 1 (placed)")
    let result = try #require(VoiceOver.read(VoiceOverResult.self, from: VoiceOver.resultURL(b.recordingsURL.appendingPathComponent("vo1"))))
    #expect(result.status == .done && result.takes.count == 1)

    // The mic heard the file from the roll at 0.5 s, so the timeline's sound must be the file delayed by 0.5 s.
    let built = try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
    var left: [Float] = []
    try await AudioIO.read(built, range: nil) { s, n in for i in 0..<n { left.append(s[2 * i]) } }
    let found = lag(of: chirps(rate: 48_000), in: left, maxLag: 48_000)
    let error = Double(found) / 48_000 - 0.5
    #expect(abs(error) < 1 / p.canvas.fps, "placed take is \(error * 1000) ms off")
    #expect(abs(error) < 0.002, "placed take is \(error * 1000) ms off")

    // The level report matches the file over the line.
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: m.path))
    let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buf)
    let t = result.takes[0]
    let line = UnsafeBufferPointer(start: buf.floatChannelData![0] + Int(t.sourceIn * 48_000), count: Int(t.duration * 48_000))
    let peak = 20 * log10(Double(line.map { abs($0) }.max()!))
    #expect(abs(t.levels.peakDB - peak) < 0.2 && r.plainText.contains("peak \(String(format: "%.1f", t.levels.peakDB)) dBFS"))

    // Collecting it again doesn't place it twice.
    let again = await box.call("voiceover_record", ["id": "vo1", "analyze": false])
    #expect(again.plainText.contains("Already placed"), "\(again.plainText)")
    #expect(try b.loadProject().tracks.flatMap(\.clips).count == 1)
}

@Test func quietTakesWarnAndTheOthersStayAlternates() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("quiet.wav")
    try writeMono(chirps(rate: 48_000, gain: 0.03), rate: 48_000, to: input)
    let box = try await makeProject(dir)
    let b = try #require(box.session.bundle)
    let standIn = RecorderStandIn(project: b.url.path)
    let r = await box.call("voiceover_record", ["start": 0.5, "end": 1.5, "preroll": 0.2, "countdown": 0, "takes": 2, "track": "new", "test_input": .string(input.path), "analyze": false])
    #expect(!r.isError && standIn.sessions.count == 1, "\(r.plainText)")
    #expect(r.plainText.contains("Warning: too quiet"), "\(r.plainText)")
    #expect(r.plainText.contains("Placed take 2") && r.plainText.contains("alternate: clip_add media_id:\"vo1-take1\""), "\(r.plainText)")
    let p = try b.loadProject()
    #expect(p.mediaAsset("vo1-take1")?.tags?.first?.label == "vo1 take 1 (alternate)" && p.mediaAsset("vo1-take2")?.metadata?["levels"]?.contains("too quiet") == true)
}

@Test func voiceOverRecordExplainsAMissingAppOrMicrophone() async throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let box = try await makeProject(dir)
    let b = try #require(box.session.bundle)

    let none = await box.call("voiceover_record", ["start": 0, "duration": 1])
    #expect(none.isError && none.plainText.contains("preview app didn't pick up") && none.plainText.contains("preview_seek open:true"), "\(none.plainText)")
    #expect(!FileManager.default.fileExists(atPath: b.recordingsURL.appendingPathComponent("vo1").path))

    let standIn = RecorderStandIn(project: b.url.path, deny: true)
    let denied = await box.call("voiceover_record", ["start": 0, "duration": 1])
    #expect(denied.isError && denied.plainText.contains("System Settings › Privacy & Security › Microphone"), "\(denied.plainText)")
    _ = standIn

    let bad = await box.call("voiceover_record", ["start": 2, "end": 1])
    #expect(bad.isError && bad.plainText.contains("end must be after start"))
    let video = await box.call("voiceover_record", ["start": 0, "duration": 1, "track": "V1"])
    #expect(video.isError && video.plainText.contains("video track"))
}
