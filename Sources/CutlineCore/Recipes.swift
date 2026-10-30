import Foundation

/// Multi-step edits built from the primitives, each returning a sentence about what it did.
extension Project {
    func keys(_ pairs: [(Seconds, Double, Easing)]) -> Curve {
        Curve(keys: pairs.map { CurveKey(t: $0.0, v: .number($0.1), ease: $0.2) })
    }

    // MARK: Time

    /// Ramps a clip's speed down to `speed` around `at` (timeline), holds, then ramps back.
    public mutating func speedRamp(_ id: String, at: Seconds?, speed target: Double, ramp: Seconds, hold: Seconds) throws -> String {
        guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
        var c = tracks[loc.track].clips[loc.clip]
        guard c.kind == .media else { throw EditError("Speed ramps need a media clip") }
        let base = c.speed
        let mid = (at ?? c.start + c.duration / 2) - c.start
        let a = max(0, mid - hold / 2 - ramp), b = max(0, mid - hold / 2), d = min(c.duration, mid + hold / 2), e = min(c.duration, mid + hold / 2 + ramp)
        c.anim["time.speed"] = keys([(a, base, .linear), (b, target, .easeInOut), (d, target, .linear), (e, base, .easeInOut)])
        tracks[loc.track].clips[loc.clip] = c
        let m = c.mediaId.flatMap { mediaAsset($0) }
        if let m, !m.isImage, c.sourceOut > m.duration + 1e-3 {
            throw EditError("The ramp needs source up to \(fmt2(c.sourceOut))s but \(m.id) is \(fmt2(m.duration))s; lower the speed change or shorten \(id)")
        }
        return "\(id) ramps \(fmt2(base))× → \(fmt2(target))× at \(fmt2(c.start + b))–\(fmt2(c.start + d)), back by \(fmt2(c.start + e)). It now uses source \(fmt2(c.sourceIn))–\(fmt2(c.sourceOut))."
    }

    /// A warning when a clip's heard, transcribed speech plays slowed or sped past ±10%, or nil.
    public func retimedSpeechWarning(_ id: String, transcripts: [String: Transcript]) -> String? {
        guard let c = clip(id), hasSound(c) else { return nil }
        let words = timelineWords(transcripts: transcripts).filter { $0.clipId == id }
        let off = words.compactMap { w -> (TimelineWord, Double)? in
            let v = c.speed(atLocal: (w.start + w.end) / 2 - c.start)
            return v < 0.9 || v > 1.1 ? (w, v) : nil
        }
        guard let first = off.first, let last = off.last else { return nil }
        let slowest = off.map(\.1).min()!, fastest = off.map(\.1).max()!
        let rate = slowest < 0.9 ? "slowed to \(fmt2(slowest))×" : "sped up to \(fmt2(fastest))×"
        let quote = off.prefix(6).map(\.0.text).joined(separator: " ") + (off.count > 6 ? "…" : "")
        return "Warning: \(off.count) spoken word(s) on \(id) play \(rate) at \(fmt2(first.0.start))–\(fmt2(last.0.end))s (\"\(quote)\"), which sounds unnatural. Mute this clip's sound (param_set audio.volume 0) and keep the dialogue from a linked or separate clip, or ramp where nobody speaks."
    }

