import Foundation

/// One synced source of a multicam clip: a camera (picture and its sound) or a sound-only recorder.
public struct MulticamAngle: Codable, Equatable, Sendable {
    /// Unique within the multicam; angles are also addressed by number (1…) and media id.
    public var name: String
    /// The inner track holding this angle's footage.
    public var track: String
    public var mediaId: String
    /// Source time in the media at multicam time 0, so source = multicam time + offset.
    public var offset: Seconds
    public var video: Bool
    public var audio: Bool

    public init(name: String, track: String, mediaId: String, offset: Seconds, video: Bool, audio: Bool) {
        self.name = name
        self.track = track
        self.mediaId = mediaId
        self.offset = offset
        self.video = video
        self.audio = audio
    }
}

/// What makes a nested sequence a multicam source: its synced angles and the sound it plays by default.
public struct MulticamSetup: Codable, Equatable, Sendable {
    public var angles: [MulticamAngle]
    /// Angle names heard by default.
    public var audio: [String]
    /// How the angles were lined up: audio, timecode, marker or in_points.
    public var sync: String

    public init(angles: [MulticamAngle], audio: [String], sync: String) {
        self.angles = angles
        self.audio = audio
        self.sync = sync
    }

    /// An angle by name, number ("2") or media id.
    public func angle(_ key: String) -> MulticamAngle? {
        if let a = angles.first(where: { $0.name == key }) { return a }
        if let n = Int(key), angles.indices.contains(n - 1) { return angles[n - 1] }
        return angles.first { $0.mediaId == key }
    }

    public func number(_ name: String) -> Int { (angles.firstIndex { $0.name == name } ?? -1) + 1 }
    public var videoAngles: [MulticamAngle] { angles.filter(\.video) }
}

/// From multicam time `at`, the picture plays `angle`; `audio` overrides the clip's sound until the next cut.
public struct AngleCut: Codable, Equatable, Sendable {
    public var at: Seconds
    public var angle: String
    public var audio: [String]?

    public init(at: Seconds, angle: String, audio: [String]? = nil) {
        self.at = at
        self.angle = angle
        self.audio = audio
    }
}

/// A multicam clip's angle switching, in multicam (sequence) time so it survives moves, trims and splits.
public struct MulticamSwitch: Codable, Equatable, Sendable {
    /// Sorted by time; the first cut's angle also plays before it.
    public var cuts: [AngleCut]
    /// Sound angles; nil plays the multicam's default.
    public var audio: [String]?
    /// Each range plays the sound of the angle on screen (when it has sound).
    public var audioFollowsVideo: Bool

    public init(cuts: [AngleCut], audio: [String]? = nil, audioFollowsVideo: Bool = false) {
        self.cuts = cuts
        self.audio = audio
        self.audioFollowsVideo = audioFollowsVideo
    }
}

/// A stretch of a multicam clip with one active picture angle and sound.
public struct AngleRange: Equatable, Sendable {
    /// Multicam time.
    public var range: TimeRange
    public var angle: String
    public var audio: [String]
}

extension Project {
    /// The multicam setup a clip plays, when it is a multicam clip.
    public func multicamSetup(_ clip: Clip) -> MulticamSetup? {
        guard clip.kind == .sequence else { return nil }
        return clip.mediaId.flatMap { sequence($0) }?.multicam
    }

    /// Multicam time at timeline time `t` of a multicam clip, and back.
    public static func multicamTime(_ clip: Clip, timeline t: Seconds) -> Seconds { clip.sourceIn + (t - clip.start) * sequenceRate(clip) }
    public static func timelineTime(_ clip: Clip, multicam m: Seconds) -> Seconds { clip.start + (m - clip.sourceIn) / sequenceRate(clip) }

