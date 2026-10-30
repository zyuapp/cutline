import Foundation

/// Times can be given as seconds or as anchors that stay correct after other edits:
///
///     12.4, "1:02.5"            timeline time
///     "lake-tahoe.w12"          start of word 12 of that media's transcript, wherever it plays
///     "lake-tahoe.w12.end"      end of that word
///     "music.b16", "music.d4"   beat 16 / downbeat 4 of that media, wherever it plays
///     "lake-tahoe.s3[.end]"     start (end) of detected shot 3 of that media
///     "beat:12", "downbeat:3"   the 12th beat / 3rd downbeat of the music on the timeline (from 0)
///     "clip_ab12cd.start/.end"  edges of a clip
///     "marker:Intro", "m_x8k2p" a marker by label or id
///     "tc:00:01:10:12"          timeline timecode (frames at the canvas rate)
///     "<media>@01:00:12:10"     a source timecode of that media (source-time arguments)
///     "start", "end"            the ends of the timeline
///
/// Any anchor can carry an offset: "lake-tahoe.w12+0.2", "clip_ab12cd.end-1".
/// Analysis that anchors can point into, beyond transcripts.
public struct AnchorIndex: Sendable {
    public var beats: [String: BeatAnalysis]
    /// Shot spans per media, in source time.
    public var shots: [String: [TimeRange]]
    /// Media whose beats count as the timeline's music; speech is left out.
    public var music: Set<String>

    public init(beats: [String: BeatAnalysis] = [:], shots: [String: [TimeRange]] = [:], music: Set<String>? = nil) {
        self.beats = beats
        self.shots = shots
        self.music = music ?? Set(beats.keys)
    }
}

extension Project {
    public func resolveTime(_ raw: String, transcripts: [String: Transcript], index: AnchorIndex = AnchorIndex()) throws -> Seconds {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Double(s) { return n }
        if let t = Project.clockTime(s) { return t }
        let (base, offset) = Project.splitOffset(s)
        if base.hasPrefix("tc:"), let t = Project.timecode(String(base.dropFirst(3)), fps: canvas.fps) { return t + offset }
        if let (mid, src) = try sourceTimecode(base) { return try placed(mid, source: src, what: base) + offset }
        if let t = try resolveAnalysisAnchor(base, index: index, timeline: true) { return t + offset }
        return try resolveBase(base, transcripts: transcripts) + offset
    }

    /// Beats of every audible media clip, in timeline time, sorted.
    public func timelineBeats(_ index: AnchorIndex, downbeats: Bool = false) -> [Seconds] {
        var out: [Seconds] = []
        for track in tracks where !track.muted {
            for c in track.clips where c.kind == .media {
                guard let id = c.mediaId, index.music.contains(id), let b = index.beats[id] else { continue }
                for t in downbeats ? b.downbeats : b.beats where t >= c.sourceIn - 1e-6 && t < c.sourceOut - 1e-6 {
                    out.append(c.timelineTime(atSource: t))
                }
            }
        }
        return Array(Set(out.map { ($0 * 1000).rounded() / 1000 })).sorted()
    }

    /// The timeline time where a source time of a media file plays first.
    func placed(_ mediaId: String, source: Seconds, what: String) throws -> Seconds {
        let hits = tracks.flatMap(\.clips).filter { $0.kind == .media && $0.mediaId == mediaId && source >= $0.sourceIn - 1e-6 && source < $0.sourceOut }
        guard let c = hits.min(by: { $0.start < $1.start }) else { throw EditError("\(what) isn't on the timeline; it was cut or never placed") }
        return min(max(c.timelineTime(atSource: source), c.start), c.end)
    }

