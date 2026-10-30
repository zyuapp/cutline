import AVFoundation
import CutlineCore
import Foundation

/// Masters ffmpeg encodes (DNxHR, XDCAM HD422, 10-bit H.264, AVC-Intra/XAVC Intra, AV1): the timeline is rendered by
/// `Exporter` to a ProRes 422 HQ intermediate (picture, mix or audio track layout, leader and timecode exactly as any
/// export), then encoded by ffmpeg with the intermediate's timecode, every audio track and the canvas color tags.
public enum FFmpegDelivery {
    public static func missing(_ p: ExportPreset) -> String {
        "\(p.title) needs ffmpeg, which wasn't found (looked at CUTLINE_FFMPEG, PATH, \(FFmpeg.searchFolders.joined(separator: ", "))): macOS has no system encoder for it. Install ffmpeg (brew install ffmpeg) and export again, or use prores_hq."
    }

    /// Frame rates XDCAM HD422 carries at 1920×1080.
    public static let xdcamRates: [Double] = [24000.0 / 1001, 24, 25, 30000.0 / 1001]
    /// Frame rates libx264's AVC-Intra Class 100 takes at 1920×1080; interlaced only at 25 and 29.97.
    public static let avcIntraRates: [Double] = [24000.0 / 1001, 25, 30000.0 / 1001, 50, 60000.0 / 1001]

    /// ffmpeg's DNxHR profiles are progressive only, so an interlaced DNx master is written as the DNxHD 1080i
    /// tier closest to the preset (VC-3, top field first): HQ → 220/185, HQX → 220x/185x 10-bit, SQ → 145/120.
    public static func interlacedDNxHD(_ preset: ExportPreset, fps: Double) -> (mbps: Int, tenBit: Bool, name: String)? {
        let ntsc = abs(fps - 30000.0 / 1001) < 0.01, pal = abs(fps - 25) < 0.01
        guard ntsc || pal else { return nil }
        switch preset {
        case .dnxhr_hq: return ntsc ? (220, false, "DNxHD 220") : (185, false, "DNxHD 185")
        case .dnxhr_hqx: return ntsc ? (220, true, "DNxHD 220x") : (185, true, "DNxHD 185x")
        case .dnxhr_sq: return ntsc ? (145, false, "DNxHD 145") : (120, false, "DNxHD 120")
        default: return nil
        }
    }

    /// Problems that stop `preset` before anything renders.
    public static func check(_ p: Project, preset: ExportPreset, container: String, fields: FieldOrder? = nil) -> String? {
        let space = p.canvas.colorSpace
        let fps = p.canvas.fps
        let interlaced = fields == .tff || fields == .bff
        let size = "\(p.canvas.width)×\(p.canvas.height) at \(String(format: "%.3f", fps)) fps"
        if preset.isDNxHR, interlaced {
            if preset == .dnxhr_lb { return "DNxHR LB can't be interlaced: ffmpeg's DNxHR is progressive only and DNxHD 1080i has no tier that light. Use dnxhr_sq (DNxHD 145/120 1080i), prores_hq or xdcam_hd422" }
            if fields == .bff { return "Interlaced DNx is DNxHD 1080i, which is top field first only (ffmpeg's DNxHR is progressive only). Export interlaced:\"tff\", or use prores_hq for bottom field first" }
            if p.canvas.width != 1920 || p.canvas.height != 1080 || interlacedDNxHD(preset, fps: fps) == nil {
                return "Interlaced DNx is DNxHD 1080i: 1920×1080 at 25 or 29.97 fps (ffmpeg's DNxHR is progressive only); this canvas is \(size). Use prores_hq for other interlaced formats, or canvas_set the size and rate"
            }
        }
        switch preset {
        case .xdcam_hd422:
            if container != "mxf" { return "XDCAM HD422 is MXF only" }
            if space.isHDR { return "XDCAM HD422 is 8-bit Rec. 709; this canvas is \(space.rawValue)" }
            if !xdcamRates.contains(where: { abs($0 - fps) < 0.01 }) { return "XDCAM HD422 1080 runs at 23.976, 24, 25 or 29.97 fps; the canvas is \(String(format: "%.3f", fps)) fps (canvas_set fps)" }
        case .dnxhr_hq, .dnxhr_sq, .dnxhr_lb:
            if space.isHDR { return "\(preset.title) is 8-bit; use dnxhr_hqx for \(space.rawValue)" }
        case .avc_intra_class100, .xavc_intra_class100:
            if p.canvas.width != 1920 || p.canvas.height != 1080 { return "\(preset.title) is 1920×1080; this canvas is \(size). canvas_set width:1920 height:1080, or use h264_422_10bit for other sizes" }
            if !avcIntraRates.contains(where: { abs($0 - fps) < 0.01 }) { return "\(preset.title) runs at 23.976, 25, 29.97, 50 or 59.94 fps; the canvas is \(String(format: "%.3f", fps)) fps (canvas_set fps)" }
            if interlaced, abs(fps - 25) > 0.01, abs(fps - 30000.0 / 1001) > 0.01 { return "Interlaced \(preset.title) is 1080i at 25 or 29.97 fps; the canvas is \(String(format: "%.3f", fps)) fps" }
            if preset == .avc_intra_class100, space.isHDR { return "AVC-Intra 100 is Rec. 709; use xavc_intra_class100 or h264_422_10bit for \(space.rawValue)" }
        case .av1:
            if interlaced { return "AV1 is progressive only; export without interlaced" }
        default: break
        }
        if !preset.containers.contains(container) {
            return "\(preset.title) goes in \(preset.containers.map { $0 == "mxf" ? "MXF" : $0 == "mov" ? "QuickTime (.mov)" : "MP4" }.joined(separator: " or ")); the path ends .\(container)"
        }
        return nil
    }

