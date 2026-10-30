import AVFoundation
import CoreMedia
import CutlineCore
import Foundation
import VideoToolbox

public enum ExportPreset: String, CaseIterable, Sendable {
    case hevc
    /// HEVC Main 10, for banding-free gradients and HDR.
    case hevc_10bit
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

    public var fileType: AVFileType { isProRes ? .mov : .mp4 }
    /// QuickTime for ProRes or a .mov path (MP4 can't carry a timecode track), MP4 otherwise.
    public func fileType(for url: URL) -> AVFileType { isProRes || url.pathExtension.lowercased() == "mov" ? .mov : .mp4 }
    public var fileExtension: String { isProRes || isDNxHR ? "mov" : self == .xdcam_hd422 ? "mxf" : "mp4" }
    public var isProRes: Bool { rawValue.hasPrefix("prores") }
    public var isDNxHR: Bool { rawValue.hasPrefix("dnxhr") }
    /// Rendered as a ProRes intermediate and encoded by ffmpeg.
    public var needsFFmpeg: Bool { isDNxHR || self == .xdcam_hd422 }

    public var title: String {
        switch self {
        case .hevc: "HEVC"
        case .hevc_10bit: "HEVC Main 10"
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
        }
    }

    /// Codecs people ask for that this Mac can't encode, with what to use instead.
    public static func unavailable(_ name: String, ffmpeg: Bool = FFmpeg.tools() != nil) -> String? {
        let n = name.lowercased()
        if let p = ExportPreset(rawValue: n), p.needsFFmpeg {
            return ffmpeg ? nil : FFmpegDelivery.missing(p)
        }
        if n.hasPrefix("dnx") { return "\(name) isn't a preset. DNxHR presets: dnxhr_hq, dnxhr_hqx (10-bit), dnxhr_sq, dnxhr_lb." }
        if n.hasPrefix("h264_10") || n == "h264_422" { return "10-bit H.264 isn't available: VideoToolbox only encodes 8-bit H.264. Use hevc_10bit or a ProRes preset." }
        if n.hasPrefix("xdcam") || n.hasPrefix("mpeg2") { return "\(name) isn't a preset; use xdcam_hd422 (MPEG-2 4:2:2 50 Mb/s in MXF OP1a)." }
        return nil
    }

    var codec: AVVideoCodecType {
        switch self {
        case .hevc, .hevc_10bit: .hevc
        case .h264: .h264
        case .prores: .proRes422
        case .prores_hq: .proRes422HQ
        case .prores_lt: .proRes422LT
        case .prores_proxy: .proRes422Proxy
        case .prores4444: .proRes4444
        case .prores4444xq: AVVideoCodecType(rawValue: "ap4x")
        case .dnxhr_hq, .dnxhr_hqx, .dnxhr_sq, .dnxhr_lb, .xdcam_hd422: .proRes422HQ
        }
    }

