import Foundation

/// A timeline of the project that isn't the one being edited: its own tracks, transitions, markers,
/// captions, mix and frame (e.g. a 9:16 cutdown beside the 16:9 master).
public struct StoredTimeline: Codable, Equatable, Sendable {
    public var name: String
    public var canvas: Canvas
    public var tracks: [Track]
    public var transitions: [Transition]
    public var markers: [Marker]
    public var captions: Captions
    public var master: MasterAudio
    public var buses: [AudioBus]?
}

extension Project {
    public var currentTimelineName: String { timelineName ?? "Main" }

    public var timelineNames: [String] { [currentTimelineName] + timelines.map(\.name) }

    func stored(as name: String) -> StoredTimeline {
        StoredTimeline(name: name, canvas: canvas, tracks: tracks, transitions: transitions, markers: markers, captions: captions, master: master, buses: buses.isEmpty ? nil : buses)
    }

    mutating func load(_ t: StoredTimeline) {
        canvas = t.canvas
        tracks = t.tracks
        transitions = t.transitions
        markers = t.markers
        captions = t.captions
        master = t.master
        buses = t.buses ?? []
        timelineName = t.name
    }

    /// Adds a timeline and makes it the one being edited: a copy of the current one, or empty with the same frame.
    public mutating func newTimeline(_ name: String, duplicate: Bool) throws {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw EditError("Name the timeline") }
        guard !timelineNames.contains(name) else { throw EditError("There is already a timeline named \(name)") }
        timelines.append(stored(as: currentTimelineName))
        if !duplicate {
            tracks = [Track(id: "V1", kind: .video, name: "Main"), Track(id: "A1", kind: .audio, name: "Music")]
            transitions = []
            markers = []
            captions = Captions()
            master = MasterAudio()
            buses = []
            for i in tracks.indices { tracks[i].output = nil }
        }
        timelineName = name
    }

    /// Makes another timeline the one being edited; the current one is kept as it is.
    public mutating func switchTimeline(to name: String) throws {
        guard name != currentTimelineName else { return }
        guard let i = timelines.firstIndex(where: { $0.name == name }) else { throw EditError("No timeline \(name); timelines: \(timelineNames.joined(separator: ", "))") }
        let target = timelines.remove(at: i)
        timelines.insert(stored(as: currentTimelineName), at: i)
        load(target)
    }

    public mutating func renameTimeline(_ old: String, to new: String) throws {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, !timelineNames.contains(new) else { throw EditError("Pick a new, unused name") }
        if old == currentTimelineName { timelineName = new; return }
        guard let i = timelines.firstIndex(where: { $0.name == old }) else { throw EditError("No timeline \(old)") }
        timelines[i].name = new
    }

    public mutating func deleteTimeline(_ name: String) throws {
        guard name != currentTimelineName else { throw EditError("Switch to another timeline before deleting \(name)") }
        guard let i = timelines.firstIndex(where: { $0.name == name }) else { throw EditError("No timeline \(name)") }
        timelines.remove(at: i)
    }
}

extension Project {
    /// The project's media `m` (from an imported timeline) names: by file (its path or camera original against
    /// each one's path and original), then id and name, then reel and name, then file name.
    public func matchingMedia(_ m: MediaAsset) -> MediaAsset? {
        let paths = [m.path, m.conformPath].filter { !$0.isEmpty }
        if let same = media.first(where: { mine in paths.contains { Importer.samePath(mine, $0) } }) { return same }
        if let same = media.first(where: { $0.id == m.id && $0.name == m.name }) { return same }
        if let reel = m.reel, !reel.isEmpty, let same = media.first(where: { $0.reel == reel && $0.name == m.name }) { return same }
        let file = Importer.fileName(m.conformPath)
        guard !file.isEmpty, file.contains(".") else { return nil }
        let named = media.filter { Importer.fileName($0.conformPath) == file || Importer.fileName($0.path) == file }
        return named.count == 1 ? named[0] : nil
    }

    /// Replaces the media with `real`'s id by `real` (the same file, probed). When both carry a timecode and they
    /// differ, its clips move so they keep their source timecode; without one, `real` keeps the old timecode.
    public mutating func replaceMediaKeepingTimecode(_ real: MediaAsset) {
        guard let i = media.firstIndex(where: { $0.id == real.id }) else { return }
        var m = real
        let old = media[i]
        if m.timecodeStart == nil {
            m.timecodeStart = old.timecodeStart
            m.timecodeLabel = old.timecodeLabel
        } else if let a = old.timecodeStart, let b = m.timecodeStart, abs(a - b) > 1e-6 {
            func move(_ tracks: inout [Track]) {
                for t in tracks.indices {
                    for c in tracks[t].clips.indices where tracks[t].clips[c].kind == .media && tracks[t].clips[c].mediaId == m.id {
                        tracks[t].clips[c].sourceIn += a - b
                    }
                }
            }
            move(&tracks)
            for s in sequences.indices { move(&sequences[s].tracks) }
        }
        media[i] = m
    }

