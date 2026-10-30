import Foundation

/// A timeline read from another tool.
public struct ImportResult: Sendable {
    public var project: Project
    /// What was dropped or approximated, one sentence each.
    public var warnings: [String]
    /// Media paths that don't exist on this machine, or EDL sources no media could be found for.
    public var missingMedia: [String]

    public init(project: Project, warnings: [String] = [], missingMedia: [String] = []) {
        self.project = project
        self.warnings = warnings
        self.missingMedia = missingMedia
    }
}

/// Reads timelines (FCPXML, OpenTimelineIO, CMX 3600 EDL) and subtitles (SRT, WebVTT) written by other tools.
/// Media is never probed: durations, sizes and rates come from the file, and only file existence is checked.
public enum Importer {
    public typealias Cue = (start: Seconds, end: Seconds, text: String)

    // MARK: Shared

    /// "A001_C003 Take 2" → "a001-c003-take-2".
    static func slug(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if !out.isEmpty && out.last != "-" {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "media" : out
    }

    static func unique(_ base: String, _ used: inout Set<String>) -> String {
        var id = base, n = 2
        while used.contains(id) { id = "\(base)-\(n)"; n += 1 }
        used.insert(id)
        return id
    }

    /// Rates like 30000/1001 become 29.97; others keep three decimals.
    static func niceFps(_ rate: Double) -> Double { (rate * 1000).rounded() / 1000 }

    /// A file path for a media URL or path, relative ones resolved against `base` (a folder, or the file beside the media).
    static func resolvePath(_ src: String, base: URL?, warnings: inout [String]) -> String {
        let s = src.trimmingCharacters(in: .whitespacesAndNewlines)
        var relative: String
        if let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme.count > 1 {
            guard scheme == "file" else {
                warnings.append("Media \(s) isn't a local file")
                return s
            }
            if url.path.hasPrefix("/") { return url.path }
            relative = url.path.isEmpty ? String(s.dropFirst(5)) : url.path
        } else if s.hasPrefix("/") {
            return s
        } else {
            relative = s.removingPercentEncoding ?? s
        }
        if relative.hasPrefix("~") { return (relative as NSString).expandingTildeInPath }
        guard let base else {
            warnings.append("Media path \(relative) is relative and no base folder was given")
            return relative
        }
        var isDir: ObjCBool = false
        let dir = base.hasDirectoryPath || (FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir) && isDir.boolValue)
            ? base : base.deletingLastPathComponent()
        return URL(fileURLWithPath: relative, relativeTo: dir).standardizedFileURL.path
    }

    static func exists(_ path: String) -> Bool { !path.isEmpty && FileManager.default.fileExists(atPath: path) }

    /// Speeds that are a hair off a round value (from frame-rate arithmetic) snap to it.
    static func niceSpeed(_ s: Double) -> Double {
        let r = (s * 100).rounded() / 100
        return abs(s * 100 - r * 100) < 0.2 ? r : s
    }

    /// Fills unknown media durations from the edit, sorts tracks, and reports clips and transitions that don't fit.
    /// Transitions that can't be placed at all are dropped.
    static func finish(_ p: inout Project, _ warnings: inout [String]) {
        var used: [String: Seconds] = [:]
        func scan(_ tracks: [Track]) {
            for c in tracks.flatMap(\.clips) where c.kind == .media {
                if let id = c.mediaId { used[id] = max(used[id] ?? 0, c.sourceOut, c.sourceIn) }
            }
        }
        scan(p.tracks)
        for s in p.sequences { scan(s.tracks) }
        for i in p.media.indices where p.media[i].duration <= 0 && !p.media[i].isImage {
            p.media[i].duration = used[p.media[i].id] ?? 0
        }
        for t in p.tracks.indices { p.tracks[t].clips.sort { $0.start < $1.start } }
        for s in p.sequences.indices {
            for t in p.sequences[s].tracks.indices { p.sequences[s].tracks[t].clips.sort { $0.start < $1.start } }
        }

        func check(_ scope: inout Project, label: String) {
            for track in scope.tracks {
                for (a, b) in zip(track.clips, track.clips.dropFirst()) where b.start < a.end - 1e-6 {
                    warnings.append("\(label)\(a.name ?? a.id) and \(b.name ?? b.id) overlap on \(track.id)")
                }
                for c in track.clips {
                    do { try scope.checkClipFits(c, track: track) } catch { warnings.append("\(label)\(c.name ?? c.id): \(error.localizedDescription)") }
                }
            }
            var kept: [Transition] = []
            for tr in scope.transitions {
                do {
                    _ = try scope.window(tr)
                    kept.append(tr)
                } catch {
                    warnings.append("\(label)Dropped transition \(tr.id): \(error.localizedDescription)")
                }
            }
            scope.transitions = kept
            for tr in kept {
                do { try scope.checkTransition(tr) } catch { warnings.append("\(label)Transition \(tr.id): \(error.localizedDescription)") }
            }
        }
        check(&p, label: "")
        for i in p.sequences.indices {
            var inner = p.inside(p.sequences[i])
            check(&inner, label: "In \(p.sequences[i].name): ")
            p.sequences[i].transitions = inner.transitions
        }
    }
}

// MARK: Tracks from lanes

/// Assigns clips to tracks by lane: lane 0 is the main track, positive lanes stack above it, negative
/// video lanes sit below it, and audio lanes become audio tracks. Clips that collide get another track of their lane.
struct LaneBuilder {
    struct Slot {
        var kind: TrackKind
        var lane: Int
        var disabled: Bool
        var clips: [Clip]
    }

    var slots = [Slot(kind: .video, lane: 0, disabled: false, clips: [])]

    /// Puts `clips`, which must share one track (a storyline), on the first track of their lane they fit.
    mutating func place(_ clips: [Clip], kind: TrackKind, lane: Int, disabled: Bool) {
        guard !clips.isEmpty else { return }
        func fits(_ s: Slot) -> Bool {
            clips.allSatisfy { c in !s.clips.contains { $0.start < c.end - 1e-6 && c.start < $0.end - 1e-6 } }
        }
        if let i = slots.firstIndex(where: { $0.kind == kind && $0.lane == lane && $0.disabled == disabled && fits($0) }) {
            slots[i].clips += clips
        } else {
            slots.append(Slot(kind: kind, lane: lane, disabled: disabled, clips: clips))
        }
    }

    func tracks() -> [Track] {
        var slots = self.slots
        if slots[0].clips.isEmpty, slots.contains(where: { $0.kind == .video && $0.lane == 0 && $0.disabled }) { slots.removeFirst() }
        func key(_ i: Int) -> (Int, Int, Int, Int) {
            let s = slots[i]
            let order = s.kind == .video ? s.lane : (s.lane <= 0 ? -s.lane : 1000 + s.lane)
            return (s.kind == .video ? 0 : 1, order, s.disabled ? 1 : 0, i)
        }
        var v = 0, a = 0
        return slots.indices.sorted { key($0) < key($1) }.map { i in
            let s = slots[i]
            let n: Int
            if s.kind == .video { v += 1; n = v } else { a += 1; n = a }
            let name = s.kind == .video ? (s.lane == 0 && !s.disabled ? "Main" : "Video \(n)") : "Audio \(n)"
            return Track(id: (s.kind == .video ? "V" : "A") + "\(n)", kind: s.kind, name: name,
                         muted: s.kind == .audio && s.disabled, hidden: s.kind == .video && s.disabled,
                         clips: s.clips.sorted { $0.start < $1.start })
        }
    }
}

// MARK: FCPXML

extension XMLElement {
    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }
    var elems: [XMLElement] { children?.compactMap { $0 as? XMLElement } ?? [] }
    func first(_ name: String) -> XMLElement? { elems.first { $0.name == name } }
}

extension Importer {
    /// Final Cut Pro XML 1.6–1.11: a library/event/project, or a bare project or sequence.
    ///
    /// The primary storyline becomes V1; connected clips and secondary storylines at positive lanes become
    /// video tracks above it, audio at negative lanes audio tracks. Compound clips (`ref-clip`) become nested
    /// sequences. Times honour `tcStart`, asset start timecode and constant-speed `timeMap`s.
    /// Media ids come from asset names, lowercase with dashes; relative `src` paths resolve against `base`.
    public static func fcpxml(_ data: Data, relativeTo base: URL?) throws -> ImportResult {
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data, options: []) } catch { throw EditError("Not valid XML: \(error.localizedDescription)") }
        guard let root = doc.rootElement(), root.name == "fcpxml" else { throw EditError("Not an FCPXML document: the root element must be <fcpxml>") }
        return try FCPReader(base: base).read(root)
    }
}

final class FCPReader {
    struct Context {
        var lanes = LaneBuilder()
        var transitions: [Transition] = []
        var markers: [Marker] = []
        /// Clips of the storylines being read, placed together when each storyline ends.
        var storylines: [[(clip: Clip, kind: TrackKind, lane: Int, disabled: Bool)]] = []
    }

    static let storyNames: Set<String> = ["asset-clip", "clip", "sync-clip", "ref-clip", "title", "gap", "video", "audio", "mc-clip", "audition", "live-drawing"]

    let base: URL?
    var warnings: [String] = []
    var missing: [String] = []
    var resources: [String: XMLElement] = [:]
    /// Asset resource id → media id and the asset's start timecode.
    var assets: [String: (id: String, start: Seconds)] = [:]
    var media: [MediaAsset] = []
    var sequences: [NestedSequence] = []
    var compounds: [String: (id: String, tcStart: Seconds)] = [:]
    var usedSequenceIds = Set<String>()
    var clipCount = 0, markerCount = 0
    var grid = FrameGrid(fps: 30)
    var canvas = Canvas()
    var ctx = Context()

