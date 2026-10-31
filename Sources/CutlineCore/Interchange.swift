import Foundation

/// Frames of exactly `num/den` seconds, e.g. 1001/30000 for 29.97 fps and 100/3000 for 30 fps.
struct FrameGrid: Equatable {
    let num: Int
    let den: Int

    init(fps: Double) {
        let fps = fps > 0 && fps <= 10_000 ? fps : 30
        let whole = fps.rounded()
        if abs(fps - whole) > 1e-6, abs(fps - whole * 1000 / 1001) < 0.01 {
            num = 1001; den = Int(whole) * 1000
        } else if abs(fps * 100 - (fps * 100).rounded()) < 1e-6 {
            num = 100; den = Int((fps * 100).rounded())
        } else {
            num = 1000; den = Int((fps * 1000).rounded())
        }
    }

    var rate: Double { Double(den) / Double(num) }

    func frames(_ t: Seconds) -> Int { Int(saturating: (t * rate).rounded()) }

    /// FCPXML time of a frame count, reduced, e.g. "3/2s" or "5s".
    func fcp(_ frames: Int) -> String { FrameGrid.fcp(frames * num, den) }

    static func fcp(_ n: Int, _ d: Int) -> String {
        let g = max(1, gcd(n, d))
        return d / g == 1 ? "\(n / g)s" : "\(n / g)/\(d / g)s"
    }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }

    /// Frames from a transition's start to its cut, and its length in frames. A centered transition of odd length
    /// has the extra frame after the cut.
    func cutFrames(_ tr: Transition) -> (before: Int, length: Int) {
        let d = max(1, frames(tr.duration))
        if let o = tr.cutOffset { return (min(max(frames(o), 0), d), d) }
        switch tr.align {
        case .center: return (d / 2, d)
        case .start: return (0, d)
        case .end: return (d, d)
        }
    }
}

extension Project {
    /// Where a transition's sound crossfade cuts: between the outgoing clip's sound end and the incoming one's start.
    func soundCut(_ tr: Transition) -> Seconds? {
        guard let f = tr.from, let t = tr.to, let a = clip(f), let b = clip(t) else { return nil }
        return (a.audioRange.end + b.audioRange.start) / 2
    }

    /// First frame, cut frame and length of a transition on `grid`: across a cut it sits around the picture cut, or
    /// with `sound` the sound cut; over a single clip edge it covers its window.
    func transitionFrames(_ tr: Transition, grid: FrameGrid, sound: Bool) -> (start: Int, cut: Int, length: Int)? {
        let (before, d) = grid.cutFrames(tr)
        if tr.from != nil, tr.to != nil {
            guard let b = tr.to.flatMap({ clip($0) }) else { return nil }
            let cut = grid.frames(sound ? soundCut(tr) ?? b.start : b.start)
            return (cut - before, cut, d)
        }
        guard let w = try? window(tr) else { return nil }
        let s = grid.frames(w.start), e = grid.frames(w.end)
        return (s, tr.from == nil ? s : e, e - s)
    }
}

/// An exact time of n/d seconds, for FCPXML times that add timecode at one rate to frames at another.
struct RationalTime: Equatable {
    var n: Int
    var d: Int

    static let zero = RationalTime(n: 0, d: 1)

    init(n: Int, d: Int) {
        let g = max(1, FrameGrid.gcd(n, d))
        self.n = n / g
        self.d = d / g
    }

    init(frames: Int, _ grid: FrameGrid) { self.init(n: frames * grid.num, d: grid.den) }

    init(frames: Int, _ format: TimecodeFormat) { self.init(n: frames * format.frameNum, d: format.frameDen) }

    static func + (a: RationalTime, b: RationalTime) -> RationalTime {
        let l = a.d / max(1, FrameGrid.gcd(a.d, b.d)) * b.d
        return RationalTime(n: a.n * (l / a.d) + b.n * (l / b.d), d: l)
    }

    static func - (a: RationalTime, b: RationalTime) -> RationalTime { a + RationalTime(n: -b.n, d: b.d) }

    /// Scaled by p/q.
    func scaled(_ p: Int, _ q: Int) -> RationalTime { RationalTime(n: n * p, d: d * q) }

    var fcp: String { FrameGrid.fcp(n, d) }
    var seconds: Seconds { Double(n) / Double(d) }
}

// MARK: Shared

/// A sound clip's picture range, split and fades in timeline frames, written beside an EDL or FCP7 XML event
/// that can only say where the sound plays: "Cutline sound 50-114 lead 3 lag 3 fades 6/6".
struct SoundHint: Equatable {
    var start: Int
    var end: Int
    var lead: Int
    var lag: Int
    var fadeIn: Int
    var fadeOut: Int
    /// The event's join into the clip (an EDL dissolve) is its sound overlapping the previous clip's, not a transition.
    var overlap = false

    static let prefix = "Cutline sound"

    init(start: Int, end: Int, lead: Int, lag: Int, fadeIn: Int, fadeOut: Int) {
        self.start = start
        self.end = end
        self.lead = lead
        self.lag = lag
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    init(_ c: Clip, grid: FrameGrid, offset: Int = 0) {
        let s = grid.frames(c.start)
        self.init(start: s + offset, end: grid.frames(c.end) + offset, lead: s - grid.frames(c.start - c.audioLead), lag: grid.frames(c.end + c.audioLag) - grid.frames(c.end),
                  fadeIn: grid.frames(c.audioFadeIn), fadeOut: grid.frames(c.audioFadeOut))
    }

    init?(text: String) {
        guard let r = text.range(of: SoundHint.prefix) else { return nil }
        let v = text[r.upperBound...].split(whereSeparator: { " -/;\n".contains($0) }).filter { !["lead", "lag", "fades"].contains($0) }
        let n = v.prefix(6).compactMap { Int($0) }
        guard n.count == 6 else { return nil }
        self.init(start: n[0], end: n[1], lead: n[2], lag: n[3], fadeIn: n[4], fadeOut: n[5])
        overlap = v.contains("overlap")
    }

    var text: String { "\(SoundHint.prefix) \(start)-\(end) lead \(lead) lag \(lag) fades \(fadeIn)/\(fadeOut)" + (overlap ? " overlap" : "") }

    /// `c`, read from an event whose sound starts `soundStart` frames into the timeline, placed as the hint says.
    func apply(_ c: inout Clip, soundStart: Int, grid: FrameGrid) {
        func t(_ f: Int) -> Seconds { Double(f * grid.num) / Double(grid.den) }
        let before = c.start
        c.sourceIn += t(start - soundStart) * c.speed
        c.start = t(start)
        c.duration = t(end - start)
        c.audioLead = t(lead)
        c.audioLag = t(lag)
        c.audioFadeIn = t(fadeIn)
        c.audioFadeOut = t(fadeOut)
        if let k = c.anim["audio.volume"] { c.anim["audio.volume"] = k.shifted(by: before - c.start) }
    }
}

extension Canvas {
    /// Frames from midnight to the first timeline frame, from `startTimecode`.
    var startFrame: Int { timecodeFormat.frames(startTimecode) ?? 0 }

    /// The `timecodeStart` an importer keeps for a program starting `frames` from midnight: nil for the default.
    func timecodeStart(frames: Int) -> String? {
        let label = timecodeFormat.string(frames)
        return timecodeFormat.frames(TimecodeFormat.defaultStart) == frames ? nil : label
    }
}

extension Project {
    var startFrame: Int { canvas.startFrame }

    /// Gain a clip's sound is heard at, `local` seconds from its start: its level or volume animation, the
    /// track's fader and, with `master`, the master gain.
    func heardGain(_ clip: Clip, track: Track, at local: Seconds, master: Bool = true) -> Double {
        let level = clip.anim["audio.volume"]?.value(at: local)?.number ?? clip.volume
        return max(0, level) * max(0, track.volume(at: clip.start + local)) * (master ? self.master.gain : 1)
    }