    /// Builds a multicam source sequence from synced angles. `offsets` are each angle's source time at the moment
    /// the angles share as zero; the earliest angle starts the sequence.
    public mutating func createMulticam(name: String, angles raw: [(name: String, mediaId: String, offset: Seconds)], audio: [String], sync: String) throws -> NestedSequence {
        guard raw.count >= 2 else { throw EditError("A multicam needs at least two angles") }
        guard Set(raw.map(\.name)).count == raw.count else { throw EditError("Angle names must differ: \(raw.map(\.name).joined(separator: ", "))") }
        var assets: [MediaAsset] = []
        for a in raw {
            guard let m = mediaAsset(a.mediaId) else { throw EditError("No media \(a.mediaId)") }
            guard !m.isImage, m.hasVideo || m.hasAudio else { throw EditError("\(a.mediaId) is a still; multicam angles are video or sound recordings") }
            assets.append(m)
        }
        guard assets.contains(where: \.hasVideo) else { throw EditError("A multicam needs at least one video angle") }
        // Shift so the earliest angle starts at multicam time 0.
        let shift = raw.map { -$0.offset }.min()!
        let seqId = IDs.make("mc")
        var angles: [MulticamAngle] = []
        var tracks: [Track] = []
        for (i, (a, m)) in zip(raw, assets).enumerated() {
            let offset = a.offset + shift
            let trackId = "angle\(i + 1)"
            let start = canvas.snap(max(0, -offset))
            var c = Clip(id: "\(seqId)-\(i + 1)", kind: .media, name: a.name, mediaId: m.id, start: start, duration: m.duration - (start + offset), sourceIn: start + offset)
            if m.hasVideo { c.transform.fit = .fill }
            guard c.duration > canvas.frameDuration else { throw EditError("\(a.name) has no footage after the sync point") }
            tracks.append(Track(id: trackId, kind: m.hasVideo ? .video : .audio, name: a.name, clips: [c]))
            angles.append(MulticamAngle(name: a.name, track: trackId, mediaId: m.id, offset: offset, video: m.hasVideo, audio: m.hasAudio))
        }
        let setup = MulticamSetup(angles: angles, audio: [], sync: sync)
        var heard: [String] = []
        for key in audio {
            guard let a = setup.angle(key), a.audio else { throw EditError("\(key) is not an angle with sound (angles: \(angles.map(\.name).joined(separator: ", ")))") }
            heard.append(a.name)
        }
        if heard.isEmpty, let first = angles.first(where: \.audio) { heard = [first.name] }
        var seq = NestedSequence(id: seqId, name: name, tracks: tracks)
        seq.multicam = MulticamSetup(angles: angles, audio: heard, sync: sync)
        sequences.append(seq)
        return seq
    }

    /// The span of multicam time every video angle covers.
    public func multicamOverlap(_ seq: NestedSequence) -> TimeRange? {
        guard let setup = seq.multicam else { return nil }
        var lo = 0.0, hi = seq.duration
        for a in setup.videoAngles {
            let clips = seq.tracks.first { $0.id == a.track }?.clips ?? []
            lo = max(lo, clips.map(\.start).min() ?? lo)
            hi = min(hi, clips.map(\.end).max() ?? hi)
        }
        return hi > lo ? TimeRange(lo, hi) : nil
    }

    /// Active picture angle and sound over the whole multicam, cut by the clip's switch list.
    public func angleRanges(_ clip: Clip) -> [AngleRange] {
        guard let seq = clip.mediaId.flatMap({ sequence($0) }), let setup = seq.multicam else { return [] }
        let sw = clip.multicam ?? MulticamSwitch(cuts: [])
        let first = sw.cuts.first?.angle ?? setup.videoAngles.first?.name ?? ""
        let cuts = sw.cuts.filter { $0.at > eps && $0.at < seq.duration - eps }
        var bounds = [AngleCut(at: 0, angle: first, audio: sw.cuts.first?.audio)] + cuts
        bounds.append(AngleCut(at: seq.duration, angle: ""))
        var out: [AngleRange] = []
        for i in 0..<(bounds.count - 1) where bounds[i + 1].at > bounds[i].at + eps {
            let angle = setup.angle(bounds[i].angle)?.name ?? first
            var sound = bounds[i].audio ?? sw.audio ?? setup.audio
            if bounds[i].audio == nil, sw.audioFollowsVideo, setup.angle(angle)?.audio == true { sound = [angle] }
            sound = sound.compactMap { setup.angle($0)?.name }
            if let last = out.last, last.angle == angle, last.audio == sound {
                out[out.count - 1].range.end = bounds[i + 1].at
            } else {
                out.append(AngleRange(range: TimeRange(bounds[i].at, bounds[i + 1].at), angle: angle, audio: sound))
            }
        }
        return out
    }

    /// The ranges a multicam clip shows on the timeline, in timeline time.
    public func visibleAngleRanges(_ clip: Clip) -> [AngleRange] {
        let lo = clip.sourceIn, hi = Project.sequenceWindow(clip).end
        return angleRanges(clip).compactMap { r in
            let a = max(r.range.start, lo), b = min(r.range.end, hi)
            guard b > a + eps else { return nil }
            return AngleRange(range: TimeRange(Project.timelineTime(clip, multicam: a), Project.timelineTime(clip, multicam: b)), angle: r.angle, audio: r.audio)
        }
    }

