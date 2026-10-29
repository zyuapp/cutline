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
        let (left, right) = Project.split(clip, at: t)
        tracks[loc.track].clips.replaceSubrange(loc.clip...loc.clip, with: [left, right])
        for i in transitions.indices where transitions[i].from == id { transitions[i].from = right.id }
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

    /// Removes clips. With `ripple`, later clips on the same track close the gap.
    public mutating func deleteClips(_ ids: [String], ripple: Bool) throws {
        for id in ids where locateClip(id) == nil { throw EditError("No clip \(id)") }
        let doomed = ids.compactMap { clip($0) }.sorted { $0.start > $1.start }
        for clip in doomed {
            guard let loc = locateClip(clip.id) else { continue }
            tracks[loc.track].clips.remove(at: loc.clip)
            if ripple {
                for i in tracks[loc.track].clips.indices where tracks[loc.track].clips[i].start >= clip.end - eps {
                    tracks[loc.track].clips[i].start = canvas.snap(tracks[loc.track].clips[i].start - clip.duration)
                }
            }
        }
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
            guard clip.sourceIn >= -eps, clip.sourceIn + clip.duration <= seq.duration + canvas.frameDuration else {
                throw EditError("\(clip.id) plays \(fmt(clip.sourceIn))–\(fmt(clip.sourceIn + clip.duration))s of \(seq.name), which is \(fmt(seq.duration))s long")
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
            if keepsLeft {
                var left = Project.trimmedRight(c, to: r.start)
                if keepsRight { left.fadeOut = 0; left.audioFadeOut = 0 }
                out.append(left)
            }
            if keepsRight {
                var right = Project.trimmedLeft(c, to: r.end)
                if keepsLeft { right.id = Project.newClipId(); right.fadeIn = 0; right.audioFadeIn = 0 }
                out.append(right)
            }
        }
        tracks[t].clips = out.sorted { $0.start < $1.start }
    }

    mutating func rippleInsert(at time: Seconds, duration: Seconds, splitTrack: Int) {
        if let c = tracks[splitTrack].clips.first(where: { time > $0.start + eps && time < $0.end - eps }) {
            _ = try? splitClip(c.id, at: time)
        }
        for t in tracks.indices {
            for i in tracks[t].clips.indices where tracks[t].clips[i].start >= time - eps {
                tracks[t].clips[i].start = canvas.snap(tracks[t].clips[i].start + duration)
            }
        }
        for i in markers.indices where markers[i].time >= time { markers[i].time += duration }
    }

    static func split(_ c: Clip, at t: Seconds) -> (Clip, Clip) {
        var left = trimmedRight(c, to: t)
        left.fadeOut = 0
        left.audioFadeOut = 0
        left.audioLag = 0
        var right = trimmedLeft(c, to: t)
        right.id = newClipId()
        right.fadeIn = 0
        right.audioFadeIn = 0
        right.audioLead = 0
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

public func fmt(_ t: Seconds) -> String {
    String(format: "%.3f", t)
}
