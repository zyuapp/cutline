import Foundation

extension Project {
    /// Timeline ranges where speech is heard on the given tracks (all unmuted tracks when empty),
    /// from transcripts. Words closer than `bridge` are joined into one range.
    public func speechRanges(transcripts: [String: Transcript], trackIds: [String] = [], bridge: Seconds = 0.6) -> [TimeRange] {
        let words = timelineWords(transcripts: transcripts, trackIds: trackIds)
        return TimeRange.merged(words.map { TimeRange($0.start, $0.end) }, tolerance: bridge)
    }

    /// Lowers the volume of clips while speech plays, by writing audio.volume animation.
    /// Returns how many dips were written.
    @discardableResult
    public mutating func duck(clipIds: [String], under speech: [TimeRange], amountDb: Double, attack: Seconds, release: Seconds) throws -> Int {
        let dip = pow(10, -abs(amountDb) / 20)
        var dips = 0
        for id in clipIds {
            guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
            var c = tracks[loc.track].clips[loc.clip]
            let full = c.volume
            let low = full * dip
            // Expand each speech range by attack and release, then merge so dips never fight.
            let windows = TimeRange.merged(speech.compactMap { r -> TimeRange? in
                let w = TimeRange(r.start - attack, r.end + release)
                return w.intersection(TimeRange(c.start, c.end)) != nil ? w : nil
            })
            var keys: [CurveKey] = []
            for w in windows {
                let down = max(0, w.start - c.start), up = min(c.duration, w.end - c.start)
                let inner0 = min(down + attack, up), inner1 = max(up - release, inner0)
                keys.append(CurveKey(t: down, v: .number(full), ease: .easeInOut))
                keys.append(CurveKey(t: inner0, v: .number(low), ease: .easeInOut))
                keys.append(CurveKey(t: inner1, v: .number(low), ease: .linear))
                keys.append(CurveKey(t: up, v: .number(full), ease: .easeInOut))
                dips += 1
            }
            var deduped: [CurveKey] = []
            for k in keys.sorted(by: { $0.t < $1.t }) {
                if let last = deduped.last, abs(last.t - k.t) < 1e-4 { deduped[deduped.count - 1] = k } else { deduped.append(k) }
            }
            try c.animate("audio.volume", keys: deduped)
            tracks[loc.track].clips[loc.clip] = c
        }
        return dips
    }

    /// Makes the cut between two adjacent clips a split edit. Positive `offset` is a J cut
    /// (the second clip's sound starts early); negative is an L cut (the first clip's sound runs long).
    /// The offset snaps to whole frames unless `subframe`; returns the offset applied.
    @discardableResult
    public mutating func splitEdit(left leftId: String, right rightId: String, offset requested: Seconds, subframe: Bool = false) throws -> Seconds {
        let offset = subframe ? requested : canvas.snap(requested)
        guard let l = locateClip(leftId), let r = locateClip(rightId) else { throw EditError("Both clips must exist") }
        guard l.track == r.track else { throw EditError("\(leftId) and \(rightId) are on different tracks") }
        let a = tracks[l.track].clips[l.clip], b = tracks[r.track].clips[r.clip]
        guard abs(a.end - b.start) < 1e-3 else { throw EditError("\(leftId) must end where \(rightId) starts (they're \(fmt(b.start - a.end))s apart)") }
        var na = a, nb = b
        if offset >= 0 {
            nb.audioLead = offset
            na.audioLag = -offset
        } else {
            na.audioLag = -offset
            nb.audioLead = offset
        }
        guard na.audioRange.duration > 0.05, nb.audioRange.duration > 0.05 else { throw EditError("A \(fmt(abs(offset)))s split would leave no sound on one of the clips") }
        let track = tracks[l.track]
        try checkClipFits(na, track: track)
        try checkClipFits(nb, track: track)
        tracks[l.track].clips[l.clip] = na
        tracks[r.track].clips[r.clip] = nb
        return offset
    }

    /// " (snapped to 14 frames, 0.583s)" when snapping moved `requested`, else "".
    public func snapNote(_ requested: Seconds, _ applied: Seconds) -> String {
        guard abs(requested - applied) > 1e-6 else { return "" }
        let frames = Int((abs(applied) * canvas.fps).rounded())
        return " (snapped from \(fmt(requested))s to \(frames) frame\(frames == 1 ? "" : "s") at \(fmt(canvas.fps))fps, \(fmt(applied))s; subframe:true keeps it sample-accurate)"
    }
}

/// A clip-sized piece of a looped or room-tone sound: where it sits and where it reads.
public struct SoundPiece: Equatable, Sendable {
    public var start: Seconds
    public var duration: Seconds
    public var sourceIn: Seconds

    public init(start: Seconds, duration: Seconds, sourceIn: Seconds) {
        self.start = start
        self.duration = duration
        self.sourceIn = sourceIn
    }
}

