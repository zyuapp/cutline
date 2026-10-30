import AVFoundation
import CutlineCore
import Foundation

/// DNxHR and XDCAM HD422 masters: the timeline is rendered by `Exporter` to a ProRes 422 HQ
/// intermediate (picture, mix, leader and timecode exactly as any export), then encoded by ffmpeg
/// with the intermediate's timecode, every audio channel and the canvas color tags.
public enum FFmpegDelivery {
    public static func missing(_ p: ExportPreset) -> String {
        "\(p.title) needs ffmpeg, which wasn't found (looked at CUTLINE_FFMPEG, PATH, \(FFmpeg.searchFolders.joined(separator: ", "))): macOS has no system encoder for it. Install ffmpeg (brew install ffmpeg) and export again, or use prores_hq."
    }

    /// Frame rates XDCAM HD422 carries at 1920×1080.
    public static let xdcamRates: [Double] = [24000.0 / 1001, 24, 25, 30000.0 / 1001]

    /// Problems that stop `preset` before anything renders.
    public static func check(_ p: Project, preset: ExportPreset, container: String) -> String? {
        let space = p.canvas.colorSpace
        switch preset {
        case .xdcam_hd422:
            if container != "mxf" { return "XDCAM HD422 is MXF only" }
            if space.isHDR { return "XDCAM HD422 is 8-bit Rec. 709; this canvas is \(space.rawValue)" }
            if !xdcamRates.contains(where: { abs($0 - p.canvas.fps) < 0.01 }) { return "XDCAM HD422 1080 runs at 23.976, 24, 25 or 29.97 fps; the canvas is \(String(format: "%.3f", p.canvas.fps)) fps (canvas_set fps)" }
        case .dnxhr_hq, .dnxhr_sq, .dnxhr_lb:
            if space.isHDR { return "\(preset.title) is 8-bit; use dnxhr_hqx for \(space.rawValue)" }
        default: break
        }
        if preset.isDNxHR, container != "mov", container != "mxf" { return "DNxHR goes in mov or mxf" }
        return nil
    }

    public static func export(_ built: BuiltTimeline, to url: URL, options: ExportOptions, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let preset = options.preset
        guard let tools = FFmpeg.tools() else { throw EditError(missing(preset)) }
        let p = built.scene.project
        let mxf = url.pathExtension.lowercased() == "mxf"
        if let why = check(p, preset: preset, container: mxf ? "mxf" : url.pathExtension.lowercased()) { throw EditError(why) }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cutline-intermediate-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: tmp) }
        var inter = options
        inter.preset = .prores_hq
        inter.subtitles = []
        inter.chapters = []
        inter.closedCaptions = []
        inter.timecode = true
        try await Exporter.export(built, to: tmp, options: inter) { progress?(0.7 * $0) }

        let asset = AVURLAsset(url: tmp)
        let duration = try await asset.load(.duration).seconds
        var channels = 0
        if let track = try await asset.loadTracks(withMediaType: .audio).first, let fd = try await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            channels = Int(asbd.pointee.mChannelsPerFrame)
        }
        let timecode = options.timecode ? try await TimecodeTrack.read(tmp) : nil
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let args = arguments(preset, input: tmp, output: url, mxf: mxf, channels: channels, duration: duration, timecode: timecode,
                             space: p.canvas.colorSpace, size: (p.canvas.width, p.canvas.height), fps: p.canvas.fps)
        try await FFmpeg.run(tools.ffmpeg, args, duration: duration) { progress?(0.7 + 0.3 * $0) }
        progress?(1)
    }

    /// ffmpeg's names for a canvas's primaries, transfer and matrix.
    static func colorTags(_ w: WorkingSpace) -> (primaries: String, transfer: String, matrix: String) {
        switch w {
        case .rec709: ("bt709", "bt709", "bt709")
        case .p3: ("smpte432", "iec61966-2-1", "bt709")
        case .rec2020_hlg: ("bt2020", "arib-std-b67", "bt2020nc")
        case .rec2020_pq: ("bt2020", "smpte2084", "bt2020nc")
        }
    }

    static func arguments(_ preset: ExportPreset, input: URL, output: URL, mxf: Bool, channels: Int, duration: Seconds, timecode: String?, space: WorkingSpace, size: (Int, Int), fps: Double) -> [String] {
        var a = ["-nostdin", "-hide_banner", "-y", "-i", input.path]
        let xdcam = preset == .xdcam_hd422
        // XDCAM always carries eight mono channels; missing ones are silent.
        let outChannels = xdcam ? 8 : channels
        if xdcam && channels == 0 { a += ["-f", "lavfi", "-t", String(format: "%.6f", duration), "-i", "anullsrc=channel_layout=mono:sample_rate=48000"] }
        var filters: [String] = []
        var maps = ["-map", "0:v:0"]
        let audioIn = channels > 0 ? "0:a:0" : "1:a:0"
        if xdcam && (size.0 != 1920 || size.1 != 1080) {
            filters.append("[0:v:0]scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1[v]")
            maps = ["-map", "[v]"]
        }
        if outChannels > 0 && (mxf || channels == 0) {
            // MXF tracks are one channel each, as broadcast ingest expects.
            let labels = (0..<outChannels).map { "[s\($0)]" }.joined()
            var chain = "[\(audioIn)]asplit=\(outChannels)\(labels)"
            for c in 0..<outChannels {
                let source = c < channels ? "c\(c)" : "0*c0"
                chain += ";[s\(c)]pan=mono|c0=\(source)[a\(c)]"
                maps += ["-map", "[a\(c)]"]
            }
            filters.append(chain)
        } else if outChannels > 0 {
            maps += ["-map", "0:a:0"]
        }
        if !filters.isEmpty { a += ["-filter_complex", filters.joined(separator: ";")] }
        a += maps
        switch preset {
        case .dnxhr_hq: a += ["-c:v", "dnxhd", "-profile:v", "dnxhr_hq", "-pix_fmt", "yuv422p"]
        case .dnxhr_hqx: a += ["-c:v", "dnxhd", "-profile:v", "dnxhr_hqx", "-pix_fmt", "yuv422p10le"]
        case .dnxhr_sq: a += ["-c:v", "dnxhd", "-profile:v", "dnxhr_sq", "-pix_fmt", "yuv422p"]
        case .dnxhr_lb: a += ["-c:v", "dnxhd", "-profile:v", "dnxhr_lb", "-pix_fmt", "yuv422p"]
        default:
            let gop = abs(fps - 30000.0 / 1001) < 0.01 ? "15" : "12"
            a += ["-c:v", "mpeg2video", "-profile:v", "0", "-level:v", "2", "-pix_fmt", "yuv422p",
                  "-b:v", "50M", "-minrate", "50M", "-maxrate", "50M", "-bufsize", "17825792", "-rc_init_occupancy", "17825792",
                  "-g", gop, "-bf", "2", "-sc_threshold", "1000000000", "-intra_vlc", "1", "-non_linear_quant", "1", "-dc", "10",
                  "-qmin", "1", "-qmax", "12"]
        }
        let tags = colorTags(space)
        a += ["-color_primaries", tags.primaries, "-color_trc", tags.transfer, "-colorspace", tags.matrix, "-color_range", "tv"]
        if outChannels > 0 { a += ["-c:a", "pcm_s24le", "-ar", "48000"] }
        if let timecode { a += ["-timecode", timecode] }
        a += ["-progress", "pipe:1", "-nostats", "-f", mxf ? "mxf" : "mov", output.path]
        return a
    }
}