    /// Beat, downbeat and shot anchors; nil when `s` is not one of them.
    func resolveAnalysisAnchor(_ s: String, index: AnchorIndex, timeline: Bool) throws -> Seconds? {
        for (prefix, down) in [("beat:", false), ("downbeat:", true)] where s.hasPrefix(prefix) {
            guard timeline else { throw EditError("\(s) is a timeline anchor; source times take \"<media>.b12\"") }
            guard let n = Int(s.dropFirst(prefix.count)) else { throw EditError("Bad anchor \(s); use \(prefix)12") }
            let all = timelineBeats(index, downbeats: down)
            guard !all.isEmpty else { throw EditError("No analyzed music on the timeline; run media_analyze with beats on the music") }
            guard all.indices.contains(n) else { throw EditError("The timeline has \(down ? "downbeats" : "beats") 0…\(all.count - 1); got \(n)") }
            return all[n]
        }
        guard let r = s.range(of: #"\.([bds])(\d+)(\.end)?$"#, options: .regularExpression) else { return nil }
        let mediaId = String(s[..<r.lowerBound])
        guard mediaAsset(mediaId) != nil else { return nil }
        var tail = s[r].dropFirst()
        let kind = tail.removeFirst()
        let atEnd = tail.hasSuffix(".end")
        guard let n = Int(atEnd ? tail.dropLast(4) : tail) else { throw EditError("Bad anchor \(s)") }
        let source: Seconds
        switch kind {
        case "s":
            guard let shots = index.shots[mediaId], !shots.isEmpty else { throw EditError("\(mediaId) has no shot analysis; run media_analyze with shots") }
            guard shots.indices.contains(n) else { throw EditError("\(mediaId) has shots s0…s\(shots.count - 1); got s\(n)") }
            source = atEnd ? shots[n].end : shots[n].start
        default:
            guard !atEnd else { throw EditError("Beats are instants; drop .end from \(s)") }
            guard let b = index.beats[mediaId] else { throw EditError("\(mediaId) has no beat analysis; run media_analyze with beats") }
            let list = kind == "b" ? b.beats : b.downbeats
            guard list.indices.contains(n) else { throw EditError("\(mediaId) has \(kind == "b" ? "beats b" : "downbeats d")0…\(list.count - 1); got \(n)") }
            source = list[n]
        }
        return timeline ? try placed(mediaId, source: source, what: s) : source
    }

    /// "HH:MM:SS:FF" (or ";" before frames for drop frame) → seconds at `fps`.
    public static func timecode(_ s: String, fps: Double) -> Seconds? {
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == ";" }).compactMap { Int($0) }
        guard parts.count == 4, fps > 0 else { return nil }
        let nominal = Int(fps.rounded())
        var frames = ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * nominal + parts[3]
        if s.contains(";"), nominal == 30 || nominal == 60 {
            let drop = nominal / 15
            let minutes = parts[0] * 60 + parts[1]
            frames -= drop * (minutes - minutes / 10)
        }
        return Double(frames) / fps
    }

    /// Seconds → "HH:MM:SS:FF" at a nominal frame rate.
    public static func timecodeString(_ t: Seconds, fps: Double) -> String {
        let nominal = max(1, Int(fps.rounded()))
        let total = Int((t * fps).rounded())
        let f = total % nominal, s = total / nominal
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60, f)
    }

    /// "<media>@HH:MM:SS:FF": a source time from the media's own timecode.
    func sourceTimecode(_ s: String) throws -> (String, Seconds)? {
        guard let at = s.firstIndex(of: "@") else { return nil }
        let mid = String(s[..<at])
        guard let m = mediaAsset(mid) else { return nil }
        guard let t = Project.timecode(String(s[s.index(after: at)...]), fps: m.fps > 0 ? m.fps : canvas.fps) else { throw EditError("Timecodes look like \(mid)@01:00:12:10") }
        return (mid, t - (m.timecodeStart ?? 0))
    }

    /// "1:02.5" or "1:00:02.5" → seconds.
    static func clockTime(_ s: String) -> Seconds? {
        let parts = s.split(separator: ":")
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p) else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func splitOffset(_ s: String) -> (String, Seconds) {
        let chars = Array(s)
        var i = chars.count - 1
        while i > 0, chars[i].isNumber || chars[i] == "." { i -= 1 }
        guard i > 0, i < chars.count - 1, chars[i] == "+" || chars[i] == "-",
              let v = Double(String(chars[(i + 1)...]))
        else { return (s, 0) }
        return (String(chars[..<i]), chars[i] == "-" ? -v : v)
    }

    func resolveBase(_ s: String, transcripts: [String: Transcript]) throws -> Seconds {
        switch s {
        case "start": return 0
        case "end": return duration
        default: break
        }
        if s.hasPrefix("marker:") {
            let label = String(s.dropFirst(7))
            guard let m = markers.first(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else {
                throw EditError("No marker labeled \(label). Markers: \(markers.map(\.label).joined(separator: ", ").ifEmpty("none"))")
            }
            return m.time
        }
        if let m = markers.first(where: { $0.id == s }) { return m.time }
        for edge in [".start", ".end"] where s.hasSuffix(edge) {
            let id = String(s.dropLast(edge.count))
            if let c = clip(id) { return edge == ".start" ? c.start : c.end }
        }
        if let r = s.range(of: #"\.w(\d+)(\.end)?$"#, options: .regularExpression) {
            let mediaId = String(s[..<r.lowerBound])
            let tail = s[r].dropFirst(2)
            let atEnd = tail.hasSuffix(".end")
            guard let index = Int(atEnd ? tail.dropLast(4) : tail) else { throw EditError("Bad word anchor \(s)") }
            guard mediaAsset(mediaId) != nil else { throw EditError("No media \(mediaId) in anchor \(s)") }
            guard let tr = transcripts[mediaId] else { throw EditError("\(mediaId) has no transcript; run media_analyze first") }
            guard tr.words.indices.contains(index) else { throw EditError("\(mediaId) has words w0…w\(tr.words.count - 1); got w\(index)") }
            let w = tr.words[index]
            let src = atEnd ? w.end : w.start
            let mid = (w.start + w.end) / 2
            let hits = tracks.flatMap(\.clips).filter { $0.kind == .media && $0.mediaId == mediaId && mid >= $0.sourceIn && mid < $0.sourceOut }
            guard let c = hits.min(by: { $0.start < $1.start }) else {
                throw EditError("Word \(s) (“\(w.text)”) isn't on the timeline; it was cut or never placed")
            }
            return min(max(c.timelineTime(atSource: src), c.start), c.end)
        }
        throw EditError("Can't read time \(s). Use seconds, \"m:ss.f\", a word like \"<media>.w12\", a beat \"<media>.b8\" or \"beat:8\", a shot \"<media>.s2\", \"<clip>.start\", \"marker:<label>\", \"start\" or \"end\", optionally with +/- seconds.")
    }
}

