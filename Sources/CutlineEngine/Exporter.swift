import AVFoundation
import CoreMedia
import CutlineCore
import Foundation
import VideoToolbox

public enum ExportPreset: String, CaseIterable, Sendable {
    case hevc
    /// HEVC Main 10, for banding-free gradients and HDR.
    case hevc_10bit
    /// HEVC Main 4:2:2 10 through VideoToolbox (Apple silicon): a 10-bit 4:2:2 mezzanine.
    case hevc_422_10bit
    case h264
    /// ProRes 422.
    case prores
    case prores_hq
    case prores_lt
    case prores_proxy
    /// ProRes 4444 with alpha, for overlays and graphics.
    case prores4444
    case prores4444xq
    /// Avid DNxHR through ffmpeg: HQ and SQ 8-bit 4:2:2, HQX 10-bit 4:2:2, LB offline.
    case dnxhr_hq
    case dnxhr_hqx
    case dnxhr_sq
    case dnxhr_lb
    /// Sony XDCAM HD422 through ffmpeg: MPEG-2 4:2:2 50 Mb/s long GOP, 1920×1080, eight 24-bit PCM channels in MXF OP1a.
    case xdcam_hd422
    /// H.264 High 10 (4:2:0 10-bit) through ffmpeg's libx264.
    case h264_10bit
    /// H.264 High 4:2:2 10-bit long GOP through libx264: the XAVC Long GOP picture format (50 Mb/s at HD by default),
    /// not Sony's own MXF profile.
    case h264_422_10bit
    /// AVC-Intra Class 100 (libx264, Panasonic flavor): High 4:2:2 Intra 10-bit, 1920×1080, fixed frame size, MXF OP1a.
    /// The UK DPP HD codec.
    case avc_intra_class100
    /// XAVC Intra Class 100 picture (libx264's Sony flavor of AVC-Intra 100) in ffmpeg's generic MXF OP1a.
    case xavc_intra_class100
    /// AV1 Main 10-bit 4:2:0 through SVT-AV1 (or libaom), MP4.
    case av1

    public var fileType: AVFileType { isProRes ? .mov : .mp4 }
    /// QuickTime for ProRes or a .mov path (MP4 can't carry a timecode track), MP4 otherwise.
    public func fileType(for url: URL) -> AVFileType { isProRes || url.pathExtension.lowercased() == "mov" ? .mov : .mp4 }
    public var fileExtension: String { containers[0] }
    /// File formats the preset is written in, the default first.
    public var containers: [String] {
        switch self {
        case _ where isProRes: ["mov"]
        case .dnxhr_hq, .dnxhr_hqx, .dnxhr_sq, .dnxhr_lb: ["mov", "mxf"]
        case .xdcam_hd422: ["mxf"]
        case .hevc_422_10bit, .h264_10bit: ["mov", "mp4"]
        case .h264_422_10bit: ["mov", "mxf", "mp4"]
        case .avc_intra_class100, .xavc_intra_class100: ["mxf", "mov"]
        case .av1: ["mp4"]
        default: ["mp4", "mov"]
        }
    }
    public var isProRes: Bool { rawValue.hasPrefix("prores") }
    public var isDNxHR: Bool { rawValue.hasPrefix("dnxhr") }
    /// Rendered as a ProRes intermediate and encoded by ffmpeg.
    public var needsFFmpeg: Bool { isDNxHR || self == .xdcam_hd422 || isX264 || self == .av1 }
    /// Encoded by ffmpeg's libx264.
    public var isX264: Bool { [.h264_10bit, .h264_422_10bit, .avc_intra_class100, .xavc_intra_class100].contains(self) }
    public var isAVCIntra: Bool { self == .avc_intra_class100 || self == .xavc_intra_class100 }

    public var title: String {
        switch self {
        case .hevc: "HEVC"
        case .hevc_10bit: "HEVC Main 10"
        case .hevc_422_10bit: "HEVC Main 4:2:2 10"
        case .h264: "H.264"
        case .prores: "Apple ProRes 422"
        case .prores_hq: "Apple ProRes 422 HQ"
        case .prores_lt: "Apple ProRes 422 LT"
        case .prores_proxy: "Apple ProRes 422 Proxy"
        case .prores4444: "Apple ProRes 4444"
        case .prores4444xq: "Apple ProRes 4444 XQ"
        case .dnxhr_hq: "Avid DNxHR HQ"
        case .dnxhr_hqx: "Avid DNxHR HQX"
        case .dnxhr_sq: "Avid DNxHR SQ"
        case .dnxhr_lb: "Avid DNxHR LB"
        case .xdcam_hd422: "Sony XDCAM HD422"
        case .h264_10bit: "H.264 High 10"
        case .h264_422_10bit: "H.264 High 4:2:2 10-bit (XAVC Long GOP picture)"
        case .avc_intra_class100: "AVC-Intra Class 100"
        case .xavc_intra_class100: "XAVC Intra Class 100 (x264 Sony flavor)"
        case .av1: "AV1 Main 10"
        }
    }