    init(base: URL?) { self.base = base }

    func time(_ s: String?) -> Seconds? {
        guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix("s") { s.removeLast() }
        let parts = s.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return n / d }
        return Double(s)
    }

    func snap(_ t: Seconds) -> Seconds { Double(grid.frames(t) * grid.num) / Double(grid.den) }

    func pair(_ s: String?) -> (Double, Double)? {
        let v = (s ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        return v.count >= 2 ? (v[0], v[1]) : nil
    }

    func label(_ e: XMLElement) -> String { e.attr("name").map { "\"\($0)\"" } ?? e.name ?? "item" }

    func read(_ root: XMLElement) throws -> ImportResult {
        if let v = root.attr("version") {
            let parts = v.split(separator: ".").compactMap { Int($0) }
            if parts.count >= 2, parts[0] != 1 || parts[1] < 6 || parts[1] > 11 {
                warnings.append("FCPXML \(v) is outside 1.6–1.11; imported as far as it matches")
            }
        }
        readResources(root)

        let projects = descendants(root, "project")
        let sequence: XMLElement
        if let p = projects.first {
            guard let s = p.first("sequence") else { throw EditError("Project \(p.attr("name") ?? "") has no sequence") }
            sequence = s
            if projects.count > 1 { warnings.append("The file has \(projects.count) projects; imported \(p.attr("name") ?? "the first")") }
        } else if let s = descendants(root, "sequence").first {
            sequence = s
        } else {
            throw EditError("No project or sequence in the FCPXML")
        }
        let name = projects.first?.attr("name") ?? sequence.attr("name") ?? "Imported"

        let format = sequence.attr("format").flatMap { resources[$0] }
        if let fd = time(format?.attr("frameDuration")), fd > 0 { grid = FrameGrid(fps: 1 / fd) }
        canvas = Canvas(width: Int(format?.attr("width") ?? "") ?? 1920, height: Int(format?.attr("height") ?? "") ?? 1080, fps: Importer.niceFps(grid.rate))

        let main = readSequence(sequence)
        var p = Project(name: name, canvas: canvas)
        p.media = media
        p.tracks = main.lanes.tracks()
        p.transitions = main.transitions
        p.markers = main.markers.sorted { $0.time < $1.time }
        p.sequences = sequences
        Importer.finish(&p, &warnings)
        return ImportResult(project: p, warnings: warnings, missingMedia: missing)
    }

    /// Elements named `name` below `e`, skipping resources (compound clips hold sequences too).
    func descendants(_ e: XMLElement, _ name: String) -> [XMLElement] {
        e.elems.flatMap { k -> [XMLElement] in
            if k.name == "resources" { return [] }
            return (k.name == name ? [k] : []) + descendants(k, name)
        }
    }

    func readResources(_ root: XMLElement) {
        let all = root.elems.filter { $0.name == "resources" }.flatMap(\.elems)
        for e in all { if let id = e.attr("id") { resources[id] = e } }
        var used = Set<String>()
        for e in all where e.name == "asset" {
            guard let rid = e.attr("id") else { continue }
            let reps = e.elems.filter { $0.name == "media-rep" }
            let src = (reps.first { $0.attr("kind") == "original-media" } ?? reps.first)?.attr("src") ?? e.attr("src")
            let path = src.map { Importer.resolvePath($0, base: base, warnings: &warnings) } ?? ""
            let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let name = e.attr("name") ?? (fileName.isEmpty ? rid : fileName)
            if src == nil {
                warnings.append("Asset \(name) has no media path")
            } else if !Importer.exists(path), !missing.contains(path) {
                missing.append(path)
            }
            let format = e.attr("format").flatMap { resources[$0] }
            let frameDuration = time(format?.attr("frameDuration"))
            let hasVideo = e.attr("hasVideo").map { $0 == "1" } ?? (format != nil || e.attr("videoSources") != nil)
            let hasAudio = e.attr("hasAudio").map { $0 == "1" } ?? (e.attr("audioSources") != nil)
            let duration = time(e.attr("duration"))
            let isImage = hasVideo && (duration == 0 || (frameDuration == nil && format?.attr("name") == "FFVideoFormatRateUndefined"))
            let fps = isImage || !hasVideo ? 0 : frameDuration.map { Importer.niceFps(1 / $0) } ?? 0
            let id = Importer.unique(Importer.slug(name), &used)
            media.append(MediaAsset(id: id, path: path, name: name, duration: isImage ? 0 : duration ?? 0,
                                    width: hasVideo ? Int(format?.attr("width") ?? "") ?? 0 : 0,
                                    height: hasVideo ? Int(format?.attr("height") ?? "") ?? 0 : 0,
                                    fps: fps, hasVideo: hasVideo, hasAudio: hasAudio, isImage: isImage))
            assets[rid] = (id, time(e.attr("start")) ?? 0)
        }
    }

    // MARK: Story

    /// Reads a sequence into its own tracks, transitions and markers, timed from its `tcStart`.
    func readSequence(_ seq: XMLElement) -> Context {
        let saved = ctx
        ctx = Context()
        let tc = time(seq.attr("tcStart")) ?? 0
        if let spine = seq.first("spine") { readSpine(spine, place: { $0 - tc }, lane: 0, disabled: false, storyline: false) }
        let out = ctx
        ctx = saved
        return out
    }

    /// Reads the items of a storyline in order; `place` maps the storyline's local time to the timeline.
    func readSpine(_ spine: XMLElement, place: @escaping (Seconds) -> Seconds, lane: Int, disabled: Bool, storyline: Bool) {
        if storyline { ctx.storylines.append([]) }
        struct Item { var clipId: String?; var start: Seconds; var end: Seconds }
        var items: [Item] = []
        var pending: [(XMLElement, Int)] = []
        var cursor = spine.elems.first { FCPReader.storyNames.contains($0.name ?? "") }.flatMap { time($0.attr("offset")) } ?? 0
        for e in spine.elems {
            let name = e.name ?? ""
            if name == "transition" { pending.append((e, items.count)); continue }
            guard FCPReader.storyNames.contains(name) else { continue }
            let offset = time(e.attr("offset")) ?? cursor
            let duration = time(e.attr("duration")) ?? 0
            let t = place(offset)
            let id = readItem(e, at: t, lane: lane, disabled: disabled)
            items.append(Item(clipId: id, start: snap(t), end: snap(t + duration)))
            cursor = offset + duration
        }
        for (tr, index) in pending {
            let prev = index > 0 ? items[index - 1] : nil
            let next = index < items.count ? items[index] : nil
            guard prev?.clipId != nil || next?.clipId != nil, let d = time(tr.attr("duration")), d > 0 else { continue }
            let cut = next?.start ?? prev!.end
            let s = time(tr.attr("offset")).map(place) ?? (cut - d / 2)
            let half = 0.5 / grid.rate
            var align = TransitionAlign.center
            if abs(s - cut) < half { align = .start } else if abs(s + d - cut) < half { align = .end } else if abs(s - (cut - d / 2)) >= half {
                warnings.append("Transition \(label(tr)) isn't on a cut; centered on it")
            }
            let name = tr.attr("name") ?? tr.first("filter-video")?.attr("name") ?? "Transition"
            let lower = name.lowercased()
            let type: String
            if lower.contains("fade to") || lower.contains("dip") {
                type = "dip"
            } else {
                type = "dissolve"
                if !lower.contains("dissolve") { warnings.append("Transition \(name) imported as a dissolve") }
            }
            ctx.transitions.append(Transition(id: "tr\(ctx.transitions.count + 1)", from: prev?.clipId, to: next?.clipId, type: type, duration: snap(d), align: align))
        }
        if storyline { flushStoryline() }
    }

    func emit(_ clip: Clip, kind: TrackKind, lane: Int, disabled: Bool) {
        if ctx.storylines.isEmpty {
            ctx.lanes.place([clip], kind: kind, lane: lane, disabled: disabled)
        } else {
            ctx.storylines[ctx.storylines.count - 1].append((clip, kind, lane, disabled))
        }
    }

    func flushStoryline() {
        let placed = ctx.storylines.removeLast()
        var groups: [(kind: TrackKind, lane: Int, disabled: Bool, clips: [Clip])] = []
        for p in placed {
            if let i = groups.firstIndex(where: { $0.kind == p.kind && $0.lane == p.lane && $0.disabled == p.disabled }) {
                groups[i].clips.append(p.clip)
            } else {
                groups.append((p.kind, p.lane, p.disabled, [p.clip]))
            }
        }
        for g in groups { ctx.lanes.place(g.clips, kind: g.kind, lane: g.lane, disabled: g.disabled) }
    }

    func nextClipId() -> String { clipCount += 1; return "c\(clipCount)" }

    func laneSum(_ parent: Int, _ child: Int) -> Int { parent + child == 0 ? child : parent + child }

    /// Reads one story item placed at timeline time `t`, then what's connected to it. Returns its clip id.
    @discardableResult
    func readItem(_ e: XMLElement, at t: Seconds, lane: Int, disabled parentDisabled: Bool) -> String? {
        let start = time(e.attr("start")) ?? 0
        let duration = time(e.attr("duration")) ?? 0
        let place: (Seconds) -> Seconds = { t + ($0 - start) }
        let disabled = parentDisabled || e.attr("enabled") == "0"
        if e.name == "audition" {
            warnings.append("Audition \(label(e)): imported its active pick")
            guard let pick = e.elems.first(where: { FCPReader.storyNames.contains($0.name ?? "") }) else { return nil }
            return readItem(pick, at: t, lane: lane, disabled: disabled)
        }
        var clipId: String?
        if let made = build(e, start: start, duration: duration, place: place, lane: lane, disabled: disabled) {
            var clip = made.0
            let kind = made.1
            let s = snap(t), end = snap(t + duration)
            if end > s {
                clip.start = s
                clip.duration = end - s
                clip.id = nextClipId()
                let keywords = e.elems.filter { $0.name == "keyword" }.compactMap { $0.attr("value") }
                if !keywords.isEmpty {
                    if clip.name == nil { clip.name = keywords.joined(separator: ", ") } else {
                        warnings.append("Keywords on \(clip.name!) not kept: \(keywords.joined(separator: ", "))")
                    }
                }
                emit(clip, kind: kind, lane: lane, disabled: disabled)
                clipId = clip.id
            }
        }
        readChildren(e, place: place, lane: lane, disabled: disabled)
        return clipId
    }

    /// Markers, connected clips and secondary storylines inside `e`, whose local time `place` maps to the timeline.
    func readChildren(_ e: XMLElement, place: (Seconds) -> Seconds, lane: Int, disabled: Bool, skip: (XMLElement) -> Bool = { _ in false }) {
        for k in e.elems where !skip(k) {
            let name = k.name ?? ""
            switch name {
            case "marker", "chapter-marker":
                markerCount += 1
                let label = k.attr("value") ?? (name == "marker" ? "Marker" : "Chapter")
                ctx.markers.append(Marker(id: "marker\(markerCount)", time: snap(place(time(k.attr("start")) ?? 0)), label: label))
            case "spine":
                guard let l = k.attr("lane").flatMap({ Int($0) }) else { continue }
                let origin = place(time(k.attr("offset")) ?? 0)
                let first = k.elems.first { FCPReader.storyNames.contains($0.name ?? "") }.flatMap { time($0.attr("offset")) } ?? 0
                readSpine(k, place: { origin + ($0 - first) }, lane: laneSum(lane, l), disabled: disabled, storyline: true)
            case _ where FCPReader.storyNames.contains(name):
                guard let l = k.attr("lane").flatMap({ Int($0) }) else { continue }
                readItem(k, at: place(time(k.attr("offset")) ?? 0), lane: laneSum(lane, l), disabled: disabled)
            default:
                break
            }
        }
    }

    /// The clip an element plays, timed from local `start`, without its timeline position.
    func build(_ e: XMLElement, start: Seconds, duration: Seconds, place: @escaping (Seconds) -> Seconds, lane: Int, disabled: Bool) -> (Clip, TrackKind)? {
        switch e.name ?? "" {
        case "asset-clip", "video", "audio": return mediaClip(e, start: start, duration: duration)
        case "clip", "sync-clip": return containerClip(e, start: start, duration: duration, place: place, lane: lane, disabled: disabled)
        case "ref-clip": return refClip(e, start: start)
        case "title": return (titleClip(e), .video)
        case "gap": return nil
        case "mc-clip":
            warnings.append("Multicam clip \(label(e)) imported as a gap")
            return nil
        default:
            warnings.append("\(e.name ?? "Element") \(label(e)) isn't supported; left as a gap")
            return nil
        }
    }

    /// Local time → source time and the constant speed of a `timeMap`.
    func timeMap(_ e: XMLElement) -> (map: (Seconds) -> Seconds, speed: Double) {
        guard let tm = e.first("timeMap") else { return ({ $0 }, 1) }
        let pts = tm.elems.filter { $0.name == "timept" }.compactMap { p -> (t: Seconds, v: Seconds)? in
            guard let t = time(p.attr("time")), let v = time(p.attr("value")) else { return nil }
            return (t, v)
        }.sorted { $0.t < $1.t }
        guard pts.count >= 2, pts.last!.t > pts.first!.t else {
            warnings.append("Freeze frame on \(label(e)) imported at normal speed")
            let p = pts.first ?? (0, 0)
            return ({ p.v + ($0 - p.t) }, 1)
        }
        let segments = zip(pts, pts.dropFirst()).filter { $1.t > $0.t }.map { a, b in (a: a, b: b, slope: (b.v - a.v) / (b.t - a.t)) }
        let first = segments[0].slope
        var speed = first
        if !segments.allSatisfy({ abs($0.slope - first) <= 1e-3 * max(1, abs(first)) }) || abs(first) < 1e-6 {
            speed = (pts.last!.v - pts.first!.v) / (pts.last!.t - pts.first!.t)
            warnings.append("\(label(e)) changes speed over time; imported at its average \(String(format: "%.3g", speed))×")
        }
        if abs(speed) < 0.01 {
            warnings.append("Speed of \(label(e)) is too slow to play; imported at normal speed")
            speed = 1
        }
        let map: (Seconds) -> Seconds = { t in
            let seg = segments.first { t < $0.b.t } ?? segments.last!
            return seg.a.v + (t - seg.a.t) * seg.slope
        }
        return (map, speed)
    }

    func clampSpeed(_ clip: inout Clip, _ speed: Double, _ e: XMLElement) {
        var s = abs(speed)
        if s > 100 || s < 0.01 {
            warnings.append("Speed of \(label(e)) clamped to 0.01–100×")
            s = min(max(s, 0.01), 100)
        }
        clip.speed = Importer.niceSpeed(s)
        clip.reverse = speed < 0
    }

    func mediaClip(_ e: XMLElement, start: Seconds, duration: Seconds) -> (Clip, TrackKind)? {
        guard let ref = e.attr("ref"), let asset = assets[ref], let m = media.first(where: { $0.id == asset.id }) else {
            let res = e.attr("ref").flatMap { resources[$0] }
            if res?.name == "effect" {
                warnings.append("Generator \(res?.attr("name") ?? label(e)) left as a gap")
            } else {
                warnings.append("\(label(e)) refers to missing resource \(e.attr("ref") ?? "nil"); left as a gap")
            }
            return nil
        }
        var clip = Clip(id: "", kind: .media, name: e.attr("name") ?? m.name, mediaId: m.id, start: 0, duration: duration)
        if !m.isImage {
            let (map, speed) = timeMap(e)
            clampSpeed(&clip, speed, e)
            clip.sourceIn = map(start) - asset.start
            if clip.reverse { clip.sourceIn -= duration * clip.speed }
        }
        let audioOnly = e.name == "audio" || e.attr("srcEnable") == "audio" || !m.hasVideo
        if e.attr("srcEnable") == "video" { clip.volume = 0 }
        adjust(e, &clip)
        return (clip, audioOnly ? .audio : .video)
    }

    /// A `clip` or `sync-clip`: plays its first storyline item, or nests a storyline it wraps.
    func containerClip(_ e: XMLElement, start: Seconds, duration: Seconds, place: @escaping (Seconds) -> Seconds, lane: Int, disabled: Bool) -> (Clip, TrackKind)? {
        let content: Set<String> = ["video", "audio", "asset-clip", "ref-clip", "clip", "sync-clip", "title"]
        let laneless = e.elems.filter { content.contains($0.name ?? "") && $0.attr("lane") == nil }
        let (outerMap, outerSpeed) = timeMap(e)
        let local = outerMap(start)
        if let inner = laneless.first(where: { $0.name != "audio" }) ?? laneless.first {
            let innerOffset = time(inner.attr("offset")) ?? 0, innerStart = time(inner.attr("start")) ?? 0
            let innerPlace: (Seconds) -> Seconds = { place(innerOffset + ($0 - innerStart)) }
            guard let made = build(inner, start: innerStart + (local - innerOffset), duration: duration * abs(outerSpeed), place: innerPlace, lane: lane, disabled: disabled) else { return nil }
            var clip = made.0
            if abs(outerSpeed - 1) > 1e-9 { clampSpeed(&clip, (clip.reverse ? -clip.speed : clip.speed) * outerSpeed, e) }
            clip.name = e.attr("name") ?? clip.name
            adjust(e, &clip)
            let ref = inner.attr("ref")
            readChildren(inner, place: innerPlace, lane: lane, disabled: disabled) { k in k.name == "audio" && k.attr("ref") == ref }
            return (clip, made.1)
        }
        if let spine = e.elems.first(where: { $0.name == "spine" && $0.attr("lane") == nil }) {
            let c = nestedContext { readSpine(spine, place: { $0 }, lane: 0, disabled: false, storyline: false) }
            let id = addSequence(name: e.attr("name") ?? "Clip", c)
            var clip = Clip(id: "", kind: .sequence, name: e.attr("name"), mediaId: id, start: 0, duration: duration, sourceIn: local)
            adjust(e, &clip)
            return (clip, .video)
        }
        warnings.append("Clip \(label(e)) has no media; left as a gap")
        return nil
    }

    func nestedContext(_ body: () -> Void) -> Context {
        let saved = ctx
        ctx = Context()
        body()
        let out = ctx
        ctx = saved
        return out
    }

    func addSequence(name: String, _ c: Context) -> String {
        let id = Importer.unique(Importer.slug(name), &usedSequenceIds)
        sequences.append(NestedSequence(id: id, name: name, tracks: c.lanes.tracks(), transitions: c.transitions))
        if !c.markers.isEmpty { warnings.append("\(c.markers.count) marker(s) inside \(name) not kept") }
        return id
    }

    /// A compound clip: its `media` resource becomes a nested sequence, shared by every use.
    func refClip(_ e: XMLElement, start: Seconds) -> (Clip, TrackKind)? {
        guard let ref = e.attr("ref"), let res = resources[ref], res.name == "media" else {
            warnings.append("Compound clip \(label(e)) refers to missing media \(e.attr("ref") ?? "nil"); left as a gap")
            return nil
        }
        let seq: (id: String, tcStart: Seconds)
        if let known = compounds[ref] {
            seq = known
        } else {
            guard let inner = res.first("sequence") else {
                warnings.append("\(res.first("multicam") != nil ? "Multicam" : "Compound") clip \(label(e)) imported as a gap")
                return nil
            }
            let name = res.attr("name") ?? e.attr("name") ?? "Compound"
            seq = (addSequence(name: name, readSequence(inner)), time(inner.attr("tcStart")) ?? 0)
            compounds[ref] = seq
        }
        let (map, speed) = timeMap(e)
        if abs(speed - 1) > 1e-6 { warnings.append("Speed of compound clip \(label(e)) not kept") }
        var clip = Clip(id: "", kind: .sequence, name: e.attr("name") ?? res.attr("name"), mediaId: seq.id, start: 0, duration: 0, sourceIn: map(start) - seq.tcStart)
        adjust(e, &clip)
        return (clip, e.attr("srcEnable") == "audio" ? .audio : .video)
    }

    func titleClip(_ e: XMLElement) -> Clip {
        var defs: [String: XMLElement] = [:]
        for d in e.elems where d.name == "text-style-def" {
            if let id = d.attr("id"), let ts = d.first("text-style") { defs[id] = ts }
        }
        var paragraphs: [String] = []
        var style: XMLElement?
        for text in e.elems where text.name == "text" {
            let runs = text.elems.filter { $0.name == "text-style" }
            paragraphs.append(runs.isEmpty ? text.stringValue ?? "" : runs.map { $0.stringValue ?? "" }.joined())
            if style == nil { style = runs.lazy.compactMap { $0.attr("ref").flatMap { defs[$0] } }.first }
        }
        var text = paragraphs.joined(separator: "\n")
        if text.isEmpty { text = e.attr("name") ?? "Title" }
        var spec = TextSpec(text: text, shadow: false, animationIn: .none, animationOut: .none)
        let w = Double(canvas.width), h = Double(canvas.height)
        if let st = style {
            if let f = st.attr("font") {
                switch f {
                case "Helvetica Neue": spec.font = "system"
                case "Times New Roman": spec.font = "serif"
                case "Menlo": spec.font = "mono"
                default: spec.font = f
                }
            }
            if let size = st.attr("fontSize").flatMap({ Double($0) }) { spec.size = size / min(w, h) }
            let face = (st.attr("fontFace") ?? "").lowercased()
            if face.contains("black") || face.contains("heavy") { spec.weight = 900 } else if face.contains("semibold") { spec.weight = 600 } else if face.contains("bold") || st.attr("bold") == "1" { spec.weight = 700 } else if face.contains("medium") { spec.weight = 500 } else if face.contains("light") || face.contains("thin") { spec.weight = 300 } else if !face.isEmpty { spec.weight = 400 }
            func color(_ s: String?) -> RGBA? {
                let v = (s ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
                return v.count >= 3 ? RGBA(r: v[0], g: v[1], b: v[2], a: v.count > 3 ? v[3] : 1) : nil
            }
            if let c = color(st.attr("fontColor")) { spec.color = c }
            if let c = color(st.attr("strokeColor")) {
                spec.stroke = c
                spec.strokeWidth = abs(st.attr("strokeWidth").flatMap { Double($0) } ?? 1) / max(spec.size * min(w, h), 1)
            }
            if st.attr("shadowColor") != nil { spec.shadow = true }
            if let a = st.attr("alignment"), let align = TextAlign(rawValue: a) { spec.align = align }
        }
        if let pos = pair(e.elems.first(where: { $0.name == "param" && $0.attr("name") == "Position" })?.attr("value")) {
            spec.x = 0.5 + pos.0 / w
            spec.y = 0.5 - pos.1 / h
        }
        var clip = Clip(id: "", kind: .text, name: e.attr("name"), start: 0, duration: 0, text: spec)
        if let at = e.first("adjust-transform"), let pos = pair(at.attr("position")) {
            clip.text!.x = 0.5 + pos.0 / 100 * h / w
            clip.text!.y = 0.5 - pos.1 / 100
        }
        adjust(e, &clip, positioned: false)
        return clip
    }

    /// Transform, crop, opacity, volume and audio enables; reports effects it can't carry.
    func adjust(_ e: XMLElement, _ clip: inout Clip, positioned: Bool = true) {
        let w = Double(canvas.width), h = Double(canvas.height)
        let what = clip.name.map { "\"\($0)\"" } ?? label(e)
        var channels: [Bool] = []
        for k in e.elems {
            switch k.name ?? "" {
            case "adjust-transform":
                if positioned, let p = pair(k.attr("position")) {
                    clip.transform.x = p.0 / 100 * h / w
                    clip.transform.y = -p.1 / 100
                }
                if let s = pair(k.attr("scale")) {
                    if abs(abs(s.0) - abs(s.1)) > 1e-3 { warnings.append("Non-uniform scale on \(what) averaged") }
                    clip.transform.scale = (abs(s.0) + abs(s.1)) / 2
                }
                if let r = k.attr("rotation").flatMap({ Double($0) }) { clip.transform.rotation = -r }
                if k.elems.contains(where: { $0.first("keyframeAnimation") != nil }) { warnings.append("Transform keyframes on \(what) not kept") }
            case "adjust-crop":
                let mode = k.attr("mode") ?? "trim"
                if mode == "pan" { warnings.append("Ken Burns on \(what) not kept") }
                if let r = k.first("trim-rect") ?? k.first("crop-rect") {
                    func v(_ n: String) -> Double { max(0, r.attr(n).flatMap { Double($0) } ?? 0) / 100 }
                    clip.transform.crop = Crop(left: v("left") * h / w, top: v("top"), right: v("right") * h / w, bottom: v("bottom"))
                }
            case "adjust-volume":
                if let a = k.attr("amount") {
                    let db = Double(a.replacingOccurrences(of: "dB", with: "").replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)) ?? 0
                    clip.volume *= db <= -96 ? 0 : pow(10, db / 20)
                }
                for param in k.elems where param.name == "param" {
                    if let f = time(param.first("fadeIn")?.attr("duration")) { clip.audioFadeIn = f }
                    if let f = time(param.first("fadeOut")?.attr("duration")) { clip.audioFadeOut = f }
                    if param.first("keyframeAnimation") != nil { warnings.append("Volume keyframes on \(what) not kept") }
                }
            case "adjust-blend":
                if let a = k.attr("amount").flatMap({ Double($0) }) { clip.transform.opacity = min(max(a, 0), 1) }
            case "adjust-conform":
                switch k.attr("type") {
                case "fill": clip.transform.fit = .fill
                case "none": warnings.append("Native-size conform on \(what) imported as fit")
                default: clip.transform.fit = .fit
                }
            case "audio-channel-source", "audio-role-source":
                channels.append(k.attr("enabled") != "0")
            case "filter-video", "filter-audio":
                warnings.append("Effect \(k.attr("name") ?? k.attr("ref") ?? "") on \(what) not kept")
            case let n where n.hasPrefix("adjust-"):
                warnings.append("\(n) on \(what) not kept")
            default:
                break
            }
        }
        if !channels.isEmpty, !channels.contains(true) { clip.volume = 0 } else if channels.contains(false) {
            warnings.append("Some audio channels of \(what) are disabled; all are kept")
        }
    }
}

