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
            let band = captionStyle.y
            for t in tracks where t.kind == .video && !t.hidden {
                for c in t.clips where c.kind == .text {
                    guard let spec = c.text, abs(spec.y - band) < spec.size + captionStyle.size else { continue }
                    if words.contains(where: { $0.end > c.start && $0.start < c.end }) {
                        out.append("\(c.id) “\(spec.text.prefix(20))” sits on the captions (y \(fmt2(spec.y)) vs captions \(fmt2(band))); move it with text.y")
                    }
                }
                for c in t.clips where c.kind == .generator {
                    guard let g = c.generatorText(at: c.duration / 2), abs(g.y - band) < g.size + captionStyle.size else { continue }
                    if words.contains(where: { $0.end > c.start && $0.start < c.end }) {
                        out.append("\(c.id) “\(g.text.prefix(20))” sits on the captions (y \(fmt2(g.y)) vs captions \(fmt2(band))); move it with fx.gen.y or captions_set y")
                    }
                }
            }
        }
        out += unseenClips()
        out += uncoveredFrame()
        out += doubledSound()
        out += droppedWords(transcripts: transcripts, dialogue: dialogue)
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
    /// Picture clips on visible tracks that never show: fully transparent, or at most 20% inside the frame, at every
    /// sampled time (start, quarters, end and each transform or text key). Rotation and 3D layers aren't measured.
    func unseenClips() -> [String] {
        let w = Double(max(1, canvas.width)), h = Double(max(1, canvas.height))
        let aspect = w / h
        var out: [String] = []
        for t in tracks where t.kind == .video && !t.hidden {
            for c in t.clips where c.kind != .adjustment && !c.transform.threeD && c.duration > 0 {
                var size = (1.0, 1.0)
                if c.kind == .media {
                    guard let m = c.mediaId.flatMap(mediaAsset), m.hasVideo else { continue }
                    if m.width > 0, m.height > 0, c.transform.fit != .stretch {
                        let ma = Double(m.width) / Double(m.height)
                        size = (ma > aspect) == (c.transform.fit == .fit) ? (1, aspect / ma) : (ma / aspect, 1)
                    }
                }
                var times = [0, 0.25, 0.5, 0.75].map { $0 * c.duration } + [max(0, c.duration - 1e-3)]
                for (path, curve) in c.anim where path.hasPrefix("transform.") || path == "text.x" || path == "text.y" {
                    times += curve.keys.map { min(max($0.t, 0), c.duration) }
                }
                var best = 0.0, opacity = 0.0
                var center = (0.5, 0.5)
                for lt in times {
                    let tr = c.resolvedTransform(at: lt)
                    opacity = max(opacity, tr.opacity)
                    var box = (x: 0.5, y: 0.5, w: size.0, h: size.1)
                    if c.kind == .text, let s = c.resolvedText(at: lt) {
                        let lines = s.text.components(separatedBy: "\n")
                        let font = s.size * min(w, h)
                        let longest = Double(lines.map(\.count).max() ?? 0)
                        box = (s.x, s.y, min(longest * font * 0.55 / w, s.maxWidth), Double(lines.count) * font * 1.2 / h)
                    } else if c.kind == .media {
                        let cr = tr.crop
                        box.x += (cr.left - cr.right) / 2 * box.w
                        box.y += (cr.top - cr.bottom) / 2 * box.h
                        box.w *= max(0, 1 - cr.left - cr.right)
                        box.h *= max(0, 1 - cr.top - cr.bottom)
                    }
                    let k = max(tr.scale, 0)
                    let cx = c.kind == .text ? box.x + tr.x : 0.5 + (box.x - 0.5) * k + tr.x
                    let cy = c.kind == .text ? box.y + tr.y : 0.5 + (box.y - 0.5) * k + tr.y
                    let bw = box.w * k, bh = box.h * k
                    let ix = max(0, min(1, cx + bw / 2) - max(0, cx - bw / 2)), iy = max(0, min(1, cy + bh / 2) - max(0, cy - bh / 2))
                    let shown = bw * bh > 0 ? ix * iy / (bw * bh) : 1
                    if shown >= best { best = shown; center = (cx, cy) }
                }
                if opacity <= 0.001 {
                    out.append("\(c.id) on \(t.id) is fully transparent for its whole length; raise transform.opacity")
                } else if best <= 0.2 {
                    out.append("\(c.id) on \(t.id) is \(best == 0 ? "entirely" : "mostly") outside the frame for its whole length (center at \(fmt2(center.0)), \(fmt2(center.1)) of the frame from the top left); transform.x/y offset it from the frame center, transform.pos_x/pos_y place it from the top left")
                }
            }
        }
        return out
    }

    /// Whether a clip plays the source channels its media was transcribed from; true when either is unknown.
    func playsTranscribedChannels(_ c: Clip) -> Bool {
        guard let r = c.channels, !r.isAsRecorded, let heard = c.mediaId.flatMap({ mediaAsset($0) })?.analysisChannel, !heard.isAsRecorded else { return true }
        return !Set(r.sourceChannels).isDisjoint(with: heard.sourceChannels)
    }

    /// Each track's audio role for stems from transcripts alone; see `inferRoles` for the full evidence.
    public func roles(transcripts: [String: Transcript]) -> [String: String] {
        inferRoles(SoundEvidence(transcripts: transcripts)).stemRoles
    }
}
