import Foundation

public struct EditError: LocalizedError, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum PlaceMode: String, Codable, Sendable, CaseIterable {
    /// After the last clip on the track.
    case append
    /// Exactly at the start; fails if something is already there.
    case place
    /// Replaces whatever is under the new clip on that track.
    case overwrite
    /// Pushes everything at or after the start later on every track.
    case insert
}

public struct SourceSegment: Equatable, Sendable {
    public var mediaId: String
    public var sourceIn: Seconds
    public var sourceOut: Seconds

    public init(mediaId: String, sourceIn: Seconds, sourceOut: Seconds) {
        self.mediaId = mediaId
        self.sourceIn = sourceIn
        self.sourceOut = sourceOut
    }

    /// `padded` (each of `requested` with its handles) with no source frame played twice: where a segment's handles
    /// reach into the next one of the same media in playback order (contiguous or overlapping takes), the two share
    /// one edit, at the middle of the gap between the requested ranges (the first's requested end when they overlap),
    /// on whole frames of `fps`. A segment that lies inside the one before it is left alone.
    public static func butted(_ padded: [SourceSegment], requested: [SourceSegment], fps: Double) -> [SourceSegment] {
        guard padded.count == requested.count, padded.count > 1 else { return padded }
        var out = padded
        let frame = fps > 0 ? 1 / fps : 0
        for i in 1..<out.count {
            let a = requested[i - 1], b = requested[i]
            guard a.mediaId == b.mediaId, b.sourceIn >= a.sourceIn - 1e-9, b.sourceOut > a.sourceOut + 1e-9,
                  out[i].sourceIn < out[i - 1].sourceOut - 1e-9 else { continue }
            var edit = b.sourceIn >= a.sourceOut ? (a.sourceOut + b.sourceIn) / 2 : a.sourceOut
            if frame > 0 { edit = out[i - 1].sourceIn + ((edit - out[i - 1].sourceIn) / frame).rounded() * frame }
            edit = min(max(edit, out[i - 1].sourceIn + frame), out[i].sourceOut - frame)
            let length = out[i].sourceOut - edit
            out[i - 1].sourceOut = edit
            out[i].sourceIn = edit
            if frame > 0 { out[i].sourceOut = edit + max(1, (length / frame - 1e-6).rounded(.up)) * frame }
        }
        return out
    }

    /// The segment with handles around the words it plays (those whose middle is inside it): it starts at least
    /// `before` ahead of the first word and ends at least `after` past the last, never reaching into the words either
    /// side or outside `0...duration`, and lasts whole frames of `fps`, rounded out so the last word is never cut.
    public func withHandles(_ t: Transcript, before: Seconds, after: Seconds, fps: Double, duration: Seconds) -> SourceSegment {
        let words = t.words
        guard let first = words.firstIndex(where: { ($0.start + $0.end) / 2 >= sourceIn && ($0.start + $0.end) / 2 < sourceOut }),
              let last = words.lastIndex(where: { ($0.start + $0.end) / 2 >= sourceIn && ($0.start + $0.end) / 2 < sourceOut }) else { return self }
        let floor = first > 0 ? words[first - 1].end : 0
        let ceiling = last + 1 < words.count ? words[last + 1].start : duration
        var s = self
        s.sourceIn = max(0, min(sourceIn, max(floor, words[first].start - before)))
        s.sourceOut = max(sourceOut, words[last].end, min(ceiling, words[last].end + after))
        guard fps > 0 else { return s }
        let frame = 1 / fps
        var frames = ((s.sourceOut - s.sourceIn) * fps - 1e-6).rounded(.up)
        if s.sourceIn + frames * frame > min(ceiling, duration) + 1e-6 {
            // Rounding out would reach the next word or past the media: the fewest frames that still hold the last word.
            frames = max(((words[last].end - s.sourceIn) * fps - 1e-6).rounded(.up), ((min(ceiling, duration) - s.sourceIn) * fps + 1e-6).rounded(.down))
        }
        s.sourceOut = s.sourceIn + max(1, frames) * frame
        return s
    }
}

