import AVFoundation
import CoreMedia
import CutlineCore
import Foundation
import VideoToolbox

public enum ExportPreset: String, CaseIterable, Sendable {
    case hevc
    case h264
    case prores
    /// ProRes 4444 with alpha, for overlays and graphics.
    case prores4444

    public var fileType: AVFileType { isProRes ? .mov : .mp4 }
    public var fileExtension: String { isProRes ? "mov" : "mp4" }
    var isProRes: Bool { self == .prores || self == .prores4444 }

    var codec: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        case .prores: .proRes422
        case .prores4444: .proRes4444
        }
    }

    /// Bits per second for a frame size and rate when no bitrate is given (high quality, delivery grade).
    func defaultBitrate(width: Int, height: Int, fps: Double) -> Int {
        let pixels = Double(width * height) * max(fps, 24)
        switch self {
        case .hevc: return Int(pixels * 0.09)
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

    public init(preset: ExportPreset = .hevc, bitrateMbps: Double? = nil, range: TimeRange? = nil, subtitles: [TimedText] = [], subtitleLanguage: String = "en", chapters: [TimedText] = [], closedCaptions: [TimedText] = [], audioKbps: Int = 256) {
        self.preset = preset
        self.bitrateMbps = bitrateMbps
        self.range = range
        self.subtitles = subtitles
        self.subtitleLanguage = subtitleLanguage
        self.chapters = chapters
        self.closedCaptions = closedCaptions
        self.audioKbps = audioKbps
    }
}

/// Renders a timeline with AVAssetReader → AVAssetWriter: the same compositor as preview,
/// with codec, bitrate, Rec. 709 color tags, and optional subtitle, chapter and closed caption tracks.
public enum Exporter {
    public static func export(_ built: BuiltTimeline, to url: URL, options: ExportOptions, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let comp = built.composition
        let reader = try AVAssetReader(asset: comp)
        let range = options.range.map { CMTimeRange(start: TimelineBuilder.time($0.start), end: TimelineBuilder.time(min($0.end, built.duration))) }
            ?? CMTimeRange(start: .zero, duration: TimelineBuilder.time(built.duration))
        reader.timeRange = range

        let size = built.videoComposition.renderSize
        let space = built.scene.project.canvas.colorSpace
        if space.isHDR && options.preset == .h264 { throw EditError("HDR needs HEVC or ProRes; use preset hevc") }
        let videoTracks = try await comp.loadTracks(withMediaType: .video)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: ColorManagement.pixelFormat(space),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)

        // Sound is mixed to a file first and read by its own reader: one reader feeding both writer inputs
        // can stall when the writer holds one stream back to interleave with the other.
        let audioTracks = try await comp.loadTracks(withMediaType: .audio)
        var audioOut: AVAssetReaderTrackOutput?
        var audioReader: AVAssetReader?
        let mixFile = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-mix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: mixFile) }
        if !audioTracks.isEmpty {
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
        let writer = try AVAssetWriter(outputURL: url, fileType: options.preset.fileType)
        writer.shouldOptimizeForNetworkUse = true

        let fps = built.scene.project.canvas.fps
        var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: fps]
        if !options.preset.isProRes {
            let bitrate = options.bitrateMbps.map { Int($0 * 1_000_000) } ?? options.preset.defaultBitrate(width: Int(size.width), height: Int(size.height), fps: fps)
            compression[AVVideoAverageBitRateKey] = bitrate
            compression[AVVideoMaxKeyFrameIntervalDurationKey] = 2
            compression[AVVideoAllowFrameReorderingKey] = true
            compression[AVVideoProfileLevelKey] = options.preset == .hevc ? (space.isHDR ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel) as String : AVVideoProfileLevelH264HighAutoLevel
        }
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: options.preset.codec,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: ColorManagement.writerColorProperties(space),
        ]
        if !compression.isEmpty && !options.preset.isProRes { videoSettings[AVVideoCompressionPropertiesKey] = compression }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let settings: [String: Any] = options.preset.isProRes
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: options.audioKbps * 1000]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        let offset = range.start
        func inRange(_ cues: [TimedText]) -> [TimedText] {
            cues.compactMap { c in
                let s = max(c.start, offset.seconds), e = min(c.end, range.end.seconds)
                return e > s ? TimedText(start: s - offset.seconds, end: e - offset.seconds, text: c.text) : nil
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

        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read the timeline") }
        if let audioReader, !audioReader.startReading() { throw audioReader.error ?? EditError("Cannot read the mixed sound") }
        guard writer.startWriting() else { throw writer.error ?? EditError("Cannot write \(url.lastPathComponent)") }
        writer.startSession(atSourceTime: .zero)

        let total = range.duration.seconds
        async let video: Void = pump(videoOut, into: videoIn, offset: offset) { t in progress?(min(1, t / max(total, 0.001))) }
        async let audio: Void = {
            if let audioOut, let audioIn { try await pump(audioOut, into: audioIn, offset: .zero, report: nil) }
        }()
        // Fed together so the writer can interleave every track while the video is being rendered.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (input, cues) in textInputs {
                group.addTask { try await TextTrack.write(cues, to: input, duration: total) }
            }
            if let (input, cues) = captionInput {
                group.addTask { try await CEA608.write(cues, to: input, fps: fps, duration: total) }
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

    /// Copies samples from a reader output to a writer input, shifting them to start at zero.
    static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, offset: CMTime, report: ((Seconds) -> Void)?) async throws {
        let queue = DispatchQueue(label: "cutline.export.\(input.mediaType.rawValue)")
        let box = PumpState()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            input.requestMediaDataWhenReady(on: queue) {
                guard !box.finished else { return }
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
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