    /// Holds the frame at `time` for `duration`, pushing everything after it later on every track.
    /// Clips on `pauseTracks` (such as dialogue) split so they pause with the picture; others play on.
    public mutating func freezeFrame(at time: Seconds, trackId: String?, duration: Seconds, zoom: Double, pauseTracks: Set<String> = []) throws -> String {
        let t = canvas.snap(time)
        let candidates = tracks.indices.filter { trackId == nil ? tracks[$0].kind == .video : tracks[$0].id == trackId }
        guard let ti = candidates.reversed().first(where: { i in tracks[i].clips.contains { $0.kind == .media && t >= $0.start - eps && t < $0.end - eps } }),
              let c = tracks[ti].clips.first(where: { $0.kind == .media && t >= $0.start - eps && t < $0.end - eps })
        else { throw EditError("No video clip at \(fmt2(t))s") }
        var frozen = c
        frozen.id = Project.newClipId()
        frozen.start = t
        frozen.duration = canvas.snap(duration)
        frozen.sourceIn = c.sourceTime(atTimeline: t)
        frozen.reverse = false
        frozen.speed = 1
        frozen.anim = [:]
        frozen.anim["time.speed"] = keys([(0, 0, .hold)])
        frozen.volume = 0
        frozen.fadeIn = 0
        frozen.fadeOut = 0
        frozen.audioFadeIn = 0
        frozen.audioFadeOut = 0
        frozen.audioLead = 0
        frozen.audioLag = 0
        frozen.transform = c.resolvedTransform(at: t - c.start)
        if zoom != 1 { frozen.anim["transform.scale"] = keys([(0, frozen.transform.scale, .linear), (frozen.duration, frozen.transform.scale * zoom, .easeOut)]) }
        for i in tracks.indices where pauseTracks.contains(tracks[i].id) && i != ti {
            if let s = tracks[i].clips.first(where: { t > $0.start + eps && t < $0.end - eps }) { _ = try? splitClip(s.id, at: t) }
        }
        rippleInsert(at: t, duration: frozen.duration, splitTrack: ti)
        try addClip(frozen, trackId: tracks[ti].id, mode: .place)
        return "Froze \(c.id) at \(fmt2(t))s for \(fmt2(frozen.duration))s as \(frozen.id); everything after moved \(fmt2(frozen.duration))s later."
    }

    // MARK: Framing

    /// Clips after a cut within the same media on the same track: classic jump cuts.
    public func jumpCuts(trackId: String) -> [String] {
        guard let i = trackIndex(trackId) else { return [] }
        let clips = tracks[i].clips
        var out: [String] = []
        var run = 0
        for (a, b) in zip(clips, clips.dropFirst()) {
            if a.kind == .media, b.kind == .media, a.mediaId == b.mediaId, abs(b.start - a.end) < canvas.frameDuration / 2 {
                run += 1
                if run % 2 == 1 { out.append(b.id) }
            } else {
                run = 0
            }
        }
        return out
    }

    /// Scales clips in to hide jump cuts, centered on the subject when `center` knows it (source fractions).
    public mutating func punchIn(_ ids: [String], amount: Double, settle: Bool, center: (Clip) -> (x: Double, y: Double)?) throws -> String {
        var done: [String] = []
        for id in ids {
            guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
            var c = tracks[loc.track].clips[loc.clip]
            let s = c.transform.scale * amount
            var x = c.transform.x, y = c.transform.y
            if let p = center(c) {
                let room = (s - 1) / 2
                x = min(room, max(-room, (0.5 - p.x) * (s - 1)))
                y = min(room, max(-room, (0.5 - p.y) * (s - 1)))
            }
            c.anim["transform.scale"] = nil
            c.anim["transform.x"] = nil
            c.anim["transform.y"] = nil
            if settle {
                c.anim["transform.scale"] = keys([(0, s * 1.03, .linear), (min(0.6, c.duration), s, .easeOut)])
            }
            c.transform.scale = s
            c.transform.x = x
            c.transform.y = y
            tracks[loc.track].clips[loc.clip] = c
            done.append(id)
        }
        return "Punched in \(done.count) clip(s) to \(fmt2(amount))×: " + done.joined(separator: ", ")
    }