extension Transcript {
    /// Gaps of at least `minimum` between spoken words, in source time; `skippingFillers` reads across filler words,
    /// so a pause broken by an "um" is one pause. Sound under a gap (music, ambience) doesn't hide it.
    public func pauses(atLeast minimum: Seconds, skippingFillers: Bool = false) -> [TimeRange] {
        let spoken = words.filter { !(skippingFillers && $0.isFiller) }
        return zip(spoken, spoken.dropFirst()).compactMap { a, b in b.start - a.end >= minimum ? TimeRange(a.end, b.start) : nil }
    }
}

let eps: Seconds = 1e-6

extension Project {
    // MARK: Tracks

    @discardableResult
    public mutating func addTrack(kind: TrackKind, name: String? = nil, index: Int? = nil) -> Track {
        let prefix = kind == .video ? "V" : "A"
        var n = 1
        while tracks.contains(where: { $0.id == "\(prefix)\(n)" }) { n += 1 }
        let track = Track(id: "\(prefix)\(n)", kind: kind, name: name ?? (kind == .video ? "Video \(n)" : "Audio \(n)"))
        let i = min(max(index ?? tracks.count, 0), tracks.count)
        tracks.insert(track, at: i)
        return track
    }

    public mutating func removeTrack(_ id: String) throws {
        guard let i = trackIndex(id) else { throw EditError("No track \(id)") }
        tracks.remove(at: i)
    }

    // MARK: Clips

    public static func newClipId() -> String { IDs.make("clip") }

    /// Places a clip on a track. Start and duration snap to the canvas frame grid.
    @discardableResult
    public mutating func addClip(_ clip: Clip, trackId: String, mode: PlaceMode) throws -> Clip {
        guard let t = trackIndex(trackId) else { throw EditError("No track \(trackId)") }
        var clip = clip
        if mode == .append { clip.start = tracks[t].end }
        clip.start = canvas.snap(max(0, clip.start))
        clip.duration = canvas.snap(clip.duration)
        guard clip.duration >= canvas.frameDuration - eps else { throw EditError("Clip is shorter than one frame") }
        try checkClipFits(clip, track: tracks[t])
        let range = TimeRange(clip.start, clip.end)
        switch mode {
        case .append, .place: break
        case .overwrite: clearRange(trackIndex: t, range)
        case .insert: rippleInsert(at: clip.start, duration: clip.duration, splitTrack: t)
        }
        if let blocker = tracks[t].clips.first(where: { $0.start < range.end - eps && $0.end > range.start + eps }) {
            throw EditError("Clip overlaps \(blocker.id) on \(trackId) (\(fmt(blocker.start))–\(fmt(blocker.end))). Use mode overwrite or insert, or another track.")
        }
        tracks[t].clips.append(clip)
        tracks[t].clips.sort { $0.start < $1.start }
        return clip
    }

    /// Replaces a clip with an edited version of itself. With `ripple`, later clips on its
    /// track move by the change in its end time.
    public mutating func replaceClip(_ clip: Clip, ripple: Bool = false) throws {
        guard let loc = locateClip(clip.id) else { throw EditError("No clip \(clip.id)") }
        var clip = clip
        clip.start = canvas.snap(max(0, clip.start))
        clip.duration = canvas.snap(clip.duration)
        guard clip.duration >= canvas.frameDuration - eps else { throw EditError("Clip would be shorter than one frame") }
        let old = tracks[loc.track].clips[loc.clip]
        try checkClipFits(clip, track: tracks[loc.track])
        var clips = tracks[loc.track].clips
        clips.remove(at: loc.clip)
        if ripple {
            let delta = clip.end - old.end
            for i in clips.indices where clips[i].start >= old.end - eps {
                clips[i].start = canvas.snap(clips[i].start + delta)
            }
        }
        if let blocker = clips.first(where: { $0.start < clip.end - eps && $0.end > clip.start + eps }) {
            throw EditError("\(clip.id) would overlap \(blocker.id) (\(fmt(blocker.start))–\(fmt(blocker.end))). Pass ripple true, or move/trim the neighbor first.")
        }
        clips.append(clip)
        clips.sort { $0.start < $1.start }
        tracks[loc.track].clips = clips
    }

