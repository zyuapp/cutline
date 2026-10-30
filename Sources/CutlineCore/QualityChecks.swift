import Foundation

extension Project {
    /// Problems a viewer would notice, found from the edit alone (no rendering): gaps, flash frames,
    /// words cut in half, titles under captions, sound ending abruptly.
    public func qualityIssues(transcripts: [String: Transcript]) -> [String] {
        var out: [String] = []
        if let main = tracks.first(where: { $0.kind == .video && !$0.clips.isEmpty }) {
            var cursor = 0.0
            for c in main.clips {
                if c.start - cursor > 0.02 { out.append("gap on \(main.id) at \(fmt2(cursor))–\(fmt2(c.start)) shows background") }
                cursor = c.end
            }
        }
        for t in tracks {
            for c in t.clips where c.kind == .media && c.duration < 0.25 {
                out.append("\(c.id) on \(t.id) is only \(fmt2(c.duration))s, likely a flash frame")
            }
        }
        let pictureEnd = tracks.filter { $0.kind == .video }.map(\.end).max() ?? 0
        for t in tracks where t.kind == .audio {
            if let last = t.clips.last, pictureEnd > 0, last.end > pictureEnd + 0.5 {
                out.append("\(last.id) on \(t.id) runs \(fmt2(last.end - pictureEnd))s past the picture; trim it or fade it out")
            }
        }
        // Edges that slice through a spoken word, on the dialogue tracks.
        let dialogue = Set(captions.trackIds.isEmpty ? captionTrackIds : captions.trackIds)
        for t in tracks where !t.muted && dialogue.contains(t.id) {
            for c in t.clips where c.kind == .media && c.volume > 0 && playsTranscribedChannels(c) {
                guard let mid = c.mediaId, let tr = transcripts[mid] else { continue }
                let heard = c.audioSourceRange
                for (edge, s) in [("starts", heard.start), ("ends", heard.end)] {
                    if let w = tr.words.first(where: { $0.start < s - 0.04 && $0.end > s + 0.04 }) {
                        out.append("\(c.id) \(edge) in the middle of “\(w.text)” (\(mid) \(fmt2(w.start))–\(fmt2(w.end))); trim to a word edge")
                    }
                }
            }
        }
        // Titles sitting in the caption band while captions show.
        if captions.enabled {
            let words = timelineWords(transcripts: transcripts)
            let band = captions.style.y
            for t in tracks where t.kind == .video && !t.hidden {
                for c in t.clips where c.kind == .text {
                    guard let spec = c.text, abs(spec.y - band) < spec.size + captions.style.size else { continue }
                    if words.contains(where: { $0.end > c.start && $0.start < c.end }) {
                        out.append("\(c.id) “\(spec.text.prefix(20))” sits on the captions (y \(fmt2(spec.y)) vs captions \(fmt2(band))); move it with text.y")
                    }
                }
                for c in t.clips where c.kind == .generator {
                    guard let g = c.generatorText(at: c.duration / 2), abs(g.y - band) < g.size + captions.style.size else { continue }
                    if words.contains(where: { $0.end > c.start && $0.start < c.end }) {
                        out.append("\(c.id) “\(g.text.prefix(20))” sits on the captions (y \(fmt2(g.y)) vs captions \(fmt2(band))); move it with fx.gen.y or captions_set y")
                    }
                }
            }
        }
        // Music that stops dead at the end of the edit.
        let speech = Set(timelineWords(transcripts: transcripts).map(\.clipId))
        for t in tracks where t.kind == .audio && !t.muted {
            if let last = t.clips.last, last.kind == .media, !speech.contains(last.id), abs(last.end - duration) < 0.05, last.audioFadeOut < 0.3, last.anim["audio.volume"] == nil {
                out.append("\(last.id) on \(t.id) stops abruptly at the end; add audio.fade_out (about 1–3 s)")
            }
        }
        return out
    }
}

extension Project {
    /// Whether a clip plays the source channels its media was transcribed from; true when either is unknown.
    func playsTranscribedChannels(_ c: Clip) -> Bool {
        guard let r = c.channels, !r.isAsRecorded, let heard = c.mediaId.flatMap({ mediaAsset($0) })?.analysisChannel, !heard.isAsRecorded else { return true }
        return !Set(r.sourceChannels).isDisjoint(with: heard.sourceChannels)
    }

    /// Each track's audio role: its own, else dialogue when it carries transcribed speech, else what its name
    /// says ("SFX", "Score", "VO"), music for other audio tracks and effects for the rest.
    public func roles(transcripts: [String: Transcript]) -> [String: String] {
        let speech = Set(timelineWords(transcripts: transcripts).compactMap { w in locateClip(w.clipId).map { tracks[$0.track].id } })
        var out: [String: String] = [:]
        for t in tracks where t.clips.contains(where: { c in c.kind == .sequence || (c.kind == .media && (c.mediaId.flatMap { mediaAsset($0) }?.hasAudio ?? false)) }) {
            out[t.id] = t.role ?? (speech.contains(t.id) ? "dialogue" : Project.roleFromName(t.name) ?? (t.kind == .audio ? "music" : "effects"))
        }
        return out
    }
}
