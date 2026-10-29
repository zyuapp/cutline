import AVFoundation
import Accelerate
import CryptoKit
import CutlineCore
import Foundation

/// Rendered, effect-processed audio for tracks that have audio effects. Preview and export both
/// play the same stem file, so what the human hears is what gets exported.
public final class AudioStems: @unchecked Sendable {
    public let directory: URL
    static let version = "stem-v1"
    static let sampleRate = 48_000.0

    public init(directory: URL) {
        self.directory = directory
    }

    /// The parts of a clip that change what it sounds like.
    struct ClipSound: Encodable {
        var id, media: String
        var start, duration, sourceIn, speed, volume, fadeIn, fadeOut, lead, lag: Double
        var volumeCurve: Curve?
        var speedCurve: Curve?
        var reverse: Bool
    }

    func sound(of track: Track, in project: Project? = nil) -> [ClipSound] {
        let clips = project.map { p in track.clips.flatMap { $0.kind == .sequence ? p.expanded($0).map(\.clip) : [$0] } } ?? track.clips
        return clips.filter { $0.kind == .media }.map {
            ClipSound(id: $0.id, media: $0.mediaId ?? "", start: $0.start, duration: $0.duration, sourceIn: $0.sourceIn, speed: $0.speed, volume: $0.volume, fadeIn: $0.audioFadeIn, fadeOut: $0.audioFadeOut, lead: $0.audioLead, lag: $0.audioLag, volumeCurve: $0.anim["audio.volume"], speedCurve: $0.anim["time.speed"], reverse: $0.reverse)
        }
    }

