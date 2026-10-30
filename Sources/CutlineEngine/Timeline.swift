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
    /// Tracks with audio effects whose processed stem isn't rendered yet; they play dry.
    public let missingStems: [String]
    /// The master layout. When it isn't stereo the composition plays a stereo fold-down of `surround`.
    public let layout: AudioLayout
    /// The rendered mix in `layout` (48 kHz float CAF), which export and delivery write instead of the composition's sound.
    public let surround: URL?
    /// Clips with temporal effects whose processed picture isn't rendered yet; they play unprocessed.
    public var missingPictures: [String] = []

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
    /// Tracks with audio effects play their cached stem from `stems`, or dry when it isn't rendered yet.
    public static func build(_ project: Project, transcripts: [String: Transcript], library: MediaLibrary, renderScale: Double = 1, stems: AudioStems? = nil) async throws -> BuiltTimeline {
        try await build(project, transcripts: transcripts, library: library, renderScale: renderScale, stems: stems, dryTrack: nil, masterStage: true)
    }

    /// `dryTrack` builds only that track's sound, before track gain and effects, for stem rendering.
    /// With `masterStage`, a rendered master stem (the mix through the master effects) replaces the tracks' sound,
    /// or for a mono or surround layout, the fold-down of the rendered layout mix. `soundOnly` skips the picture.
    static func build(_ project: Project, transcripts: [String: Transcript], library: MediaLibrary, renderScale: Double, stems: AudioStems?, dryTrack: String?, masterStage: Bool, soundOnly: Bool = false) async throws -> BuiltTimeline {
        let project = project.resolvingAudioTransitions()
        var heads: [String: Seconds] = [:], tails: [String: Seconds] = [:]
        for w in project.transitionWindows where w.transition.hasVideo {
            if let id = w.transition.from { tails[id] = max(tails[id] ?? 0, w.tail) }
            if let id = w.transition.to { heads[id] = max(heads[id] ?? 0, w.head) }
        }
        for c in project.tracks.flatMap(\.clips) where c.kind == .sequence {
            guard let seq = c.mediaId.flatMap({ project.sequence($0) }) else { continue }
            for w in project.inside(seq).transitionWindows where w.transition.hasVideo {
                if let id = w.transition.from { tails["\(c.id)/\(id)"] = w.tail }
                if let id = w.transition.to { heads["\(c.id)/\(id)"] = w.head }
            }
        }
        let duration = max(project.duration, project.canvas.frameDuration)
        let comp = AVMutableComposition()
        var trackIDs: [String: CMPersistentTrackID] = [:]
        var orientations: [String: CGImagePropertyOrientation] = [:]
        var images: [String: CIImage] = [:]
        var audioParams: [AVMutableAudioMixInputParameters] = []
        var missingStems: [String] = []
        var missingPictures: [String] = []
        let master = dryTrack == nil ? project.master.gain : 1
        var masterStem: URL?
        var surround: URL?
        // Tracks only weakly reference their asset, so proxies stay alive until the build is done.
        var proxies: [AVURLAsset] = []
        defer { _ = proxies }
        if masterStage, dryTrack == nil, project.master.layout != .stereo {
            if let cached = stems?.cachedLayoutMix(for: project) {
                surround = cached.mix
                masterStem = cached.foldDown
            } else {
                missingStems.append("layout")
            }
        } else if masterStage, dryTrack == nil, AudioStems.hasMasterChain(project) {
            masterStem = stems?.cachedMaster(for: project)
            if masterStem == nil { missingStems.append("master") }
        }

        if dryTrack == nil, !soundOnly {
            let base = try await BaseVideo.asset()
            if let baseTrack = try await base.loadTracks(withMediaType: .video).first,
               let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let one = CMTimeRange(start: .zero, duration: try await baseTrack.load(.timeRange).duration)
                try ct.insertTimeRange(one, of: baseTrack, at: .zero)
                ct.scaleTimeRange(CMTimeRange(start: .zero, duration: one.duration), toDuration: time(duration))
                trackIDs["__base"] = ct.trackID
            }
        }

        for track in project.tracks {
            if let dryTrack, track.id != dryTrack { continue }
            // Nested sequences contribute their own media clips, with ids "<sequence clip>/<inner clip>".
            let clips: [(kind: TrackKind, clip: Clip)] = track.clips.flatMap { c -> [(kind: TrackKind, clip: Clip)] in
                if c.kind == .sequence { return project.expanded(c).filter { $0.clip.kind == .media }.map { (track.kind == .audio ? .audio : $0.kind, $0.clip) } }
                return c.kind == .media ? [(track.kind, c)] : []
            }
            guard !clips.isEmpty else { continue }
            let trackGain = dryTrack != nil ? 1 : (track.muted ? 0 : track.volume) * master
            let fader: Curve? = dryTrack != nil || track.muted ? nil : track.volumeCurve.map { c in Curve(keys: c.keys.map { var k = $0; k.v = .number(($0.v.number ?? 1) * master); return k }) }
            let hasAudioFx = track.effects.contains { EffectCatalog.isAudio($0.type) && $0.enabled }
            var stemURL: URL?
            if dryTrack == nil, hasAudioFx, masterStem == nil {
                stemURL = stems?.cachedStem(for: track, in: project)
                if stemURL == nil { missingStems.append(track.id) }
            }
            // Clips meeting in a transition overlap by their handles, so they alternate between picture lanes.
            var videoLanes: [(track: AVMutableCompositionTrack, end: Seconds)] = []
            // Split edits can overlap neighbouring sound, so each track gets as many audio lanes as it needs.
            var lanes: [(track: AVMutableCompositionTrack, params: AVMutableAudioMixInputParameters, end: Seconds)] = []
            for (pictureKind, clip) in clips {
                guard let mid = clip.mediaId, let media = project.mediaAsset(mid) else { continue }
                if media.isImage {
                    if images[mid] == nil, dryTrack == nil, !soundOnly { images[mid] = library.image(for: media) }
                    continue
                }
                let entry = try await library.entry(for: media)
                orientations[mid] = entry.orientation
                // Reversed clips read an upright backwards copy whose time 0 is the range's end.
                var video = entry.video, videoRange = entry.videoRange, audio = entry.audio, audioRange = entry.audioRange
                var base = clip.sourceIn
                if clip.reverse {
                    let maxSize = CGSize(width: project.canvas.width, height: project.canvas.height)
                    let proxy = AVURLAsset(url: try await ReverseProxy.url(for: media, range: TimeRange(clip.sourceIn, clip.sourceOut), maxSize: maxSize))
                    proxies.append(proxy)
                    video = try await proxy.loadTracks(withMediaType: .video).first
                    audio = try await proxy.loadTracks(withMediaType: .audio).first
                    videoRange = try await video?.load(.timeRange)
                    audioRange = try await audio?.load(.timeRange)
                    orientations[clip.id] = .up
                    base = 0
                }

                // Temporal effects play a processed copy of the picture once it is rendered.
                var videoBase = base
                if dryTrack == nil, !soundOnly, pictureKind == .video,
                   let req = ProcessedPicture.request(clip, media: media, canvas: project.canvas, head: heads[clip.id] ?? 0, tail: tails[clip.id] ?? 0) {
                    if let url = ProcessedPicture.cached(req) {
                        let proxy = AVURLAsset(url: url)
                        proxies.append(proxy)
                        if let pv = try await proxy.loadTracks(withMediaType: .video).first {
                            video = pv
                            videoRange = try await pv.load(.timeRange)
                            videoBase = clip.sourceIn - req.range.start
                            orientations[clip.id] = .up
                        }
                    } else {
                        missingPictures.append(clip.id)
                    }
                }

                if dryTrack == nil, !soundOnly, pictureKind == .video, let v = video, let vr = videoRange {
                    let head = heads[clip.id] ?? 0, tail = tails[clip.id] ?? 0
                    let start = clip.start - head
                    var lane = videoLanes.firstIndex { $0.end <= start + 1e-6 }
                    if lane == nil, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                        videoLanes.append((t, -.infinity))
                        lane = videoLanes.count - 1
                    }
                    let smooth = clip.interpolate.flatMap(RetimeProxy.Interpolation.init(rawValue:))
                    if let lane, let smooth, clip.isRetimed || clip.speed < 0.99 {
                        // Slowed footage plays a pre-rendered copy with in-between frames, upright, one frame per output frame.
                        let made = try await RetimeProxy.url(for: media, clip: clip, head: head, tail: tail, fps: project.canvas.fps, maxSize: CGSize(width: project.canvas.width, height: project.canvas.height), interpolation: smooth)
                        let proxy = AVURLAsset(url: made.url)
                        proxies.append(proxy)
                        if let pv = try await proxy.loadTracks(withMediaType: .video).first {
                            let total = clip.duration + head + tail
                            let range = CMTimeRange(start: .zero, duration: time(total))
                            try insert(range.intersection(try await pv.load(.timeRange)), of: pv, into: videoLanes[lane].track, at: time(clip.start - head), sourceDuration: time(total), target: time(total))
                            orientations[clip.id] = .up
                        }
                        videoLanes[lane].end = clip.end + tail
                        trackIDs[clip.id] = videoLanes[lane].track.trackID
                    } else if let lane {
                        try insertPieces(clip, from: -head, to: clip.duration + tail, base: videoBase, fps: project.canvas.fps, source: v, available: vr, into: videoLanes[lane].track)
                        videoLanes[lane].end = clip.end + tail
                        trackIDs[clip.id] = videoLanes[lane].track.trackID
                    }
                }
                guard stemURL == nil, masterStem == nil, let a = audio, let ar = audioRange, clip.volume > 0 || clip.anim["audio.volume"] != nil else { continue }
                let span = clip.audioRange
                guard span.duration > 0.01 else { continue }
                // Clips with their own audio effects or channel routing play a processed copy of their sound.
                var clipStem: AVAssetTrack?
                if AudioStems.needsClipStem(clip) {
                    let (solo, soloTrack) = AudioStems.solo(clip, in: project)
                    if let url = stems?.cachedStem(for: soloTrack, in: solo) {
                        let asset = AVURLAsset(url: url)
                        proxies.append(asset)
                        clipStem = try await asset.loadTracks(withMediaType: .audio).first
                    } else {
                        missingStems.append(clip.id)
                    }
                }
                var lane = lanes.firstIndex { $0.end <= span.start + 1e-6 }
                if lane == nil {
                    guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    let params = AVMutableAudioMixInputParameters(track: t)
                    params.audioTimePitchAlgorithm = .spectral
                    params.setVolume(0, at: .zero)
                    lanes.append((t, params, -.infinity))
                    lane = lanes.count - 1
                }
                if let clipStem {
                    let range = CMTimeRange(start: time(span.start), end: time(span.end))
                    try insert(range.intersection(try await clipStem.load(.timeRange)), of: clipStem, into: lanes[lane!].track, at: time(span.start), sourceDuration: range.duration, target: range.duration)
                    if let fader {
                        addFader(fader, from: span.start, to: span.end, to: lanes[lane!].params)
                    } else {
                        lanes[lane!].params.setVolume(Float(trackGain), at: time(span.start))
                    }
                } else {
                    try insertPieces(clip, from: -clip.audioLead, to: clip.duration + clip.audioLag, base: base, fps: 20, source: a, available: ar, into: lanes[lane!].track)
                    addVolumeEnvelope(clip, trackGain: trackGain, fader: fader, to: lanes[lane!].params)
                }
                lanes[lane!].end = span.end
            }
            audioParams += lanes.map(\.params)
            if let stemURL {
                let stem = AVURLAsset(url: stemURL)
                if let st = try await stem.loadTracks(withMediaType: .audio).first,
                   let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try t.insertTimeRange(try await st.load(.timeRange), of: st, at: .zero)
                    let params = AVMutableAudioMixInputParameters(track: t)
                    if let fader { addFader(fader, from: 0, to: duration, to: params) } else { params.setVolume(Float(trackGain), at: .zero) }
                    audioParams.append(params)
                }
            }
        }

        if let masterStem {
            let stem = AVURLAsset(url: masterStem)
            if let st = try await stem.loadTracks(withMediaType: .audio).first,
               let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try t.insertTimeRange(try await st.load(.timeRange), of: st, at: .zero)
                let params = AVMutableAudioMixInputParameters(track: t)
                params.setVolume(1, at: .zero)
                audioParams.append(params)
            }
        }

        // Tracks that stop early would leave a reader waiting for frames; pad them with empty time to the end.
        for t in comp.tracks where t.mediaType == .video && !t.segments.isEmpty && t.timeRange.end < time(duration) {
            t.insertEmptyTimeRange(CMTimeRange(start: t.timeRange.end, end: time(duration)))
        }
        let scene = RenderScene(project: project, captions: project.captions.enabled && dryTrack == nil ? project.captionSegments(transcripts: transcripts) : [], trackIDs: trackIDs, orientations: orientations, images: images)
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = CutlineCompositor.compositorClass(project.canvas.colorSpace)
        vc.frameDuration = CMTime(value: 1000, timescale: CMTimeScale(project.canvas.fps * 1000))
        let w = (Double(project.canvas.width) * renderScale / 2).rounded() * 2
        let h = (Double(project.canvas.height) * renderScale / 2).rounded() * 2
        vc.renderSize = CGSize(width: w, height: h)
        let tags = ColorManagement.videoCompositionTags(project.canvas.colorSpace)
        vc.colorPrimaries = tags.primaries
        vc.colorTransferFunction = tags.transfer
        vc.colorYCbCrMatrix = tags.matrix
        vc.instructions = [CutlineInstruction(timeRange: CMTimeRange(start: .zero, duration: time(duration)), scene: scene)]

        let mix = AVMutableAudioMix()
        mix.inputParameters = audioParams
        var built = BuiltTimeline(composition: comp, videoComposition: vc, audioMix: mix, scene: scene, duration: duration, missingStems: missingStems, layout: project.master.layout, surround: surround)
        built.missingPictures = missingPictures
        return built
    }

    /// Gain over the clip's sound: animated or fixed volume, times fades, with a few ms of ramp at
    /// the edges so cuts don't click. Animated volume is sampled every 50 ms. Times are relative
    /// to the clip's picture start, so split-edit lead is negative.
    /// Ramps following fader automation, sampled every 50 ms.
    static func addFader(_ curve: Curve, from a: Seconds, to b: Seconds, to params: AVMutableAudioMixInputParameters) {
        var t = a
        while t < b - 1e-4 {
            let n = min(b, t + 0.05)
            params.setVolumeRamp(fromStartVolume: Float(max(0, curve.value(at: t)?.number ?? 1)), toEndVolume: Float(max(0, curve.value(at: n)?.number ?? 1)), timeRange: CMTimeRange(start: time(t), duration: time(n - t)))
            t = n
        }
    }

    static func addVolumeEnvelope(_ clip: Clip, trackGain: Double, fader: Curve? = nil, to params: AVMutableAudioMixInputParameters) {
        let a0 = -clip.audioLead, a1 = clip.duration + clip.audioLag
        let len = a1 - a0
        guard len > 0 else { return }
        let fi = min(max(clip.audioFadeIn, declick), len / 2)
        let fo = min(max(clip.audioFadeOut, declick), len / 2)
        func gain(_ local: Seconds) -> Float {
            var g = clip.number("audio.volume", at: local, default: clip.volume) * (fader?.value(at: clip.start + local)?.number ?? trackGain)
            if local - a0 < fi { g *= max(0, local - a0) / fi }
            if a1 - local < fo { g *= max(0, a1 - local) / fo }
            return Float(max(0, g))
        }
        var points: [Seconds] = [a0, a0 + fi, a1 - fo, a1]
        if fader != nil { points += stride(from: a0, to: a1, by: 0.05).map { $0 } }
        if let curve = clip.anim["audio.volume"] {
            points += stride(from: a0, to: a1, by: 0.05).map { $0 }
            points += curve.keys.map(\.t).filter { $0 > a0 && $0 < a1 }
        }
        let sorted = Array(Set(points.map { ($0 * 10000).rounded() / 10000 })).filter { $0 >= a0 && $0 <= a1 }.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) where b - a > 1e-4 {
            params.setVolumeRamp(fromStartVolume: gain(a), toEndVolume: gain(min(b, a1 - 1e-6)), timeRange: CMTimeRange(start: time(clip.start + a), duration: time(b - a)))
        }
    }

    /// Inserts a clip's media from local time `a` to `b` (beyond its edges for handles and split edits).
    /// Speed curves become one constant-speed piece per step; held frames repeat a sliver of source.
    static func insertPieces(_ clip: Clip, from a: Seconds, to b: Seconds, base: Seconds, fps: Double, source: AVAssetTrack, available: CMTimeRange, into track: AVMutableCompositionTrack) throws {
        let d = clip.duration
        let endOffset = clip.sourceOffset(atLocal: d)
        func offset(_ t: Seconds) -> Seconds {
            if t <= 0 { return t * clip.speed(atLocal: 0) }
            if t >= d { return endOffset + (t - d) * clip.speed(atLocal: d) }
            return clip.sourceOffset(atLocal: t)
        }
        var steps: [Seconds] = [a]
        if clip.isRetimed {
            var t = (a * fps).rounded(.down) / fps + 1 / fps
            while t < b - 1e-6 {
                steps.append(t)
                t += 1 / fps
            }
        }
        steps.append(b)
        // Offsets are computed in one pass; sourceOffset integrates from 0 each call.
        let offsets = clip.isRetimed ? Self.offsets(clip, steps) : steps.map(offset)
        for i in 0..<(steps.count - 1) where steps[i + 1] - steps[i] > 1e-6 {
            let s0 = base + offsets[i]
            let s1 = max(base + offsets[i + 1], s0 + 1.0 / 600)
            let src = CMTimeRange(start: time(s0), end: time(s1))
            try insert(src.intersection(available), of: source, into: track, at: time(clip.start + steps[i]), sourceDuration: src.duration, target: time(steps[i + 1] - steps[i]))
        }
    }

    /// Source offsets at increasing local times, integrating the speed curve once.
    static func offsets(_ clip: Clip, _ times: [Seconds]) -> [Seconds] {
        let d = clip.duration
        let v0 = clip.speed(atLocal: 0), v1 = clip.speed(atLocal: d)
        var out: [Seconds] = []
        var acc = 0.0, at = 0.0
        var prev = v0
        let h = 1.0 / 480
        var endOffset: Seconds?
        for t in times {
            if t <= 0 { out.append(t * v0); continue }
            let target = min(t, d)
            while at < target - 1e-12 {
                let step = min(h, target - at)
                let cur = clip.speed(atLocal: at + step)
                acc += (prev + cur) * step / 2
                prev = cur
                at += step
            }
            if t >= d {
                if endOffset == nil { endOffset = acc }
                out.append(endOffset! + (t - d) * v1)
            } else {
                out.append(acc)
            }
        }
        return out
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
