import Foundation

/// Files found for relinking, by name.
public struct RelinkIndex: Sendable {
    var byName: [String: [String]] = [:]
    var byStem: [String: [String]] = [:]

    public init(_ paths: [String]) {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            byName[url.lastPathComponent.lowercased(), default: []].append(path)
            byStem[url.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(path)
        }
    }

    /// The file for `m`: the same file name, else the same name ignoring the extension (a picture for a picture).
    /// Ties prefer the candidate sharing the most trailing folders with the old path.
    public func match(_ m: MediaAsset) -> String? {
        let old = URL(fileURLWithPath: m.conformPath)
        var candidates = byName[old.lastPathComponent.lowercased()] ?? []
        if candidates.isEmpty {
            candidates = (byStem[old.deletingPathExtension().lastPathComponent.lowercased()] ?? [])
                .filter { Project.imageExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) == m.isImage }
        }
        return candidates.max { a, b in
            let sa = Project.sharedFolders(a, m.conformPath), sb = Project.sharedFolders(b, m.conformPath)
            return sa != sb ? sa < sb : a.count > b.count
        }
    }
}

extension Project {
    /// Media whose file `exists` doesn't find.
    public func missingMedia(exists: (String) -> Bool) -> [MediaAsset] {
        media.filter { !exists($0.path) }
    }

    /// Points a media item at another file. Returns false for an unknown id. A transcoded item
    /// forgets its mezzanine and points at the new file as its own original.
    @discardableResult
    public mutating func relink(mediaId: String, to path: String) -> Bool {
        guard let i = media.firstIndex(where: { $0.id == mediaId }) else { return false }
        media[i].path = path
        media[i].originalPath = nil
        media[i].transcoded = nil
        return true
    }

    /// Relinks every missing media item to a file found under `searchRoots`: same file name first,
    /// then same name ignoring the extension. Ties prefer the candidate sharing the most trailing
    /// folders with the old path. Returns (media id, new path) for each relinked item.
    @discardableResult
    public mutating func relinkAll(searchRoots: [URL], fileExists: (String) -> Bool) -> [(String, String)] {
        let missing = missingMedia(exists: fileExists)
        guard !missing.isEmpty else { return [] }
        let index = RelinkIndex(Project.files(under: searchRoots))
        var out: [(String, String)] = []
        for m in missing {
            guard let best = index.match(m) else { continue }
            relink(mediaId: m.id, to: best)
            out.append((m.id, best))
        }
        return out
    }