    /// Codecs people ask for that this Mac can't encode, with what to use instead.
    public static func unavailable(_ name: String, ffmpeg: Bool = FFmpeg.tools() != nil) -> String? {
        let n = name.lowercased()
        if let p = ExportPreset(rawValue: n), p.needsFFmpeg {
            return ffmpeg ? nil : FFmpegDelivery.missing(p)
        }
        if n.hasPrefix("dnx") { return "\(name) isn't a preset. DNxHR presets: dnxhr_hq, dnxhr_hqx (10-bit), dnxhr_sq, dnxhr_lb." }
        if n.hasPrefix("h264_10") || n.hasPrefix("h264_422") { return "\(name) isn't a preset; 10-bit H.264 is h264_10bit (High 10) or h264_422_10bit (High 4:2:2), encoded by ffmpeg." }
        if n.hasPrefix("xavc") { return "\(name) isn't a preset; use xavc_intra_class100 (MXF) or h264_422_10bit (XAVC Long GOP picture)." }
        if n.hasPrefix("avc_intra") || n.hasPrefix("avci") { return "\(name) isn't a preset; use avc_intra_class100 (AVC-Intra 100 in MXF, the UK DPP codec)." }
        if n.hasPrefix("av1") || n == "aom" || n == "svtav1" { return "\(name) isn't a preset; use av1." }
        if n == "imf" || n.hasPrefix("imf_") { return "IMF packages aren't made: ffmpeg can't write the audio-only MXF track files IMF needs, nor JPEG 2000 in its IMF profiles. Deliver prores_hq or prores4444 with audio_tracks, or build the IMF in a mastering tool." }
        if n.hasPrefix("hevc_422") { return "\(name) isn't a preset; use hevc_422_10bit." }
        if n.hasPrefix("xdcam") || n.hasPrefix("mpeg2") { return "\(name) isn't a preset; use xdcam_hd422 (MPEG-2 4:2:2 50 Mb/s in MXF OP1a)." }
        return nil
    }

    var codec: AVVideoCodecType {
        switch self {
        case .hevc, .hevc_10bit, .hevc_422_10bit: .hevc
        case .h264: .h264
        case .prores: .proRes422
        case .prores_hq: .proRes422HQ
        case .prores_lt: .proRes422LT
        case .prores_proxy: .proRes422Proxy
        case .prores4444: .proRes4444
        case .prores4444xq: AVVideoCodecType(rawValue: "ap4x")
        case .dnxhr_hq, .dnxhr_hqx, .dnxhr_sq, .dnxhr_lb, .xdcam_hd422, .h264_10bit, .h264_422_10bit, .avc_intra_class100, .xavc_intra_class100, .av1: .proRes422HQ
        }
    }

    /// Bits per second for a frame size and rate when no bitrate is given (high quality, delivery grade).
    func defaultBitrate(width: Int, height: Int, fps: Double) -> Int {
        let pixels = Double(width * height) * max(fps, 24)
        switch self {
        case .hevc: return Int(pixels * 0.09)
        case .hevc_10bit: return Int(pixels * 0.11)
        case .hevc_422_10bit: return Int(pixels * 0.4)
        case .h264: return Int(pixels * 0.14)
        default: return 0
        }
    }
}

/// Text cues embedded as a subtitle or chapter track.
public struct TimedText: Sendable {
    public var start: Seconds
    public var end: Seconds
    public var text: String

