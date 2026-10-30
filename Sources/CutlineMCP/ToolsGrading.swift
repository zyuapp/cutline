import CoreGraphics
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    /// A shot's color statistics from source frames at `times` (default five across what it plays), inside its crop
    /// and without letterbox bars, with its middle frame.
    static func shotColor(_ c: Clip, _ p: Project, times: [Seconds]? = nil) async throws -> (stats: ColorMatch.Stats, middle: CGImage?) {
        guard let m = c.mediaId.flatMap({ p.mediaAsset($0) }), m.hasVideo else { throw EditError("\(c.id) has no picture") }
        let lo = min(c.sourceIn, c.sourceOut), span = abs(c.sourceOut - c.sourceIn)
        let ts = m.isImage ? [0.0] : times ?? [0.1, 0.3, 0.5, 0.7, 0.9].map { lo + span * $0 }
        let crop = c.transform.crop
        let frames = try await Frames.media(m, times: ts, maxSize: CGSize(width: 240, height: 240))
        var pixels: [SIMD3<Float>] = []
        for f in frames { pixels += ShotColor.pictureSamples(f.image, crop: (crop.left, crop.top, crop.right, crop.bottom)) }
        return (ColorMatch.stats(pixels), frames.isEmpty ? nil : frames[frames.count / 2].image)
    }

    /// The topmost visible media clip at timeline time `t`.
    static func pictureClip(at t: Seconds, _ p: Project) -> Clip? {
        p.tracks.filter { $0.kind == .video && !$0.hidden }.compactMap { $0.clip(at: t) }.filter { $0.kind == .media }.last
    }

    struct MatchPlan {
        var ref: Clip
        var refAt: Seconds?
        var refTimes: [Seconds]?
        var ids: [String]
        var strength: Double
        var cap: Double?
    }

    static func matchPlan(_ a: Args, _ current: Project) throws -> MatchPlan {
        let refAt = try a.optTime("reference_at")
        var refId = a.optString("reference")
        if refId == nil, let t = refAt {
            guard let c = pictureClip(at: t, current) else { throw EditError("No media clip at reference_at \(fmt2(t))s") }
            refId = c.id
        }
        guard let refId else { throw EditError("Pass reference (the clip whose look the others match) or reference_at (a timeline time)") }
        guard let ref = current.clip(refId), ref.kind == .media else { throw EditError("reference must be a media clip") }
        var refTimes: [Seconds]?
        if let t = refAt {
            guard t >= ref.start - 1e-6, t <= ref.end + 1e-6 else { throw EditError("reference_at \(fmt2(t))s is outside \(refId) (\(fmt2(ref.start))–\(fmt2(ref.end))s)") }
            refTimes = [ref.sourceTime(atTimeline: min(t, ref.end - 0.01))]
        }
        var ids = a.strings("clips") ?? []
        if let tid = a.optString("track") {
            guard let i = current.trackIndex(tid) else { throw EditError("No track \(tid)") }
            ids += current.tracks[i].clips.filter { $0.kind == .media }.map(\.id)
        }
        if ids.isEmpty, let v1 = current.tracks.first(where: { $0.kind == .video }) { ids = v1.clips.filter { $0.kind == .media }.map(\.id) }
        var seen: Set<String> = [refId]
        ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { throw EditError("No clips to match; pass clips or track") }
        let strength = a.optDouble("strength") ?? 0.8
        guard (0...1).contains(strength) else { throw EditError("strength is 0…1") }
        return MatchPlan(ref: ref, refAt: refAt, refTimes: refTimes, ids: ids, strength: strength, cap: a.bool("allow_large", default: false) ? nil : ColorMatch.maxLightnessShift)
    }

    func matchColorRecipe(_ a: Args, dry: Bool) async throws -> ToolResult {
        let b = try session.requireBundle()
        let current = try session.project()
        let plan = try Toolbox.matchPlan(a, current)
        let dir = b.cacheURL.appendingPathComponent("looks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let made = try await Toolbox.matchShots(plan, current, dir: dir)
        return try applyMatch(made.files, report: made.report, warnings: made.warnings, plan: plan, current: current, dry: dry)
    }

    /// Each shot's match LUT against the reference, in its own async frame: the debug build's task allocator
    /// aborted when this loop shared match_color's.
    static func matchShots(_ plan: MatchPlan, _ current: Project, dir: URL) async throws -> (files: [String: URL], report: [String], warnings: [String]) {
        let reference = try await shotColor(plan.ref, current, times: plan.refTimes)
        let refPrint = reference.middle.flatMap(ShotColor.featurePrint)
        var files: [String: URL] = [:]
        var report: [String] = [], warnings: [String] = []
        for id in plan.ids {
            guard let c = current.clip(id) else { throw EditError("No clip \(id)") }
            guard c.kind == .media, c.mediaId.flatMap({ current.mediaAsset($0) })?.hasVideo == true else { report.append("\(id): skipped (no picture)"); continue }
            let shot = try await shotColor(c, current)
            let content = ShotColor.contentDistance(shot.middle.flatMap(ShotColor.featurePrint), refPrint)
            let made = try matchShot(id, to: plan.ref.id, shot.stats, reference.stats, content: content, strength: plan.strength, cap: plan.cap, dir: dir)
            files[id] = made.url
            report.append(made.line)
            if let w = made.warning { warnings.append(w) }
        }
        return (files, report, warnings)
    }

    /// The edit half of match_color, kept out of the async function: the debug build's task allocator
    /// aborted when the edit ran inline there.
    func applyMatch(_ made: [String: URL], report: [String], warnings: [String], plan: MatchPlan, current: Project, dry: Bool) throws -> ToolResult {
        let refId = plan.ref.id, strength = plan.strength
        let refText = plan.refAt.map { "\(refId) at \(fmt2($0))s" } ?? refId
        return try runEdit("Match \(made.count) shot(s) to \(Toolbox.clipName(refId, current))", dry: dry) { p in
            for (id, url) in made {
                guard let loc = p.locateClip(id) else { continue }
                p.tracks[loc.track].clips[loc.clip].effects.removeAll { $0.id == "match" }
                p.tracks[loc.track].clips[loc.clip].effects.insert(Effect(id: "match", type: "color.lut", params: ["file": .string(url.path)]), at: 0)
            }
            return (["Matched to \(refText) at strength \(fmt2(strength)):"] + report.map { "  " + $0 } + warnings).joined(separator: "\n")
                + "\nTune with param_set fx.match.mix; check continuity with timeline_measure what:[\"compare\"] reference:\(refId)."
        }
    }

    /// Writes one shot's match LUT and describes it.
    static func matchShot(_ id: String, to refId: String, _ s: ColorMatch.Stats, _ r: ColorMatch.Stats, content: Double?, strength: Double, cap: Double?, dir: URL) throws -> (url: URL, line: String, warning: String?) {
        let cmp = ColorMatch.compare(s, to: r, contentDistance: content)
        let f = ColorMatch.transform(from: s, to: r, strength: strength, maxLightnessShift: cap)
        let url = dir.appendingPathComponent("match-\(id)-\(refId).cube")
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

    func qualifyRecipe(_ a: Args, dry: Bool) async throws -> ToolResult {
        let current = try session.project()
        let clipId = try a.string("clip")
        guard let c = current.clip(clipId), c.kind == .media, let m = c.mediaId.flatMap({ current.mediaAsset($0) }), m.hasVideo else { throw EditError("clip must be a media clip with a picture") }
        let at = try a.optTime("at") ?? (c.start + c.duration / 2)
        guard at >= c.start - 1e-6, at <= c.end + 1e-6 else { throw EditError("at \(fmt2(at))s is outside \(clipId) (\(fmt2(c.start))–\(fmt2(c.end))s)") }
        let effectId = a.optString("effect")
        let existing = effectId.flatMap { id in c.effects.first { $0.id == id } }
        let type = existing?.type ?? a.optString("type") ?? "color.wheels"
        guard EffectCatalog.type(type)?.spec("q_hue") != nil else { throw EditError("\(type) can't be limited to a qualifier; use a color, blur or stylize effect") }
        let source = m.isImage ? 0 : c.sourceTime(atTimeline: min(at, c.end - 0.01))
        guard let frame = try await Frames.media(m, times: [source], maxSize: CGSize(width: 960, height: 960)).first?.image else { throw EditError("Cannot read a frame of \(m.id)") }
        // The eyedropper sees the picture as the effect receives it.
        let picture = ShotColor.picture(frame, effects: c.effects, before: existing?.id, clip: c, at: at - c.start)
        var region: CGRect
        var faceBox: CGRect?
        if a.bool("face", default: false) {
            let faces = ShotColor.faces(picture)
            let n = a.optInt("n") ?? 0
            guard n >= 0, n < faces.count else { throw EditError(faces.isEmpty ? "No face found in \(clipId) at \(fmt2(at))s; pass x and y of a skin area instead" : "Only \(faces.count) face(s) at \(fmt2(at))s; n counts from 0, largest first") }
            faceBox = faces[n]
            region = ShotColor.skinPatch(of: faces[n])
        } else {
            let x = try a.double("x"), y = try a.double("y")
            guard (0...1).contains(x), (0...1).contains(y) else { throw EditError("x and y are fractions of the frame, 0…1 from the top left") }
            let r = a.optDouble("radius") ?? 0.02
            let rx = r * Double(picture.height) / Double(picture.width)
            region = CGRect(x: x - rx, y: y - r, width: 2 * rx, height: 2 * r)
        }
        let samples = ShotColor.samples(picture, in: region)
        guard let q = Qualifier.pick(samples) else { throw EditError("The sampled pixels are nearly gray, so there is no hue to key; sample a colored area, or set q_hue_width 360 for a luma-only key") }
        let frameSamples = ShotColor.pictureSamples(picture, step: 4)
        let coverage = Double(frameSamples.filter { q.clean(Double(q.weight($0))) > 0.5 }.count) / Double(max(1, frameSamples.count))
        let hit = Double(samples.filter { q.clean(Double(q.weight($0))) > 0.9 }.count) / Double(max(1, samples.count))
        let window = a.bool("window", default: faceBox != nil)
        let where_ = faceBox.map { String(format: "face %d (%.2f, %.2f, %.2f×%.2f)", a.optInt("n") ?? 0, $0.minX, $0.minY, $0.width, $0.height) } ?? String(format: "(%.2f, %.2f)", region.midX, region.midY)
        return try runEdit("Qualify \(Toolbox.clipName(clipId, current))", dry: dry) { p in
            guard let loc = p.locateClip(clipId) else { throw EditError("No clip \(clipId)") }
            var clip = p.tracks[loc.track].clips[loc.clip]
            var e = existing ?? Effect(id: effectId ?? clip.nextEffectId(type), type: type)
            let limit = e.params["limit"]?.string ?? "none"
            var shape = limit.split(separator: "+").map(String.init).first { $0 == "rect" || $0 == "ellipse" }
            if window, let box = faceBox {
                shape = "ellipse"
                e.params["limit_x"] = .number((box.midX * 1000).rounded() / 1000)
                e.params["limit_y"] = .number((box.midY * 1000).rounded() / 1000)
                e.params["limit_width"] = .number(min(3, (box.width * 1.35 * 1000).rounded() / 1000))
                e.params["limit_height"] = .number(min(3, (box.height * 1.5 * 1000).rounded() / 1000))
                e.params["limit_feather"] = .number(0.03)
            }
            e.params["limit"] = .string(shape.map { "\($0)+qualifier" } ?? "qualifier")
            e.params["q_preset"] = nil
            e.params["q_softness"] = nil
            for (k, v) in q.params { e.params[k] = v }
            if let i = clip.effects.firstIndex(where: { $0.id == e.id }) { clip.effects[i] = e } else { clip.effects.append(e) }
            p.tracks[loc.track].clips[loc.clip] = clip
            var text = "Qualifier on \(clipId) effect \(e.id) (\(e.type), limit \(e.params["limit"]!.string!)) sampled from \(samples.count) pixels at \(where_), \(fmt2(at))s: \(q.summary). "
            text += String(format: "%.0f%% of the sampled area keys fully; the colors cover %.0f%% of the whole frame.", hit * 100, coverage * 100)
            if shape != nil && window && faceBox != nil { text += " An ellipse window on the face keeps the key there; make it follow the face with param_set bind fx.\(e.id).limit_x/limit_y to face:\(m.id)." }
            else if shape == nil && coverage > 0.35 { text += " That is a lot of the frame: narrow it with q_hue_width or q_sat_max, or add a window (limit ellipse+qualifier)." }
            return text + " Check it with timeline_frames view:\"matte\" clip:\(clipId) effect:\(e.id); refine with q_clean_black, q_clean_white, q_denoise and q_blur."
        }
    }

    /// timeline_measure compare: each shot's graded color against a reference shot.
    func measureCompare(_ p: Project, reference: String?, referenceTime: Seconds?, range: TimeRange?) async throws -> [String] {
        let b = try session.requireBundle()
        let scale = min(1, 360 / Double(max(p.canvas.width, p.canvas.height)))
        let built = try await TimelineBuilder.build(p, transcripts: b.transcripts(for: p), library: session.library, renderScale: scale)
        var cuts = Set<Double>([0, p.duration])
        for t in p.tracks where t.kind == .video && !t.hidden { for c in t.clips where c.kind == .media { cuts.insert(c.start); cuts.insert(c.end) } }
        let bounds = cuts.sorted()
        var shots: [(start: Seconds, end: Seconds, clip: Clip, stats: ColorMatch.Stats)] = []
        for (lo, hi) in zip(bounds, bounds.dropFirst()) where hi - lo > 0.3 {
            if let range, hi <= range.start || lo >= range.end { continue }
            guard let main = Toolbox.pictureClip(at: (lo + hi) / 2, p) else { continue }
            let frames = try await Frames.timeline(built, times: [0.25, 0.5, 0.75].map { lo + (hi - lo) * $0 }, maxSize: CGSize(width: 320, height: 320))
            let bg = SIMD3(Float(p.canvas.background.r), Float(p.canvas.background.g), Float(p.canvas.background.b))
            let pixels = frames.flatMap { ShotColor.pictureSamples($0.image, background: bg) }
            guard !pixels.isEmpty else { continue }
            shots.append((lo, hi, main, ColorMatch.stats(pixels)))
        }
        guard !shots.isEmpty else { return ["Compare: no shots with media in range"] }
        var ri = 0
        if let reference {
            guard let i = shots.firstIndex(where: { $0.clip.id == reference }) else { throw EditError("reference \(reference) is not a shot in range; shots: " + shots.map(\.clip.id).joined(separator: ", ")) }
            ri = i
        } else if let t = referenceTime, let i = shots.firstIndex(where: { t >= $0.start && t < $0.end }) {
            ri = i
        }
        let ref = shots[ri]
        var lines = ["Compare (graded picture, bars left out) against \(ref.clip.id) \(fmt2(ref.start))–\(fmt2(ref.end))s; ΔE is CIEDE2000 of the median color (under 2 invisible, 2–5 close, over 5 a visible mismatch):"]
        var mismatched: [String] = []
        for (i, s) in shots.enumerated() {
            let st = s.stats
            var line = String(format: "  %@–%@ %@: L %.1f a %.1f b %.1f, colorfulness %.1f", fmt2(s.start), fmt2(s.end), s.clip.id, st.mean.x, st.mean.y, st.mean.z, st.chroma)
            if i == ri {
                line += " (reference)"
            } else {
                let cmp = ColorMatch.compare(st, to: ref.stats)
                line += String(format: ", ΔE %.1f, ΔL %+.1f, colorfulness ×%.2f", cmp.deltaE, -cmp.lightnessGap, 1 / max(cmp.colorfulnessRatio, 1e-3))
                if cmp.deltaE > 5 {
                    line += " — visible mismatch"
                    mismatched.append(s.clip.id)
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
