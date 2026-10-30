import AVFoundation
import CutlineCore
import Foundation

/// The routed mix: each track's sound is rendered on its own (post-fader, and pre-fader when a send needs it),
/// summed into the buses it feeds, run through each bus's effects and fader in dependency order, then summed
/// into the master with its gain and effects. Stereo and mono masters mix in stereo (mono folds at the end);
/// surround masters mix in their layout, panning each clip with the surround panner and running effects per
/// channel pair. Track signals are cached by content, so a bus change only re-runs the bus processing.
extension AudioStems {
    /// One track's contribution: the solo project that renders it, and its cache key.
    struct Feed {
        var track: Track
        var post: (project: Project, key: String)?
        var pre: (project: Project, key: String)?
    }

    /// The layout buses mix in: the master's when it is surround, else stereo.
    static func mixLayout(_ project: Project) -> AudioLayout { project.master.layout.isSurround ? project.master.layout : .stereo }

    static func hasSound(_ t: Track) -> Bool { t.clips.contains { $0.kind == .media || $0.kind == .sequence } }

    /// A track alone with a plain master, before (`preFader`) or after its fader.
    static func soloSignal(_ track: Track, in resolved: Project, preFader: Bool) -> Project {
        var t = track
        t.output = nil
        t.sends = []
        t.muted = false
        if preFader {
            t.volume = 1
            t.volumeCurve = nil
        }
        var p = resolved
        p.tracks = [t]
        p.transitions = []
        p.buses = []
        p.master = MasterAudio()
        return p
    }

    func signalKey(_ solo: Project, layout: AudioLayout) -> String {
        struct Pan: Encodable {
            var id: String
            var surround: SurroundPan?
            var anim: [String: Curve]
            var start, end: Double
        }
        guard let t = solo.tracks.first else { return "sig-empty" }
        var parts = [Data("sig-v1|\(layout.rawValue)|\(t.volume)".utf8), Data(key(for: t, in: solo).utf8)]
        if let c = t.volumeCurve { parts.append((try? Self.encoder.encode(c)) ?? Data()) }
        if layout.isSurround {
            let pans = t.clips.map { c in Pan(id: c.id, surround: c.surround, anim: c.anim.filter { Clip.surroundSpecs.map(\.name).contains($0.key) }, start: c.audioRange.start, end: c.audioRange.end) }
            parts.append((try? Self.encoder.encode(pans)) ?? Data())
        }
        return "sig-" + hash(parts)
    }

    func feeds(_ project: Project, layout: AudioLayout) -> [Feed] {
        let resolved = project.resolvingAudioTransitions()
        let routing = project.mixRouting()
        var out: [Feed] = []
        for t in resolved.tracks where !t.muted && Self.hasSound(t) {
            let post = routing.destinationHeard(t.output) || t.sends.contains { !$0.preFader && $0.gain > 0 && routing.destinationHeard($0.bus) }
            let pre = t.sends.contains { $0.preFader && $0.gain > 0 && routing.destinationHeard($0.bus) }
            var f = Feed(track: t)
            if post {
                let solo = Self.soloSignal(t, in: resolved, preFader: false)
                f.post = (solo, signalKey(solo, layout: layout))
            }
            if pre {
                let solo = Self.soloSignal(t, in: resolved, preFader: true)
                f.pre = (solo, signalKey(solo, layout: layout))
            }
            if f.post != nil || f.pre != nil { out.append(f) }
        }
        return out
    }

    /// Content hash of the routed mix in `layout`: every track signal, outputs, sends, buses and the master.
    public func busKey(for project: Project, layout: AudioLayout? = nil) -> String {
        let layout = layout ?? Self.mixLayout(project)
        var parts = [Data("busmix-v1|\(layout.rawValue)".utf8)]
        for f in feeds(project, layout: layout) {
            parts.append(Data("\(f.track.id)|\(f.track.output ?? "")|\(f.post?.key ?? "")|\(f.pre?.key ?? "")".utf8))
            parts.append((try? Self.encoder.encode(f.track.sends)) ?? Data())
        }
        parts.append((try? Self.encoder.encode(project.buses)) ?? Data())
        parts.append((try? Self.encoder.encode(project.master)) ?? Data())
        return "bus-" + hash(parts)
    }