extension Project {
    /// Whether a clip carries sound of its own.
    func hasSound(_ c: Clip) -> Bool {
        guard c.kind == .media, let m = c.mediaId.flatMap({ mediaAsset($0) }) else { return false }
        return m.hasAudio && !m.isImage
    }

    /// Moves the start or end of a clip's sound by `delta` timeline seconds (positive is later), leaving its picture.
    /// When that edge meets a touching clip with sound on the same track, the cut between the two sounds rolls:
    /// the neighbour's sound shortens or lengthens by the same amount, so the two never play over each other.
    /// The new sound edge lands on the frame grid unless `subframe`.
    @discardableResult
    public mutating func trimAudio(_ id: String, edge: ClipEdge, delta: Seconds, subframe: Bool = false) throws -> String {
        guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
        guard abs(delta) > eps else { return "No change" }
        let clips = tracks[loc.track].clips
        let c = clips[loc.clip]
        guard hasSound(c) else { throw EditError("\(id) has no sound") }
        let neighbour: Clip? = edge == .start
            ? (loc.clip > 0 ? clips[loc.clip - 1] : nil).flatMap { abs($0.end - c.start) < 1e-3 ? $0 : nil }
            : (loc.clip + 1 < clips.count ? clips[loc.clip + 1] : nil).flatMap { abs($0.start - c.end) < 1e-3 ? $0 : nil }
        if let n = neighbour, hasSound(n) {
            let requested = edge == .start ? c.audioLead - delta : -(c.audioLag + delta)
            let applied = edge == .start
                ? try splitEdit(left: n.id, right: id, offset: requested, subframe: subframe)
                : try splitEdit(left: id, right: n.id, offset: requested, subframe: subframe)
            let note = snapNote(requested, applied)
            let u = clip(id)!, o = clip(n.id)!
            let cut = edge == .start ? u.audioRange.start : u.audioRange.end
            let (out, inc) = edge == .start ? (o, u) : (u, o)
            return "Rolled the sound cut between \(out.id) and \(inc.id) to \(fmt2(cut))s: \(out.id)'s sound ends and \(inc.id)'s begins there (pictures cut at \(fmt2(inc.start))s)" + note
        }
        var u = c
        let requested = edge == .start ? c.audioLead - delta : c.audioLag + delta
        let applied = subframe ? requested : canvas.snap(requested)
        if edge == .start { u.audioLead = applied } else { u.audioLag = applied }
        guard abs(applied - (edge == .start ? c.audioLead : c.audioLag)) > eps else { return "No change: \(fmt(abs(delta)))s is under half a frame" + snapNote(requested, applied) }
        guard u.audioRange.duration > 0.05 else { throw EditError("That would leave \(id) with no sound") }
        try checkClipFits(u, track: tracks[loc.track])
        tracks[loc.track].clips[loc.clip] = u
        return "\(id)'s sound now runs \(fmt2(u.audioRange.start))–\(fmt2(u.audioRange.end)) (picture \(fmt2(u.start))–\(fmt2(u.end)))" + snapNote(requested, applied)
    }