extension Project {
    /// A position inside a media file: seconds, or "media.w12" / "media.w12.end" with an optional offset.
    public func resolveSourceTime(_ raw: String, transcripts: [String: Transcript], index: AnchorIndex = AnchorIndex()) throws -> Seconds {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Double(s) { return n }
        if let t = Project.clockTime(s) { return t }
        let (base, offset) = Project.splitOffset(s)
        if let (_, src) = try sourceTimecode(base) { return src + offset }
        if let t = try resolveAnalysisAnchor(base, index: index, timeline: false) { return t + offset }
        guard let r = base.range(of: #"\.w(\d+)(\.end)?$"#, options: .regularExpression) else {
            throw EditError("Source times are seconds in the media file, a word like \"<media>.w12\", a beat \"<media>.b8\" or a shot \"<media>.s2\"; got \(s)")
        }
        let mediaId = String(base[..<r.lowerBound])
        let tail = base[r].dropFirst(2)
        let atEnd = tail.hasSuffix(".end")
        guard let index = Int(atEnd ? tail.dropLast(4) : tail) else { throw EditError("Bad word anchor \(s)") }
        guard let tr = transcripts[mediaId] else { throw EditError("\(mediaId) has no transcript; run media_analyze first") }
        guard tr.words.indices.contains(index) else { throw EditError("\(mediaId) has words w0…w\(tr.words.count - 1); got w\(index)") }
        return (atEnd ? tr.words[index].end : tr.words[index].start) + offset
    }
}

extension Transcript {
    /// The anchor id of a word, e.g. "lake-tahoe.w12".
    public func wordId(_ index: Int) -> String { "\(mediaId).w\(index)" }
}
