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