// MARK: OpenTimelineIO

extension Importer {
    /// OpenTimelineIO JSON: a Timeline (or a SerializableCollection holding one) whose Stack holds Video and
    /// Audio tracks. Clips (Clip.1 `media_reference`, Clip.2 `media_references`) with ExternalReferences,
    /// gaps, SMPTE dissolves, LinearTimeWarp speed, markers and nested Stacks (as nested sequences).
    /// Audio clips that only repeat a video clip's sound are folded into it. Cutline's own metadata
    /// (clip ids, titles, volumes) is read back when present.
    public static func otio(_ data: Data, relativeTo base: URL?) throws -> ImportResult {
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data) } catch { throw EditError("Not valid JSON: \(error.localizedDescription)") }
        guard let root = json as? [String: Any] else { throw EditError("Not an OpenTimelineIO document") }
        return try OTIOReader(base: base).read(root)
    }
}

final class OTIOReader {
    let base: URL?
    var warnings: [String] = []
    var missing: [String] = []
    var media: [MediaAsset] = []
    var mediaByPath: [String: Int] = [:]
    var availableStart: [String: Seconds] = [:]
    var usedMediaIds = Set<String>(), usedSequenceIds = Set<String>(), usedClipIds = Set<String>()
    var sequences: [NestedSequence] = []
    var markers: [Marker] = []
    var clipCount = 0, transitionCount = 0
    var canvas = Canvas()