    /// The ffmpeg encoder `preset` uses with these encoders, or why this ffmpeg can't make it.
    public static func encoder(_ preset: ExportPreset, _ e: FFmpeg.Encoders, tool: String) -> Result<String, EditError> {
        func fail(_ s: String) -> Result<String, EditError> { .failure(EditError("\(s) (\(tool)). Install a full build (brew install ffmpeg) or set CUTLINE_FFMPEG to one, or use prores_hq.")) }
        if preset.isX264 {
            guard e.names.contains("libx264") else { return fail("\(preset.title) needs ffmpeg built with libx264, and this ffmpeg has no libx264 encoder") }
            let pix = preset == .h264_10bit ? "yuv420p10le" : "yuv422p10le"
            if let formats = e.pixelFormats["libx264"], !formats.contains(pix) { return fail("\(preset.title) needs 10-bit x264, and this ffmpeg's libx264 has no \(pix) (it was built 8-bit only)") }
            return .success("libx264")
        }
        if preset == .av1 {
            for name in ["libsvtav1", "libaom-av1"] where e.names.contains(name) {
                if let formats = e.pixelFormats[name], !formats.contains("yuv420p10le") { continue }
                return .success(name)
            }
            return fail("AV1 needs ffmpeg built with SVT-AV1 (libsvtav1) or libaom with 10-bit support, and this ffmpeg has neither")
        }
        let name = preset == .xdcam_hd422 ? "mpeg2video" : "dnxhd"
        return e.names.isEmpty || e.names.contains(name) ? .success(name) : fail("\(preset.title) needs ffmpeg's \(name) encoder, which this ffmpeg lacks")
    }