    /// Regular files under `roots`, recursively, skipping hidden files and package contents.
    public static func files(under roots: [URL]) -> [String] {
        var out: [String] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.append(url.standardizedFileURL.path)
            }
        }
        return out
    }

    /// Among probed `candidates` (their `path` set), the file for offline `m` by reel and timecode: the same reel
    /// (`m`'s reel, else its EDL reel from the file name) and a timecode span covering the source time `m`'s clips
    /// play (its whole length when unused), the shortest such file when several do. Nil without a timecode on `m`.
    public func reelTimecodeMatch(_ m: MediaAsset, candidates: [MediaAsset]) -> MediaAsset? {
        guard let start = m.timecodeStart, !m.isImage else { return nil }
        let reel = Project.edlReel(m)
        let used = usedSourceRanges(handles: 0)[m.id] ?? []
        let lo = start + (used.map(\.start).min() ?? 0), hi = start + (used.map(\.end).max() ?? m.duration)
        let tol = 0.5 / max(m.fps, 24)
        return candidates.filter { c in
            guard let cs = c.timecodeStart, let r = c.reel, !c.isImage, Project.edlReel(r) == reel else { return false }
            guard !m.hasVideo || c.hasVideo, !m.hasAudio || c.hasAudio else { return false }
            return cs <= lo + tol && cs + c.duration >= hi - tol
        }.min { $0.duration < $1.duration }
    }

    static let maxNesting = 16
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp"]

    /// Trailing parent folder names two paths have in common.
    static func sharedFolders(_ a: String, _ b: String) -> Int {
        let pa = Array(URL(fileURLWithPath: a).deletingLastPathComponent().pathComponents.reversed())
        let pb = Array(URL(fileURLWithPath: b).deletingLastPathComponent().pathComponents.reversed())
        var n = 0
        while n < min(pa.count, pb.count), pa[n].lowercased() == pb[n].lowercased() { n += 1 }
        return n
    }

    /// Merged source ranges of each time-based media item the edit plays: picture with transition
    /// handles, sound with split-edit lead and lag, and the visible part of nested sequences.
    /// Clips on hidden and muted tracks count. Each range grows by `handles`, clamped to the file.
    public func usedSourceRanges(handles: Seconds) -> [String: [TimeRange]] {
        var raw: [String: [TimeRange]] = [:]
        collectSourceUses(tracks: tracks, transitions: transitions, window: nil, clipWindows: true, depth: 0) { _, mediaId, range in
            raw[mediaId, default: []].append(range)
        }
        var out: [String: [TimeRange]] = [:]
        for (id, ranges) in raw {
            guard let m = mediaAsset(id) else { continue }
            out[id] = TimeRange.merged(ranges.map { padded($0, handles, m) })
        }
        return out
    }

    func padded(_ r: TimeRange, _ handles: Seconds, _ m: MediaAsset) -> TimeRange {
        let end = m.duration > 0 ? min(m.duration, r.end + handles) : r.end + handles
        return TimeRange(max(0, r.start - handles), max(max(0, r.start - handles), end))
    }

    /// Source span one media clip reads: picture plus `head`/`tail` transition handles, and its sound.
    func sourceHull(_ c: Clip, media m: MediaAsset, head: Seconds, tail: Seconds) -> TimeRange? {
        guard !m.isImage else { return nil }
        var parts: [TimeRange] = []
        if m.hasVideo {
            parts.append(c.reverse ? TimeRange(c.sourceIn, c.sourceOut)
                : TimeRange(c.sourceIn - head * c.speed(atLocal: 0), c.sourceOut + tail * c.speed(atLocal: c.duration)))
        }
        if m.hasAudio {
            let a = c.audioSourceRange
            parts.append(c.reverse ? TimeRange(min(a.start, c.sourceIn), max(a.end, c.sourceOut)) : a)
        }
        guard let lo = parts.map(\.start).min(), let hi = parts.map(\.end).max() else { return nil }
        return TimeRange(lo, hi)
    }

    /// Calls `use` with (clip path, media id, source hull) for every media clip, walking into sequences.
    /// With `clipWindows`, clips inside a sequence count only where the sequence clip shows them.
    /// `depth` counts levels already entered; walking stops at `maxNesting`.
    func collectSourceUses(tracks: [Track], transitions: [Transition], window: TimeRange?, clipWindows: Bool, depth: Int, prefix: String = "", _ use: (String, String, TimeRange) -> Void) {
        guard depth < Project.maxNesting else { return }
        var view = self
        view.tracks = tracks
        view.transitions = transitions
        view = view.resolvingAudioTransitions()
        var heads: [String: Seconds] = [:], tails: [String: Seconds] = [:]
        for w in view.transitionWindows {
            if let id = w.transition.from { tails[id] = max(tails[id] ?? 0, w.tail) }
            if let id = w.transition.to { heads[id] = max(heads[id] ?? 0, w.head) }
        }
        for track in view.tracks {
            for clip in track.clips {
                var c = clip
                var head = heads[c.id] ?? 0, tail = tails[c.id] ?? 0
                if clipWindows, let window {
                    guard c.end > window.start + eps, c.start < window.end - eps else { continue }
                    if c.start < window.start - eps { c = Project.trimmedLeft(c, to: window.start); head = 0 }
                    if c.end > window.end + eps { c = Project.trimmedRight(c, to: window.end); tail = 0 }
                }
                switch c.kind {
                case .media:
                    guard let id = c.mediaId, let m = mediaAsset(id), let hull = sourceHull(c, media: m, head: head, tail: tail) else { continue }
                    use(prefix + clip.id, id, hull)
                case .sequence:
                    guard let seq = c.mediaId.flatMap({ sequence($0) }) else { continue }
                    let inner = TimeRange(max(0, c.sourceIn - head), Project.sequenceWindow(c).end + tail)
                    collectSourceUses(tracks: seq.tracks, transitions: seq.transitions, window: inner, clipWindows: clipWindows, depth: depth + 1, prefix: prefix + clip.id + "/", use)
                default:
                    continue
                }
            }
        }
    }
}