    /// Shrinks a clip into a rounded inset in a corner, with a shadow and optional border.
    public mutating func pictureInPicture(_ id: String, corner: String, size: Double, margin: Double, roundness: Double, border: RGBA?) throws -> String {
        guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
        var c = tracks[loc.track].clips[loc.clip]
        let aspect = Double(canvas.width) / Double(canvas.height)
        let mx = margin / aspect
        let dx = 0.5 - size / 2 - mx, dy = 0.5 - size / 2 - margin
        let (sx, sy): (Double, Double) = switch corner {
        case "top_left": (-1, -1)
        case "top_right": (1, -1)
        case "bottom_left": (-1, 1)
        case "center": (0, 0)
        default: (1, 1)
        }
        c.transform.fit = .fill
        c.transform.scale = size
        c.transform.x = sx * dx
        c.transform.y = sy * dy
        c.effects.removeAll { ["pip_mask", "pip_border", "pip_shadow"].contains($0.id) }
        c.effects.append(Effect(id: "pip_mask", type: "mask.rect", params: ["width": .number(1), "height": .number(1), "roundness": .number(roundness)]))
        if let border { c.effects.append(Effect(id: "pip_border", type: "stylize.border", params: ["color": .string(border.hex), "width": .number(0.006)])) }
        c.effects.append(Effect(id: "pip_shadow", type: "stylize.drop_shadow", params: ["opacity": .number(0.45), "radius": .number(0.025), "y": .number(0.012)]))
        tracks[loc.track].clips[loc.clip] = c
        return "\(id) is now a \(Int(size * 100))% inset at \(corner.replacingOccurrences(of: "_", with: " ")) with rounded corners and a shadow (effects pip_mask, pip_shadow\(border == nil ? "" : ", pip_border"))."
    }

    /// Arranges clips side by side, stacked, or in a grid; each fills its cell.
    public mutating func splitScreen(_ ids: [String], layout: String, gap: Double) throws -> String {
        guard ids.count >= 2 else { throw EditError("A split screen needs at least two clips") }
        let n = ids.count
        let cells: [(x: Double, y: Double, w: Double, h: Double)]
        switch layout {
        case "tb": cells = (0..<n).map { i -> (x: Double, y: Double, w: Double, h: Double) in (0.5, (Double(i) + 0.5) / Double(n), 1, 1 / Double(n)) }
        case "grid":
            let cols = Int(ceil(sqrt(Double(n)))), rows = Int(ceil(Double(n) / Double(cols)))
            let cw = 1 / Double(cols), rh = 1 / Double(rows)
            cells = (0..<n).map { i -> (x: Double, y: Double, w: Double, h: Double) in
                let col = Double(i % cols), row = Double(i / cols)
                return ((col + 0.5) * cw, (row + 0.5) * rh, cw, rh)
            }
        default: cells = (0..<n).map { i -> (x: Double, y: Double, w: Double, h: Double) in ((Double(i) + 0.5) / Double(n), 0.5, 1 / Double(n), 1) }
        }
        for (id, cell) in zip(ids, cells) {
            guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
            var c = tracks[loc.track].clips[loc.clip]
            // Fill the frame at the cell's larger scale, then mask to the cell size around the center.
            let s = max(cell.w, cell.h)
            c.transform.fit = .fill
            c.transform.scale = s
            c.transform.x = cell.x - 0.5
            c.transform.y = cell.y - 0.5
            c.anim["transform.scale"] = nil
            c.anim["transform.x"] = nil
            c.anim["transform.y"] = nil
            c.effects.removeAll { $0.id == "split_mask" }
            c.effects.append(Effect(id: "split_mask", type: "mask.rect", params: ["width": .number(max(0.01, cell.w / s - gap / s)), "height": .number(max(0.01, cell.h / s - gap / s))]))
            tracks[loc.track].clips[loc.clip] = c
        }
        return "Split screen (\(layout)) with \(n) clips: " + ids.joined(separator: ", ")
    }

    // MARK: Rhythm

    /// Lays footage on a track so each cut lands on a beat. `pool` is source spans to draw from, unscored.
    public mutating func beatCut(pool: [(mediaId: String, range: TimeRange)], beats: [Seconds], every: Int, trackId: String, from: Seconds? = nil, align: BeatAlign = .fill, music: [String] = []) throws -> String {
        try beatCut(footage: pool.map { BeatFootage(mediaId: $0.mediaId, range: $0.range) }, beats: beats, every: every, trackId: trackId, from: from, align: align, music: music)
    }