    func mediaStamps(_ ids: Set<String>, in project: Project) -> String {
        ids.sorted().compactMap { id -> String? in
            guard let m = project.mediaAsset(id) else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: m.path)
            let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(m.id)|\(m.path)|\(attrs?[.size] as? Int ?? 0)|\(stamp)"
        }.joined(separator: ";")
    }

    func hash(_ parts: [Data]) -> String {
        var data = Data(Self.version.utf8)
        for p in parts { data.append(p) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    /// Content hash of what a track sounds like before its fader and mute: clips and audio effects.
    public func key(for track: Track, in project: Project) -> String {
        let project = project.resolvingAudioTransitions()
        let track = project.tracks.first { $0.id == track.id } ?? track
        let fx = track.effects.filter { EffectCatalog.isAudio($0.type) }
        let ids = Set(track.clips.compactMap(\.mediaId))
        return hash([
            (try? Self.encoder.encode(sound(of: track, in: project))) ?? Data(),
            (try? Self.encoder.encode(fx)) ?? Data(),
            Data(mediaStamps(ids, in: project).utf8),
        ])
    }

    /// Content hash of the whole mix feeding the master effects.
    public func masterKey(for project: Project) -> String {
        var parts: [Data] = []
        for t in project.tracks where t.clips.contains(where: { $0.kind == .media }) {
            parts.append(Data("\(t.id)|\(t.muted)|\(t.volume)|\(key(for: t, in: project))".utf8))
        }
        parts.append((try? Self.encoder.encode(project.master)) ?? Data())
        return "master-" + hash(parts)
    }

    func url(forKey key: String) -> URL { directory.appendingPathComponent("\(key).caf") }

    public func cachedStem(for track: Track, in project: Project) -> URL? {
        let u = url(forKey: key(for: track, in: project))
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    public func cachedMaster(for project: Project) -> URL? {
        let u = url(forKey: masterKey(for: project))
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func hasMasterChain(_ project: Project) -> Bool {
        project.master.effects.contains { EffectCatalog.isAudio($0.type) && $0.enabled }
    }

    /// Renders every stem whose inputs changed: track stems, then the master. Returns what it rendered.
    @discardableResult
    public func renderMissing(_ project: Project, transcripts: [String: Transcript], library: MediaLibrary) async throws -> [String] {
        var done: [String] = []
        for track in project.tracks where track.effects.contains(where: { EffectCatalog.isAudio($0.type) && $0.enabled }) {
            guard cachedStem(for: track, in: project) == nil else { continue }
            try await render(track, in: project, transcripts: transcripts, library: library)
            done.append(track.id)
        }
        if Self.hasMasterChain(project), cachedMaster(for: project) == nil {
            try await renderMaster(project, transcripts: transcripts, library: library)
            done.append("master")
        }
        if !done.isEmpty { prune(keep: 40) }
        return done
    }

    /// Keeps the most recently written stems; older versions re-render if an undo needs them.
    func prune(keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let stems = files.filter { $0.pathExtension == "caf" && !$0.lastPathComponent.hasPrefix("dry-") && !$0.lastPathComponent.hasPrefix("stem-") }
        guard stems.count > keep else { return }
        let dated = stems.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? fm.removeItem(at: url) }
    }

    func writeAtomically(_ dest: URL, _ body: (URL) async throws -> Void) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent("stem-\(UUID().uuidString).caf")
        try await body(tmp)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    @discardableResult
    public func render(_ track: Track, in project: Project, transcripts: [String: Transcript], library: MediaLibrary) async throws -> URL {
        let dest = url(forKey: key(for: track, in: project))
        try await writeAtomically(dest) { tmp in
            let dry = directory.appendingPathComponent("dry-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: dry) }
            let built = try await TimelineBuilder.build(project, transcripts: transcripts, library: library, renderScale: 1, stems: nil, dryTrack: track.id, masterStage: false)
            let frames = try await AudioIO.mixdown(built, range: nil, to: dry)
            try AudioChain.process(dry: dry, frames: frames, effects: track.effects.filter { EffectCatalog.isAudio($0.type) && $0.enabled }, to: tmp)
        }
        return dest
    }

    /// Mixes every track (with track stems and the master gain) and runs the master effects over it.
    @discardableResult
    public func renderMaster(_ project: Project, transcripts: [String: Transcript], library: MediaLibrary) async throws -> URL {
        let dest = url(forKey: masterKey(for: project))
        try await writeAtomically(dest) { tmp in
            let dry = directory.appendingPathComponent("dry-\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: dry) }
            let built = try await TimelineBuilder.build(project, transcripts: transcripts, library: library, renderScale: 1, stems: self, dryTrack: nil, masterStage: false)
            let frames = try await AudioIO.mixdown(built, range: nil, to: dry)
            try AudioChain.process(dry: dry, frames: frames, effects: project.master.effects.filter { EffectCatalog.isAudio($0.type) && $0.enabled }, to: tmp)
        }
        return dest
    }
}

enum AudioIO {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioStems.sampleRate, channels: 2, interleaved: false)!

    static var readerSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: AudioStems.sampleRate, AVNumberOfChannelsKey: 2,
        ]
    }

    /// Reads the mixed sound of a timeline as interleaved stereo float, chunk by chunk.
    static func read(_ built: BuiltTimeline, range: TimeRange?, _ body: (UnsafePointer<Float>, Int) throws -> Void) async throws {
        let tracks = try await built.composition.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return }
        let reader = try AVAssetReader(asset: built.composition)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: readerSettings)
        output.audioMix = built.audioMix
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let end = range?.end ?? built.duration
        let start = range?.start ?? 0
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), end: CMTime(seconds: end, preferredTimescale: 48_000))
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read the timeline's audio") }
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { continue }
            let frames = length / (MemoryLayout<Float>.size * 2)
            try ptr.withMemoryRebound(to: Float.self, capacity: frames * 2) { try body($0, frames) }
        }
        if reader.status == .failed { throw reader.error ?? EditError("Audio read failed") }
    }

    /// Writes a timeline's mixed sound to a float CAF file and returns its length in frames.
    static func mixdown(_ built: BuiltTimeline, range: TimeRange?, to url: URL) async throws -> AVAudioFramePosition {
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var total: AVAudioFramePosition = 0
        try await read(built, range: range) { samples, frames in
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            buf.frameLength = AVAudioFrameCount(frames)
            let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
            for i in 0..<frames {
                l[i] = samples[2 * i]
                r[i] = samples[2 * i + 1]
            }
            try file.write(from: buf)
            total += AVAudioFramePosition(frames)
        }
        if total == 0 {
            // Silence keeps the stem valid when every clip on the track is muted.
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buf.frameLength = 4800
            try file.write(from: buf)
            total = 4800
        }
        return total
    }
}