/// How to collect a project's media into one folder, optionally keeping only the used source ranges.
/// Whole copies keep their media id. Trimmed copies get one file per merged range: the first keeps the media id,
/// later ones are "<id>_t<n>"; clips move to the copy that holds them and their `sourceIn` drops by its `offset`.
public struct ConsolidatePlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// Media the copy comes from.
        public var mediaId: String
        /// Id of the copy in the rewritten project.
        public var newId: String
        public var sourcePath: String
        /// Source seconds kept; nil copies the whole file.
        public var range: TimeRange?
        /// File name inside the destination folder.
        public var fileName: String

        /// Source time in the original minus this is the time in the copy.
        public var offset: Seconds { range?.start ?? 0 }
    }

    public var items: [Item]
    public var trim: Bool
    /// With `trim`: whether the project's other timelines keep their media too; otherwise they're left out.
    public var allTimelines: Bool

    /// Without `trim`, every media item is copied whole. With it, unused media is dropped, stills are
    /// copied whole, and time-based media keeps the ranges clips read (entire nested clips) plus `handles`: clips of
    /// the current timeline and its sequences, and of the other timelines with `allTimelines`.
    public init(_ project: Project, trim: Bool, handles: Seconds, allTimelines: Bool = false) {
        self.trim = trim
        self.allTimelines = allTimelines
        var names = Set<String>()
        func unique(_ name: String) -> String {
            let url = URL(fileURLWithPath: name)
            let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
            var candidate = name, n = 2
            while names.contains(candidate.lowercased()) {
                candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
                n += 1
            }
            names.insert(candidate.lowercased())
            return candidate
        }
        var items: [Item] = []
        guard trim else {
            for m in project.media {
                items.append(Item(mediaId: m.id, newId: m.id, sourcePath: m.path, range: nil, fileName: unique(m.url.lastPathComponent)))
            }
            self.items = items
            return
        }
        var raw: [String: [TimeRange]] = [:]
        var stills = Set<String>()
        Self.wholeClipUses(project, allTimelines: allTimelines) { _, id, r in raw[id, default: []].append(r) }
        for c in Self.mediaClips(project, allTimelines: allTimelines) {
            if let id = c.mediaId, project.mediaAsset(id)?.isImage == true { stills.insert(id) }
        }
        for m in project.media {
            if stills.contains(m.id) {
                items.append(Item(mediaId: m.id, newId: m.id, sourcePath: m.path, range: nil, fileName: unique(m.url.lastPathComponent)))
                continue
            }
            guard let ranges = raw[m.id] else { continue }
            let stem = m.url.deletingPathExtension().lastPathComponent
            for (n, r) in TimeRange.merged(ranges.map { project.padded($0, handles, m) }).enumerated() {
                items.append(Item(mediaId: m.id, newId: n == 0 ? m.id : "\(m.id)_t\(n + 1)", sourcePath: m.path, range: r, fileName: unique("\(stem)_t\(n + 1).mov")))
            }
        }
        self.items = items
    }

    /// Whole media clips of the top level (keyed by clip id) and of every sequence ("<sequence id>:<clip id>"),
    /// each measured with the transitions of its own timeline.
    static func wholeClipUses(_ p: Project, allTimelines: Bool = false, _ use: (String, String, TimeRange) -> Void) {
        p.collectSourceUses(tracks: p.tracks, transitions: p.transitions, window: nil, clipWindows: false, depth: Project.maxNesting - 1, use)
        for seq in p.sequences {
            p.collectSourceUses(tracks: seq.tracks, transitions: seq.transitions, window: nil, clipWindows: false, depth: Project.maxNesting - 1, prefix: "\(seq.id):", use)
        }
        guard allTimelines else { return }
        for (i, t) in p.timelines.enumerated() {
            p.collectSourceUses(tracks: t.tracks, transitions: t.transitions, window: nil, clipWindows: false, depth: Project.maxNesting - 1, prefix: "timeline\(i):", use)
        }
    }

    static func mediaClips(_ p: Project, allTimelines: Bool = false) -> [Clip] {
        (p.tracks + p.sequences.flatMap(\.tracks) + (allTimelines ? p.timelines.flatMap(\.tracks) : [])).flatMap(\.clips).filter { $0.kind == .media }
    }

    /// Media of `project` the plan leaves out, each with why: "offline" (its file is missing), "only on other
    /// timelines" (used there but not on the current one) or "unused".
    public func skipped(_ project: Project) -> [(mediaId: String, reason: String)] {
        let kept = Set(items.map(\.mediaId))
        let elsewhere = Set(project.timelines.flatMap(\.tracks).flatMap(\.clips).compactMap(\.mediaId))
        return project.media.filter { !kept.contains($0.id) }.map { m in
            if !FileManager.default.fileExists(atPath: m.path) { return (m.id, "offline") }
            if elsewhere.contains(m.id) { return (m.id, "only on other timelines") }
            return (m.id, "unused")
        }
    }

    /// The copy holding `range` of a media item's source, if any.
    public func item(for mediaId: String, containing range: TimeRange) -> Item? {
        items.first { i in
            guard i.mediaId == mediaId else { return false }
            guard let r = i.range else { return true }
            // Clip ends may sit a frame past a file's measured duration, where the copy ends too.
            return r.start <= max(0, range.start) + 1e-6 && range.end <= r.end + 0.05
        }
    }

    /// The copy and its time for a source time of the original, for remapping analysis.
    public func locate(mediaId: String, time: Seconds) -> (mediaId: String, time: Seconds)? {
        item(for: mediaId, containing: TimeRange(time, time)).map { ($0.newId, time - $0.offset) }
    }

    /// The project pointing at the copies in `directory`. Trimmed copies take their range as duration. Caption edits
    /// and translations on words of `transcripts` follow the words into the copies' re-timed transcripts.
    public func apply(to project: Project, directory: URL, transcripts: [String: Transcript] = [:]) -> Project {
        var p = project
        p.media = items.compactMap { i in
            guard var m = project.mediaAsset(i.mediaId) else { return nil }
            m.id = i.newId
            m.path = directory.appendingPathComponent(i.fileName).path
            if let r = i.range {
                m.duration = r.duration
                // A trimmed copy of a mezzanine no longer lines up with the camera original.
                m.originalPath = nil
                m.transcoded = nil
                // Its first frame keeps the source timecode it had in the original.
                if let frames = m.timecodeFrames(fallback: project.canvas.fps) {
                    let f = m.timecodeFormat(fallback: project.canvas.fps, dropFrame: project.canvas.dropFrame)
                    m.setTimecode(frames: frames + f.frameCount(r.start), format: f)
                }
            }
            return m
        }
        guard trim else { return p }
        var hulls: [String: TimeRange] = [:]
        Self.wholeClipUses(project, allTimelines: allTimelines) { path, _, r in hulls[path] = r }
        func remap(_ c: inout Clip, key: String) {
            guard c.kind == .media, let id = c.mediaId, project.mediaAsset(id)?.isImage == false,
                  let hull = hulls[key], let it = item(for: id, containing: hull) else { return }
            c.mediaId = it.newId
            // Rounded so frame-exact times don't land a hair early (CMTime(seconds:) truncates).
            c.sourceIn = ((c.sourceIn - it.offset) * 1e9).rounded() / 1e9
        }
        for t in p.tracks.indices {
            for c in p.tracks[t].clips.indices { remap(&p.tracks[t].clips[c], key: p.tracks[t].clips[c].id) }
        }
        for s in p.sequences.indices {
            let sid = p.sequences[s].id
            for t in p.sequences[s].tracks.indices {
                for c in p.sequences[s].tracks[t].clips.indices { remap(&p.sequences[s].tracks[t].clips[c], key: "\(sid):\(p.sequences[s].tracks[t].clips[c].id)") }
            }
        }
        if allTimelines {
            for i in p.timelines.indices {
                for t in p.timelines[i].tracks.indices {
                    for c in p.timelines[i].tracks[t].clips.indices { remap(&p.timelines[i].tracks[t].clips[c], key: "timeline\(i):\(p.timelines[i].tracks[t].clips[c].id)") }
                }
            }
        } else {
            p.timelines = []
        }
        remapWords(&p.captions, transcripts: transcripts)
        for i in p.timelines.indices { remapWords(&p.timelines[i].captions, transcripts: transcripts) }
        return p
    }

    /// Where word `index` of `mediaId`'s transcript lands: the copy and its index in the copy's transcript.
    public func locateWord(_ mediaId: String, _ index: Int, in transcript: Transcript) -> (mediaId: String, index: Int)? {
        for i in items where i.mediaId == mediaId {
            if let n = i.retimed(transcript).words[index] { return (i.newId, n) }
        }
        return nil
    }

    private func remapWords(_ captions: inout Captions, transcripts: [String: Transcript]) {
        guard trim else { return }
        func moved(_ m: String, _ w: Int) -> (mediaId: String, index: Int)? { transcripts[m].flatMap { locateWord(m, w, in: $0) } }
        captions.edits = captions.edits.compactMap { e in
            guard transcripts[e.mediaId] != nil else { return e }
            guard let a = moved(e.mediaId, e.fromWord) else { return nil }
            let z = (e.fromWord...max(e.fromWord, e.toWord)).reversed().lazy.compactMap { moved(e.mediaId, $0) }.first { $0.mediaId == a.mediaId } ?? a
            var e = e
            e.mediaId = a.mediaId
            e.fromWord = a.index
            e.toWord = z.index
            return e
        }
        func anchor(_ s: String) -> String? {
            guard let (m, w) = Project.parseWordAnchor(s), transcripts[m] != nil else { return s }
            return moved(m, w).map { "\($0.mediaId).w\($0.index)" }
        }
        for (tag, list) in captions.translations {
            let kept = list.compactMap { t -> CaptionTranslation? in
                guard let a = anchor(t.from), let z = anchor(t.to) else { return nil }
                var t = t
                t.from = a
                t.to = z
                return t
            }
            captions.translations[tag] = kept.isEmpty ? nil : kept
        }
    }
}

