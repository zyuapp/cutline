import AVFoundation
import CutlineCore
import Foundation

/// A master's audio track layout (`AudioTrackSpec`): each track rendered over the export range in its own layout,
/// the mix conformed to the master loudness target and the stems left as they are, so they sum back to the
/// pre-master mix. A leader puts tone under the bars and the 2-pop on every program track.
public enum AudioTracks {
    public struct Job: @unchecked Sendable {
        public var spec: AudioTrackSpec
        /// The timeline whose sound the track carries; nil for the export's own timeline (the mix), silence and tone.
        public var timeline: BuiltTimeline?

        public init(_ spec: AudioTrackSpec, timeline: BuiltTimeline? = nil) {
            self.spec = spec
            self.timeline = timeline
        }
    }

    public struct Rendered: Sendable {
        public var spec: AudioTrackSpec
        /// 48 kHz float CAF in the spec's layout: the leader's length, then the program.
        public var url: URL
        public var conform: LoudnessConform?
        /// The program part as written; nil for silence and tone.
        public var loudness: LoudnessReport?
    }

    /// What an export rendered, for its report.
    public final class Report: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Rendered] = []
        public init() {}
        public var tracks: [Rendered] { lock.withLock { stored } }
        func set(_ r: [Rendered]) { lock.withLock { stored = r } }
    }

    static let rate = AudioStems.sampleRate

    /// Renders every job over `span` of the timeline into `dir`. `dialogue` (timeline spans) gates the mix's loudness target.
    static func render(_ jobs: [Job], mix: BuiltTimeline, span: CMTimeRange, leader: Leader?, tc: TimecodeFormat, dialogue: [TimeRange]?, in dir: URL) async throws -> [Rendered] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let count = Int64((span.duration.seconds * rate).rounded())
        let start = span.start.seconds
        let gate = dialogue?.map { TimeRange($0.start - start, $0.end - start) }
        let master = mix.scene.project.master
        let lead = leader.map { Int64((tc.seconds($0.frames(tc)) * rate).rounded()) } ?? 0
        var out: [Rendered] = []
        for (i, job) in jobs.enumerated() {
            let layout = job.spec.layout
            let base = dir.appendingPathComponent("track\(i + 1)")
            let program = base.appendingPathExtension("program.caf")
            guard job.spec.content.isProgram else {
                try synthesize(layout, frames: lead + count, tone: job.spec.content == .tone, to: program)
                out.append(Rendered(spec: job.spec, url: program, conform: nil, loudness: nil))
                continue
            }
            let (source, frames, from) = try await sound(job.timeline ?? mix, span: span, count: count, scratch: base.appendingPathExtension("mix.caf"))
            let folded = base.appendingPathExtension("folded.caf")
            try AudioIO.convert(source, matrix: from.downmixMatrix(to: layout), layout: layout, frames: frames, to: folded)
            var conform: LoudnessConform?
            if job.spec.content == .mix, let target = master.loudnessTarget {
                conform = try await LoudnessConform.run(folded, layout: layout, frames: 0..<count, target: target, ceiling: master.ceiling, dialogue: gate, to: program)
            } else {
                try FileManager.default.moveItem(at: folded, to: program)
            }
            let loudness = try LoudnessMeter.measure(file: program, layout: layout, dialogue: gate)
            var url = program
            if let leader, lead > 0 {
                url = base.appendingPathExtension("caf")
                try prependLeader(leader, tc: tc, to: program, layout: layout, output: url)
            }
            out.append(Rendered(spec: job.spec, url: url, conform: conform, loudness: loudness))
        }
        return out
    }

    /// The timeline's sound over `span` in its master layout: the rendered surround file, or a stereo mixdown.
    static func sound(_ built: BuiltTimeline, span: CMTimeRange, count: Int64, scratch: URL) async throws -> (URL, Range<Int64>, AudioLayout) {
        if built.layout != .stereo {
            guard let s = built.surround else { throw EditError("The \(built.layout.title) mix isn't rendered yet; render the project's stems before exporting") }
            let from = Int64((span.start.seconds * rate).rounded())
            return (s, from..<(from + count), built.layout)
        }
        _ = try await AudioIO.mixdown(built, range: TimeRange(span.start.seconds, span.end.seconds), to: scratch)
        return (scratch, 0..<count, .stereo)
    }

    static func toneSample(_ s: Int64) -> Float {
        Float(pow(10, Leader.toneDbfs / 20)) * Float(sin(2 * Double.pi * Leader.toneHz * Double(s) / rate))
    }

    /// Silence, or line-up tone: 1 kHz at −20 dBFS, none on LFE.
    static func synthesize(_ layout: AudioLayout, frames: Int64, tone: Bool, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: layout.floatFileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: Int64 = 48_000
        var at: Int64 = 0
        while at < frames {
            let n = Int(min(chunk, frames - at))
            var x = [[Float]](repeating: [Float](repeating: 0, count: n), count: layout.channelCount)
            if tone {
                let wave = (0..<n).map { toneSample(at + Int64($0)) }
                for c in 0..<layout.channelCount where c != layout.lfeChannel { x[c] = wave }
            }
            try AudioIO.write(x, to: file)
            at += Int64(n)
        }
    }

    /// Writes the leader's sound (tone under the bars, the 2-pop) and then `program` to `output`.
    static func prependLeader(_ leader: Leader, tc: TimecodeFormat, to program: URL, layout: AudioLayout, output: URL) throws {
        let total = Int64((tc.seconds(leader.frames(tc)) * rate).rounded())
        let barsEnd = Int64((tc.seconds(leader.barsSeconds * tc.nominal) * rate).rounded())
        let pop: Range<Int64>? = leader.popFrame(tc).map { f in Int64((tc.seconds(f) * rate).rounded())..<Int64((tc.seconds(f + 1) * rate).rounded()) }
        let file = try AVAudioFile(forWriting: output, settings: layout.floatFileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: Int64 = 48_000
        var at: Int64 = 0
        while at < total {
            let n = Int(min(chunk, total - at))
            var x = [[Float]](repeating: [Float](repeating: 0, count: n), count: layout.channelCount)
            for i in 0..<n {
                let s = at + Int64(i)
                guard s < barsEnd || pop?.contains(s) == true else { continue }
                let v = toneSample(s)
                for c in 0..<layout.channelCount where c != layout.lfeChannel { x[c][i] = v }
            }
            try AudioIO.write(x, to: file)
            at += Int64(n)
        }
        let input = try AVAudioFile(forReading: program)
        let n = layout.channelCount
        let identity = (0..<n).map { o in (0..<n).map { $0 == o ? 1.0 : 0 } }
        try AudioIO.remix(input, matrix: identity, frames: 0..<input.length) { try AudioIO.write($0, to: file) }
    }

    /// Every channel of `tracks` in order in one discrete N-channel float CAF.
    static func pack(_ tracks: [Rendered], to url: URL) throws {
        let channels = tracks.reduce(0) { $0 + $1.spec.layout.channelCount }
        let file = try AVAudioFile(forWriting: url, settings: discreteSettings(channels), commonFormat: .pcmFormatFloat32, interleaved: false)
        let inputs = try tracks.map { try AVAudioFile(forReading: $0.url) }
        let length = inputs.map(\.length).max() ?? 0
        let chunk: Int64 = 65_536
        var at: Int64 = 0
        while at < length {
            let n = Int(min(chunk, length - at))
            var x: [[Float]] = []
            for (input, t) in zip(inputs, tracks) {
                let read = try AudioIO.readChunk(input, frames: n)
                x += (0..<t.spec.layout.channelCount).map { $0 < read.count ? read[$0] : [Float](repeating: 0, count: n) }
            }
            try AudioIO.write(x, to: file)
            at += Int64(n)
        }
    }

    static func discreteLayoutData(_ channels: Int) -> Data {
        AudioLayout.layoutData(kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels))
    }

    static func discreteSettings(_ channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVChannelLayoutKey: discreteLayoutData(channels),
        ]
    }

    /// QuickTime track name ('tnam') and title ('©nam'), which Apple apps and ffprobe read.
    static func nameMetadata(_ name: String) -> [AVMetadataItem] {
        [AVMetadataIdentifier.quickTimeUserDataTrackName, .quickTimeUserDataFullName].map { id in
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.value = name as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            if id == .quickTimeUserDataFullName { item.locale = Locale(identifier: "en_US") }
            return item
        }
    }

    /// The writer tracks a rendered layout becomes: one per spec, or one carrying every channel.
    static func writerTracks(_ rendered: [Rendered], packing: AudioTrackSpec.Packing, scratch: URL) throws -> [(url: URL, channels: Int, layout: Data?, name: String)] {
        guard packing == .channels, rendered.count > 1 else {
            return rendered.map { r in
                let l = r.spec.layout
                return (r.url, l.channelCount, l == .stereo ? nil : l.channelLayoutData, r.spec.name)
            }
        }
        try pack(rendered, to: scratch)
        let channels = rendered.reduce(0) { $0 + $1.spec.layout.channelCount }
        return [(scratch, channels, discreteLayoutData(channels), rendered.map(\.spec.name).joined(separator: " | "))]
    }
}
