import AVFoundation
import CutlineCore
import Foundation

extension AudioLayout {
    /// Core Audio layout whose channel order matches `channelNames`.
    public var channelLayoutTag: AudioChannelLayoutTag {
        switch self {
        case .mono: kAudioChannelLayoutTag_Mono
        case .stereo: kAudioChannelLayoutTag_Stereo
        case .surround51: kAudioChannelLayoutTag_MPEG_5_1_A
        case .surround71: kAudioChannelLayoutTag_MPEG_7_1_C
        }
    }

    /// The same speakers in AAC's and ALAC's channel order; nil for 7.1, which both only carry with
    /// front-wide speakers instead of rear surrounds.
    var codecChannelLayoutTag: AudioChannelLayoutTag? {
        switch self {
        case .surround51: kAudioChannelLayoutTag_MPEG_5_1_D
        case .surround71: nil
        default: channelLayoutTag
        }
    }

    /// For each channel of `tag`, its index in this layout's order.
    func channelOrder(in tag: AudioChannelLayoutTag) -> [Int] {
        let ours = Self.labels(channelLayoutTag), theirs = Self.labels(tag)
        return theirs.enumerated().map { i, label in ours.firstIndex(of: label) ?? i }
    }

    static func labels(_ tag: AudioChannelLayoutTag) -> [AudioChannelLabel] {
        var t = tag
        var size: UInt32 = 0
        let tagSize = UInt32(MemoryLayout<AudioChannelLayoutTag>.size)
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, tagSize, &t, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, tagSize, &t, &size, raw) == noErr else { return [] }
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        let n = Int(layout.pointee.mNumberChannelDescriptions)
        return withUnsafePointer(to: &layout.pointee.mChannelDescriptions) { p in
            p.withMemoryRebound(to: AudioChannelDescription.self, capacity: n) { d in (0..<n).map { d[$0].mChannelLabel } }
        }
    }

    var channelLayout: AVAudioChannelLayout { AVAudioChannelLayout(layoutTag: channelLayoutTag)! }

    /// `AudioChannelLayout` bytes for `AVChannelLayoutKey`.
    var channelLayoutData: Data { Self.layoutData(channelLayoutTag) }

    static func layoutData(_ tag: AudioChannelLayoutTag) -> Data {
        let l = AVAudioChannelLayout(layoutTag: tag)!
        return withExtendedLifetime(l) { Data(bytes: l.layout, count: MemoryLayout<AudioChannelLayout>.size) }
    }

    /// Deinterleaved float at the stem rate.
    var floatFormat: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: AudioStems.sampleRate, channelLayout: channelLayout) }

    var floatFileSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioStems.sampleRate, AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: channelLayoutData,
        ]
    }

    /// The layout a file with this many channels is read as.
    init?(channelCount: Int) {
        guard let l = AudioLayout.allCases.first(where: { $0.channelCount == channelCount }) else { return nil }
        self = l
    }
}

/// Mono and surround mixes. Each clip's sound is rendered dry with its own envelope, the track fader and the
/// master gain (the stereo machinery), then panned into the layout by `SurroundPanner` with its `audio.pan_x`,
/// `audio.pan_y`, `audio.center` and `audio.lfe`; mono sources are panned as one point, stereo sources as a
/// pair. Tracks with audio effects are panned as their processed stem, following the clip playing at each moment.
/// Master effects then run per channel pair (L/R, Ls/Rs, Lrs/Rrs) and on C and LFE alone.
/// A mono layout is the stereo mix folded to one channel.
public enum SurroundMix {
    static let window: Seconds = 30
    static let block = 256
    static let lfeCutoff = 120.0

    /// Renders (or reuses) the project's mix in its master layout: a 1, 6 or 8 channel 48 kHz float CAF tagged
    /// with its channel layout. Clip and track effect stems are rendered first.
    public static func renderSurround(_ project: Project, transcripts: [String: Transcript] = [:], library: MediaLibrary, stems: AudioStems) async throws -> URL {
        guard project.master.layout != .stereo else { throw EditError("The master layout is stereo; set it to mono, surround51 or surround71 first") }
        try await stems.renderMissing(project, transcripts: transcripts, library: library)
        guard let made = stems.cachedLayoutMix(for: project) else { throw EditError("The \(project.master.layout.title) mix wasn't rendered") }
        return made.mix
    }