/// Analysis of an item's source re-timed to the copy: times drop by its offset and what lies outside its range is
/// left out. Whole copies keep the analysis as it is.
extension ConsolidatePlan.Item {
    func keeps(_ t: Seconds) -> Bool { range.map { t >= $0.start && t < $0.end } ?? true }

    func clipped(_ r: TimeRange) -> TimeRange? {
        guard let range else { return r }
        return r.intersection(range).map { TimeRange($0.start - offset, $0.end - offset) }
    }

    /// The copy's transcript, and for each kept word its index in the copy (keyed by its index in the original).
    public func retimed(_ t: Transcript) -> (transcript: Transcript, words: [Int: Int]) {
        var out = t
        out.mediaId = newId
        out.words = []
        var map: [Int: Int] = [:]
        var speakers: [String?] = []
        for (i, w) in t.words.enumerated() where keeps((w.start + w.end) / 2) {
            map[i] = out.words.count
            var w = w
            w.start -= offset
            w.end -= offset
            out.words.append(w)
            if let s = t.speakers, i < s.count { speakers.append(s[i]) }
        }
        out.speakers = t.speakers == nil ? nil : speakers
        return (out, map)
    }

    /// `words` is `retimed(transcript).words` for the same media.
    public func retimed(_ s: SpeakerAnalysis, words: [Int: Int]) -> SpeakerAnalysis {
        let order = words.sorted { $0.value < $1.value }.map(\.key)
        return SpeakerAnalysis(
            mediaId: newId, speakers: s.speakers,
            segments: s.segments.compactMap { g in clipped(TimeRange(g.start, g.end)).map { SpeakerSegment(start: $0.start, end: $0.end, speaker: g.speaker, confidence: g.confidence) } },
            wordSpeakers: order.map { $0 < s.wordSpeakers.count ? s.wordSpeakers[$0] : nil },
            emphasis: order.map { $0 < s.emphasis.count ? s.emphasis[$0] : 0 })
    }

