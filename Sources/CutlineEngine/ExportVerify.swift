import AVFoundation
import CutlineCore
import Foundation

/// What a written master must hold: picture for the whole requested length and every promised audio channel
/// running as long as the picture.
public struct ExportExpectation: Sendable {
    /// Seconds of picture, leader included.
    public var duration: Seconds
    public var fps: Double
    /// Audio channels across all audio tracks; 0 expects none.
    public var audioChannels: Int

    public init(duration: Seconds, fps: Double, audioChannels: Int) {
        self.duration = duration
        self.fps = fps
        self.audioChannels = audioChannels
    }

    public var frames: Int { Int((duration * fps - 1e-6).rounded(.up)) }

    /// What `options` should produce from `built`.
    public init(_ built: BuiltTimeline, options: ExportOptions) {
        let canvas = built.scene.project.canvas
        let tc = canvas.timecodeFormat
        let lead = options.leader.map { tc.seconds($0.frames(tc)) } ?? 0
        duration = built.readRange(options.range).duration.seconds + lead
        fps = canvas.fps
        let channels = options.audioTracks.isEmpty ? built.layout.channelCount : options.audioTracks.reduce(0) { $0 + $1.spec.layout.channelCount }
        audioChannels = options.preset == .xdcam_hd422 ? max(8, channels) : channels
    }
}

/// Reads a written file back: picture length in frames and each audio track's channels and length.
public enum ExportVerifier {
    public struct Measured: Sendable {
        public var videoSeconds: Seconds?
        public var audio: [(channels: Int, seconds: Seconds)]
    }

    /// Nil when the file can't be read back (MXF without ffprobe).
    public static func measure(_ url: URL) async throws -> Measured? {
        if url.pathExtension.lowercased() == "mxf" {
            guard let ffprobe = FFmpeg.tools()?.ffprobe else { return nil }
            let info = try await FFmpeg.probe(url, ffprobe: ffprobe)
            return Measured(videoSeconds: info.video.map { $0.duration ?? info.duration }, audio: info.audio.map { ($0.channels, $0.duration ?? info.duration) })
        }
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video).first
        var audio: [(Int, Seconds)] = []
        for t in try await asset.loadTracks(withMediaType: .audio) {
            let fd = try await t.load(.formatDescriptions).first
            let channels = fd.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }.map(Int.init) ?? 0
            audio.append((channels, try await t.load(.timeRange).duration.seconds))
        }
        return Measured(videoSeconds: try await video?.load(.timeRange).duration.seconds, audio: audio)
    }

    /// Mismatches between `m` and `e`: picture off by more than a frame, missing channels, sound shorter or
    /// longer than the picture by more than a frame (plus an AAC packet of encoder padding).
    public static func problems(_ m: Measured, _ e: ExportExpectation) -> [String] {
        var out: [String] = []
        let frame = 1 / max(e.fps, 1)
        guard let v = m.videoSeconds else { return ["no picture track"] }
        let frames = Int((v * e.fps).rounded())
        if abs(frames - e.frames) > 1 {
            out.append("picture is \(frames) frames (\(secs(v))s), not the \(e.frames) frames (\(secs(e.duration))s) requested")
        }
        let channels = m.audio.reduce(0) { $0 + $1.channels }
        if channels < e.audioChannels {
            out.append(m.audio.isEmpty ? "no audio track, though \(e.audioChannels) channel(s) were promised" : "\(channels) audio channel(s), not \(e.audioChannels)")
        }
        for (i, a) in m.audio.enumerated() {
            if a.seconds < e.duration - frame - 1e-3 {
                out.append("audio track \(i + 1) ends at \(secs(a.seconds))s, before the picture (\(secs(e.duration))s)")
            } else if a.seconds > e.duration + frame + 2048 / 48_000 {
                out.append("audio track \(i + 1) runs \(secs(a.seconds))s, past the picture (\(secs(e.duration))s)")
            }
        }
        return out
    }

    /// Throws when the file at `url` doesn't hold what `e` asks for.
    public static func verify(_ url: URL, _ e: ExportExpectation) async throws {
        guard let m = try await measure(url) else { return }
        let found = problems(m, e)
        if !found.isEmpty { throw EditError("\(url.lastPathComponent) didn't come out as asked: " + found.joined(separator: "; ") + ". The file was deleted.") }
    }

    /// One line on what the file holds, for an export report.
    public static func summary(_ url: URL, _ e: ExportExpectation) async -> String? {
        guard let m = try? await measure(url), let v = m.videoSeconds else { return nil }
        let frames = Int((v * e.fps).rounded())
        var s = "Checked: \(frames) frames (\(secs(v))s), as requested"
        if m.audio.isEmpty { return s + "; no audio" }
        let shapes = Dictionary(grouping: m.audio, by: \.channels).sorted { $0.key < $1.key }.map { "\($0.value.count)× \($0.key == 1 ? "mono" : "\($0.key)-channel")" }
        let shortest = m.audio.map(\.seconds).min() ?? 0
        s += "; audio \(shapes.joined(separator: " + ")) track\(m.audio.count == 1 ? "" : "s"), each at least \(secs(shortest))s"
        return s
    }
}

private func secs(_ v: Double) -> String { String(format: "%.2f", v) }