    public init(start: Seconds, end: Seconds, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// A subtitle track in one language.
public struct SubtitleTrack: Sendable {
    /// BCP 47 tag, e.g. "fr" or "pt-BR".
    public var language: String
    public var cues: [TimedText]
    /// Every cue is forced: players show it even with subtitles off.
    public var forced: Bool

    public init(language: String, cues: [TimedText], forced: Bool = false) {
        self.language = language
        self.cues = cues
        self.forced = forced
    }
}

public struct ExportOptions: Sendable {
    public var preset: ExportPreset
    /// Megabits per second; nil picks a high-quality default. Ignored for ProRes.
    public var bitrateMbps: Double?
    public var range: TimeRange?
    public var subtitles: [TimedText]
    public var subtitleLanguage: String
    public var chapters: [TimedText]
    /// CEA-608 pop-on closed captions on CC1, written as a QuickTime 'c608' track; empty for none.
    public var closedCaptions: [TimedText]
    /// AAC bitrate in kbps for HEVC and H.264.
    public var audioKbps: Int
    /// Timecode of the first program frame; nil uses the canvas start timecode.
    public var timecodeStart: String?
    /// Writes a QuickTime timecode track ('tmcd') when the container can carry one.
    public var timecode: Bool = true
    /// Bars, tone, slate and 2-pop before the program; the timecode track starts that much earlier.
    public var leader: Leader?
    /// Interlaced output: the timeline is rendered at the field rate and woven, top or bottom field first. ProRes only.
    public var interlaced: FieldOrder?
    /// HDR10 static metadata for PQ timelines; nil uses the defaults (P3-D65 1000 cd/m² mastering display) with
    /// MaxCLL and MaxFALL measured from the render.
    public var hdr: HDRMetadata?
    /// The master's audio track layout (QuickTime or MXF): one track per job, or every channel in one track with
    /// `audioPacking` channels. Empty writes the mix as one track.
    public var audioTracks: [AudioTracks.Job] = []
    public var audioPacking: AudioTrackSpec.Packing = .tracks
    /// Receives each rendered track's loudness and conform.
    public var audioTracksReport: AudioTracks.Report?
    /// Dialogue spans (timeline time) a dialogue-gated master loudness target is measured over.
    public var loudnessGate: [TimeRange]?
    /// Subtitle tracks after `subtitles` (other languages). All subtitle tracks form one alternate group.
    public var subtitleTracks: [SubtitleTrack] = []
    /// Language of the subtitle track players pick by default; nil is the first.
    public var defaultSubtitleLanguage: String?

    public init(preset: ExportPreset = .hevc, bitrateMbps: Double? = nil, range: TimeRange? = nil, subtitles: [TimedText] = [], subtitleLanguage: String = "en", chapters: [TimedText] = [], closedCaptions: [TimedText] = [], audioKbps: Int = 256, timecodeStart: String? = nil, leader: Leader? = nil) {
        self.preset = preset
        self.bitrateMbps = bitrateMbps
        self.range = range
        self.subtitles = subtitles
        self.subtitleLanguage = subtitleLanguage
        self.chapters = chapters
        self.closedCaptions = closedCaptions
        self.audioKbps = audioKbps
        self.timecodeStart = timecodeStart
        self.leader = leader
    }
}

/// Renders a timeline with AVAssetReader → AVAssetWriter: the same compositor as preview,
/// with codec, bitrate, Rec. 709 color tags, and optional subtitle, chapter and closed caption tracks.
public enum Exporter {
    /// Writes the timeline to `url`, then reads it back (`ExportVerifier`): a file whose picture or sound came out
    /// shorter than the range, or without a promised audio channel, fails the export. A failed export deletes
    /// whatever it wrote there. Returns the loudness conform when the master has a loudness target.
    @discardableResult
    public static func export(_ built: BuiltTimeline, to url: URL, options: ExportOptions, progress report: (@Sendable (Double) -> Void)? = nil) async throws -> LoudnessConform? {
        let heartbeat = Heartbeat.current
        let progress: @Sendable (Double) -> Void = { heartbeat?.beat(progress: $0); report?($0) }
        return try await removingOnFailure(url) {
            let conform = options.preset.needsFFmpeg
                ? try await FFmpegDelivery.export(built, to: url, options: options, progress: progress)
                : try await write(built, to: url, options: options, progress: progress)
            try await ExportVerifier.verify(url, ExportExpectation(built, options: options))
            return conform
        }
    }

    static func write(_ built: BuiltTimeline, to url: URL, options: ExportOptions, progress: (@Sendable (Double) -> Void)?) async throws -> LoudnessConform? {
        let comp = built.composition
        let reader = try AVAssetReader(asset: comp)
        let range = built.readRange(options.range)
        reader.timeRange = range

        let size = built.videoComposition.renderSize
        let canvas = built.scene.project.canvas
        let space = built.outputSpace
        let tc = canvas.timecodeFormat
        let leader = options.leader
        let leaderFrames = leader?.frames(tc) ?? 0
        let leaderTime = CMTime(value: CMTimeValue(leaderFrames * tc.frameNum), timescale: CMTimeScale(tc.frameDen))
        let startLabel = options.timecodeStart ?? canvas.startTimecode
        guard let programStart = tc.frames(startLabel) else { throw EditError("Start timecode \(startLabel) isn't hh:mm:ss:ff at \(tc.nominal) fps") }
        if space.isHDR && options.preset == .h264 { throw EditError("HDR needs HEVC or ProRes; use preset hevc") }
        let videoTracks = try await comp.loadTracks(withMediaType: .video)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: ColorManagement.pixelFormat(space),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        let weave = options.interlaced == .progressive ? nil : options.interlaced
        if weave != nil {
            guard options.preset.isProRes else { throw EditError("Interlaced output needs a ProRes preset (prores_hq for broadcast); VideoToolbox's H.264 and HEVC encoders are progressive only") }
            if let why = FieldOrder.interlacedRateProblem(fps: canvas.fps) { throw EditError(why) }
            guard leader == nil else { throw EditError("Interlaced output can't carry a leader yet; export the leader as a separate progressive file") }
            let fields = built.videoComposition.mutableCopy() as! AVMutableVideoComposition
            fields.frameDuration = CMTimeMultiplyByRatio(built.videoComposition.frameDuration, multiplier: 1, divisor: 2)
            videoOut.videoComposition = fields
        } else {
            videoOut.videoComposition = built.videoComposition
        }
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        // Sound is mixed to a file first and read by its own reader: one reader feeding both writer inputs
        // can stall when the writer holds one stream back to interleave with the other.
        // Mono and surround timelines write their rendered layout mix instead.
        var audioOut: AVAssetReaderTrackOutput?
        var audioReader: AVAssetReader?
        let layout = built.layout
        let mixFile = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-mix-\(UUID().uuidString).caf")
        let conformedFile = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-loudness-\(UUID().uuidString).caf")
        defer {
            try? FileManager.default.removeItem(at: mixFile)
            try? FileManager.default.removeItem(at: conformedFile)
        }
        let master = built.scene.project.master
        var conform: LoudnessConform?
        let tracksDir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-tracks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tracksDir) }
        var trackReaders: [(AVAssetReader, AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        var trackGroups: [(url: URL, channels: Int, layout: Data?, name: String)] = []
        if !options.audioTracks.isEmpty {
            guard options.preset.fileType(for: url) == .mov else { throw EditError("An audio track layout needs a QuickTime (.mov) or MXF master; MP4 carries the mix only") }
            let rendered = try await AudioTracks.render(options.audioTracks, mix: built, span: range, leader: leader, tc: tc, dialogue: options.loudnessGate, in: tracksDir)
            options.audioTracksReport?.set(rendered)
            conform = rendered.first { $0.spec.content == .mix }?.conform
            trackGroups = try AudioTracks.writerTracks(rendered, packing: options.audioPacking, scratch: tracksDir.appendingPathComponent("packed.caf"))
        } else if layout != .stereo {
            guard let surround = built.surround else { throw EditError("The \(layout.title) mix isn't rendered yet; render the project's stems (AudioStems.renderMissing) before exporting") }
            let from = Int64((range.start.seconds * 48_000).rounded())
            let count = Int64((range.duration.seconds * 48_000).rounded())
            // Conformed or not, the range is copied out padded with silence to the picture's length.
            if let target = master.loudnessTarget {
                conform = try await LoudnessConform.run(surround, layout: layout, frames: from..<(from + count), target: target, ceiling: master.ceiling, dialogue: options.loudnessGate, to: conformedFile)
            } else {
                let n = layout.channelCount
                try AudioIO.convert(surround, matrix: (0..<n).map { o in (0..<n).map { $0 == o ? 1.0 : 0 } }, layout: layout, frames: from..<(from + count), to: conformedFile)
            }
            let asset = AVURLAsset(url: conformedFile)
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let r = try AVAssetReader(asset: asset)
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: layout.channelCount,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                    AVChannelLayoutKey: layout.channelLayoutData,
                ])
                r.add(out)
                audioReader = r
                audioOut = out
            }
        } else {
            // A timeline without sound, or whose sound ends early, still gets a mix as long as the picture.
            let count = Int64((range.duration.seconds * 48_000).rounded())
            _ = try await AudioIO.mixdown(built, range: TimeRange(range.start.seconds, range.end.seconds), to: mixFile, length: count)
            var mixed = mixFile
            if let target = master.loudnessTarget {
                let gate = options.loudnessGate?.map { TimeRange($0.start - range.start.seconds, $0.end - range.start.seconds) }
                conform = try await LoudnessConform.run(mixFile, layout: .stereo, frames: 0..<count, target: target, ceiling: master.ceiling, dialogue: gate, to: conformedFile)
                mixed = conformedFile
            }
            let mixAsset = AVURLAsset(url: mixed)
            if let track = try await mixAsset.loadTracks(withMediaType: .audio).first {
                let r = try AVAssetReader(asset: mixAsset)
                r.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: count, timescale: 48_000))
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                ])
                r.add(out)
                audioReader = r
                audioOut = out
            }
        }

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: options.preset.fileType(for: url))
        writer.shouldOptimizeForNetworkUse = true

        let fps = canvas.fps
        var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: fps]
        if !options.preset.isProRes {
            let bitrate = options.bitrateMbps.map { Int($0 * 1_000_000) }
                ?? (space.isHDR ? HDRMetadata.defaultBitrate(width: Int(size.width), height: Int(size.height), fps: fps) : options.preset.defaultBitrate(width: Int(size.width), height: Int(size.height), fps: fps))
            compression[AVVideoAverageBitRateKey] = bitrate
            compression[AVVideoMaxKeyFrameIntervalDurationKey] = 2
            compression[AVVideoAllowFrameReorderingKey] = true
            compression[AVVideoProfileLevelKey] = options.preset == .h264 ? AVVideoProfileLevelH264HighAutoLevel : (options.preset == .hevc_422_10bit ? kVTProfileLevel_HEVC_Main42210_AutoLevel : space.isHDR || options.preset == .hevc_10bit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String
        }
        if space == .rec2020_pq, options.preset.codec == .hevc {
            var meta = options.hdr ?? HDRMetadata(maxLuminance: canvas.peakRolloff?.peakNits ?? 1000)
            if meta.maxCLL == nil || meta.maxFALL == nil {
                let levels = try await HDRMetadata.measure(built, range: range)
                meta.maxCLL = meta.maxCLL ?? Int(levels.maxCLL.rounded())
                meta.maxFALL = meta.maxFALL ?? Int(levels.maxFALL.rounded())
            }
            compression[kVTCompressionPropertyKey_MasteringDisplayColorVolume as String] = meta.masteringDisplayData
            compression[kVTCompressionPropertyKey_ContentLightLevelInfo as String] = HDRMetadata.contentLightData(maxCLL: meta.maxCLL ?? 0, maxFALL: meta.maxFALL ?? 0)
        }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: options.preset.codec,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: ColorManagement.writerColorProperties(space),
        ]
        if !compression.isEmpty && !options.preset.isProRes { videoSettings[AVVideoCompressionPropertiesKey] = compression }
        if let order = weave {
            videoSettings[AVVideoCompressionPropertiesKey] = [kVTCompressionPropertyKey_FieldCount as String: 2, kVTCompressionPropertyKey_FieldDetail as String: order.fieldDetail as String]
        }
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else { throw EditError("This Mac can't encode \(options.preset.title)" + (options.preset == .hevc_422_10bit ? ": its VideoToolbox has no HEVC 4:2:2 encoder. Use prores_hq, or h264_422_10bit with ffmpeg" : "")) }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        for g in trackGroups {
            let asset = AVURLAsset(url: g.url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw EditError("Rendering audio track \(g.name) failed") }
            let r = try AVAssetReader(asset: asset)
            var read: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: g.channels,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ]
            var write: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: g.channels, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            if let l = g.layout {
                read[AVChannelLayoutKey] = l
                write[AVChannelLayoutKey] = l
            }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: read)
            r.add(out)
            guard writer.canApply(outputSettings: write, forMediaType: .audio) else { throw EditError("\(url.pathExtension) can't carry a \(g.channels)-channel audio track") }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: write)
            input.expectsMediaDataInRealTime = false
            input.metadata = AudioTracks.nameMetadata(g.name)
            writer.add(input)
            trackReaders.append((r, out, input))
        }

        var audioIn: AVAssetWriterInput?
        if trackGroups.isEmpty, audioOut != nil || leader != nil {
            let settings = audioSettings(layout, preset: options.preset, kbps: options.audioKbps)
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { throw EditError("\(options.preset.rawValue) can't carry \(layout.title) audio") }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        let offset = range.start
        let lead = leaderTime.seconds
        func inRange(_ cues: [TimedText]) -> [TimedText] {
            cues.compactMap { c in
                let s = max(c.start, offset.seconds), e = min(c.end, range.end.seconds)
                return e > s ? TimedText(start: s - offset.seconds + lead, end: e - offset.seconds + lead, text: c.text) : nil
            }
        }
        let subtitleTracks = (options.subtitles.isEmpty ? [] : [SubtitleTrack(language: options.subtitleLanguage, cues: options.subtitles)]) + options.subtitleTracks
        let defaultSubtitle = subtitleTracks.firstIndex { $0.language == options.defaultSubtitleLanguage } ?? 0
        var textInputs: [(AVAssetWriterInput, [TimedText], Bool)] = []
        for (i, track) in subtitleTracks.enumerated() {
            let shifted = inRange(track.cues)
            guard !shifted.isEmpty else { continue }
            let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: try TextTrack.formatDescription(.subtitle, forced: track.forced))
            input.expectsMediaDataInRealTime = false
            input.languageCode = TextTrack.iso639(track.language)
            input.extendedLanguageTag = track.language
            input.marksOutputTrackAsEnabled = i == defaultSubtitle
            guard writer.canAdd(input) else { continue }
            writer.add(input)
            textInputs.append((input, shifted, track.forced))
        }
        if textInputs.count > 1 {
            let group = AVAssetWriterInputGroup(inputs: textInputs.map(\.0), defaultInput: textInputs.first { $0.0.marksOutputTrackAsEnabled }?.0)
            if writer.canAdd(group) { writer.add(group) }
        }
        let chapterCues = inRange(options.chapters)
        if !chapterCues.isEmpty {
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: try TextTrack.formatDescription(.text))
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = false
            if writer.canAdd(input) {
                writer.add(input)
                textInputs.append((input, chapterCues, false))
            }
        }
        if let chapters = textInputs.first(where: { $0.0.mediaType == .text })?.0, videoIn.canAddTrackAssociation(withTrackOf: chapters, type: AVAssetTrack.AssociationType.chapterList.rawValue) {
            videoIn.addTrackAssociation(withTrackOf: chapters, type: AVAssetTrack.AssociationType.chapterList.rawValue)
        }
        var captionInput: (AVAssetWriterInput, [TimedText])?
        let captions = inRange(options.closedCaptions)
        if !captions.isEmpty {
            let input = AVAssetWriterInput(mediaType: .closedCaption, outputSettings: nil, sourceFormatHint: try CEA608.formatDescription())
            input.expectsMediaDataInRealTime = false
            input.languageCode = options.subtitleLanguage
            guard writer.canAdd(input) else { throw EditError("\(options.preset.fileExtension) files cannot carry closed captions") }
            writer.add(input)
            captionInput = (input, captions)
        }

        var timecodeInput: AVAssetWriterInput?
        if options.timecode {
            let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: try TimecodeTrack.formatDescription(tc))
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                if videoIn.canAddTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue) {
                    videoIn.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue)
                }
                timecodeInput = input
            }
        }
        let leaderVideo = try leader?.videoSamples(width: Int(size.width), height: Int(size.height), space: space, tc: tc) ?? []
        let leaderAudio = try leader?.audioSamples(layout: layout, tc: tc) ?? []

        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read the timeline") }
        if let audioReader, !audioReader.startReading() { throw audioReader.error ?? EditError("Cannot read the mixed sound") }
        for (r, _, _) in trackReaders where !r.startReading() { throw r.error ?? EditError("Cannot read a rendered audio track") }
        guard writer.startWriting() else { throw writer.error ?? EditError("Cannot write \(url.lastPathComponent)") }
        writer.startSession(atSourceTime: .zero)
        let readers = [reader] + [audioReader].compactMap { $0 } + trackReaders.map(\.0)
        let watch = StallWatch("Writing \(url.lastPathComponent)") {
            readers.forEach { $0.cancelReading() }
            writer.cancelWriting()
        }
        defer { watch.stop() }

        let total = range.duration.seconds
        let audioStart = CMTime.zero - leaderTime
        async let video: Void = pump(videoOut, into: videoIn, offset: offset - leaderTime, first: leaderVideo, weave: weave, watch: watch) { t in progress?(min(1, max(0, t - lead) / max(total, 0.001))) }
        async let audio: Void = {
            if let audioIn { try await pump(audioOut, into: audioIn, offset: audioStart, first: leaderAudio, watch: watch, report: nil) }
        }()
        let trackPumps = trackReaders
        async let tracks: Void = withThrowingTaskGroup(of: Void.self) { group in
            for (_, out, input) in trackPumps { group.addTask { try await pump(out, into: input, offset: .zero, watch: watch, report: nil) } }
            try await group.waitForAll()
        }
        // Fed together so the writer can interleave every track while the video is being rendered.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (input, cues, forced) in textInputs {
                group.addTask { try await TextTrack.write(cues, to: input, duration: total + lead, forced: forced, watch: watch) }
            }
            if let (input, cues) = captionInput {
                group.addTask { try await CEA608.write(cues, to: input, fps: fps, duration: total + lead, watch: watch) }
            }
            if let timecodeInput {
                let first = programStart + tc.frameCount(range.start.seconds) - leaderFrames
                let sample = try TimecodeTrack.sample(startFrame: (first % tc.framesPerDay + tc.framesPerDay) % tc.framesPerDay, duration: range.duration + leaderTime, try TimecodeTrack.formatDescription(tc))
                group.addTask { try await TextTrack.append([sample], to: timecodeInput, watch: watch) }
            }
            try await group.waitForAll()
        }
        _ = try await (video, audio, tracks)

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? EditError("Reading the timeline failed")
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? EditError("Writing \(url.lastPathComponent) failed") }
        return conform
    }

    /// Runs `body`; when it throws, removes what it left at `url` (a partial or empty output) and rethrows.
    /// A file that was there before and wasn't touched stays.
    public static func removingOnFailure<T>(_ url: URL, _ body: () async throws -> T) async throws -> T {
        let before = fileStamp(url)
        do {
            return try await body()
        } catch {
            discard(url, unless: before)
            throw error
        }
    }

    public static func removingOnFailureSync<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let before = fileStamp(url)
        do {
            return try body()
        } catch {
            discard(url, unless: before)
            throw error
        }
    }

    struct FileStamp: Equatable {
        var size: Int?
        var modified: Date?
        var inode: Int?
    }

    static func fileStamp(_ url: URL) -> FileStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return FileStamp(size: a[.size] as? Int, modified: a[.modificationDate] as? Date, inode: a[.systemFileNumber] as? Int)
    }

    static func discard(_ url: URL, unless before: FileStamp?) {
        guard let now = fileStamp(url), now != before else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 24-bit PCM for ProRes, AAC otherwise (at least 384 kb/s for 5.1). 7.1 is 24-bit PCM in either container:
    /// the AAC encoder only carries 7.1 with front-wide speakers, not rear surrounds.
    static func audioSettings(_ layout: AudioLayout, preset: ExportPreset, kbps: Int) -> [String: Any] {
        let aacTag = preset.isProRes ? nil : layout.codecChannelLayoutTag
        var settings: [String: Any] = aacTag == nil
            ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: layout.channelCount, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: layout.channelCount, AVEncoderBitRateKey: max(kbps, layout == .surround51 ? 384 : 0) * 1000]
        if layout != .stereo { settings[AVChannelLayoutKey] = AudioLayout.layoutData(aacTag ?? layout.channelLayoutTag) }
        return settings
    }

    /// Copies `first`, then samples from a reader output shifted back by `offset`, to a writer input. Fails with
    /// the watch when nothing moves for its limit or the task is cancelled.
    static func pump(_ output: AVAssetReaderOutput?, into input: AVAssetWriterInput, offset: CMTime, first: [CMSampleBuffer] = [], weave: FieldOrder? = nil, watch: StallWatch? = nil, report: ((Seconds) -> Void)?) async throws {
        let queue = DispatchQueue(label: "cutline.export.\(input.mediaType.rawValue)")
        var next = 0
        try await withCancellation(watch) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let done = OnceContinuation(c)
                watch?.register { done.resume(.failure($0)) }
                guarded(watch, {
                    input.requestMediaDataWhenReady(on: queue) {
                        guard !done.isDone else { return }
                        while input.isReadyForMoreMediaData {
                            if next < first.count {
                                defer { next += 1 }
                                guard guarded(watch, { input.append(first[next]) }) == true else {
                                    done.resume(.failure(watch?.failed ?? EditError("The encoder rejected a leader frame")))
                                    return
                                }
                                watch?.touch()
                                continue
                            }
                            guard let sample = weave.map({ Interlace.nextFrame(output, order: $0) }) ?? output?.nextSample() else {
                                guarded(watch, { input.markAsFinished() })
                                done.resume(watch?.failed.map { .failure($0) } ?? .success(()))
                                return
                            }
                            var buffer = sample
                            if offset != .zero, let shifted = Self.shift(sample, by: offset) { buffer = shifted }
                            report?(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                            guard guarded(watch, { input.append(buffer) }) == true else {
                                done.resume(.failure(watch?.failed ?? EditError("The encoder rejected a frame")))
                                return
                            }
                            watch?.touch()
                        }
                    }
                })
            }
        }
    }

    /// Runs a writer call unless `watch` tripped (nil then).
    @discardableResult
    static func guarded<T>(_ watch: StallWatch?, _ body: () -> T) -> T? {
        guard let watch else { return body() }
        return watch.live(body)
    }

    /// Runs `body`, tripping `watch` when the task is cancelled.
    static func withCancellation<T>(_ watch: StallWatch?, _ body: () async throws -> T) async throws -> T {
        guard let watch else { return try await body() }
        return try await withTaskCancellationHandler { try await body() } onCancel: { watch.trip(CancellationError()) }
    }

    static func shift(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}

