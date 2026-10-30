import CoreGraphics
import Foundation

/// The changes a conformed deliverable makes to meet a platform, applied to a copy of the project at export.
public struct DeliveryConform: Sendable {
    /// Frame size the picture is scaled into (without distortion) and padded to.
    public var size: (width: Int, height: Int)?
    /// Output frame rate; frames are the timeline at each output frame's time.
    public var fps: Double?
    /// Master loudness target (LUFS) and true-peak ceiling (dBTP) the mix is conformed to.
    public var loudness: Double?
    public var ceiling: Double?
    public var timecodeStart: String?
    /// One line per change, for the export report.
    public var steps: [String] = []

    public init() {}

    public var isEmpty: Bool { steps.isEmpty }

    /// `p` as rendered: the frame rate, loudness target and ceiling changed, the edit's times left alone.
    public func rendered(_ p: Project) -> Project {
        var out = p
        if let fps { out.canvas.fps = fps }
        if let loudness { out.master.loudnessTarget = loudness }
        if let ceiling { out.master.truePeakCeiling = ceiling }
        if let timecodeStart { out.canvas.timecodeStart = timecodeStart }
        return out
    }

    /// `p` as delivered, for platform checks: `rendered` at the conformed frame size.
    public func delivered(_ p: Project) -> Project {
        var out = rendered(p)
        if let size {
            out.canvas.width = size.width
            out.canvas.height = size.height
        }
        return out
    }
}

/// Delivery targets: shape, length and loudness limits, and where the app's own UI covers the picture.
/// Broadcast targets also fix the frame size, frame rate and mastering codec.
public struct Platform: Sendable {
    public var id: String
    public var name: String
    /// Accepted width:height ratios.
    public var aspects: [Double]
    public var maxDuration: Seconds?
    public var loudness: Double
    /// Allowed distance from `loudness` in LU.
    public var loudnessTolerance: Double = 1
    /// Highest true peak in dBTP.
    public var truePeak: Double = -1
    /// Safe area free of platform UI, as fractions of the frame (top-left origin).
    public var safe: CGRect
    public var preset: String
    public var notes: String
    /// Required frame size in pixels; nil accepts any size of the right shape.
    public var frameSize: (width: Int, height: Int)?
    /// Accepted frame rates; nil accepts any.
    public var frameRates: [Double]?
    /// Accepted export presets; nil accepts any.
    public var presets: [String]?
    /// Integrated loudness is measured only where dialogue plays (dialogue-gated, as Dolby Dialogue Intelligence).
    public var dialogueGated = false
    /// Audio track layout the master carries (an `AudioTrackSpec` preset); nil for the plain mix.
    public var audioTracks: String?
    /// Total audio channels the master must carry; nil for any.
    public var audioChannels: Int?
    /// Timed-text sidecar format the delivery expects.
    public var subtitleFormat: String?
    /// Timecode the program must start at.
    public var startTimecode: String?
    /// Accepted frame sizes when there are several; overrides `frameSize`.
    public var frameSizes: [(width: Int, height: Int)]?

    static let masterPresets = ["prores_hq", "prores", "prores4444", "prores4444xq", "dnxhr_hq", "dnxhr_hqx", "xdcam_hd422", "avc_intra_class100", "xavc_intra_class100"]