    /// A clip's level for a target without track or master gain: the gain at the start of its sound and, when it
    /// changes, keys at local seconds on `grid` frames over the sound (split-edit lead and lag included). Eased
    /// segments of the volume animation and fader are sampled every 0.1 s, since targets interpolate keys linearly,
    /// and the whole sound every 0.25 s when both change.
    func bakedLevel(_ clip: Clip, track: Track, grid: FrameGrid, master: Bool = true) -> (gain: Double, keys: [(t: Seconds, gain: Double)]) {
        let a0 = -clip.audioLead, a1 = clip.duration + clip.audioLag
        let curves = [clip.anim["audio.volume"].map { ($0, 0.0) }, track.volumeCurve.map { ($0, clip.start) }].compactMap { $0 }
        guard !curves.isEmpty else { return (heardGain(clip, track: track, at: 0, master: master), []) }
        var times = [a0, a1]
        // The product of two ramps isn't linear between their keys.
        if curves.count > 1 { times += stride(from: a0, to: a1, by: 0.25).map { $0 } }
        for (curve, shift) in curves {
            times += curve.keys.map { $0.t - shift }
            for (a, b) in zip(curve.keys, curve.keys.dropFirst()) where b.ease != .linear || b.bezier != nil {
                times += stride(from: a.t + 0.1, to: b.t, by: 0.1).map { $0 - shift }
            }
        }
        var frames: [Int] = []
        for f in times.map({ grid.frames($0) }).sorted() where f >= grid.frames(a0) && f <= grid.frames(a1) && frames.last != f { frames.append(f) }
        let keys = frames.map { f -> (t: Seconds, gain: Double) in
            let t = Double(f * grid.num) / Double(grid.den)
            return (t, heardGain(clip, track: track, at: min(max(t, a0), a1), master: master))
        }
        let first = heardGain(clip, track: track, at: a0, master: master)
        if keys.allSatisfy({ abs($0.gain - first) < 1e-6 }) { return (first, []) }
        return (keys.first?.gain ?? first, keys)
    }

    static func decibels(_ gain: Double) -> String {
        gain <= 1e-5 ? "-96dB" : String(format: "%.2fdB", 20 * log10(gain))
    }

    static func gain(decibels s: String) -> Double {
        let t = s.replacingOccurrences(of: "dB", with: "").replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)
        let db = Double(t) ?? 0
        return db <= -96 ? 0 : pow(10, db / 20)
    }
}

// MARK: OpenTimelineIO

extension Project {
    /// OpenTimelineIO JSON (Clip.2 with `media_references`, OTIO 0.15+), timed in frames at the canvas fps.
    /// Video tracks come first, bottom layer first, then the embedded audio of video tracks, then audio tracks.
    /// Text, solid, adjustment and generator clips become gaps carrying `{"cutline": {kind, text, clip}}` metadata
    /// (`clip` the whole Cutline clip); sound overlapping the next clip's on a track is a crossfade marked `overlap`;
    /// speed is a LinearTimeWarp with `source_range` duration in timeline frames. Sound (embedded and audio
    /// tracks) spans each clip's audio range, so split edits read as offset audio, with an `AudioLevel` effect
    /// holding the heard level (`gain_db`, `keyframes`, fades; faders and master folded in). Transitions sit on the
    /// picture cut in video tracks and on the sound cut in sound tracks, with their part, alignment and cut offset
    /// in Cutline metadata. Clips carry a `cdl`
    /// like the CMX adapter's, a LUT's .cube path as `lut.file`, and Cutline metadata with the transform, effects,
    /// animation and audio settings. Sequence clips are Stacks in their track holding the sequence's tracks, with
    /// `source_range` the part played. `global_start_time` is the canvas's start timecode. Media with source
    /// timecode have their `available_range` from it at their own rate and clips' `source_range` start in it, with
    /// the label and reel in the reference's Cutline metadata.
    public func otio() throws -> Data { try scopedToTimeline().otio(InterchangeContext()) }