    /// Adds another project's timeline (an imported EDL, FCPXML, OTIO, XML or AAF) as a new timeline and makes it
    /// current. Its media are matched to this project's (`matchingMedia`) when the source range the timeline reads
    /// fits them: clips of matched media whose imported timecode differs from the project's move to keep their
    /// source timecode, and offline media whose timecode agrees grow to what the timeline reads. Media that
    /// conflict with offline media (another timecode or a longer range) are added as separate media. Nested
    /// sequences whose id is taken get a new one. Clips that still don't fit are trimmed to their source, moved off
    /// overlaps to a new track, or left out, each with a warning, so one bad clip never stops the import.
    @discardableResult
    public mutating func adoptTimeline(_ other: Project, name requested: String) throws -> (matched: Int, added: Int, warnings: [String], name: String) {
        let name = freeTimelineName(requested)
        var rename: [String: String] = [:]
        var shift: [String: Seconds] = [:]
        var matched = 0, added = 0
        var warnings: [String] = []
        let reads = other.sourceReads()
        func add(_ m: MediaAsset) -> String {
            var copy = m
            copy.id = uniqueMediaId(m.id)
            media.append(copy)
            added += 1
            return copy.id
        }
        for m in other.media {
            guard let first = matchingMedia(m) else {
                rename[m.id] = add(m)
                continue
            }
            // The match, then other media of the same file (separate copies made by earlier imports).
            let candidates = [first] + media.filter { $0.id != first.id && $0.name == first.name && $0.path == first.path }
            let need = reads[m.id]
            func tcShift(_ same: MediaAsset) -> Seconds {
                guard let a = m.timecodeStart, let b = same.timecodeStart, abs(a - b) > 1e-6 else { return 0 }
                return a - b
            }
            func fits(_ same: MediaAsset) -> Bool {
                guard !same.isImage, let need else { return true }
                let tol = 1 / max(same.fps, 24), s = tcShift(same)
                return need.start + s >= -tol && need.end + s <= same.duration + tol
            }
            var pick = candidates.first(where: fits)
            if pick == nil, let need, need.start > -1e-3,
               let grow = candidates.first(where: { !Importer.exists($0.path) && tcShift($0) == 0 }), let i = media.firstIndex(where: { $0.id == grow.id }) {
                media[i].duration = need.end
                pick = media[i]
            }
            if pick == nil, Importer.exists(first.path) { pick = first }
            if let same = pick {
                rename[m.id] = same.id
                let s = tcShift(same)
                if s != 0 { shift[m.id] = s }
                matched += 1
                continue
            }
            let id = add(m)
            rename[m.id] = id
            let theirs = m.timecodeString(fallback: other.canvas.fps).map { " from \($0)" } ?? ""
            let mine = first.timecodeString(fallback: canvas.fps).map { " from \($0)" } ?? ""
            warnings.append("\(m.name): this timeline reads \(fmt2(need?.start ?? 0))–\(fmt2(need?.end ?? 0))s of it\(theirs), outside the project's offline \(first.id) (\(fmt2(first.duration))s\(mine)); kept as separate media \(id)")
        }
        var renameSequence: [String: String] = [:]
        var usedSequenceIds = Set(sequences.map(\.id))
        for s in other.sequences where usedSequenceIds.contains(s.id) { renameSequence[s.id] = Importer.unique(s.id, &usedSequenceIds) }
        func remapMedia(_ tracks: [Track]) -> [Track] {
            tracks.map { t in
                var t = t
                for i in t.clips.indices where t.clips[i].kind == .media {
                    guard let id = t.clips[i].mediaId else { continue }
                    t.clips[i].mediaId = rename[id] ?? id
                    if let s = shift[id] { t.clips[i].sourceIn += s }
                }
                return t
            }
        }
        func remapSequences(_ tracks: [Track]) -> [Track] {
            tracks.map { t in
                var t = t
                for i in t.clips.indices where t.clips[i].kind == .sequence {
                    if let id = t.clips[i].mediaId, let new = renameSequence[id] { t.clips[i].mediaId = new }
                }
                return t
            }
        }
        var incoming: [NestedSequence] = []
        for s in other.sequences {
            var s = s
            s.tracks = remapMedia(s.tracks)
            if var setup = s.multicam {
                for k in setup.angles.indices {
                    setup.angles[k].offset += shift[setup.angles[k].mediaId] ?? 0
                    setup.angles[k].mediaId = rename[setup.angles[k].mediaId] ?? setup.angles[k].mediaId
                }
                s.multicam = setup
            }
            incoming.append(s)
        }
        // A sequence that is already here as it is keeps its id.
        for s in incoming where renameSequence[s.id] != nil {
            if let same = sequence(s.id), same.name == s.name, same.tracks == remapSequences(s.tracks), same.multicam == s.multicam { renameSequence[s.id] = nil }
        }
        var addedSequences = Set<String>()
        for var s in incoming {
            if renameSequence[s.id] == nil, sequence(s.id) != nil { continue }
            s.id = renameSequence[s.id] ?? s.id
            s.tracks = remapSequences(s.tracks)
            addedSequences.insert(s.id)
            sequences.append(s)
        }
        try newTimeline(name, duplicate: false)
        canvas = other.canvas
        tracks = remapSequences(remapMedia(other.tracks))
        transitions = other.transitions
        markers = other.markers
        captions = other.captions
        master = other.master
        for i in sequences.indices where addedSequences.contains(sequences[i].id) {
            var inner = inside(sequences[i])
            warnings += inner.repairAdopted(label: "In \(sequences[i].name): ")
            sequences[i].tracks = inner.tracks
            sequences[i].transitions = inner.transitions
        }
        warnings += repairAdopted(label: "")
        return (matched, added, Importer.condense(warnings), name)
    }