    public static let all: [Platform] = [
        Platform(id: "youtube", name: "YouTube", aspects: [16.0 / 9], maxDuration: nil, loudness: -14, safe: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), preset: "h264", notes: "Chapters from markers go in the description; the first must be at 0:00"),
        Platform(id: "youtube_shorts", name: "YouTube Shorts", aspects: [9.0 / 16], maxDuration: 180, loudness: -14, safe: CGRect(x: 0.05, y: 0.08, width: 0.8, height: 0.72), preset: "hevc", notes: "Title and channel cover the bottom, buttons the right edge"),
        Platform(id: "tiktok", name: "TikTok", aspects: [9.0 / 16], maxDuration: 600, loudness: -14, safe: CGRect(x: 0.05, y: 0.1, width: 0.78, height: 0.65), preset: "hevc", notes: "Caption and sound bar cover the bottom quarter, buttons the right edge"),
        Platform(id: "instagram_reels", name: "Instagram Reels", aspects: [9.0 / 16], maxDuration: 180, loudness: -14, safe: CGRect(x: 0.05, y: 0.12, width: 0.8, height: 0.66), preset: "hevc", notes: "Grid crops to 3:4 around the center; keep key action there"),
        Platform(id: "instagram_feed", name: "Instagram feed", aspects: [4.0 / 5, 1], maxDuration: 60, loudness: -14, safe: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), preset: "hevc", notes: ""),
        Platform(id: "x", name: "X", aspects: [16.0 / 9, 1], maxDuration: 140, loudness: -14, safe: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), preset: "h264", notes: ""),
        Platform(id: "linkedin", name: "LinkedIn", aspects: [16.0 / 9, 1, 4.0 / 5], maxDuration: 600, loudness: -14, safe: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), preset: "h264", notes: "Most viewers watch muted; burn in captions"),
        Platform(id: "broadcast_eu", name: "Broadcast EU (EBU R128)", aspects: [16.0 / 9], maxDuration: nil, loudness: -23, loudnessTolerance: 1, truePeak: -1, safe: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), preset: "prores_hq",
                 notes: "1080i25 masters are delivered as 1080p25 (or PsF); add bars, tone and slate with leader:true. Titles stay inside the 80% title-safe area.",
                 frameSize: (1920, 1080), frameRates: [25], presets: masterPresets),
        Platform(id: "broadcast_us", name: "Broadcast US (ATSC A/85)", aspects: [16.0 / 9], maxDuration: nil, loudness: -24, loudnessTolerance: 2, truePeak: -2, safe: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), preset: "prores_hq",
                 notes: "1080i29.97 masters are delivered as 1080p29.97 with drop-frame timecode; add bars, tone and slate with leader:true. Titles stay inside the 80% title-safe area.",
                 frameSize: (1920, 1080), frameRates: [30000.0 / 1001], presets: masterPresets),
        Platform(id: "broadcast", name: "Broadcast (EBU R128 or ATSC A/85)", aspects: [16.0 / 9], maxDuration: nil, loudness: -23, loudnessTolerance: 1, truePeak: -1, safe: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), preset: "prores_hq",
                 notes: "Generic broadcast: 25 fps checks against EBU R128, 29.97 against ATSC A/85. Pick broadcast_eu or broadcast_us for a region.",
                 frameSize: (1920, 1080), frameRates: [25, 30000.0 / 1001], presets: masterPresets),
        Platform(id: "netflix_master", name: "Netflix master", aspects: [16.0 / 9], maxDuration: nil, loudness: -27, loudnessTolerance: 2, truePeak: -2, safe: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), preset: "prores_hq",
                 notes: "Loudness is dialogue-gated (measured where dialogue plays). Audio: 5.1 + 2.0 printmasters for surround mixes, else 2.0 mix + M&E with DIA/MUS/FX/AMB stems; IMSC 1.1 timed text sidecar. IMF and Dolby Vision aren't made here.",
                 frameRates: [24000.0 / 1001, 24, 25, 30000.0 / 1001], presets: ["prores_hq", "prores4444", "prores4444xq"],
                 dialogueGated: true, audioTracks: "broadcast_8ch", subtitleFormat: "imsc", frameSizes: [(1920, 1080), (3840, 2160)]),
        Platform(id: "broadcast_uk_dpp", name: "UK DPP (AS-11 UK DPP HD)", aspects: [16.0 / 9], maxDuration: nil, loudness: -23, loudnessTolerance: 0.5, truePeak: -1, safe: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), preset: "avc_intra_class100",
                 notes: "AVC-Intra 100 1920×1080 in MXF OP1a, 25 fps: export interlaced:\"tff\" for 1080i25 (progressive goes as 25p). Program starts at 10:00:00:00; leader:true adds bars, tone and slate before it. Eight mono 24-bit tracks: 1-2 stereo mix, 3-4 M&E, 5-8 DIA/MUS/FX/AMB. AS-11 descriptive metadata isn't written.",
                 frameSize: (1920, 1080), frameRates: [25], presets: ["avc_intra_class100"],
                 audioTracks: "broadcast_8ch", audioChannels: 8, startTimecode: "10:00:00:00"),
    ]

    public static func named(_ id: String) -> Platform? { all.first { $0.id == id } }

    private func fmt1(_ v: Double) -> String { String(format: "%.1f", v) }

    /// The regional variant for generic `broadcast` at the project's frame rate.
    public func resolved(for p: Project) -> Platform {
        if id == "netflix_master", p.master.layout.isSurround {
            var r = self
            r.audioTracks = "netflix_51_20"
            return r
        }
        guard id == "broadcast" else { return self }
        guard var r = Platform.named(abs(p.canvas.fps - 30000.0 / 1001) < 0.01 ? "broadcast_us" : "broadcast_eu") else { return self }
        r.frameRates = frameRates
        return r
    }

    /// Problems with the edit's shape, length, frame rate and codec for this platform.
    public func check(_ p: Project, preset chosen: String? = nil) -> [String] {
        var out: [String] = []
        let aspect = Double(p.canvas.width) / Double(p.canvas.height)
        if let sizes = frameSizes {
            if !sizes.contains(where: { $0.width == p.canvas.width && $0.height == p.canvas.height }) {
                out.append("\(name) needs \(sizes.map { "\($0.width)×\($0.height)" }.joined(separator: " or ")); the canvas is \(p.canvas.width)×\(p.canvas.height). Change it with canvas_set width:\(sizes[0].width) height:\(sizes[0].height).")
            }
        } else if let size = frameSize {
            if p.canvas.width != size.width || p.canvas.height != size.height {
                out.append("\(name) needs \(size.width)×\(size.height); the canvas is \(p.canvas.width)×\(p.canvas.height). Change it with canvas_set width:\(size.width) height:\(size.height).")
            }
        } else if !aspects.contains(where: { abs($0 - aspect) < 0.02 }) {
            out.append("\(name) expects \(aspects.map(Platform.ratioName).joined(separator: " or ")); the canvas is \(p.canvas.width)×\(p.canvas.height). Change it with canvas_set (use fit \"fill\" on landscape footage).")
        }
        if let rates = frameRates, !rates.contains(where: { abs($0 - p.canvas.fps) < 0.001 }) {
            let names = rates.map(Platform.fpsName).joined(separator: " or ")
            out.append("\(name) needs \(names) fps; the canvas is \(Platform.fpsName(p.canvas.fps)) fps. Conform with canvas_set fps:\(rates.map(Platform.fpsValue).joined(separator: " or fps:")): cuts, sound edges, transitions, markers and keyframes snap to the nearest frame of the new rate, keeping the edit's length (conform:\"keep_frames\" keeps frame counts instead, so the edit runs longer or shorter). Footage shot at another rate still plays at its own speed and may judder.")
        }
        if let presets, let chosen, !presets.contains(chosen) {
            out.append("\(name) masters are \(presets.joined(separator: ", ")); \(chosen) is a distribution codec. Use preset \(preset).")
        }
        if let maxDuration, p.duration > maxDuration + 0.01 {
            out.append("\(name) allows up to \(Int(maxDuration))s; the edit is \(fmt2(p.duration))s.")
        }
        return out
    }

    /// Problems with the audio track layout, timed text and start timecode a delivery is made with.
    public func deliveryCheck(_ p: Project, audioTracks specs: [AudioTrackSpec], subtitleFormats: [String], timecodeStart: String?) -> [String] {
        var out: [String] = []
        if audioTracks != nil {
            let mixes = specs.filter { $0.content == .mix }.map(\.layout)
            if specs.isEmpty {
                out.append("\(name) masters carry an audio track layout; export with audio_tracks:\"\(audioTracks!)\".")
            } else {
                if !mixes.contains(.stereo) { out.append("\(name) needs a stereo mix track (mix@stereo); the layout is \(AudioTrackSpec.describe(specs)).") }
                if p.master.layout.isSurround, !mixes.contains(p.master.layout) { out.append("\(name) needs the \(p.master.layout.title) printmaster (mix@\(p.master.layout.title)) as well as the stereo mix.") }
            }
            let channels = specs.reduce(0) { $0 + $1.layout.channelCount }
            if let n = audioChannels, !specs.isEmpty, channels != n { out.append("\(name) masters carry \(n) audio channels; the layout has \(channels) (audio_tracks:\"\(audioTracks!)\" has \(n)).") }
        }
        if let f = subtitleFormat, !subtitleFormats.contains(f) {
            out.append("\(name) expects a \(f == "imsc" ? "IMSC 1.1" : f) timed-text sidecar; add subtitles:\"\(f)\" (or subtitle_formats with \"\(f)\").")
        }
        if let tc = startTimecode, (timecodeStart ?? p.canvas.startTimecode) != tc {
            let start = timecodeStart ?? p.canvas.startTimecode
            out.append("\(name) programs start at \(tc); this one starts at \(start). Export with timecode_start:\"\(tc)\" (or canvas_set timecode_start).")
        }
        return out
    }

    /// Broadcast and mastering targets (fixed frame size): exports refuse to render past failed checks by default.
    public var isMastering: Bool { frameSize != nil || frameSizes != nil }

    /// What a conformed deliverable changes so `p` meets this platform's frame size, frame rate, loudness, true peak
    /// and start timecode, without editing the project.
    public func conformPlan(_ p: Project, timecodeStart: String? = nil) -> DeliveryConform {
        var plan = DeliveryConform()
        let sizes = frameSizes ?? frameSize.map { [$0] } ?? []
        if let first = sizes.first, !sizes.contains(where: { $0.width == p.canvas.width && $0.height == p.canvas.height }) {
            let aspect = Double(p.canvas.width) / Double(max(1, p.canvas.height))
            let target = sizes.first { abs(Double($0.width) / Double($0.height) - aspect) < 0.02 && $0.width >= p.canvas.width } ?? first
            plan.size = target
            let s = min(Double(target.width) / Double(p.canvas.width), Double(target.height) / Double(p.canvas.height))
            let w = Int((Double(p.canvas.width) * s / 2).rounded()) * 2, h = Int((Double(p.canvas.height) * s / 2).rounded()) * 2
            plan.steps.append("picture \(p.canvas.width)×\(p.canvas.height) scaled \(fmt2(s))× to \(w)×\(h)" + (w == target.width && h == target.height ? "" : " and \(w < target.width ? "pillarboxed" : "letterboxed") in black to \(target.width)×\(target.height)"))
        }
        if let rates = frameRates, !rates.contains(where: { abs($0 - p.canvas.fps) < 0.001 }) {
            let rate = rates.min { abs($0 - p.canvas.fps) < abs($1 - p.canvas.fps) }!
            plan.fps = rate
            plan.steps.append("frame rate \(Platform.fpsName(p.canvas.fps)) → \(Platform.fpsName(rate)) fps by nearest frame (each output frame shows the timeline at its own time; no blending, so motion may judder)")
        }
        if p.master.loudnessTarget.map({ abs($0 - loudness) > loudnessTolerance }) ?? true {
            plan.loudness = loudness
            plan.steps.append("loudness to \(fmt1(loudness)) LUFS integrated\(dialogueGated ? " dialogue-gated" : "")")
        }
        if p.master.ceiling > truePeak || plan.loudness != nil {
            plan.ceiling = min(p.master.ceiling, truePeak)
            plan.steps.append("true-peak limiting at \(fmt1(plan.ceiling!)) dBTP")
        }
        if let tc = startTimecode, (timecodeStart ?? p.canvas.startTimecode) != tc {
            plan.timecodeStart = tc
            plan.steps.append("program start timecode \(tc)")
        }
        return plan
    }

    static func ratioName(_ r: Double) -> String {
        for (w, h) in [(16, 9), (9, 16), (1, 1), (4, 5), (4, 3)] where abs(Double(w) / Double(h) - r) < 0.01 { return "\(w):\(h)" }
        return String(format: "%.2f:1", r)
    }

    static func fpsName(_ f: Double) -> String { f.rounded() == f ? String(Int(f)) : String(format: "%.2f", f) }
    static func fpsValue(_ f: Double) -> String { f.rounded() == f ? String(Int(f)) : String(format: "%.2f", f) }
}
