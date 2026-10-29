import AVFoundation
import CoreImage
import CutlineCore
import Foundation

/// A playable, renderable AVFoundation version of a project.
public struct BuiltTimeline: @unchecked Sendable {
    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    public let audioMix: AVAudioMix
    public let scene: RenderScene
    public let duration: Seconds

    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}

public enum TimelineBuilder {
    static let timescale: CMTimeScale = 60_000
    static let declick: Seconds = 0.008

    static func time(_ s: Seconds) -> CMTime { CMTime(seconds: s, preferredTimescale: timescale) }

    /// Builds the composition. Rendering size defaults to the canvas; pass `renderScale` to preview smaller.
    public static func build(_ project: Project, transcripts: [String: Transcript], library: MediaLibrary, renderScale: Double = 1) async throws -> BuiltTimeline {
        let duration = max(project.duration, project.canvas.frameDuration)
        let comp = AVMutableComposition()
        var trackIDs: [String: CMPersistentTrackID] = [:]
        var orientations: [String: CGImagePropertyOrientation] = [:]
        var images: [String: CIImage] = [:]
        var audioParams: [AVMutableAudioMixInputParameters] = []

        let base = try await BaseVideo.asset()
        if let baseTrack = try await base.loadTracks(withMediaType: .video).first,
           let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let one = CMTimeRange(start: .zero, duration: try await baseTrack.load(.timeRange).duration)
            try ct.insertTimeRange(one, of: baseTrack, at: .zero)
            ct.scaleTimeRange(CMTimeRange(start: .zero, duration: one.duration), toDuration: time(duration))
            trackIDs["__base"] = ct.trackID
        }

        for track in project.tracks {
            let clips = track.clips.filter { $0.kind == .media }
            guard !clips.isEmpty else { continue }
            var videoTrack: AVMutableCompositionTrack?
            var audioTrack: AVMutableCompositionTrack?
            var params: AVMutableAudioMixInputParameters?
            for clip in clips {
                guard let mid = clip.mediaId, let media = project.mediaAsset(mid) else { continue }
                if media.isImage {
                    if images[mid] == nil { images[mid] = library.image(for: media) }
                    continue
                }
                let entry = try await library.entry(for: media)
                orientations[mid] = entry.orientation
                let at = time(clip.start)
                let src = CMTimeRange(start: time(clip.sourceIn), end: time(clip.sourceOut))
                let target = time(clip.duration)

                if track.kind == .video, let v = entry.video, let vr = entry.videoRange {
                    if videoTrack == nil {
                        videoTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    try insert(src.intersection(vr), of: v, into: videoTrack!, at: at, sourceDuration: src.duration, target: target)
                }
                if let a = entry.audio, let ar = entry.audioRange, clip.volume > 0 {
                    if audioTrack == nil {
                        audioTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                        params = AVMutableAudioMixInputParameters(track: audioTrack)
                        params!.audioTimePitchAlgorithm = .spectral
                        params!.setVolume(0, at: .zero)
                    }
                    try insert(src.intersection(ar), of: a, into: audioTrack!, at: at, sourceDuration: src.duration, target: target)
                    let v = Float(track.muted ? 0 : clip.volume * track.volume)
                    let fi = max(clip.audioFadeIn, declick), fo = max(clip.audioFadeOut, declick)
                    params!.setVolumeRamp(fromStartVolume: 0, toEndVolume: v, timeRange: CMTimeRange(start: at, duration: time(min(fi, clip.duration / 2))))
                    params!.setVolumeRamp(fromStartVolume: v, toEndVolume: 0, timeRange: CMTimeRange(start: time(clip.end - min(fo, clip.duration / 2)), duration: time(min(fo, clip.duration / 2))))
                }
            }
            if let videoTrack { trackIDs[track.id] = videoTrack.trackID }
            if let params { audioParams.append(params) }
        }

        let scene = RenderScene(project: project, captions: project.captions.enabled ? project.captionSegments(transcripts: transcripts) : [], trackIDs: trackIDs, orientations: orientations, images: images)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = CutlineCompositor.self
        vc.frameDuration = CMTime(value: 1000, timescale: CMTimeScale(project.canvas.fps * 1000))
        let w = (Double(project.canvas.width) * renderScale / 2).rounded() * 2
        let h = (Double(project.canvas.height) * renderScale / 2).rounded() * 2
        vc.renderSize = CGSize(width: w, height: h)
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        vc.instructions = [CutlineInstruction(timeRange: CMTimeRange(start: .zero, duration: time(duration)), scene: scene)]

        let mix = AVMutableAudioMix()
        mix.inputParameters = audioParams
        return BuiltTimeline(composition: comp, videoComposition: vc, audioMix: mix, scene: scene, duration: duration)
    }

    /// Inserts `range` at `at`, padding with empty time so later inserts stay aligned, then
    /// scales it from the source duration to the timeline duration.
    static func insert(_ range: CMTimeRange, of source: AVAssetTrack, into track: AVMutableCompositionTrack, at: CMTime, sourceDuration: CMTime, target: CMTime) throws {
        let end = track.segments.isEmpty ? .zero : track.timeRange.end
        if at > end {
            track.insertEmptyTimeRange(CMTimeRange(start: end, end: at))
        }
        let start = max(at, end)
        guard range.duration > .zero else {
            track.insertEmptyTimeRange(CMTimeRange(start: start, duration: target))
            return
        }
        try track.insertTimeRange(range, of: source, at: start)
        if range.duration < sourceDuration {
            track.insertEmptyTimeRange(CMTimeRange(start: start + range.duration, duration: sourceDuration - range.duration))
        }
        if sourceDuration != target {
            track.scaleTimeRange(CMTimeRange(start: start, duration: sourceDuration), toDuration: target)
        }
    }
}

/// A one-second black clip stretched under every timeline so the compositor runs for every frame.
enum BaseVideo {
    nonisolated(unsafe) static var cached: AVURLAsset?
    static let lock = NSLock()

    static func asset() async throws -> AVURLAsset {
        if let a = lock.withLock({ cached }) { return a }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cutline", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("base-v1.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            let tmp = dir.appendingPathComponent("base-\(UUID().uuidString).mov")
            try await write(to: tmp)
            try? FileManager.default.moveItem(at: tmp, to: url)
        }
        let a = AVURLAsset(url: url)
        lock.withLock { cached = a }
        return a
    }

    static func write(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let pb else { throw EditError("Cannot allocate base frame") }
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
        CVPixelBufferUnlockBaseAddress(pb, [])
        for i in 0...30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? EditError("Cannot write base video") }
    }
}