    /// Cuts footage on every `every`-th beat, picking each shot with `BeatCutPlan` (quality, motion matched to the
    /// music's `energy` over each shot's timeline span, no moment twice, spread over the media).
    /// With `from` (the start of the cut range) before the first beat, `align` decides what plays there: `.fill`
    /// stretches the first shot back to `from` so no background shows; `.firstBeat` trims the head of the `music`
    /// clips so their first beat lands on `from`. `framing` gives each fill-framed clip its transform x and y.
    public mutating func beatCut(footage: [BeatFootage], beats: [Seconds], every: Int, trackId: String, from: Seconds? = nil, align: BeatAlign = .fill, music: [String] = [], energy: ((TimeRange) -> Double?)? = nil, framing: ((Clip) -> (x: Double, y: Double)?)? = nil) throws -> String {
        guard !footage.isEmpty else { throw EditError("No footage to cut") }
        var marks: [Seconds] = []
        for i in stride(from: 0, to: beats.count, by: max(1, every)) {
            let t = canvas.snap(beats[i])
            if marks.last.map({ t > $0 + 1e-6 }) ?? true { marks.append(t) }
        }
        guard marks.count >= 2 else { throw EditError("Need at least two beats in the range") }
        var lead = ""
        var moved: Seconds = 0
        if let from, marks[0] > canvas.snap(from) + 1e-6 {
            let start = canvas.snap(from), shift = marks[0] - start
            switch align {
            case .fill, .zero:
                marks[0] = start
                lead = " The first shot also covers \(fmt2(start))–\(fmt2(start + shift))s before the first beat."
            case .firstBeat:
                moved = shift
                guard !music.isEmpty else { throw EditError("align first_beat needs the music clip on the timeline") }
                for id in music {
                    guard var c = clip(id) else { continue }
                    if c.start <= start + 1e-6 {
                        let cut = shift + (start - c.start)
                        guard cut < c.duration else { continue }
                        c.sourceIn += cut * c.speed
                        c.duration -= cut
                        c.start = start
                    } else {
                        c.start -= shift
                    }
                    try replaceClip(c)
                }
                marks = marks.map { $0 - shift }
                lead = " The music now starts \(fmt2(shift))s later in the song so its first beat lands at \(fmt2(start))s."
            }
        }
        let spans = zip(marks, marks.dropFirst()).map { TimeRange($0, $1) }
        // Energy is read where the music played before a first_beat shift moved it.
        let plan = BeatCutPlan.choose(footage, segments: spans.map { .init(need: $0.duration, energy: energy?(TimeRange($0.start + moved, $0.end + moved))) })
        var placed: [Clip] = []
        for (span, pick) in zip(spans, plan.picks) {
            guard let pick else { continue }
            var c = Clip(id: Project.newClipId(), kind: .media, mediaId: footage[pick.footage].mediaId, start: span.start, duration: span.duration, sourceIn: pick.sourceIn)
            c.transform.fit = .fill
            if let f = framing?(c) {
                c.transform.x = f.x
                c.transform.y = f.y
            }
            c.volume = 0
            try addClip(c, trackId: trackId, mode: .overwrite)
            placed.append(c)
        }
        var note = "Cut \(placed.count) shots on \(trackId) to the beat (every \(every) beat\(every == 1 ? "" : "s")) from \(fmt2(marks.first!))s to \(fmt2(marks.last!))s." + lead
        let byMedia = Dictionary(grouping: placed) { $0.mediaId ?? "" }.mapValues(\.count)
        if byMedia.count > 1 { note += " Shots per media: " + byMedia.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", ") + "." }
        if plan.scored { note += plan.energyMatched ? " Picked by quality, with motion following the music's energy (louder passages get busier shots)." : " Picked by quality." }
        if plan.repeats > 0 {
            let list = plan.reused.prefix(6).map { r -> String in
                let need = spans[r.segment].duration
                return "\(footage[r.footage].mediaId) \(fmt2(r.sourceIn))–\(fmt2(r.sourceIn + need))s at \(fmt2(spans[r.segment].start))s"
            }
            note += " Every moment was used, so \(plan.repeats) shot(s) show again the moment shown longest ago (" + list.joined(separator: "; ") + (plan.reused.count > 6 ? "; …" : "") + "); add media or sources to avoid repeats."
        }
        let framed = placed.filter { $0.transform.x != 0 || $0.transform.y != 0 }.count
        if framed > 0 { note += " \(framed) shot(s) framed to keep faces or the subject in view." }
        return note
    }

    // MARK: Reframing

    /// Changes the canvas shape and pans each media clip to keep its subject in frame.
    /// `subject` gives subject centers over source time (fractions of the source frame).
    public mutating func reframe(width: Int, height: Int, subject: (Clip) -> [(t: Seconds, x: Double, y: Double)]) throws -> String {
        let oldAspect = Double(canvas.width) / Double(max(1, canvas.height))
        canvas.width = width
        canvas.height = height
        let canvasAspect = Double(width) / Double(height)
        var followed = 0, centered = 0, recentered = 0
        for ti in tracks.indices where tracks[ti].kind == .video {
            for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].kind == .media {
                var c = tracks[ti].clips[ci]
                guard let m = c.mediaId.flatMap({ mediaAsset($0) }), m.hasVideo, m.height > 0 else { continue }
                let srcAspect = Double(m.width) / Double(m.height)
                // Vertical offsets keep the same subject point and stay within the overflow, so the picture covers the frame.
                let wasH = (c.transform.fit == .fill ? max(1, oldAspect / srcAspect) : min(1, oldAspect / srcAspect)) * c.transform.scale
                let ph = max(1, canvasAspect / srcAspect) * c.transform.scale
                let roomY = max(0, (ph - 1) / 2)
                func fitY(_ v: Double) -> Double { min(roomY, max(-roomY, wasH > 0 ? v * ph / wasH : v)) }
                let beforeY = c.transform.y, beforeCurve = c.anim["transform.y"]
                c.transform.y = fitY(c.transform.y)
                if var curve = c.anim["transform.y"] {
                    for k in curve.keys.indices { if let v = curve.keys[k].v.number { curve.keys[k].v = .number(fitY(v)) } }
                    c.anim["transform.y"] = curve
                }
                if abs(beforeY - c.transform.y) > 1e-6 || beforeCurve != c.anim["transform.y"] { recentered += 1 }
                c.transform.fit = .fill
                c.anim["transform.x"] = nil
                let pw = max(1, srcAspect / canvasAspect) * c.transform.scale
                let room = (pw - 1) / 2
                let points = subject(c).filter { $0.t >= min(c.sourceIn, c.sourceOut) - 0.5 && $0.t <= max(c.sourceIn, c.sourceOut) + 0.5 }
                if points.isEmpty || room < 0.01 {
                    c.transform.x = 0
                    centered += 1
                } else {
                    // Smooth the path so the frame drifts rather than jitters.
                    let xs = points.map { min(room, max(-room, (0.5 - $0.x) * pw)) }
                    var smooth: [Double] = []
                    for i in xs.indices {
                        let lo = max(0, i - 2), hi = min(xs.count - 1, i + 2)
                        smooth.append(xs[lo...hi].reduce(0, +) / Double(hi - lo + 1))
                    }
                    var ks: [(Seconds, Double, Easing)] = []
                    for (p, x) in zip(points, smooth) {
                        let local = c.timelineTime(atSource: p.t) - c.start
                        guard local >= -0.01 && local <= c.duration + 0.01 else { continue }
                        if let last = ks.last, local - last.0 < 0.4 { continue }
                        ks.append((max(0, min(c.duration, local)), x, .easeInOut))
                    }
                    if ks.count >= 2 {
                        c.anim["transform.x"] = keys(ks)
                        c.transform.x = ks[0].1
                    } else {
                        c.transform.x = ks.first?.1 ?? smooth[0]
                    }
                    followed += 1
                }
                tracks[ti].clips[ci] = c
            }
        }
        return "Canvas is now \(width)×\(height). \(followed) clip(s) pan to follow their subject, \(centered) centered." + (recentered > 0 ? " \(recentered) clip(s) had their vertical offset refit so their pictures still cover the frame." : "")
    }
}

/// What a beat cut does before the first beat of its range.
public enum BeatAlign: String, CaseIterable, Sendable {
    /// The first shot starts at the range start and runs to the second cut.
    case fill
    /// Same as `fill`: the picture starts at the range start.
    case zero
    /// The music is trimmed so its first beat is at the range start.
    case firstBeat = "first_beat"
}