/// Builds an offline AVAudioEngine chain for a list of audio effects.
enum AudioChain {
    static let tail: Double = 2

    static func process(dry: URL, frames: AVAudioFramePosition, effects: [Effect], to url: URL) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let nodes = effects.flatMap { units(for: $0) }
        for n in nodes { engine.attach(n) }
        let format = AudioIO.format
        var previous: AVAudioNode = player
        for n in nodes {
            engine.connect(previous, to: n, format: format)
            previous = n
        }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let source = try AVAudioFile(forReading: dry)
        try engine.start()
        player.scheduleFile(source, at: nil)
        player.play()

        let latency = nodes.compactMap { ($0 as? AVAudioUnit)?.auAudioUnit.latency }.reduce(0, +)
        var skip = AVAudioFramePosition((latency * AudioStems.sampleRate).rounded())
        let hasTail = effects.contains { ["audio.reverb", "audio.delay"].contains($0.type) }
        let total = frames + skip + (hasTail ? AVAudioFramePosition(tail * AudioStems.sampleRate) : 0)
        let out = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: AudioStems.sampleRate,
            AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 24,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var rendered: AVAudioFramePosition = 0
        while rendered < total {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), total - rendered))
            let status = try engine.renderOffline(n, to: buffer)
            guard status == .success else { break }
            rendered += AVAudioFramePosition(buffer.frameLength)
            if skip > 0 {
                let drop = min(skip, AVAudioFramePosition(buffer.frameLength))
                skip -= drop
                guard drop < AVAudioFramePosition(buffer.frameLength) else { continue }
                let keep = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - drop)
                let trimmed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: keep)!
                trimmed.frameLength = keep
                for c in 0..<Int(buffer.format.channelCount) {
                    trimmed.floatChannelData![c].update(from: buffer.floatChannelData![c] + Int(drop), count: Int(keep))
                }
                try out.write(from: trimmed)
            } else {
                try out.write(from: buffer)
            }
        }
        engine.stop()
    }

    static func number(_ e: Effect, _ name: String) -> Float {
        Float(e.params[name]?.number ?? EffectCatalog.type(e.type)?.spec(name)?.defaultValue.number ?? 0)
    }

    static func string(_ e: Effect, _ name: String) -> String {
        e.params[name]?.string ?? EffectCatalog.type(e.type)?.spec(name)?.defaultValue.string ?? ""
    }

    static func apple(_ subtype: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subtype, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    }

    static func set(_ unit: AVAudioUnit, _ address: AUParameterAddress, _ value: Float) {
        unit.auAudioUnit.parameterTree?.parameter(withAddress: address)?.value = value
    }

    /// Audio units for one effect. `mix` scales the wet amount of effects that have one.
    static func units(for e: Effect) -> [AVAudioNode] {
        let mix = Float(e.mix)
        switch e.type {
        case "audio.eq":
            let eq = AVAudioUnitEQ(numberOfBands: 5)
            let hp = number(e, "highpass_hz"), lp = number(e, "lowpass_hz")
            let b = eq.bands
            b[0].filterType = .highPass; b[0].frequency = max(10, hp); b[0].bypass = hp <= 0
            b[1].filterType = .lowShelf; b[1].frequency = number(e, "low_hz"); b[1].gain = number(e, "low_gain"); b[1].bypass = number(e, "low_gain") == 0
            b[2].filterType = .parametric; b[2].frequency = number(e, "mid_hz"); b[2].gain = number(e, "mid_gain"); b[2].bandwidth = number(e, "mid_width"); b[2].bypass = number(e, "mid_gain") == 0
            b[3].filterType = .highShelf; b[3].frequency = number(e, "high_hz"); b[3].gain = number(e, "high_gain"); b[3].bypass = number(e, "high_gain") == 0
            b[4].filterType = .lowPass; b[4].frequency = lp > 0 ? lp : 20_000; b[4].bypass = lp <= 0
            return [eq]
        case "audio.compressor":
            let u = apple(kAudioUnitSubType_DynamicsProcessor)
            set(u, 0, number(e, "threshold"))
            set(u, 1, number(e, "headroom"))
            set(u, 2, 1)
            set(u, 3, -100)
            set(u, 4, number(e, "attack_ms") / 1000)
            set(u, 5, number(e, "release_ms") / 1000)
            set(u, 6, number(e, "makeup"))
            return [u]
        case "audio.gate":
            let u = apple(kAudioUnitSubType_DynamicsProcessor)
            set(u, 0, 20)
            set(u, 1, 40)
            set(u, 2, number(e, "ratio"))
            set(u, 3, number(e, "threshold"))
            return [u]
        case "audio.limiter":
            let u = apple(kAudioUnitSubType_PeakLimiter)
            set(u, 0, 0.005)
            set(u, 1, max(0.001, min(0.04, number(e, "release_ms") / 1000)))
            set(u, 2, number(e, "input_gain"))
            // The limiter holds peaks at full scale; a gain stage after it sets the ceiling.
            let ceiling = AVAudioUnitEQ(numberOfBands: 0)
            ceiling.globalGain = number(e, "ceiling")
            return [u, ceiling]
        case "audio.voice_isolation":
            let u = apple(kAudioUnitSubType_AUSoundIsolation)
            set(u, 0, number(e, "amount") * mix * 100)
            return [u]
        case "audio.reverb":
            let u = AVAudioUnitReverb()
            let presets: [String: AVAudioUnitReverbPreset] = [
                "small_room": .smallRoom, "medium_room": .mediumRoom, "large_room": .largeRoom,
                "medium_hall": .mediumHall, "large_hall": .largeHall, "plate": .plate, "cathedral": .cathedral,
            ]
            u.loadFactoryPreset(presets[string(e, "space")] ?? .mediumRoom)
            u.wetDryMix = number(e, "wet") * mix * 100
            return [u]
        case "audio.delay":
            let u = AVAudioUnitDelay()
            u.delayTime = TimeInterval(number(e, "time_ms") / 1000)
            u.feedback = number(e, "feedback") * 100
            u.wetDryMix = number(e, "wet") * mix * 100
            return [u]
        case "audio.character":
            let u = AVAudioUnitDistortion()
            let presets: [String: AVAudioUnitDistortionPreset] = [
                "radio": .speechRadioTower, "phone": .multiCellphoneConcert, "broken_speaker": .multiBrokenSpeaker,
                "lofi": .multiDecimated2, "alien": .speechAlienChatter,
            ]
            u.loadFactoryPreset(presets[string(e, "style")] ?? .speechRadioTower)
            u.wetDryMix = number(e, "wet") * mix * 100
            return [u]
        case "audio.pitch":
            let u = AVAudioUnitTimePitch()
            u.pitch = number(e, "semitones") * 100
            return [u]
        default:
            return []
        }
    }
}

