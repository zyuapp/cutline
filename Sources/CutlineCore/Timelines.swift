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
}

extension Project {
    public var currentTimelineName: String { timelineName ?? "Main" }

    public var timelineNames: [String] { [currentTimelineName] + timelines.map(\.name) }

    func stored(as name: String) -> StoredTimeline {
        StoredTimeline(name: name, canvas: canvas, tracks: tracks, transitions: transitions, markers: markers, captions: captions, master: master)
    }

    mutating func load(_ t: StoredTimeline) {
        canvas = t.canvas
        tracks = t.tracks
        transitions = t.transitions
        markers = t.markers
        captions = t.captions
        master = t.master
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

    /// Adds another project's timeline (an imported EDL, FCPXML, OTIO or XML) as a new timeline and makes it current.
    /// Its media are matched to this project's (`matchingMedia`), so clips point at media already here; the rest are
    /// added. Clips of matched media whose imported timecode differs from the project's are moved to keep their
    /// source timecode.
    @discardableResult
    public mutating func adoptTimeline(_ other: Project, name: String) throws -> (matched: Int, added: Int) {
        var rename: [String: String] = [:]
        var shift: [String: Seconds] = [:]
        var matched = 0, added = 0
        for m in other.media {
            if let same = matchingMedia(m) {
                rename[m.id] = same.id
                if let a = m.timecodeStart, let b = same.timecodeStart, abs(a - b) > 1e-6 { shift[m.id] = a - b }
                matched += 1
            } else {
                var copy = m
                var n = 2
                while media.contains(where: { $0.id == copy.id }) { copy.id = "\(m.id)-\(n)"; n += 1 }
                rename[m.id] = copy.id
                media.append(copy)
                added += 1
            }
        }
        func remap(_ tracks: [Track]) -> [Track] {
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
        try newTimeline(name, duplicate: false)
        canvas = other.canvas
        tracks = remap(other.tracks)
        transitions = other.transitions
        markers = other.markers
        captions = other.captions
        master = other.master
        for s in other.sequences where !sequences.contains(where: { $0.id == s.id }) {
            var s = s
            s.tracks = remap(s.tracks)
            sequences.append(s)
        }
        return (matched, added)
    }
}
