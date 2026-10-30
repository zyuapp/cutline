import Foundation

public struct CaptionWord: Equatable, Hashable, Sendable {
    public var text: String
    public var start: Seconds
    public var end: Seconds
    /// The transcript word this came from, as "<mediaId>.w<index>".
    public var anchor: String? = nil
    /// A cue must start at this word.
    public var breakBefore = false
    /// The last transcript word this covers, when rewritten text or a multi-word replacement spans several.
    public var lastAnchor: String? = nil
    /// The next word stays in this word's cue (caption_edit merge).
    public var joinNext = false

    /// The last transcript word this covers.
    public var endAnchor: String? { lastAnchor ?? anchor }
}

/// A block of caption text on the timeline.
public struct CaptionSegment: Equatable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var start: Seconds
    public var end: Seconds
    /// Each line is a list of words.
    public var lines: [[CaptionWord]]

    public var words: [CaptionWord] { lines.flatMap { $0 } }
    public var text: String { lines.map { Project.joinWords($0.map(\.text)) }.joined(separator: "\n") }
}

/// A transcript word placed on the timeline.
public struct TimelineWord: Equatable, Sendable {
    public var text: String
    public var start: Seconds
    public var end: Seconds
    public var clipId: String
    public var mediaId: String
    public var sourceStart: Seconds
    /// Index in the media's transcript, so "<mediaId>.w<index>" is this word's anchor.
    public var wordIndex: Int
    /// Who says it, when the media has speaker analysis.
    public var speaker: String? = nil

    /// A caption cue starts at this word: it comes from another source file than `previous` across a clip change,
    /// or another speaker says it.
    func startsCue(after previous: TimelineWord) -> Bool {
        if clipId != previous.clipId, mediaId != previous.mediaId { return true }
        if let a = speaker, let b = previous.speaker, a != b { return true }
        return false
    }
}