/// Loudness per ITU-R BS.1770-4 / EBU R128: integrated, short-term, momentary, range and peak.
public struct LoudnessReport: Sendable {
    public var integrated: Double
    public var shortTermMax: Double
    public var momentaryMax: Double
    public var range: Double
    public var peakDb: Double
    /// Inter-sample peak from 4× oversampling (BS.1770-4 Annex 2).
    public var truePeakDb: Double
    public var duration: Seconds

    public var summary: String {
        func f(_ v: Double) -> String { v.isFinite ? String(format: "%.1f", v) : "silent" }
        return "integrated \(f(integrated)) LUFS, short-term max \(f(shortTermMax)) LUFS, momentary max \(f(momentaryMax)) LUFS, range \(f(range)) LU, true peak \(f(truePeakDb)) dBTP (sample peak \(f(peakDb)) dBFS)"
    }
}

public enum LoudnessMeter {
    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// K-weighting at 48 kHz: a high shelf for the head, then a high pass.
    static func kWeighting() -> [Biquad] {
        [
            Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285, a1: -1.69065929318241, a2: 0.73248077421585),
            Biquad(b0: 1.0, b1: -2.0, b2: 1.0, a1: -1.99004745483398, a2: 0.99007225036621),
        ]
    }

    public static func measure(_ built: BuiltTimeline, range: TimeRange? = nil) async throws -> LoudnessReport {
        var acc = Accumulator()
        try await AudioIO.read(built, range: range) { samples, n in acc.feed(samples, n) }
        return acc.report()
    }

    /// Consumes interleaved stereo float at 48 kHz.
    struct Accumulator {
        let hop = Int(AudioStems.sampleRate * 0.1)
        var filters = [LoudnessMeter.kWeighting(), LoudnessMeter.kWeighting()]
        var hopEnergy: [Double] = []
        var acc = 0.0
        var count = 0
        var peak: Float = 0
        var truePeak = 0.0
        var history = [[Double]](repeating: [Double](repeating: 0, count: 12), count: 2)
        var head = 0
        var frames = 0

        /// Polyphase interpolation filter for 4× oversampling, 12 taps per phase.
        static let phases: [[Double]] = [
            [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625, 0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
            [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250, 0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
            [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500, 0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
            [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500, 0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750],
        ]

        mutating func feed(_ samples: UnsafePointer<Float>, _ n: Int) {
            var p: Float = 0
            vDSP_maxmgv(samples, 1, &p, vDSP_Length(n * 2))
            peak = max(peak, p)
            for i in 0..<n {
                head = (head + 1) % 12
                history[0][head] = Double(samples[2 * i])
                history[1][head] = Double(samples[2 * i + 1])
                for ch in 0..<2 {
                    for phase in Accumulator.phases {
                        var y = 0.0
                        var k = head
                        for c in phase {
                            y += c * history[ch][k]
                            k = k == 0 ? 11 : k - 1
                        }
                        truePeak = max(truePeak, abs(y))
                    }
                }
                let l = filters[0][1].run(filters[0][0].run(Double(samples[2 * i])))
                let r = filters[1][1].run(filters[1][0].run(Double(samples[2 * i + 1])))
                acc += l * l + r * r
                count += 1
                if count == hop {
                    hopEnergy.append(acc / Double(hop))
                    acc = 0
                    count = 0
                }
            }
            frames += n
        }

        func report() -> LoudnessReport {
            func loudness(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-20)) }
            func windows(_ size: Int) -> [Double] {
                guard hopEnergy.count >= size else { return hopEnergy.isEmpty ? [] : [hopEnergy.reduce(0, +) / Double(hopEnergy.count)] }
                return (0...(hopEnergy.count - size)).map { i in hopEnergy[i..<(i + size)].reduce(0, +) / Double(size) }
            }
            let momentary = windows(4)
            let shortTerm = windows(30)
            let gated = momentary.filter { loudness($0) > -70 }
            var integrated = -Double.infinity
            if !gated.isEmpty {
                let relative = loudness(gated.reduce(0, +) / Double(gated.count)) - 10
                let final = gated.filter { loudness($0) > relative }
                if !final.isEmpty { integrated = loudness(final.reduce(0, +) / Double(final.count)) }
            }
            var lra = 0.0
            let stAbove = shortTerm.filter { loudness($0) > -70 }
            if !stAbove.isEmpty {
                let rel = loudness(stAbove.reduce(0, +) / Double(stAbove.count)) - 20
                let values = stAbove.map(loudness).filter { $0 > rel }.sorted()
                if values.count > 1 {
                    lra = values[Int(Double(values.count - 1) * 0.95)] - values[Int(Double(values.count - 1) * 0.10)]
                }
            }
            return LoudnessReport(
                integrated: integrated,
                shortTermMax: shortTerm.map(loudness).max() ?? -.infinity,
                momentaryMax: momentary.map(loudness).max() ?? -.infinity,
                range: lra,
                peakDb: 20 * log10(Double(max(peak, 1e-10))),
                truePeakDb: 20 * log10(max(truePeak, Double(peak), 1e-10)),
                duration: Double(frames) / AudioStems.sampleRate
            )
        }
    }
}