    init(base: URL?) { self.base = base }

    static func schema(_ d: [String: Any]) -> String { (d["OTIO_SCHEMA"] as? String)?.split(separator: ".").first.map(String.init) ?? "" }
    static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap { Double($0) } }
    static func time(_ v: Any?) -> Seconds? {
        guard let d = v as? [String: Any], let value = number(d["value"]), let rate = number(d["rate"]), rate > 0 else { return nil }
        return value / rate
    }
    static func rate(_ v: Any?) -> Double? { ((v as? [String: Any])?["duration"] as? [String: Any]).flatMap { number($0["rate"]) } }
    static func range(_ v: Any?) -> (start: Seconds, duration: Seconds)? {
        guard let d = v as? [String: Any], let dur = time(d["duration"]) else { return nil }
        return (time(d["start_time"]) ?? 0, dur)
    }
    static func cutline(_ d: [String: Any]) -> [String: Any] { (d["metadata"] as? [String: Any])?["cutline"] as? [String: Any] ?? [:] }
    static func items(_ d: [String: Any]) -> [[String: Any]] { d["children"] as? [[String: Any]] ?? [] }

    func read(_ root: [String: Any]) throws -> ImportResult {
        var timeline = root
        switch Self.schema(root) {
        case "Timeline": break
        case "SerializableCollection":
            let found = (root["children"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.filter { Self.schema($0) == "Timeline" }
            guard let first = found.first else { throw EditError("The OTIO collection holds no timeline") }
            if found.count > 1 { warnings.append("The collection has \(found.count) timelines; imported \(first["name"] as? String ?? "the first")") }
            timeline = first
        case "Stack": timeline = ["name": "Imported", "tracks": root]
        default: throw EditError("Not an OpenTimelineIO timeline (\(root["OTIO_SCHEMA"] as? String ?? "no schema"))")
        }
        guard let stack = timeline["tracks"] as? [String: Any] else { throw EditError("The timeline has no tracks") }

        let md = Self.cutline(timeline)
        let fps = Self.number(md["fps"]) ?? findRate(stack) ?? 24
        canvas = Canvas(width: Int(Self.number(md["width"]) ?? 1920), height: Int(Self.number(md["height"]) ?? 1080),
                        fps: Importer.niceFps(fps), background: (md["background"] as? String).flatMap { RGBA(hex: $0) } ?? .black)

        let (tracks, transitions) = readStack(stack, top: true)
        for m in stack["markers"] as? [[String: Any]] ?? [] { addMarker(m, at: { $0 }) }

        var p = Project(name: timeline["name"] as? String ?? "Imported", canvas: canvas)
        p.media = media
        p.tracks = tracks.contains(where: { $0.kind == .video }) ? tracks : [Track(id: "V1", kind: .video, name: "Main")] + tracks
        p.transitions = transitions
        p.markers = markers.sorted { $0.time < $1.time }
        p.sequences = sequences
        Importer.finish(&p, &warnings)
        return ImportResult(project: p, warnings: warnings, missingMedia: missing)
    }

    func findRate(_ stack: [String: Any]) -> Double? {
        for track in Self.items(stack) {
            for item in Self.items(track) { if let r = Self.rate(item["source_range"]) { return r } }
        }
        return nil
    }

    func addMarker(_ m: [String: Any], at map: (Seconds) -> Seconds) {
        guard let r = Self.range(m["marked_range"]) else { return }
        let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (m["comment"] as? String) ?? "Marker"
        markers.append(Marker(id: "marker\(markers.count + 1)", time: map(r.start), label: name))
    }

    func clipId(_ preferred: Any?) -> String {
        if let s = preferred as? String, !s.isEmpty, !usedClipIds.contains(s) { usedClipIds.insert(s); return s }
        repeat { clipCount += 1 } while usedClipIds.contains("c\(clipCount)")
        usedClipIds.insert("c\(clipCount)")
        return "c\(clipCount)"
    }

    func readStack(_ stack: [String: Any], top: Bool) -> ([Track], [Transition]) {
        var tracks: [Track] = []
        var transitions: [Transition] = []
        var linked = Set<String>()
        for child in Self.items(stack) {
            guard Self.schema(child) == "Track" else {
                warnings.append("\(child["OTIO_SCHEMA"] as? String ?? "Item") directly in a stack not kept")
                continue
            }
            let kind: TrackKind = (child["kind"] as? String)?.lowercased() == "audio" ? .audio : .video
            let md = Self.cutline(child)
            if md["embeddedAudio"] as? Bool == true {
                for item in Self.items(child) where Self.schema(item) == "Clip" {
                    if let ref = activeReference(item), let id = mediaId(ref, clipName: item["name"] as? String ?? "", kind: .audio) { linked.insert(id) }
                }
                continue
            }
            let enabled = child["enabled"] as? Bool ?? true
            let name = (child["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (kind == .video ? "Video" : "Audio")
            var track = Track(id: "", kind: kind, name: name, muted: kind == .audio && !enabled, hidden: kind == .video && !enabled,
                              volume: Self.number(md["volume"]) ?? 1)
            let read = readTrack(child, kind: kind, top: top)
            track.clips = read.clips
            transitions += read.transitions
            tracks.append(track)
            if !read.disabled.isEmpty {
                tracks.append(Track(id: "", kind: kind, name: "\(name) (disabled)", muted: kind == .audio, hidden: kind == .video, clips: read.disabled))
            }
        }

        // Sound already carried by a video clip.
        let video = tracks.filter { $0.kind == .video }.flatMap(\.clips).filter { $0.kind == .media }
        let half = 0.5 / max(canvas.fps, 1)
        var drop: [Int] = []
        for t in tracks.indices where tracks[t].kind == .audio && !tracks[t].clips.isEmpty {
            tracks[t].clips.removeAll { a in
                guard a.kind == .media, video.contains(where: { v in
                    v.mediaId == a.mediaId && abs(v.start - a.start) < half && abs(v.duration - a.duration) < half
                        && abs(v.sourceIn - a.sourceIn) < half && abs(v.speed - a.speed) < 1e-6 && v.reverse == a.reverse
                }) else { return false }
                if let id = a.mediaId { linked.insert(id) }
                return true
            }
            if tracks[t].clips.isEmpty { drop.append(t) }
        }
        for t in drop.reversed() { tracks.remove(at: t) }
        for i in media.indices where linked.contains(media[i].id) { media[i].hasAudio = true }

        var v = 0, a = 0
        for t in tracks.indices {
            if tracks[t].kind == .video { v += 1; tracks[t].id = "V\(v)" } else { a += 1; tracks[t].id = "A\(a)" }
        }
        return (tracks, transitions)
    }

    func naturalDuration(_ item: [String: Any]) -> Seconds {
        if let r = Self.range(item["source_range"]) { return r.duration }
        switch Self.schema(item) {
        case "Track": return Self.items(item).filter { Self.schema($0) != "Transition" }.map(naturalDuration).reduce(0, +)
        case "Stack": return Self.items(item).map(naturalDuration).max() ?? 0
        case "Clip": return activeReference(item).flatMap { Self.range($0["available_range"])?.duration } ?? 0
        default: return 0
        }
    }

    func activeReference(_ clip: [String: Any]) -> [String: Any]? {
        if let refs = clip["media_references"] as? [String: Any] {
            let key = clip["active_media_reference_key"] as? String ?? "DEFAULT_MEDIA"
            return (refs[key] ?? refs.values.first) as? [String: Any]
        }
        return clip["media_reference"] as? [String: Any]
    }

    func mediaId(_ ref: [String: Any], clipName: String, kind: TrackKind) -> String? {
        switch Self.schema(ref) {
        case "ExternalReference":
            guard let url = ref["target_url"] as? String, !url.isEmpty else { return nil }
            let path = Importer.resolvePath(url, base: base, warnings: &warnings)
            let avail = Self.range(ref["available_range"])
            if let i = mediaByPath[path] {
                if kind == .video { media[i].hasVideo = true } else { media[i].hasAudio = true }
                return media[i].id
            }
            let file = (path as NSString).lastPathComponent
            var name = (ref["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (clipName.isEmpty ? file : clipName)
            if name == file { name = (file as NSString).deletingPathExtension }
            let ext = (file as NSString).pathExtension.lowercased()
            let isImage = avail == nil && ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp"].contains(ext)
            let id = Importer.unique(Importer.slug(name), &usedMediaIds)
            media.append(MediaAsset(id: id, path: path, name: name, duration: avail?.duration ?? 0,
                                    width: canvas.width, height: canvas.height,
                                    fps: kind == .video && !isImage ? Importer.niceFps(Self.rate(ref["available_range"]) ?? canvas.fps) : 0,
                                    hasVideo: kind == .video, hasAudio: kind == .audio, isImage: isImage))
            mediaByPath[path] = media.count - 1
            availableStart[id] = avail?.start ?? 0
            if !Importer.exists(path), !missing.contains(path) { missing.append(path) }
            return id
        default:
            return nil
        }
    }

    func readTrack(_ track: [String: Any], kind: TrackKind, top: Bool) -> (clips: [Clip], disabled: [Clip], transitions: [Transition]) {
        var clips: [Clip] = [], disabled: [Clip] = []
        var transitions: [Transition] = []
        var items: [(id: String?, start: Seconds, end: Seconds)] = []
        var pending: [([String: Any], Int)] = []
        var cursor: Seconds = 0
        for item in Self.items(track) {
            let schema = Self.schema(item)
            let name = item["name"] as? String ?? ""
            if schema == "Transition" { pending.append((item, items.count)); continue }
            let range = Self.range(item["source_range"])
            let duration = schema == "Clip" ? (range?.duration ?? naturalDuration(item)) : naturalDuration(item)
            let start = cursor
            cursor += duration
            var made: Clip?
            switch schema {
            case "Clip":
                made = clip(item, kind: kind, start: start, duration: duration, range: range)
                if let c = made, top {
                    for m in item["markers"] as? [[String: Any]] ?? [] {
                        addMarker(m) { c.start + ($0 - (range?.start ?? 0)) / c.speed }
                    }
                }
            case "Gap":
                made = gapClip(item, kind: kind, start: start, duration: duration)
            case "Stack":
                let (tracks, trs) = readStack(item, top: false)
                let seqName = name.isEmpty ? "Nested \(sequences.count + 1)" : name
                let id = Importer.unique(Importer.slug(seqName), &usedSequenceIds)
                sequences.append(NestedSequence(id: id, name: seqName, tracks: tracks, transitions: trs))
                made = Clip(id: clipId(nil), kind: .sequence, name: name.isEmpty ? nil : name, mediaId: id, start: start, duration: duration, sourceIn: range?.start ?? 0)
            default:
                warnings.append("\(item["OTIO_SCHEMA"] as? String ?? "Item") \(name) in a track left as a gap")
            }
            guard var c = made, duration > 0 else { items.append((nil, start, start + duration)); continue }
            c.start = start
            c.duration = duration
            if item["enabled"] as? Bool == false { disabled.append(c); items.append((nil, start, start + duration)); continue }
            clips.append(c)
            items.append((c.id, start, start + duration))
        }
        if top {
            for m in track["markers"] as? [[String: Any]] ?? [] { addMarker(m) { $0 } }
        }
        let half = 0.5 / max(canvas.fps, 1)
        for (tr, index) in pending {
            let a = Self.time(tr["in_offset"]) ?? 0, b = Self.time(tr["out_offset"]) ?? 0
            let from = index > 0 ? items[index - 1].id : nil
            let to = index < items.count ? items[index].id : nil
            guard a + b > 0, from != nil || to != nil else { continue }
            var align = TransitionAlign.center
            if a < half { align = .start } else if b < half { align = .end } else if abs(a - b) > half {
                warnings.append("Uneven transition \(tr["name"] as? String ?? "") centered on its cut")
            }
            let name = (tr["name"] as? String ?? "").lowercased()
            var type = "dissolve"
            if name.contains("dip") || name.contains("fade to") { type = "dip" } else if tr["transition_type"] as? String != "SMPTE_Dissolve" && !name.contains("dissolve") {
                warnings.append("Transition \(tr["name"] as? String ?? tr["transition_type"] as? String ?? "") imported as a dissolve")
            }
            transitionCount += 1
            transitions.append(Transition(id: "tr\(transitionCount)", from: from, to: to, type: type, duration: a + b, align: align))
        }
        return (clips, disabled, transitions)
    }

    func clip(_ item: [String: Any], kind: TrackKind, start: Seconds, duration: Seconds, range: (start: Seconds, duration: Seconds)?) -> Clip? {
        let name = item["name"] as? String ?? ""
        guard let ref = activeReference(item), let id = mediaId(ref, clipName: name, kind: kind) else {
            warnings.append("Clip \(name) has no media file; left as a gap")
            if !name.isEmpty, !missing.contains(name) { missing.append(name) }
            return nil
        }
        let md = Self.cutline(item)
        var c = Clip(id: clipId(md["clipId"]), kind: .media, name: name.isEmpty ? nil : name, mediaId: id, start: start, duration: duration,
                     sourceIn: (range?.start ?? 0) - (availableStart[id] ?? 0))
        for e in item["effects"] as? [[String: Any]] ?? [] {
            switch Self.schema(e) {
            case "LinearTimeWarp":
                var s = Self.number(e["time_scalar"]) ?? 1
                if s < 0 { c.reverse = true; s = -s }
                if s < 0.01 || s > 100 {
                    warnings.append("Speed \(s)× on \(name) not kept")
                } else {
                    c.speed = Importer.niceSpeed(s)
                }
            case "FreezeFrame":
                warnings.append("Freeze frame on \(name) not kept")
            default:
                warnings.append("Effect \(e["effect_name"] as? String ?? e["OTIO_SCHEMA"] as? String ?? "") on \(name) not kept")
            }
        }
        if let v = Self.number(md["volume"]) { c.volume = v }
        if let f = Self.number(md["fadeIn"]) { c.fadeIn = f }
        if let f = Self.number(md["fadeOut"]) { c.fadeOut = f }
        if let b = (md["blend"] as? String).flatMap({ BlendMode(rawValue: $0) }) { c.blend = b }
        return c
    }

    /// Cutline writes titles, solids and adjustment clips as gaps with their kind in the metadata.
    func gapClip(_ item: [String: Any], kind: TrackKind, start: Seconds, duration: Seconds) -> Clip? {
        let md = Self.cutline(item)
        guard kind == .video, let k = (md["kind"] as? String).flatMap({ ClipKind(rawValue: $0) }) else { return nil }
        let name = item["name"] as? String
        let id = clipId(md["clipId"])
        var c: Clip
        switch k {
        case .text:
            let text = md["text"] as? String ?? name ?? ""
            c = Clip(id: id, kind: .text, name: name == text ? nil : name, start: start, duration: duration, text: TextSpec(text: text))
        case .solid:
            c = Clip(id: id, kind: .solid, name: name == "solid" ? nil : name, start: start, duration: duration, color: (md["color"] as? String).flatMap { RGBA(hex: $0) } ?? .black)
        case .adjustment:
            c = Clip(id: id, kind: .adjustment, name: name == "adjustment" ? nil : name, start: start, duration: duration)
            if !(md["effects"] as? [Any] ?? []).isEmpty { warnings.append("Effects of adjustment clip \(name ?? id) not kept") }
        default:
            warnings.append("\(k.rawValue.capitalized) clip \(name ?? id) can't be rebuilt from OTIO; left as a gap")
            return nil
        }
        if let f = Self.number(md["fadeIn"]) { c.fadeIn = f }
        if let f = Self.number(md["fadeOut"]) { c.fadeOut = f }
        return c
    }
}

// MARK: CMX 3600 EDL

enum EDLTimecode {
    static func dropFrames(_ nominal: Int) -> Int { nominal == 30 ? 2 : nominal == 60 ? 4 : 0 }

    /// Frame count of a timecode, counting drop-frame labels when `drop`.
    static func frames(_ h: Int, _ m: Int, _ s: Int, _ f: Int, nominal: Int, drop: Bool) -> Int {
        let base = ((h * 60 + m) * 60 + s) * nominal + f
        guard drop, dropFrames(nominal) > 0 else { return base }
        let minutes = h * 60 + m
        return base - dropFrames(nominal) * (minutes - minutes / 10)
    }

    /// Parses "hh:mm:ss:ff"; a ";" or "." marks drop frame.
    static func parse(_ s: String, nominal: Int, drop: Bool) -> (frames: Int, hour: Int, drop: Bool)? {
        let parts = s.split(whereSeparator: { ":;.,".contains($0) }).map { Int($0) }
        guard parts.count == 4, let h = parts[0], let m = parts[1], let sec = parts[2], let f = parts[3] else { return nil }
        let df = (drop || s.contains(";")) && dropFrames(nominal) > 0
        return (frames(h, m, sec, f, nominal: nominal, drop: df), h, df)
    }

    static func string(_ frames: Int, nominal: Int, drop: Bool) -> String {
        var f = max(0, frames)
        let d = dropFrames(nominal)
        if drop && d > 0 {
            let perMinute = nominal * 60 - d, perTen = nominal * 600 - d * 9
            let tens = f / perTen, rem = f % perTen
            f += d * 9 * tens + (rem > d ? d * ((rem - d) / perMinute) : 0)
        }
        let ff = f % nominal, ss = f / nominal % 60, mm = f / (nominal * 60) % 60, hh = f / (nominal * 3600)
        return String(format: "%02d:%02d:%02d", hh, mm, ss) + (drop && d > 0 ? ";" : ":") + String(format: "%02d", ff)
    }
}

extension Importer {
    /// CMX 3600 EDL at `fps`: TITLE, FCM, cut (C), dissolve (D), wipe (W) and key (K) events on V and A/A2/AA
    /// channels, M2 speed changes, and FROM/TO CLIP NAME, SOURCE FILE and LOC comments. Record times start
    /// at the hour of the first event. A dissolve starts at its edit and borrows the outgoing clip's media.
    ///
    /// Each source is looked up with `mediaResolver` by clip name, source file path, file name and reel, in that
    /// order. The project lists a placeholder MediaAsset for each id it uses (sized from the edit) to replace
    /// with the real one; sources it can't resolve but that name a SOURCE FILE get media at that path.
    public static func edl(_ text: String, fps: Double, mediaResolver: (String) -> String?) throws -> ImportResult {
        struct Line {
            var event: String
            var reel: String
            var channel: String
            var trans: String
            var transFrames: Int
            var src: (Int, Int)
            var rec: (Int, Int)
            var recHour: Int
            var drop: Bool
            var clipName: String?
            var sourceFile: String?
            var speed: Double?
        }
        let grid = FrameGrid(fps: fps)
        let rate = grid.rate
        let nominal = max(1, Int(rate.rounded()))
        var warnings: [String] = [], missing: [String] = []
        var title: String?
        var drop = false
        var lines: [Line] = []
        var locs: [(frames: Int, label: String)] = []
        var named: Int?

        let body = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (n, raw) in body.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("TITLE:") { title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
            if upper.hasPrefix("FCM:") { drop = !upper.contains("NON") && upper.contains("DROP"); continue }
            if line.hasPrefix("*") {
                let comment = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                let uc = comment.uppercased()
                func value(_ prefix: String) -> String { String(comment.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
                let current = lines.indices.reversed().prefix { lines[$0].event == lines.last?.event }.reversed().map { $0 }
                if uc.hasPrefix("FROM CLIP NAME:"), let i = current.first {
                    lines[i].clipName = value("FROM CLIP NAME:"); named = i
                } else if uc.hasPrefix("TO CLIP NAME:"), let i = current.last {
                    lines[i].clipName = value("TO CLIP NAME:"); named = i
                } else if uc.hasPrefix("SOURCE FILE:"), let i = named.flatMap({ current.contains($0) ? $0 : nil }) ?? current.last {
                    lines[i].sourceFile = value("SOURCE FILE:")
                } else if uc.hasPrefix("LOC:") {
                    let parts = value("LOC:").split(whereSeparator: \.isWhitespace).map(String.init)
                    if let first = parts.first, let tc = EDLTimecode.parse(first, nominal: nominal, drop: drop) {
                        let colors: Set<String> = ["RED", "GREEN", "BLUE", "CYAN", "MAGENTA", "YELLOW", "BLACK", "WHITE", "ORANGE", "PURPLE", "PINK"]
                        var rest = parts.dropFirst()
                        if let c = rest.first, colors.contains(c.uppercased()) { rest = rest.dropFirst() }
                        locs.append((tc.frames, rest.joined(separator: " ").isEmpty ? "Marker" : rest.joined(separator: " ")))
                    }
                } else if let r = comment.range(of: "|M:"), let last = lines.last {
                    let label = comment[r.upperBound...].components(separatedBy: " |").first?.trimmingCharacters(in: .whitespaces) ?? "Marker"
                    locs.append((last.rec.0, label))
                }
                continue
            }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.first?.uppercased() == "M2" {
                guard tokens.count >= 3, let v = Double(tokens[2]) else { warnings.append("Line \(n + 1): unreadable M2"); continue }
                let current = lines.indices.reversed().prefix { lines[$0].event == lines.last?.event }
                if let i = current.first(where: { lines[$0].reel == tokens[1] }) ?? current.first { lines[i].speed = v / rate }
                continue
            }
            guard let first = tokens.first, first.allSatisfy(\.isNumber), tokens.count >= 8 else { continue }
            var idx = 4
            var transFrames = 0
            if tokens.count >= 9, let d = Int(tokens[4]) { transFrames = d; idx = 5 }
            let tcs = tokens.dropFirst(idx).prefix(4).compactMap { EDLTimecode.parse($0, nominal: nominal, drop: drop) }
            guard tcs.count == 4 else { warnings.append("Line \(n + 1): unreadable event"); continue }
            lines.append(Line(event: first, reel: tokens[1], channel: tokens[2].uppercased(), trans: tokens[3].uppercased(), transFrames: transFrames,
                              src: (tcs[0].frames, tcs[1].frames), rec: (tcs[2].frames, tcs[3].frames), recHour: tcs[2].hour, drop: tcs[2].drop))
            named = nil
        }
        guard !lines.isEmpty else { throw EditError("No events in the EDL") }

        let firstLine = lines.min { $0.rec.0 < $1.rec.0 }!
        let origin = EDLTimecode.frames(firstLine.recHour, 0, 0, 0, nominal: nominal, drop: firstLine.drop)
        func seconds(_ f: Int) -> Seconds { Double(f * grid.num) / Double(grid.den) }
        func rec(_ f: Int) -> Seconds { seconds(f - origin) }

        // Media
        var media: [MediaAsset] = []
        var usedIds = Set<String>()
        var byPath: [String: String] = [:]
        func resolve(_ l: Line, video: Bool, audio: Bool) -> String? {
            var names: [String] = []
            if let c = l.clipName { names.append(c) }
            if let f = l.sourceFile {
                names.append(f)
                names.append((f as NSString).lastPathComponent)
                names.append(((f as NSString).lastPathComponent as NSString).deletingPathExtension)
            }
            names.append(l.reel)
            var id: String?
            for n in names where id == nil { id = mediaResolver(n) }
            var path = l.sourceFile ?? ""
            if id == nil, let f = l.sourceFile {
                path = f.hasPrefix("file:") ? (URL(string: f)?.path ?? f) : f
                if let known = byPath[path] { id = known } else {
                    let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    id = unique(slug(name), &usedIds)
                    byPath[path] = id
                    if !exists(path), !missing.contains(path) { missing.append(path) }
                }
            }
            guard let id else {
                let what = l.clipName ?? l.reel
                warnings.append("Event \(l.event): no media for \(what); left as a gap")
                if !missing.contains(what) { missing.append(what) }
                return nil
            }
            if let i = media.firstIndex(where: { $0.id == id }) {
                media[i].hasVideo = media[i].hasVideo || video
                media[i].hasAudio = media[i].hasAudio || audio
                if media[i].path.isEmpty { media[i].path = path }
            } else {
                usedIds.insert(id)
                let name = l.clipName.map { ($0 as NSString).deletingPathExtension } ?? l.reel
                media.append(MediaAsset(id: id, path: path, name: name, duration: 0, width: 1920, height: 1080, fps: niceFps(rate), hasVideo: video, hasAudio: audio))
            }
            return id
        }
        var extent: [String: Seconds] = [:]

        // Tracks by channel: video channels by number, then audio.
        struct Channel: Hashable { var kind: TrackKind; var n: Int }
        func channel(_ s: String) -> (main: Channel, audio: Bool)? {
            if s == "B" { return (Channel(kind: .video, n: 1), true) }
            let parts = s.split(separator: "/").map(String.init)
            var video: Int?, audio: [Int] = []
            for p in parts {
                if p.hasPrefix("V") { video = Int(p.dropFirst()) ?? 1 } else if p == "AA" { audio.append(1) } else if p.hasPrefix("A") { audio.append(Int(p.dropFirst()) ?? 1) }
            }
            if let video { return (Channel(kind: .video, n: video), !audio.isEmpty) }
            if let a = audio.first { return (Channel(kind: .audio, n: a), true) }
            return nil
        }
        var clips: [Channel: [Clip]] = [:]
        var transitions: [Transition] = []
        var count = 0
        let half = 0.5 / rate
        func isBlack(_ reel: String) -> Bool { ["BL", "BLK", "BLACK"].contains(reel.uppercased()) }
        func makeClip(_ l: Line, _ ch: (main: Channel, audio: Bool)) -> Clip? {
            guard !isBlack(l.reel), l.rec.1 > l.rec.0 else { return nil }
            guard let id = resolve(l, video: ch.main.kind == .video, audio: ch.audio) else { return nil }
            let duration = seconds(l.rec.1 - l.rec.0)
            count += 1
            var c = Clip(id: "c\(count)", kind: .media, name: l.clipName ?? l.reel, mediaId: id, start: rec(l.rec.0), duration: duration, sourceIn: seconds(l.src.0))
            var speed = l.speed ?? 1
            if l.speed == nil, l.src.1 != l.src.0, abs((l.src.1 - l.src.0) - (l.rec.1 - l.rec.0)) > 1 {
                speed = Double(l.src.1 - l.src.0) / Double(l.rec.1 - l.rec.0)
            }
            if speed < 0 { c.reverse = true; speed = -speed }
            if speed < 0.01 || speed > 100 {
                warnings.append("Event \(l.event): speed \(speed)× not kept")
                speed = 1
            }
            c.speed = niceSpeed(speed)
            if c.reverse { c.sourceIn -= duration * c.speed }
            extent[id] = max(extent[id] ?? 0, c.sourceOut)
            return c
        }

        var i = 0
        while i < lines.count {
            let l = lines[i]
            guard let ch = channel(l.channel) else {
                warnings.append("Event \(l.event): channel \(l.channel) not supported")
                i += 1
                continue
            }
            var fromLine: Line?
            var toLine = l
            if l.trans == "C", i + 1 < lines.count, lines[i + 1].event == l.event, lines[i + 1].trans != "C", lines[i + 1].channel == l.channel {
                fromLine = l
                toLine = lines[i + 1]
                i += 2
            } else {
                i += 1
            }
            if let f = fromLine, f.rec.1 > f.rec.0, let c = makeClip(f, ch) { clips[ch.main, default: []].append(c) }
            let code = toLine.trans
            guard code != "C" else {
                if let c = makeClip(toLine, ch) { clips[ch.main, default: []].append(c) }
                continue
            }
            var type: String? = "dissolve"
            if code.hasPrefix("W") {
                type = "wipe"
                warnings.append("Event \(toLine.event): wipe \(code) imported as a left-to-right wipe")
            } else if code.hasPrefix("K") {
                type = nil
                warnings.append("Event \(toLine.event): key not kept; imported as a cut")
            }
            let d = seconds(toLine.transFrames)
            let cut = rec(toLine.rec.0)
            var outgoing: Int?
            if fromLine.map({ !isBlack($0.reel) }) ?? true {
                outgoing = clips[ch.main]?.lastIndex { abs($0.end - cut) < half }
            }
            if isBlack(toLine.reel) {
                guard let o = outgoing, let type, d > 0 else { continue }
                let extend = min(d, seconds(toLine.rec.1 - toLine.rec.0))
                clips[ch.main]![o].duration += extend
                let c = clips[ch.main]![o]
                if let id = c.mediaId { extent[id] = max(extent[id] ?? 0, c.sourceOut) }
                transitions.append(Transition(id: "tr\(transitions.count + 1)", from: c.id, to: nil, type: type, duration: extend, align: .start))
                continue
            }
            guard let incoming = makeClip(toLine, ch) else { continue }
            clips[ch.main, default: []].append(incoming)
            guard let type, d > 0 else { continue }
            let from = outgoing.map { clips[ch.main]![$0] }
            if let f = from, let id = f.mediaId { extent[id] = max(extent[id] ?? 0, f.sourceOut + d * f.speed) }
            transitions.append(Transition(id: "tr\(transitions.count + 1)", from: from?.id, to: incoming.id, type: type, duration: d, align: .start))
        }

        for k in media.indices { media[k].duration = extent[media[k].id] ?? 0 }
        var tracks: [Track] = []
        let order = clips.keys.sorted { ($0.kind == .video ? 0 : 1, $0.n) < ($1.kind == .video ? 0 : 1, $1.n) }
        var v = 0, a = 0
        if !order.contains(where: { $0.kind == .video }) { tracks.append(Track(id: "V1", kind: .video, name: "Video 1")); v = 1 }
        for key in order {
            if key.kind == .video { v += 1 } else { a += 1 }
            let id = key.kind == .video ? "V\(v)" : "A\(a)"
            tracks.append(Track(id: id, kind: key.kind, name: "\(key.kind == .video ? "Video" : "Audio") \(key.n)", clips: clips[key]!.sorted { $0.start < $1.start }))
        }
        // Audio that repeats a video clip's or another channel's: the same source on the same record time.
        var seen: [Clip] = tracks.filter { $0.kind == .video }.flatMap(\.clips)
        for t in tracks.indices where tracks[t].kind == .audio {
            tracks[t].clips.removeAll { c in
                let dup = seen.contains { s in
                    s.mediaId == c.mediaId && abs(s.start - c.start) < half && abs(s.duration - c.duration) < half && abs(s.sourceIn - c.sourceIn) < half
                }
                if !dup { seen.append(c) }
                return dup
            }
        }
        tracks.removeAll { $0.kind == .audio && $0.clips.isEmpty }

        var p = Project(name: title ?? "EDL", canvas: Canvas(fps: niceFps(rate)))
        p.media = media
        p.tracks = tracks
        p.transitions = transitions
        p.markers = locs.enumerated().map { Marker(id: "marker\($0.offset + 1)", time: rec($0.element.frames), label: $0.element.label) }.sorted { $0.time < $1.time }
        finish(&p, &warnings)
        return ImportResult(project: p, warnings: warnings, missingMedia: missing)
    }
}

extension Project {
    /// CMX 3600 EDL of the main video track (V) and the first two audio tracks (A, A2), recorded from
    /// 01:00:00:00 in canvas frames (drop frame at 29.97 and 59.94). Each event names its clip and source
    /// file in comments, speed becomes an M2 line and markers LOC comments. Transitions become dissolves
    /// (wipes stay wipes) starting at the edit, so a centered one moves the edit to its start; transitions
    /// from or to nothing go through black. Only media clips are listed.
    public func edl(title: String) -> String {
        let grid = FrameGrid(fps: canvas.fps)
        let nominal = max(1, Int(grid.rate.rounded()))
        let drop = grid.num == 1001 && EDLTimecode.dropFrames(nominal) > 0
        let origin = EDLTimecode.frames(1, 0, 0, 0, nominal: nominal, drop: drop)
        func tc(_ f: Int) -> String { EDLTimecode.string(f, nominal: nominal, drop: drop) }
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        func reel(_ c: Clip) -> String {
            let name = c.mediaId.flatMap(mediaAsset)?.name ?? ""
            let r = String(name.uppercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }.prefix(8))
            return r.isEmpty ? "AX" : r
        }
        func clipName(_ c: Clip) -> String { c.name ?? c.mediaId.flatMap(mediaAsset)?.name ?? c.id }
        var out = ["TITLE: \(title)", "FCM: \(drop ? "DROP FRAME" : "NON-DROP FRAME")", ""]
        var event = 0
        func line(_ reel: String, _ ch: String, _ tr: String, _ dur: Int?, _ s0: Int, _ s1: Int, _ r0: Int, _ r1: Int) {
            let d = dur.map { String(format: "%03d", $0) } ?? "   "
            out.append("\(String(format: "%03d", event))  \(pad(reel, 8)) \(pad(ch, 5)) \(pad(tr, 4)) \(d) \(tc(s0)) \(tc(s1)) \(tc(r0 + origin)) \(tc(r1 + origin))")
        }
        func code(_ w: TransitionWindow) -> String { w.transition.type == "wipe" ? "W001" : "D" }

        var pendingMarkers = markers.filter { $0.time >= 0 }.sorted { $0.time < $1.time }
        func flushMarkers(before frame: Int?) {
            while let m = pendingMarkers.first, frame.map({ grid.frames(m.time) < $0 }) ?? true {
                out.append("* LOC: \(tc(grid.frames(m.time) + origin)) RED     \(m.label)")
                pendingMarkers.removeFirst()
            }
        }

        let video = tracks.first { $0.kind == .video }
        let audio = tracks.filter { $0.kind == .audio }.prefix(2)
        let channels: [(Track, String)] = (video.map { [($0, "V")] } ?? []) + audio.enumerated().map { ($0.element, $0.offset == 0 ? "A" : "A2") }
        let windows = transitionWindows
        for (track, ch) in channels {
            let clips = track.clips.filter { c in
                guard c.kind == .media, let m = c.mediaId.flatMap(mediaAsset) else { return false }
                return track.kind == .video || m.hasAudio
            }.sorted { $0.start < $1.start }
            let ids = Set(clips.map(\.id))
            let mine = windows.filter { $0.trackId == track.id }
            for c in clips {
                let inW = mine.first { $0.transition.to == c.id }
                let outW = mine.first { $0.transition.from == c.id }
                let pairedIn = inW.flatMap { w in w.transition.from.map { ids.contains($0) } == true ? w : nil }
                let fadeIn = inW.flatMap { $0.transition.from == nil ? $0 : nil }
                let pairedOut = outW.flatMap { w in w.transition.to.map { ids.contains($0) } == true ? w : nil }
                let fadeOut = outW.flatMap { $0.transition.to == nil ? $0 : nil }
                let r0 = grid.frames(pairedIn?.start ?? c.start)
                let r1 = grid.frames(pairedOut?.start ?? fadeOut?.start ?? c.end)
                guard r1 > r0 else { continue }
                let s0 = grid.frames(c.sourceTime(atTimeline: Double(r0) / grid.rate))
                let s1 = s0 + (r1 - r0)
                event += 1
                if let w = pairedIn, let from = w.transition.from.flatMap({ clip($0) }) {
                    let fs = grid.frames(from.sourceTime(atTimeline: Double(r0) / grid.rate))
                    line(reel(from), ch, "C", nil, fs, fs, r0, r0)
                    line(reel(c), ch, code(w), grid.frames(w.end - w.start), s0, s1, r0, r1)
                    out.append("* FROM CLIP NAME: \(clipName(from))")
                    out.append("* TO CLIP NAME: \(clipName(c))")
                } else if let w = fadeIn {
                    line("BL", ch, "C", nil, 0, 0, r0, r0)
                    line(reel(c), ch, code(w), grid.frames(w.end - w.start), s0, s1, r0, r1)
                    out.append("* TO CLIP NAME: \(clipName(c))")
                } else {
                    line(reel(c), ch, "C", nil, s0, s1, r0, r1)
                    out.append("* FROM CLIP NAME: \(clipName(c))")
                }
                if let path = c.mediaId.flatMap(mediaAsset)?.path, !path.isEmpty { out.append("* SOURCE FILE: \(path)") }
                if abs(c.speed - 1) > 1e-9 || c.reverse {
                    let v = c.speed * canvas.fps * (c.reverse ? -1 : 1)
                    out.append("M2   \(pad(reel(c), 8))       \(String(format: "%05.1f", v))                \(tc(s0))")
                }
                if ch == "V" { flushMarkers(before: r1) }
                if let w = fadeOut {
                    event += 1
                    let fs = grid.frames(c.sourceTime(atTimeline: Double(r1) / grid.rate))
                    let d = grid.frames(w.end - w.start)
                    line(reel(c), ch, "C", nil, fs, fs, r1, r1)
                    line("BL", ch, code(w), d, 0, d, r1, r1 + d)
                    out.append("* FROM CLIP NAME: \(clipName(c))")
                }
                out.append("")
            }
            if ch == "V" { flushMarkers(before: nil) }
        }
        if video == nil { flushMarkers(before: nil) }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: Subtitles

extension Importer {
    /// SubRip cues. Tolerates a BOM, CRLF, missing numbers or blank lines, "." for ",", positions after
    /// the times, and strips HTML-style and {\…} styling tags.
    public static func srt(_ text: String) throws -> [(start: Seconds, end: Seconds, text: String)] {
        try cues(text)
    }

    /// WebVTT cues. Skips the header, NOTE, STYLE and REGION blocks and cue identifiers, ignores cue
    /// settings, and strips voice, class, timestamp and styling tags.
    public static func vtt(_ text: String) throws -> [(start: Seconds, end: Seconds, text: String)] {
        try cues(text)
    }

    static func cues(_ text: String) throws -> [Cue] {
        let body = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var out: [Cue] = []
        var cur: (start: Seconds, end: Seconds, lines: [String])?
        func close() {
            if let c = cur {
                let lines = c.lines.map(cleanCueText).filter { !$0.isEmpty }
                if !lines.isEmpty, c.end > c.start { out.append((c.start, c.end, lines.joined(separator: "\n"))) }
            }
            cur = nil
        }
        for line in body.components(separatedBy: "\n") {
            if let t = cueTiming(line) {
                if var c = cur {
                    // No blank line before this cue: a number just above it is its index, not text.
                    if let last = c.lines.last, last.trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) { c.lines.removeLast() }
                    cur = c
                    close()
                }
                cur = (t.0, t.1, [])
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                close()
            } else if cur != nil {
                cur!.lines.append(line)
            }
        }
        close()
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty && !trimmed.isEmpty && !trimmed.uppercased().hasPrefix("WEBVTT") {
            throw EditError("No subtitle cues found")
        }
        return out
    }

    static func cueTiming(_ line: String) -> (Seconds, Seconds)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let right = line[arrow.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        guard let a = cueTime(left), let b = cueTime(right) else { return nil }
        return (a, b)
    }

    /// "01:02:03,456", "02:03.456", "1:02:03.4".
    static func cueTime(_ s: String) -> Seconds? {
        let parts = s.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let sec = Double(parts.last!), parts.dropLast().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let units = parts.dropLast().compactMap { Double($0) }
        return units.reduce(0) { $0 * 60 + $1 } * 60 + sec
    }

    static func cleanCueText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        for (entity, ch) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&lrm;", ""), ("&rlm;", ""), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: entity, with: ch)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}