    /// Fourth-order Butterworth low-pass at 120 Hz for the LFE send.
    static func lfeFilter() -> [LoudnessMeter.Biquad] {
        [0.54119610, 1.3065630].map { q in
            let c = AudioDSP.Biquad.lowPass(lfeCutoff, q: q, AudioStems.sampleRate)
            return LoudnessMeter.Biquad(b0: c[0], b1: c[1], b2: c[2], a1: c[3], a2: c[4])
        }
    }

    /// Low-passes a signal for the LFE channel.
    public static func lowPassLFE(_ x: [Float]) -> [Float] {
        var f = lfeFilter()
        return x.map { v in Float(f.indices.reduce(Double(v)) { f[$1].run($0) }) }
    }

    /// One sound panned into the mix: a clip, or a whole track's processed stem.
    final class Source {
        let built: BuiltTimeline
        let start: Int64, end: Int64
        /// Clips whose pan applies, with their sound's timeline range.
        let segments: [(range: TimeRange, clip: Clip)]
        let mono: Bool
        var lfe = SurroundMix.lfeFilter()

        init(built: BuiltTimeline, range: TimeRange, segments: [(range: TimeRange, clip: Clip)], mono: Bool) {
            self.built = built
            start = Int64((max(0, range.start) * AudioStems.sampleRate).rounded())
            end = Int64((range.end * AudioStems.sampleRate).rounded())
            self.segments = segments
            self.mono = mono
        }

        /// Gains applied to the source's left and right channels, and its LFE send, at a timeline time.
        func gains(at t: Seconds, layout: AudioLayout) -> (left: [Double], right: [Double], lfe: Double) {
            var active = segments.filter { $0.range.start <= t && t < $0.range.end }
            if active.isEmpty, let held = segments.last(where: { $0.range.end <= t }) ?? segments.first { active = [held] }
            let n = layout.channelCount
            var l = [Double](repeating: 0, count: n), r = l
            var lfe = 0.0
            for (_, clip) in active {
                let local = t - clip.start
                let x = clip.number("audio.pan_x", at: local), y = clip.number("audio.pan_y", at: local, default: 1)
                let c = clip.number("audio.center", at: local, default: 1)
                lfe += clip.number("audio.lfe", at: local)
                if mono {
                    let g = SurroundPanner.gains(x: x, y: y, center: c, layout: layout)
                    for i in 0..<n { l[i] += 0.25 * g[i] * g[i] }
                    r = l
                } else {
                    let p = SurroundPanner.pairGains(x: x, y: y, center: c, layout: layout)
                    for i in 0..<n {
                        l[i] += p.left[i] * p.left[i]
                        r[i] += p.right[i] * p.right[i]
                    }
                }
            }
            let k = Double(max(active.count, 1))
            return (l.map { ($0 / k).squareRoot() }, r.map { ($0 / k).squareRoot() }, lfe / k)
        }
    }

    /// The sounds to pan, each with a timeline that plays only that sound (gains, fades and fader included).
    static func sources(_ project: Project, library: MediaLibrary, transcripts: [String: Transcript], stems: AudioStems) async throws -> [Source] {
        let resolved = project.resolvingAudioTransitions()
        let duration = max(resolved.duration, resolved.canvas.frameDuration)
        var out: [Source] = []
        for track in resolved.tracks where !track.muted {
            let clips = track.clips.filter { $0.kind == .media || $0.kind == .sequence }
            guard !clips.isEmpty else { continue }
            var solo = resolved
            solo.transitions = []
            if track.effects.contains(where: { EffectCatalog.isAudio($0.type) && $0.enabled }) {
                solo.tracks = [track]
                let built = try await TimelineBuilder.build(solo, transcripts: transcripts, library: library, renderScale: 1, stems: stems, dryTrack: nil, masterStage: false, soundOnly: true)
                out.append(Source(built: built, range: TimeRange(0, duration), segments: clips.map { ($0.audioRange, $0) }, mono: false))
                continue
            }
            for clip in clips where clip.volume > 0 || clip.anim["audio.volume"] != nil {
                var mono = false
                if clip.kind == .media {
                    guard let media = clip.mediaId.flatMap({ resolved.mediaAsset($0) }), media.hasAudio, !media.isImage else { continue }
                    if let routing = clip.channels, !routing.isAsRecorded, !clip.reverse { mono = routing.isMono } else { mono = try await channelCount(media, library: library) == 1 || clip.channels?.isMono == true }
                }
                var t = track
                t.clips = [clip]
                solo.tracks = [t]
                let range = TimeRange(max(0, clip.audioRange.start), min(duration, clip.audioRange.end))
                guard range.duration > 0.001 else { continue }
                let built = try await TimelineBuilder.build(solo, transcripts: transcripts, library: library, renderScale: 1, stems: stems, dryTrack: nil, masterStage: false, soundOnly: true)
                out.append(Source(built: built, range: range, segments: [(clip.audioRange, clip)], mono: mono))
            }
        }
        return out
    }