    func uniqueMediaId(_ base: String) -> String {
        var id = base, n = 2
        while media.contains(where: { $0.id == id }) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    /// The source range each media's clips read (split-edit sound included), on the timeline and in its sequences.
    func sourceReads() -> [String: TimeRange] {
        var out: [String: TimeRange] = [:]
        for c in (tracks + sequences.flatMap(\.tracks)).flatMap(\.clips) where c.kind == .media {
            guard let id = c.mediaId else { continue }
            let r = c.audioSourceRange
            let lo = min(c.sourceIn, c.sourceOut, r.start), hi = max(c.sourceIn, c.sourceOut, r.end)
            out[id] = out[id].map { TimeRange(min($0.start, lo), max($0.end, hi)) } ?? TimeRange(lo, hi)
        }
        return out
    }

    /// Makes an adopted timeline valid clip by clip: overlapping clips move to a new track of their kind, media
    /// clips reading past their source are trimmed to it, and clips that still don't fit are left out.
    mutating func repairAdopted(label: String) -> [String] {
        var warnings: [String] = []
        func problem(_ c: Clip, _ track: Track) -> String? {
            do { try checkClipFits(c, track: track); return nil } catch { return (error as? EditError)?.message ?? "\(error)" }
        }
        var t = 0
        while t < tracks.count {
            tracks[t].clips.sort { $0.start < $1.start }
            var kept: [Clip] = [], moved: [Clip] = []
            for c in tracks[t].clips {
                if let last = kept.last, c.start < last.end - eps { moved.append(c) } else { kept.append(c) }
            }
            if !moved.isEmpty {
                let kind = tracks[t].kind, prefix = kind == .video ? "V" : "A"
                var n = tracks.filter { $0.kind == kind }.count + 1
                while trackIndex("\(prefix)\(n)") != nil { n += 1 }
                warnings.append("\(label)\(moved.map { $0.name ?? $0.id }.prefix(3).joined(separator: ", "))\(moved.count > 3 ? ", …" : "") overlapped clips on \(tracks[t].id); moved to \(prefix)\(n)")
                tracks[t].clips = kept
                let lane = Track(id: "\(prefix)\(n)", kind: kind, name: kind == .video ? "Video \(n)" : "Audio \(n)", muted: tracks[t].muted, hidden: tracks[t].hidden, clips: moved)
                tracks.insert(lane, at: t + 1)
            }
            var dropped = Set<String>()
            for i in tracks[t].clips.indices {
                let track = tracks[t]
                var c = track.clips[i]
                guard let why = problem(c, track) else { continue }
                if c.kind == .media, let m = c.mediaId.flatMap(mediaAsset), !m.isImage, !c.reverse, !c.isRetimed, c.speed > 0 {
                    if c.sourceIn < 0 { c = Project.trimmedLeft(c, to: c.start - c.sourceIn / c.speed) }
                    if c.sourceOut > m.duration { c = Project.trimmedRight(c, to: c.start + (m.duration - c.sourceIn) / c.speed) }
                    c.audioLead = max(0, min(c.audioLead, c.sourceIn / c.speed))
                    c.audioLag = max(0, min(c.audioLag, (m.duration - c.sourceOut) / c.speed))
                    if c.duration > canvas.frameDuration / 2, problem(c, track) == nil {
                        tracks[t].clips[i] = c
                        warnings.append("\(label)\(c.name ?? c.id): \(why); trimmed to \(fmt2(c.duration))s")
                        continue
                    }
                }
                dropped.insert(c.id)
                warnings.append("\(label)\(c.name ?? c.id): \(why); left out")
            }
            if !dropped.isEmpty {
                tracks[t].clips.removeAll { dropped.contains($0.id) }
                transitions.removeAll { [$0.from, $0.to].contains { $0.map(dropped.contains) ?? false } }
            }
            let busIds = Set(buses.map(\.id))
            if let o = tracks[t].output, !busIds.contains(o) { tracks[t].output = nil }
            tracks[t].sends.removeAll { !busIds.contains($0.bus) }
            t += 1
        }
        return warnings

    }

    /// `name`, or "name 2", "name 3"… when a timeline already has it.
    public func freeTimelineName(_ name: String) -> String {
        let base = name.trimmingCharacters(in: .whitespaces)
        guard timelineNames.contains(base) else { return base }
        var n = 2
        while timelineNames.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