/// 3GPP timed text (tx3g) samples, the format MP4 and QuickTime use for subtitles and chapter names.
enum TextTrack {
    /// ISO 639-2/T code ("fra") for a BCP 47 tag ("fr-CA"), as QuickTime track languages need.
    static func iso639(_ tag: String) -> String {
        Locale.Language(identifier: tag).languageCode?.identifier(.alpha3) ?? tag
    }

    static func formatDescription(_ type: AVMediaType, forced: Bool = false) throws -> CMFormatDescription {
        let color: (Int) -> [String: Any] = { v in
            [kCMTextFormatDescriptionColor_Red as String: v, kCMTextFormatDescriptionColor_Green as String: v, kCMTextFormatDescriptionColor_Blue as String: v, kCMTextFormatDescriptionColor_Alpha as String: 255]
        }
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: forced ? kCMTextDisplayFlag_allSubtitlesForced : 0,
            kCMTextFormatDescriptionExtension_BackgroundColor as String: [kCMTextFormatDescriptionColor_Red as String: 0, kCMTextFormatDescriptionColor_Green as String: 0, kCMTextFormatDescriptionColor_Blue as String: 0, kCMTextFormatDescriptionColor_Alpha as String: 0],
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: [kCMTextFormatDescriptionRect_Top as String: 0, kCMTextFormatDescriptionRect_Left as String: 0, kCMTextFormatDescriptionRect_Bottom as String: 0, kCMTextFormatDescriptionRect_Right as String: 0],
            kCMTextFormatDescriptionExtension_DefaultStyle as String: [
                kCMTextFormatDescriptionStyle_StartChar as String: 0, kCMTextFormatDescriptionStyle_EndChar as String: 0,
                kCMTextFormatDescriptionStyle_Font as String: 1, kCMTextFormatDescriptionStyle_FontFace as String: 0,
                kCMTextFormatDescriptionStyle_ForegroundColor as String: color(255), kCMTextFormatDescriptionStyle_FontSize as String: 18,
            ],
            kCMTextFormatDescriptionExtension_HorizontalJustification as String: 1,
            kCMTextFormatDescriptionExtension_VerticalJustification as String: -1,
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Sans-Serif"],
        ]
        var fd: CMFormatDescription?
        let mediaType = type == .subtitle ? kCMMediaType_Subtitle : kCMMediaType_Text
        let status = CMFormatDescriptionCreate(allocator: nil, mediaType: mediaType, mediaSubType: kCMTextFormatType_3GText, extensions: extensions as CFDictionary, formatDescriptionOut: &fd)
        guard status == noErr, let fd else { throw EditError("Cannot describe the text track (\(status))") }
        return fd
    }

    /// Writes cues with empty samples filling the gaps so the track spans the whole timeline.
    static func write(_ cues: [TimedText], to input: AVAssetWriterInput, duration: Seconds, forced: Bool = false, watch: StallWatch? = nil) async throws {
        let fd = try formatDescription(input.mediaType, forced: forced)
        var spans: [(Seconds, Seconds, String)] = []
        var t = 0.0
        for c in cues.sorted(by: { $0.start < $1.start }) where c.end > t {
            let s = max(c.start, t)
            if s > t + 0.001 { spans.append((t, s, "")) }
            spans.append((s, c.end, c.text))
            t = c.end
        }
        if duration > t + 0.001 { spans.append((t, duration, "")) }
        try await append(spans.map { try sample($0.0, $0.1, $0.2, fd) }, to: input, watch: watch)
    }

    static func append(_ samples: [CMSampleBuffer], to input: AVAssetWriterInput, watch: StallWatch? = nil) async throws {
        let queue = DispatchQueue(label: "cutline.export.text")
        var next = 0
        try await Exporter.withCancellation(watch) {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let done = OnceContinuation(c)
                watch?.register { done.resume(.failure($0)) }
                Exporter.guarded(watch, {
                    input.requestMediaDataWhenReady(on: queue) {
                        guard !done.isDone else { return }
                        while input.isReadyForMoreMediaData {
                            guard next < samples.count else {
                                Exporter.guarded(watch, { input.markAsFinished() })
                                done.resume(watch?.failed.map { .failure($0) } ?? .success(()))
                                return
                            }
                            guard Exporter.guarded(watch, { input.append(samples[next]) }) == true else {
                                done.resume(.failure(watch?.failed ?? EditError("The writer rejected a text or caption sample")))
                                return
                            }
                            watch?.touch()
                            next += 1
                        }
                    }
                })
            }
        }
    }

    static func sample(_ s: Seconds, _ e: Seconds, _ text: String, _ fd: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = Array(text.utf8)
        var bytes: [UInt8] = [UInt8(utf8.count >> 8 & 0xFF), UInt8(utf8.count & 0xFF)] + utf8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { throw EditError("Cannot allocate a text sample") }
        CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: e - s, preferredTimescale: 600), presentationTimeStamp: CMTime(seconds: s, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { throw EditError("Cannot create a text sample") }
        return sample
    }
}