    static func channelCount(_ media: MediaAsset, library: MediaLibrary) async throws -> Int {
        guard let track = try await library.entry(for: media).audio else { return 0 }
        let fds = try await track.load(.formatDescriptions)
        return fds.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }.map(Int.init) ?? 2
    }

    /// Pans every source into `layout`, window by window, and writes `frames` frames of float to `url`.
    static func pan(_ sources: [Source], layout: AudioLayout, frames: Int64, to url: URL) async throws {
        let n = layout.channelCount
        let rate = AudioStems.sampleRate
        let file = try AVAudioFile(forWriting: url, settings: layout.floatFileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let windowFrames = Int64(window * rate)
        var w0: Int64 = 0
        while w0 < frames {
            let w1 = min(frames, w0 + windowFrames)
            let len = Int(w1 - w0)
            var mix = [[Float]](repeating: [Float](repeating: 0, count: len), count: n)
            for src in sources where src.start < w1 && src.end > w0 {
                let a = max(src.start, w0), b = min(src.end, w1)
                try await AudioIO.readPlaced(src.built, range: TimeRange(Double(a) / rate, Double(b) / rate)) { samples, count, at in
                    var i = 0
                    while i < count {
                        let g = a + at + Int64(i)
                        guard g >= a, g < b else { i += 1; continue }
                        let m = min(block, count - i, Int(b - g))
                        let t0 = Double(g) / rate
                        let g0 = src.gains(at: t0, layout: layout), g1 = src.gains(at: t0 + Double(m) / rate, layout: layout)
                        let base = Int(g - w0)
                        for j in 0..<m {
                            let f = Double(j) / Double(m)
                            let l = Double(samples[2 * (i + j)]), r = Double(samples[2 * (i + j) + 1])
                            for c in 0..<n {
                                let gl = g0.left[c] + (g1.left[c] - g0.left[c]) * f
                                let gr = g0.right[c] + (g1.right[c] - g0.right[c]) * f
                                if gl != 0 || gr != 0 { mix[c][base + j] += Float(gl * l + gr * r) }
                            }
                            if let lfeCh = layout.lfeChannel {
                                let send = g0.lfe + (g1.lfe - g0.lfe) * f
                                var y = 0.5 * (l + r)
                                for k in src.lfe.indices { y = src.lfe[k].run(y) }
                                mix[lfeCh][base + j] += Float(send * y)
                            }
                        }
                        i += m
                    }
                }
            }
            try AudioIO.write(mix, to: file)
            w0 = w1
        }
    }

    /// Runs the master effects over a layout mix: L/R, Ls/Rs and Lrs/Rrs as stereo pairs, C and LFE alone.
    static func processMaster(_ dry: URL, layout: AudioLayout, frames: Int64, effects: [Effect], to url: URL, scratch: URL) async throws {
        let groups: [[Int]] = layout == .mono ? [[0]] : [[0, 1], [2], [3], [4, 5]] + (layout == .surround71 ? [[6, 7]] : [])
        var processed: [URL] = []
        defer { for u in processed { try? FileManager.default.removeItem(at: u) } }
        for group in groups {
            let pairDry = scratch.appendingPathComponent("dry-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: pairDry) }
            let out = scratch.appendingPathComponent("dry-\(UUID().uuidString).caf")
            processed.append(out)
            let picks = group.count == 2 ? group : [group[0], group[0]]
            try AudioIO.convert(dry, matrix: picks.map { c in (0..<layout.channelCount).map { $0 == c ? 1 : 0 } }, layout: .stereo, frames: 0..<frames, to: pairDry)
            try await AudioChain.process(dry: pairDry, frames: AVAudioFramePosition(frames), effects: effects, to: out)
        }
        let file = try AVAudioFile(forWriting: url, settings: layout.floatFileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let readers = try processed.map { try AVAudioFile(forReading: $0) }
        let chunk: Int64 = 65_536
        var at: Int64 = 0
        while at < frames {
            let len = Int(min(chunk, frames - at))
            var mix = [[Float]](repeating: [Float](repeating: 0, count: len), count: layout.channelCount)
            for (group, reader) in zip(groups, readers) {
                let part = try AudioIO.readChunk(reader, frames: len)
                for (k, c) in group.enumerated() where k < part.count { mix[c] = part[k] }
            }
            try AudioIO.write(mix, to: file)
            at += Int64(len)
        }
    }
}

extension AudioStems {
    /// Content hash of a mono or surround mix: every track's sound, fader and pans, and the master.
    public func layoutKey(for project: Project) -> String {
        struct Pan: Encodable {
            var id: String
            var surround: SurroundPan?
            var anim: [String: Curve]
        }
        let resolved = project.resolvingAudioTransitions()
        var parts: [Data] = [Data("layout-v1|\(project.master.layout.rawValue)".utf8)]
        for t in project.tracks where t.clips.contains(where: { $0.kind == .media || $0.kind == .sequence }) {
            parts.append(Data("\(t.id)|\(t.muted)|\(t.volume)|\(key(for: t, in: project))".utf8))
            if let c = t.volumeCurve { parts.append((try? Self.encoder.encode(c)) ?? Data()) }
            let clips = resolved.tracks.first { $0.id == t.id }?.clips ?? []
            let pans = clips.map { c in Pan(id: c.id, surround: c.surround, anim: c.anim.filter { Clip.surroundSpecs.map(\.name).contains($0.key) }) }
            parts.append((try? Self.encoder.encode(pans)) ?? Data())
            parts.append(Data(clips.map { "\($0.id):\($0.audioRange.start):\($0.audioRange.end)" }.joined(separator: ",").utf8))
        }
        parts.append((try? Self.encoder.encode(project.master)) ?? Data())
        if project.usesBuses { parts.append(Data(busKey(for: project).utf8)) }
        return "\(project.master.layout.rawValue)-" + hash(parts)
    }

    func foldURL(forKey key: String) -> URL { directory.appendingPathComponent("\(key)-fold.caf") }

    /// The rendered layout mix and its stereo fold-down for playback, if both exist.
    public func cachedLayoutMix(for project: Project) -> (mix: URL, foldDown: URL)? {
        let key = layoutKey(for: project)
        let mix = url(forKey: key), fold = foldURL(forKey: key)
        let fm = FileManager.default
        return fm.fileExists(atPath: mix.path) && fm.fileExists(atPath: fold.path) ? (mix, fold) : nil
    }

    /// Renders the mix in the project's master layout and its stereo fold-down. Clip and track stems must exist.
    @discardableResult
    func renderLayoutMix(_ project: Project, transcripts: [String: Transcript], library: MediaLibrary) async throws -> URL {
        let layout = project.master.layout
        let key = layoutKey(for: project)
        let frames = Int64((max(project.duration, project.canvas.frameDuration) * Self.sampleRate).rounded())
        let fx = project.master.effects.filter { EffectCatalog.isAudio($0.type) && $0.enabled }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var scratch: [URL] = []
        defer { for u in scratch { try? FileManager.default.removeItem(at: u) } }
        func temp(_ prefix: String) -> URL {
            let u = directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).caf")
            scratch.append(u)
            return u
        }
        let mix = temp("stem")
        if project.usesBuses {
            if layout == .mono {
                let stereo = temp("dry")
                try await renderRouted(project, layout: .stereo, frames: frames, transcripts: transcripts, library: library, to: stereo)
                try AudioIO.convert(stereo, matrix: AudioLayout.stereo.downmixMatrix(to: .mono), layout: .mono, frames: 0..<frames, to: mix)
            } else {
                try await renderRouted(project, layout: layout, frames: frames, transcripts: transcripts, library: library, to: mix)
            }
        } else if layout == .mono {
            let built = try await TimelineBuilder.build(project, transcripts: transcripts, library: library, renderScale: 1, stems: self, dryTrack: nil, masterStage: false, soundOnly: true)
            var stereo = temp("dry")
            let n = try await AudioIO.mixdown(built, range: nil, to: stereo)
            if !fx.isEmpty {
                let processed = temp("dry")
                try await AudioChain.process(dry: stereo, frames: n, effects: fx, to: processed)
                stereo = processed
            }
            try AudioIO.convert(stereo, matrix: AudioLayout.stereo.downmixMatrix(to: .mono), layout: .mono, frames: 0..<frames, to: mix)
        } else {
            let sources = try await SurroundMix.sources(project, library: library, transcripts: transcripts, stems: self)
            let dry = fx.isEmpty ? mix : temp("dry")
            try await SurroundMix.pan(sources, layout: layout, frames: frames, to: dry)
            if !fx.isEmpty { try await SurroundMix.processMaster(dry, layout: layout, frames: frames, effects: fx, to: mix, scratch: directory) }
        }
        let fold = temp("stem")
        try AudioIO.convert(mix, matrix: layout.downmixMatrix(to: .stereo), layout: .stereo, frames: 0..<frames, to: fold)
        let dest = url(forKey: key)
        for (from, to) in [(mix, dest), (fold, foldURL(forKey: key))] {
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.moveItem(at: from, to: to)
        }
        return dest
    }
}

extension AudioIO {
    /// Like `read`, but also passes where each chunk starts, in frames from `range.start`.
    static func readPlaced(_ built: BuiltTimeline, range: TimeRange, _ body: (UnsafePointer<Float>, Int, Int64) throws -> Void) async throws {
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty, range.duration > 0 else { return }
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: readerSettings)
        output.audioMix = built.audioMix
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let start = CMTime(seconds: range.start, preferredTimescale: 48_000)
        reader.timeRange = CMTimeRange(start: start, end: CMTime(seconds: range.end, preferredTimescale: 48_000))
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read the timeline's audio") }
        try await withoutActuallyEscaping(body) { body in
            try await offPool {
                var next: Int64 = 0
                while let sample = output.nextSample() {
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                    var length = 0
                    var ptr: UnsafeMutablePointer<CChar>?
                    guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { continue }
                    let frames = length / (MemoryLayout<Float>.size * 2)
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let at = pts.isValid ? Int64(((pts - start).seconds * AudioStems.sampleRate).rounded()) : next
                    try ptr.withMemoryRebound(to: Float.self, capacity: frames * 2) { try body($0, frames, at) }
                    next = at + Int64(frames)
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? EditError("Audio read failed") }
    }

    /// Appends deinterleaved float to a file opened with a float processing format.
    static func write(_ x: [[Float]], to file: AVAudioFile) throws {
        let n = x.first?.count ?? 0
        guard n > 0 else { return }
        let chunk = 65_536
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(min(chunk, n))) else { throw EditError("Cannot allocate audio") }
        for start in stride(from: 0, to: n, by: chunk) {
            let count = min(chunk, n - start)
            buf.frameLength = AVAudioFrameCount(count)
            for c in 0..<min(x.count, Int(file.processingFormat.channelCount)) {
                x[c].withUnsafeBufferPointer { buf.floatChannelData![c].update(from: $0.baseAddress! + start, count: count) }
            }
            try file.write(from: buf)
        }
        Heartbeat.beat()
    }

    /// Reads up to `frames` frames from the file's current position as deinterleaved float, zero-padded past the end.
    static func readChunk(_ file: AVAudioFile, frames: Int) throws -> [[Float]] {
        let channels = Int(file.processingFormat.channelCount)
        var out = [[Float]](repeating: [Float](repeating: 0, count: frames), count: channels)
        guard frames > 0, file.framePosition < file.length, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else { return out }
        try file.read(into: buf, frameCount: AVAudioFrameCount(frames))
        Heartbeat.beat()
        let n = Int(buf.frameLength)
        for c in 0..<channels { out[c].withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: buf.floatChannelData![c], count: n) } }
        return out
    }

    /// Writes `frames` of a file through a `[output][input]` channel matrix as a float CAF in `layout`.
    static func convert(_ source: URL, matrix: [[Double]], layout: AudioLayout, frames: Range<Int64>, to url: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forWriting: url, settings: layout.floatFileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try remix(input, matrix: matrix, frames: frames) { try write($0, to: output) }
    }

    /// Streams `frames` of a file through a channel matrix in chunks, zero-padded past the end.
    static func remix(_ input: AVAudioFile, matrix: [[Double]], frames: Range<Int64>, _ body: ([[Float]]) throws -> Void) throws {
        input.framePosition = min(frames.lowerBound, input.length)
        let chunk: Int64 = 65_536
        var at = frames.lowerBound
        while at < frames.upperBound {
            let len = Int(min(chunk, frames.upperBound - at))
            let x = try readChunk(input, frames: len)
            let y = matrix.map { row -> [Float] in
                var acc = [Float](repeating: 0, count: len)
                for (c, g) in row.enumerated() where g != 0 && c < x.count {
                    let gf = Float(g)
                    for i in 0..<len { acc[i] += gf * x[c][i] }
                }
                return acc
            }
            try body(y)
            at += Int64(len)
        }
    }
}