    public func retimed(_ a: AudioAnalysis) -> AudioAnalysis {
        guard let range else { return a }
        var out = a
        out.mediaId = newId
        let lo = min(a.levels.count, max(0, Int((range.start * a.levelRate).rounded(.down))))
        let hi = min(a.levels.count, max(lo, Int((range.end * a.levelRate).rounded(.up))))
        out.levels = Array(a.levels[lo..<hi])
        out.silences = a.silences.compactMap(clipped)
        return out
    }

    public func retimed(_ v: VisualAnalysis) -> VisualAnalysis {
        VisualAnalysis(mediaId: newId, sceneCuts: v.sceneCuts.filter { keeps($0) && $0 > offset }.map { $0 - offset })
    }

    public func retimed(_ s: ShotAnalysis) -> ShotAnalysis {
        let shots = s.shots.compactMap { shot -> Shot? in
            guard let r = clipped(TimeRange(shot.start, shot.end)) else { return nil }
            var shot = shot
            shot.start = r.start
            shot.end = r.end
            return shot
        }.enumerated().map { i, shot in
            var shot = shot
            shot.index = i
            return shot
        }
        let faces = s.faces.compactMap { f -> FaceTrack? in
            let samples = f.samples.filter { keeps($0.t) }.map { FaceSample(t: $0.t - offset, box: $0.box) }
            return samples.isEmpty ? nil : FaceTrack(id: f.id, samples: samples)
        }
        return ShotAnalysis(mediaId: newId, shots: shots, faces: faces, samplesPerSecond: s.samplesPerSecond)
    }

    public func retimed(_ b: BeatAnalysis) -> BeatAnalysis {
        let kept = b.beats.indices.filter { keeps(b.beats[$0]) }
        return BeatAnalysis(mediaId: newId, tempo: b.tempo, beats: kept.map { b.beats[$0] - offset }, downbeats: b.downbeats.filter(keeps).map { $0 - offset },
                            onsets: b.onsets.filter(keeps).map { $0 - offset }, energy: kept.map { $0 < b.energy.count ? b.energy[$0] : 0 })
    }

    public func retimed(_ e: SoundEvents) -> SoundEvents {
        SoundEvents(mediaId: newId, events: e.events.compactMap { ev in clipped(TimeRange(ev.start, ev.end)).map { SoundEvent(label: ev.label, start: $0.start, end: $0.end, confidence: ev.confidence) } })
    }

    public func retimed(_ tracks: [ObjectTrack]) -> [ObjectTrack] {
        tracks.compactMap { t in
            let samples = t.samples.filter { keeps($0.t) }.map { s -> TrackSample in
                var s = s
                s.t -= offset
                return s
            }
            return samples.isEmpty ? nil : ObjectTrack(id: t.id, mediaId: newId, label: t.label, samples: samples)
        }
    }
}