    /// With clips the export replaced (`InterchangeContext.originals`) written as the clip they stand for, in metadata.
    func otio(_ ctx: InterchangeContext) throws -> Data {
        let grid = FrameGrid(fps: canvas.fps)
        let rate = canvas.fps > 0 ? canvas.fps : 30

        func rt(_ value: Int) -> [String: Any] { ["OTIO_SCHEMA": "RationalTime.1", "rate": rate, "value": Double(value)] }
        func range(_ start: Int, _ duration: Int) -> [String: Any] {
            ["OTIO_SCHEMA": "TimeRange.1", "start_time": rt(start), "duration": rt(duration)]
        }
        func gap(_ frames: Int, name: String = "", metadata: [String: Any] = [:]) -> [String: Any] {
            ["OTIO_SCHEMA": "Gap.1", "name": name, "source_range": range(0, frames), "effects": [Any](), "markers": [Any](),
             "metadata": metadata, "enabled": true]
        }
        func summary(_ clip: Clip) -> [String: Any] {
            var md: [String: Any] = [
                "clipId": clip.id, "kind": clip.kind.rawValue, "speed": clip.speed, "volume": clip.volume,
                "effects": Self.jsonValue(clip.effects), "transform": Self.jsonValue(clip.transform),
            ]
            if clip.blend != .normal { md["blend"] = clip.blend.rawValue }
            if clip.fadeIn > 0 { md["fadeIn"] = clip.fadeIn }
            if clip.fadeOut > 0 { md["fadeOut"] = clip.fadeOut }
            if clip.audioFadeIn > 0 { md["audioFadeIn"] = clip.audioFadeIn }
            if clip.audioFadeOut > 0 { md["audioFadeOut"] = clip.audioFadeOut }
            if clip.audioLead != 0 { md["audioLead"] = clip.audioLead }
            if clip.audioLag != 0 { md["audioLag"] = clip.audioLag }
            if !clip.anim.isEmpty { md["anim"] = Self.jsonValue(clip.anim) }
            if let t = clip.text { md["text"] = t.text }
            if let c = clip.color { md["color"] = c.hex }
            if clip.reverse { md["reverse"] = true }
            if let ch = clip.channels { md["channels"] = ch.rawValue }
            // Everything about titles, solids and generators, and the clip a baked graphic stands for.
            if let e = ctx.embedded(clip) { md["clip"] = Self.jsonValue(e) }
            return md
        }
        /// OTIO's CMX adapter keeps an EDL's `*ASC_SOP`/`*ASC_SAT` this way.
        func cdlMetadata(_ c: CDL) -> [String: Any] {
            ["asc_sop": ["slope": [c.slope.x, c.slope.y, c.slope.z], "offset": [c.offset.x, c.offset.y, c.offset.z], "power": [c.power.x, c.power.y, c.power.z]],
             "asc_sat": c.saturation]
        }
        /// The level a clip is heard at, track fader and master gain folded in, for readers that don't know Cutline's metadata.
        /// Times are seconds from the item's start, which is `itemStart` seconds from the clip's.
        func audioLevel(_ clip: Clip, track: Track, itemStart: Seconds, scope: Project) -> [String: Any] {
            let level = scope.bakedLevel(clip, track: track, grid: grid)
            func db(_ g: Double) -> Double { g <= 1e-5 ? -96 : (2000 * log10(g)).rounded() / 100 }
            var md: [String: Any] = ["gain_db": track.muted ? -96 : db(level.gain)]
            if !level.keys.isEmpty, !track.muted { md["keyframes"] = level.keys.map { ["time": $0.t - itemStart, "gain_db": db($0.gain)] } }
            if clip.audioFadeIn > 0 { md["fade_in"] = clip.audioFadeIn }
            if clip.audioFadeOut > 0 { md["fade_out"] = clip.audioFadeOut }
            return ["OTIO_SCHEMA": "Effect.1", "name": "AudioLevel", "effect_name": "AudioLevel", "metadata": ["cutline": md]]
        }
        /// The media's timecode format and first frame, when it has source timecode.
        func sourceTimecode(_ m: MediaAsset?) -> (format: TimecodeFormat, frames: Int)? {
            guard let m, !m.isImage, let f = m.timecodeFrames(fallback: canvas.fps) else { return nil }
            return (m.timecodeFormat(fallback: canvas.fps, dropFrame: canvas.dropFrame), f)
        }
        func reference(_ asset: MediaAsset?) -> [String: Any] {
            guard let m = asset else {
                return ["OTIO_SCHEMA": "MissingReference.1", "name": "", "available_range": NSNull(), "available_image_bounds": NSNull(), "metadata": [String: Any]()]
            }
            var available: Any = m.isImage ? NSNull() : range(0, Int((m.duration * grid.rate + 1e-6).rounded(.down)))
            var md: [String: Any] = [:]
            // With source timecode the available range runs from it, at the media's own rate.
            if let tc = sourceTimecode(m) {
                func at(_ v: Int) -> [String: Any] { ["OTIO_SCHEMA": "RationalTime.1", "rate": tc.format.rate, "value": Double(v)] }
                available = ["OTIO_SCHEMA": "TimeRange.1", "start_time": at(tc.frames), "duration": at(Int((m.duration * tc.format.rate + 1e-6).rounded(.down)))]
                md["timecode"] = tc.format.string(tc.frames)
            }
            if let reel = m.reel, !reel.isEmpty { md["reel"] = reel }
            if m.hasAudio, m.audioChannels != nil { md["audioChannels"] = Self.channelLayout(m) }
            let metadata: [String: Any] = md.isEmpty ? [:] : ["cutline": md]
            return ["OTIO_SCHEMA": "ExternalReference.1", "name": m.name, "target_url": m.conformURL.absoluteString,
                    "available_range": available, "available_image_bounds": NSNull(), "metadata": metadata]
        }
        /// `sound` is the clip as heard: from its audio source range over its audio range, with its level; the item
        /// starts `skip` seconds into it.
        func clipItem(_ clip: Clip, track: Track, frames: Int, sound: Bool, scope: Project, skip: Seconds = 0) -> [String: Any] {
            let asset = clip.mediaId.flatMap(mediaAsset)
            var effects: [Any] = []
            if abs(clip.speed - 1) > 1e-9 {
                effects.append(["OTIO_SCHEMA": "LinearTimeWarp.1", "name": "", "effect_name": "LinearTimeWarp",
                                "time_scalar": clip.speed, "metadata": [String: Any]()] as [String: Any])
            }
            let audible = asset.map { $0.hasAudio && !$0.isImage } ?? false
            if sound, audible { effects.append(audioLevel(clip, track: track, itemStart: skip - clip.audioLead, scope: scope)) }
            var metadata: [String: Any] = ["cutline": summary(clip)]
            if !sound, let cdl = clip.cdl { metadata["cdl"] = cdlMetadata(cdl) }
            if !sound, let lut = ctx.luts[clip.id] { metadata["lut"] = ["file": lut, "whole_grade": true] } else if !sound, let lut = clip.lutFiles.first { metadata["lut"] = ["file": lut] }
            let sourceIn = (sound ? clip.audioSourceRange.start : clip.sourceIn) + skip * clip.speed
            var sourceRange = range(grid.frames(sourceIn), frames)
            // In source timecode, at the media's rate like its available range.
            if let tc = sourceTimecode(asset) {
                let value = Double(tc.frames) + sourceIn * tc.format.rate
                sourceRange["start_time"] = ["OTIO_SCHEMA": "RationalTime.1", "rate": tc.format.rate,
                                             "value": abs(value - value.rounded()) < 1e-6 ? value.rounded() : value]
            }
            return ["OTIO_SCHEMA": "Clip.2", "name": clip.name ?? asset?.name ?? clip.id,
                    "source_range": sourceRange,
                    "media_references": ["DEFAULT_MEDIA": reference(asset)], "active_media_reference_key": "DEFAULT_MEDIA",
                    "effects": effects, "markers": [Any](), "metadata": metadata, "enabled": true]
        }
        /// A sequence clip: a Stack holding the sequence's tracks, over the clip's part of it.
        func stackItem(_ clip: Clip, _ seq: NestedSequence, frames: Int, scope: Project) -> [String: Any] {
            var md = summary(clip)
            md["sequenceId"] = seq.id
            md["sequenceName"] = seq.name
            if let mc = ctx.multicams[clip.id] {
                md["multicam"] = ["sequence": Self.jsonValue(mc.sequence), "switch": Self.jsonValue(mc.switch), "media": Self.jsonValue(mc.media)]
            }
            var metadata: [String: Any] = ["cutline": md]
            if let cdl = clip.cdl { metadata["cdl"] = cdlMetadata(cdl) }
            return ["OTIO_SCHEMA": "Stack.1", "name": clip.name ?? seq.name, "source_range": range(grid.frames(clip.sourceIn), frames),
                    "children": otioTracks(scope.inside(seq)), "effects": [Any](), "markers": [Any](), "metadata": metadata, "enabled": true]
        }
        func otioTrack(_ track: Track, name: String, kind: String, embeddedAudio: Bool, scope: Project) -> [String: Any] {
            var children: [[String: Any]] = []
            var cursor = 0
            let sound = embeddedAudio || track.kind == .audio
            func span(_ clip: Clip) -> TimeRange { sound && clip.kind == .media ? clip.audioRange : TimeRange(clip.start, clip.end) }
            let edges = track.clips.map { (grid.frames(span($0).start), grid.frames(span($0).end)) }
            /// Dissolves sit on the picture cut, crossfades on the sound cut; from or to nothing only beside a gap.
            func transitionItems(from a: String?, to b: String?) -> [[String: Any]] {
                scope.transitions.filter { $0.from == a && $0.to == b && (sound ? $0.hasAudio : $0.hasVideo) }.compactMap { tr in
                    guard let at = scope.transitionFrames(tr, grid: grid, sound: sound) else { return nil }
                    var md: [String: Any] = ["type": tr.type, "part": tr.part.rawValue, "align": tr.align.rawValue]
                    if let o = tr.cutOffset { md["cutOffset"] = o }
                    return ["OTIO_SCHEMA": "Transition.1", "name": tr.type, "transition_type": tr.type == "dissolve" ? "SMPTE_Dissolve" : "Custom_Transition",
                            "in_offset": rt(at.cut - at.start), "out_offset": rt(at.start + at.length - at.cut), "metadata": ["cutline": md]]
                }
            }
            let ordered = track.clips.sorted(by: { span($0).start < span($1).start })
            // Sound overlapping the next clip's with no transition between them: a crossfade over the overlap, cut where
            // the items meet, which Cutline reads back as the overlap.
            var cutAfter: [String: (cut: Int, before: Int, after: Int)] = [:], cutBefore: [String: Int] = [:]
            if sound {
                let heard = ordered.filter { $0.kind == .media && !$0.reverse }
                for (a, b) in zip(heard, heard.dropFirst()) where transitionItems(from: a.id, to: b.id).isEmpty {
                    let s = grid.frames(b.audioRange.start), e = grid.frames(a.audioRange.end)
                    guard e > s, s > cutBefore[a.id] ?? grid.frames(a.audioRange.start), e < grid.frames(b.audioRange.end),
                          transitionItems(from: a.id, to: nil).isEmpty, transitionItems(from: nil, to: b.id).isEmpty else { continue }
                    let picture = grid.frames(b.start)
                    let cut = picture >= s && picture <= e ? picture : (s + e) / 2
                    cutAfter[a.id] = (cut, cut - s, e - cut)
                    cutBefore[b.id] = cut
                }
            }
            for clip in ordered {
                let s = cutBefore[clip.id] ?? max(grid.frames(span(clip).start), cursor), e = cutAfter[clip.id]?.cut ?? grid.frames(span(clip).end)
                guard e > s else { continue }
                if s > cursor { children.append(gap(s - cursor)) }
                let audible = clip.mediaId.flatMap(mediaAsset).map { $0.hasAudio && !$0.isImage } ?? false
                if clip.kind == .sequence, !embeddedAudio, let seq = clip.mediaId.flatMap(scope.sequence) {
                    children.append(stackItem(clip, seq, frames: e - s, scope: scope))
                } else if clip.kind == .media && (!embeddedAudio || audible) {
                    if !edges.contains(where: { $0.1 == s }), cutBefore[clip.id] == nil { children += transitionItems(from: nil, to: clip.id) }
                    let skip = cutBefore[clip.id].map { Double(($0 - grid.frames(clip.audioRange.start)) * grid.num) / Double(grid.den) } ?? 0
                    children.append(clipItem(clip, track: track, frames: e - s, sound: sound, scope: scope, skip: skip))
                    if let o = cutAfter[clip.id] {
                        children.append(["OTIO_SCHEMA": "Transition.1", "name": "Cross Fade (0dB)", "transition_type": "SMPTE_Dissolve",
                                         "in_offset": rt(o.before), "out_offset": rt(o.after), "metadata": ["cutline": ["overlap": true]]])
                    } else {
                        for next in track.clips where next.id != clip.id && grid.frames(span(next).start) == e { children += transitionItems(from: clip.id, to: next.id) }
                    }
                    if !edges.contains(where: { $0.0 == e }), cutAfter[clip.id] == nil { children += transitionItems(from: clip.id, to: nil) }
                } else if embeddedAudio {
                    children.append(gap(e - s))
                } else {
                    var md: [String: Any] = ["kind": clip.kind.rawValue]
                    if let t = clip.text?.text { md["text"] = t }
                    children.append(gap(e - s, name: clip.name ?? clip.text?.text ?? clip.kind.rawValue,
                                        metadata: ["cutline": summary(clip).merging(md) { _, b in b }]))
                }
                cursor = e
            }
            let enabled = embeddedAudio || track.kind == .audio ? !track.muted : !track.hidden
            var md: [String: Any] = ["trackId": track.id, "volume": track.volume]
            if embeddedAudio { md["embeddedAudio"] = true }
            if let curve = track.volumeCurve { md["volumeCurve"] = Self.jsonValue(curve) }
            if !track.effects.isEmpty { md["effects"] = track.effects.map(\.type) }
            return ["OTIO_SCHEMA": "Track.1", "name": name, "kind": kind, "children": children, "effects": [Any](),
                    "markers": [Any](), "metadata": ["cutline": md], "source_range": NSNull(), "enabled": enabled]
        }

        func otioTracks(_ scope: Project) -> [[String: Any]] {
            let video = scope.tracks.filter { $0.kind == .video }
            let embedded = video.filter { t in
                t.clips.contains { $0.kind == .media && ($0.mediaId.flatMap(mediaAsset).map { $0.hasAudio && !$0.isImage } ?? false) }
            }
            var children = video.map { otioTrack($0, name: $0.name, kind: "Video", embeddedAudio: false, scope: scope) }
            children += embedded.map { otioTrack($0, name: "\($0.name) Audio", kind: "Audio", embeddedAudio: true, scope: scope) }
            children += scope.tracks.filter { $0.kind == .audio }.map { otioTrack($0, name: $0.name, kind: "Audio", embeddedAudio: false, scope: scope) }
            return children
        }
        let children = otioTracks(self)

        let markerItems: [[String: Any]] = markers.sorted { $0.time < $1.time }.map {
            ["OTIO_SCHEMA": "Marker.2", "name": $0.label, "color": "RED", "comment": "",
             "marked_range": range(grid.frames($0.time), 0), "metadata": ["cutline": ["markerId": $0.id]]]
        }
        let stack: [String: Any] = ["OTIO_SCHEMA": "Stack.1", "name": "tracks", "children": children, "effects": [Any](),
                                    "markers": markerItems, "metadata": [String: Any](), "source_range": NSNull(), "enabled": true]
        var md: [String: Any] = ["width": canvas.width, "height": canvas.height, "fps": canvas.fps, "background": canvas.background.hex]
        if let df = canvas.dropFrame { md["dropFrame"] = df }
        if master.gainDb != 0 { md["masterGainDb"] = master.gainDb }
        let timeline: [String: Any] = [
            "OTIO_SCHEMA": "Timeline.1", "name": name, "global_start_time": rt(startFrame), "tracks": stack, "metadata": ["cutline": md],
        ]
        return try JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func jsonValue<T: Encodable>(_ v: T) -> Any {
        (try? JSONEncoder().encode(v)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) } ?? NSNull()
    }