    /// Other clips linked to this one.
    public func linked(_ id: String) -> [String] {
        guard let link = clip(id)?.link else { return [] }
        return tracks.flatMap(\.clips).filter { $0.link == link && $0.id != id }.map(\.id)
    }

    /// Moves a clip and, by the same amount, the clips linked to it.
    public mutating func moveLinked(_ id: String, start: Seconds, trackId: String? = nil) throws {
        guard let old = clip(id) else { throw EditError("No clip \(id)") }
        let delta = start - old.start
        try moveClip(id, start: start, trackId: trackId)
        for other in linked(id) {
            guard let c = clip(other) else { continue }
            try moveClip(other, start: c.start + delta)
        }
    }

    public mutating func moveClip(_ id: String, start: Seconds, trackId: String? = nil) throws {
        guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
        var clip = tracks[loc.track].clips[loc.clip]
        let target = trackId ?? tracks[loc.track].id
        guard let t = trackIndex(target) else { throw EditError("No track \(target)") }
        if t == loc.track {
            clip.start = start
            try replaceClip(clip)
            return
        }
        let backup = tracks
        tracks[loc.track].clips.remove(at: loc.clip)
        clip.start = start
        do {
            try addClip(clip, trackId: target, mode: .overwrite)
        } catch {
            tracks = backup
            throw error
        }
    }

    /// Splits a clip at a timeline time. Returns the ids of the two halves.
    @discardableResult
    public mutating func splitClip(_ id: String, at time: Seconds) throws -> (String, String) {
        guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
        let t = canvas.snap(time)
        let clip = tracks[loc.track].clips[loc.clip]
        guard t > clip.start + eps, t < clip.end - eps else {
            throw EditError("Split time \(fmt(t)) is outside \(id) (\(fmt(clip.start))–\(fmt(clip.end)))")
        }
        var (left, right) = Project.split(clip, at: t)
        let partners = clip.link == nil ? [] : linked(id)
        if clip.link != nil { right.link = IDs.make("lnk") }
        tracks[loc.track].clips.replaceSubrange(loc.clip...loc.clip, with: [left, right])
        for i in transitions.indices where transitions[i].from == id { transitions[i].from = right.id }
        for other in partners {
            guard let o = locateClip(other) else { continue }
            let c = tracks[o.track].clips[o.clip]
            guard t > c.start + eps, t < c.end - eps else { continue }
            var (l, r) = Project.split(c, at: t)
            r.link = right.link
            tracks[o.track].clips.replaceSubrange(o.clip...o.clip, with: [l, r])
            for i in transitions.indices where transitions[i].from == other { transitions[i].from = r.id }
        }
        return (left.id, right.id)
    }

    /// Splits every clip that spans `time` on the given tracks (all when nil).
    @discardableResult
    public mutating func splitAll(at time: Seconds, trackIds: [String]? = nil) -> [String] {
        let t = canvas.snap(time)
        var created: [String] = []
        for i in tracks.indices where trackIds == nil || trackIds!.contains(tracks[i].id) {
            if let c = tracks[i].clips.first(where: { t > $0.start + eps && t < $0.end - eps }),
               let ids = try? splitClip(c.id, at: t) {
                created.append(ids.1)
            }
        }
        return created
    }