    /// What a sequence clip plays: a multicam clip's angles cut down to the active picture and sound, else its sequence.
    public func contents(of clip: Clip) -> NestedSequence? {
        guard let seq = clip.mediaId.flatMap({ sequence($0) }) else { return nil }
        guard let setup = seq.multicam else { return seq }
        func pieces(_ angle: String, _ r: TimeRange, _ tag: String) -> [Clip] {
            guard let a = setup.angle(angle), let track = seq.tracks.first(where: { $0.id == a.track }) else { return [] }
            return track.clips.compactMap { inner in
                guard inner.end > r.start + eps, inner.start < r.end - eps else { return nil }
                var c = inner
                if c.start < r.start { c = Project.trimmedLeft(c, to: r.start) }
                if c.end > r.end { c = Project.trimmedRight(c, to: r.end) }
                c.id = "\(inner.id)~\(tag)"
                return c
            }
        }
        var picture: [Clip] = []
        var sound: [[Clip]] = []
        for (k, r) in angleRanges(clip).enumerated() {
            picture += pieces(r.angle, r.range, "\(k)").map { var c = $0; c.volume = 0; return c }
            for (j, name) in r.audio.enumerated() {
                if sound.count <= j { sound.append([]) }
                for var c in pieces(name, r.range, "\(k)a\(j)") {
                    c.transform = Transform()
                    // Sound from the same recording carries on across picture cuts.
                    if let last = sound[j].last, last.mediaId == c.mediaId, abs(last.end - c.start) < eps, abs(last.sourceOut - c.sourceIn) < eps {
                        sound[j][sound[j].count - 1].duration += c.duration
                    } else {
                        sound[j].append(c)
                    }
                }
            }
        }
        var tracks = [Track(id: "picture", kind: .video, name: "Active angle", clips: picture)]
        for (j, clips) in sound.enumerated() { tracks.append(Track(id: "sound\(j + 1)", kind: .audio, name: "Sound \(j + 1)", clips: clips)) }
        return NestedSequence(id: seq.id, name: seq.name, tracks: tracks)
    }

    /// Switches a multicam clip's picture (and optionally sound) to `angle` from timeline time `from` until `to`,
    /// or until the next cut when `to` is nil. Returns a line describing the switch.
    @discardableResult
    public mutating func switchMulticam(_ clipId: String, from: Seconds, to: Seconds? = nil, angle: String?, audio: [String]? = nil) throws -> String {
        guard let loc = locateClip(clipId) else { throw EditError("No clip \(clipId)") }
        var clip = tracks[loc.track].clips[loc.clip]
        guard let setup = multicamSetup(clip) else { throw EditError("\(clipId) is not a multicam clip; make one with multicam_create") }
        let a = canvas.snap(max(clip.start, from)), b = to.map { canvas.snap(min(clip.end, $0)) }
        guard a < clip.end - eps else { throw EditError("\(fmt2(from))s is outside \(clipId) (\(fmt2(clip.start))–\(fmt2(clip.end))s)") }
        if let b, b <= a + eps { throw EditError("to must come after from") }
        let ma = Project.multicamTime(clip, timeline: a), mb = b.map { Project.multicamTime(clip, timeline: $0) }
        var sw = clip.multicam ?? MulticamSwitch(cuts: [])
        var cuts = sw.cuts
        if cuts.isEmpty, let first = setup.videoAngles.first { cuts = [AngleCut(at: 0, angle: first.name)] }
        if let first = cuts.first, first.at > eps { cuts.insert(AngleCut(at: 0, angle: first.angle, audio: first.audio), at: 0) }
        func effective(_ m: Seconds) -> AngleCut { cuts.last { $0.at <= m + eps } ?? cuts[0] }
        var picture = effective(ma).angle
        if let angle {
            guard let found = setup.angle(angle), found.video else { throw EditError("No video angle \(angle) in \(clip.name ?? clipId) (angles: " + setup.videoAngles.map { "\(setup.number($0.name)) \($0.name)" }.joined(separator: ", ") + ")") }
            picture = found.name
        }
        var sound = effective(ma).audio
        if let audio {
            sound = try audio.map { key in
                guard let s = setup.angle(key), s.audio else { throw EditError("No angle with sound \(key)") }
                return s.name
            }
        }
        // What plays after the switched range keeps playing there.
        let resume = mb.map { m -> AngleCut in var c = effective(m); c.at = m; return c }
        cuts.removeAll { $0.at >= ma - eps && $0.at <= (mb ?? ma) + eps }
        cuts.append(AngleCut(at: ma, angle: picture, audio: sound))
        if let resume { cuts.append(resume) }
        sw.cuts = cuts
        clip.multicam = Project.simplified(sw)
        tracks[loc.track].clips[loc.clip] = clip
        let span = b.map { "\(fmt2(a))–\(fmt2($0))s" } ?? "from \(fmt2(a))s"
        return "\(clipId) \(span): angle \(setup.number(picture)) \(picture)" + (audio != nil ? ", sound " + (sound ?? []).joined(separator: "+") : "")
    }

