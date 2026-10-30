import Foundation

/// A timeline read from another tool.
public struct ImportResult: Sendable {
    public var project: Project
    /// What was dropped or approximated, one sentence each.
    public var warnings: [String]
    /// Offline media, once each: paths that don't exist on this machine, or the names of sources without a path.
    public var missingMedia: [String]

    public init(project: Project, warnings: [String] = [], missingMedia: [String] = []) {
        self.project = project
        self.warnings = warnings
        self.missingMedia = missingMedia
    }
}

/// Reads timelines (FCPXML, Final Cut Pro 7 XML, OpenTimelineIO, CMX 3600 EDL) and subtitles (SRT, WebVTT) written
/// by other tools. Media is never probed: durations, sizes and rates come from the file, and only file existence is
/// checked. Media that isn't found stays as offline media, with the clips' timing, so it can be relinked.
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
            if url.path.hasPrefix("/") {
                // file://localhost/D%3a/media/a.mov from Windows: "D:/media/a.mov".
                let p = url.path
                if p.count > 3, p.dropFirst().first!.isLetter, p.dropFirst(2).hasPrefix(":/") { return String(p.dropFirst()) }
                return p
            }
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

    /// A regular file (not a folder) at `path`.
    static func exists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return !path.isEmpty && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Whether `path` names `m`'s file: the file it plays or, for a mezzanine, the camera original.
    static func samePath(_ m: MediaAsset, _ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if m.path == path || m.conformPath == path { return true }
        guard path.hasPrefix("/") else { return false }
        func canonical(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }
        let p = canonical(path)
        return [m.path, m.conformPath].contains { $0.hasPrefix("/") && canonical($0) == p }
    }

    /// The last component of a POSIX or Windows path.
    static func fileName(_ path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    static let stillExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp", "bmp", "psd", "tga", "dpx", "exr"]

    /// Speeds that are a hair off a round value (from frame-rate arithmetic) snap to it.
    static func niceSpeed(_ s: Double) -> Double {
        let r = (s * 100).rounded() / 100
        return abs(s * 100 - r * 100) < 0.2 ? r : s
    }

    /// LUT files named beside a CDL, as disabled `color.lut` effects, since the CDL already carries their look.
    static func lutEffects(_ paths: [String]) -> [Effect] {
        paths.filter { !$0.isEmpty }.enumerated().map {
            Effect(id: $0.offset == 0 ? "lut" : "lut\($0.offset + 1)", type: "color.lut", enabled: false, params: ["file": .string($0.element)])
        }
    }

    /// A clip's interchange grade: its CDL and the LUT files named beside it. One LUT whose file exists comes back
    /// as the LUT itself when there is no CDL or the CDL is that LUT's own fit (as exporters write a lone LUT);
    /// otherwise the CDL is the grade and the LUTs stay disabled beside it.
    static func colorEffects(cdl: CDL?, luts: [String]) -> [Effect] {
        let luts = luts.filter { !$0.isEmpty }
        if luts.count == 1, exists(luts[0]) {
            let lut = Effect(id: "lut", type: "color.lut", params: ["file": .string(luts[0])])
            guard let cdl else { return [lut] }
            if let fit = Clip(id: "", kind: .media, start: 0, duration: 1, effects: [lut]).cdl, fit.distance(to: cdl) < 2e-3 { return [lut] }
        }
        return (cdl.map { [$0.effect(id: "cdl")] } ?? []) + lutEffects(luts)
    }

    /// The grade in a note or comment: `ASC_SOP … ASC_SAT …` and `LUT <path>` parts, separated by ";".
    static func noteColor(_ note: String) -> [Effect] {
        if let whole = gradeLUT(note) { return whole }
        let luts = note.components(separatedBy: ";").compactMap { part -> String? in
            let s = part.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.hasPrefix("LUT ") ? String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces) : nil
        }
        return colorEffects(cdl: CDL(text: note), luts: luts)
    }

    /// Removes media in `ids` no clip plays (baked graphics read back as their generators).
    static func dropUnused(_ p: inout Project, _ ids: Set<String>, missing: inout [String]) {
        guard !ids.isEmpty else { return }
        let used = Set((p.tracks + p.sequences.flatMap(\.tracks)).flatMap(\.clips).filter { $0.kind == .media }.compactMap(\.mediaId))
        let gone = p.media.filter { ids.contains($0.id) && !used.contains($0.id) }
        p.media.removeAll { m in gone.contains { $0.id == m.id } }
        missing.removeAll { path in gone.contains { $0.path == path || $0.name == path } }
    }

    /// The grade a note names as a baked .cube of the whole color stack, read back as that LUT.
    static func gradeLUT(_ note: String) -> [Effect]? {
        for part in note.components(separatedBy: ";") {
            let s = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix(Project.gradeLUTTag + " ") || s.hasPrefix(Project.gradeLUTTag + ":") {
                let path = String(s.dropFirst(Project.gradeLUTTag.count + 1)).trimmingCharacters(in: .whitespaces)
                return path.isEmpty ? nil : [Effect(id: "lut", type: "color.lut", params: ["file": .string(path)])]
            }
        }
        return nil
    }

    /// Holds the clip's first source frame for its whole length, silently.
    static func freeze(_ c: inout Clip) {
        c.speed = 1
        c.reverse = false
        c.anim["time.speed"] = Curve(keys: [CurveKey(t: 0, v: .number(0), ease: .hold)])
        c.volume = 0
    }

    /// Repeated warnings collapse into one line with a count, in first-seen order.
    static func condense(_ warnings: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for w in warnings {
            if counts[w] == nil { order.append(w) }
            counts[w, default: 0] += 1
        }
        return order.map { counts[$0]! > 1 ? "\($0) (×\(counts[$0]!))" : $0 }
    }

    /// "Effect X on a not kept", or "Effect X on 12 clips not kept: a, b, c, …" for many clips.
    static func summarize(_ what: String, clips: [String]) -> String {
        var names: [String] = []
        for c in clips where !names.contains(c) { names.append(c) }
        if clips.count == 1 { return "\(what) on \(names[0]) not kept" }
        let shown = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? ", …" : "")
        return "\(what) on \(clips.count) clips not kept: \(shown)"
    }

    /// Grows offline media so every clip and transition handle that reads it fits. Media read before its
    /// start gains frames at the front: clips' source times and the timecode move with them.
    static func fitOffline(_ p: inout Project, _ offline: Set<String>) {
        guard !offline.isEmpty else { return }
        var lo: [String: Seconds] = [:], hi: [String: Seconds] = [:]
        func scan(_ scope: Project) {
            let windows = scope.transitionWindows
            for c in scope.tracks.flatMap(\.clips) where c.kind == .media {
                guard let id = c.mediaId, offline.contains(id), let m = p.mediaAsset(id), !m.isImage else { continue }
                var a = min(c.sourceIn, c.sourceOut), b = max(c.sourceIn, c.sourceOut, c.sourceIn + 1 / max(m.fps, 24))
                if !c.reverse {
                    for w in windows {
                        if w.transition.to == c.id { a = min(a, c.sourceIn - w.head * max(c.speed(atLocal: 0), 0.01)) }
                        if w.transition.from == c.id { b = max(b, c.sourceOut + w.tail * max(c.speed(atLocal: c.duration), 0.01)) }
                    }
                }
                lo[id] = min(lo[id] ?? a, a)
                hi[id] = max(hi[id] ?? b, b)
            }
        }
        scan(p)
        for s in p.sequences { scan(p.inside(s)) }
        for i in p.media.indices {
            let id = p.media[i].id
            guard let low = lo[id], let high = hi[id] else { continue }
            let fps = max(p.media[i].fps > 0 ? p.media[i].fps : p.canvas.fps, 1)
            let shift = low < -1e-6 ? (-low * fps - 1e-6).rounded(.up) / fps : 0
            if shift > 0 {
                if let tc = p.media[i].timecodeStart { p.media[i].setTimecode(seconds: tc - shift, format: p.media[i].timecodeFormat(fallback: p.canvas.fps)) }
                func move(_ tracks: inout [Track]) {
                    for t in tracks.indices {
                        for c in tracks[t].clips.indices where tracks[t].clips[c].kind == .media && tracks[t].clips[c].mediaId == id {
                            tracks[t].clips[c].sourceIn += shift
                        }
                    }
                }
                move(&p.tracks)
                for s in p.sequences.indices { move(&p.sequences[s].tracks) }
                p.media[i].tags = p.media[i].tags?.map { MediaTag(label: $0.label, start: $0.start + shift, end: $0.end + shift, rating: $0.rating) }
            }
            p.media[i].duration = max(p.media[i].duration + shift, high + shift)
        }
    }

    /// Fills unknown media durations from the edit, sorts tracks, grows `offline` media to fit, and reports
    /// clips and transitions that don't fit. Transitions that can't be placed at all are dropped.
    static func finish(_ p: inout Project, _ warnings: inout [String], offline: Set<String> = []) {
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
        fitOffline(&p, offline)
        // A nested sequence ends at its last clip; what a use plays past that was empty.
        let frame = p.canvas.frameDuration
        func trimNested(_ tracks: inout [Track], label: String, in sequences: [NestedSequence]) {
            for t in tracks.indices {
                for c in tracks[t].clips.indices where tracks[t].clips[c].kind == .sequence {
                    let clip = tracks[t].clips[c]
                    guard let seq = sequences.first(where: { $0.id == clip.mediaId }) else { continue }
                    let left = seq.duration - clip.sourceIn
                    guard clip.duration > left + frame / 2, left > frame / 2 else { continue }
                    tracks[t].clips[c].duration = left
                    warnings.append("\(label)Nested \(seq.name) holds \(fmt2(left))s from \(fmt2(clip.sourceIn))s but \(clip.id) plays \(fmt2(clip.duration))s of it; trimmed to its content")
                }
            }
        }
        for i in p.sequences.indices {
            let all = p.sequences
            trimNested(&p.sequences[i].tracks, label: "In \(all[i].name): ", in: all)
        }
        trimNested(&p.tracks, label: "", in: p.sequences)

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
        warnings = condense(warnings)
    }

    /// Transitions once sound clips have folded into their pictures (`soundOf`, audio clip to picture clip): a
    /// crossfade between folded sounds moves to the pictures as an audio-only transition, and joins a dissolve over
    /// the same clips with the same timing into one. Other dissolves touching pictures whose sound came from
    /// elsewhere (`separate`) are picture only.
    static func foldTransitions(_ transitions: [Transition], soundOf: [String: String], separate: Set<String>, frame: Seconds) -> [Transition] {
        var out: [Transition] = [], sound: [Transition] = []
        for var tr in transitions {
            let moved = [tr.from, tr.to].contains { $0.map { soundOf[$0] != nil } ?? false }
            tr.from = tr.from.map { soundOf[$0] ?? $0 }
            tr.to = tr.to.map { soundOf[$0] ?? $0 }
            if moved { sound.append(tr); continue }
            if tr.part == .both, [tr.from, tr.to].contains(where: { $0.map(separate.contains) ?? false }) { tr.part = .video }
            out.append(tr)
        }
        func close(_ a: Seconds?, _ b: Seconds?) -> Bool { a == nil && b == nil || a.flatMap { x in b.map { abs(x - $0) < frame / 2 } } == true }
        for var tr in sound {
            if let i = out.firstIndex(where: { $0.from == tr.from && $0.to == tr.to && $0.part == .video && close($0.duration, tr.duration)
                && $0.align == tr.align && close($0.cutOffset, tr.cutOffset) }) {
                out[i].part = .both
            } else if tr.from != nil, tr.to != nil, !out.contains(where: { $0.from == tr.from && $0.to == tr.to && $0.hasAudio }) {
                tr.part = .audio
                out.append(tr)
            }
        }
        return out
    }

    /// Alignment, duration and cut offset of a transition running `before` seconds before its cut and `after`
    /// past it, covering the same frames; uneven ones keep the cut where it is (`Transition.cutOffset`).
    static func alignment(before a: Seconds, after b: Seconds, frame: Seconds) -> (align: TransitionAlign, duration: Seconds, cutOffset: Seconds?) {
        let half = frame / 2
        if a < half { return (.start, b, nil) }
        if b < half { return (.end, a, nil) }
        if abs(a - b) < half { return (.center, a + b, nil) }
        return (.center, a + b, a)
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

    /// Detached audio playing exactly under its own silenced video clip folds back into that clip.
    static func foldAudio(_ slots: inout [Slot]) {
        var removals: [(slot: Int, clip: Int)] = []
        for s in slots.indices where slots[s].kind == .audio {
            for (k, a) in slots[s].clips.enumerated() where a.kind == .media {
                for v in slots.indices where slots[v].kind == .video && slots[v].disabled == slots[s].disabled {
                    guard let i = slots[v].clips.firstIndex(where: { c in
                        c.kind == .media && c.volume == 0 && c.mediaId == a.mediaId && abs(c.start - a.start) < 1e-4 && abs(c.duration - a.duration) < 1e-4
                            && abs(c.sourceIn - a.sourceIn) < 1e-4 && c.speed == a.speed && c.reverse == a.reverse && !c.isRetimed
                    }) else { continue }
                    slots[v].clips[i].volume = a.volume
                    slots[v].clips[i].audioFadeIn = a.audioFadeIn
                    slots[v].clips[i].audioFadeOut = a.audioFadeOut
                    slots[v].clips[i].channels = a.channels
                    removals.append((s, k))
                    break
                }
            }
        }
        for r in removals.sorted(by: { ($0.slot, $0.clip) > ($1.slot, $1.clip) }) { slots[r.slot].clips.remove(at: r.clip) }
        slots.removeAll { $0.kind == .audio && $0.clips.isEmpty }
    }

    func tracks() -> [Track] {
        var slots = self.slots
        LaneBuilder.foldAudio(&slots)
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
    /// Final Cut Pro XML 1.6–1.11: a library/event/project, or a bare project or sequence. Without either, the
    /// event's clips are strung out on V1. Keywords and ratings become media tags.
    ///
    /// The primary storyline becomes V1; connected clips and secondary storylines at positive lanes become
    /// video tracks above it, audio at negative lanes audio tracks. Compound clips (`ref-clip`) become nested
    /// sequences. Times honour `tcStart` (kept as the canvas's start timecode), asset start timecode and
    /// `timeMap`s: constant speed, reverse, freezes, and ramps as held speeds between points. Multicam media become multicam sequences (an angle per `mc-angle`), and butting
    /// `mc-clip`s of one multicam one multicam clip cut at each `mc-source` change; `audio-channel-source` `srcCh`
    /// becomes `audio.channels`. Expanded audio (`audioStart`/`audioDuration`) becomes split edits, volume
    /// keyframes audio.volume animation, an `ASC_SOP` in a clip's note a `color.cdl` effect and a `LUT <path>`
    /// there a disabled `color.lut`. Assets keep their `audioRate` as the media's sample rate.
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
    var offline = Set<String>()
    var resources: [String: XMLElement] = [:]
    /// Asset resource id → media id and the asset's start timecode.
    var assets: [String: (id: String, start: Seconds)] = [:]
    var media: [MediaAsset] = []
    var sequences: [NestedSequence] = []
    var compounds: [String: (id: String, tcStart: Seconds)] = [:]
    /// Multicam media resource id → its sequence, `tcStart` and angle names by `angleID`.
    var multicams: [String: (id: String, tcStart: Seconds, angles: [String: String])] = [:]
    /// Drop frame of each media's timecode, from the `tcFormat` of its first clip.
    var dropFrame: [String: Bool] = [:]
    var usedSequenceIds = Set<String>()
    /// Media of baked graphics read back as the clips they stand for.
    var replaced = Set<String>()
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
        let browser = browserClips(root)
        var sequence: XMLElement?
        if let p = projects.first {
            guard let s = p.first("sequence") else { throw EditError("Project \(p.attr("name") ?? "") has no sequence") }
            sequence = s
            if projects.count > 1 { warnings.append("The file has \(projects.count) projects; imported \(p.attr("name") ?? "the first")") }
        } else if let s = descendants(root, "sequence").first {
            sequence = s
        } else if browser.isEmpty {
            throw EditError("No project, sequence or clips in the FCPXML")
        }
        let name = projects.first?.attr("name") ?? sequence?.attr("name") ?? descendants(root, "event").first?.attr("name") ?? "Imported"

        let formatId = sequence?.attr("format") ?? browser.lazy.compactMap { e in
            e.attr("format") ?? e.attr("ref").flatMap { self.resources[$0] }.flatMap { $0.first("sequence")?.attr("format") ?? $0.attr("format") }
        }.first
        let format = formatId.flatMap { resources[$0] }
        if let fd = time(format?.attr("frameDuration")), fd > 0 { grid = FrameGrid(fps: 1 / fd) }
        canvas = Canvas(width: Int(format?.attr("width") ?? "") ?? 1920, height: Int(format?.attr("height") ?? "") ?? 1080, fps: Importer.niceFps(grid.rate))
        if let tc = sequence?.attr("tcFormat") { canvas.dropFrame = Canvas.dropFrame(tc == "DF", fps: canvas.fps) }
        if let tc = time(sequence?.attr("tcStart")), tc >= 0 { canvas.timecodeStart = canvas.timecodeStart(frames: canvas.timecodeFormat.frameCount(tc)) }

        let main: Context
        if let sequence {
            main = readSequence(sequence)
            for e in browser { tagBrowserClip(e) }
        } else {
            warnings.append("The file has no project; its \(browser.count) event clips are strung out on V1 in order")
            main = nestedContext {
                var t: Seconds = 0
                for e in browser {
                    readItem(e, at: t, lane: 0, disabled: false)
                    t = snap(t + (time(e.attr("duration")) ?? 0))
                }
            }
        }
        for i in media.indices {
            guard let start = media[i].timecodeStart else { continue }
            let rate = media[i].fps > 0 ? media[i].fps : canvas.fps
            media[i].setTimecode(seconds: start, format: TimecodeFormat(fps: rate, dropFrame: dropFrame[media[i].id]))
        }
        for i in media.indices where media[i].tags != nil {
            var seen: [MediaTag] = []
            for t in media[i].tags! where !seen.contains(t) { seen.append(t) }
            media[i].tags = seen.sorted { ($0.start, $0.label) < ($1.start, $1.label) }
        }
        var p = Project(name: name, canvas: canvas)
        p.media = media
        p.tracks = main.lanes.tracks()
        p.transitions = main.transitions
        p.markers = main.markers.sorted { $0.time < $1.time }
        p.sequences = sequences
        p.joinMulticamPieces()
        Importer.dropUnused(&p, replaced, missing: &missing)
        Importer.finish(&p, &warnings, offline: offline)
        return ImportResult(project: p, warnings: warnings, missingMedia: missing)
    }

    /// Clips in events (or at the root) outside any project: the browser.
    func browserClips(_ root: XMLElement) -> [XMLElement] {
        let holders = [root] + root.elems.filter { $0.name == "library" } + descendants(root, "event")
        return holders.flatMap { h in h.elems.filter { FCPReader.storyNames.contains($0.name ?? "") && $0.name != "gap" } }
    }

    /// Keywords and ratings on `e` become tags of the media `clip` plays, in source time; `start` is `e`'s local start.
    func addTags(_ e: XMLElement, _ clip: Clip, start: Seconds, duration: Seconds) {
        let marks = e.elems.filter { $0.name == "keyword" || $0.name == "rating" }
        guard !marks.isEmpty else { return }
        guard clip.kind == .media, let i = media.firstIndex(where: { $0.id == clip.mediaId }) else {
            warnings.append("Keywords on \(clip.name ?? label(e)) not kept")
            return
        }
        for k in marks {
            let s = time(k.attr("start")) ?? start, d = time(k.attr("duration")) ?? duration
            let a = clip.sourceIn + (s - start) * clip.speed, b = a + d * clip.speed
            if k.name == "rating" {
                let value = k.attr("value") ?? "favorite"
                media[i].tags = (media[i].tags ?? []) + [MediaTag(label: k.attr("name") ?? value, start: a, end: b, rating: value)]
            } else {
                let labels = (k.attr("value") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                media[i].tags = (media[i].tags ?? []) + labels.map { MediaTag(label: $0, start: a, end: b) }
            }
        }
    }

    /// Keywords and ratings of a browser clip, which isn't placed on the timeline.
    func tagBrowserClip(_ e: XMLElement) {
        guard ["asset-clip", "clip", "sync-clip", "video", "audio"].contains(e.name ?? ""),
              e.elems.contains(where: { $0.name == "keyword" || $0.name == "rating" }) else { return }
        let start = time(e.attr("start")) ?? 0, duration = time(e.attr("duration")) ?? 0
        let saved = warnings
        var made: (Clip, TrackKind)?
        _ = nestedContext { made = build(e, start: start, duration: duration, place: { $0 }, lane: 0, disabled: false) }
        warnings = saved
        if let made { addTags(e, made.0, start: start, duration: duration) }
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
            let id = Importer.unique(Importer.slug(name), &used)
            if src == nil {
                warnings.append("Asset \(name) has no media path")
            }
            if !Importer.exists(path) {
                offline.insert(id)
                if src != nil, !missing.contains(path) { missing.append(path) }
            }
            let format = e.attr("format").flatMap { resources[$0] }
            let frameDuration = time(format?.attr("frameDuration"))
            let hasVideo = e.attr("hasVideo").map { $0 == "1" } ?? (format != nil || e.attr("videoSources") != nil)
            let hasAudio = e.attr("hasAudio").map { $0 == "1" } ?? (e.attr("audioSources") != nil)
            let duration = time(e.attr("duration"))
            let isImage = hasVideo && (duration == 0 || (frameDuration == nil && format?.attr("name") == "FFVideoFormatRateUndefined"))
            let fps = isImage || !hasVideo ? 0 : frameDuration.map { Importer.niceFps(1 / $0) } ?? 0
            var m = MediaAsset(id: id, path: path, name: name, duration: isImage ? 0 : duration ?? 0,
                               width: hasVideo ? Int(format?.attr("width") ?? "") ?? 0 : 0,
                               height: hasVideo ? Int(format?.attr("height") ?? "") ?? 0 : 0,
                               fps: fps, hasVideo: hasVideo, hasAudio: hasAudio, isImage: isImage)
            let start = time(e.attr("start")) ?? 0
            if start > 0, !isImage { m.timecodeStart = start }
            if let reel = e.first("metadata")?.elems.first(where: { $0.attr("key") == "com.apple.proapps.studio.reel" })?.attr("value"), !reel.isEmpty { m.reel = reel }
            if hasAudio, let tracks = e.attr("audioSources").flatMap({ Int($0) }), let total = e.attr("audioChannels").flatMap({ Int($0) }), tracks > 0, total > 0 {
                m.audioChannels = Importer.sourceChannels((0..<tracks).map { total / tracks + ($0 < total % tracks ? 1 : 0) })
            }
            if hasAudio, var rate = e.attr("audioRate")?.lowercased() {
                let k = rate.hasSuffix("k")
                if k { rate.removeLast() }
                if let r = Double(rate), r > 0 { m.sampleRate = k ? r * 1000 : r }
            }
            media.append(m)
            assets[rid] = (id, start)
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
            // Whole frames before the cut; a centered transition of odd length has the extra frame after it.
            let before = grid.frames(cut) - grid.frames(s), length = grid.frames(d)
            var align = TransitionAlign.center
            var cutOffset: Seconds?
            if before == 0 { align = .start } else if before == length { align = .end } else if before != length / 2 {
                if before > 0, before < length { cutOffset = snap(cut - s) } else { warnings.append("Transition \(label(tr)) isn't on a cut; centered on it") }
            }
            let video = tr.first("filter-video") != nil, audio = tr.first("filter-audio") != nil
            let name = tr.first("filter-video")?.attr("name") ?? tr.attr("name") ?? "Transition"
            let lower = name.lowercased()
            let type: String
            if lower.contains("fade to") || lower.contains("dip") {
                type = "dip"
            } else {
                type = "dissolve"
                if !lower.contains("dissolve"), video || !audio { warnings.append("Transition \(name) imported as a dissolve") }
            }
            var made = Transition(id: "tr\(ctx.transitions.count + 1)", from: prev?.clipId, to: next?.clipId, type: type, duration: snap(d), align: align,
                                  part: video == audio ? .both : video ? .video : .audio)
            made.cutOffset = prev?.clipId != nil && next?.clipId != nil ? cutOffset : nil
            ctx.transitions.append(made)
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
                addTags(e, clip, start: start, duration: duration)
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
        // The clip Cutline wrote whole: a title, solid, generator or baked graphic.
        if let json = e.first("metadata")?.elems.first(where: { $0.attr("key") == Project.fcpClipKey })?.attr("value"),
           let c = Project.restoredClip(json: json, placed: Clip(id: "", kind: .media, start: 0, duration: duration)) {
            if let ref = e.attr("ref"), let asset = assets[ref] { replaced.insert(asset.id) }
            return (c, .video)
        }
        switch e.name ?? "" {
        case "asset-clip", "video", "audio": return mediaClip(e, start: start, duration: duration)
        case "clip", "sync-clip": return containerClip(e, start: start, duration: duration, place: place, lane: lane, disabled: disabled)
        case "ref-clip": return refClip(e, start: start)
        case "title": return (titleClip(e), .video)
        case "gap": return nil
        case "mc-clip": return mcClip(e, start: start)
        default:
            warnings.append("\(e.name ?? "Element") \(label(e)) isn't supported; left as a gap")
            return nil
        }
    }

    /// A `timeMap`'s points, local time to source time, in time order; empty without one.
    func timePoints(_ e: XMLElement) -> [(t: Seconds, v: Seconds)] {
        guard let tm = e.first("timeMap") else { return [] }
        return tm.elems.filter { $0.name == "timept" }.compactMap { p -> (t: Seconds, v: Seconds)? in
            guard let t = time(p.attr("time")), let v = time(p.attr("value")) else { return nil }
            return (t, v)
        }.sorted { $0.t < $1.t }
    }

    /// Local time → source time and the constant speed of a `timeMap`.
    func timeMap(_ e: XMLElement) -> (map: (Seconds) -> Seconds, speed: Double) {
        guard e.first("timeMap") != nil else { return ({ $0 }, 1) }
        let pts = timePoints(e)
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

    /// A compound or multicam clip's constant speed; sequence clips don't play reversed.
    func sequenceSpeed(_ clip: inout Clip, _ speed: Double, _ e: XMLElement) {
        guard abs(speed - 1) > 1e-6 else { return }
        if speed < 0 {
            warnings.append("Reverse on \(label(e)) not kept; it plays forward at \(String(format: "%.3g", -speed))×")
        }
        clampSpeed(&clip, abs(speed), e)
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
            if res?.name == "effect", (res?.attr("uid") ?? "").contains("Solids.localized") || res?.attr("name") == "Custom" {
                let v = (e.elems.first { $0.name == "param" && $0.attr("name") == "Color" }?.attr("value") ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
                var clip = Clip(id: "", kind: .solid, name: e.attr("name"), start: 0, duration: duration,
                                color: v.count >= 3 ? RGBA(r: v[0], g: v[1], b: v[2], a: v.count > 3 ? v[3] : 1) : .black)
                if clip.name == "Solid" { clip.name = nil }
                adjust(e, &clip)
                return (clip, .video)
            }
            if res?.name == "effect" {
                warnings.append("Generator \(res?.attr("name") ?? label(e)) left as a gap")
            } else {
                warnings.append("\(label(e)) refers to missing resource \(e.attr("ref") ?? "nil"); left as a gap")
            }
            return nil
        }
        var clip = Clip(id: "", kind: .media, name: e.attr("name") ?? m.name, mediaId: m.id, start: 0, duration: duration)
        if let tc = e.attr("tcFormat"), dropFrame[m.id] == nil { dropFrame[m.id] = tc == "DF" }
        if !m.isImage {
            let pts = timePoints(e)
            if !pts.isEmpty {
                // Speed, reverse, freeze or ramp from the map, in the clip's local seconds and the asset's own time.
                if let w = Importer.retime(&clip, map: pts.map { ($0.t - start, $0.v - asset.start) }, tolerance: 0.1 / max(canvas.fps, 1)) { warnings.append(w) }
            } else {
                clip.sourceIn = start - asset.start
            }
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
        var hosted: (inner: XMLElement, offset: Seconds)?
        if laneless.isEmpty, let gap = e.elems.first(where: { $0.name == "gap" && $0.attr("lane") == nil }),
           let k = gap.elems.first(where: { content.contains($0.name ?? "") && $0.attr("lane") != nil }) {
            // Final Cut's detached audio: a clip holding a gap with the sound connected to it.
            hosted = (k, (time(gap.attr("offset")) ?? 0) + (time(k.attr("offset")) ?? 0) - (time(gap.attr("start")) ?? 0))
        }
        if let inner = hosted?.inner ?? laneless.first(where: { $0.name != "audio" }) ?? laneless.first {
            let innerOffset = hosted?.offset ?? time(inner.attr("offset")) ?? 0, innerStart = time(inner.attr("start")) ?? 0
            let innerPlace: (Seconds) -> Seconds = { place(innerOffset + ($0 - innerStart)) }
            guard let made = build(inner, start: innerStart + (local - innerOffset), duration: duration * abs(outerSpeed), place: innerPlace, lane: lane, disabled: disabled) else { return nil }
            var clip = made.0
            if abs(outerSpeed - 1) > 1e-9 { clampSpeed(&clip, (clip.reverse ? -clip.speed : clip.speed) * outerSpeed, e) }
            clip.name = e.attr("name") ?? clip.name
            let ref = inner.attr("ref")
            // A clip showing only the picture of a file leaves its sound to a detached audio clip, if any.
            if inner.name == "video", hosted == nil, clip.kind == .media, clip.mediaId.flatMap({ id in media.first { $0.id == id } })?.hasAudio == true,
               !laneless.contains(where: { $0.name == "audio" && $0.attr("ref") == ref }),
               !inner.elems.contains(where: { $0.name == "audio" && $0.attr("ref") == ref }) {
                clip.volume = 0
            }
            adjust(e, &clip)
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
        var clip = Clip(id: "", kind: .sequence, name: e.attr("name") ?? res.attr("name"), mediaId: seq.id, start: 0, duration: 0, sourceIn: map(start) - seq.tcStart)
        sequenceSpeed(&clip, speed, e)
        if e.attr("srcEnable") == "video" { clip.volume = 0 }
        adjust(e, &clip)
        return (clip, e.attr("srcEnable") == "audio" ? .audio : .video)
    }

    /// A multicam clip: its `multicam` media becomes a multicam sequence with an angle per `mc-angle`, shared by every
    /// use; the clip plays the `mc-source` angles it enables (picture adjustments from the picture's source).
    func mcClip(_ e: XMLElement, start: Seconds) -> (Clip, TrackKind)? {
        guard let ref = e.attr("ref"), let res = resources[ref], let mc = res.first("multicam") else {
            warnings.append("Multicam clip \(label(e)) refers to missing media \(e.attr("ref") ?? "nil"); left as a gap")
            return nil
        }
        let known: (id: String, tcStart: Seconds, angles: [String: String])
        if let k = multicams[ref] {
            known = k
        } else {
            let tc = time(mc.attr("tcStart")) ?? 0
            var tracks: [Track] = [], angles: [MulticamAngle] = [], names: [String: String] = [:]
            for (n, a) in mc.elems.filter({ $0.name == "mc-angle" }).enumerated() {
                var name = a.attr("name").flatMap { $0.isEmpty ? nil : $0 } ?? "Angle \(n + 1)"
                while angles.contains(where: { $0.name == name }) { name += " \(n + 1)" }
                let c = nestedContext { readSpine(a, place: { $0 - tc }, lane: 0, disabled: false, storyline: false) }
                let clips = c.lanes.tracks().flatMap(\.clips).filter { $0.kind == .media }.sorted { $0.start < $1.start }
                guard let first = clips.first, let m = media.first(where: { $0.id == first.mediaId }) else {
                    warnings.append("Angle \(name) of multicam \(res.attr("name") ?? "") has no media; left out")
                    continue
                }
                let trackId = "angle\(angles.count + 1)"
                tracks.append(Track(id: trackId, kind: m.hasVideo ? .video : .audio, name: name, clips: clips))
                angles.append(MulticamAngle(name: name, track: trackId, mediaId: m.id, offset: first.sourceIn - first.start, video: m.hasVideo, audio: m.hasAudio))
                names[a.attr("angleID") ?? name] = name
            }
            guard angles.contains(where: \.video) else {
                warnings.append("Multicam clip \(label(e)) has no video angle; left as a gap")
                return nil
            }
            let name = res.attr("name") ?? e.attr("name") ?? "Multicam"
            let id = Importer.unique(Importer.slug(name), &usedSequenceIds)
            var seq = NestedSequence(id: id, name: name, tracks: tracks)
            seq.multicam = MulticamSetup(angles: angles, audio: angles.first(where: \.audio).map { [$0.name] } ?? [], sync: "timecode")
            sequences.append(seq)
            known = (id, tc, names)
            multicams[ref] = known
        }
        let sources = e.elems.filter { $0.name == "mc-source" }
        func enabled(_ kinds: Set<String>) -> [XMLElement] { sources.filter { kinds.contains($0.attr("srcEnable") ?? "all") && known.angles[$0.attr("angleID") ?? ""] != nil } }
        let setup = sequences.first { $0.id == known.id }?.multicam
        let pictureSource = enabled(["all", "video"]).first
        let picture = pictureSource.flatMap { known.angles[$0.attr("angleID")!] } ?? setup?.videoAngles.first?.name ?? ""
        let sound = enabled(["all", "audio"]).compactMap { known.angles[$0.attr("angleID")!] }
        let (map, speed) = timeMap(e)
        var clip = Clip(id: "", kind: .sequence, name: e.attr("name") ?? res.attr("name"), mediaId: known.id, start: 0, duration: 0, sourceIn: map(start) - known.tcStart)
        sequenceSpeed(&clip, speed, e)
        clip.multicam = MulticamSwitch(cuts: [AngleCut(at: 0, angle: picture)], audio: sources.isEmpty ? nil : sound)
        if clip.name == res.attr("name") { clip.name = nil }
        adjust(e, &clip)
        if let pictureSource { adjust(pictureSource, &clip) }
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

    /// Transform, crop, opacity, volume, split-edit audio, a CDL in the note and audio enables; reports effects it can't carry.
    func adjust(_ e: XMLElement, _ clip: inout Clip, positioned: Bool = true) {
        let w = Double(canvas.width), h = Double(canvas.height)
        let what = clip.name.map { "\"\($0)\"" } ?? label(e)
        let start = time(e.attr("start")) ?? 0
        if let a0 = time(e.attr("audioStart")), let ad = time(e.attr("audioDuration")), let d = time(e.attr("duration")) {
            clip.audioLead = snap(start - a0)
            clip.audioLag = snap(a0 + ad - start - d)
        }
        if let note = e.first("note")?.stringValue { clip.effects += Importer.noteColor(note) }
        if let role = e.attr("audioRole"), !role.isEmpty { clip.role = role }
        var channels: [(enabled: Bool, src: [Int]?)] = []
        for k in e.elems {
            switch k.name ?? "" {
            case "adjust-transform":
                if positioned, let p = pair(k.attr("position")) {
                    clip.transform.x = p.0 / 100 * h / w
                    clip.transform.y = -p.1 / 100
                }
                if let s = pair(k.attr("scale")) {
                    if abs(abs(s.0) - abs(s.1)) > 1e-3 * max(abs(s.0), abs(s.1)), clip.transform.fit == .fit {
                        // An uneven scale of the fit picture: a stretch, else averaged.
                        let m = clip.mediaId.flatMap { id in media.first { $0.id == id } }
                        if canvas.setConform(&clip, media: m, x: abs(s.0), y: abs(s.1)) != nil {
                            clip.transform.scale = (abs(s.0) + abs(s.1)) / 2
                            warnings.append("Non-uniform scale on \(what) averaged")
                        }
                    } else {
                        if abs(abs(s.0) - abs(s.1)) > 1e-3 { warnings.append("Non-uniform scale on \(what) averaged") }
                        clip.transform.scale = (abs(s.0) + abs(s.1)) / 2
                    }
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
                let base = clip.volume
                if let a = k.attr("amount") { clip.volume *= Project.gain(decibels: a) }
                for param in k.elems where param.name == "param" {
                    if let f = time(param.first("fadeIn")?.attr("duration")) { clip.audioFadeIn = f }
                    if let f = time(param.first("fadeOut")?.attr("duration")) { clip.audioFadeOut = f }
                    guard let anim = param.first("keyframeAnimation"), base > 0 else { continue }
                    let keys = anim.elems.filter { $0.name == "keyframe" }.compactMap { kf -> CurveKey? in
                        guard let t = time(kf.attr("time")), let v = kf.attr("value") else { return nil }
                        return CurveKey(t: snap(t - start), v: .number(base * Project.gain(decibels: v)), ease: .linear)
                    }
                    if !keys.isEmpty { clip.anim["audio.volume"] = Curve(keys: keys) }
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
                let src = k.attr("srcCh").map { $0.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) } }
                channels.append((k.attr("enabled") != "0" && k.attr("active") != "0", src.flatMap { $0.contains(nil) ? nil : $0.compactMap { $0 } }))
            case "filter-video", "filter-audio":
                warnings.append("Effect \(k.attr("name") ?? k.attr("ref") ?? "") on \(what) not kept")
            case let n where n.hasPrefix("adjust-"):
                warnings.append("\(n) on \(what) not kept")
            default:
                break
            }
        }
        let heard = channels.filter(\.enabled)
        let count = clip.mediaId.flatMap { id in media.first { $0.id == id } }?.sourceChannelCount ?? 0
        if !channels.isEmpty, heard.isEmpty {
            clip.volume = 0
        } else if clip.kind == .media, !heard.isEmpty, heard.allSatisfy({ $0.src != nil }) {
            var src: [Int] = []
            for n in heard.flatMap({ $0.src! }) where !src.contains(n) { src.append(n) }
            let whole = src == Array(1...max(count, 2)) || (src.isEmpty)
            if !whole {
                let raw = src.count == 1 ? "ch\(src[0])" : src.count == 2 && heard.count == 1 ? "ch\(src[0])+ch\(src[1])" : "mix:" + src.map(String.init).joined(separator: ",")
                clip.channels = ChannelRouting(rawValue: raw)
            }
        } else if heard.count < channels.count {
            warnings.append("Some audio channels of \(what) are disabled; all are kept")
        }
        if let raw = e.first("metadata")?.elems.first(where: { $0.attr("key") == Project.fcpChannelsKey })?.attr("value"), let ch = ChannelRouting(rawValue: raw) { clip.channels = ch }
    }
}

// MARK: OpenTimelineIO

extension Importer {
    /// OpenTimelineIO JSON: a Timeline (or a SerializableCollection holding one) whose Stack holds Video and
    /// Audio tracks. Clips (Clip.1 `media_reference`, Clip.2 `media_references`) with External and ImageSequence
    /// references (Missing and Generator ones become offline media), gaps, dissolves, LinearTimeWarp speed and
    /// freeze frames, markers, and nested Stacks and Tracks (as nested sequences; items directly in a stack get
    /// a track each). Resolve's per-clip volume is kept and its untouched clip properties skipped. Audio clips
    /// that only repeat a video clip's sound are folded into it. Cutline's own metadata (clip ids, titles,
    /// volumes, sequence ids) is read back when present. `global_start_time` becomes the canvas's start timecode.
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
    var mediaByKey: [String: Int] = [:]
    var availableStart: [String: Seconds] = [:]
    var offline = Set<String>()
    var usedMediaIds = Set<String>(), usedSequenceIds = Set<String>(), usedClipIds = Set<String>()
    var sequences: [NestedSequence] = []
    /// Cutline sequence ids written in stack metadata → imported sequence ids, so every use shares one sequence.
    var sequenceIds: [String: String] = [:]
    var markers: [Marker] = []
    var clipCount = 0, transitionCount = 0
    var canvas = Canvas()
    /// Effects that couldn't be carried, by name, with the clips they were on.
    var dropped: [(name: String, clips: [String])] = []

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
    static func path(_ d: [String: Any]?, _ keys: [String]) -> Any? {
        var cur: Any? = d
        for k in keys { cur = (cur as? [String: Any])?[k] }
        return cur
    }

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
        let fcp = Self.path(timeline, ["metadata", "fcp_xml", "media", "video", "format", "samplecharacteristics"]) as? [String: Any]
        canvas = Canvas(width: Int(Self.number(md["width"]) ?? Self.number(fcp?["width"]) ?? 1920),
                        height: Int(Self.number(md["height"]) ?? Self.number(fcp?["height"]) ?? 1080),
                        fps: Importer.niceFps(fps), background: (md["background"] as? String).flatMap { RGBA(hex: $0) } ?? .black)
        canvas.dropFrame = md["dropFrame"] as? Bool
        if let start = Self.time(timeline["global_start_time"]), start >= 0 {
            canvas.timecodeStart = canvas.timecodeStart(frames: canvas.timecodeFormat.frameCount(start))
        }

        let (tracks, transitions) = readStack(stack, top: true)
        for m in stack["markers"] as? [[String: Any]] ?? [] { addMarker(m, at: { $0 }) }

        var p = Project(name: (timeline["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Imported", canvas: canvas)
        p.media = media
        p.tracks = tracks.contains(where: { $0.kind == .video }) ? tracks : [Track(id: "V1", kind: .video, name: "Main")] + tracks
        p.transitions = transitions
        p.markers = markers.sorted { $0.time < $1.time }
        p.sequences = sequences
        if let g = Self.number(md["masterGainDb"]) { p.master.gainDb = g }
        for d in dropped { warnings.append(Importer.summarize(d.name, clips: d.clips)) }
        Importer.finish(&p, &warnings, offline: offline)
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
        let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (m["comment"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Marker"
        markers.append(Marker(id: "marker\(markers.count + 1)", time: map(r.start), label: name))
    }

    func drop(_ effect: String, on clip: String) {
        if let i = dropped.firstIndex(where: { $0.name == effect }) { dropped[i].clips.append(clip) } else { dropped.append((effect, [clip])) }
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
        /// Crossfades on the sound of video tracks, between the pictures their clips carry.
        var embedded: [Transition] = []
        for item in Self.items(stack) {
            var child = item
            switch Self.schema(item) {
            case "Track": break
            case "Gap": continue
            case "Clip", "Stack":
                // An item placed directly in a stack plays from the stack's start on a track of its own.
                child = ["OTIO_SCHEMA": "Track.1", "name": item["name"] ?? "", "kind": "Video", "children": [item]]
            default:
                warnings.append("\(item["OTIO_SCHEMA"] as? String ?? "Item") directly in a stack not kept")
                continue
            }
            let kind: TrackKind = (child["kind"] as? String)?.lowercased() == "audio" ? .audio : .video
            let md = Self.cutline(child)
            if md["embeddedAudio"] as? Bool == true {
                for item in Self.items(child) where Self.schema(item) == "Clip" {
                    if let id = mediaId(activeReference(item), clipName: item["name"] as? String ?? "", kind: .audio) { linked.insert(id) }
                }
                embedded += soundTransitions(child)
                continue
            }
            let enabled = child["enabled"] as? Bool ?? true
            let name = (child["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (kind == .video ? "Video" : "Audio")
            var track = Track(id: "", kind: kind, name: name, muted: kind == .audio && !enabled, hidden: kind == .video && !enabled,
                              volume: Self.number(md["volume"]) ?? 1)
            track.volumeCurve = Self.decode(Curve.self, md["volumeCurve"])
            var read = readTrack(child, kind: kind, top: top)
            // Cutline writes the sound of audio clips over their audio range.
            if kind == .audio {
                // The picture lands on the frame its item's sound started a split before.
                let grid = FrameGrid(fps: canvas.fps)
                func snap(_ t: Seconds) -> Seconds { Double(grid.frames(t) * grid.num) / Double(grid.den) }
                for i in read.clips.indices {
                    let c = read.clips[i], lead = c.audioLead, lag = c.audioLag
                    guard lead != 0 || lag != 0, c.duration - lead - lag > 0 else { continue }
                    let start = snap(c.start + lead), end = snap(c.end - lag)
                    read.clips[i].start = start
                    read.clips[i].duration = end - start
                    read.clips[i].sourceIn += (start - c.start) * c.speed
                }
            }
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
        for tr in embedded where !transitions.contains(where: { $0.from == tr.from && $0.to == tr.to && $0.hasAudio }) { transitions.append(tr) }

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

    /// The media a reference points at. References without a usable file (missing, generator, empty URL)
    /// become offline media named after the reference or clip, sized from their available range.
    func mediaId(_ ref: [String: Any]?, clipName: String, kind: TrackKind) -> String? {
        let avail = ref.flatMap { Self.range($0["available_range"]) }
        let availRate = ref.flatMap { Self.rate($0["available_range"]) }
        let refName = (ref?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch ref.map(Self.schema) {
        case "ExternalReference":
            guard let url = ref?["target_url"] as? String, !url.isEmpty else { break }
            let path = Importer.resolvePath(url, base: base, warnings: &warnings)
            let file = (path as NSString).lastPathComponent
            var name = refName ?? (clipName.isEmpty ? file : clipName)
            if name == file { name = (file as NSString).deletingPathExtension }
            let isImage = Importer.stillExtensions.contains((file as NSString).pathExtension.lowercased())
                && (avail.map { $0.duration <= 1.5 / max(availRate ?? canvas.fps, 1) } ?? true)
            return addMedia(key: path, path: path, name: name, avail: avail, rate: availRate, kind: kind, isImage: isImage, shown: path, ref: ref)
        case "ImageSequenceReference":
            guard let r = ref, let baseURL = r["target_url_base"] as? String else { break }
            let prefix = r["name_prefix"] as? String ?? "", suffix = r["name_suffix"] as? String ?? ""
            let first = Int(Self.number(r["start_frame"]) ?? 1), pad = Int(Self.number(r["frame_zero_padding"]) ?? 0)
            let digits = String(first)
            let frame = String(repeating: "0", count: max(0, pad - digits.count)) + digits
            let folder = Importer.resolvePath(baseURL, base: base, warnings: &warnings)
            let path = (folder as NSString).appendingPathComponent(prefix + frame + suffix)
            var name = refName ?? (clipName.isEmpty ? prefix : clipName)
            while let last = name.last, ".-_ ".contains(last) { name.removeLast() }
            return addMedia(key: path, path: path, name: name.isEmpty ? "Sequence" : name, avail: avail, rate: Self.number(r["rate"]) ?? availRate,
                            kind: kind, isImage: false, shown: path)
        default:
            break
        }
        let name = refName ?? (clipName.isEmpty ? "Offline" : clipName)
        return addMedia(key: "\u{0}" + name, path: name, name: (name as NSString).deletingPathExtension, avail: avail, rate: availRate, kind: kind, isImage: false, shown: name)
    }

    func addMedia(key: String, path: String, name: String, avail: (start: Seconds, duration: Seconds)?, rate: Double?, kind: TrackKind, isImage: Bool, shown: String, ref: [String: Any]? = nil) -> String {
        if let i = mediaByKey[key] {
            if kind == .video { media[i].hasVideo = true } else { media[i].hasAudio = true }
            return media[i].id
        }
        let id = Importer.unique(Importer.slug(name), &usedMediaIds)
        var m = MediaAsset(id: id, path: path, name: name, duration: isImage ? 0 : avail?.duration ?? 0,
                           width: canvas.width, height: canvas.height,
                           fps: kind == .video && !isImage ? Importer.niceFps(rate ?? canvas.fps) : 0,
                           hasVideo: kind == .video, hasAudio: kind == .audio, isImage: isImage)
        if let s = avail?.start, s > 0, !isImage {
            let label = Self.path(ref, ["metadata", "cutline", "timecode"]) as? String
            m.setTimecode(seconds: s, format: TimecodeFormat(fps: rate ?? canvas.fps, dropFrame: label.map(TimecodeFormat.isDropLabel)))
        }
        if let reel = Self.path(ref, ["metadata", "cutline", "reel"]) as? String, !reel.isEmpty { m.reel = reel }
        if let layout = Self.path(ref, ["metadata", "cutline", "audioChannels"]) as? [Any] { m.audioChannels = Importer.sourceChannels(layout.compactMap { Self.number($0).map { Int($0) } }) }
        media.append(m)
        mediaByKey[key] = media.count - 1
        availableStart[id] = isImage ? 0 : avail?.start ?? 0
        if !Importer.exists(path) {
            offline.insert(id)
            if !missing.contains(shown) { missing.append(shown) }
        }
        return id
    }

    func readTrack(_ track: [String: Any], kind: TrackKind, top: Bool) -> (clips: [Clip], disabled: [Clip], transitions: [Transition]) {
        var clips: [Clip] = [], disabled: [Clip] = []
        var transitions: [Transition] = []
        var items: [(id: String?, start: Seconds, end: Seconds)] = []
        var pending: [([String: Any], Int)] = []
        var cursor: Seconds = 0
        let frame = 1 / max(canvas.fps, 1)
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
                        addMarker(m) { c.start + ($0 - (range?.start ?? self.availableStart[c.mediaId ?? ""] ?? 0)) / c.speed }
                    }
                }
            case "Gap":
                made = gapClip(item, kind: kind, start: start, duration: duration)
            case "Stack", "Track":
                let stack = schema == "Stack" ? item : ["OTIO_SCHEMA": "Stack.1", "name": name, "children": [item]]
                let (tracks, trs) = readStack(stack, top: false)
                let seqName = name.isEmpty ? "Nested \(sequences.count + 1)" : name
                let content = tracks.flatMap(\.clips).map(\.end).max() ?? 0
                let offset = range?.start ?? 0
                if content <= offset + frame / 2 {
                    warnings.append("Nested \(seqName) has nothing in it; kept as offline media")
                    if let id = mediaId(nil, clipName: seqName, kind: kind) {
                        made = Clip(id: clipId(nil), kind: .media, name: seqName, mediaId: id, start: start, duration: duration, sourceIn: offset)
                    }
                    break
                }
                let md = Self.cutline(item)
                let named = (md["sequenceName"] as? String) ?? seqName
                let id: String
                if let mc = md["multicam"] as? [String: Any], let restored = multicam(mc) {
                    id = restored
                } else if let key = md["sequenceId"] as? String, let known = sequenceIds[key] {
                    id = known
                } else {
                    id = Importer.unique((md["sequenceId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Importer.slug(named), &usedSequenceIds)
                    sequences.append(NestedSequence(id: id, name: named, tracks: tracks, transitions: trs))
                    if let key = md["sequenceId"] as? String { sequenceIds[key] = id }
                }
                var c = Clip(id: clipId(md["clipId"]), kind: .sequence, name: name.isEmpty || (md["sequenceName"] != nil && name == named) ? nil : name,
                             mediaId: id, start: start, duration: duration, sourceIn: offset)
                if let v = Self.number(md["volume"]) { c.volume = v }
                restore(md, &c)
                if let b = (md["blend"] as? String).flatMap({ BlendMode(rawValue: $0) }) { c.blend = b }
                if let mc = md["multicam"] as? [String: Any], sequences.first(where: { $0.id == id })?.multicam != nil {
                    c.multicam = Self.decode(MulticamSwitch.self, mc["switch"])
                    if c.name == named { c.name = nil }
                }
                made = c
                if !(item["effects"] as? [[String: Any]] ?? []).isEmpty { drop("Effects", on: seqName) }
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
        for (tr, index) in pending {
            let from = index > 0 ? items[index - 1].id : nil
            let to = index < items.count ? items[index].id : nil
            // Cutline's overlapping sounds: each item's sound runs on under the crossfade.
            if Self.cutline(tr)["overlap"] as? Bool == true, kind == .audio,
               let a = clips.firstIndex(where: { $0.id == from }), let b = clips.firstIndex(where: { $0.id == to }) {
                let before = Self.time(tr["in_offset"]) ?? 0, after = Self.time(tr["out_offset"]) ?? 0
                clips[a].duration += after
                clips[b].start -= before
                clips[b].duration += before
                clips[b].sourceIn -= before * clips[b].speed
                continue
            }
            if let made = transition(tr, from: from, to: to) { transitions.append(made) }
        }
        return (clips, disabled, transitions)
    }

    /// A Transition item between the items `from` and `to` (nil for gaps or the track's ends).
    func transition(_ tr: [String: Any], from: String?, to: String?) -> Transition? {
        let a = Self.time(tr["in_offset"]) ?? 0, b = Self.time(tr["out_offset"]) ?? 0
        guard a + b > 0, from != nil || to != nil else { return nil }
        let frame = 1 / max(canvas.fps, 1)
        let md = Self.cutline(tr)
        let label = (tr["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tr["transition_type"] as? String ?? ""
        var (align, duration, cutOffset) = from != nil && to != nil
            ? Importer.alignment(before: a, after: b, frame: frame)
            : (TransitionAlign.center, a + b, nil)
        if from != nil, to != nil, let known = (md["align"] as? String).flatMap(TransitionAlign.init(rawValue:)) {
            align = known
            cutOffset = Self.number(md["cutOffset"])
        }
        let name = label.lowercased()
        var type = (md["type"] as? String).flatMap { TransitionCatalog.type($0) != nil ? $0 : nil } ?? "dissolve"
        if md["type"] == nil {
            if name.contains("dip") || name.contains("fade to") { type = "dip" } else if tr["transition_type"] as? String != "SMPTE_Dissolve" && !name.contains("dissolve") && !name.contains("cross fade") {
                warnings.append("Transition \(label) imported as a dissolve")
            }
        }
        transitionCount += 1
        var made = Transition(id: "tr\(transitionCount)", from: from, to: to, type: type, duration: duration, align: align,
                              part: (md["part"] as? String).flatMap(TransitionPart.init(rawValue:)) ?? .both)
        made.cutOffset = cutOffset
        return made
    }

    /// Crossfades on the sound track of a video track, between the clips whose sound its items carry.
    func soundTransitions(_ track: [String: Any]) -> [Transition] {
        var out: [Transition] = []
        var previous: String?
        var pending: [String: Any]?
        for item in Self.items(track) {
            if Self.schema(item) == "Transition" {
                pending = Self.cutline(item)["overlap"] as? Bool == true ? nil : item
                continue
            }
            let id = Self.schema(item) == "Clip" ? Self.cutline(item)["clipId"] as? String : nil
            if let tr = pending, let from = previous, let to = id, var made = transition(tr, from: from, to: to) {
                made.part = .audio
                out.append(made)
            }
            pending = nil
            previous = id
        }
        return out
    }

    func clip(_ item: [String: Any], kind: TrackKind, start: Seconds, duration: Seconds, range: (start: Seconds, duration: Seconds)?) -> Clip? {
        let name = item["name"] as? String ?? ""
        let md = Self.cutline(item)
        if let c = restored(md, start: start, duration: duration), c.kind != .media { return c }
        let ref = activeReference(item)
        if let ref, Self.schema(ref) == "GeneratorReference" {
            let generator = ref["generator_kind"] as? String ?? ""
            if generator.lowercased().contains("solid"), kind == .video {
                let color = (ref["parameters"] as? [String: Any])?["color"] as? String
                return Clip(id: clipId(md["clipId"]), kind: .solid, name: name.isEmpty ? nil : name, start: start, duration: duration,
                            color: color.flatMap { RGBA(hex: $0) ?? RGBA.named($0) } ?? .black)
            }
            warnings.append("Generator \(name.isEmpty ? generator : name)\(generator.isEmpty ? "" : " (\(generator))") kept as offline media")
        }
        guard let id = mediaId(ref, clipName: name, kind: kind) else { return nil }
        var c = Clip(id: clipId(md["clipId"]), kind: .media, name: name.isEmpty ? nil : name, mediaId: id, start: start, duration: duration,
                     sourceIn: range.map { $0.start - (availableStart[id] ?? 0) } ?? 0)
        let label = name.isEmpty ? c.id : name
        for e in item["effects"] as? [[String: Any]] ?? [] {
            switch Self.schema(e) {
            case "LinearTimeWarp":
                var s = Self.number(e["time_scalar"]) ?? 1
                if s < 0 { c.reverse = true; s = -s }
                if s == 0 {
                    Importer.freeze(&c)
                } else if s < 0.01 || s > 100 {
                    warnings.append("Speed \(s)× on \(label) not kept")
                } else {
                    c.speed = Importer.niceSpeed(s)
                }
            case "FreezeFrame":
                Importer.freeze(&c)
            default:
                if let resolve = Self.path(e, ["metadata", "Resolve_OTIO"]) as? [String: Any] {
                    resolveEffect(resolve, &c, label)
                } else if e["effect_name"] as? String == "AudioLevel" {
                    if md.isEmpty { audioLevel(Self.cutline(e), &c) }
                } else {
                    drop("Effect \(e["effect_name"] as? String ?? e["OTIO_SCHEMA"] as? String ?? "")", on: label)
                }
            }
        }
        if let v = Self.number(md["volume"]) { c.volume = v }
        restore(md, &c)
        if Self.decode([Effect].self, md["effects"]) == nil {
            c.effects += Importer.colorEffects(cdl: Self.cdl(item), luts: [Self.path(item, ["metadata", "lut", "file"]) as? String].compactMap { $0 })
        }
        if let b = (md["blend"] as? String).flatMap({ BlendMode(rawValue: $0) }) { c.blend = b }
        return c
    }

    static func decode<T: Decodable>(_ type: T.Type, _ v: Any?) -> T? { Project.decode(type, v) }

    /// The multicam a stack of active angles stands for, from Cutline's metadata: the sequence (once per id) with its
    /// angles' media matched by file or added. Returns its id.
    func multicam(_ md: [String: Any]) -> String? {
        guard var seq = Self.decode(NestedSequence.self, md["sequence"]), seq.multicam != nil, let assets = Self.decode([MediaAsset].self, md["media"]) else { return nil }
        if let known = sequenceIds["multicam:" + seq.id] { return known }
        var rename: [String: String] = [:]
        for a in assets {
            if let same = media.first(where: { m in [a.path, a.conformPath].contains { Importer.samePath(m, $0) } }) {
                rename[a.id] = same.id
                continue
            }
            var m = a
            m.id = Importer.unique(a.id, &usedMediaIds)
            media.append(m)
            mediaByKey["multicam:" + a.id] = media.count - 1
            if !Importer.exists(m.path) { offline.insert(m.id) }
            rename[a.id] = m.id
        }
        for t in seq.tracks.indices {
            for c in seq.tracks[t].clips.indices {
                if let id = seq.tracks[t].clips[c].mediaId { seq.tracks[t].clips[c].mediaId = rename[id] ?? id }
            }
        }
        if var setup = seq.multicam {
            for k in setup.angles.indices { setup.angles[k].mediaId = rename[setup.angles[k].mediaId] ?? setup.angles[k].mediaId }
            seq.multicam = setup
        }
        let key = seq.id
        seq.id = Importer.unique(seq.id, &usedSequenceIds)
        sequences.append(seq)
        sequenceIds["multicam:" + key] = seq.id
        return seq.id
    }

    /// Clip settings Cutline keeps in its metadata.
    func restore(_ md: [String: Any], _ c: inout Clip) {
        if let f = Self.number(md["fadeIn"]) { c.fadeIn = f }
        if let f = Self.number(md["fadeOut"]) { c.fadeOut = f }
        if let f = Self.number(md["audioFadeIn"]) { c.audioFadeIn = f }
        if let f = Self.number(md["audioFadeOut"]) { c.audioFadeOut = f }
        if let v = Self.number(md["audioLead"]) { c.audioLead = v }
        if let v = Self.number(md["audioLag"]) { c.audioLag = v }
        if md["reverse"] as? Bool == true { c.reverse = true }
        if let ch = (md["channels"] as? String).flatMap(ChannelRouting.init(rawValue:)) { c.channels = ch }
        if let t = Self.decode(Transform.self, md["transform"]) { c.transform = t }
        if let e = Self.decode([Effect].self, md["effects"]) { c.effects = e }
        if let a = Self.decode([String: Curve].self, md["anim"]) { c.anim.merge(a) { _, b in b } }
    }

    /// The `cdl` metadata OTIO's CMX adapter writes from `*ASC_SOP`/`*ASC_SAT`.
    static func cdl(_ item: [String: Any]) -> CDL? {
        guard let sop = path(item, ["metadata", "cdl", "asc_sop"]) as? [String: Any] else { return nil }
        func v(_ k: String, _ d: Double) -> SIMD3<Double> {
            let a = (sop[k] as? [Any] ?? []).compactMap(number)
            return a.count >= 3 ? SIMD3(a[0], a[1], a[2]) : SIMD3(repeating: d)
        }
        return CDL(slope: v("slope", 1), offset: v("offset", 0), power: v("power", 1), saturation: number(path(item, ["metadata", "cdl", "asc_sat"])) ?? 1)
    }

    /// An `AudioLevel` effect from another tool: level in dB, keyframes in seconds from the item start, fades.
    func audioLevel(_ md: [String: Any], _ c: inout Clip) {
        func gain(_ db: Double) -> Double { db <= -96 ? 0 : pow(10, db / 20) }
        if let db = Self.number(md["gain_db"]) { c.volume *= gain(db) }
        let keys = (md["keyframes"] as? [[String: Any]] ?? []).compactMap { k -> CurveKey? in
            guard let t = Self.number(k["time"]), let db = Self.number(k["gain_db"]) else { return nil }
            return CurveKey(t: t, v: .number(gain(db)), ease: .linear)
        }
        if !keys.isEmpty { c.anim["audio.volume"] = Curve(keys: keys) }
        if let f = Self.number(md["fade_in"]) { c.audioFadeIn = f }
        if let f = Self.number(md["fade_out"]) { c.audioFadeOut = f }
    }

    /// Resolve writes every clip property as an effect: static clip volume is kept, untouched ones are skipped.
    func resolveEffect(_ e: [String: Any], _ c: inout Clip, _ label: String) {
        guard e["Enabled"] as? Bool != false else { return }
        let effect = e["Effect Name"] as? String ?? e["Name"] as? String ?? "effect"
        func same(_ a: Any?, _ b: Any?) -> Bool {
            if let x = Self.number(a), let y = Self.number(b) { return abs(x - y) < 1e-6 }
            if let x = a as? [Any], let y = b as? [Any] { return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) } }
            return String(describing: a) == String(describing: b)
        }
        var changed: [[String: Any]] = []
        for q in e["Parameters"] as? [[String: Any]] ?? [] {
            let keyed = !((q["Key Frames"] as? [String: Any]) ?? [:]).isEmpty
            if keyed || (q["Default Parameter Value"] != nil && !same(q["Parameter Value"], q["Default Parameter Value"])) { changed.append(q) }
        }
        if effect == "Fairlight Clip Volume and Fades" {
            for q in changed {
                if q["Parameter ID"] as? String == "volume", ((q["Key Frames"] as? [String: Any]) ?? [:]).isEmpty, let db = Self.number(q["Parameter Value"]) {
                    c.volume *= db <= -96 ? 0 : pow(10, db / 20)
                } else {
                    drop("Resolve \(q["Parameter ID"] as? String ?? "volume") animation", on: label)
                }
            }
        } else if !changed.isEmpty {
            drop("Resolve \(effect)", on: label)
        }
    }

    /// Cutline writes titles, solids and adjustment clips as gaps with their kind in the metadata.
    /// The clip Cutline wrote whole into the metadata (titles, solids, generators, baked graphics), at the item's place.
    func restored(_ md: [String: Any], start: Seconds, duration: Seconds) -> Clip? {
        guard var c = Self.decode(Clip.self, md["clip"]) else { return nil }
        c.id = clipId(md["clipId"] ?? c.id)
        c.start = start
        c.duration = duration
        return c
    }

    func gapClip(_ item: [String: Any], kind: TrackKind, start: Seconds, duration: Seconds) -> Clip? {
        let md = Self.cutline(item)
        if kind == .video, let c = restored(md, start: start, duration: duration) { return c }
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
            if !(md["effects"] as? [Any] ?? []).isEmpty, Self.decode([Effect].self, md["effects"]) == nil { warnings.append("Effects of adjustment clip \(name ?? id) not kept") }
        default:
            warnings.append("\(k.rawValue.capitalized) clip \(name ?? id) can't be rebuilt from OTIO; left as a gap")
            return nil
        }
        restore(md, &c)
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
    /// The longest split-edit lead or lag an importer folds into a picture clip; sound further apart stays a clip of its own.
    public static let maxSplit: Seconds = 5

    /// Links each sound clip left on an audio track to the silent picture clip of the same media it plays in sync
    /// with, so they move together like a detached sound.
    static func linkSeparateSound(_ tracks: inout [Track], half: Seconds) {
        for t in tracks.indices where tracks[t].kind == .audio {
            for i in tracks[t].clips.indices where tracks[t].clips[i].kind == .media && tracks[t].clips[i].link == nil {
                let a = tracks[t].clips[i]
                for v in tracks.indices where tracks[v].kind == .video {
                    guard let j = tracks[v].clips.firstIndex(where: { c in
                        c.kind == .media && c.mediaId == a.mediaId && c.volume <= 1e-6 && abs(c.speed - a.speed) < 1e-6 && c.reverse == a.reverse
                            && a.start < c.end - half && c.start < a.end - half
                            && abs((a.sourceIn - a.start * a.speed) - (c.sourceIn - c.start * c.speed)) < half * max(a.speed, 1)
                    }) else { continue }
                    let link = tracks[v].clips[j].link ?? IDs.make("lnk")
                    tracks[v].clips[j].link = link
                    tracks[t].clips[i].link = link
                    break
                }
            }
        }
    }

    /// An EDL of `project`'s media read into a copy of it: its timeline is replaced by the EDL's, media it
    /// names are matched to the project's (see `edl(_:fps:media:mediaResolver:)`), and sources it doesn't
    /// know are added as offline media.
    public static func edl(_ text: String, into project: Project, fps: Double? = nil) throws -> ImportResult {
        let r = try edl(text, fps: fps ?? project.canvas.fps, media: project.media)
        var p = project
        p.tracks = r.project.tracks
        p.transitions = r.project.transitions
        p.markers = r.project.markers
        p.sequences = []
        p.media += r.project.media.filter { m in !project.media.contains { $0.id == m.id } }
        p.canvas.timecodeStart = r.project.canvas.timecodeStart
        if abs(r.project.canvas.fps - p.canvas.fps) < 1e-3 { p.canvas.dropFrame = r.project.canvas.dropFrame }
        return ImportResult(project: p, warnings: r.warnings, missingMedia: r.missingMedia)
    }

    /// CMX 3600 EDL at `fps`: TITLE, FCM, cut (C), dissolve (D), wipe (W) and key (K) events on V and A/A2/AA
    /// channels, M2 speed changes and freeze frames, and FROM/TO CLIP NAME, SOURCE FILE (or Avid's FROM CLIP
    /// and Nucoda's FROM FILE) and LOC comments. Without M2 the record duration wins over the source's.
    /// Timeline zero is the hour at or before the first record-in, or the first record-in itself when it sits
    /// in the last 10 minutes before an hour (pre-roll like 00:59:50:00). A dissolve starts at its edit and
    /// borrows the outgoing clip's media. Channels 3 and 4 come from NONE events with an AUD line.
    /// `*ASC_SOP`/`*ASC_SAT` become a `color.cdl` effect and `*LUT:` a disabled `color.lut` beside it; FCM sets the
    /// canvas's drop frame.
    ///
    /// Each source is first matched to `existing` media by source file path (or camera original), then by reel
    /// (the file whose timecode covers the event when several share it) or clip name, then by file name; those are
    /// kept as they are, and their source timecodes count from their own timecode at their own rate (zero-based
    /// when before it). Others are looked up with `mediaResolver` by clip name, source file
    /// path, file name and reel, in that order. The project lists a placeholder MediaAsset for each other id it uses
    /// (sized from the edit) to replace with the real one. Sources it can't resolve stay as offline media named by
    /// source file, clip name or reel, with source times counted from the hour of their earliest timecode (kept as
    /// `timecodeStart`). The program's first frame becomes the canvas's `timecodeStart`.
    ///
    /// Picture events without sound on their line (V) are silent. Audio-only events are audio clips, except sound
    /// on channel 1 of a silent picture event's source, in sync with it, overlapping it and starting and ending
    /// within `maxSplit` seconds of it: that is the picture's split edit (on another channel too where it overlaps
    /// such sound). Dissolves on audio channels are crossfades; between split sounds they move to the pictures as
    /// audio-only transitions, joining a matching picture dissolve into one of both.
    public static func edl(_ text: String, fps: Double, media existing: [MediaAsset] = [], mediaResolver: (String) -> String? = { _ in nil }) throws -> ImportResult {
        struct Line {
            var event: String
            var reel: String
            var channel: String
            var trans: String
            var transFrames: Int
            var src: (Int, Int)
            var rec: (Int, Int)
            var drop: Bool
            /// The source timecodes as written, read again in a known source's own counting.
            var srcText = ("", "")
            var clipName: String?
            var sourceFile: String?
            var speed: Double?
            var freeze = false
            /// Audio channels from an `AUD` line (3 and 4 in four-channel CMX).
            var aud: [Int] = []
            var sop: String?
            var sat: String?
            var luts: [String] = []
            var gradeLUT: String?
            var hint: SoundHint?
        }
        let grid = FrameGrid(fps: fps)
        let rate = grid.rate
        let nominal = max(1, Int(rate.rounded()))
        var warnings: [String] = [], missing: [String] = []
        var title: String?
        var drop = false
        var fcm: Bool?
        var lines: [Line] = []
        var locs: [(frames: Int, label: String)] = []
        var named: Int?
        let bareComments = ["FROM CLIP NAME:", "TO CLIP NAME:", "SOURCE FILE:", "FROM CLIP:", "FROM FILE:", "LOC:"]

        let body = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (n, raw) in body.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("TITLE:") { title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces); continue }
            if upper.hasPrefix("FCM:") { drop = !upper.contains("NON") && upper.contains("DROP"); fcm = drop; continue }
            var comment: String?
            if line.hasPrefix("*") {
                comment = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if bareComments.contains(where: { upper.hasPrefix($0) }) {
                comment = line
            }
            if let comment {
                let uc = comment.uppercased()
                func value(_ prefix: String) -> String { String(comment.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
                let current = lines.indices.reversed().prefix { lines[$0].event == lines.last?.event }.reversed().map { $0 }
                if uc.hasPrefix("FROM CLIP NAME:"), let i = current.first {
                    lines[i].clipName = value("FROM CLIP NAME:"); named = i
                } else if uc.hasPrefix("TO CLIP NAME:"), let i = current.last {
                    lines[i].clipName = value("TO CLIP NAME:"); named = i
                } else if let prefix = ["SOURCE FILE:", "FROM CLIP:", "FROM FILE:"].first(where: { uc.hasPrefix($0) }),
                          let i = named.flatMap({ current.contains($0) ? $0 : nil }) ?? current.last {
                    lines[i].sourceFile = value(prefix)
                } else if uc.hasPrefix("LOC:") {
                    let parts = value("LOC:").split(whereSeparator: \.isWhitespace).map(String.init)
                    if let first = parts.first, let tc = EDLTimecode.parse(first, nominal: nominal, drop: drop) {
                        let colors: Set<String> = ["RED", "GREEN", "BLUE", "CYAN", "MAGENTA", "YELLOW", "BLACK", "WHITE", "ORANGE", "PURPLE", "PINK"]
                        var rest = parts.dropFirst()
                        if let c = rest.first, colors.contains(c.uppercased()) { rest = rest.dropFirst() }
                        locs.append((tc.frames, rest.joined(separator: " ").isEmpty ? "Marker" : rest.joined(separator: " ")))
                    }
                } else if uc.hasPrefix("ASC_SOP"), let i = current.last {
                    lines[i].sop = value("ASC_SOP")
                } else if uc.hasPrefix("ASC_SAT"), let i = current.last {
                    lines[i].sat = value("ASC_SAT")
                } else if uc.hasPrefix("LUT:"), let i = current.last {
                    lines[i].luts.append(value("LUT:"))
                } else if uc.hasPrefix(Project.gradeLUTTag + ":"), let i = current.last {
                    lines[i].gradeLUT = value(Project.gradeLUTTag + ":")
                } else if uc.hasPrefix(Project.edlSourceTCTag + ":"), let i = current.last {
                    let own = value(Project.edlSourceTCTag + ":").split(whereSeparator: \.isWhitespace).map(String.init)
                    if own.count >= 2 { lines[i].srcText = (own[0], own[1]) }
                } else if comment.hasPrefix(SoundHint.prefix), let i = current.last {
                    lines[i].hint = SoundHint(text: comment)
                } else if uc.contains("FREEZE FRAME"), let i = current.last {
                    lines[i].freeze = true
                } else if let r = comment.range(of: "|M:"), let last = lines.last {
                    let label = comment[r.upperBound...].components(separatedBy: " |").first?.trimmingCharacters(in: .whitespaces) ?? "Marker"
                    locs.append((last.rec.0, label))
                }
                continue
            }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.first?.uppercased() == "AUD" {
                if let event = lines.last?.event {
                    for k in lines.indices where lines[k].event == event { lines[k].aud = tokens.dropFirst().compactMap { Int($0) } }
                }
                continue
            }
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
                              src: (tcs[0].frames, tcs[1].frames), rec: (tcs[2].frames, tcs[3].frames), drop: tcs[2].drop,
                              srcText: (tokens[idx], tokens[idx + 1])))
            named = nil
        }
        guard !lines.isEmpty else { throw EditError("No events in the EDL") }

        let firstLine = lines.min { $0.rec.0 < $1.rec.0 }!
        let perHour = EDLTimecode.frames(1, 0, 0, 0, nominal: nominal, drop: firstLine.drop)
        let hour = firstLine.rec.0 / perHour * perHour
        let origin = Double(hour + perHour - firstLine.rec.0) / rate <= 600 ? firstLine.rec.0 : hour
        func seconds(_ f: Int) -> Seconds { Double(f * grid.num) / Double(grid.den) }
        func rec(_ f: Int) -> Seconds { seconds(f - origin) }

        // Media
        var media: [MediaAsset] = []
        var usedIds = Set(existing.map(\.id))
        var byKey: [String: String] = [:]
        var placeholders = Set<String>(), offline = Set<String>()
        let known = Set(existing.map(\.id))
        /// "Z682_156 (LAY3) FF" and "Z686_5A (LAY2) (47.56 FPS)" name the same media as "Z682_156 (LAY3)" and "Z686_5A (LAY2)".
        func mediaName(_ s: String) -> String {
            var s = s.trimmingCharacters(in: .whitespaces)
            if let r = s.range(of: #"\s*\(\s*-?[0-9.]+\s*FPS\s*\)\s*$"#, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
            if let r = s.range(of: #"\s+FF$"#, options: .regularExpression) { s.removeSubrange(r) }
            return s.isEmpty ? "Clip" : s
        }
        /// Existing media by source file path, then reel or clip name, then file name.
        func match(_ l: Line) -> MediaAsset? {
            guard !existing.isEmpty else { return nil }
            let path = l.sourceFile.map { $0.hasPrefix("file:") ? (URL(string: $0)?.path ?? $0) : $0 }
            if let path, let m = existing.first(where: { Importer.samePath($0, path) }) { return m }
            let reel = l.reel.uppercased()
            if !["AX", "BL", "BLK", "BLACK"].contains(reel) {
                // One camera reel holds many files: the one whose timecode covers the event's source in.
                let reels = existing.filter { $0.reel?.uppercased() == reel || Project.edlReel($0) == reel || Project.edlReel($0.name) == reel }
                let covering = reels.first { m in
                    guard m.timecodeStart != nil, let t = m.sourceSeconds(timecode: l.srcText.0, fallback: fps) else { return false }
                    return t > -1e-6 && t < max(m.duration, 1 / rate)
                }
                if let m = covering ?? (reels.count == 1 || reels.allSatisfy({ $0.timecodeStart == nil }) ? reels.first : nil) { return m }
            }
            if let c = l.clipName.map(mediaName) {
                let stem = (c as NSString).deletingPathExtension
                if let m = existing.first(where: { $0.name == c || $0.name == stem || fileName($0.path) == c || fileName($0.conformPath) == c }) { return m }
            }
            if let path {
                let file = fileName(path), stem = (file as NSString).deletingPathExtension
                return existing.first { fileName($0.path) == file || fileName($0.conformPath) == file } ?? existing.first { $0.name == stem }
            }
            return nil
        }
        func resolve(_ l: Line, video: Bool, audio: Bool) -> String {
            if let m = match(l) {
                if !media.contains(where: { $0.id == m.id }) { media.append(m) }
                return m.id
            }
            var names: [String] = []
            if let c = l.clipName {
                names.append(c)
                if mediaName(c) != c { names.append(mediaName(c)) }
            }
            if let f = l.sourceFile {
                names.append(f)
                names.append(fileName(f))
                names.append((fileName(f) as NSString).deletingPathExtension)
            }
            names.append(l.reel)
            var id: String?
            for n in names where id == nil { id = mediaResolver(n) }
            var path = l.sourceFile.map { $0.hasPrefix("file:") ? (URL(string: $0)?.path ?? $0) : $0 } ?? ""
            if id == nil {
                let key = path.isEmpty ? l.clipName.map(mediaName) ?? l.reel : path
                if let known = byKey[key] { id = known } else {
                    let base = path.isEmpty ? (key as NSString).deletingPathExtension : (fileName(path) as NSString).deletingPathExtension
                    let made = unique(slug(base), &usedIds)
                    byKey[key] = made
                    placeholders.insert(made)
                    if !exists(path) {
                        offline.insert(made)
                        if !missing.contains(path.isEmpty ? key : path) { missing.append(path.isEmpty ? key : path) }
                    }
                    if path.isEmpty { path = key }
                    id = made
                }
            }
            let found = id!
            if let i = media.firstIndex(where: { $0.id == found }) {
                media[i].hasVideo = media[i].hasVideo || video
                media[i].hasAudio = media[i].hasAudio || audio
                if media[i].path.isEmpty { media[i].path = path }
            } else {
                usedIds.insert(found)
                let name = l.clipName.map { (mediaName($0) as NSString).deletingPathExtension } ?? l.reel
                media.append(MediaAsset(id: found, path: path, name: name, duration: 0, width: 1920, height: 1080, fps: niceFps(rate), hasVideo: video, hasAudio: audio))
            }
            return found
        }
        var extent: [String: Seconds] = [:]
        var mismatched: [String] = []

        // Tracks by channel: video channels by number, then audio.
        struct Channel: Hashable { var kind: TrackKind; var n: Int }
        func channel(_ l: Line) -> (main: Channel, audio: Bool)? {
            let s = l.channel
            if s == "B" { return (Channel(kind: .video, n: 1), true) }
            if s == "NONE", let a = l.aud.first { return (Channel(kind: .audio, n: a), true) }
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
        /// Video clips whose event carries their sound.
        var sounding = Set<String>()
        let half = 0.5 / rate
        func isBlack(_ reel: String) -> Bool { ["BL", "BLK", "BLACK"].contains(reel.uppercased()) }
        /// Audio clips with Cutline's sound comment, and the record frame their event's sound starts at.
        var hinted: [String: (hint: SoundHint, soundStart: Int)] = [:]
        func makeClip(_ l: Line, _ ch: (main: Channel, audio: Bool)) -> Clip? {
            guard !isBlack(l.reel), l.rec.1 > l.rec.0 else { return nil }
            let id = resolve(l, video: ch.main.kind == .video, audio: ch.audio)
            let duration = seconds(l.rec.1 - l.rec.0)
            count += 1
            var sourceIn = seconds(l.src.0)
            // A known source's timecode counts at its own rate; a source in before its first frame is zero-based.
            if known.contains(id), let m = media.first(where: { $0.id == id }), m.timecodeStart != nil,
               let t = m.sourceSeconds(timecode: l.srcText.0, fallback: fps), t > -0.5 / rate {
                sourceIn = max(0, t)
            }
            var c = Clip(id: "c\(count)", kind: .media, name: l.clipName ?? l.reel, mediaId: id, start: rec(l.rec.0), duration: duration, sourceIn: sourceIn)
            if l.freeze || l.speed == 0 {
                freeze(&c)
            } else {
                var speed = l.speed ?? 1
                if l.speed == nil, l.src.1 != l.src.0, abs((l.src.1 - l.src.0) - (l.rec.1 - l.rec.0)) > 1 { mismatched.append(l.event) }
                if speed < 0 { c.reverse = true; speed = -speed }
                if speed < 0.01 || speed > 100 {
                    warnings.append("Event \(l.event): speed \(speed)× not kept")
                    speed = 1
                }
                c.speed = niceSpeed(speed)
                if c.reverse { c.sourceIn -= duration * c.speed }
            }
            extent[id] = max(extent[id] ?? 0, c.sourceOut, c.sourceIn + 1 / rate)
            c.effects += l.gradeLUT.flatMap { gradeLUT(Project.gradeLUTTag + " " + $0) } ?? colorEffects(cdl: l.sop.flatMap { CDL(sop: $0, sat: l.sat) }, luts: l.luts)
            if ch.main.kind == .video && ch.audio { sounding.insert(c.id) }
            if known.contains(id), c.name == media.first(where: { $0.id == id })?.name { c.name = nil }
            if ch.main.kind == .audio, let h = l.hint, !c.reverse { hinted[c.id] = (h, l.rec.0 - origin) }
            return c
        }

        var i = 0
        while i < lines.count {
            let l = lines[i]
            guard let ch = channel(l) else {
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
            // A dissolve between sounds is a crossfade.
            transitions.append(Transition(id: "tr\(transitions.count + 1)", from: from?.id, to: incoming.id, type: type, duration: d, align: .start,
                                          part: ch.main.kind == .audio && from != nil ? .audio : .both))
        }
        // Cutline's sound comments: dissolves standing for overlapping sound go, and each clip takes its picture and split back.
        let overlapped = Set(hinted.filter(\.value.hint.overlap).map(\.key))
        transitions.removeAll { tr in tr.part == .audio && tr.to.map(overlapped.contains) == true && tr.from.map { hinted[$0] != nil } == true }
        for key in clips.keys where key.kind == .audio {
            for k in clips[key]!.indices {
                guard let h = hinted[clips[key]![k].id] else { continue }
                h.hint.apply(&clips[key]![k], soundStart: h.soundStart, grid: grid)
            }
        }
        if !mismatched.isEmpty {
            let list = mismatched.count > 6 ? mismatched.prefix(6).joined(separator: ", ") + ", …" : mismatched.joined(separator: ", ")
            warnings.append("Event\(mismatched.count == 1 ? "" : "s") \(list): source and record durations differ without an M2 speed; record durations kept at normal speed")
        }

        // Offline sources count from the hour of their first timecode.
        let sourceHour = EDLTimecode.frames(1, 0, 0, 0, nominal: nominal, drop: drop)
        for id in placeholders {
            let ins = clips.values.flatMap { $0 }.filter { $0.mediaId == id }.map(\.sourceIn)
            guard let low = ins.min(), let m = media.firstIndex(where: { $0.id == id }) else { continue }
            let hourFrames = Int((low * rate + 0.5) / Double(sourceHour)) * sourceHour
            let tc = seconds(hourFrames)
            guard tc > 0 else { continue }
            media[m].setTimecode(frames: hourFrames, format: TimecodeFormat(fps: rate, dropFrame: drop))
            for key in clips.keys {
                for k in clips[key]!.indices where clips[key]![k].mediaId == id { clips[key]![k].sourceIn -= tc }
            }
            extent[id] = (extent[id] ?? tc) - tc
        }

        for k in media.indices where !known.contains(media[k].id) { media[k].duration = extent[media[k].id] ?? 0 }
        var tracks: [Track] = []
        var channels: [String: Int] = [:]
        let order = clips.keys.sorted { ($0.kind == .video ? 0 : 1, $0.n) < ($1.kind == .video ? 0 : 1, $1.n) }
        var v = 0, a = 0
        if !order.contains(where: { $0.kind == .video }) { tracks.append(Track(id: "V1", kind: .video, name: "Video 1")); v = 1 }
        for key in order {
            if key.kind == .video { v += 1 } else { a += 1 }
            let id = key.kind == .video ? "V\(v)" : "A\(a)"
            channels[id] = key.n
            tracks.append(Track(id: id, kind: key.kind, name: "\(key.kind == .video ? "Video" : "Audio") \(key.n)", clips: clips[key]!.sorted { $0.start < $1.start }))
        }
        // Audio that repeats a video clip's or another channel's: the same source on the same record time.
        let carried = sounding
        /// Audio clips folded away, to the clip that now carries their sound.
        var soundOf: [String: String] = [:]
        var seen: [Clip] = tracks.filter { $0.kind == .video }.flatMap(\.clips)
        let videoIds = Set(seen.map(\.id))
        for t in tracks.indices where tracks[t].kind == .audio {
            tracks[t].clips.removeAll { c in
                let match = seen.first { s in
                    s.mediaId == c.mediaId && abs(s.start - c.start) < half && abs(s.duration - c.duration) < half && abs(s.sourceIn - c.sourceIn) < half
                }
                if let s = match {
                    if videoIds.contains(s.id) { sounding.insert(s.id) }
                    soundOf[c.id] = soundOf[s.id] ?? s.id
                }
                if match == nil { seen.append(c) }
                return match != nil
            }
        }
        // Sound on channel 1 of a picture-only event's source, in sync with it, overlapping it and starting and
        // ending near it: a split edit. On other channels it is one only where it overlaps such sound, as sound
        // moved off channel 1 to keep it from overlapping there.
        var heard = tracks.filter { $0.kind == .video }.flatMap(\.clips).filter { sounding.contains($0.id) }.map(\.audioRange)
        func fold(_ t: Int, overlapping: Bool) {
            var kept: [Clip] = []
            for a in tracks[t].clips {
                var folded = false
                let overlaps = heard.contains { $0.start < a.end - half && a.start < $0.end - half }
                for v in tracks.indices where tracks[v].kind == .video && !folded && (!overlapping || overlaps) {
                    guard let i = tracks[v].clips.firstIndex(where: { c in
                        !sounding.contains(c.id) && c.mediaId == a.mediaId && abs(c.speed - a.speed) < 1e-6 && !c.reverse && !a.reverse && !c.isRetimed
                            && a.start < c.end - half && c.start < a.end - half
                            && abs(c.start - a.start) <= maxSplit + half && abs(a.end - c.end) <= maxSplit + half
                            && abs((a.sourceIn - a.start * a.speed) - (c.sourceIn - c.start * c.speed)) < half * max(a.speed, 1)
                    }) else { continue }
                    tracks[v].clips[i].audioLead = tracks[v].clips[i].start - a.start
                    tracks[v].clips[i].audioLag = a.end - tracks[v].clips[i].end
                    sounding.insert(tracks[v].clips[i].id)
                    soundOf[a.id] = tracks[v].clips[i].id
                    heard.append(TimeRange(a.start, a.end))
                    folded = true
                }
                if !folded { kept.append(a) }
            }
            tracks[t].clips = kept
        }
        for t in tracks.indices where tracks[t].kind == .audio && channels[tracks[t].id] == 1 { fold(t, overlapping: false) }
        for t in tracks.indices where tracks[t].kind == .audio && channels[tracks[t].id] != 1 { fold(t, overlapping: true) }
        transitions = Importer.foldTransitions(transitions, soundOf: soundOf, separate: sounding.subtracting(carried), frame: 1 / rate)
        tracks.removeAll { $0.kind == .audio && $0.clips.isEmpty }
        var na = 0
        for t in tracks.indices where tracks[t].kind == .audio {
            na += 1
            tracks[t].id = "A\(na)"
        }
        // A picture-only event plays no sound, unless its media is known to have none.
        let silent = Set(media.filter { known.contains($0.id) && (!$0.hasAudio || $0.isImage) }.map(\.id))
        for t in tracks.indices where tracks[t].kind == .video {
            for i in tracks[t].clips.indices where !sounding.contains(tracks[t].clips[i].id) && !silent.contains(tracks[t].clips[i].mediaId ?? "") {
                tracks[t].clips[i].volume = 0
            }
        }

        var canvas = Canvas(fps: niceFps(rate))
        if let fcm { canvas.dropFrame = Canvas.dropFrame(fcm, fps: canvas.fps) }
        if let start = canvas.timecodeFormat.frames(EDLTimecode.string(origin, nominal: nominal, drop: firstLine.drop)) {
            canvas.timecodeStart = canvas.timecodeStart(frames: start)
        }
        var p = Project(name: title ?? "EDL", canvas: canvas)
        p.media = media
        p.tracks = tracks
        p.transitions = transitions
        p.markers = locs.enumerated().map { Marker(id: "marker\($0.offset + 1)", time: rec($0.element.frames), label: $0.element.label) }.sorted { $0.time < $1.time }
        finish(&p, &warnings, offline: offline)
        return ImportResult(project: p, warnings: warnings, missingMedia: missing)
    }
}

extension Project {
    /// The reel an EDL names media by: its name in capitals, letters, digits and underscores, at most 8; "AX" when empty.
    static func edlReel(_ name: String) -> String {
        let r = String(name.uppercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" }.prefix(8))
        return r.isEmpty ? "AX" : r
    }

    /// The reel an EDL names `m` by: its own reel, else its file name (its name without one), cut to EDL rules.
    static func edlReel(_ m: MediaAsset) -> String {
        let reel = m.reel?.trimmingCharacters(in: .whitespaces) ?? ""
        let file = (Importer.fileName(m.conformPath) as NSString).deletingPathExtension
        let name = !reel.isEmpty ? reel : file.isEmpty ? m.name : file
        return edlReel(name.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_"))
    }

    /// The project with sequence clips replaced by what they play, for targets without nesting. A sequence's
    /// lowest video track goes on the clip's own track, its other tracks on the next free tracks of their kind
    /// (new ones when taken); levels fold in its clip's volume and track faders. Transitions inside come along,
    /// and ones to or from the sequence clip move to its first or last clip on the clip's track.
    func flattenedSequences() -> Project {
        guard tracks.contains(where: { $0.clips.contains { $0.kind == .sequence } }) else { return self }
        var p = self
        var moved: [String: (first: String?, last: String?)] = [:]
        let hosted = tracks.indices.flatMap { t in tracks[t].clips.filter { $0.kind == .sequence }.map { (t, $0) } }
        for t in p.tracks.indices { p.tracks[t].clips.removeAll { $0.kind == .sequence } }
        for (host, clip) in hosted {
            guard let seq = clip.mediaId.flatMap(sequence) else { continue }
            let inner = inside(seq).flattenedSequences()
            let window = Project.sequenceWindow(clip)
            var kept = Set<String>()
            var counts: [TrackKind: Int] = [:]
            for track in inner.tracks where !(track.muted && track.kind == .audio) && !(track.hidden && track.kind == .video) {
                let clips: [Clip] = track.clips.compactMap { c in
                    guard c.end > window.start + eps && c.start < window.end - eps else { return nil }
                    var c = c
                    if c.start < window.start { c = Project.trimmedLeft(c, to: window.start) }
                    if c.end > window.end { c = Project.trimmedRight(c, to: window.end) }
                    c = Project.placed(c, in: clip)
                    c.id = "\(clip.id)/\(c.id)"
                    c.volume *= clip.volume * track.volume
                    return c
                }
                let n = counts[track.kind, default: 0]
                counts[track.kind] = n + 1
                guard !clips.isEmpty else { continue }
                let same = p.tracks.indices.filter { p.tracks[$0].kind == track.kind }
                let from = p.tracks[host].kind == track.kind ? same.firstIndex(of: host) ?? 0 : 0
                func free(_ i: Int) -> Bool { clips.allSatisfy { c in !p.tracks[i].clips.contains { $0.start < c.end - eps && $0.end > c.start + eps } } }
                var target = from + n < same.count ? same[from + n] : nil
                if let i = target, !free(i) { target = same.dropFirst(from + n).first(where: free) }
                if target == nil {
                    p.addTrack(kind: track.kind, name: track.name)
                    target = p.tracks.count - 1
                }
                guard let ti = target else { continue }
                p.tracks[ti].clips = (p.tracks[ti].clips + clips).sorted { $0.start < $1.start }
                kept.formUnion(clips.map(\.id))
                if ti == host {
                    moved[clip.id] = (clips.min { $0.start < $1.start }?.id, clips.max { $0.end < $1.end }?.id)
                }
            }
            for var tr in inner.transitions {
                tr.from = tr.from.map { "\(clip.id)/\($0)" }
                tr.to = tr.to.map { "\(clip.id)/\($0)" }
                guard [tr.from, tr.to].compactMap({ $0 }).allSatisfy(kept.contains) else { continue }
                tr.id = "\(clip.id)/\(tr.id)"
                p.transitions.append(tr)
            }
        }
        p.transitions = p.transitions.compactMap { tr in
            var tr = tr
            if let f = tr.from, let m = moved[f] { tr.from = m.last }
            if let t = tr.to, let m = moved[t] { tr.to = m.first }
            return tr.from == nil && tr.to == nil ? nil : tr
        }
        p.sequences = []
        return p
    }

    /// CMX 3600 EDL of the main video track and the first two audio tracks, recorded from the canvas's start
    /// timecode in canvas frames (drop frame as `Canvas.isDropFrame` says). Sequence clips are listed as the
    /// events they play (`flattenedSequences`). The main track's production sound rides with its picture as
    /// AA/V (A/V for a one-channel source, A/V or A2/V when routed to one channel) when picture and sound cut and
    /// dissolve together; otherwise (split edits, picture-only dissolves,
    /// audio-only crossfades) the picture is a V event and the sound an AA event over its audio range. Audio
    /// tracks are A and A2, or channels 3 and 4 (NONE with an AUD line) when there is production sound; a clip
    /// routed to source channels (audio.channels ch1, ch2, ch1+ch2, ch3, ch4, ch3+ch4) goes on those channels
    /// (A, A2, AA, AUD 3, AUD 4, AUD 3 4), as CMX patches source channel n to record channel n. Sound
    /// that would overlap other sound on its channel moves to a channel free at that time (3, 4, A or A2), and is
    /// cut short where none is, so no channel holds overlapping events. Source timecode is the media's own (its
    /// first frame's timecode plus the in point) counted in the list's rate and drop frame: the same frame count at
    /// the same rate, else the same time of day; a `* SOURCE TC:` comment then gives it at the source's own rate. The
    /// reel is its reel or file name (`edlReel`). Each event names its clip and source file in comments, speed becomes an M2 line, the clip's CDL
    /// `*ASC_SOP` and `*ASC_SAT` lines and its LUT files `*LUT:` lines, and markers LOC comments. Dissolves (wipes
    /// stay wipes) and crossfades are written as CMX writes them: the outgoing event runs to the transition's
    /// start, then a zero-length line of it and a D line of the incoming event. They start at the edit, so a
    /// centered one moves the edit to its start (crossfades sit on the sound cut); transitions from or to nothing
    /// go through black. Only media clips are listed.
    public func edl(title: String) -> String { scopedToTimeline().edl(title: title, InterchangeContext()) }

    func edl(title: String, _ ctx: InterchangeContext) -> String { flattenedSequences().flatEDL(title: title, ctx) }

    private func flatEDL(title: String, _ ctx: InterchangeContext) -> String {
        let grid = FrameGrid(fps: canvas.fps)
        let format = canvas.timecodeFormat
        let nominal = format.nominal, drop = format.dropFrame
        let origin = startFrame
        func tc(_ f: Int) -> String { EDLTimecode.string(f, nominal: nominal, drop: drop) }
        func seconds(_ f: Int) -> Seconds { Double(f * grid.num) / Double(grid.den) }
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        func reel(_ c: Clip) -> String { c.mediaId.flatMap(mediaAsset).map(Project.edlReel) ?? "AX" }
        func srcFormat(_ c: Clip) -> TimecodeFormat { c.mediaId.flatMap(mediaAsset)?.timecodeFormat(fallback: canvas.fps, dropFrame: canvas.dropFrame) ?? format }
        /// Source frames from midnight at second `t` of the clip's media, in its own counting.
        func nativeSrc(_ c: Clip, _ t: Seconds) -> Int { c.mediaId.flatMap(mediaAsset)?.sourceFrames(at: t, fallback: canvas.fps) ?? grid.frames(t) }
        /// Source frame `f` counted as `s` does, in the list's counting: the same frame count at the same rate (only the
        /// drop-frame labels change), else the list frame nearest the label's time of day (hh:mm:ss and the fraction of
        /// a second), so every label is valid at the list's rate: a fraction that rounds to a whole second carries into it.
        func listFrames(_ f: Int, from s: TimecodeFormat) -> Int {
            if s.frameNum * format.frameDen == format.frameNum * s.frameDen { return f }
            let parts = s.string(f).split(whereSeparator: { ":;".contains($0) }).compactMap { Int($0) }
            guard parts.count == 4 else { return f }
            let frames = Int((Double(parts[3]) / Double(s.nominal) * Double(nominal)).rounded())
            let second = parts[0] * 3600 + parts[1] * 60 + parts[2] + frames / nominal
            let (h, m, sec) = (second / 3600 % 24, second / 60 % 60, second % 60)
            var ff = frames % nominal
            if drop, sec == 0, m % 10 != 0 { ff = max(ff, EDLTimecode.dropFrames(nominal)) }
            return EDLTimecode.frames(h, m, sec, ff, nominal: nominal, drop: drop)
        }
        /// Source frame at second `t` of the clip's media, counted at the list's rate and drop frame.
        func src(_ c: Clip, _ t: Seconds) -> Int { listFrames(nativeSrc(c, t), from: srcFormat(c)) }
        /// List frames of source played over `frames` record frames.
        func srcLength(_ c: Clip, _ frames: Int) -> Int { Int((Double(frames) * c.speed).rounded()) }
        func clipName(_ c: Clip) -> String { c.name ?? c.mediaId.flatMap(mediaAsset)?.name ?? c.id }
        var out = ["TITLE: \(title)", "FCM: \(drop ? "DROP FRAME" : "NON-DROP FRAME")", ""]
        var event = 0
        func line(_ reel: String, _ ch: String, _ tr: String, _ dur: Int?, _ s0: Int, _ s1: Int, _ r0: Int, _ r1: Int) {
            let d = dur.map { String(format: "%03d", $0) } ?? "   "
            out.append("\(String(format: "%03d", event))  \(pad(reel, 8)) \(pad(ch, 5)) \(pad(tr, 4)) \(d) \(tc(s0)) \(tc(s1)) \(tc(r0 + origin)) \(tc(r1 + origin))")
        }
        func code(_ tr: Transition) -> String { tr.type == "wipe" ? "W001" : "D" }

        var pendingMarkers = markers.filter { $0.time >= 0 }.sorted { $0.time < $1.time }
        func flushMarkers(before frame: Int?) {
            while let m = pendingMarkers.first, frame.map({ grid.frames(m.time) < $0 }) ?? true {
                out.append("* LOC: \(tc(grid.frames(m.time) + origin)) RED     \(m.label)")
                pendingMarkers.removeFirst()
            }
        }
        /// `t0` is the source second at the event's start, `frames` its record length.
        func describe(_ c: Clip, s0: Int, t0: Seconds, frames: Int) {
            if let path = c.mediaId.flatMap(mediaAsset)?.conformPath, !path.isEmpty { out.append("* SOURCE FILE: \(path)") }
            let own = srcFormat(c)
            if own != format {
                let n0 = nativeSrc(c, t0), n1 = n0 + own.frameCount(seconds(frames) * c.speed)
                let rate = (Double(own.frameDen) / Double(own.frameNum) * 1000).rounded() / 1000
                out.append("* \(Project.edlSourceTCTag): \(own.string(n0)) \(own.string(n1)) (\(String(format: "%g", rate)) fps\(own.dropFrame ? " DF" : own.frameNum == 1001 ? " NDF" : ""))")
            }
            if abs(c.speed - 1) > 1e-9 || c.reverse {
                let v = c.speed * canvas.fps * (c.reverse ? -1 : 1)
                out.append("M2   \(pad(reel(c), 8))       \(String(format: "%05.1f", v))                \(tc(s0))")
            }
        }

        /// A clip over record frames `r0..<r1`, reading from source second `t0`, entered from `from` (from black
        /// when nil) by `into`, or left to black by `out`.
        struct Event {
            var clip: Clip
            var r0: Int
            var r1: Int
            var t0: Seconds
            var into: (tr: Transition, length: Int, from: Clip?)?
            var out: (tr: Transition, length: Int)?
            var hint: SoundHint?
            var end: Int { r1 + (out?.length ?? 0) }
        }
        /// Writes an event on channel `ch` (with an AUD line for channels 3 and 4); `picture` adds the grade.
        func write(_ e: Event, _ ch: String, aud: [Int], picture: Bool) {
            let c = e.clip
            let s0 = src(c, e.t0), s1 = s0 + srcLength(c, e.r1 - e.r0)
            func audLine() { if !aud.isEmpty { out.append("AUD  " + aud.map(String.init).joined(separator: " ")) } }
            event += 1
            if let (tr, d, from) = e.into {
                if let from {
                    let fs = src(from, sourceTime(from, at: e.r0, sound: !picture))
                    line(reel(from), ch, "C", nil, fs, fs, e.r0, e.r0)
                } else {
                    line("BL", ch, "C", nil, 0, 0, e.r0, e.r0)
                }
                line(reel(c), ch, code(tr), d, s0, s1, e.r0, e.r1)
                audLine()
                if let from { out.append("* FROM CLIP NAME: \(clipName(from))") }
                out.append("* TO CLIP NAME: \(clipName(c))")
            } else {
                line(reel(c), ch, "C", nil, s0, s1, e.r0, e.r1)
                audLine()
                out.append("* FROM CLIP NAME: \(clipName(c))")
            }
            describe(c, s0: s0, t0: e.t0, frames: e.r1 - e.r0)
            if let h = e.hint { out.append("* " + h.text) }
            if picture {
                if let cdl = c.cdl {
                    out.append("*ASC_SOP \(cdl.sop)")
                    out.append("*ASC_SAT \(cdl.sat)")
                }
                out += c.lutFiles.map { "*LUT: \($0)" }
                if let whole = ctx.luts[c.id] ?? c.id.components(separatedBy: "/").last.flatMap({ ctx.luts[$0] }) { out.append("* \(Project.gradeLUTTag): \(whole)") }
            }
            if picture, ch.contains("V") { flushMarkers(before: e.r1) }
            if let (tr, d) = e.out {
                event += 1
                let fs = src(c, sourceTime(c, at: e.r1, sound: !picture))
                line(reel(c), ch, "C", nil, fs, fs, e.r1, e.r1)
                line("BL", ch, code(tr), d, 0, d, e.r1, e.r1 + d)
                audLine()
                out.append("* FROM CLIP NAME: \(clipName(c))")
            }
            out.append("")
        }
        /// Source second of a clip's picture, or its sound, at record frame `r`.
        func sourceTime(_ c: Clip, at r: Int, sound: Bool) -> Seconds {
            sound && !c.reverse ? c.audioSourceRange.start + (seconds(r) - c.audioRange.start) * c.speed : c.sourceTime(atTimeline: seconds(r))
        }
        /// Events of `clips` over their pictures, or with `sound` their sounds, joined by the transitions `joins` allows.
        /// With `hints`, sound overlapping the next clip's with no transition between them dissolves into it over the
        /// overlap, and each clip names its picture and split in a Cutline comment.
        func events(_ clips: [Clip], sound: Bool, hints: Bool = false, joins: (Transition) -> Bool) -> [Event] {
            let ids = Set(clips.map(\.id))
            let mine = transitions.filter { tr in joins(tr) && [tr.from, tr.to].compactMap { $0 }.allSatisfy(ids.contains) }
            func at(_ tr: Transition) -> (start: Int, cut: Int, length: Int)? { transitionFrames(tr, grid: grid, sound: sound) }
            var overlapInto: [String: (from: Clip, start: Int, length: Int)] = [:], overlapOut: [String: Int] = [:]
            if hints {
                let heard = clips.filter { !$0.reverse }
                for (a, b) in zip(heard, heard.dropFirst()) where !mine.contains(where: { $0.from == a.id || $0.to == b.id }) {
                    let s = grid.frames(b.audioRange.start), e = grid.frames(a.audioRange.end)
                    guard e > s, s > grid.frames(a.audioRange.start), e < grid.frames(b.audioRange.end) else { continue }
                    overlapInto[b.id] = (a, s, e - s)
                    overlapOut[a.id] = s
                }
            }
            let programEnd = grid.frames(duration)
            var list: [Event] = []
            for c in clips {
                let span = sound && !c.reverse ? c.audioRange : TimeRange(c.start, c.end)
                var e = Event(clip: c, r0: grid.frames(span.start), r1: grid.frames(span.end), t0: 0)
                if hints, !c.reverse, !mine.contains(where: { $0.from == c.id || $0.to == c.id }) {
                    var h = SoundHint(c, grid: grid)
                    h.overlap = overlapInto[c.id] != nil
                    if h.overlap || overlapOut[c.id] != nil || h.lead != 0 || h.lag != 0 || e.r1 > programEnd || e.r0 < 0 { e.hint = h }
                    // No sound plays past the program.
                    if overlapOut[c.id] == nil { e.r1 = min(e.r1, programEnd) }
                }
                if let o = overlapInto[c.id] {
                    e.r0 = o.start
                    e.into = (Transition(id: "", from: o.from.id, to: c.id, type: "dissolve", duration: seconds(o.length), align: .start, part: .audio), o.length, o.from)
                }
                if let s = overlapOut[c.id] { e.r1 = s }
                if let tr = mine.first(where: { $0.to == c.id }), let w = at(tr) {
                    if let f = tr.from, let from = clips.first(where: { $0.id == f }) {
                        e.r0 = w.start
                        e.into = (tr, w.length, from)
                    } else if tr.from == nil {
                        e.into = (tr, w.length, nil)
                    }
                }
                if let tr = mine.first(where: { $0.from == c.id }), let w = at(tr) {
                    if tr.to != nil {
                        e.r1 = w.start
                    } else {
                        e.r1 = max(e.r0, e.r1 - w.length)
                        e.out = (tr, w.length)
                    }
                }
                e.t0 = sourceTime(c, at: e.r0, sound: sound)
                if e.r0 < 0 {
                    e.t0 -= seconds(e.r0) * c.speed * (c.reverse ? -1 : 1)
                    e.r0 = 0
                    e.into = nil
                }
                guard e.end > e.r0, e.r1 >= e.r0 else { continue }
                list.append(e)
            }
            return list
        }

        let video = tracks.first { $0.kind == .video }
        /// Production sound of the main video track.
        func sounds(_ c: Clip, _ track: Track) -> Bool {
            guard c.kind == .media, let m = c.mediaId.flatMap(mediaAsset), m.hasAudio, !m.isImage, !track.muted else { return false }
            return c.volume > 1e-6 || c.anim["audio.volume"] != nil
        }
        func split(_ c: Clip) -> Bool { grid.frames(c.audioLead) != 0 || grid.frames(c.audioLag) != 0 }
        func listed(_ track: Track) -> [Clip] {
            track.clips.filter { c in
                guard c.kind == .media, let m = c.mediaId.flatMap(mediaAsset) else { return false }
                return track.kind == .video || m.hasAudio
            }.sorted { $0.start < $1.start }
        }
        // Sound, on lanes of channels: AA (1 and 2), A (1), A2 (2), and 3 and 4 (NONE with an AUD line).
        struct Lane: Equatable { var label: String; var aud: [Int]; var channels: [Int] }
        let aa = Lane(label: "AA", aud: [], channels: [1, 2]), a1 = Lane(label: "A", aud: [], channels: [1]), a2 = Lane(label: "A2", aud: [], channels: [2])
        let ch3 = Lane(label: "NONE", aud: [3], channels: [3]), ch4 = Lane(label: "NONE", aud: [4], channels: [4])
        let ch34 = Lane(label: "NONE", aud: [3, 4], channels: [3, 4])
        /// The lane of the source channels a clip is routed to, when CMX has one.
        func routed(_ c: Clip) -> Lane? {
            guard let r = c.channels else { return nil }
            switch r.form {
            case .single(1): return a1
            case .single(2): return a2
            case .single(3): return ch3
            case .single(4): return ch4
            case .pair(1, 2): return aa
            case .pair(3, 4): return ch34
            default: return nil
            }
        }
        /// Whether a clip's unrouted sound is one channel: its source has a single channel.
        func mono(_ c: Clip) -> Bool { c.channels == nil && c.mediaId.flatMap(mediaAsset)?.audioChannels?.count == 1 }
        /// The channels production sound takes riding on its picture event (A/V, A2/V or AA/V); nil when it is on
        /// channels a picture event can't carry.
        func riding(_ c: Clip) -> Lane? {
            if let r = routed(c) { return r.aud.isEmpty ? r : nil }
            return mono(c) ? a1 : aa
        }
        let pictures = video.map(listed) ?? []
        let production = video.map { v in pictures.filter { sounds($0, v) } } ?? []
        // Sound rides on its picture's events (A/V, AA/V) only where both cut and dissolve together.
        let heard = Set(production.map(\.id))
        var together = Set(production.filter { !split($0) && riding($0) != nil }.map(\.id))
        var settled = false
        while !settled {
            settled = true
            for tr in transitions {
                let ends = [tr.from, tr.to].compactMap { $0 }.filter(heard.contains)
                guard ends.contains(where: together.contains), tr.part != .both || !ends.allSatisfy(together.contains) else { continue }
                together.subtract(ends)
                settled = false
            }
        }

        // Picture; sound riding on it takes its channels (1 and 2 for stereo, 1 for a mono source).
        var busy: [Int: [(Int, Int)]] = [:]
        for e in events(pictures, sound: false, joins: { $0.hasVideo }) {
            let ride = together.contains(e.clip.id) ? riding(e.clip) : nil
            if let ride { for ch in ride.channels { busy[ch, default: []].append((e.r0, e.end)) } }
            write(e, ride.map { $0.label + "/V" } ?? "V", aud: [], picture: true)
        }
        flushMarkers(before: nil)

        /// A chain's lane: the one its clips are all routed to, else `fallback`.
        func lane(_ chain: [Event], _ fallback: Lane) -> Lane {
            guard let first = chain.first.flatMap({ routed($0.clip) }), chain.allSatisfy({ routed($0.clip) == first }) else {
                return fallback == aa && chain.allSatisfy({ mono($0.clip) }) ? a1 : fallback
            }
            return first
        }
        let audioTracks = Array(tracks.filter { $0.kind == .audio }.prefix(2))
        let hasProduction = !production.isEmpty
        var sources: [(events: [Event], lane: Lane)] = []
        let separate = production.filter { !together.contains($0.id) }
        if !separate.isEmpty { sources.append((events(separate, sound: true, joins: { $0.hasAudio }), aa)) }
        for (k, t) in audioTracks.enumerated() {
            let lane = hasProduction ? (k == 0 ? ch3 : ch4) : (k == 0 ? a1 : a2)
            sources.append((events(listed(t), sound: true, hints: true, joins: { $0.hasAudio }), lane))
        }
        // Each chain of events joined by transitions takes one lane: its own when free, else the first free one.
        func free(_ lane: Lane, _ chain: [Event]) -> Bool {
            chain.allSatisfy { e in lane.channels.allSatisfy { ch in (busy[ch] ?? []).allSatisfy { $0.1 <= e.r0 || $0.0 >= e.end } } }
        }
        func take(_ lane: Lane, _ chain: [Event]) {
            for e in chain { for ch in lane.channels { busy[ch, default: []].append((e.r0, e.end)) } }
        }
        func chains(_ list: [Event]) -> [[Event]] {
            var out: [[Event]] = []
            for e in list {
                if e.into?.from != nil, let last = out.last?.last, e.into?.from?.id == last.clip.id { out[out.count - 1].append(e) } else { out.append([e]) }
            }
            return out
        }
        var placed: [(lane: Lane, events: [Event])] = []
        var waiting: [(chain: [Event], lane: Lane)] = []
        for s in sources {
            for chain in chains(s.events) {
                let own = lane(chain, s.lane)
                if free(own, chain) { take(own, chain); placed.append((own, chain)) } else { waiting.append((chain, own)) }
            }
        }
        for (chain, own) in waiting {
            if let lane = [own, ch3, ch4, a1, a2].first(where: { free($0, chain) }) {
                take(lane, chain)
                placed.append((lane, chain))
                continue
            }
            // No channel is free: what overlaps is cut off its own lane.
            for var e in chain {
                for (b0, b1) in own.channels.flatMap({ busy[$0] ?? [] }).sorted(by: { $0.0 < $1.0 }) {
                    if b0 <= e.r0, b1 > e.r0 {
                        e.t0 += seconds(b1 - e.r0) * e.clip.speed * (e.clip.reverse ? -1 : 1)
                        e.r0 = b1
                        e.into = nil
                    } else if b0 > e.r0, b0 < e.end {
                        e.r1 = min(e.r1, b0)
                        e.out = nil
                    }
                }
                guard e.r1 > e.r0 else { continue }
                take(own, [e])
                placed.append((own, [e]))
            }
        }
        for lane in [aa, a1, a2, ch3, ch4, ch34] {
            let mine = placed.filter { $0.lane.label == lane.label && $0.lane.aud == lane.aud }.flatMap(\.events).sorted { $0.r0 < $1.r0 }
            for e in mine { write(e, lane.label, aud: lane.aud, picture: false) }
        }
        while out.last == "" { out.removeLast() }
        return out.joined(separator: "\n") + "\n"
    }
}

// MARK: Final Cut Pro 7 XML

extension Importer {
    /// Final Cut Pro 7 XML (xmeml 1–5), which Premiere Pro, Resolve and Hiero also write: the first
    /// sequence's video and audio tracks, clipitems with their `file` (defined once, referenced by id after),
    /// nested sequences, transitionitems (clip edges of -1 sit at the transition's cut, Premiere's `cutPointTicks`
    /// kept as an uneven cut), generators (text, color mattes, slugs, and Premiere's synthetic black, transparent,
    /// matte, bars and counting leader as solids), Time Remap speed, reverse and keyframes (ramps and freezes), Audio
    /// Levels with keyframes, Basic Motion (its scale of the media's own pixels read as fit, fill or a scaled fit), Crop, Opacity, a CDL and LUT files in clip comments (see `colorEffects`), each file's source timecode and
    /// reel, enabled flags and markers. Audio clipitems that only repeat a video clip's sound fold
    /// into it, linked ones in sync but starting or ending elsewhere fold in as split edits, and audio fades
    /// from or to black become clip fades; video clips whose sound isn't on an audio track are silent. A video
    /// transition between clips whose sound came from audio clipitems is picture only, and a crossfade between
    /// those sounds is audio only, unless the two match, which makes one transition of both. Files that don't exist, or that have no path, stay as offline media.
    /// A sound clipitem's `sourcetrack` in a file of more than two channels is its `audio.channels` (other channels
    /// of the same picture stay clips of their own). Multiclips become multicam sequences (an angle per `angle`
    /// clip), and butting clipitems of one multiclip one multicam clip cut at each `activevideoangle` change.
    public static func xmeml(_ data: Data, relativeTo base: URL?) throws -> ImportResult {
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data, options: []) } catch { throw EditError("Not valid XML: \(error.localizedDescription)") }
        guard let root = doc.rootElement(), root.name == "xmeml" else { throw EditError("Not a Final Cut Pro 7 XML document: the root element must be <xmeml>") }
        return try XMEMLReader(base: base).read(root)
    }
}

final class XMEMLReader {
    /// Premiere Pro's time unit.
    static let ticksPerSecond = 254_016_000_000.0

    let base: URL?
    var warnings: [String] = []
    var missing: [String] = []
    var media: [MediaAsset] = []
    var offline = Set<String>()
    var fileDefs: [String: XMLElement] = [:]
    var sequenceDefs: [String: XMLElement] = [:]
    var clipDefs: [String: XMLElement] = [:]
    /// Multiclip id → its multicam sequence and the angle names in order.
    var multiclips: [String: (id: String, angles: [String?])] = [:]
    var mediaByKey: [String: String] = [:]
    var usedMediaIds = Set<String>(), usedSequenceIds = Set<String>()
    var sequences: [NestedSequence] = []
    var nestedIds: [String: String] = [:]
    var reading = Set<String>()
    var markers: [Marker] = []
    var dropped: [(name: String, clips: [String])] = []
    var nestedMarkers = 0
    /// Media of baked graphics read back as the clips they stand for.
    var replaced = Set<String>()
    /// Clip ids to their clipitem ids, and the clipitems each is linked with.
    var xmlIds: [String: String] = [:]
    var links: [String: Set<String>] = [:]
    var clipCount = 0, transitionCount = 0
    var canvas = Canvas()

    init(base: URL?) { self.base = base }

    func text(_ e: XMLElement?, _ name: String) -> String? {
        e?.first(name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func number(_ e: XMLElement?, _ name: String) -> Double? { text(e, name).flatMap { Double($0) } }

    /// Frames per second of a `<rate>` (timebase, ntsc) inside `e`.
    func rate(_ e: XMLElement?) -> Double? {
        guard let r = e?.first("rate"), let base = number(r, "timebase"), base > 0 else { return nil }
        return text(r, "ntsc")?.uppercased() == "TRUE" ? base * 1000 / 1001 : base
    }

    func all(_ e: XMLElement) -> [XMLElement] { e.elems.flatMap { [$0] + all($0) } }

    func drop(_ what: String, on clip: String) {
        if let i = dropped.firstIndex(where: { $0.name == what }) { dropped[i].clips.append(clip) } else { dropped.append((what, [clip])) }
    }

    func read(_ root: XMLElement) throws -> ImportResult {
        for e in all(root) where !e.elems.isEmpty {
            guard let id = e.attr("id") else { continue }
            if e.name == "file", fileDefs[id] == nil { fileDefs[id] = e }
            if e.name == "sequence", sequenceDefs[id] == nil { sequenceDefs[id] = e }
            if e.name == "clip", clipDefs[id] == nil { clipDefs[id] = e }
        }
        // The sequence at the top, or the first one in a project's bins.
        var tops = root.elems.filter { $0.name == "sequence" }
        if tops.isEmpty {
            func bins(_ e: XMLElement) -> [XMLElement] {
                e.elems.flatMap { k -> [XMLElement] in
                    if k.name == "sequence" { return [k] }
                    return ["project", "children", "bin"].contains(k.name ?? "") ? bins(k) : []
                }
            }
            tops = bins(root)
        }
        guard let seq = tops.first else { throw EditError("No sequence in the XML") }
        if tops.count > 1 { warnings.append("The file has \(tops.count) sequences; imported \(text(seq, "name") ?? "the first")") }

        let fps = rate(seq) ?? 30
        let format = seq.first("media")?.first("video")?.first("format")?.first("samplecharacteristics")
        canvas = Canvas(width: Int(number(format, "width") ?? 1920), height: Int(number(format, "height") ?? 1080), fps: Importer.niceFps(fps))
        if let df = text(seq.first("timecode"), "displayformat")?.uppercased() { canvas.dropFrame = Canvas.dropFrame(df == "DF", fps: canvas.fps) }
        if let tc = seq.first("timecode") {
            let format = canvas.timecodeFormat
            if let frames = number(tc, "frame").map({ Int($0.rounded()) }) ?? text(tc, "string").flatMap { format.frames($0) }, frames >= 0 {
                canvas.timecodeStart = canvas.timecodeStart(frames: frames)
            }
        }

        let (tracks, transitions) = readBody(seq, top: true)
        for m in seq.elems where m.name == "marker" {
            guard let at = number(m, "in"), at >= 0 else { continue }
            markers.append(Marker(id: "marker\(markers.count + 1)", time: at / fps, label: markerLabel(m)))
        }
        var p = Project(name: text(seq, "name").flatMap { $0.isEmpty ? nil : $0 } ?? "Imported", canvas: canvas)
        p.media = media
        p.tracks = tracks.contains(where: { $0.kind == .video }) ? tracks : [Track(id: "V1", kind: .video, name: "Video 1")] + tracks
        p.transitions = transitions
        p.markers = markers.sorted { $0.time < $1.time }
        p.sequences = sequences
        p.joinMulticamPieces()
        if nestedMarkers > 0 { warnings.append("\(nestedMarkers) marker(s) inside nested sequences not kept") }
        for d in dropped { warnings.append(Importer.summarize(d.name, clips: d.clips)) }
        Importer.dropUnused(&p, replaced, missing: &missing)
        Importer.finish(&p, &warnings, offline: offline)
        return ImportResult(project: p, warnings: warnings, missingMedia: missing)
    }

    func markerLabel(_ m: XMLElement) -> String {
        text(m, "name").flatMap { $0.isEmpty ? nil : $0 } ?? text(m, "comment").flatMap { $0.isEmpty ? nil : $0 } ?? "Marker"
    }

    /// Tracks and transitions of a sequence, with repeated sound folded away.
    func readBody(_ seq: XMLElement, top: Bool) -> ([Track], [Transition]) {
        let fps = rate(seq) ?? canvas.fps
        var tracks: [Track] = []
        var transitions: [Transition] = []
        for kind in [TrackKind.video, .audio] {
            let holder = seq.first("media")?.first(kind == .video ? "video" : "audio")
            for (n, t) in (holder?.elems.filter { $0.name == "track" } ?? []).enumerated() {
                let enabled = text(t, "enabled")?.uppercased() != "FALSE"
                let name = text(t, "name").flatMap { $0.isEmpty ? nil : $0 } ?? "\(kind == .video ? "Video" : "Audio") \(n + 1)"
                let read = readTrack(t, kind: kind, fps: fps, top: top)
                transitions += read.transitions
                tracks.append(Track(id: "", kind: kind, name: name, muted: kind == .audio && !enabled, hidden: kind == .video && !enabled, clips: read.clips))
                if !read.disabled.isEmpty {
                    tracks.append(Track(id: "", kind: kind, name: "\(name) (disabled)", muted: kind == .audio, hidden: kind == .video, clips: read.disabled))
                }
            }
        }

        // Audio clipitems repeating a video clip's sound, or another channel's, fold away.
        let half = 0.5 / fps
        func same(_ a: Clip, _ b: Clip, channels: Bool = true) -> Bool {
            a.mediaId == b.mediaId && a.kind == b.kind && abs(a.start - b.start) < half && abs(a.duration - b.duration) < half
                && abs(a.sourceIn - b.sourceIn) < half && abs(a.speed - b.speed) < 1e-6 && a.reverse == b.reverse && (!channels || a.channels == b.channels)
        }
        var heard = Set<String>()
        var folded = Set<String>()
        /// Folded audio clips to the clip whose sound they carried.
        var soundOf: [String: String] = [:]
        func hear(_ a: Clip, in v: inout Clip, split: Bool) {
            v.volume = a.volume
            v.audioFadeIn = a.audioFadeIn
            v.audioFadeOut = a.audioFadeOut
            v.channels = a.channels
            if let c = a.anim["audio.volume"] { v.anim["audio.volume"] = c.shifted(by: a.start - v.start) }
            if split {
                v.audioLead = v.start - a.start
                v.audioLag = a.end - v.end
            } else if a.audioLead != 0 || a.audioLag != 0 {
                v.audioLead = a.audioLead
                v.audioLag = a.audioLag
            }
        }
        for t in tracks.indices where tracks[t].kind == .audio {
            for a in tracks[t].clips {
                for v in tracks.indices where tracks[v].kind == .video && !folded.contains(a.id) {
                    // Another source channel of a picture already heard stays a clip of its own.
                    guard let i = tracks[v].clips.firstIndex(where: { same($0, a, channels: false) && (!heard.contains($0.id) || $0.channels == a.channels) }) else { continue }
                    if !heard.contains(tracks[v].clips[i].id) { hear(a, in: &tracks[v].clips[i], split: false) }
                    heard.insert(tracks[v].clips[i].id)
                    folded.insert(a.id)
                    soundOf[a.id] = tracks[v].clips[i].id
                }
            }
        }
        // Sound linked to its picture but starting or ending elsewhere is a split edit.
        for t in tracks.indices where tracks[t].kind == .audio {
            for a in tracks[t].clips where !folded.contains(a.id) && a.kind == .media {
                let linked = links[a.id] ?? []
                for v in tracks.indices where tracks[v].kind == .video && !folded.contains(a.id) {
                    guard let i = tracks[v].clips.firstIndex(where: { c in
                        !heard.contains(c.id) && c.kind == .media && c.mediaId == a.mediaId && linked.contains(xmlIds[c.id] ?? "")
                            && abs(c.speed - a.speed) < 1e-6 && !c.reverse && !a.reverse
                            && a.start < c.end + half && c.start < a.end + half
                            && abs((a.sourceIn - a.start * a.speed) - (c.sourceIn - c.start * c.speed)) < half * max(a.speed, 1)
                            && abs(c.start - a.start) <= Importer.maxSplit + half && abs(a.end - c.end) <= Importer.maxSplit + half
                    }) else { continue }
                    hear(a, in: &tracks[v].clips[i], split: true)
                    heard.insert(tracks[v].clips[i].id)
                    folded.insert(a.id)
                    soundOf[a.id] = tracks[v].clips[i].id
                }
            }
        }
        // Other channels of sound already folded, linked to the same picture, go too.
        let heardXML = Set(heard.compactMap { xmlIds[$0] })
        var seen: [Clip] = []
        for t in tracks.indices where tracks[t].kind == .audio {
            let kept = tracks[t].clips.filter { a in
                if folded.contains(a.id) { return false }
                if !(links[a.id] ?? []).isDisjoint(with: heardXML),
                   let v = tracks.lazy.filter({ $0.kind == .video }).flatMap(\.clips).first(where: { heard.contains($0.id) && $0.mediaId == a.mediaId && $0.channels == a.channels && links[a.id]!.contains(xmlIds[$0.id] ?? "") }) {
                    soundOf[a.id] = v.id
                    return false
                }
                if let s = seen.first(where: { same($0, a) }) {
                    soundOf[a.id] = soundOf[s.id] ?? s.id
                    return false
                }
                seen.append(a)
                return true
            }
            if !tracks[t].clips.isEmpty, kept.isEmpty { tracks[t].id = "-" }
            tracks[t].clips = kept
        }
        tracks.removeAll { $0.id == "-" }
        // Clips that overlap on a track move to a track of their own below it.
        var split: [Track] = []
        for track in tracks {
            var lanes: [[Clip]] = [[]]
            for c in track.clips.sorted(by: { $0.start < $1.start }) {
                if let l = lanes.firstIndex(where: { ($0.last?.end ?? -.infinity) <= c.start + 1e-6 }) { lanes[l].append(c) } else { lanes.append([c]) }
            }
            for (n, clips) in lanes.enumerated() {
                var t = track
                t.clips = clips
                if n > 0 {
                    t.name += " (overlap \(n))"
                    warnings.append("Overlapping clips on \(track.name) moved to a track of their own")
                }
                split.append(t)
            }
        }
        tracks = split
        // Picture whose sound isn't on any audio track plays silent.
        for t in tracks.indices where tracks[t].kind == .video {
            for c in tracks[t].clips.indices where !heard.contains(tracks[t].clips[c].id) {
                let clip = tracks[t].clips[c]
                let sounds: Bool
                switch clip.kind {
                case .media: sounds = clip.mediaId.flatMap { id in media.first { $0.id == id } }?.hasAudio ?? false
                case .sequence: sounds = clip.mediaId.flatMap { id in sequences.first { $0.id == id } }.map(audible) ?? false
                default: sounds = false
                }
                if sounds { tracks[t].clips[c].volume = 0 }
            }
        }
        var v = 0, a = 0
        for t in tracks.indices {
            if tracks[t].kind == .video { v += 1; tracks[t].id = "V\(v)" } else { a += 1; tracks[t].id = "A\(a)" }
        }
        Importer.linkSeparateSound(&tracks, half: half)
        return (tracks, Importer.foldTransitions(transitions, soundOf: soundOf, separate: heard, frame: 1 / fps))
    }

    /// Whether anything in a nested sequence makes sound.
    func audible(_ seq: NestedSequence) -> Bool {
        seq.tracks.contains { t in
            t.clips.contains { c in
                guard c.volume > 0 else { return false }
                switch c.kind {
                case .media: return t.kind == .audio || (media.first { $0.id == c.mediaId }?.hasAudio ?? false)
                case .sequence: return sequences.first { $0.id == c.mediaId }.map(audible) ?? false
                default: return false
                }
            }
        }
    }

    /// A transitionitem in sequence frames, with the frame its clips' -1 edges stand for.
    struct Edge {
        var start: Double
        var end: Double
        var cut: Double
        var align: String
    }

    func readTrack(_ track: XMLElement, kind: TrackKind, fps: Double, top: Bool) -> (clips: [Clip], disabled: [Clip], transitions: [Transition]) {
        let entries = track.elems.filter { ["clipitem", "generatoritem", "transitionitem"].contains($0.name ?? "") }
        var edges: [Int: Edge] = [:]
        for (i, e) in entries.enumerated() where e.name == "transitionitem" {
            guard let s = number(e, "start"), let en = number(e, "end"), en > s else { continue }
            let align = text(e, "alignment")?.lowercased() ?? "center"
            var cut: Double
            switch align {
            case "start", "start-black": cut = s
            case "end", "end-black": cut = en
            default: cut = s + ((en - s) / 2).rounded(.down)
            }
            if let ticks = number(e, "cutPointTicks"), align == "center" || align.isEmpty {
                cut = s + (ticks / Self.ticksPerSecond * fps).rounded()
            }
            edges[i] = Edge(start: s, end: en, cut: cut, align: align)
        }
        // Cutline's sound hints, and the constant-gain crossfades between hinted clips that stand for overlapping sound.
        let grid = FrameGrid(fps: fps)
        let hints: [Int: SoundHint] = kind == .audio ? Dictionary(uniqueKeysWithValues: entries.enumerated().compactMap { i, e in
            text(e.first("comments"), "mastercomment4").flatMap(SoundHint.init(text:)).map { (i, $0) }
        }) : [:]
        let overlaps = Set(edges.keys.filter { i in
            let id = text(entries[i].first("effect"), "effectid") ?? ""
            return id == "KGAudioTransCrossFade0dB" && !edges[i]!.align.hasSuffix("black") && hints[i - 1] != nil && hints[i + 1] != nil
        })
        var hinted: [String: SoundHint] = [:]
        var clips: [Clip] = [], disabled: [Clip] = []
        var ids: [Int: String] = [:]
        var cursor = 0.0
        for (i, e) in entries.enumerated() where e.name != "transitionitem" {
            var s = number(e, "start") ?? -1, en = number(e, "end") ?? -1
            var mediaStart = s, mediaEnd = en
            if s < 0, let t = i > 0 ? edges[i - 1] : nil { s = overlaps.contains(i - 1) ? t.start : t.cut; mediaStart = t.start }
            if en < 0, let t = edges[i + 1] { en = overlaps.contains(i + 1) ? t.end : t.cut; mediaEnd = t.end }
            let length = (number(e, "out") ?? 0) - (number(e, "in") ?? 0)
            if s < 0 { s = en >= 0 ? en - length : cursor; mediaStart = s }
            if en < 0 { en = s + length; mediaEnd = en }
            if mediaStart < 0 { mediaStart = s }
            if mediaEnd < 0 { mediaEnd = en }
            cursor = en
            guard en > s else { continue }
            guard var c = item(e, kind: kind, fps: fps, start: s, end: en, mediaStart: mediaStart, mediaEnd: mediaEnd, top: top) else { continue }
            clipCount += 1
            c.id = "c\(clipCount)"
            c.start = s / fps
            c.duration = (en - s) / fps
            if let h = hints[i], c.kind == .media, !c.reverse {
                h.apply(&c, soundStart: Int(s.rounded()), grid: grid)
                hinted[c.id] = h
            }
            if text(e, "enabled")?.uppercased() == "FALSE" {
                disabled.append(c)
                continue
            }
            if top, c.kind == .media || c.kind == .sequence {
                let cr = rate(e) ?? fps
                for m in e.elems where m.name == "marker" {
                    guard let at = number(m, "in") else { continue }
                    let t = c.start + (at / cr - c.sourceIn) / max(c.speed, 0.01)
                    if t >= c.start - 1e-9 && t <= c.end + 1e-9 {
                        markers.append(Marker(id: "marker\(markers.count + 1)", time: t, label: markerLabel(m)))
                    }
                }
            } else if !top {
                nestedMarkers += e.elems.filter { $0.name == "marker" }.count
            }
            clips.append(c)
            ids[i] = c.id
            xmlIds[c.id] = e.attr("id")
            links[c.id] = Set(e.elems.filter { $0.name == "link" }.compactMap { text($0, "linkclipref") })
        }

        var transitions: [Transition] = []
        for (i, edge) in edges.sorted(by: { $0.key < $1.key }) where !overlaps.contains(i) {
            let e = entries[i]
            let from = ids[i - 1], to = ids[i + 1]
            guard from != nil || to != nil else { continue }
            // Sound fading from or to silence is the clip's own fade.
            if kind == .audio, edge.align == "start-black", let k = clips.firstIndex(where: { $0.id == to }) {
                clips[k].audioFadeIn = (edge.end - edge.start) / fps
                continue
            }
            if kind == .audio, edge.align == "end-black", let k = clips.firstIndex(where: { $0.id == from }) {
                clips[k].audioFadeOut = (edge.end - edge.start) / fps
                continue
            }
            let effect = e.first("effect")
            let name = text(effect, "name") ?? text(effect, "effectid") ?? "Transition"
            let lower = name.lowercased(), category = text(effect, "effectcategory")?.lowercased() ?? ""
            var type = "dissolve"
            if lower.contains("dip") || lower.contains("fade to") {
                type = "dip"
            } else if category.contains("wipe") || lower.contains("wipe") {
                type = "wipe"
                warnings.append("Transition \(name) imported as a left-to-right wipe")
            } else if !(lower.contains("dissolve") || lower.contains("cross fade") || lower.contains("crossfade") || lower.contains("constant")) {
                warnings.append("Transition \(name) imported as a dissolve")
            }
            let d = (edge.end - edge.start) / fps
            var align = TransitionAlign.center
            switch edge.align {
            case "start", "start-black": align = .start
            case "end", "end-black": align = .end
            default: break
            }
            let pair = from != nil && to != nil && !edge.align.hasSuffix("black")
            transitionCount += 1
            var made = Transition(id: "tr\(transitionCount)", from: edge.align == "start-black" ? nil : from, to: edge.align == "end-black" ? nil : to,
                                  type: type, duration: d, align: pair ? align : .center,
                                  part: kind == .audio ? .audio : .both)
            // A cut off the middle (Premiere's cutPointTicks) keeps its place.
            let before = edge.cut - edge.start
            if pair, align == .center, before > 0, before < edge.end - edge.start, abs(before - (edge.end - edge.start) / 2) > (number(e, "cutPointTicks") != nil ? 0.25 : 0.6) { made.cutOffset = before / fps }
            transitions.append(made)
        }
        for k in clips.indices {
            guard let h = hinted[clips[k].id] else { continue }
            clips[k].audioFadeIn = Double(h.fadeIn * grid.num) / Double(grid.den)
            clips[k].audioFadeOut = Double(h.fadeOut * grid.num) / Double(grid.den)
        }
        return (clips, disabled, transitions)
    }

    /// One clipitem or generatoritem between sequence frames `start` and `end`, whose media spans
    /// `mediaStart`–`mediaEnd` (wider than the clip under transitions).
    func item(_ e: XMLElement, kind: TrackKind, fps: Double, start: Double, end: Double, mediaStart: Double, mediaEnd: Double, top: Bool) -> Clip? {
        let name = text(e, "name").flatMap { $0.isEmpty ? nil : $0 } ?? (e.name == "generatoritem" ? "Generator" : "Clip")
        let duration = (end - start) / fps
        // The clip Cutline wrote whole: a title, solid, generator or baked graphic.
        if kind == .video, let json = text(e.first("comments"), "mastercomment3"), json.hasPrefix(Project.clipTag),
           let c = Project.restoredClip(json: json, placed: Clip(id: "", kind: .media, start: 0, duration: duration)) {
            if let f = e.first("file") {
                let file = f.attr("id").flatMap { fileDefs[$0] } ?? f
                replaced.insert(mediaId(file, key: f.attr("id"), clipName: name, kind: kind))
            }
            return c
        }
        if e.name == "generatoritem" { return generator(e, effect: e.first("effect"), name: name, kind: kind, duration: duration) }

        let cr = rate(e) ?? fps
        let inF = number(e, "in") ?? 0, outF = number(e, "out") ?? inF
        var c: Clip
        if let mc = e.first("multiclip") {
            guard let made = multiclip(mc, name: name) else { return nil }
            c = Clip(id: "", kind: .sequence, name: name == made.name ? nil : name, mediaId: made.id, start: 0, duration: duration, sourceIn: inF / cr)
            c.multicam = MulticamSwitch(cuts: [AngleCut(at: 0, angle: made.picture)], audio: made.sound)
        } else if let s = e.first("sequence") {
            guard let id = nested(s) else { return nil }
            c = Clip(id: "", kind: .sequence, name: name, mediaId: id, start: 0, duration: duration, sourceIn: inF / cr)
        } else {
            guard let f = e.first("file") else {
                warnings.append("Clipitem \(name) has no file; left as a gap")
                return nil
            }
            let file = f.attr("id").flatMap { fileDefs[$0] } ?? f
            let source = text(file, "mediaSource") ?? ""
            let pathless = (text(file, "pathurl") ?? "").isEmpty
            let generated = pathless ? Self.premiereGenerator(text(file, "name") ?? name) : nil
            if kind == .audio, let g = generated {
                if g == "bars" || g == "leader" { drop("Tone of \(text(file, "name") ?? name)", on: name) }
                return nil
            }
            if source == "Slug" || source == "GraphicAndType" || generated != nil {
                if let made = synthetic(e, file: file, source: source, name: name, kind: kind, duration: duration) { return made }
            }
            let id = mediaId(file, key: f.attr("id"), clipName: name, kind: kind)
            c = Clip(id: "", kind: .media, name: name, mediaId: id, start: 0, duration: duration, sourceIn: inF / cr)
        }

        // Speed: the frames used against the frames shown, else the Time Remap filter.
        var speed = 1.0, reverse = false, freeze = false
        var graph: [(when: Double, value: Double)] = [], basicScale: Double?
        var levelKeys: [(when: Double, gain: Double)] = []
        var levelBase = 1.0
        let shown = (mediaEnd - mediaStart) / fps, used = (outF - inF) / cr
        if shown > 0, used > 0, abs(used / shown - 1) > 0.005 { speed = used / shown }
        for effect in filters(e) {
            let id = (text(effect, "effectid") ?? "").lowercased(), effectName = text(effect, "name") ?? id
            let params = effect.elems.filter { $0.name == "parameter" }
            func param(_ key: String) -> XMLElement? { params.first { ($0.first("parameterid")?.stringValue ?? "").lowercased() == key } }
            switch id {
            case "timeremap", "speed":
                // Variable speed: source frames (`value`) at frames from the clipitem's first (`when`).
                graph = (param("graphdict")?.elems ?? []).filter { $0.name == "keyframe" }.compactMap { k in
                    guard let w = number(k, "when"), let v = number(k, "value") else { return nil }
                    return (w, v)
                }
                if text(param("variablespeed"), "value") == "1", graph.isEmpty { drop("Variable speed", on: name) }
                if text(param("reverse"), "value")?.uppercased() == "TRUE" { reverse = true }
                if let v = number(param("speed"), "value") {
                    if v < 0 { reverse = true }
                    if v == 0 { freeze = true } else if abs(abs(v) - 100) > 1e-6 {
                        // Percent in Final Cut Pro 7 and Premiere; Hiero writes the factor itself. More exact than
                        // the frame counts, which round.
                        let factor = abs(v) > 10 ? abs(v) / 100 : abs(v)
                        if speed == 1 || abs(factor - speed) < 0.03 * factor { speed = factor }
                    }
                }
            case "audiolevels":
                if let p = param("level") {
                    levelBase = c.volume
                    if let v = number(p, "value") { c.volume *= max(0, v) }
                    let keys = p.elems.filter { $0.name == "keyframe" }.compactMap { k -> (Double, Double)? in
                        guard let when = number(k, "when"), let v = number(k, "value") else { return nil }
                        return (when, max(0, v))
                    }
                    if !keys.isEmpty { levelKeys = keys }
                }
            case "basic":
                if let v = number(param("scale"), "value") { basicScale = max(0, v) / 100 }
                if let v = number(param("rotation"), "value") { c.transform.rotation = v }
                if let center = param("center")?.first("value") {
                    c.transform.x = number(center, "horiz") ?? 0
                    c.transform.y = number(center, "vert") ?? 0
                }
                if ["centeroffset", "anchorpoint"].contains(where: { k in param(k)?.first("value").map { (number($0, "horiz") ?? 0) != 0 || (number($0, "vert") ?? 0) != 0 } ?? false }) {
                    drop("Anchor point", on: name)
                }
                if params.contains(where: { $0.first("keyframe") != nil }) { drop("Motion keyframes", on: name) }
            case "crop":
                func edge(_ k: String) -> Double { min(max((number(param(k), "value") ?? 0) / 100, 0), 1) }
                c.transform.crop = Crop(left: edge("left"), top: edge("top"), right: edge("right"), bottom: edge("bottom"))
            case "opacity":
                if let p = param("opacity") {
                    if p.first("keyframe") != nil { drop("Opacity keyframes", on: name) }
                    if let v = number(p, "value") { c.transform.opacity = min(max(v / 100, 0), 1) }
                }
            default:
                drop("Filter \(effectName)", on: name)
            }
        }
        // Basic Motion scales the media's own pixels: its fit or fill size, or a stretch's width.
        if let k = basicScale {
            let m = c.kind == .media ? c.mediaId.flatMap { id in media.first { $0.id == id } } : nil
            let x = k / (canvas.mediaFitScale(m) ?? 1)
            if let w = canvas.setConform(&c, media: m, x: x, y: x) { warnings.append(w) }
        }
        if !graph.isEmpty, c.kind == .media {
            let map = graph.map { ((mediaStart + $0.when - start) / fps, $0.value / cr) }
            if let w = Importer.retime(&c, map: map, tolerance: 0.1 / max(fps, 1)) { warnings.append(w) }
        } else if freeze {
            Importer.freeze(&c)
        } else {
            if speed < 0.01 || speed > 100 {
                warnings.append("Speed \(speed)× on \(name) not kept")
                speed = 1
            }
            c.speed = Importer.niceSpeed(speed)
            c.reverse = reverse
            // Under an incoming transition the media starts at the transition, before the clip.
            c.sourceIn += (start - mediaStart) / fps * c.speed
            if reverse { c.sourceIn = inF / cr + (mediaEnd - end) / fps * c.speed }
        }
        // Level keyframes are in source frames; a key's time is where the clip plays that frame.
        if !levelKeys.isEmpty, levelBase > 0 {
            let keys = levelKeys.map { k in
                CurveKey(t: (k.when - inF) / cr / max(c.speed, 0.01) - (start - mediaStart) / fps, v: .number(k.gain * levelBase), ease: .linear)
            }
            c.anim["audio.volume"] = Curve(keys: keys)
        }
        if let comments = e.first("comments") {
            let note = comments.elems.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "; ")
            c.effects += Importer.noteColor(note.isEmpty ? comments.stringValue ?? "" : note)
        }
        // The source channel the item plays: its sourcetrack in a file of more than two channels, or Cutline's routing.
        if kind == .audio, c.kind == .media {
            let count = c.mediaId.flatMap { id in media.first { $0.id == id } }?.sourceChannelCount ?? 0
            if let n = number(e.first("sourcetrack"), "trackindex").map({ Int($0) }), n > 2 || (count > 2 && n >= 1) { c.channels = ChannelRouting(rawValue: "ch\(n)") }
            let notes = e.elems.filter { $0.name == "comments" }.flatMap(\.elems).compactMap(\.stringValue)
            if let s = notes.first(where: { $0.hasPrefix(Project.channelsTag) }) { c.channels = ChannelRouting(rawValue: String(s.dropFirst(Project.channelsTag.count))) ?? c.channels }
        }
        return c
    }

    /// Enabled effects of a clipitem's filters.
    func filters(_ e: XMLElement) -> [XMLElement] {
        e.elems.filter { $0.name == "filter" && text($0, "enabled")?.uppercased() != "FALSE" }.compactMap { $0.first("effect") }
    }

    /// Premiere's synthetic media: black video becomes a solid, graphics with their text become titles.
    func synthetic(_ e: XMLElement, file: XMLElement, source: String, name: String, kind: TrackKind, duration: Seconds) -> Clip? {
        let fileName = text(file, "name") ?? name
        if source == "GraphicAndType" {
            if let effect = filters(e).first(where: { text($0, "effectid") == "GraphicAndType" }), let words = text(effect, "name"), !words.isEmpty, kind == .video {
                warnings.append("Graphic \(name): its text is kept, its styling isn't")
                let t = words.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                return Clip(id: "", kind: .text, name: name, start: 0, duration: duration, text: TextSpec(text: t))
            }
            warnings.append("Graphic \(name) has no readable text; kept as offline media")
            return nil
        }
        guard kind == .video else { return nil }
        switch Self.premiereGenerator(fileName) {
        case "black":
            return Clip(id: "", kind: .solid, name: name, start: 0, duration: duration, color: .black)
        case "transparent":
            warnings.append("Transparent Video \(name) imported as an empty adjustment clip")
            return Clip(id: "", kind: .adjustment, name: name, start: 0, duration: duration)
        case "matte":
            if let color = filterColor(e) { return Clip(id: "", kind: .solid, name: name, start: 0, duration: duration, color: color) }
            warnings.append("Color Matte \(name): its color isn't in the file; imported as a black solid")
            return Clip(id: "", kind: .solid, name: name, start: 0, duration: duration, color: .black)
        case "bars":
            warnings.append("\(fileName) \(name) imported as a gray solid; the leader option of export draws real bars and tone")
            return Clip(id: "", kind: .solid, name: name, start: 0, duration: duration, color: RGBA(r: 0.75, g: 0.75, b: 0.75))
        case "leader":
            warnings.append("\(fileName) \(name) imported as a black solid")
            return Clip(id: "", kind: .solid, name: name, start: 0, duration: duration, color: .black)
        default:
            warnings.append("Premiere \(fileName) kept as offline media")
            return nil
        }
    }

    /// Premiere's synthetic media by file name: black, transparent, matte, bars or leader; nil for anything else.
    static func premiereGenerator(_ fileName: String) -> String? {
        let n = fileName.lowercased()
        if n == "black video" || n == "slug" { return "black" }
        if n == "transparent video" { return "transparent" }
        if n.hasPrefix("color matte") { return "matte" }
        if n.contains("bars and tone") || n.hasPrefix("smpte bars") || n == "bars" { return "bars" }
        if n.contains("counting leader") { return "leader" }
        return nil
    }

    /// A fill color in a clip's filters, as Premiere and Final Cut write mattes (0–255 channels).
    func filterColor(_ e: XMLElement) -> RGBA? {
        for effect in filters(e) {
            for p in effect.elems where p.name == "parameter" {
                guard let v = p.first("value"), number(v, "red") != nil else { continue }
                func channel(_ n: String) -> Double { min(max((number(v, n) ?? 0) / 255, 0), 1) }
                return RGBA(r: channel("red"), g: channel("green"), b: channel("blue"))
            }
        }
        return nil
    }

    func generator(_ e: XMLElement, effect: XMLElement?, name: String, kind: TrackKind, duration: Seconds) -> Clip? {
        guard kind == .video else { return nil }
        let id = (text(effect, "effectid") ?? "").lowercased(), category = (text(effect, "effectcategory") ?? "").lowercased()
        let params = effect?.elems.filter { $0.name == "parameter" } ?? []
        func param(_ key: String) -> XMLElement? { params.first { ($0.first("parameterid")?.stringValue ?? "").lowercased() == key } }
        if category == "text" || id.contains("text") {
            if let words = text(param("str"), "value"), !words.isEmpty {
                var spec = TextSpec(text: words.replacingOccurrences(of: "\r", with: "\n"))
                if let font = text(param("fontname"), "value"), !font.isEmpty { spec.font = font }
                if let px = number(param("fontsize"), "value"), px > 0 { spec.size = px / Double(min(canvas.width, canvas.height)) }
                if let style = number(param("fontstyle"), "value") { spec.weight = style == 2 || style == 4 ? 700 : 400 }
                if let a = number(param("fontalign"), "value") { spec.align = a == 1 ? .left : a == 3 ? .right : .center }
                func color(_ key: String) -> RGBA? {
                    guard let v = param(key)?.first("value"), number(v, "red") != nil else { return nil }
                    func channel(_ n: String) -> Double { min(max((number(v, n) ?? 255) / 255, 0), 1) }
                    return RGBA(r: channel("red"), g: channel("green"), b: channel("blue"), a: channel("alpha"))
                }
                if let c = color("fontcolor") { spec.color = c }
                if let v = param("origin")?.first("value") {
                    spec.x = 0.5 + (number(v, "horiz") ?? 0)
                    spec.y = 0.5 + (number(v, "vert") ?? 0)
                }
                if let c = color("linecolor"), let w = number(param("linewidth"), "value"), w > 0 {
                    spec.stroke = c
                    spec.strokeWidth = w / max(spec.size * Double(min(canvas.width, canvas.height)), 1)
                }
                return Clip(id: "", kind: .text, name: name == words ? nil : name, start: 0, duration: duration, text: spec)
            }
            warnings.append("Text generator \(name) has no text; left as a gap")
            return nil
        }
        if id == "color" || category == "matte" || id == "slug" {
            var color = RGBA.black
            if let v = param("fillcolor")?.first("value") {
                func channel(_ n: String) -> Double { min(max((number(v, n) ?? 0) / 255, 0), 1) }
                color = RGBA(r: channel("red"), g: channel("green"), b: channel("blue"))
            }
            return Clip(id: "", kind: .solid, name: name, start: 0, duration: duration, color: color)
        }
        warnings.append("Generator \(name) (\(text(effect, "name") ?? id)) left as a gap")
        return nil
    }

    /// Media for a `file`, shared by every clipitem naming the same file id.
    func mediaId(_ file: XMLElement, key fileKey: String?, clipName: String, kind: TrackKind) -> String {
        let url = text(file, "pathurl").flatMap { $0.isEmpty ? nil : $0 }
        let name = text(file, "name").flatMap { $0.isEmpty ? nil : $0 } ?? clipName
        let key = fileKey ?? url ?? "\u{0}" + name
        let fileMedia = file.first("media")
        if let id = mediaByKey[key], let i = media.firstIndex(where: { $0.id == id }) {
            if kind == .video { media[i].hasVideo = true } else { media[i].hasAudio = true }
            return id
        }
        let path = url.map { Importer.resolvePath($0, base: base, warnings: &warnings) } ?? name
        let fr = rate(file) ?? canvas.fps
        let video = fileMedia?.first("video"), sample = video?.first("samplecharacteristics")
        let hasVideo = video != nil || kind == .video, hasAudio = fileMedia?.first("audio") != nil || kind == .audio
        let ext = (path as NSString).pathExtension.lowercased()
        let isImage = Importer.stillExtensions.contains(ext) && (number(file, "duration") ?? 0) <= 1
        let id = Importer.unique(Importer.slug((name as NSString).deletingPathExtension), &usedMediaIds)
        var m = MediaAsset(id: id, path: path, name: (name as NSString).deletingPathExtension,
                           duration: isImage ? 0 : (number(file, "duration") ?? 0) / fr,
                           width: hasVideo ? Int(number(sample, "width") ?? number(file, "width") ?? Double(canvas.width)) : 0,
                           height: hasVideo ? Int(number(sample, "height") ?? number(file, "height") ?? Double(canvas.height)) : 0,
                           fps: hasVideo && !isImage ? Importer.niceFps(fr) : 0, hasVideo: hasVideo, hasAudio: hasAudio, isImage: isImage)
        if let tc = file.first("timecode"), !isImage {
            let display = text(tc, "displayformat")?.uppercased()
            let format = TimecodeFormat(fps: rate(tc) ?? fr, dropFrame: display == "DF" ? true : display == "NDF" ? false : nil)
            if let frames = number(tc, "frame").map({ Int($0.rounded()) }) ?? text(tc, "string").flatMap({ format.frames(reading: $0) }), frames > 0 {
                m.setTimecode(frames: frames, format: format)
            }
        }
        if let reel = text(file.first("timecode")?.first("reel"), "name"), !reel.isEmpty { m.reel = reel }
        if let rate = number(fileMedia?.first("audio")?.first("samplecharacteristics"), "samplerate"), rate > 0 { m.sampleRate = rate }
        m.audioChannels = Importer.sourceChannels((fileMedia?.elems.filter { $0.name == "audio" } ?? []).map { max(1, Int(number($0, "channelcount") ?? 1)) })
        media.append(m)
        mediaByKey[key] = id
        if !Importer.exists(path) {
            offline.insert(id)
            if !missing.contains(path) { missing.append(path) }
        }
        return id
    }

    /// A multiclip as a multicam sequence, read once per id, with an angle per `angle` clip; returns it with the
    /// angles this use marks active (the first angle when none is).
    func multiclip(_ mc: XMLElement, name clipName: String) -> (id: String, name: String, picture: String, sound: [String])? {
        let key = mc.attr("id") ?? text(mc, "name") ?? clipName
        let elems = mc.elems.filter { $0.name == "angle" }
        let name = text(mc, "name").flatMap { $0.isEmpty ? nil : $0 } ?? clipName
        if multiclips[key] == nil {
            var tracks: [Track] = [], angles: [MulticamAngle] = [], names: [String?] = []
            for (n, a) in elems.enumerated() {
                guard let ref = a.first("clip"), let clip = ref.attr("id").flatMap({ clipDefs[$0] }) ?? (ref.elems.isEmpty ? nil : ref) else { names.append(nil); continue }
                var angleName = text(clip, "name").flatMap { $0.isEmpty ? nil : $0 } ?? "Angle \(n + 1)"
                while angles.contains(where: { $0.name == angleName }) { angleName += " \(n + 1)" }
                let content = readBody(clip, top: false).0.filter { !$0.clips.isEmpty }
                guard let t = content.first(where: { $0.kind == .video }) ?? content.first, let first = t.clips.first(where: { $0.kind == .media }),
                      let m = media.first(where: { $0.id == first.mediaId }) else { names.append(nil); continue }
                let trackId = "angle\(angles.count + 1)"
                tracks.append(Track(id: trackId, kind: t.kind, name: angleName, clips: t.clips))
                angles.append(MulticamAngle(name: angleName, track: trackId, mediaId: m.id, offset: first.sourceIn - first.start, video: t.kind == .video, audio: m.hasAudio))
                names.append(angleName)
            }
            guard angles.contains(where: \.video) else {
                warnings.append("Multiclip \(name) has no video angle; left as a gap")
                return nil
            }
            let id = Importer.unique(Importer.slug(name), &usedSequenceIds)
            var seq = NestedSequence(id: id, name: name, tracks: tracks)
            seq.multicam = MulticamSetup(angles: angles, audio: angles.first(where: \.audio).map { [$0.name] } ?? [], sync: text(mc, "synctype") == "3" ? "timecode" : "in_points")
            sequences.append(seq)
            multiclips[key] = (id, names)
        }
        let known = multiclips[key]!
        func active(_ flag: String) -> String? {
            elems.indices.first { text(elems[$0], flag)?.uppercased() == "TRUE" }.flatMap { known.angles.indices.contains($0) ? known.angles[$0] : nil }
        }
        let first = known.angles.compactMap { $0 }
        let seqName = sequences.first { $0.id == known.id }?.name ?? name
        return (known.id, seqName, active("activevideoangle") ?? first.first ?? "", [active("activeaudioangle") ?? first.first].compactMap { $0 })
    }

    /// A nested sequence, read once per id.
    func nested(_ s: XMLElement) -> String? {
        let xmlId = s.attr("id")
        if let xmlId, let known = nestedIds[xmlId] { return known }
        let def = xmlId.flatMap { sequenceDefs[$0] } ?? s
        guard def.first("media") != nil else {
            warnings.append("Nested sequence \(xmlId ?? "") isn't in the file; left as a gap")
            return nil
        }
        if let xmlId {
            guard !reading.contains(xmlId) else { return nil }
            reading.insert(xmlId)
        }
        let (tracks, transitions) = readBody(def, top: false)
        nestedMarkers += def.elems.filter { $0.name == "marker" }.count
        let name = text(def, "name").flatMap { $0.isEmpty ? nil : $0 } ?? "Nested \(sequences.count + 1)"
        let id = Importer.unique(Importer.slug(name), &usedSequenceIds)
        sequences.append(NestedSequence(id: id, name: name, tracks: tracks, transitions: transitions))
        if let xmlId { nestedIds[xmlId] = id; reading.remove(xmlId) }
        return id
    }
}

extension Project {
    /// Final Cut Pro 7 XML (xmeml version 5) for Premiere Pro, Resolve and Final Cut Pro 7, timed in canvas
    /// frames. Video tracks come bottom first, then audio: the sound of video clips on an audio track of its
    /// own after each video track's, then the audio tracks. Each file is described at its first use and
    /// referenced by id after. Dissolves (wipes stay wipes, dips become Dip to Black) are transitionitems on the
    /// picture cut and sound crossfades are audio transitionitems on the sound cut, with the clips' edges under them
    /// written as -1 and their media spanning the transition; an uneven one keeps its cut as Premiere's
    /// `cutPointTicks`. Every in, out, start and end counts from the same frame, so a clipitem plays as many source
    /// frames as it lasts at normal speed. Speed and reverse are a Time Remap filter, ramps and freezes its keyframes
    /// (`graphdict`: the source frame at frames from the clipitem's first); opacity is Opacity, scale (the fit or fill
    /// size in the media's own pixels; a stretch is written fit), position and rotation Basic Motion, and crop Crop; the CDL and LUT files are a clip comment (`ASC_SOP …; LUT <path>`).
    /// Sound clipitems are linked to their picture and span the audio range, so split edits keep
    /// their own in and out; levels are Audio Levels (keyframed when animated, track faders and master gain
    /// folded in) and fades 0 dB cross fades from or to black. Sound overlapping the next clip's on its track is a
    /// 0 dB crossfade over the overlap, and no sound plays past the program; where the clipitem can't say where a
    /// clip's sound sits, `mastercomment4` holds a `SoundHint`. Text clips become Text (or Outline Text) generators
    /// with string, font, size, color, alignment and origin, solids Color mattes, each with the whole Cutline clip
    /// in `mastercomment3`; nested sequences are nested sequences, multicam clips a clipitem per angle switch playing
    /// a `multiclip` of every angle with the active ones marked; a file has an `audio` per source track, and a sound
    /// clipitem's `sourcetrack` is its first routed channel (the routing in `mastercomment2`); adjustment and generator clips are left out. The
    /// sequence's timecode is the canvas's start timecode; each file declares its own audio sample rate and its
    /// source timecode (at its own rate and drop frame) with its reel. Clip in and out points stay zero-based.
    public func xmeml() -> String { scopedToTimeline().splittingMulticam().xmeml(InterchangeContext()) }

    func xmeml(_ ctx: InterchangeContext) -> String {
        let grid = FrameGrid(fps: canvas.fps)
        let timebase = max(1, Int(grid.rate.rounded()))
        let ntsc = grid.num == 1001
        func f(_ t: Seconds) -> Int { grid.frames(t) }
        func leaf(_ name: String, _ value: String) -> XMLElem { XMLElem(name, text: value) }
        func rate() -> XMLElem { XMLElem("rate", children: [leaf("timebase", "\(timebase)"), leaf("ntsc", ntsc ? "TRUE" : "FALSE")]) }
        func timecode(_ frames: Int) -> XMLElem {
            XMLElem("timecode", children: [rate(), leaf("string", EDLTimecode.string(frames, nominal: timebase, drop: canvas.isDropFrame)),
                                           leaf("frame", "\(frames)"), leaf("displayformat", canvas.isDropFrame ? "DF" : "NDF")])
        }
        func parameter(_ id: String, _ name: String, _ value: String, min: String? = nil, max: String? = nil) -> XMLElem {
            XMLElem("parameter", children: [leaf("parameterid", id), leaf("name", name)] + (min.map { [leaf("valuemin", $0)] } ?? [])
                + (max.map { [leaf("valuemax", $0)] } ?? []) + [leaf("value", value)])
        }
        func effect(_ name: String, id: String, category: String, type: String, mediaType: String, _ params: [XMLElem]) -> XMLElem {
            XMLElem("effect", children: [leaf("name", name), leaf("effectid", id), leaf("effectcategory", category),
                                         leaf("effecttype", type), leaf("mediatype", mediaType)] + params)
        }
        func number(_ v: Double) -> String {
            let s = String(format: "%.6f", v)
            var t = s
            while t.hasSuffix("0") { t.removeLast() }
            if t.hasSuffix(".") { t.removeLast() }
            return t
        }

        var described = Set<String>()
        func file(_ m: MediaAsset) -> XMLElem {
            let id = "file-\(m.id)"
            if described.contains(id) { return XMLElem("file", [("id", id)]) }
            described.insert(id)
            var kids = [leaf("name", (m.conformPath as NSString).lastPathComponent.isEmpty ? m.name : (m.conformPath as NSString).lastPathComponent)]
            if m.conformPath.hasPrefix("/") {
                kids.append(leaf("pathurl", m.conformURL.absoluteString.replacingOccurrences(of: "file:///", with: "file://localhost/")))
            }
            kids += [rate(), leaf("duration", "\(m.isImage ? 1 : f(m.duration))")]
            // The file's own timecode, at its rate and drop frame, with its reel.
            let tf = m.timecodeFormat(fallback: canvas.fps, dropFrame: canvas.dropFrame)
            let tcFrames = m.isImage ? 0 : m.timecodeFrames(fallback: canvas.fps) ?? 0
            var tcKids = [XMLElem("rate", children: [leaf("timebase", "\(tf.nominal)"), leaf("ntsc", tf.frameNum == 1001 ? "TRUE" : "FALSE")]),
                          leaf("string", tf.string(tcFrames)), leaf("frame", "\(tcFrames)"), leaf("displayformat", tf.dropFrame ? "DF" : "NDF")]
            if let reel = m.reel, !reel.isEmpty { tcKids.append(XMLElem("reel", children: [leaf("name", reel)])) }
            kids.append(XMLElem("timecode", children: tcKids))
            var mediaKids: [XMLElem] = []
            if m.hasVideo {
                mediaKids.append(XMLElem("video", children: [XMLElem("samplecharacteristics", children: [
                    rate(), leaf("width", "\(m.width > 0 ? m.width : canvas.width)"), leaf("height", "\(m.height > 0 ? m.height : canvas.height)"),
                ])]))
            }
            if m.hasAudio {
                // One audio element per source track, so sourcetrack's trackindex counts source channels.
                for count in Project.channelLayout(m) {
                    mediaKids.append(XMLElem("audio", children: [
                        XMLElem("samplecharacteristics", children: [leaf("depth", "16"), leaf("samplerate", "\(m.sampleRate.map { Int($0.rounded()) } ?? 48000)")]), leaf("channelcount", "\(count)"),
                    ]))
                }
            }
            kids.append(XMLElem("media", children: mediaKids))
            return XMLElem("file", [("id", id)], children: kids)
        }

        var sequenceDescribed = Set<String>()
        var multiclipUses = 0
        /// A multiclip with every angle as a clip of its own, written whole at each use (as Premiere reads them), the
        /// piece's picture and first sound angle marked active.
        func multiclip(_ seq: NestedSequence, _ setup: MulticamSetup, picture: String, sound: [String], scope: Project) -> XMLElem {
            multiclipUses += 1
            var kids = [leaf("name", seq.name), leaf("collapsed", "FALSE"), leaf("synctype", setup.sync == "timecode" ? "3" : "1")]
            for (n, a) in setup.angles.enumerated() {
                guard let t = seq.tracks.first(where: { $0.id == a.track }) else { continue }
                let id = "multiclip-\(seq.id)/\(multiclipUses)/angle\(n + 1)"
                var angle: [XMLElem] = []
                if a.name == picture { angle.append(leaf("activevideoangle", "TRUE")) }
                if a.name == sound.first { angle.append(leaf("activeaudioangle", "TRUE")) }
                let body = sequenceElem(scope.inside(NestedSequence(id: seq.id, name: a.name, tracks: [t])), id: id, name: a.name, markers: [])
                angle.append(XMLElem("clip", [("id", id)], children: body.children.filter { $0.name != "timecode" }))
                kids.append(XMLElem("angle", children: angle))
            }
            return XMLElem("multiclip", [("id", "multiclip-\(seq.id)")], children: kids)
        }
        func sequenceElem(_ scope: Project, id: String, name: String, markers: [Marker]) -> XMLElem {
            let windows = scope.transitionWindows
            let top = id == "sequence-1"
            let prefix = top ? "" : id + "/"
            /// A transitionitem over `at` (first frame, cut frame, length in sequence frames).
            func transitionItem(_ tr: Transition, _ at: (start: Int, cut: Int, length: Int), kind: TrackKind) -> XMLElem {
                let align: String
                if tr.from == nil {
                    align = "start-black"
                } else if tr.to == nil {
                    align = "end-black"
                } else {
                    align = tr.align == .start ? "start" : tr.align == .end ? "end" : "center"
                }
                let name: String, id: String, category: String
                switch (tr.type, kind) {
                case (_, .audio): (name, id, category) = ("Cross Fade (+3dB)", "KGAudioTransCrossFade3dB", "audiotransition")
                case ("wipe", _): (name, id, category) = ("Edge Wipe", "Edge Wipe", "Wipe")
                case ("dip", _): (name, id, category) = ("Dip to Color Dissolve", "Dip to Color Dissolve", "Dissolve")
                default: (name, id, category) = ("Cross Dissolve", "Cross Dissolve", "Dissolve")
                }
                // Premiere's cut point within an uneven transition, in its ticks.
                let ticks = tr.from != nil && tr.to != nil && tr.cutOffset != nil ? [leaf("cutPointTicks", "\((at.cut - at.start) * 254_016_000_000 * grid.num / grid.den)")] : []
                return XMLElem("transitionitem", children: [
                    leaf("start", "\(at.start)"), leaf("end", "\(at.start + at.length)"), leaf("alignment", align)] + ticks + [rate(),
                    effect(name, id: id, category: category, type: "transition", mediaType: kind == .audio ? "audio" : "video", []),
                ])
            }
            func byte(_ v: Double) -> String { "\(Int((min(max(v, 0), 1) * 255).rounded()))" }
            /// Audio fade from or to silence: a 0 dB cross fade against black at the edge of a sound clipitem.
            func fadeItem(_ start: Int, _ end: Int, into: Bool) -> XMLElem {
                XMLElem("transitionitem", children: [
                    leaf("start", "\(start)"), leaf("end", "\(end)"), leaf("alignment", into ? "start-black" : "end-black"), rate(),
                    effect("Cross Fade (0dB)", id: "KGAudioTransCrossFade0dB", category: "audiotransition", type: "transition", mediaType: "audio", []),
                ])
            }
            /// Sound overlapping its neighbour's on one track: a constant-gain crossfade over `at`, cut where the clipitems meet.
            func overlapItem(_ at: (start: Int, cut: Int, length: Int)) -> XMLElem {
                XMLElem("transitionitem", children: [
                    leaf("start", "\(at.start)"), leaf("end", "\(at.start + at.length)"), leaf("alignment", "center"),
                    leaf("cutPointTicks", "\((at.cut - at.start) * 254_016_000_000 * grid.num / grid.den)"), rate(),
                    effect("Cross Fade (0dB)", id: "KGAudioTransCrossFade0dB", category: "audiotransition", type: "transition", mediaType: "audio", []),
                ])
            }
            func emits(_ c: Clip, _ kind: TrackKind) -> Bool {
                switch c.kind {
                case .media: return c.mediaId.flatMap { scope.mediaAsset($0) } != nil
                case .sequence: return c.mediaId.flatMap { scope.sequence($0) } != nil
                case .text, .solid: return kind == .video
                default: return false
                }
            }
            func itemId(_ c: Clip, sound: Bool) -> String { "clipitem-\(prefix)\(c.id)\(sound ? "-audio" : "")" }

            // Tracks in output order, so linked picture and sound can name each other's place.
            let videoTracks = scope.tracks.filter { $0.kind == .video }
            let soundTracks: [Track] = videoTracks.filter { !$0.muted }.compactMap { track in
                var sound = track
                sound.clips = track.clips.filter { c in
                    guard c.volume > 1e-6 || c.anim["audio.volume"] != nil else { return false }
                    switch c.kind {
                    case .media: return c.mediaId.flatMap { scope.mediaAsset($0) }.map { $0.hasAudio && !$0.isImage } ?? false
                    case .sequence: return c.mediaId.flatMap { scope.sequence($0) }?.tracks.contains { $0.kind == .audio && !$0.clips.isEmpty || $0.kind == .video && $0.clips.contains { $0.kind == .media } } ?? false
                    default: return false
                    }
                }
                return sound.clips.isEmpty ? nil : sound
            }
            var places: [String: XMLElem] = [:]
            func plan(_ tracks: [Track], kind: TrackKind, sound: Bool) {
                for (t, track) in tracks.enumerated() {
                    let clips = track.clips.filter { emits($0, kind) }.sorted { $0.start < $1.start }
                    for (n, c) in clips.enumerated() {
                        var kids = [leaf("linkclipref", itemId(c, sound: sound)), leaf("mediatype", kind == .video ? "video" : "audio"),
                                    leaf("trackindex", "\(t + 1 + (sound || kind == .video ? 0 : soundTracks.count))"), leaf("clipindex", "\(n + 1)")]
                        if kind == .audio { kids.append(leaf("groupindex", "1")) }
                        places[itemId(c, sound: sound)] = XMLElem("link", children: kids)
                    }
                }
            }
            plan(videoTracks, kind: .video, sound: false)
            plan(soundTracks, kind: .audio, sound: true)
            func links(_ c: Clip) -> [XMLElem] {
                guard let v = places[itemId(c, sound: false)], let a = places[itemId(c, sound: true)] else { return [] }
                return [v, a]
            }

            /// `sound` is the audio of a video track. Sound crossfades sit on the sound cut, dissolves on the picture cut.
            func trackElem(_ track: Track, kind: TrackKind, sound: Bool) -> XMLElem {
                let clips = track.clips.sorted { $0.start < $1.start }
                let ids = Set(clips.map(\.id))
                let audio = kind == .audio
                let mine = windows.map(\.transition).filter { tr in
                    (audio ? tr.hasAudio : tr.hasVideo) && [tr.from, tr.to].compactMap { $0 }.allSatisfy(ids.contains)
                }
                func at(_ tr: Transition) -> (start: Int, cut: Int, length: Int)? { scope.transitionFrames(tr, grid: grid, sound: audio) }
                /// A transition, or with none sound overlapping its neighbour's: a constant-gain crossfade over the overlap.
                typealias Join = (tr: Transition?, at: (start: Int, cut: Int, length: Int))
                var joinsIn: [String: Join] = [:], joinsOut: [String: Join] = [:]
                for tr in mine {
                    guard let a = tr.from, let b = tr.to, let w = at(tr) else { continue }
                    if joinsIn[b] == nil { joinsIn[b] = (tr, w) }
                    if joinsOut[a] == nil { joinsOut[a] = (tr, w) }
                }
                var overlapped = Set<String>()
                if audio {
                    let heardClips = clips.filter { $0.kind == .media && !$0.reverse && emits($0, kind) }
                    for (a, b) in zip(heardClips, heardClips.dropFirst()) where joinsOut[a.id] == nil && joinsIn[b.id] == nil
                        && !mine.contains(where: { $0.from == a.id && $0.to == nil || $0.to == b.id && $0.from == nil }) {
                        let s = f(b.audioRange.start), e = f(a.audioRange.end)
                        guard e > s, s > (joinsIn[a.id]?.at.cut ?? f(a.audioRange.start)), e < f(b.audioRange.end) else { continue }
                        let picture = f(b.start)
                        let cut = picture >= s && picture <= e ? picture : (s + e) / 2
                        joinsOut[a.id] = (nil, (s, cut, e - s))
                        joinsIn[b.id] = (nil, (s, cut, e - s))
                        overlapped.formUnion([a.id, b.id])
                    }
                }
                let programEnd = f(scope.duration)
                var items: [XMLElem] = []
                for c in clips {
                    let into = joinsIn[c.id], outOf = joinsOut[c.id]
                    let black = (into: mine.first { $0.to == c.id && $0.from == nil }, out: mine.first { $0.from == c.id && $0.to == nil })
                    if let j = into {
                        items.append(j.tr.map { transitionItem($0, j.at, kind: kind) } ?? overlapItem(j.at))
                    } else if let tr = black.into, let w = at(tr) {
                        items.append(transitionItem(tr, w, kind: kind))
                    }
                    // Sound plays over the audio range, so split edits keep their own in and out; none plays outside the program.
                    let heard = audio && c.kind == .media && !c.reverse
                    let span = heard ? c.audioRange : TimeRange(c.start, c.end)
                    let s = f(span.start), e = f(span.end)
                    let r0 = into?.at.cut ?? (audio ? max(s, 0) : s), r1 = outOf?.at.cut ?? (audio && black.out == nil ? min(e, programEnd) : e)
                    guard e > s, r1 > r0 else { continue }
                    let head = into.map { r0 - $0.at.start } ?? 0, tail = outOf.map { $0.at.start + $0.at.length - r1 } ?? 0
                    let length = r1 - r0 + head + tail
                    var kids = [leaf("name", c.name ?? c.mediaId.flatMap { scope.mediaAsset($0)?.name } ?? c.kind.rawValue),
                                leaf("enabled", "TRUE"), leaf("duration", "\(length)"), rate(),
                                leaf("start", into != nil ? "-1" : "\(r0)"), leaf("end", outOf != nil ? "-1" : "\(r1)")]
                    /// Source frames played over `n` sequence frames.
                    func played(_ n: Int) -> Int { Int((Double(n) * c.speed).rounded()) }
                    var sourceFrame = 0
                    switch c.kind {
                    case .media:
                        guard let m = c.mediaId.flatMap({ scope.mediaAsset($0) }) else { continue }
                        let inF: Int, outF: Int
                        // A ramp or freeze: Time Remap keys at the clipitem's frames, over the source range they reach.
                        let lo = r0 - head - f(c.start), hi = r1 + tail - f(c.start)
                        let graph = c.isRetimed && !m.isImage ? c.timeMap(frames: lo, hi, grid: grid) : []
                        if m.isImage {
                            (inF, outF) = (0, length)
                        } else if let a = graph.first, let b = graph.last {
                            inF = f(min(a.source, b.source))
                            outF = max(f(max(a.source, b.source)), inF + 1)
                            sourceFrame = inF
                        } else if c.reverse {
                            (inF, outF) = (f(min(c.sourceIn, c.sourceOut)) - played(head), f(max(c.sourceIn, c.sourceOut)) + played(tail))
                        } else {
                            // In and out count from the same frame as start and end, so both span the same frames.
                            sourceFrame = f(heard ? c.audioSourceRange.start : c.sourceIn)
                            (inF, outF) = (sourceFrame + played(r0 - s - head), sourceFrame + played(r1 - s + tail))
                        }
                        if c.reverse, graph.isEmpty { sourceFrame = f(min(c.sourceIn, c.sourceOut)) }
                        kids += [leaf("in", "\(inF)"), leaf("out", "\(outF)"), file(m)]
                        if kind == .audio { kids.append(XMLElem("sourcetrack", children: [leaf("mediatype", "audio"), leaf("trackindex", "\(c.channels?.sourceChannels.first ?? 1)")])) }
                        if let a = graph.first, let b = graph.last {
                            let average = (b.source - a.source) / max(Double((b.frame - a.frame) * grid.num) / Double(grid.den), 1e-9)
                            var keys = XMLElem("parameter", children: [leaf("parameterid", "graphdict"), leaf("name", "graphdict")])
                            keys.children += graph.map { p in
                                XMLElem("keyframe", children: [leaf("when", "\(p.frame - lo)"), leaf("value", number((p.source * grid.rate * 1000).rounded() / 1000))])
                            }
                            kids.append(XMLElem("filter", children: [effect("Time Remap", id: "timeremap", category: "motion", type: "motion", mediaType: "video", [
                                parameter("variablespeed", "variablespeed", "1"),
                                parameter("speed", "speed", number((average * 100 * 1000).rounded() / 1000)),
                                parameter("reverse", "reverse", c.reverse ? "TRUE" : "FALSE"),
                                parameter("frameblending", "frameblending", "FALSE"),
                                keys,
                            ])]))
                        } else if abs(c.speed - 1) > 1e-9 || c.reverse {
                            kids.append(XMLElem("filter", children: [effect("Time Remap", id: "timeremap", category: "motion", type: "motion", mediaType: "video", [
                                parameter("variablespeed", "variablespeed", "0"),
                                parameter("speed", "speed", number(c.speed * 100 * (c.reverse ? -1 : 1))),
                                parameter("reverse", "reverse", c.reverse ? "TRUE" : "FALSE"),
                                parameter("frameblending", "frameblending", "FALSE"),
                            ])]))
                        }
                    case .sequence:
                        guard let seq = c.mediaId.flatMap({ scope.sequence($0) }) else { continue }
                        let inner = f(c.sourceIn), k = Project.sequenceRate(c)
                        func through(_ n: Int) -> Int { Int((Double(n) * k).rounded()) }
                        kids += [leaf("in", "\(inner + through(r0 - s - head))"), leaf("out", "\(inner + through(r1 - s + tail))")]
                        let ref = "sequence-\(seq.id)"
                        if let setup = seq.multicam {
                            let shown = scope.visibleAngleRanges(c).first
                            kids.append(multiclip(seq, setup, picture: shown?.angle ?? setup.videoAngles.first?.name ?? "", sound: shown?.audio ?? setup.audio, scope: scope))
                        } else if sequenceDescribed.contains(ref) {
                            kids.append(XMLElem("sequence", [("id", ref)]))
                        } else {
                            sequenceDescribed.insert(ref)
                            kids.append(sequenceElem(scope.inside(seq), id: ref, name: seq.name, markers: []))
                        }
                        if abs(k - 1) > 1e-9 {
                            kids.append(XMLElem("filter", children: [effect("Time Remap", id: "timeremap", category: "motion", type: "motion", mediaType: "video", [
                                parameter("variablespeed", "variablespeed", "0"),
                                parameter("speed", "speed", number(k * 100)),
                                parameter("reverse", "reverse", "FALSE"),
                                parameter("frameblending", "frameblending", "FALSE"),
                            ])]))
                        }
                    case .text where kind == .video:
                        let spec = c.text ?? TextSpec(text: c.name ?? "")
                        func rgba(_ id: String, _ name: String, _ v: RGBA) -> XMLElem {
                            XMLElem("parameter", children: [leaf("parameterid", id), leaf("name", name), XMLElem("value", children: [
                                leaf("alpha", byte(v.a)), leaf("red", byte(v.r)), leaf("green", byte(v.g)), leaf("blue", byte(v.b)),
                            ])])
                        }
                        // Final Cut's Text and Outline Text generators: the string, font, size in pixels, color, alignment, and
                        // origin as an offset from the center in fractions of the frame, as Basic Motion's center.
                        let outline = spec.stroke != nil && spec.strokeWidth > 0
                        var params = [
                            parameter("str", "Text", spec.text), parameter("fontname", "Font", Self.fcpFont(spec.font)),
                            parameter("fontsize", "Size", number((spec.size * Double(min(canvas.width, canvas.height))).rounded()), min: "0", max: "1000"),
                            parameter("fontstyle", "Style", spec.weight >= 600 ? "2" : "1", min: "1", max: "4"),
                            parameter("fontalign", "Alignment", spec.align == .left ? "1" : spec.align == .right ? "3" : "2", min: "1", max: "3"),
                            rgba("fontcolor", "Font Color", spec.color),
                            XMLElem("parameter", children: [leaf("parameterid", "origin"), leaf("name", "Origin"),
                                                            XMLElem("value", children: [leaf("horiz", number(spec.x - 0.5)), leaf("vert", number(spec.y - 0.5))])]),
                        ]
                        if outline, let stroke = spec.stroke {
                            params += [rgba("linecolor", "Line Color", stroke), parameter("linewidth", "Line Width", number(spec.strokeWidth * spec.size * Double(min(canvas.width, canvas.height))))]
                        }
                        kids += [leaf("in", "0"), leaf("out", "\(length)"), effect(outline ? "Outline Text" : "Text", id: outline ? "Outline Text" : "Text", category: "Text", type: "generator", mediaType: "video", params)]
                    case .solid where kind == .video:
                        let color = c.color ?? .black
                        kids += [leaf("in", "0"), leaf("out", "\(length)"), effect("Color", id: "Color", category: "Matte", type: "generator", mediaType: "video", [
                            XMLElem("parameter", children: [leaf("parameterid", "fillcolor"), leaf("name", "Color"), XMLElem("value", children: [
                                leaf("alpha", "255"), leaf("red", byte(color.r)), leaf("green", byte(color.g)), leaf("blue", byte(color.b)),
                            ])]),
                        ])]
                    default:
                        continue
                    }
                    if kind == .audio {
                        // No track or master gain in xmeml: both fold into the clip's level.
                        let level = scope.bakedLevel(c, track: track, grid: grid, master: top)
                        if abs(level.gain - 1) > 1e-6 || !level.keys.isEmpty {
                            var p = parameter("level", "Level", number(level.gain), min: "0", max: "3.98109")
                            // Keyframes are in source frames, like the clip's in and out.
                            let itemStart = heard ? -c.audioLead : 0
                            p.children += level.keys.map { k in
                                XMLElem("keyframe", children: [leaf("when", "\(sourceFrame + Int((Double(f(k.t - itemStart)) * c.speed).rounded()))"), leaf("value", number(k.gain))])
                            }
                            kids.append(XMLElem("filter", children: [effect("Audio Levels", id: "audiolevels", category: "audiolevels", type: "audiolevels", mediaType: "audio", [p])]))
                        }
                    }
                    if kind == .video {
                        let t = c.transform
                        // Basic Motion scales the media's own pixels: the fit, fill (or a stretch's fit) size times the clip's scale.
                        let conform = scope.canvas.conformScale(c.kind == .media ? c.mediaId.flatMap { scope.mediaAsset($0) } : nil, crop: t.crop, fit: t.fit == .stretch ? .fit : t.fit)
                        let pixels = (scope.canvas.mediaFitScale(c.kind == .media ? c.mediaId.flatMap { scope.mediaAsset($0) } : nil) ?? 1) * conform.x * t.scale
                        if abs(pixels - 1) > 1e-6 || t.x != 0 || t.y != 0 || t.rotation != 0 {
                            kids.append(XMLElem("filter", children: [effect("Basic Motion", id: "basic", category: "motion", type: "motion", mediaType: "video", [
                                parameter("scale", "Scale", number(pixels * 100), min: "0", max: "1000"),
                                parameter("rotation", "Rotation", number(t.rotation), min: "-8640", max: "8640"),
                                XMLElem("parameter", children: [leaf("parameterid", "center"), leaf("name", "Center"),
                                                                XMLElem("value", children: [leaf("horiz", number(t.x)), leaf("vert", number(t.y))])]),
                            ])]))
                        }
                        if !t.crop.isEmpty {
                            kids.append(XMLElem("filter", children: [effect("Crop", id: "crop", category: "motion", type: "motion", mediaType: "video", [
                                parameter("left", "left", number(t.crop.left * 100), min: "0", max: "100"),
                                parameter("right", "right", number(t.crop.right * 100), min: "0", max: "100"),
                                parameter("top", "top", number(t.crop.top * 100), min: "0", max: "100"),
                                parameter("bottom", "bottom", number(t.crop.bottom * 100), min: "0", max: "100"),
                            ])]))
                        }
                        if t.opacity < 1 - 1e-6 {
                            kids.append(XMLElem("filter", children: [effect("Opacity", id: "opacity", category: "motion", type: "motion", mediaType: "video", [
                                parameter("opacity", "opacity", number(t.opacity * 100), min: "0", max: "100"),
                            ])]))
                        }
                        // The grade as a note: Premiere has no place for a CDL or LUT.
                        let grade = c.kind == .media ? (c.cdl.map { [$0.text] } ?? []) + c.lutFiles.map { "LUT \($0)" } + (ctx.luts[c.id].map { ["\(Project.gradeLUTTag) \($0)"] } ?? []) : []
                        var comments: [XMLElem] = []
                        if !grade.isEmpty { comments.append(leaf("mastercomment1", grade.joined(separator: "; "))) }
                        // The whole Cutline clip, for what the generator items can't say.
                        if let e = ctx.embedded(c) { comments.append(leaf("mastercomment3", Project.clipTag + Project.clipJSON(e))) }
                        if !comments.isEmpty { kids.append(XMLElem("comments", children: comments)) }
                    }
                    // What the clipitem can't say about the clip's sound, for Cutline to read back.
                    let hint = SoundHint(c, grid: grid)
                    var soundNotes: [XMLElem] = []
                    if kind == .audio, c.kind == .media, let ch = c.channels { soundNotes.append(leaf("mastercomment2", Project.channelsTag + ch.rawValue)) }
                    if heard, overlapped.contains(c.id) || (into == nil && r0 != s) || (outOf == nil && r1 != e) || (track.kind == .audio && (hint.lead != 0 || hint.lag != 0)) {
                        soundNotes.append(leaf("mastercomment4", hint.text))
                    }
                    if !soundNotes.isEmpty { kids.append(XMLElem("comments", children: soundNotes)) }
                    if c.kind == .media || c.kind == .sequence { kids += links(c) }
                    if heard, into == nil, black.into == nil, c.audioFadeIn > 0 { items.append(fadeItem(r0, min(r1, r0 + max(1, f(c.audioFadeIn))), into: true)) }
                    items.append(XMLElem(c.kind == .text || c.kind == .solid ? "generatoritem" : "clipitem", [("id", itemId(c, sound: sound))], children: kids))
                    if let tr = black.out, let w = at(tr) { items.append(transitionItem(tr, w, kind: kind)) } else if heard, outOf == nil, c.audioFadeOut > 0 {
                        items.append(fadeItem(max(r0, r1 - max(1, f(c.audioFadeOut))), r1, into: false))
                    }
                }
                return XMLElem("track", children: items + [leaf("enabled", (kind == .video ? track.hidden : track.muted) ? "FALSE" : "TRUE"), leaf("locked", "FALSE")])
            }

            var video: [XMLElem] = [XMLElem("format", children: [XMLElem("samplecharacteristics", children: [
                rate(), leaf("width", "\(canvas.width)"), leaf("height", "\(canvas.height)"), leaf("pixelaspectratio", "square"),
            ])])]
            var audio: [XMLElem] = [XMLElem("format", children: [XMLElem("samplecharacteristics", children: [leaf("depth", "16"), leaf("samplerate", "48000")])])]
            for track in videoTracks {
                video.append(trackElem(track, kind: .video, sound: false))
            }
            for sound in soundTracks {
                audio.append(trackElem(sound, kind: .audio, sound: true))
            }
            for track in scope.tracks where track.kind == .audio {
                audio.append(trackElem(track, kind: .audio, sound: false))
            }
            var kids = [leaf("name", name), leaf("duration", "\(f(scope.duration))"), rate(), timecode(top ? startFrame : 0),
                        XMLElem("media", children: [XMLElem("video", children: video), XMLElem("audio", children: audio)])]
            for m in markers.sorted(by: { $0.time < $1.time }) where m.time >= 0 {
                kids.append(XMLElem("marker", children: [leaf("name", m.label), leaf("comment", ""), leaf("in", "\(f(m.time))"), leaf("out", "-1")]))
            }
            return XMLElem("sequence", [("id", id)], children: kids)
        }

        let root = XMLElem("xmeml", [("version", "5")], children: [sequenceElem(self, id: "sequence-1", name: name, markers: markers)])
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE xmeml>\n"
        root.write(&out, depth: 0)
        return out
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