    static func decode<T: Decodable>(_ type: T.Type, _ v: Any?) -> T? {
        guard let v, JSONSerialization.isValidJSONObject(v), let data = try? JSONSerialization.data(withJSONObject: v) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: FCPXML

/// A minimal XML element tree that escapes on output.
struct XMLElem {
    var name: String
    var attrs: [(String, String)] = []
    var children: [XMLElem] = []
    var text: String?

    /// Mixed content, like a title's `<text>`, is written without indentation, which would become part of it.
    var inline: Bool

    init(_ name: String, _ attrs: [(String, String)] = [], children: [XMLElem] = [], text: String? = nil, inline: Bool = false) {
        self.name = name
        self.attrs = attrs
        self.children = children
        self.text = text
        self.inline = inline
    }

    /// Indented by `depth`, or on one line when `depth` is nil.
    func write(_ out: inout String, depth: Int?) {
        let pad = depth.map { String(repeating: "    ", count: $0) } ?? ""
        let newline = depth == nil ? "" : "\n"
        out += pad + "<" + name
        for (k, v) in attrs { out += " \(k)=\"\(XMLElem.escape(v, attribute: true))\"" }
        if let text {
            out += ">" + XMLElem.escape(text, attribute: false) + "</\(name)>" + newline
        } else if children.isEmpty {
            out += "/>" + newline
        } else if inline || depth == nil {
            out += ">"
            for c in children { c.write(&out, depth: nil) }
            out += "</\(name)>" + newline
        } else {
            out += ">\n"
            for c in children { c.write(&out, depth: depth.map { $0 + 1 }) }
            out += pad + "</\(name)>\n"
        }
    }

    static func escape(_ s: String, attribute: Bool) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "'" where attribute: out += "&apos;"
            case "\n" where attribute: out += "&#10;"
            case "\t" where attribute: out += "&#9;"
            case "\r": out += "&#13;"
            default:
                // Characters XML 1.0 cannot carry.
                if u.value < 0x20 && u != "\n" && u != "\t" { continue }
                if u.value == 0xFFFE || u.value == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

extension Project {
    /// FCPXML 1.11 for Final Cut Pro. The lowest video track is the primary storyline (gaps fill holes);
    /// higher video tracks connect at lanes 1, 2, … and audio tracks at lanes -1, -2, …, each attached to
    /// the storyline item under its start. Text clips become Basic Titles (text, font, size, color, alignment,
    /// Position), solids the Custom solid generator, each with the whole Cutline clip as `com.cutline.clip` metadata;
    /// speed, reverse, freezes and speed ramps become a `timeMap` (linear between points where the speed changes);
    /// stretch is a non-uniform scale of the fit picture. Adjustment clips have no FCP equivalent and become gaps on the storyline or are left
    /// out above it. Butting audio-track clips whose sound overlaps share a secondary storyline.
    /// Transitions sit between the items they join, with a `filter-video` for the picture and a `filter-audio`
    /// (Audio Crossfade) for the sound; connected clips joined by transitions go in a secondary storyline.
    /// Sequence clips are compound clips: a `media` resource holding the sequence, played by a `ref-clip`; multicam
    /// clips are an `mc-clip` per angle switch of a `multicam` media with an `mc-angle` per angle, `mc-source`s naming
    /// the picture and sound angles. Routed sound is an `audio-channel-source` (`srcCh`) with the routing as metadata.
    /// Split edits are expanded audio (`audioStart`/`audioDuration`); levels, fades and volume keys are
    /// `adjust-volume` with track faders and master gain folded in; transform, crop, fill and opacity are
    /// `adjust-*`; the clip's CDL goes in its note as `ASC_SOP … ASC_SAT …`, followed by `; LUT <path>` for each LUT.
    /// The project's `tcStart` is the canvas's start timecode; assets declare their own audio sample rate. An asset
    /// with source timecode starts at it (with its reel as metadata), and clips of it start at that timecode plus
    /// their in point, as Final Cut writes them.
    public func fcpxml() -> String { scopedToTimeline().splittingMulticam().fcpxml(InterchangeContext()) }

    func fcpxml(_ ctx: InterchangeContext) -> String {
        let grid = FrameGrid(fps: canvas.fps)
        var nextId = 1
        func makeId() -> String { defer { nextId += 1 }; return "r\(nextId)" }

        // Resources
        var resources: [XMLElem] = []
        var formats: [String: String] = [:]
        func format(width: Int, height: Int, fps: Double?) -> String {
            let fg = fps.map { FrameGrid(fps: $0) }
            let key = "\(width)x\(height)@\(fg.map { "\($0.num)/\($0.den)" } ?? "still")"
            if let id = formats[key] { return id }
            let id = makeId()
            var attrs = [("id", id)]
            if let name = Self.fcpFormatName(width: width, height: height, grid: fg) { attrs.append(("name", name)) }
            if let fg { attrs.append(("frameDuration", "\(fg.num)/\(fg.den)s")) }
            attrs += [("width", "\(width)"), ("height", "\(height)")]
            resources.append(XMLElem("format", attrs))
            formats[key] = id
            return id
        }
        let sequenceFormat = format(width: canvas.width, height: canvas.height, fps: canvas.fps)

        var assetIds: [String: String] = [:]
        /// Where an asset's own time starts: its source timecode.
        func assetStart(_ m: MediaAsset) -> RationalTime {
            guard !m.isImage, let f = m.timecodeFrames(fallback: canvas.fps) else { return .zero }
            return RationalTime(frames: f, m.timecodeFormat(fallback: canvas.fps, dropFrame: canvas.dropFrame))
        }
        for m in media {
            let id = makeId()
            assetIds[m.id] = id
            var attrs = [("id", id), ("name", m.name), ("start", assetStart(m).fcp)]
            if m.isImage {
                attrs.append(("duration", "0s"))
            } else {
                let mg = FrameGrid(fps: m.hasVideo && m.fps > 0 ? m.fps : canvas.fps)
                attrs.append(("duration", mg.fcp(Int((m.duration * mg.rate + 1e-6).rounded(.down)))))
            }
            attrs.append(("hasVideo", m.hasVideo ? "1" : "0"))
            if m.hasVideo {
                attrs.append(("format", format(width: m.width, height: m.height, fps: m.isImage ? nil : (m.fps > 0 ? m.fps : canvas.fps))))
                attrs.append(("videoSources", "1"))
            }
            attrs.append(("hasAudio", m.hasAudio ? "1" : "0"))
            if m.hasAudio {
                let rate = m.sampleRate.map { Int($0.rounded()) }.flatMap { $0 > 0 ? $0 : nil } ?? 48000
                let layout = Self.channelLayout(m)
                attrs += [("audioSources", "\(layout.count)"), ("audioChannels", "\(layout.reduce(0, +))"), ("audioRate", "\(rate)")]
            }
            var kids = [XMLElem("media-rep", [("kind", "original-media"), ("src", m.conformURL.absoluteString)])]
            if let reel = m.reel, !reel.isEmpty {
                kids.append(XMLElem("metadata", children: [XMLElem("md", [("key", "com.apple.proapps.studio.reel"), ("value", reel)])]))
            }
            resources.append(XMLElem("asset", attrs, children: kids))
        }
        let titleRef = "r_title"
        let dissolveRef = "r_dissolve"
        let allTracks = tracks + sequences.flatMap(\.tracks)
        let crossfadeRef = "r_crossfade"
        let allTransitions = transitions + sequences.flatMap(\.transitions)
        if allTransitions.contains(where: \.hasVideo) {
            resources.append(XMLElem("effect", [("id", dissolveRef), ("name", "Cross Dissolve"), ("uid", "FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265")]))
        }
        if allTransitions.contains(where: \.hasAudio) {
            resources.append(XMLElem("effect", [("id", crossfadeRef), ("name", "Audio Crossfade"), ("uid", "FFAudioTransition")]))
        }
        if allTracks.contains(where: { $0.kind == .video && $0.clips.contains { $0.kind == .text } }) {
            resources.append(XMLElem("effect", [("id", titleRef), ("name", "Basic Title"),
                                                ("uid", ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti")]))
        }
        let solidRef = "r_solid"
        if allTracks.contains(where: { $0.kind == .video && $0.clips.contains { $0.kind == .solid } }) {
            resources.append(XMLElem("effect", [("id", solidRef), ("name", "Custom"), ("uid", ".../Generators.localized/Solids.localized/Custom.localized/Custom.motn")]))
        }
        /// The whole Cutline clip, for clips Final Cut can only approximate.
        func cutlineMetadata(_ clip: Clip) -> [XMLElem] {
            guard let e = ctx.embedded(clip) else { return [] }
            return [XMLElem("metadata", children: [XMLElem("md", [("key", Self.fcpClipKey), ("value", Self.clipJSON(e))])])]
        }

        // Story elements
        var styleCount = 0
        let w = Double(canvas.width), h = Double(canvas.height)
        func num(_ v: Double) -> String { CDL.number((v * 10000).rounded() / 10000) }
        /// Level, fades and volume keys; track faders and the master gain are folded in, since Final Cut has neither.
        func volumeChildren(_ clip: Clip, track: Track, start: RationalTime, scope: Project) -> [XMLElem] {
            if track.muted && track.kind == .video { return [XMLElem("adjust-volume", [("amount", "-96dB")])] }
            let level = scope.bakedLevel(clip, track: track, grid: grid)
            var kids: [XMLElem] = []
            if clip.audioFadeIn > 0 { kids.append(XMLElem("fadeIn", [("type", "easeIn"), ("duration", grid.fcp(grid.frames(clip.audioFadeIn)))])) }
            if clip.audioFadeOut > 0 { kids.append(XMLElem("fadeOut", [("type", "easeOut"), ("duration", grid.fcp(grid.frames(clip.audioFadeOut)))])) }
            if !level.keys.isEmpty {
                kids.append(XMLElem("keyframeAnimation", children: level.keys.map {
                    XMLElem("keyframe", [("time", (start + RationalTime(frames: grid.frames($0.t), grid)).fcp), ("value", Self.decibels($0.gain))])
                }))
            }
            guard abs(level.gain - 1) > 1e-6 || !kids.isEmpty else { return [] }
            return [XMLElem("adjust-volume", [("amount", Self.decibels(level.gain))], children: kids.isEmpty ? [] : [XMLElem("param", [("name", "amount")], children: kids)])]
        }
        /// Crop, conform, position (percent of the frame height, up positive), scale, counterclockwise rotation and opacity.
        func pictureChildren(_ clip: Clip) -> [XMLElem] {
            let t = clip.transform
            var kids: [XMLElem] = []
            if !t.crop.isEmpty {
                kids.append(XMLElem("adjust-crop", [("mode", "trim")], children: [XMLElem("trim-rect", [
                    ("left", num(t.crop.left * w / h * 100)), ("top", num(t.crop.top * 100)), ("right", num(t.crop.right * w / h * 100)), ("bottom", num(t.crop.bottom * 100)),
                ])]))
            }
            if t.fit == .fill { kids.append(XMLElem("adjust-conform", [("type", "fill")])) }
            // Stretch is the fit picture scaled unevenly.
            let k = t.fit == .stretch ? conformScale(clip) : (x: 1.0, y: 1.0)
            let sx = t.scale * k.x, sy = t.scale * k.y
            if t.x != 0 || t.y != 0 || sx != 1 || sy != 1 || t.rotation != 0 {
                var attrs: [(String, String)] = []
                if t.x != 0 || t.y != 0 { attrs.append(("position", "\(num(t.x * w / h * 100)) \(num(-t.y * 100))")) }
                if sx != 1 || sy != 1 { attrs.append(("scale", "\(num(sx)) \(num(sy))")) }
                if t.rotation != 0 { attrs.append(("rotation", num(-t.rotation))) }
                kids.append(XMLElem("adjust-transform", attrs))
            }
            if t.opacity < 1 - 1e-6 { kids.append(XMLElem("adjust-blend", [("amount", num(t.opacity))])) }
            return kids
        }
        /// The clip's CDL and LUT files, which Final Cut has no place for.
        func note(_ clip: Clip) -> XMLElem? {
            let parts = (clip.cdl.map { [$0.text] } ?? []) + clip.lutFiles.map { "LUT \($0)" } + (ctx.luts[clip.id].map { ["\(Self.gradeLUTTag) \($0)"] } ?? [])
            return parts.isEmpty ? nil : XMLElem("note", text: parts.joined(separator: "; "))
        }
        /// The clip's local start, which is in retimed time when the speed is not 1. A time-mapped clip's local time
        /// starts at its source in, past any split-edit lead.
        func localStart(_ clip: Clip) -> Int {
            if clip.needsTimeMap { return grid.frames(clip.sourceIn) + max(0, grid.frames(clip.audioLead)) }
            return abs(clip.speed - 1) > 1e-9 && clip.speed > 0 ? grid.frames(clip.sourceIn / clip.speed) : grid.frames(clip.sourceIn)
        }
        /// A constant-speed `timeMap`: local time from `origin` to frame `end` plays source time at `speed`.
        func speedMap(origin: RationalTime, end: Int, speed: Double) -> XMLElem {
            let p = Int((speed * 1000).rounded())
            return XMLElem("timeMap", children: [
                XMLElem("timept", [("time", origin.fcp), ("value", origin.fcp), ("interp", "linear")]),
                XMLElem("timept", [("time", (origin + RationalTime(frames: end, grid)).fcp), ("value", (origin + RationalTime(frames: end, grid).scaled(p, 1000)).fcp), ("interp", "linear")]),
            ])
        }
        /// A sequence clip's local start (its sequence time, retimed when it plays at another speed) and timeMap.
        func sequenceTiming(_ clip: Clip, frames: Int) -> (start: Int, map: XMLElem?) {
            let k = Project.sequenceRate(clip)
            guard abs(k - 1) > 1e-9 else { return (grid.frames(clip.sourceIn), nil) }
            let start = grid.frames(clip.sourceIn / k)
            return (start, speedMap(origin: .zero, end: start + frames, speed: k))
        }
        /// Source seconds in thousandths of a frame.
        func sourceTime(_ s: Seconds) -> RationalTime {
            RationalTime(n: Int((s * Double(grid.den) * 1000 / Double(grid.num)).rounded()) * grid.num, d: grid.den * 1000)
        }
        /// A media clip's first frame in its asset's time: the asset's timecode plus its local start.
        func clipStart(_ clip: Clip, _ asset: MediaAsset) -> RationalTime {
            guard !clip.needsTimeMap, abs(clip.speed - 1) <= 1e-9, !asset.isImage else { return assetStart(asset) + RationalTime(frames: localStart(clip), grid) }
            return assetStart(asset) + exactSource(clip.sourceIn, asset)
        }
        /// Source seconds on the asset's frame grid or the timeline's when they fall on one, else to the 48 kHz sample.
        func exactSource(_ s: Seconds, _ asset: MediaAsset) -> RationalTime {
            for g in [FrameGrid(fps: asset.hasVideo && asset.fps > 0 ? asset.fps : canvas.fps), grid] {
                let n = (s * g.rate).rounded()
                if abs(n / g.rate - s) < 1e-6 { return RationalTime(frames: Int(n), g) }
            }
            return RationalTime(n: Int((s * 48000).rounded()), d: 48000)
        }
        func mediaElement(_ clip: Clip, asset: MediaAsset, track: Track, lane: Int?, offset: RationalTime, frames: Int, scope: Project) -> XMLElem {
            let audioOnly = track.kind == .audio
            let origin = assetStart(asset)
            let start = clipStart(clip, asset)
            var attrs: [(String, String)] = [("ref", assetIds[asset.id]!)]
            if let lane { attrs.append(("lane", "\(lane)")) }
            attrs += [("offset", offset.fcp), ("name", clip.name ?? asset.name), ("start", start.fcp), ("duration", grid.fcp(frames))]
            if audioOnly && asset.hasVideo { attrs.append(("srcEnable", "audio")) }
            if audioOnly ? track.muted : track.hidden { attrs.append(("enabled", "0")) }
            if origin != .zero { attrs.append(("tcFormat", asset.timecodeFormat(fallback: canvas.fps, dropFrame: canvas.dropFrame).dropFrame ? "DF" : "NDF")) }
            let sound = asset.hasAudio && !asset.isImage
            let lead = grid.frames(clip.audioLead), lag = grid.frames(clip.audioLag)
            if sound, lead != 0 || lag != 0 {
                attrs += [("audioStart", (start - RationalTime(frames: lead, grid)).fcp), ("audioDuration", grid.fcp(frames + lead + lag))]
            }
            if sound, let role = clip.role { attrs.append(("audioRole", role)) }
            var children: [XMLElem] = []
            if !audioOnly, asset.hasVideo, let n = note(clip) { children.append(n) }
            if clip.needsTimeMap, !asset.isImage {
                // Points where the playback bends, over the sound's reach too.
                let lead = max(0, grid.frames(clip.audioLead)), lag = max(0, grid.frames(clip.audioLag))
                let local = origin + RationalTime(frames: localStart(clip), grid)
                children.append(XMLElem("timeMap", children: clip.timeMap(frames: -lead, frames + lag, grid: grid).map { p in
                    XMLElem("timept", [("time", (local + RationalTime(frames: p.frame, grid)).fcp), ("value", (origin + sourceTime(p.source)).fcp), ("interp", "linear")])
                }))
            } else if abs(clip.speed - 1) > 1e-9, clip.speed > 0, !asset.isImage {
                // Local time runs from the asset's timecode, as source time does.
                children.append(speedMap(origin: origin, end: localStart(clip) + frames, speed: clip.speed))
            }
            if !audioOnly && asset.hasVideo { children += pictureChildren(clip) }
            if sound { children += volumeChildren(clip, track: track, start: start, scope: scope) }
            var md = !audioOnly ? cutlineMetadata(clip).flatMap(\.children) : []
            if sound, let ch = clip.channels {
                // The source channels heard, as Final Cut lists them; Cutline's routing as metadata.
                var a = [("srcCh", (ch.sourceChannels.isEmpty ? [1, 2] : ch.sourceChannels).map(String.init).joined(separator: ", "))]
                if case .pair = ch.form { a.append(("outCh", "L, R")) }
                children.append(XMLElem("audio-channel-source", a))
                md.append(XMLElem("md", [("key", Self.fcpChannelsKey), ("value", ch.rawValue)]))
            }
            if let l = clip.link, scope.tracks.contains(where: { $0.clips.contains { $0.link == l && $0.id != clip.id } }) {
                md.append(XMLElem("md", [("key", Self.fcpLinkKey), ("value", l)]))
            }
            if !md.isEmpty { children.append(XMLElem("metadata", children: md)) }
            return XMLElem(asset.isImage ? "video" : "asset-clip", attrs, children: children)
        }
        /// A solid as Final Cut's Custom solid generator in its color.
        func solidElement(_ clip: Clip, track: Track, lane: Int?, offset: RationalTime, frames: Int) -> XMLElem {
            var attrs: [(String, String)] = [("ref", solidRef)]
            if let lane { attrs.append(("lane", "\(lane)")) }
            attrs += [("offset", offset.fcp), ("name", clip.name ?? "Solid"), ("start", "0s"), ("duration", grid.fcp(frames))]
            if track.hidden { attrs.append(("enabled", "0")) }
            let c = clip.color ?? .black
            return XMLElem("video", attrs, children: [XMLElem("param", [("name", "Color"), ("value", [c.r, c.g, c.b, c.a].map { String(format: "%.4g", $0) }.joined(separator: " "))])]
                + pictureChildren(clip) + cutlineMetadata(clip))
        }
        func titleElement(_ clip: Clip, track: Track, lane: Int?, offset: RationalTime, frames: Int) -> XMLElem {
            let spec = clip.text ?? TextSpec(text: clip.name ?? "")
            styleCount += 1
            let styleId = "ts\(styleCount)"
            var attrs: [(String, String)] = [("ref", titleRef)]
            if let lane { attrs.append(("lane", "\(lane)")) }
            attrs += [("offset", offset.fcp), ("name", clip.name ?? spec.text), ("duration", grid.fcp(frames))]
            if track.hidden { attrs.append(("enabled", "0")) }
            let c = spec.color
            let style = XMLElem("text-style", [
                ("font", Self.fcpFont(spec.font)),
                ("fontSize", "\(Int((spec.size * Double(min(canvas.width, canvas.height))).rounded()))"),
                ("fontFace", spec.weight >= 600 ? "Bold" : "Regular"),
                ("fontColor", [c.r, c.g, c.b, c.a].map { String(format: "%.4g", $0) }.joined(separator: " ")),
                ("alignment", spec.align.rawValue),
            ])
            // Basic Title's Position: pixels from the frame's center, up positive.
            let position = XMLElem("param", [("name", "Position"), ("key", "9999/999166631/999166633/1/100/101"),
                                             ("value", "\(num((spec.x - 0.5) * w)) \(num((0.5 - spec.y) * h))")])
            return XMLElem("title", attrs, children: [
                position,
                XMLElem("text", children: [XMLElem("text-style", [("ref", styleId)], text: spec.text)], inline: true),
                XMLElem("text-style-def", [("id", styleId)], children: [style]),
            ] + cutlineMetadata(clip))
        }
        /// A sequence clip: a `ref-clip` playing the compound clip of its sequence from the clip's offset into it.
        var compounds: [String: String] = [:]
        func refElement(_ clip: Clip, _ seq: NestedSequence, track: Track, lane: Int?, offset: RationalTime, frames: Int, scope: Project) -> XMLElem {
            if let setup = seq.multicam { return mcElement(clip, seq, setup, track: track, lane: lane, offset: offset, frames: frames, scope: scope) }
            let ref: String
            if let known = compounds[seq.id] {
                ref = known
            } else {
                let body = sequenceElement(scope.inside(seq), tcStart: 0, top: false)
                ref = makeId()
                resources.append(XMLElem("media", [("id", ref), ("name", seq.name)], children: [body]))
                compounds[seq.id] = ref
            }
            let audioOnly = track.kind == .audio
            var attrs: [(String, String)] = [("ref", ref)]
            if let lane { attrs.append(("lane", "\(lane)")) }
            let timing = sequenceTiming(clip, frames: frames)
            attrs += [("offset", offset.fcp), ("name", clip.name ?? seq.name), ("start", grid.fcp(timing.start)), ("duration", grid.fcp(frames))]
            if audioOnly { attrs.append(("srcEnable", "audio")) }
            if audioOnly ? track.muted : track.hidden { attrs.append(("enabled", "0")) }
            var children: [XMLElem] = []
            if !audioOnly, let n = note(clip) { children.append(n) }
            if let map = timing.map { children.append(map) }
            if !audioOnly { children += pictureChildren(clip) }
            children += volumeChildren(clip, track: track, start: RationalTime(frames: timing.start, grid), scope: scope)
            return XMLElem("ref-clip", attrs, children: children)
        }
        /// A multicam clip (one piece of `splittingMulticam`): an `mc-clip` of the `multicam` media holding every angle
        /// as an `mc-angle` storyline in multicam time, with `mc-source`s for its picture and sound angles.
        var multicams: [String: (ref: String, ids: [String: String])] = [:]
        func mcElement(_ clip: Clip, _ seq: NestedSequence, _ setup: MulticamSetup, track: Track, lane: Int?, offset: RationalTime, frames: Int, scope: Project) -> XMLElem {
            let known: (ref: String, ids: [String: String])
            if let k = multicams[seq.id] {
                known = k
            } else {
                var ids: [String: String] = [:]
                var angles: [XMLElem] = []
                for (n, a) in setup.angles.enumerated() {
                    guard var t = seq.tracks.first(where: { $0.id == a.track }) else { continue }
                    let angleID = "\(seq.id)-\(n + 1)"
                    ids[a.name] = angleID
                    t.kind = .video
                    let body = sequenceElement(scope.inside(NestedSequence(id: seq.id, name: a.name, tracks: [t])), tcStart: 0, top: false)
                    angles.append(XMLElem("mc-angle", [("name", a.name), ("angleID", angleID)], children: body.children.first?.children ?? []))
                }
                let ref = makeId()
                resources.append(XMLElem("media", [("id", ref), ("name", seq.name)], children: [
                    XMLElem("multicam", [("format", sequenceFormat), ("tcStart", "0s"), ("tcFormat", canvas.isDropFrame ? "DF" : "NDF")], children: angles),
                ]))
                known = (ref, ids)
                multicams[seq.id] = known
            }
            let audioOnly = track.kind == .audio
            let shown = scope.visibleAngleRanges(clip).first
            let picture = shown?.angle ?? setup.videoAngles.first?.name ?? ""
            let sound = shown?.audio ?? setup.audio
            var attrs: [(String, String)] = [("ref", known.ref)]
            if let lane { attrs.append(("lane", "\(lane)")) }
            let timing = sequenceTiming(clip, frames: frames)
            attrs += [("offset", offset.fcp), ("name", clip.name ?? seq.name), ("start", grid.fcp(timing.start)), ("duration", grid.fcp(frames))]
            if audioOnly { attrs.append(("srcEnable", "audio")) }
            if audioOnly ? track.muted : track.hidden { attrs.append(("enabled", "0")) }
            var children: [XMLElem] = []
            if !audioOnly, let n = note(clip) { children.append(n) }
            if let map = timing.map { children.append(map) }
            children += volumeChildren(clip, track: track, start: RationalTime(frames: timing.start, grid), scope: scope)
            var sources: [XMLElem] = []
            if !audioOnly, let id = known.ids[picture] {
                sources.append(XMLElem("mc-source", [("angleID", id), ("srcEnable", sound.contains(picture) ? "all" : "video")], children: pictureChildren(clip)))
            }
            for name in sound where audioOnly || name != picture {
                if let id = known.ids[name] { sources.append(XMLElem("mc-source", [("angleID", id), ("srcEnable", "audio")])) }
            }
            return XMLElem("mc-clip", attrs, children: children + sources)
        }

        struct SpineItem {
            var elem: XMLElem
            var offset: Int
            /// The item's first frame in its own time.
            var localStart: RationalTime
            var frames: Int
            var anchored: [(offset: Int, lane: Int, elem: XMLElem)] = []
            var markers: [XMLElem] = []
            var clipId: String?
        }
        /// A sequence whose timeline starts at frame `tcStart`: its lowest video track is the spine, the rest connect to it.
        func sequenceElement(_ scope: Project, tcStart tc: Int, top: Bool) -> XMLElem {
            func gapItem(_ offset: Int, _ frames: Int, name: String = "Gap") -> SpineItem {
                SpineItem(elem: XMLElem("gap", [("name", name), ("offset", grid.fcp(tc + offset)), ("duration", grid.fcp(frames))]), offset: offset, localStart: .zero, frames: frames)
            }
            func sequenceClip(_ clip: Clip) -> NestedSequence? { clip.kind == .sequence ? clip.mediaId.flatMap(scope.sequence) : nil }
            let videoTracks = scope.tracks.filter { $0.kind == .video }
            var spine: [SpineItem] = []
            var cursor = 0
            if let primary = videoTracks.first {
                for clip in primary.clips.sorted(by: { $0.start < $1.start }) {
                    let s = max(grid.frames(clip.start), cursor), e = grid.frames(clip.end)
                    guard e > s else { continue }
                    if s > cursor { spine.append(gapItem(cursor, s - cursor)) }
                    let at = RationalTime(frames: tc + s, grid)
                    if clip.kind == .media, let asset = clip.mediaId.flatMap(mediaAsset) {
                        spine.append(SpineItem(elem: mediaElement(clip, asset: asset, track: primary, lane: nil, offset: at, frames: e - s, scope: scope),
                                               offset: s, localStart: clipStart(clip, asset), frames: e - s, clipId: clip.id))
                    } else if let seq = sequenceClip(clip) {
                        spine.append(SpineItem(elem: refElement(clip, seq, track: primary, lane: nil, offset: at, frames: e - s, scope: scope),
                                               offset: s, localStart: RationalTime(frames: sequenceTiming(clip, frames: e - s).start, grid), frames: e - s, clipId: clip.id))
                    } else if clip.kind == .text {
                        spine.append(SpineItem(elem: titleElement(clip, track: primary, lane: nil, offset: at, frames: e - s), offset: s, localStart: .zero, frames: e - s, clipId: clip.id))
                    } else if clip.kind == .solid {
                        spine.append(SpineItem(elem: solidElement(clip, track: primary, lane: nil, offset: at, frames: e - s), offset: s, localStart: .zero, frames: e - s, clipId: clip.id))
                    } else {
                        spine.append(gapItem(s, e - s, name: clip.name ?? clip.kind.rawValue.capitalized))
                    }
                    cursor = e
                }
            }
            let markers = top ? scope.markers.filter { $0.time >= 0 } : []
            let markerEnd = markers.map { grid.frames($0.time) + 1 }.max() ?? 0
            let end = max(grid.frames(scope.duration), markerEnd, cursor, 1)
            if end > cursor { spine.append(gapItem(cursor, end - cursor)) }

            func parent(of frame: Int) -> Int {
                spine.firstIndex { frame >= $0.offset && frame < $0.offset + $0.frames } ?? (spine.count - 1)
            }

            /// A transition placed in its storyline's time (timeline frames from `tc`); a crossfade is its `filter-audio`.
            func transitionElem(_ tr: Transition) -> XMLElem? {
                guard let at = scope.transitionFrames(tr, grid: grid, sound: false) else { return nil }
                let video = tr.type == "dip" ? "Fade To Color" : "Cross Dissolve"
                var kids: [XMLElem] = []
                if tr.hasVideo { kids.append(XMLElem("filter-video", [("ref", dissolveRef), ("name", video)])) }
                if tr.hasAudio { kids.append(XMLElem("filter-audio", [("ref", crossfadeRef), ("name", "Audio Crossfade")])) }
                return XMLElem("transition", [("name", tr.hasVideo ? video : "Audio Crossfade"), ("offset", grid.fcp(tc + at.start)), ("duration", grid.fcp(at.length))], children: kids)
            }
            func transitions(from a: String?, to b: String?) -> [XMLElem] {
                scope.transitions.filter { $0.from == a && $0.to == b }.compactMap(transitionElem)
            }

            // Connected clips; ones joined by transitions go in a storyline of their own, which can hold them.
            let connected: [(track: Track, lane: Int)] =
                videoTracks.dropFirst().enumerated().map { (track: $0.element, lane: $0.offset + 1) }
                + scope.tracks.filter { $0.kind == .audio }.enumerated().map { (track: $0.element, lane: -($0.offset + 1)) }
            func connectedElem(_ clip: Clip, track: Track, lane: Int?, offset: RationalTime) -> XMLElem? {
                let frames = grid.frames(clip.end) - grid.frames(clip.start)
                if clip.kind == .media, let asset = clip.mediaId.flatMap(mediaAsset) {
                    if track.kind == .audio && !asset.hasAudio { return nil }
                    return mediaElement(clip, asset: asset, track: track, lane: lane, offset: offset, frames: frames, scope: scope)
                } else if let seq = sequenceClip(clip) {
                    return refElement(clip, seq, track: track, lane: lane, offset: offset, frames: frames, scope: scope)
                } else if clip.kind == .text, track.kind == .video {
                    return titleElement(clip, track: track, lane: lane, offset: offset, frames: frames)
                } else if clip.kind == .solid, track.kind == .video {
                    return solidElement(clip, track: track, lane: lane, offset: offset, frames: frames)
                }
                return nil
            }
            for (track, lane) in connected {
                let clips = track.clips.filter { grid.frames($0.end) > grid.frames($0.start) && grid.frames($0.start) >= 0 }.sorted { $0.start < $1.start }
                var k = 0
                while k < clips.count {
                    var run = [clips[k]]
                    // Butting sound clips whose sound overlaps share a storyline, where expanded audio may overlap.
                    func joined(_ a: Clip, _ b: Clip) -> Bool {
                        !transitions(from: a.id, to: b.id).isEmpty || track.kind == .audio && a.kind == .media && b.kind == .media
                            && grid.frames(a.end) == grid.frames(b.start) && grid.frames(a.audioRange.end) > grid.frames(b.audioRange.start)
                    }
                    while k + run.count < clips.count, joined(run.last!, clips[k + run.count]) { run.append(clips[k + run.count]) }
                    k += run.count
                    let s = grid.frames(run[0].start)
                    let p = parent(of: s)
                    let offset = spine[p].localStart + RationalTime(frames: s - spine[p].offset, grid)
                    let fadeIn = transitions(from: nil, to: run[0].id), fadeOut = transitions(from: run.last!.id, to: nil)
                    if run.count == 1, fadeIn.isEmpty, fadeOut.isEmpty {
                        if let elem = connectedElem(run[0], track: track, lane: lane, offset: offset) { spine[p].anchored.append((s, lane, elem)) }
                        continue
                    }
                    var inner = fadeIn
                    for (i, clip) in run.enumerated() {
                        guard let elem = connectedElem(clip, track: track, lane: nil, offset: RationalTime(frames: tc + grid.frames(clip.start), grid)) else { continue }
                        inner.append(elem)
                        if i + 1 < run.count { inner += transitions(from: clip.id, to: run[i + 1].id) }
                    }
                    inner += fadeOut
                    spine[p].anchored.append((s, lane, XMLElem("spine", [("lane", "\(lane)"), ("offset", offset.fcp)], children: inner)))
                }
            }

            // Markers
            for m in markers.sorted(by: { $0.time < $1.time }) {
                let f = grid.frames(m.time)
                let p = parent(of: f)
                spine[p].markers.append(XMLElem("marker", [("start", (spine[p].localStart + RationalTime(frames: f - spine[p].offset, grid)).fcp), ("duration", grid.fcp(1)), ("value", m.label)]))
            }

            var spineElems: [XMLElem] = []
            for (k, item) in spine.enumerated() {
                var e = item.elem
                e.children += item.anchored.sorted { ($0.offset, $0.lane) < ($1.offset, $1.lane) }.map(\.elem)
                e.children += item.markers
                let last = ["audio-channel-source", "metadata"]
                e.children = e.children.filter { !last.contains($0.name) } + last.flatMap { n in e.children.filter { $0.name == n } }
                // A transition sits between the two spine items it joins, overlapping both; from or to nothing, beside a gap.
                let before = k > 0 ? spine[k - 1].clipId : nil, after = k + 1 < spine.count ? spine[k + 1].clipId : nil
                if let id = item.clipId, before == nil { spineElems += transitions(from: nil, to: id) }
                spineElems.append(e)
                if let id = item.clipId {
                    if let next = after { spineElems += transitions(from: id, to: next) } else { spineElems += transitions(from: id, to: nil) }
                }
            }
            return XMLElem("sequence", [
                ("format", sequenceFormat), ("duration", grid.fcp(end)), ("tcStart", grid.fcp(tc)), ("tcFormat", canvas.isDropFrame ? "DF" : "NDF"),
                ("audioLayout", "stereo"), ("audioRate", "48k"),
            ], children: [XMLElem("spine", children: spineElems)])
        }

        let sequence = sequenceElement(self, tcStart: startFrame, top: true)
        let root = XMLElem("fcpxml", [("version", "1.11")], children: [
            XMLElem("resources", children: resources),
            XMLElem("library", children: [
                XMLElem("event", [("name", name)], children: [XMLElem("project", [("name", name)], children: [sequence])]),
            ]),
        ])
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n\n"
        root.write(&out, depth: 0)
        return out
    }

    static func fcpFont(_ font: String) -> String {
        switch font {
        case "system", "rounded": return "Helvetica Neue"
        case "serif": return "Times New Roman"
        case "mono": return "Menlo"
        default: return font
        }
    }

    /// Final Cut's name for common formats, e.g. "FFVideoFormat1080p2997"; nil for custom sizes.
    static func fcpFormatName(width: Int, height: Int, grid: FrameGrid?) -> String? {
        guard let grid else { return "FFVideoFormatRateUndefined" }
        let sizes = [(1280, 720, "720p"), (1920, 1080, "1080p"), (3840, 2160, "3840x2160p")]
        guard let size = sizes.first(where: { $0.0 == width && $0.1 == height })?.2 else { return nil }
        let rates: [String: String] = ["1001/24000": "2398", "100/2400": "24", "100/2500": "25", "1001/30000": "2997",
                                       "100/3000": "30", "100/5000": "50", "1001/60000": "5994", "100/6000": "60"]
        return rates["\(grid.num)/\(grid.den)"].map { "FFVideoFormat\(size)\($0)" }
    }
}
