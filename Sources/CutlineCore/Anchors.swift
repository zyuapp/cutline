import Foundation

/// Times can be given as seconds or as anchors that stay correct after other edits:
///
///     12.4, "1:02.5"            timeline time
///     "lake-tahoe.w12"          start of word 12 of that media's transcript, wherever it plays
///     "lake-tahoe.w12.end"      end of that word
///     "clip_ab12cd.start/.end"  edges of a clip
///     "marker:Intro", "m_x8k2p" a marker by label or id
///     "start", "end"            the ends of the timeline
///
/// Any anchor can carry an offset: "lake-tahoe.w12+0.2", "clip_ab12cd.end-1".
extension Project {
    public func resolveTime(_ raw: String, transcripts: [String: Transcript]) throws -> Seconds {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Double(s) { return n }
        if let t = Project.clockTime(s) { return t }
        let (base, offset) = Project.splitOffset(s)
        return try resolveBase(base, transcripts: transcripts) + offset
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
        throw EditError("Can't read time \(s). Use seconds, \"m:ss.f\", a word like \"<media>.w12\", \"<clip>.start\", \"marker:<label>\", \"start\" or \"end\", optionally with +/- seconds.")
    }
}

extension Project {
    /// A position inside a media file: seconds, or "media.w12" / "media.w12.end" with an optional offset.
    public func resolveSourceTime(_ raw: String, transcripts: [String: Transcript]) throws -> Seconds {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Double(s) { return n }
        if let t = Project.clockTime(s) { return t }
        let (base, offset) = Project.splitOffset(s)
        guard let r = base.range(of: #"\.w(\d+)(\.end)?$"#, options: .regularExpression) else {
            throw EditError("Source times are seconds in the media file or a word like \"<media>.w12\"; got \(s)")
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