    /// Bits per second for a frame size and rate when no bitrate is given (high quality, delivery grade).
    func defaultBitrate(width: Int, height: Int, fps: Double) -> Int {
        let pixels = Double(width * height) * max(fps, 24)
        switch self {
        case .hevc: return Int(pixels * 0.09)
        case .hevc_10bit: return Int(pixels * 0.11)
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
    public static func export(_ built: BuiltTimeline, to url: URL, options: ExportOptions, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if options.preset.needsFFmpeg { return try await FFmpegDelivery.export(built, to: url, options: options, progress: progress) }
        let comp = built.composition
        let reader = try AVAssetReader(asset: comp)
        let range = options.range.map { CMTimeRange(start: TimelineBuilder.time($0.start), end: TimelineBuilder.time(min($0.end, built.duration))) }
            ?? CMTimeRange(start: .zero, duration: TimelineBuilder.time(built.duration))
        reader.timeRange = range

        let size = built.videoComposition.renderSize
        let canvas = built.scene.project.canvas
        let space = canvas.colorSpace
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
        let audioTracks = try await comp.loadTracks(withMediaType: .audio)
        var audioOut: AVAssetReaderTrackOutput?
        var audioReader: AVAssetReader?
        var audioOffset = CMTime.zero
        let layout = built.layout
        let mixFile = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-mix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: mixFile) }
        if layout != .stereo {
            guard let source = built.surround else { throw EditError("The \(layout.title) mix isn't rendered yet; render the project's stems (AudioStems.renderMissing) before exporting") }
            let asset = AVURLAsset(url: source)
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let r = try AVAssetReader(asset: asset)
                r.timeRange = CMTimeRange(start: CMTime(seconds: range.start.seconds, preferredTimescale: 48_000), end: CMTime(seconds: range.end.seconds, preferredTimescale: 48_000))
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: layout.channelCount,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                    AVChannelLayoutKey: layout.channelLayoutData,
                ])
                r.add(out)
                audioReader = r
                audioOut = out
                audioOffset = r.timeRange.start
            }
        } else if !audioTracks.isEmpty {
            _ = try await AudioIO.mixdown(built, range: TimeRange(range.start.seconds, range.end.seconds), to: mixFile)
            let mixAsset = AVURLAsset(url: mixFile)
            if let track = try await mixAsset.loadTracks(withMediaType: .audio).first {
                let r = try AVAssetReader(asset: mixAsset)
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
            let bitrate = options.bitrateMbps.map { Int($0 * 1_000_000) } ?? options.preset.defaultBitrate(width: Int(size.width), height: Int(size.height), fps: fps)
            compression[AVVideoAverageBitRateKey] = bitrate
            compression[AVVideoMaxKeyFrameIntervalDurationKey] = 2
            compression[AVVideoAllowFrameReorderingKey] = true
            compression[AVVideoProfileLevelKey] = options.preset == .h264 ? AVVideoProfileLevelH264HighAutoLevel : (space.isHDR || options.preset == .hevc_10bit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String
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
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else { throw EditError("This Mac can't encode \(options.preset.title)") }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput?
        if audioOut != nil || leader != nil {
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
        let textInputs = try [(options.subtitles, AVMediaType.subtitle), (options.chapters, AVMediaType.text)].compactMap { cues, type -> (AVAssetWriterInput, [TimedText])? in
            let shifted = inRange(cues)
            guard !shifted.isEmpty else { return nil }
            let input = AVAssetWriterInput(mediaType: type, outputSettings: nil, sourceFormatHint: try TextTrack.formatDescription(type))
            input.expectsMediaDataInRealTime = false
            if type == .subtitle {
                input.languageCode = options.subtitleLanguage
                input.extendedLanguageTag = options.subtitleLanguage
            } else {
                input.marksOutputTrackAsEnabled = false
            }
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            return (input, shifted)
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
        guard writer.startWriting() else { throw writer.error ?? EditError("Cannot write \(url.lastPathComponent)") }
        writer.startSession(atSourceTime: .zero)

        let total = range.duration.seconds
        let audioStart = audioOffset - leaderTime
        async let video: Void = pump(videoOut, into: videoIn, offset: offset - leaderTime, first: leaderVideo, weave: weave) { t in progress?(min(1, max(0, t - lead) / max(total, 0.001))) }
        async let audio: Void = {
            if let audioIn { try await pump(audioOut, into: audioIn, offset: audioStart, first: leaderAudio, report: nil) }
        }()
        // Fed together so the writer can interleave every track while the video is being rendered.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (input, cues) in textInputs {
                group.addTask { try await TextTrack.write(cues, to: input, duration: total + lead) }
            }
            if let (input, cues) = captionInput {
                group.addTask { try await CEA608.write(cues, to: input, fps: fps, duration: total + lead) }
            }
            if let timecodeInput {
                let first = programStart + tc.frameCount(range.start.seconds) - leaderFrames
                let sample = try TimecodeTrack.sample(startFrame: (first % tc.framesPerDay + tc.framesPerDay) % tc.framesPerDay, duration: range.duration + leaderTime, try TimecodeTrack.formatDescription(tc))
                group.addTask { try await TextTrack.append([sample], to: timecodeInput) }
            }
            try await group.waitForAll()
        }
        _ = try await (video, audio)

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? EditError("Reading the timeline failed")
        }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? EditError("Writing \(url.lastPathComponent) failed") }
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

    /// Copies `first`, then samples from a reader output shifted back by `offset`, to a writer input.
    static func pump(_ output: AVAssetReaderOutput?, into input: AVAssetWriterInput, offset: CMTime, first: [CMSampleBuffer] = [], weave: FieldOrder? = nil, report: ((Seconds) -> Void)?) async throws {
        let queue = DispatchQueue(label: "cutline.export.\(input.mediaType.rawValue)")
        let box = PumpState()
        var next = 0
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                guard !box.finished else { return }
                while input.isReadyForMoreMediaData {
                    if next < first.count {
                        defer { next += 1 }
                        if !input.append(first[next]) {
                            box.finished = true
                            done.resume(throwing: EditError("The encoder rejected a leader frame"))
                            return
                        }
                        continue
                    }
                    guard let sample = weave.map({ Interlace.nextFrame(output, order: $0) }) ?? output?.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        box.finished = true
                        done.resume()
                        return
                    }
                    var buffer = sample
                    if offset != .zero, let shifted = Self.shift(sample, by: offset) { buffer = shifted }
                    report?(CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
                    if !input.append(buffer) {
                        box.finished = true
                        done.resume(throwing: EditError("The encoder rejected a frame"))
                        return
                    }
                }
            }
        }
    }

    final class PumpState: @unchecked Sendable {
        var finished = false
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
    static func formatDescription(_ type: AVMediaType) throws -> CMFormatDescription {
        let color: (Int) -> [String: Any] = { v in
            [kCMTextFormatDescriptionColor_Red as String: v, kCMTextFormatDescriptionColor_Green as String: v, kCMTextFormatDescriptionColor_Blue as String: v, kCMTextFormatDescriptionColor_Alpha as String: 255]
        }
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
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
    static func write(_ cues: [TimedText], to input: AVAssetWriterInput, duration: Seconds) async throws {
        let fd = try formatDescription(input.mediaType)
        var spans: [(Seconds, Seconds, String)] = []
        var t = 0.0
        for c in cues.sorted(by: { $0.start < $1.start }) where c.end > t {
            let s = max(c.start, t)
            if s > t + 0.001 { spans.append((t, s, "")) }
            spans.append((s, c.end, c.text))
            t = c.end
        }
        if duration > t + 0.001 { spans.append((t, duration, "")) }
        try await append(spans.map { try sample($0.0, $0.1, $0.2, fd) }, to: input)
    }

    static func append(_ samples: [CMSampleBuffer], to input: AVAssetWriterInput) async throws {
        let queue = DispatchQueue(label: "cutline.export.text")
        let state = Exporter.PumpState()
        var next = 0
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                guard !state.finished else { return }
                while input.isReadyForMoreMediaData {
                    guard next < samples.count else {
                        input.markAsFinished()
                        state.finished = true
                        done.resume()
                        return
                    }
                    if !input.append(samples[next]) {
                        state.finished = true
                        done.resume(throwing: EditError("The writer rejected a text or caption sample"))
                        return
                    }
                    next += 1
                }
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