extension Project {
    /// Words heard on the timeline, mapped from source transcripts through every clip's sound range (lead and lag
    /// included). Where two clips' sound overlaps on one track (a crossfade), each clip is read up to the middle of
    /// the overlap. A word heard twice at once, from two clips (the same source word, or the same word either side
    /// of a crossfade), is kept once. Every caption output reads these words.
    public func timelineWords(transcripts: [String: Transcript], trackIds: [String] = []) -> [TimelineWord] {
        var out: [TimelineWord] = []
        for track in flattenedForSound where !track.muted && (trackIds.isEmpty || trackIds.contains(track.id)) {
            let sounding = track.clips.filter { $0.kind == .media && $0.volume > 0.001 }.sorted { $0.audioRange.start < $1.audioRange.start }
            for (k, clip) in sounding.enumerated() {
                guard let mid = clip.mediaId, let tr = transcripts[mid] else { continue }
                let heard = clip.audioSourceRange
                var span = clip.audioRange
                if k > 0 {
                    let before = sounding[k - 1].audioRange
                    if before.end > span.start, before.end < span.end { span.start = (span.start + before.end) / 2 }
                }
                if k + 1 < sounding.count {
                    let after = sounding[k + 1].audioRange
                    if after.start < span.end, after.start > span.start { span.end = (after.start + span.end) / 2 }
                }
                for (wi, w) in tr.words.enumerated() {
                    let mid = (w.start + w.end) / 2
                    guard mid >= heard.start, mid < heard.end else { continue }
                    if span.start != clip.audioRange.start || span.end != clip.audioRange.end {
                        let at = clip.timelineTime(atSource: mid)
                        guard at >= span.start, at < span.end else { continue }
                    }
                    let s = max(span.start, clip.timelineTime(atSource: w.start))
                    let e = min(span.end, clip.timelineTime(atSource: w.end))
                    let speaker = tr.speakers.flatMap { wi < $0.count ? $0[wi] : nil }
                    out.append(TimelineWord(text: w.text, start: s, end: max(e, s + 0.05), clipId: clip.id, mediaId: tr.mediaId, sourceStart: w.start, wordIndex: wi, speaker: speaker))
                }
            }
        }
        out.sort { $0.start < $1.start }
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() }
        var deduped: [TimelineWord] = []
        for w in out {
            if let last = deduped.last, last.text == w.text, abs(last.start - w.start) < 0.05 { continue }
            let heardTwice = deduped.suffix(6).contains { k in
                k.clipId != w.clipId && min(k.end, w.end) - max(k.start, w.start) > 0.5 * min(k.end - k.start, w.end - w.start)
                    && ((k.mediaId == w.mediaId && k.wordIndex == w.wordIndex) || norm(k.text) == norm(w.text))
            }
            if heardTwice { continue }
            deduped.append(w)
        }
        return deduped
    }

    /// Tracks captioned by default: those with the dialogue role, or else every track whose role or name
    /// isn't music, effects or ambience.
    public var captionTrackIds: [String] {
        let sound = flattenedForSound
        let dialogue = sound.filter { $0.role?.lowercased() == "dialogue" }.map(\.id)
        if !dialogue.isEmpty { return dialogue }
        let background = ["music", "effects", "sfx", "fx", "ambience", "ambient", "amb", "atmos", "atmosphere", "room tone", "roomtone", "foley", "score", "bed"]
        return sound.filter { t in
            let tags = [t.role, t.name].compactMap { $0?.lowercased() }
            return !tags.contains { tag in background.contains { tag == $0 || tag.hasPrefix($0 + " ") || tag.hasSuffix(" " + $0) } }
        }.map(\.id)
    }

    /// Timeline words the captions read: the caption tracks, or the dialogue tracks when none are set.
    public func captionTimelineWords(transcripts: [String: Transcript]) -> [TimelineWord] {
        let ids = captions.trackIds.isEmpty ? captionTrackIds : captions.trackIds
        guard !ids.isEmpty else { return [] }
        return timelineWords(transcripts: transcripts, trackIds: ids)
    }

    /// Timeline spans where two clips' speech overlaps, which a single caption track can't show cleanly.
    public func overlappingSpeech(transcripts: [String: Transcript]) -> [TimeRange] {
        let words = captionTimelineWords(transcripts: transcripts)
        var spans: [TimeRange] = []
        for (i, a) in words.enumerated() {
            for b in words[(i + 1)...] {
                if b.start >= a.end - 0.05 { break }
                if b.clipId != a.clipId { spans.append(TimeRange(b.start, min(a.end, b.end))) }
            }
        }
        return TimeRange.merged(spans, tolerance: 0.5)
    }

    /// Words the captions show, in timeline order, with replacements, hidden words and cue edits applied. Spoken casing.
    /// A new cue starts where the source file changes at a clip change and where the speaker changes, unless a merge
    /// edit joins the two.
    public func captionWords(transcripts: [String: Transcript]) -> [CaptionWord] {
        let hidden = Set(captions.hiddenWords.map { $0.lowercased() })
        let replacements = Dictionary(captions.replacements.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let joins = Set(captions.edits.filter { $0.mergeNext == true }.map { "\($0.mediaId).w\($0.toWord)" })
        var words: [CaptionWord] = []
        var run: (edit: CaptionEdit, words: [TimelineWord], breaks: Bool)?
        // Set at a source or speaker change; the next shown word starts a cue.
        var pendingBreak = false
        func takeBreak() -> Bool {
            defer { pendingBreak = false }
            return pendingBreak && words.last?.joinNext != true
        }
        func flush() {
            guard let r = run else { return }
            run = nil
            if r.edit.hidden == true {
                pendingBreak = pendingBreak || r.breaks
                return
            }
            let start = r.words[0].start + (r.edit.startOffset ?? 0)
            let end = max(start + 0.05, r.words.last!.end + (r.edit.endOffset ?? 0))
            let anchor = "\(r.edit.mediaId).w\(r.words[0].wordIndex)"
            let last = "\(r.edit.mediaId).w\(r.words.last!.wordIndex)"
            var made: [CaptionWord]
            if let text = r.edit.text {
                let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
                let total = Double(max(1, tokens.reduce(0) { $0 + $1.count + 1 }))
                var t = start
                made = tokens.map { tok in
                    let d = (end - start) * Double(tok.count + 1) / total
                    defer { t += d }
                    return CaptionWord(text: tok, start: t, end: t + d, anchor: anchor, lastAnchor: last)
                }
            } else {
                made = r.words.map { CaptionWord(text: $0.text, start: $0.start, end: $0.end, anchor: "\($0.mediaId).w\($0.wordIndex)") }
                if !made.isEmpty {
                    made[0].start = start
                    made[made.count - 1].end = end
                }
            }
            if (r.edit.breakBefore == true || r.breaks), !made.isEmpty { made[0].breakBefore = true }
            for i in made.indices { made[i].joinNext = made[i].endAnchor.map(joins.contains) ?? false }
            words += made
        }
        var previous: TimelineWord?
        for w in captionTimelineWords(transcripts: transcripts) {
            if let p = previous, w.startsCue(after: p) { pendingBreak = true }
            previous = w
            if let edit = captions.edits.last(where: { !$0.isMergeOnly && $0.covers(w.mediaId, w.wordIndex) }) {
                if let r = run, r.edit == edit, r.words.last?.clipId == w.clipId, !pendingBreak {
                    run!.words.append(w)
                } else {
                    flush()
                    run = (edit, [w], takeBreak())
                }
                continue
            }
            flush()
            let norm = w.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
            if hidden.contains(norm) { continue }
            var text = w.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rep = replacements[norm] {
                let trailing = String(text.reversed().prefix { $0.isPunctuation }.reversed())
                text = rep + trailing
            }
            guard !text.isEmpty else { continue }
            let anchor = "\(w.mediaId).w\(w.wordIndex)"
            words.append(CaptionWord(text: text, start: w.start, end: w.end, anchor: anchor, breakBefore: takeBreak(), joinNext: joins.contains(anchor)))
        }
        flush()
        mergeMultiWordReplacements(&words, replacements: replacements)
        return words
    }

    /// Burned-in captions: the shared cues (`captionCues`, in `captions.language`) laid out with the caption style's lines. A cue with more
    /// words than the style's `maxWordsPerLine × maxLines` shows as consecutive pages within the cue's time; subtitles
    /// and closed captions keep it as one cue.
    public func captionSegments(transcripts: [String: Transcript]) -> [CaptionSegment] {
        let style = captions.style
        let perLine = min(max(1, style.maxWordsPerLine), 10_000)
        let perPage = perLine * min(max(1, style.maxLines), 100)
        let cues = captionCues(transcripts: transcripts, language: captions.language)
        // Chinese, Japanese and Korean lines keep to the language's line length in characters, not a word count.
        let translated = captions.language.map { captions.translations[Self.languageTag($0)] != nil } ?? false
        let wide = translated ? SubtitleRules.forLanguage(captions.language!) : SubtitleRules.forText(cues.prefix(20).map(\.text).joined())
        let columns = wide.flatMap { $0.wide ? $0.columns : nil }
        var segments: [CaptionSegment] = []
        for (ci, cue) in cues.enumerated() {
            var words = cue.words
            if style.uppercase { for i in words.indices { words[i].text = words[i].text.uppercased() } }
            let columns = SubtitleRules.forText(cue.text) == nil ? nil : columns
            let pages = columns.map { Self.splitToFit(words, width: $0, lines: max(1, style.maxLines)) } ?? Self.evenChunks(words, max: perPage)
            var end = cue.end
            // Back-to-back cues stay up until the next one rather than blinking off for the subtitle gap.
            if ci + 1 < cues.count, cues[ci + 1].start - cue.end < 0.15 { end = cues[ci + 1].start }
            for (pi, page) in pages.enumerated() {
                let s = pi == 0 ? cue.start : max(page[0].start, segments.last?.start ?? cue.start)
                let e = pi + 1 < pages.count ? max(pages[pi + 1][0].start, s) : end
                let lines = columns.map { width in Self.lineGroups(page.map(\.text), width: width).map { Array(page[$0]) } } ?? Self.evenChunks(page, max: perLine)
                segments.append(CaptionSegment(id: segments.count, start: s, end: max(e, s), lines: lines))
            }
        }
        return segments
    }

    /// `items` cut into the fewest consecutive chunks of at most `limit`, as even in size as possible.
    static func evenChunks<T>(_ items: [T], max limit: Int) -> [[T]] {
        guard !items.isEmpty else { return [] }
        let n = Int((Double(items.count) / Double(Swift.max(1, limit))).rounded(.up))
        let size = Int((Double(items.count) / Double(n)).rounded(.up))
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    private func mergeMultiWordReplacements(_ words: inout [CaptionWord], replacements: [String: String]) {
        let multi = replacements.filter { $0.key.contains(" ") }
        guard !multi.isEmpty else { return }
        for (key, value) in multi {
            let parts = key.split(separator: " ").map(String.init)
            var i = 0
            while i + parts.count <= words.count {
                let window = words[i..<(i + parts.count)].map {
                    $0.text.trimmingCharacters(in: .punctuationCharacters).lowercased()
                }
                if window == parts {
                    let lastWord = words[i + parts.count - 1]
                    let trailing = String(lastWord.text.reversed().prefix { $0.isPunctuation }.reversed())
                    let merged = CaptionWord(text: value + trailing, start: words[i].start, end: lastWord.end, anchor: words[i].anchor, breakBefore: words[i].breakBefore, lastAnchor: lastWord.endAnchor, joinNext: lastWord.joinNext)
                    words.replaceSubrange(i..<(i + parts.count), with: [merged])
                }
                i += 1
            }
        }
    }
}

extension Clip {
    /// Transform at a time relative to the clip start, with animation and fades applied.
    public func resolvedTransform(at local: Seconds) -> Transform {
        var t = transform
        if !anim.isEmpty {
            t.scale = number("transform.scale", at: local, default: t.scale)
            t.x = number("transform.x", at: local, default: t.x)
            t.y = number("transform.y", at: local, default: t.y)
            t.rotation = number("transform.rotation", at: local, default: t.rotation)
            t.opacity = number("transform.opacity", at: local, default: t.opacity)
            t.crop.left = number("transform.crop.left", at: local, default: t.crop.left)
            t.crop.top = number("transform.crop.top", at: local, default: t.crop.top)
            t.crop.right = number("transform.crop.right", at: local, default: t.crop.right)
            t.crop.bottom = number("transform.crop.bottom", at: local, default: t.crop.bottom)
            t.anchorX = number("transform.anchor_x", at: local, default: t.anchorX)
            t.anchorY = number("transform.anchor_y", at: local, default: t.anchorY)
            t.rotateX = number("transform.rotate_x", at: local, default: t.rotateX)
            t.rotateY = number("transform.rotate_y", at: local, default: t.rotateY)
            t.perspective = number("transform.perspective", at: local, default: t.perspective)
            t.z = number("transform.z", at: local, default: t.z)
        }
        var fade = 1.0
        if fadeIn > 0 { fade = min(fade, local / fadeIn) }
        if fadeOut > 0 { fade = min(fade, (duration - local) / fadeOut) }
        t.opacity *= min(max(fade, 0), 1)
        return t
    }
}