    /// Removes clips. With `ripple`, later clips on the same track close the gap. A neighbour's split edit made of its
    /// own sound (an L cut running under a deleted clip, a J cut starting under one) is kept: into the gap, or with
    /// `ripple` against the clip that now touches it, whose sound yields. Sound that stopped short only for a deleted
    /// clip plays to its picture edge again. Returns how surviving clips' sound edges moved.
    @discardableResult
    public mutating func deleteClips(_ ids: [String], ripple: Bool) throws -> [String] {
        for id in ids where locateClip(id) == nil { throw EditError("No clip \(id)") }
        let ids = Array(Set(ids + ids.flatMap { linked($0) }))
        let doomed = ids.compactMap { clip($0) }.sorted { $0.start > $1.start }
        let before = Dictionary(tracks.flatMap(\.clips).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for clip in doomed {
            guard let loc = locateClip(clip.id) else { continue }
            let t = loc.track
            tracks[t].clips.remove(at: loc.clip)
            isolateSound(trackIndex: t, around: TimeRange(clip.start, clip.end), keepingOwnSound: true)
            if ripple {
                for i in tracks[t].clips.indices where tracks[t].clips[i].start >= clip.end - eps {
                    tracks[t].clips[i].start = canvas.snap(tracks[t].clips[i].start - clip.duration)
                }
                rejoinSound(trackIndex: t, at: clip.start)
            }
        }
        var notes: [String] = []
        for c in tracks.flatMap(\.clips) {
            guard let o = before[c.id], hasSound(c) else { continue }
            if abs(o.audioLead - c.audioLead) > eps { notes.append("\(c.id) sound start: \(Self.soundEdge(o.audioLead, lead: true)) → \(Self.soundEdge(c.audioLead, lead: true))") }
            if abs(o.audioLag - c.audioLag) > eps { notes.append("\(c.id) sound end: \(Self.soundEdge(o.audioLag, lead: false)) → \(Self.soundEdge(c.audioLag, lead: false))") }
        }
        return notes
    }

    static func soundEdge(_ x: Seconds, lead: Bool) -> String {
        if abs(x) < eps { return "at the picture cut" }
        if lead { return x > 0 ? "\(fmt2(x))s before its picture (J cut)" : "\(fmt2(-x))s after its picture starts" }
        return x > 0 ? "\(fmt2(x))s past its picture (L cut)" : "\(fmt2(-x))s before its picture ends"
    }

    /// After a ripple closed a gap at `time` on track `t`: a split edit the clip ending or starting there brought keeps
    /// its length against the clip now touching it, whose sound yields, so the two sounds don't play over each other.
    mutating func rejoinSound(trackIndex t: Int, at time: Seconds) {
        let tol = canvas.frameDuration / 2
        let clips = tracks[t].clips
        guard let a = clips.first(where: { abs($0.end - time) < tol && hasSound($0) }),
              let b = clips.first(where: { abs($0.start - time) < tol && hasSound($0) }) else { return }
        let offset = a.audioLag > eps ? -a.audioLag : b.audioLead > eps ? b.audioLead : 0
        guard offset != 0 else { return }
        if (try? splitEdit(left: a.id, right: b.id, offset: offset, subframe: true)) != nil { return }
        guard let l = locateClip(a.id), let r = locateClip(b.id) else { return }
        tracks[t].clips[l.clip].limitSound(to: b.start)
        tracks[t].clips[r.clip].limitSound(from: b.start)
    }

    /// Removes a timeline range from the given tracks (all when nil). With `ripple`,
    /// everything after the range moves earlier, keeping the tracks in sync.
    public mutating func deleteRange(_ range: TimeRange, trackIds: [String]? = nil, ripple: Bool) {
        let r = TimeRange(canvas.snap(range.start), canvas.snap(range.end))
        guard r.duration > eps else { return }
        let scope = tracks.indices.filter { trackIds == nil || trackIds!.contains(tracks[$0].id) }
        for t in scope {
            clearRange(trackIndex: t, r)
            if ripple {
                for i in tracks[t].clips.indices where tracks[t].clips[i].start >= r.end - eps {
                    tracks[t].clips[i].start = canvas.snap(tracks[t].clips[i].start - r.duration)
                }
            }
        }
        if ripple && trackIds == nil {
            markers.removeAll { $0.time >= r.start && $0.time < r.end }
            for i in markers.indices where markers[i].time >= r.end { markers[i].time -= r.duration }
        }
    }

    /// Timeline ranges where the given source ranges of a media file play.
    public func timelineRanges(mediaId: String, sourceRanges: [TimeRange], trackIds: [String]? = nil) -> [TimeRange] {
        var out: [TimeRange] = []
        for track in tracks where trackIds == nil || trackIds!.contains(track.id) {
            for clip in track.clips where clip.kind == .media && clip.mediaId == mediaId {
                let src = TimeRange(clip.sourceIn, clip.sourceOut)
                for r in sourceRanges {
                    guard let hit = src.intersection(r) else { continue }
                    out.append(TimeRange(clip.timelineTime(atSource: hit.start), clip.timelineTime(atSource: hit.end)))
                }
            }
        }
        return TimeRange.merged(out)
    }

    /// Cuts the given source ranges of a media file out of the timeline wherever they play,
    /// rippling every track. Returns the removed timeline ranges in the pre-edit timeline.
    @discardableResult
    public mutating func cutSourceRanges(mediaId: String, ranges: [TimeRange], trackIds: [String]? = nil) -> [TimeRange] {
        let hits = timelineRanges(mediaId: mediaId, sourceRanges: ranges, trackIds: trackIds)
            .map { TimeRange(canvas.snap($0.start), canvas.snap($0.end)) }
            .filter { $0.duration >= canvas.frameDuration - eps }
        for r in hits.reversed() { deleteRange(r, ripple: true) }
        return hits
    }

    /// Lays source segments end to end on a track, starting at `at` (or the track end).
    @discardableResult
    public mutating func assemble(_ segments: [SourceSegment], trackId: String, at: Seconds? = nil, replaceTrack: Bool = false) throws -> [Clip] {
        guard let t = trackIndex(trackId) else { throw EditError("No track \(trackId)") }
        let backup = tracks
        if replaceTrack { tracks[t].clips.removeAll() }
        var cursor = at ?? tracks[t].end
        var made: [Clip] = []
        do {
            for seg in segments {
                guard let media = mediaAsset(seg.mediaId) else { throw EditError("No media \(seg.mediaId)") }
                guard seg.sourceOut > seg.sourceIn else { throw EditError("Segment \(fmt(seg.sourceIn))–\(fmt(seg.sourceOut)) of \(seg.mediaId) is empty") }
                let clip = Clip(id: Project.newClipId(), kind: .media, name: media.name, mediaId: media.id, start: cursor, duration: seg.sourceOut - seg.sourceIn, sourceIn: seg.sourceIn)
                let placed = try addClip(clip, trackId: trackId, mode: .overwrite)
                made.append(placed)
                cursor = placed.end
            }
        } catch {
            tracks = backup
            throw error
        }
        return made
    }

    // MARK: Validation

    public func validate() throws {
        for track in tracks {
            for (a, b) in zip(track.clips, track.clips.dropFirst()) where b.start < a.end - eps {
                throw EditError("\(a.id) and \(b.id) overlap on \(track.id)")
            }
            for clip in track.clips { try checkClipFits(clip, track: track) }
        }
        try validateRouting()
    }

    func checkClipFits(_ clip: Clip, track: Track) throws {
        guard clip.duration > 0 else { throw EditError("\(clip.id) has no duration") }
        guard clip.speed > 0.01, clip.speed <= 100 else { throw EditError("Speed must be between 0.01 and 100") }
        switch clip.kind {
        case .media:
            guard let id = clip.mediaId, let media = mediaAsset(id) else { throw EditError("\(clip.id) references unknown media \(clip.mediaId ?? "nil")") }
            if !media.isImage {
                guard clip.sourceIn >= -eps else { throw EditError("\(clip.id) starts before the beginning of \(media.id)") }
                guard clip.sourceOut <= media.duration + 1 / max(media.fps, 24) else {
                    throw EditError("\(clip.id) needs source up to \(fmt(clip.sourceOut))s but \(media.id) is \(fmt(media.duration))s long")
                }
            }
            if track.kind == .audio && !media.hasAudio { throw EditError("\(media.id) has no audio for audio track \(track.id)") }
            if clip.raw != nil && media.raw == nil { throw EditError("raw.* parameters develop camera RAW media; \(media.id) isn't RAW (use input.exposure or color effects)") }
            if let why = clip.channels?.problem(count: media.sourceChannelCount) { throw EditError("\(clip.id) audio.channels \(clip.channels!.rawValue): \(why)") }
            if (clip.audioLead != 0 || clip.audioLag != 0) && !media.isImage {
                let heard = clip.audioSourceRange
                if heard.start < -1e-3 { throw EditError("\(clip.id)'s audio would start \(fmt(-heard.start))s before the beginning of \(media.id); reduce audio.lead") }
                if heard.end > media.duration + 1e-3 { throw EditError("\(clip.id)'s audio would run \(fmt(heard.end - media.duration))s past the end of \(media.id); reduce audio.lag") }
            }
        case .text, .solid, .adjustment, .generator:
            guard track.kind == .video else { throw EditError("\(clip.kind.rawValue) clips go on video tracks") }
            if clip.kind == .text && clip.text == nil { throw EditError("Text clip \(clip.id) has no text") }
            if clip.kind == .generator && !clip.effects.contains(where: { GeneratorCatalog.type($0.type) != nil }) { throw EditError("Generator clip \(clip.id) has no generator") }
        case .sequence:
            guard let seq = clip.mediaId.flatMap({ sequence($0) }) else { throw EditError("\(clip.id) references unknown sequence \(clip.mediaId ?? "nil")") }
            let window = Project.sequenceWindow(clip)
            guard clip.sourceIn >= -eps, window.end <= seq.duration + canvas.frameDuration else {
                throw EditError("\(clip.id) plays \(fmt(clip.sourceIn))–\(fmt(window.end))s of \(seq.name), which is \(fmt(seq.duration))s long")
            }
        }
    }

    // MARK: Primitives

    mutating func clearRange(trackIndex t: Int, _ r: TimeRange) {
        var out: [Clip] = []
        for c in tracks[t].clips {
            if c.end <= r.start + eps || c.start >= r.end - eps {
                out.append(c)
                continue
            }
            let keepsLeft = c.start < r.start - eps
            let keepsRight = c.end > r.end + eps
            let heard = c.audioRange
            if keepsLeft {
                var left = Project.trimmedRight(c, to: r.start)
                left.audioLag = heard.end - left.end
                left.limitSound(to: r.start)
                if keepsRight { left.fadeOut = 0; left.audioFadeOut = 0 }
                out.append(left)
            }
            if keepsRight {
                var right = Project.trimmedLeft(c, to: r.end)
                right.audioLead = right.start - heard.start
                right.limitSound(from: r.end)
                if keepsLeft { right.id = Project.newClipId(); right.fadeIn = 0; right.audioFadeIn = 0 }
                out.append(right)
            }
        }
        tracks[t].clips = out.sorted { $0.start < $1.start }
        isolateSound(trackIndex: t, around: r)
    }

    /// After `r` was emptied on track `t` (or opened, for an insert): sound of clips before `r` stops by its start and
    /// sound of clips after it starts at its end, so nothing is heard inside it. A clip touching `r` whose sound stopped
    /// short of its picture edge for a split edit with a clip that is now gone plays to that edge again, unless another
    /// clip's sound still covers it.
    /// `keepingOwnSound` leaves the sound clips beside `r` play into it, for a deleted clip whose place is now a gap.
    mutating func isolateSound(trackIndex t: Int, around r: TimeRange, keepingOwnSound: Bool = false) {
        let tol = canvas.frameDuration / 2
        var clips = tracks[t].clips
        for i in clips.indices where hasSound(clips[i]) && !keepingOwnSound {
            if clips[i].end <= r.start + eps {
                clips[i].limitSound(to: r.start)
            } else if clips[i].start >= r.end - eps {
                clips[i].limitSound(from: r.end)
            }
        }
        func covered(_ span: TimeRange, except i: Int) -> Bool {
            clips.indices.contains { j in
                j != i && hasSound(clips[j]) && (clips[j].audioRange.intersection(span).map { $0.duration > eps } ?? false)
            }
        }
        for i in clips.indices where hasSound(clips[i]) {
            let c = clips[i], heard = c.audioRange
            if abs(c.end - r.start) < tol, heard.end < c.end - eps, heard.end > c.start, !covered(TimeRange(heard.end, c.end), except: i) {
                clips[i].audioLag = 0
            }
            if abs(c.start - r.end) < tol, heard.start > c.start + eps, heard.start < c.end, !covered(TimeRange(c.start, heard.start), except: i) {
                clips[i].audioLead = 0
            }
        }
        tracks[t].clips = clips
    }

    mutating func rippleInsert(at time: Seconds, duration: Seconds, splitTrack: Int) {
        if let c = tracks[splitTrack].clips.first(where: { time > $0.start + eps && time < $0.end - eps }) {
            _ = try? splitClip(c.id, at: time)
        }
        for t in tracks.indices {
            isolateSound(trackIndex: t, around: TimeRange(time, time))
            for i in tracks[t].clips.indices where tracks[t].clips[i].start >= time - eps {
                tracks[t].clips[i].start = canvas.snap(tracks[t].clips[i].start + duration)
            }
        }
        for i in markers.indices where markers[i].time >= time { markers[i].time += duration }
    }

    /// Halves of a clip cut at `t`. Each half keeps only the sound the clip played on its side of `t`, so a cut inside
    /// a split edit's overlap doesn't play the neighbour's share twice.
    static func split(_ c: Clip, at t: Seconds) -> (Clip, Clip) {
        let heard = c.audioRange
        var left = trimmedRight(c, to: t)
        left.fadeOut = 0
        left.audioFadeOut = 0
        left.audioLag = heard.end - left.end
        left.limitSound(to: t)
        var right = trimmedLeft(c, to: t)
        right.id = newClipId()
        right.fadeIn = 0
        right.audioFadeIn = 0
        right.audioLead = right.start - heard.start
        right.limitSound(from: t)
        return (left, right)
    }

    static func trimmedLeft(_ c: Clip, to newStart: Seconds) -> Clip {
        var c = c
        let delta = newStart - c.start
        c.start = newStart
        c.duration -= delta
        if (c.kind == .media && !c.reverse) || c.kind == .sequence { c.sourceIn += c.sourceOffset(atLocal: delta) }
        c.anim = c.anim.mapValues { $0.shifted(by: -delta) }
        c.fadeIn = min(c.fadeIn, c.duration)
        c.audioFadeIn = min(c.audioFadeIn, c.duration)
        return c
    }

    static func trimmedRight(_ c: Clip, to newEnd: Seconds) -> Clip {
        var c = c
        if c.kind == .media && c.reverse { c.sourceIn += c.sourceOffset(atLocal: c.duration) - c.sourceOffset(atLocal: newEnd - c.start) }
        c.duration = newEnd - c.start
        c.fadeOut = min(c.fadeOut, c.duration)
        c.audioFadeOut = min(c.audioFadeOut, c.duration)
        return c
    }
}

extension Clip {
    /// Keeps the clip's sound inside `lo...hi` of the timeline, leaving its picture; no overlap leaves it silent.
    mutating func limitSound(from lo: Seconds = -.infinity, to hi: Seconds = .infinity) {
        let heard = audioRange
        guard heard.start < lo - eps || heard.end > hi + eps else { return }
        let s = max(heard.start, lo), e = min(heard.end, hi)
        if e <= s + eps {
            audioLead = 0
            audioLag = -duration
            return
        }
        if s > heard.start { audioLead = start - s }
        if e < heard.end { audioLag = e - end }
        if abs(audioLead) < 1e-9 { audioLead = 0 }
        if abs(audioLag) < 1e-9 { audioLag = 0 }
    }
}

public func fmt(_ t: Seconds) -> String {
    String(format: "%.3f", t)
}
