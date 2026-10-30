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

    /// Lays footage on a track so each cut lands on a beat. `pool` is source spans to draw from, in order.
    public mutating func beatCut(pool: [(mediaId: String, range: TimeRange)], beats: [Seconds], every: Int, trackId: String) throws -> String {
        guard !pool.isEmpty else { throw EditError("No footage to cut") }
        var marks: [Seconds] = []
        for i in stride(from: 0, to: beats.count, by: max(1, every)) {
            let t = canvas.snap(beats[i])
            if marks.last.map({ t > $0 + 1e-6 }) ?? true { marks.append(t) }
        }
        guard marks.count >= 2 else { throw EditError("Need at least two beats in the range") }
        var placed: [String] = []
        var next = 0
        var used: [String: Seconds] = [:]
        for (a, b) in zip(marks, marks.dropFirst()) {
            let need = b - a
            var tries = 0
            while tries < pool.count {
                let item = pool[next % pool.count]
                next += 1
                tries += 1
                let key = item.mediaId + "\(item.range.start)"
                guard item.range.duration >= need - 1e-6 else { continue }
                // First use takes the middle of the span, away from its edges; later uses continue after it.
                let fresh = item.range.start + (item.range.duration - need) / 2
                let from = used[key] ?? fresh
                let start = item.range.end - from >= need - 1e-6 ? from : item.range.start
                used[key] = start + need
                var c = Clip(id: Project.newClipId(), kind: .media, mediaId: item.mediaId, start: a, duration: need, sourceIn: start)
                c.transform.fit = .fill
                c.volume = 0
                try addClip(c, trackId: trackId, mode: .overwrite)
                placed.append(c.id)
                break
            }
        }
        return "Cut \(placed.count) shots on \(trackId) to the beat (every \(every) beat\(every == 1 ? "" : "s")) from \(fmt2(marks.first!))s to \(fmt2(marks.last!))s."
    }

    // MARK: Reframing

    /// Changes the canvas shape and pans each media clip to keep its subject in frame.
    /// `subject` gives subject centers over source time (fractions of the source frame).
    public mutating func reframe(width: Int, height: Int, subject: (Clip) -> [(t: Seconds, x: Double, y: Double)]) throws -> String {
        canvas.width = width
        canvas.height = height
        let canvasAspect = Double(width) / Double(height)
        var followed = 0, centered = 0
        for ti in tracks.indices where tracks[ti].kind == .video {
            for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].kind == .media {
                var c = tracks[ti].clips[ci]
                guard let m = c.mediaId.flatMap({ mediaAsset($0) }), m.hasVideo, m.height > 0 else { continue }
                let srcAspect = Double(m.width) / Double(m.height)
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
        return "Canvas is now \(width)×\(height). \(followed) clip(s) pan to follow their subject, \(centered) centered."
    }
}