    /// Replaces a multicam clip's switch list with cuts at timeline times.
    public mutating func setMulticamCuts(_ clipId: String, cuts: [(at: Seconds, angle: String)], audioFollowsVideo: Bool? = nil, audio: [String]? = nil) throws {
        guard let loc = locateClip(clipId) else { throw EditError("No clip \(clipId)") }
        var clip = tracks[loc.track].clips[loc.clip]
        guard let setup = multicamSetup(clip) else { throw EditError("\(clipId) is not a multicam clip") }
        var sw = clip.multicam ?? MulticamSwitch(cuts: [])
        var list: [AngleCut] = []
        for c in cuts.sorted(by: { $0.at < $1.at }) {
            guard let a = setup.angle(c.angle), a.video else { throw EditError("No video angle \(c.angle)") }
            list.append(AngleCut(at: max(0, Project.multicamTime(clip, timeline: canvas.snap(c.at))), angle: a.name))
        }
        sw.cuts = list
        if let audioFollowsVideo { sw.audioFollowsVideo = audioFollowsVideo }
        if let audio {
            sw.audio = try audio.map { key in
                guard let s = setup.angle(key), s.audio else { throw EditError("No angle with sound \(key)") }
                return s.name
            }
        }
        clip.multicam = Project.simplified(sw)
        tracks[loc.track].clips[loc.clip] = clip
    }

    /// Sets a multicam clip's sound: fixed angles, or following the picture.
    public mutating func setMulticamSound(_ clipId: String, audio: [String]?, followsVideo: Bool?) throws {
        guard let loc = locateClip(clipId) else { throw EditError("No clip \(clipId)") }
        var clip = tracks[loc.track].clips[loc.clip]
        guard let setup = multicamSetup(clip) else { throw EditError("\(clipId) is not a multicam clip") }
        var sw = clip.multicam ?? MulticamSwitch(cuts: [])
        if let followsVideo { sw.audioFollowsVideo = followsVideo }
        if let audio {
            sw.audio = try audio.map { key in
                guard let s = setup.angle(key), s.audio else { throw EditError("No angle with sound \(key)") }
                return s.name
            }
        }
        clip.multicam = sw
        tracks[loc.track].clips[loc.clip] = clip
    }

    /// Cuts sorted, the first at 0, with repeats of the angle and sound already playing removed.
    static func simplified(_ sw: MulticamSwitch) -> MulticamSwitch {
        var out = sw
        out.cuts = []
        for c in sw.cuts.sorted(by: { $0.at < $1.at }) {
            if let l = out.cuts.last, abs(l.at - c.at) < eps { out.cuts[out.cuts.count - 1] = c; continue }
            if let l = out.cuts.last, l.angle == c.angle, l.audio == c.audio { continue }
            out.cuts.append(c)
        }
        if !out.cuts.isEmpty { out.cuts[0].at = 0 }
        return out
    }

    /// The project with every multicam clip replaced by a plain nested sequence of its active angles, for formats
    /// and tools that don't know multicam.
    public func flatteningMulticam() -> Project {
        guard sequences.contains(where: { $0.multicam != nil }) else { return self }
        var p = self
        for t in p.tracks.indices {
            for i in p.tracks[t].clips.indices {
                let c = p.tracks[t].clips[i]
                guard multicamSetup(c) != nil, var seq = contents(of: c) else { continue }
                seq.id = "\(seq.id)-\(c.id)"
                seq.name = (c.name ?? seq.name) + " (active angles)"
                p.sequences.append(seq)
                p.tracks[t].clips[i].mediaId = seq.id
                p.tracks[t].clips[i].multicam = nil
            }
        }
        let used = Set((p.tracks + p.sequences.flatMap(\.tracks)).flatMap(\.clips).compactMap { $0.kind == .sequence ? $0.mediaId : nil })
        p.sequences.removeAll { $0.multicam != nil && !used.contains($0.id) }
        return p
    }

