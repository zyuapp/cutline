import CoreGraphics
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    /// A shot's color statistics as timeline_measure compare reads them: the clip rendered alone by the engine
    /// (camera log, ACES and RAW input, input tone and exposure, crop and framing) with its effects before
    /// `effectsBefore` (all when nil), at timeline `times` (default five across the clip), without bars; with its
    /// middle frame. `builds` keeps one render per clip and effect cut.
    func shotColor(_ c: Clip, _ p: Project, times: [Seconds]? = nil, effectsBefore: Int? = nil, builds: inout [String: BuiltTimeline]) async throws -> (stats: ColorMatch.Stats, middle: CGImage?) {
        guard let m = c.mediaId.flatMap({ p.mediaAsset($0) }), m.hasVideo else { throw EditError("\(c.id) has no picture") }
        let key = "\(c.id)|\(effectsBefore.map(String.init) ?? "all")"
        let built: BuiltTimeline
        if let hit = builds[key] {
            built = hit
        } else {
            guard let solo = p.soloPicture(c.id, effectsBefore: effectsBefore) else { throw EditError("No clip \(c.id)") }
            built = try await session.timeline(for: solo, renderScale: min(1, 360 / Double(max(p.canvas.width, p.canvas.height))), shared: false)
            builds[key] = built
        }
        let frame = 1 / max(1, p.canvas.fps)
        let ts = (times ?? [0.1, 0.3, 0.5, 0.7, 0.9].map { c.start + c.duration * $0 }).map { min(max($0, c.start), max(c.start, c.end - frame)) }
        let frames = try await Frames.timeline(built, times: ts, maxSize: CGSize(width: 320, height: 320))
        let bg = SIMD3(Float(p.canvas.background.r), Float(p.canvas.background.g), Float(p.canvas.background.b))
        let pixels = frames.flatMap { ShotColor.pictureSamples($0.image, background: bg) }
        guard !pixels.isEmpty else { throw EditError("\(c.id) shows no picture to sample") }
        return (ColorMatch.stats(pixels), frames.isEmpty ? nil : frames[frames.count / 2].image)
    }

    /// Index of the first match LUT on a clip, where a new one goes (the front of the stack) when it has none.
    static func matchSlot(_ c: Clip) -> Int {
        c.effects.firstIndex { $0.type == "color.lut" && ($0.id == "match" || $0.id.hasPrefix("match_s")) } ?? 0
    }

    /// The topmost visible media clip at timeline time `t`.
    static func pictureClip(at t: Seconds, _ p: Project) -> Clip? {
        p.tracks.filter { $0.kind == .video && !$0.hidden }.compactMap { $0.clip(at: t) }.filter { $0.kind == .media }.last
    }

    struct MatchPlan {
        var ref: Clip
        var refAt: Seconds?
        var refTimes: [Seconds]?
        /// reference was a time: refAt picks the clip and its shot, not one exact frame.
        var refByTime = false
        var ids: [String]
        var strength: Double
        var cap: Double?
        /// What gets a match LUT: whole clips, or single shots of clips that play several.
        var units: [MatchUnit] = []
        var refShot: String?
    }

    struct MatchUnit {
        var clip: String
        /// Source span of one shot, with its index and the clip's shot count; nil matches the whole clip.
        var shot: TimeRange?
        var index = 0
        var count = 1

        var effectId: String { shot == nil ? "match" : "match_s\(index + 1)" }
        var file: String { shot == nil ? clip : "\(clip)-s\(index + 1)" }
    }

    static func matchPlan(_ a: Args, _ current: Project) throws -> MatchPlan {
        var refAt = try a.optTime("reference_at")
        var refId = a.optString("reference")
        var refName = "reference_at", byTime = false
        // A time or anchor ("start", "marker:Hero", 12.5) as reference names the clip showing there.
        if let r = a.value("reference"), refAt == nil, current.clip(refId ?? "") == nil, let t = try? Args.parseTime(r, name: "reference") {
            refAt = min(max(0, t), max(0, current.duration - 0.01))
            refId = nil
            refName = "reference \(r.string ?? fmt2(t))"
            byTime = true
        }
        if refId == nil, let t = refAt {
            guard let c = pictureClip(at: t, current) else { throw EditError("No media clip at \(refName) \(fmt2(t))s") }
            refId = c.id
        }
        guard let refId else { throw EditError("Pass reference (the clip whose look the others match) or reference_at (a timeline time)") }
        guard let ref = current.clip(refId), ref.kind == .media else { throw EditError(current.clip(refId) == nil ? "No clip \(refId); reference is a media clip id or a timeline time or anchor" : "reference must be a media clip; \(refId) is \(current.clip(refId)!.kind.rawValue)") }
        var refTimes: [Seconds]?
        if let t = refAt {
            guard t >= ref.start - 1e-6, t <= ref.end + 1e-6 else { throw EditError("reference_at \(fmt2(t))s is outside \(refId) (\(fmt2(ref.start))–\(fmt2(ref.end))s)") }
            if !byTime { refTimes = [min(t, ref.end - 0.01)] }
        }
        var ids = a.strings("clips") ?? []
        if let tid = a.optString("track") {
            guard let i = current.trackIndex(tid) else { throw EditError("No track \(tid)") }
            ids += current.tracks[i].clips.filter { $0.kind == .media }.map(\.id)
        }
        if ids.isEmpty, let v1 = current.tracks.first(where: { $0.kind == .video }) { ids = v1.clips.filter { $0.kind == .media }.map(\.id) }
        let named = ids
        var seen: Set<String> = [refId]
        ids = ids.filter { seen.insert($0).inserted }
        if ids.isEmpty, !a.bool("include_reference_shots", default: false) {
            let source = a.optString("track").map { "track \($0)" } ?? (a.strings("clips") != nil ? "clips" : current.tracks.first { $0.kind == .video }.map { "track \($0.id) (the default)" } ?? "the timeline")
            let what = named.isEmpty ? "\(source) has no media clips" : "\(source) has only the reference clip \(refId)"
            throw EditError("Nothing to match: \(what). Pass clips or a track holding other clips, or include_reference_shots:true to match the reference's other shots")
        }
        let strength = a.optDouble("strength") ?? 0.8
        guard (0...1).contains(strength) else { throw EditError("strength is 0…1") }
        return MatchPlan(ref: ref, refAt: refAt, refTimes: refTimes, refByTime: byTime, ids: ids, strength: strength, cap: a.bool("allow_large", default: false) ? nil : ColorMatch.maxLightnessShift)
    }

    /// Splits the plan into shots: each clip that plays several shots (scope shot, the default) gets one LUT per shot,
    /// the reference is measured in its own shot only. The reference clip is left alone unless
    /// include_reference_shots matches its other shots too.
    func matchUnits(_ plan: inout MatchPlan, _ a: Args, _ current: Project) throws {
        let scope = try Toolbox.gradeScope(a, shots: 2)
        let refShots = clipShots(plan.ref, current)
        if scope == .shot, refShots.count > 1 {
            let t = plan.refAt ?? (plan.ref.start + plan.ref.duration / 2)
            let i = Toolbox.shotIndex(refShots, clip: plan.ref, at: t)
            let r = refShots[i]
            if plan.refTimes == nil {
                let span = plan.ref.timelineSpan(ofSource: r)
                plan.refTimes = [0.1, 0.3, 0.5, 0.7, 0.9].map { span.start + (span.end - span.start) * $0 }
            }
            plan.refShot = Toolbox.shotLabel(refShots, i, clip: plan.ref)
            if a.bool("include_reference_shots", default: false) {
                for j in refShots.indices where j != i { plan.units.append(MatchUnit(clip: plan.ref.id, shot: refShots[j], index: j, count: refShots.count)) }
            }
        }
        for id in plan.ids {
            guard let c = current.clip(id) else { throw EditError("No clip \(id)") }
            let shots = clipShots(c, current)
            if scope == .shot, shots.count > 1 {
                plan.units += shots.indices.map { MatchUnit(clip: id, shot: shots[$0], index: $0, count: shots.count) }
            } else {
                plan.units.append(MatchUnit(clip: id))
            }
        }
        guard !plan.units.isEmpty else { throw EditError("No clips to match; pass clips or track") }
    }

    func matchColorRecipe(_ a: Args, dry: Bool) async throws -> ToolResult {
        let b = try session.requireBundle()
        let current = try session.project()
        var plan = try Toolbox.matchPlan(a, current)
        try matchUnits(&plan, a, current)
        let dir = b.cacheURL.appendingPathComponent("looks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let made = try await matchShots(plan, current, dir: dir)
        return try applyMatch(made.files, report: made.report, warnings: made.warnings, plan: plan, current: current, dry: dry)
    }

    /// Each shot's match LUT against the reference, in its own async frame: the debug build's task allocator
    /// aborted when this loop shared match_color's.
    func matchShots(_ plan: MatchPlan, _ current: Project, dir: URL) async throws -> (files: [(MatchUnit, URL)], report: [String], warnings: [String]) {
        var builds: [String: BuiltTimeline] = [:]
        let reference = try await shotColor(plan.ref, current, times: plan.refTimes, builds: &builds)
        let refPrint = await ShotColor.featurePrintOffPool(reference.middle)
        var files: [(MatchUnit, URL)] = []
        var report: [String] = [], warnings: [String] = []
        for u in plan.units {
            guard let c = current.clip(u.clip) else { throw EditError("No clip \(u.clip)") }
            guard c.kind == .media, c.mediaId.flatMap({ current.mediaAsset($0) })?.hasVideo == true else { report.append("\(u.clip): skipped (no picture)"); continue }
            let times = u.shot.map { r in
                let span = c.timelineSpan(ofSource: r)
                return [0.1, 0.3, 0.5, 0.7, 0.9].map { span.start + (span.end - span.start) * $0 }
            }
            let shot = try await shotColor(c, current, times: times, effectsBefore: Toolbox.matchSlot(c), builds: &builds)
            let shotPrint = await ShotColor.featurePrintOffPool(shot.middle)
            let content = ShotColor.contentDistance(shotPrint, refPrint)
            let label = u.shot.map { r in
                let t = c.timelineSpan(ofSource: r)
                return "\(u.clip) shot \(u.index + 1)/\(u.count) (\(fmt2(t.start))–\(fmt2(t.end))s)"
            } ?? u.clip
            let made = try Toolbox.matchShot(label, file: u.file, to: plan.ref.id, shot.stats, reference.stats, content: content, strength: plan.strength, cap: plan.cap, dir: dir)
            files.append((u, made.url))
            report.append(made.line)
            if let w = made.warning { warnings.append(w) }
        }
        return (files, report, warnings)
    }

    /// The edit half of match_color, kept out of the async function: the debug build's task allocator
    /// aborted when the edit ran inline there.
    func applyMatch(_ made: [(MatchUnit, URL)], report: [String], warnings: [String], plan: MatchPlan, current: Project, dry: Bool) throws -> ToolResult {
        let refId = plan.ref.id, strength = plan.strength
        let refText = (plan.refAt.map { plan.refByTime ? "\(refId) (the clip at \(fmt2($0))s)" : "\(refId) at \(fmt2($0))s" } ?? refId) + (plan.refShot.map { " (\($0))" } ?? "")
        return try runEdit("Match \(made.count) shot(s) to \(Toolbox.clipName(refId, current))", dry: dry) { p in
            var slots: [String: Int] = [:]
            for id in Set(made.map(\.0.clip)) {
                guard let loc = p.locateClip(id) else { continue }
                slots[id] = Toolbox.matchSlot(p.tracks[loc.track].clips[loc.clip])
                p.tracks[loc.track].clips[loc.clip].effects.removeAll { $0.type == "color.lut" && ($0.id == "match" || $0.id.hasPrefix("match_s")) }
            }
            for (u, url) in made.reversed() {
                guard let loc = p.locateClip(u.clip) else { continue }
                let at = min(slots[u.clip] ?? 0, p.tracks[loc.track].clips[loc.clip].effects.count)
                p.tracks[loc.track].clips[loc.clip].effects.insert(Effect(id: u.effectId, type: "color.lut", params: ["file": .string(url.path)], sourceRange: u.shot), at: at)
            }
            let perShot = made.contains { $0.0.shot != nil }
            return (["Matched to \(refText) at strength \(fmt2(strength)):"] + report.map { "  " + $0 } + warnings).joined(separator: "\n")
                + (perShot ? "\nClips that play several shots get one LUT per shot (match_s1, match_s2…) acting only in that shot; scope:\"clip\" matches whole clips." : "")
                + "\nTune with param_set fx.\(perShot ? "match_s<n>" : "match").mix; check continuity with timeline_measure what:[\"compare\"] reference:\(refId)."
        }
    }

    /// Writes one shot's match LUT and describes it.
    static func matchShot(_ id: String, file: String, to refId: String, _ s: ColorMatch.Stats, _ r: ColorMatch.Stats, content: Double?, strength: Double, cap: Double?, dir: URL) throws -> (url: URL, line: String, warning: String?) {
        let cmp = ColorMatch.compare(s, to: r, contentDistance: content)
        let f = ColorMatch.transform(from: s, to: r, strength: strength, maxLightnessShift: cap)
        let url = dir.appendingPathComponent("match-\(file)-\(refId).cube")
        try writeCube(ColorMath.cubeData(size: 33, f), size: 33, title: "Match \(id) to \(refId)", to: url)
        let after = ColorMatch.matchedLightness(from: s, to: r, strength: strength, maxLightnessShift: cap)
        var line = String(format: "%@: median L %.0f→%.0f (reference %.0f), a %.1f b %.1f toward %.1f %.1f, colorfulness %.1f (reference %.1f), ΔE %.1f before", id, s.mean.x, after, r.mean.x, s.mean.y, s.mean.z, r.mean.y, r.mean.z, s.chroma, r.chroma, cmp.deltaE)
        let wanted = (r.mean.x - s.mean.x) * strength
        if abs(after - s.mean.x) < abs(wanted) - 1 {
            line += String(format: "; lightness moves %+.0f of the %+.0f L asked: matching never more than doubles or halves a tone's contrast", after - s.mean.x, wanted)
            if let cap { line += String(format: " and moves tones at most ±%.0f L (allow_large:true lifts that)", cap) }
        }
        let warning = cmp.warnings.isEmpty ? nil : "Warning: \(id) may not be comparable with \(refId): " + cmp.warnings.joined(separator: "; ") + ". Match it to a shot from its own scene, lower strength, or check it with timeline_frames."
        return (url, line, warning)
    }

    /// timeline_measure compare: each shot of the main picture, graded, against a reference shot. Shots split at clip
    /// edges and scene cuts like match_color's; titles, graphics and captions over the picture are left out.
    func measureCompare(_ p: Project, reference: String?, referenceTime: Seconds?, range: TimeRange?) async throws -> [String] {
        let scale = min(1, 360 / Double(max(p.canvas.width, p.canvas.height)))
        let picture = p.pictureOnly()
        let built = try await session.timeline(for: picture, renderScale: scale, shared: false)
        let bg = SIMD3(Float(p.canvas.background.r), Float(p.canvas.background.g), Float(p.canvas.background.b))
        var shots: [(start: Seconds, end: Seconds, clip: Clip, label: String, stats: ColorMatch.Stats)] = []
        for s in picture.mainPictureShots(shots: { clipShots($0, p) }) {
            if let range, s.range.end <= range.start || s.range.start >= range.end { continue }
            let (lo, hi) = (s.range.start, s.range.end)
            let frames = try await Frames.timeline(built, times: [0.1, 0.3, 0.5, 0.7, 0.9].map { lo + (hi - lo) * $0 }, maxSize: CGSize(width: 320, height: 320))
            let pixels = frames.flatMap { ShotColor.pictureSamples($0.image, background: bg) }
            guard !pixels.isEmpty else { continue }
            let label = s.shots > 1 ? "\(s.clip.id) shot \(s.shot + 1)/\(s.shots)" : s.clip.id
            shots.append((lo, hi, s.clip, label, ColorMatch.stats(pixels)))
        }
        guard !shots.isEmpty else { return ["Compare: no shots with media in range"] }
        var ri = 0
        if let reference {
            let mine = shots.indices.filter { shots[$0].clip.id == reference }
            guard let first = mine.first, let c = p.clip(reference) else { throw EditError("reference \(reference) is not a shot in range; shots: " + Array(Set(shots.map(\.clip.id))).sorted().joined(separator: ", ")) }
            // Like match_color: the clip's shot at its middle.
            let mid = referenceTime ?? (c.start + c.duration / 2)
            ri = mine.first { shots[$0].start <= mid + 1e-6 && mid < shots[$0].end } ?? first
        } else if let t = referenceTime, let i = shots.firstIndex(where: { t >= $0.start && t < $0.end }) {
            ri = i
        }
        let ref = shots[ri]
        var lines = ["Compare (graded main picture per shot; titles, graphics, captions and bars left out) against \(ref.label) \(fmt2(ref.start))–\(fmt2(ref.end))s; ΔE is CIEDE2000 of the median color (under 2 invisible, 2–5 close, over 5 a visible mismatch):"]
        var mismatched: [String] = []
        for (i, s) in shots.enumerated() {
            let st = s.stats
            var line = String(format: "  %@–%@ %@: L %.1f a %.1f b %.1f, colorfulness %.1f", fmt2(s.start), fmt2(s.end), s.label, st.mean.x, st.mean.y, st.mean.z, st.chroma)
            if i == ri {
                line += " (reference)"
            } else {
                let cmp = ColorMatch.compare(st, to: ref.stats)
                line += String(format: ", ΔE %.1f, ΔL %+.1f, colorfulness ×%.2f", cmp.deltaE, -cmp.lightnessGap, 1 / max(cmp.colorfulnessRatio, 1e-3))
                if cmp.deltaE > 5 {
                    line += " — visible mismatch"
                    if !mismatched.contains(s.clip.id) { mismatched.append(s.clip.id) }
                }
                if !cmp.warnings.isEmpty { line += "; not directly comparable: " + cmp.warnings.joined(separator: "; ") }
            }
            lines.append(line)
        }
        if !mismatched.isEmpty {
            lines.append("Mismatched: \(mismatched.joined(separator: ", ")). Fix with recipe match_color {clips: [\(mismatched.map { "\"\($0)\"" }.joined(separator: ", "))], reference: \"\(ref.clip.id)\"}, or grade them by hand.")
        }
        return lines
    }
}