    /// The rendered stereo bus mix (through the master effects), if it exists.
    public func cachedBusMix(for project: Project) -> URL? {
        let u = url(forKey: busKey(for: project, layout: .stereo))
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Renders the stereo bus mix playback and export use under a stereo master.
    @discardableResult
    public func renderBusMix(_ project: Project, transcripts: [String: Transcript], library: MediaLibrary) async throws -> URL {
        let dest = url(forKey: busKey(for: project, layout: .stereo))
        let frames = Int64((max(project.duration, project.canvas.frameDuration) * Self.sampleRate).rounded())
        try await writeAtomically(dest) { tmp in
            try await renderRouted(project, layout: .stereo, frames: frames, transcripts: transcripts, library: library, to: tmp)
        }
        return dest
    }

    func signal(_ solo: Project, key: String, layout: AudioLayout, frames: Int64, transcripts: [String: Transcript], library: MediaLibrary) async throws -> URL {
        let dest = url(forKey: key)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        try await renderMissing(solo, transcripts: transcripts, library: library)
        try await writeAtomically(dest) { tmp in
            if layout.isSurround {
                let sources = try await SurroundMix.sources(solo, library: library, transcripts: transcripts, stems: self)
                try await SurroundMix.pan(sources, layout: layout, frames: frames, to: tmp)
            } else {
                let built = try await TimelineBuilder.build(solo, transcripts: transcripts, library: library, renderScale: 1, stems: self, dryTrack: nil, masterStage: false, soundOnly: true)
                _ = try await AudioIO.mixdown(built, range: nil, to: tmp)
            }
        }
        return dest
    }

    /// Writes the routed mix in `layout` (stereo or the surround master layout), `frames` long, to `url`.
    func renderRouted(_ project: Project, layout: AudioLayout, frames: Int64, transcripts: [String: Transcript], library: MediaLibrary, to url: URL) async throws {
        let routing = project.mixRouting()
        var scratch: [URL] = []
        defer { for u in scratch { try? FileManager.default.removeItem(at: u) } }
        func temp() -> URL {
            let u = directory.appendingPathComponent("dry-\(UUID().uuidString).caf")
            scratch.append(u)
            return u
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var post: [String: URL] = [:], pre: [String: URL] = [:]
        let feeds = feeds(project, layout: layout)
        for f in feeds {
            if let s = f.post { post[f.track.id] = try await signal(s.project, key: s.key, layout: layout, frames: frames, transcripts: transcripts, library: library) }
            if let s = f.pre { pre[f.track.id] = try await signal(s.project, key: s.key, layout: layout, frames: frames, transcripts: transcripts, library: library) }
        }
        var outputs: [String: (url: URL, layout: AudioLayout)] = [:]
        for bus in routing.order where routing.busHeard(bus.id) {
            let busLayout = bus.layout.flatMap { $0.channelCount <= layout.channelCount ? $0 : nil } ?? layout
            var inputs: [Input] = []
            if routing.destinationHeard(bus.id) {
                for f in feeds {
                    if f.track.output == bus.id, let u = post[f.track.id] { inputs.append(Input(url: u, layout: layout, gain: 1)) }
                    for s in f.track.sends where s.bus == bus.id && s.gain > 0 {
                        if let u = (s.preFader ? pre : post)[f.track.id] { inputs.append(Input(url: u, layout: layout, gain: s.gain)) }
                    }
                }
            }
            for child in routing.order where child.output == bus.id {
                if let o = outputs[child.id] { inputs.append(Input(url: o.url, layout: o.layout, gain: 1)) }
            }
            var sum = temp()
            try Self.sum(inputs, layout: busLayout, frames: frames, to: sum)
            let fx = bus.effects.filter { EffectCatalog.isAudio($0.type) && $0.enabled }
            if !fx.isEmpty {
                let processed = temp()
                try await process(sum, layout: busLayout, frames: frames, effects: fx, to: processed)
                sum = processed
            }
            let out = temp()
            try Self.sum([Input(url: sum, layout: busLayout, gain: 1)], layout: busLayout, frames: frames, fader: bus.volumeCurve == nil ? nil : { bus.volume(at: $0) }, gain: bus.volume, to: out)
            outputs[bus.id] = (out, busLayout)
        }
        var inputs: [Input] = []
        if routing.destinationHeard(nil) {
            for f in feeds where f.track.output == nil {
                if let u = post[f.track.id] { inputs.append(Input(url: u, layout: layout, gain: 1)) }
            }
        }
        for bus in routing.order where bus.output == nil {
            if let o = outputs[bus.id] { inputs.append(Input(url: o.url, layout: o.layout, gain: 1)) }
        }
        let fx = project.master.effects.filter { EffectCatalog.isAudio($0.type) && $0.enabled }
        let dry = fx.isEmpty ? url : temp()
        try Self.sum(inputs, layout: layout, frames: frames, gain: project.master.gain, to: dry)
        if !fx.isEmpty { try await process(dry, layout: layout, frames: frames, effects: fx, to: url) }
    }

    func process(_ dry: URL, layout: AudioLayout, frames: Int64, effects: [Effect], to url: URL) async throws {
        if layout == .stereo {
            try await AudioChain.process(dry: dry, frames: AVAudioFramePosition(frames), effects: effects, to: url)
        } else {
            try await SurroundMix.processMaster(dry, layout: layout, frames: frames, effects: effects, to: url, scratch: directory)
        }
    }

    struct Input {
        var url: URL
        var layout: AudioLayout
        var gain: Double
    }

    /// Sums files into `layout`, folding each input's layout into it, times `gain` or the `fader` curve over
    /// timeline time (sampled every 32 frames and interpolated). Missing inputs give silence.
    static func sum(_ inputs: [Input], layout: AudioLayout, frames: Int64, fader: ((Seconds) -> Double)? = nil, gain: Double = 1, to url: URL) throws {
        let output = try AVAudioFile(forWriting: url, settings: layout.floatFileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let readers = try inputs.map { i -> (AVAudioFile, [[Double]], Double) in
            let file = try AVAudioFile(forReading: i.url)
            let from = AudioLayout(channelCount: Int(file.processingFormat.channelCount)) ?? i.layout
            return (file, from.downmixMatrix(to: layout), i.gain)
        }
        let n = layout.channelCount
        let chunk: Int64 = 65_536
        let step = 32
        var at: Int64 = 0
        while at < frames {
            let len = Int(min(chunk, frames - at))
            var mix = [[Float]](repeating: [Float](repeating: 0, count: len), count: n)
            for (file, matrix, g) in readers {
                let x = try AudioIO.readChunk(file, frames: len)
                for (o, row) in matrix.enumerated() where o < n {
                    for (c, w) in row.enumerated() where w != 0 && c < x.count {
                        let k = Float(w * g)
                        mix[o].withUnsafeMutableBufferPointer { m in
                            x[c].withUnsafeBufferPointer { s in for i in 0..<len { m[i] += k * s[i] } }
                        }
                    }
                }
            }
            if let fader {
                var i = 0
                var g0 = fader(Double(at) / sampleRate)
                while i < len {
                    let m = min(step, len - i)
                    let g1 = fader(Double(at + Int64(i + m)) / sampleRate)
                    for j in 0..<m {
                        let g = Float(g0 + (g1 - g0) * Double(j) / Double(m))
                        for c in 0..<n { mix[c][i + j] *= g }
                    }
                    g0 = g1
                    i += m
                }
            } else if gain != 1 {
                let g = Float(gain)
                for c in 0..<n { for i in 0..<len { mix[c][i] *= g } }
            }
            try AudioIO.write(mix, to: output)
            at += Int64(len)
        }
    }
}