    /// The project with every multicam clip cut into one clip per angle switch, each playing one picture angle and
    /// its sound from the start, as FCPXML (`mc-clip`) and FCP7 XML (`multiclip`) write them. The first piece keeps
    /// the clip's id and fades in, the last its fade out and the transitions from it.
    public func splittingMulticam() -> Project {
        guard sequences.contains(where: { $0.multicam != nil }) else { return self }
        var p = self
        func split(_ tracks: inout [Track], _ transitions: inout [Transition]) {
            for t in tracks.indices {
                var out: [Clip] = []
                for c in tracks[t].clips {
                    guard multicamSetup(c) != nil else { out.append(c); continue }
                    let ranges = visibleAngleRanges(c)
                    for (k, r) in ranges.enumerated() {
                        var piece = c
                        if r.range.start > piece.start + eps { piece = Project.trimmedLeft(piece, to: r.range.start) }
                        if r.range.end < piece.end - eps { piece = Project.trimmedRight(piece, to: r.range.end) }
                        if k > 0 {
                            piece.id = "\(c.id)~\(k)"
                            piece.fadeIn = 0
                            piece.audioFadeIn = 0
                        }
                        if k < ranges.count - 1 {
                            piece.fadeOut = 0
                            piece.audioFadeOut = 0
                        }
                        piece.multicam = MulticamSwitch(cuts: [AngleCut(at: 0, angle: r.angle)], audio: r.audio)
                        out.append(piece)
                    }
                    if ranges.count > 1 {
                        for i in transitions.indices where transitions[i].from == c.id { transitions[i].from = "\(c.id)~\(ranges.count - 1)" }
                    }
                    if ranges.isEmpty { out.append(c) }
                }
                tracks[t].clips = out
            }
        }
        split(&p.tracks, &p.transitions)
        for s in p.sequences.indices where p.sequences[s].multicam == nil {
            var seq = p.sequences[s]
            split(&seq.tracks, &seq.transitions)
            p.sequences[s] = seq
        }
        return p
    }

    /// Joins butting pieces of one multicam clip, read from formats that write a clip per angle switch, back into
    /// one clip whose switch list has a cut where each piece starts. Each piece carries its picture angle as its
    /// first cut and its sound as its switch's `audio`.
    mutating func joinMulticamPieces() {
        let half = canvas.frameDuration / 2
        let all = sequences
        func join(_ tracks: inout [Track], _ transitions: inout [Transition]) {
            for t in tracks.indices {
                var out: [Clip] = []
                for c in tracks[t].clips.sorted(by: { $0.start < $1.start }) {
                    if var a = out.last, a.kind == .sequence, c.kind == .sequence, a.mediaId == c.mediaId,
                       let id = c.mediaId, all.first(where: { $0.id == id })?.multicam != nil, let sw = a.multicam, let next = c.multicam,
                       abs(a.end - c.start) < half, abs(Project.sequenceWindow(a).end - c.sourceIn) < half * Project.sequenceRate(a),
                       abs(a.speed - c.speed) < 1e-6, !a.isRetimed, !c.isRetimed, !a.reverse, !c.reverse,
                       !transitions.contains(where: { $0.from == a.id && $0.to == c.id }) {
                        var cuts = sw.cuts
                        if let n = next.cuts.first {
                            let sound = n.audio ?? next.audio
                            cuts.append(AngleCut(at: c.sourceIn, angle: n.angle, audio: sound == sw.audio ? nil : sound ?? []))
                        }
                        a.duration = c.end - a.start
                        a.fadeOut = c.fadeOut
                        a.audioFadeOut = c.audioFadeOut
                        a.multicam = Project.simplified(MulticamSwitch(cuts: cuts, audio: sw.audio, audioFollowsVideo: sw.audioFollowsVideo))
                        out[out.count - 1] = a
                        for i in transitions.indices where transitions[i].from == c.id { transitions[i].from = a.id }
                        continue
                    }
                    out.append(c)
                }
                tracks[t].clips = out
            }
        }
        join(&tracks, &transitions)
        for s in sequences.indices {
            var seq = sequences[s]
            join(&seq.tracks, &seq.transitions)
            sequences[s] = seq
        }
    }
}