    /// Butt-joined pieces filling `range` from the room-tone span `source`. Each piece reads a different part of the
    /// span (a golden-ratio walk over the slack) so the loop isn't heard, and keeps `crossfade / 2` of source on each
    /// side so neighbouring pieces can overlap their sound by `crossfade`.
    public func roomTonePieces(range: TimeRange, source: TimeRange, crossfade: Seconds) throws -> [SoundPiece] {
        let x = max(0, crossfade)
        let usable = source.duration - x
        guard usable >= max(2 * x, 0.2) else {
            throw EditError("The room-tone span is \(fmt2(source.duration))s; it needs at least \(fmt2(max(3 * x, 0.2 + x)))s for a \(fmt2(x))s crossfade")
        }
        guard range.duration >= canvas.frameDuration - eps else { return [] }
        let piece = usable >= 1.5 ? usable * 0.6 : usable
        let n = max(1, Int((range.duration / piece - 1e-9).rounded(.up)))
        var bounds = (0...n).map { canvas.snap(range.start + range.duration * Double($0) / Double(n)) }
        bounds[0] = range.start
        bounds[n] = range.end
        var out: [SoundPiece] = []
        for i in 0..<n where bounds[i + 1] - bounds[i] > eps {
            let d = bounds[i + 1] - bounds[i]
            let slack = max(0, usable - d)
            let walk = (0.37 + Double(i) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
            out.append(SoundPiece(start: bounds[i], duration: d, sourceIn: source.start + x / 2 + walk * slack))
        }
        return out
    }

    /// The crossfade room tone uses for `range`: `crossfade`, shortened to half the range so short gaps get short fades.
    /// With `fps`, half the crossfade (each piece's sound overlap) is a whole number of frames, unless that half is
    /// under a frame (gaps that short keep their sample-accurate declick).
    public static func roomToneCrossfade(_ crossfade: Seconds, range: TimeRange, fps: Double? = nil) -> Seconds {
        let x = min(max(0, crossfade), range.duration / 2)
        guard let fps, fps > 0, x / 2 * fps >= 1 - 1e-9 else { return x }
        var frames = (x / 2 * fps).rounded()
        if 2 * frames / fps > range.duration / 2 + 1e-9 { frames = (x / 2 * fps + 1e-9).rounded(.down) }
        return 2 * frames / fps
    }

    /// Fills a timeline range with room tone on `trackId`: clips of `mediaId` from the quiet `source` span, crossfaded
    /// into each other and into whatever sound meets the range's edges, with role dialogue.room tone. The crossfade shrinks to fit short ranges
    /// (see `roomToneCrossfade`), and no fade runs longer than its clip. Returns the new clip ids.
    @discardableResult
    public mutating func fillRoomTone(_ range: TimeRange, mediaId: String, source: TimeRange, trackId: String, crossfade: Seconds = 0.25) throws -> [String] {
        guard let m = mediaAsset(mediaId) else { throw EditError("No media \(mediaId)") }
        guard m.hasAudio, !m.isImage else { throw EditError("\(mediaId) has no sound") }
        guard source.start >= -eps, source.end <= m.duration + eps, source.duration > 0 else {
            throw EditError("The room-tone span \(fmt2(source.start))–\(fmt2(source.end))s isn't inside \(mediaId) (0–\(fmt2(m.duration))s)")
        }
        let x = Project.roomToneCrossfade(crossfade, range: range, fps: canvas.fps)
        var ids: [String] = []
        for piece in try roomTonePieces(range: range, source: source, crossfade: x) {
            var c = Clip(id: Project.newClipId(), kind: .media, name: "Room tone", mediaId: mediaId, start: piece.start, duration: piece.duration, sourceIn: piece.sourceIn)
            c.role = Project.roomToneRole
            c.audioLead = min(x / 2, piece.start)
            c.audioLag = x / 2
            c.audioFadeIn = c.audioLead + x / 2
            c.audioFadeOut = x
            let placed = try addClip(c, trackId: trackId, mode: .place)
            if let loc = locateClip(placed.id) {
                let d = placed.duration
                tracks[loc.track].clips[loc.clip].audioFadeIn = min(placed.audioFadeIn, d)
                tracks[loc.track].clips[loc.clip].audioFadeOut = min(placed.audioFadeOut, d)
            }
            ids.append(c.id)
        }
        return ids
    }

    /// Stretches between the first and last sound on a track where none of its clips is heard, at least `minGap` long.
    public func soundGaps(trackId: String, minGap: Seconds) throws -> [TimeRange] {
        guard let t = trackIndex(trackId) else { throw EditError("No track \(trackId)") }
        let heard = tracks[t].clips.filter { hasSound($0) && ($0.volume > 0 || $0.anim["audio.volume"] != nil) }.map(\.audioRange)
        let merged = TimeRange.merged(heard)
        return zip(merged, merged.dropFirst()).map { TimeRange($0.end, $1.start) }.filter { $0.duration >= max(minGap, eps) }
    }

    /// Pieces that repeat `source` end to end from `start` for `duration` timeline seconds; the last one is cut short.
    public func loopPieces(start: Seconds, duration: Seconds, source: TimeRange, speed: Double = 1) throws -> [SoundPiece] {
        let length = source.duration / speed
        guard length >= canvas.frameDuration else { throw EditError("The source range to loop is shorter than a frame") }
        let n = max(1, Int((duration / length - 1e-6).rounded(.up)))
        guard n <= 2_000 else { throw EditError("That would take \(n) repeats; loop a longer source range") }
        var out: [SoundPiece] = []
        for i in 0..<n {
            let s = canvas.snap(start + Double(i) * length)
            let e = i == n - 1 ? canvas.snap(start + duration) : canvas.snap(start + Double(i + 1) * length)
            if e - s >= canvas.frameDuration - eps { out.append(SoundPiece(start: s, duration: e - s, sourceIn: source.start)) }
        }
        return out
    }
}

extension Clip {
    /// A note when retiming changes how a clip's sound plays: slowed or sped past ±10%.
    public static func retimeWarning(speed: Double, hasAudio: Bool) -> String? {
        guard hasAudio, speed < 0.9 || speed > 1.1 else { return nil }
        return "Warning: audio \(speed < 1 ? "slowed" : "sped up") to \(fmt2(speed))×; use loop:true for room tone or ambience, or speed changes with time.interpolate for picture"
    }

    /// Refuses extreme slow-downs of sound-only media unless `allow`.
    public static func checkAudioStretch(speed: Double, media: MediaAsset, allow: Bool) throws {
        guard !allow, media.hasAudio, !media.hasVideo, !media.isImage, speed < 0.25 else { return }
        throw EditError("That would slow \(media.id)'s sound to \(fmt2(speed))×. To fill time with ambience or room tone pass loop:true (or use recipe room_tone); pass allow_stretch:true to stretch anyway")
    }
}