    @discardableResult
    public static func export(_ built: BuiltTimeline, to url: URL, options: ExportOptions, progress: (@Sendable (Double) -> Void)? = nil) async throws -> LoudnessConform? {
        let preset = options.preset
        guard let tools = FFmpeg.tools() else { throw EditError(missing(preset)) }
        let p = built.scene.project
        let container = url.pathExtension.lowercased()
        if let why = check(p, preset: preset, container: container, fields: options.interlaced) { throw EditError(why) }
        let caps = try await FFmpeg.encoders(tools.ffmpeg, pixelFormatsOf: preset.isX264 ? ["libx264"] : preset == .av1 ? ["libsvtav1", "libaom-av1"] : [])
        let videoEncoder = try encoder(preset, caps, tool: tools.ffmpeg.path).get()
        let specs = options.audioTracks.map(\.spec)
        let channelTotal = specs.reduce(0) { $0 + $1.layout.channelCount }
        if preset == .xdcam_hd422, channelTotal > 8 { throw EditError("XDCAM HD422 carries 8 audio channels; the layout has \(channelTotal): \(AudioTrackSpec.describe(specs))") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("cutline-intermediate-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: tmp) }
        var inter = options
        inter.preset = .prores_hq
        inter.subtitles = []
        inter.chapters = []
        inter.closedCaptions = []
        inter.timecode = true
        if container == "mxf" { inter.audioPacking = .tracks }
        let conform = try await Exporter.export(built, to: tmp, options: inter) { progress?(0.7 * $0) }

        let asset = AVURLAsset(url: tmp)
        var channels: [Int] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            if let fd = try await track.load(.formatDescriptions).first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                channels.append(Int(asbd.pointee.mChannelsPerFrame))
            }
        }
        let duration = try await asset.load(.duration).seconds
        let timecode = options.timecode ? try await TimecodeTrack.read(tmp) : nil
        var names: [String] = []
        if !specs.isEmpty {
            if container == "mxf" { names = AudioTrackSpec.channels(specs).map(\.name) }
            else if options.audioPacking == .channels, specs.count > 1 { names = [specs.map(\.name).joined(separator: " | ")] }
            else { names = specs.map(\.name) }
        }
        try? fm.removeItem(at: url)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let args = arguments(preset, input: tmp, output: url, container: container, channels: channels, names: names, duration: duration, timecode: timecode,
                             space: p.canvas.colorSpace, size: (p.canvas.width, p.canvas.height), fps: p.canvas.fps, fields: options.interlaced,
                             bitrateMbps: options.bitrateMbps, encoder: videoEncoder)
        try await FFmpeg.run(tools.ffmpeg, args, duration: duration) { progress?(0.7 + 0.3 * $0) }
        progress?(1)
        return conform
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

    /// `channels` holds each intermediate audio track's channel count; `names` each output audio stream's name.
    static func arguments(_ preset: ExportPreset, input: URL, output: URL, container: String, channels: [Int], names: [String] = [], duration: Seconds, timecode: String?, space: WorkingSpace, size: (Int, Int), fps: Double, fields: FieldOrder? = nil, bitrateMbps: Double? = nil, encoder: String? = nil) -> [String] {
        var a = ["-nostdin", "-hide_banner", "-y", "-i", input.path]
        let mxf = container == "mxf"
        let xdcam = preset == .xdcam_hd422
        let total = channels.reduce(0, +)
        // XDCAM always carries eight mono channels; missing ones are silent.
        let silent = xdcam ? max(0, 8 - total) : 0
        if silent > 0 { a += ["-f", "lavfi", "-t", String(format: "%.6f", duration), "-i", "anullsrc=channel_layout=mono:sample_rate=48000"] }
        var filters: [String] = []
        var maps = ["-map", "0:v:0"]
        if xdcam && (size.0 != 1920 || size.1 != 1080) {
            filters.append("[0:v:0]scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1[v]")
            maps = ["-map", "[v]"]
        }
        var streams = 0
        if mxf || silent > 0 {
            // MXF tracks are one channel each, as broadcast ingest expects.
            for (t, n) in channels.enumerated() where n > 0 {
                let labels = (0..<n).map { "[t\(t)c\($0)]" }.joined()
                var chain = n == 1 ? "[0:a:\(t)]anull[t\(t)c0]" : "[0:a:\(t)]asplit=\(n)\(labels)"
                for c in 0..<n {
                    if n > 1 { chain += ";[t\(t)c\(c)]pan=mono|c0=c\(c)[a\(streams)]" } else { chain += ";[t\(t)c0]anull[a\(streams)]" }
                    maps += ["-map", "[a\(streams)]"]
                    streams += 1
                }
                filters.append(chain)
            }
            if silent > 0 {
                let labels = (0..<silent).map { "[a\(streams + $0)]" }.joined()
                filters.append(silent == 1 ? "[1:a:0]anull\(labels)" : "[1:a:0]asplit=\(silent)\(labels)")
                for k in 0..<silent { maps += ["-map", "[a\(streams + k)]"] }
                streams += silent
            }
        } else {
            for t in channels.indices where channels[t] > 0 {
                maps += ["-map", "0:a:\(t)"]
                streams += 1
            }
        }
        if !filters.isEmpty { a += ["-filter_complex", filters.joined(separator: ";")] }
        a += maps
        let interlaced = fields == .tff || fields == .bff
        let rate = bitrateMbps.map { m -> [String] in
            let b = String(format: "%.0fk", m * 1000)
            return ["-b:v", b, "-maxrate", String(format: "%.0fk", m * 1500), "-bufsize", String(format: "%.0fk", m * 2000)]
        }
        if preset.isDNxHR, interlaced, let tier = interlacedDNxHD(preset, fps: fps) {
            a += ["-c:v", "dnxhd", "-b:v", "\(tier.mbps)M", "-pix_fmt", tier.tenBit ? "yuv422p10le" : "yuv422p"]
        } else {
            var x264: [String] = []
            if preset == .xavc_intra_class100 { x264.append("avcintra-flavor=sony") }
            if preset.isX264, interlaced { x264.append(fields == .tff ? "tff=1" : "bff=1") }
            switch preset {
            case .dnxhr_hq: a += ["-c:v", "dnxhd", "-profile:v", "dnxhr_hq", "-pix_fmt", "yuv422p"]
            case .dnxhr_hqx: a += ["-c:v", "dnxhd", "-profile:v", "dnxhr_hqx", "-pix_fmt", "yuv422p10le"]
            case .dnxhr_sq: a += ["-c:v", "dnxhd", "-profile:v", "dnxhr_sq", "-pix_fmt", "yuv422p"]
            case .dnxhr_lb: a += ["-c:v", "dnxhd", "-profile:v", "dnxhr_lb", "-pix_fmt", "yuv422p"]
            case .h264_10bit:
                a += ["-c:v", "libx264", "-profile:v", "high10", "-pix_fmt", "yuv420p10le", "-preset", "slow"] + (rate ?? ["-crf", "16"])
            case .h264_422_10bit:
                a += ["-c:v", "libx264", "-profile:v", "high422", "-pix_fmt", "yuv422p10le", "-preset", "slow", "-g", String(max(1, Int((fps / 2).rounded())))]
                    + (rate ?? ["-b:v", "50M", "-maxrate", "50M", "-bufsize", "50M"])
            case .avc_intra_class100, .xavc_intra_class100:
                a += ["-c:v", "libx264", "-avcintra-class", "100", "-pix_fmt", "yuv422p10le"]
            case .av1:
                if encoder == "libaom-av1" {
                    a += ["-c:v", "libaom-av1", "-pix_fmt", "yuv420p10le", "-cpu-used", "6", "-row-mt", "1"] + (rate.map { Array($0.prefix(2)) } ?? ["-crf", "24", "-b:v", "0"])
                } else {
                    a += ["-c:v", "libsvtav1", "-pix_fmt", "yuv420p10le", "-preset", "6"] + (rate.map { Array($0.prefix(2)) } ?? ["-crf", "24"])
                }
            default:
                let gop = abs(fps - 30000.0 / 1001) < 0.01 ? "15" : "12"
                a += ["-c:v", "mpeg2video", "-profile:v", "0", "-level:v", "2", "-pix_fmt", "yuv422p",
                      "-b:v", "50M", "-minrate", "50M", "-maxrate", "50M", "-bufsize", "17825792", "-rc_init_occupancy", "17825792",
                      "-g", gop, "-bf", "2", "-sc_threshold", "1000000000", "-intra_vlc", "1", "-non_linear_quant", "1", "-dc", "10",
                      "-qmin", "1", "-qmax", "12"]
            }
            if !x264.isEmpty { a += ["-x264-params", x264.joined(separator: ":")] }
        }
        if let fields, interlaced {
            a += ["-flags", "+ilme+ildct", "-field_order", fields == .tff ? "tt" : "bb"]
        }
        let tags = colorTags(space)
        a += ["-color_primaries", tags.primaries, "-color_trc", tags.transfer, "-colorspace", tags.matrix, "-color_range", "tv"]
        if streams > 0 {
            if container == "mp4" {
                a += ["-c:a", "aac"]
                var perStream = channels.filter { $0 > 0 }
                if perStream.count != streams { perStream = [Int](repeating: 2, count: streams) }
                for (i, n) in perStream.enumerated() { a += ["-b:a:\(i)", "\(max(256, 64 * n))k"] }
            } else {
                a += ["-c:a", "pcm_s24le"]
            }
            a += ["-ar", "48000"]
        }
        if !mxf {
            for (i, name) in names.prefix(streams).enumerated() { a += ["-metadata:s:a:\(i)", "title=\(name)", "-metadata:s:a:\(i)", "handler_name=\(name)"] }
        }
        if let timecode {
            a += ["-timecode", timecode]
            if container == "mp4" { a += ["-write_tmcd", "1"] }
        }
        a += ["-progress", "pipe:1", "-nostats", "-f", mxf ? "mxf" : container == "mp4" ? "mp4" : "mov", output.path]
        return a
    }
}
