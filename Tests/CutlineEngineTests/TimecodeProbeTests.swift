import AVFoundation
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private let tools = FFmpeg.tools()
private let skip: Testing.Comment = "ffmpeg not found; brew install ffmpeg to run"

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-tc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func ffmpeg(_ args: [String]) async throws {
    try await FFmpeg.run(tools!.ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30000/1001", "-t", "1"] + args)
}

@Suite(.serialized) struct TimecodeProbeTests {
    @Test(.enabled(if: tools != nil, skip)) func quickTimeTimecodeTrackIsReadAtImport() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ndf = dir.appendingPathComponent("A001C002.mov")
        try await ffmpeg(["-c:v", "prores_ks", "-profile:v", "0", "-timecode", "14:22:10:05", ndf.path])
        let m = try await MediaProbe.probe(ndf, id: "a")
        #expect(m.timecodeLabel == "14:22:10:05" && m.timecodeString() == "14:22:10:05")
        let frames = ((14 * 60 + 22) * 60 + 10) * 30 + 5
        #expect(abs((m.timecodeStart ?? 0) - Double(frames) * 1001 / 30000) < 1e-6, "\(String(describing: m.timecodeStart))")

        let df = dir.appendingPathComponent("df.mov")
        try await ffmpeg(["-c:v", "prores_ks", "-profile:v", "0", "-timecode", "01:00:00;00", "-metadata:s:v", "reel_name=A001", df.path])
        let d = try await MediaProbe.probe(df, id: "d")
        #expect(d.timecodeString() == "01:00:00;00" && d.reel == "A001", "\(String(describing: d.timecodeLabel)) \(String(describing: d.reel))")
        #expect(abs((d.timecodeStart ?? 0) - 107_892.0 * 1001 / 30000) < 1e-6)
        // The anchor counts in the file's own timecode.
        var p = Project(name: "P", canvas: Canvas(fps: 25))
        p.media = [d]
        #expect(try abs(p.resolveSourceTime("d@01:00:00;15", transcripts: [:]) - 15.0 * 1001 / 30000) < 1e-9)

        let mp4 = dir.appendingPathComponent("clip.mp4")
        try await ffmpeg(["-c:v", "libx264", "-pix_fmt", "yuv420p", "-timecode", "10:00:00:00", mp4.path])
        #expect(try await MediaProbe.probe(mp4, id: "m").timecodeString() == "10:00:00:00")
    }

    @Test(.enabled(if: tools != nil, skip)) func mxfNonDropTimecodeAndReelSurviveTheMezzanine() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("TAPE7.mxf")
        try await ffmpeg(["-c:v", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "20M", "-timecode", "10:00:00:00", "-metadata", "reel_name=TAPE7", src.path])
        guard case .ready(let m) = try await MediaIngest.prepare(src, id: "tape", cache: dir.appendingPathComponent("cache"), tools: tools) else { Issue.record("deferred"); return }
        // 10:00:00:00 non-drop at 29.97 is 1,080,000 frames: 36036 s, not 35999.964 (drop frame) or 36000.
        #expect(m.timecodeString() == "10:00:00:00", "\(String(describing: m.timecodeLabel))")
        #expect(abs((m.timecodeStart ?? 0) - 36036) < 1e-6, "\(String(describing: m.timecodeStart))")
        #expect(m.reel == "TAPE7")
        #expect(m.originalPath == src.path)
    }
}
