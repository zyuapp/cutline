import CutlineCore
import CutlineEngine
import Foundation
import simd

extension Toolbox {
    /// Seconds around a track_mask correction its re-anchored track blends over.
    static let correctionReach: Seconds = 1

    /// recipe track_mask: keyframes a mask.shape's points so the shape follows a planar track, its points tracked as
    /// a group or its bounding box, optionally snapped to a segmentation matte's edges; or outlines a person or
    /// subject matte on every frame. Corrections re-anchor tracking at their frames.
    func trackMask(_ a: Args, dry: Bool) async throws -> ToolResult {
        let b = try session.requireBundle()
        let current = try session.project()
        let clipId = try a.string("clip")
        guard let c = current.clip(clipId), c.kind == .media, let mid = c.mediaId, let m = current.mediaAsset(mid), m.hasVideo, !m.isImage else { throw EditError("\(clipId) is not a video clip") }
        let modeName = a.optString("mode") ?? "planar"
        guard let mode = RotoTracker.Mode(rawValue: modeName) else { throw EditError("mode is planar, points, translate, person or subject") }
        let outlines = mode == .person || mode == .subject
        let shapes = c.effects.filter { $0.type == "mask.shape" }
        let existing = (a.optString("effect") ?? shapes.first?.id).flatMap { id in c.effects.first { $0.id == id } }
        if let given = a.optString("effect"), existing?.type != "mask.shape", !(outlines && existing == nil) {
            throw EditError("\(clipId) has no mask.shape \(given); effects: \(c.effects.map(\.id).joined(separator: ", ").ifEmptyText("none"))")
        }
        guard existing != nil || outlines else {
            throw EditError("\(clipId) has no mask.shape; draw one first: effect_add {target: \"\(clipId)\", type: \"mask.shape\", params: {points: \"x,y x,y x,y …\"}}, or use mode \"person\" or \"subject\" to outline the matte")
        }
        let effectId = existing?.id ?? a.optString("effect") ?? c.nextEffectId("mask.shape")
        let at = min(max(try a.optTime("at") ?? c.start, c.start), c.end - 1e-3)
        let src = c.sourceTime(atTimeline: at)
        let path = "fx.\(effectId).points"
        // Mask points are fractions of the cropped picture; trackers work in the full source frame.
        func toSource(_ p: SIMD2<Double>, at t: Seconds) -> SIMD2<Double> {
            let crop = c.resolvedTransform(at: t - c.start).crop
            return SIMD2(crop.left + p.x * max(0.0001, 1 - crop.left - crop.right), crop.top + p.y * max(0.0001, 1 - crop.top - crop.bottom))
        }
        let crop = c.resolvedTransform(at: at - c.start).crop
        let cw = max(0.0001, 1 - crop.left - crop.right), ch = max(0.0001, 1 - crop.top - crop.bottom)
        let toClip = { (p: SIMD2<Double>) in SIMD2((p.x - crop.left) / cw, (p.y - crop.top) / ch) }
        var given: [(Double, Double)] = []
        if let fx = existing {
            let raw = c.anim[path]?.value(at: at - c.start)?.string ?? fx.params["points"]?.string ?? EffectCatalog.type("mask.shape")?.spec("points")?.defaultValue.string ?? ""
            given = Curve.points(raw) ?? []
            guard given.count >= 3 || outlines else { throw EditError("\(effectId) has no points at \(fmt2(at))s") }
        }
        let points = given.map { toSource(SIMD2($0.0, $0.1), at: at) }
        let aspect = m.width > 0 && m.height > 0 ? Double(m.width) / Double(m.height) : 16.0 / 9
        let lo = max(0, min(c.sourceIn, c.sourceOut)), hi = min(m.duration, max(c.sourceIn, c.sourceOut))
        var quad: [SIMD2<Double>]?
        if let list = a.value("corners")?.array {
            let pts = list.compactMap { $0.array.flatMap { xy in xy.count == 2 ? xy.compactMap(\.double) : nil } }.filter { $0.count == 2 }
            guard pts.count == 4 else { throw EditError("corners is four [x, y] pairs: top-left, top-right, bottom-right, bottom-left") }
            quad = pts.map { toSource(SIMD2($0[0], $0[1]), at: at) }
        }
        let count = min(200, max(6, a.optInt("detail") ?? 32))
        var anchors = [RotoTracker.Anchor(t: src, points: points)]
        for item in a.value("correct")?.array ?? [] {
            let ca = Args(item)
            let t = try ca.time("at")
            guard t >= c.start - 1e-6, t <= c.end + 1e-6 else { throw EditError("correct at \(fmt2(t))s is outside \(clipId) (\(fmt2(c.start))–\(fmt2(c.end))s)") }
            var pts: [(Double, Double)]?
            if let s = ca.optString("points") { pts = Curve.points(s) } else if let list = ca.value("points")?.array {
                let xy = list.compactMap { $0.array?.compactMap(\.double) }.filter { $0.count == 2 }
                pts = xy.count == list.count ? xy.map { ($0[0], $0[1]) } : nil
            }
            guard let pts, pts.count >= 3 else { throw EditError("Each correct entry is {at, points: \"x,y x,y …\"} (or [[x,y], …]) in the clip's frame") }
            guard outlines || pts.count == points.count else { throw EditError("correct at \(fmt2(t))s has \(pts.count) points; \(effectId) has \(points.count), give every point in the same order") }
            let tt = min(t, c.end - 1e-3)
            let s = c.sourceTime(atTimeline: tt)
            anchors.removeAll { abs($0.t - s) < 1e-3 }
            anchors.append(RotoTracker.Anchor(t: s, points: pts.map { toSource(SIMD2($0.0, $0.1), at: tt) }))
        }
        let corrections = anchors.count - 1
        let refine = a.optString("refine") ?? "none"
        let kind: Segmentation.Kind?
        switch refine {
        case "none": kind = nil
        case "subject": kind = .subject
        case "person": kind = .person(.balanced)
        default: throw EditError("refine is subject, person or none")
        }
        let snapReach = a.optDouble("snap") ?? 0.03
        var keys: [RotoTracker.Key]
        var notes: [String] = []
        if let t = a.optString("track") {
            guard !outlines, corrections == 0 else { throw EditError("track drives planar or translate tracking; leave it out for mode \(modeName) or corrections") }
            let id = t.hasPrefix("track:") ? String(t.dropFirst(6)) : t
            guard let track = (b.analysis([ObjectTrack].self, mid, "tracks") ?? []).first(where: { $0.id == id }) else { throw EditError("No track \(id) in \(mid); create one with media_track") }
            let samples = track.samples.filter { $0.confidence >= ObjectTrack.lostConfidence }
            guard let ref = samples.min(by: { abs($0.t - src) < abs($1.t - src) }) else { throw EditError("\(id) has no confident samples") }
            if let cs = ref.corners, cs.count == 8, mode != .translate {
                keys = RotoTracker.carried(points, quad: (0..<4).map { SIMD2(cs[2 * $0], cs[2 * $0 + 1]) }, samples: samples)
                notes.append("Following surface track \(id).")
            } else {
                keys = RotoTracker.translated(points, box: ref.box, samples: samples)
                notes.append("Moving with \(id)'s box.")
            }
        } else {
            let cuts = b.visualAnalysis(mid)?.sceneCuts ?? []
            let fps = min(30, max(10, m.fps))
            let size = a.optDouble("size") ?? 0.08
            func run(_ from: Seconds, _ to: Seconds, _ pts: [SIMD2<Double>]) async throws -> RotoTracker.Result? {
                if !outlines && abs(to - from) <= 0.02 { return nil }
                return try await RotoTracker.track(media: m.url, from: from, to: to, points: pts, mode: mode, quad: from == src ? quad : nil, pointSize: size, fps: fps, cuts: cuts,
                                                   refine: mode == .points ? kind : nil, snap: snapReach, count: count)
            }
            let tracked = try await RotoTracker.anchored(anchors, lo: lo, hi: hi, blend: !outlines, run: run)
            keys = tracked.keys
            if corrections > 0, !outlines {
                // Away from the corrections the track from at stands; each correction's re-anchored track takes over
                // around it.
                let main = try await RotoTracker.anchored([anchors[0]], lo: lo, hi: hi, run: run)
                keys = RotoTracker.blended(base: main.keys, overlay: keys, near: anchors.dropFirst().map(\.t), radius: Toolbox.correctionReach)
            }
            var stops: [String] = []
            for cut in tracked.cuts.sorted(by: { $0.time < $1.time }) where !stops.contains(Toolbox.cutNote(cut)) { stops.append(Toolbox.cutNote(cut)) }
            if !stops.isEmpty { notes.append("Tracking stopped at " + stops.joined(separator: " and ") + "; the shape holds its last position beyond.") }
            if corrections > 0 { notes.append(outlines ? "\(corrections) correction(s) pick the \(modeName) region from their frames on." : "\(corrections) correction(s): re-tracked from each both ways and blended into the track within \(fmt1(Toolbox.correctionReach))s of it, so the shape is exact there.") }
        }
        guard !keys.isEmpty else { throw EditError("The tracker found nothing to follow; try mode points or translate, or a larger shape") }
        if outlines, !keys.contains(where: { $0.confidence > 0 }) { throw EditError("No \(modeName) found in \(clipId)'s frames; draw a mask.shape and use mode points instead") }
        let lost = keys.filter { $0.confidence < ObjectTrack.lostConfidence }
        if !lost.isEmpty { notes.append((outlines ? "No \(modeName) outline" : "Low confidence") + " at \(lost.count) of \(keys.count) samples (\(fmt2(lost.first!.t))–\(fmt2(lost.last!.t))s source); check those frames" + (outlines ? "." : " and add correct:[{at, points}] keys there.")) }
        if let kind, !outlines {
            if mode == .points {
                notes.append("Every frame's shape was snapped to the \(refine) matte's edge before tracking on.")
            } else {
                let snapped = try await RotoTracker.snapped(keys, media: m.url, kind: kind, radius: snapReach, aspect: aspect)
                keys = snapped.keys
                notes.append("Snapped \(snapped.moved) of \(keys.count * points.count) point positions to the \(refine) matte's edge.")
            }
        } else if outlines, refine != "none" {
            notes.append("refine is ignored: the shape is the \(modeName) outline already.")
        }
        let all = keys.count
        keys = RotoTracker.thinned(keys)
        let curveKeys = keys.compactMap { k -> CurveKey? in
            let t = c.timelineTime(atSource: k.t) - c.start
            guard t >= -0.5, t <= c.duration + 0.5 else { return nil }
            let text = k.points.map { p in let q = toClip(p); return String(format: "%.5f,%.5f", q.x, q.y) }.joined(separator: " ")
            return CurveKey(t: t, v: .string(text), ease: .linear)
        }
        guard !curveKeys.isEmpty else { throw EditError("No tracked samples fall inside \(clipId)") }
        let span = keys.map { c.timelineTime(atSource: $0.t) }
        let label = "Track \(effectId) on \(Toolbox.clipName(clipId, current))"
        let what = outlines ? "outlines the \(modeName) (\(count) points)" : "follows the footage (\(modeName)\(kind != nil ? " + \(refine) edges" : ""))"
        let summary = "\(clipId): \(path) \(what), \(curveKeys.count) keyframes from \(all) tracked samples over \(fmt2(span.min()!))–\(fmt2(span.max()!))s. " + notes.joined(separator: " ") + " Check the matte with timeline_frames {view: \"matte\", clip: \"\(clipId)\", effect: \"\(effectId)\"}; fix a frame with correct:[{at, points}]."
        return try runEdit(label, dry: dry) { p in
            guard let loc = p.locateClip(clipId) else { throw EditError("No clip \(clipId)") }
            if !p.tracks[loc.track].clips[loc.clip].effects.contains(where: { $0.id == effectId }) {
                p.tracks[loc.track].clips[loc.clip].effects.append(Effect(id: effectId, type: "mask.shape", params: ["points": curveKeys[0].v]))
            }
            p.tracks[loc.track].clips[loc.clip].anim[path] = Curve(keys: curveKeys)
            return summary
        }
    }
}
