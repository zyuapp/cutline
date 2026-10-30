import CutlineCore
import CutlineEngine
import Foundation
import simd

extension Toolbox {
    /// recipe track_mask: keyframes a mask.shape's points so the shape follows a planar track, per-point tracks or
    /// its bounding box, optionally snapped to a segmentation matte's edges.
    func trackMask(_ a: Args, dry: Bool) async throws -> ToolResult {
        let b = try session.requireBundle()
        let current = try session.project()
        let clipId = try a.string("clip")
        guard let c = current.clip(clipId), c.kind == .media, let mid = c.mediaId, let m = current.mediaAsset(mid), m.hasVideo, !m.isImage else { throw EditError("\(clipId) is not a video clip") }
        let shapes = c.effects.filter { $0.type == "mask.shape" }
        guard let effectId = a.optString("effect") ?? shapes.first?.id, let fx = c.effects.first(where: { $0.id == effectId }), fx.type == "mask.shape" else {
            throw EditError("\(clipId) has no mask.shape\(a.optString("effect").map { " \($0)" } ?? ""); draw one first: effect_add {target: \"\(clipId)\", type: \"mask.shape\", params: {points: \"x,y x,y x,y …\"}}")
        }
        let modeName = a.optString("mode") ?? "planar"
        guard let mode = RotoTracker.Mode(rawValue: modeName) else { throw EditError("mode is planar, points or translate") }
        let at = min(max(try a.optTime("at") ?? c.start, c.start), c.end - 1e-3)
        let local = at - c.start
        let src = c.sourceTime(atTimeline: at)
        let path = "fx.\(effectId).points"
        let raw = c.anim[path]?.value(at: local)?.string ?? fx.params["points"]?.string ?? EffectCatalog.type("mask.shape")?.spec("points")?.defaultValue.string ?? ""
        guard let given = Curve.points(raw), given.count >= 3 else { throw EditError("\(effectId) has no points at \(fmt2(at))s") }
        // Mask points are fractions of the cropped picture; trackers work in the full source frame.
        let crop = c.resolvedTransform(at: local).crop
        let cw = max(0.0001, 1 - crop.left - crop.right), ch = max(0.0001, 1 - crop.top - crop.bottom)
        let toSource = { (p: SIMD2<Double>) in SIMD2(crop.left + p.x * cw, crop.top + p.y * ch) }
        let toClip = { (p: SIMD2<Double>) in SIMD2((p.x - crop.left) / cw, (p.y - crop.top) / ch) }
        let points = given.map { toSource(SIMD2($0.0, $0.1)) }
        let aspect = m.width > 0 && m.height > 0 ? Double(m.width) / Double(m.height) : 16.0 / 9
        let lo = max(0, min(c.sourceIn, c.sourceOut)), hi = min(m.duration, max(c.sourceIn, c.sourceOut))
        var quad: [SIMD2<Double>]?
        if let list = a.value("corners")?.array {
            let pts = list.compactMap { $0.array.flatMap { xy in xy.count == 2 ? xy.compactMap(\.double) : nil } }.filter { $0.count == 2 }
            guard pts.count == 4 else { throw EditError("corners is four [x, y] pairs: top-left, top-right, bottom-right, bottom-left") }
            quad = pts.map { toSource(SIMD2($0[0], $0[1])) }
        }
        var keys: [RotoTracker.Key]
        var notes: [String] = []
        if let t = a.optString("track") {
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
            func run(_ to: Seconds) async throws -> RotoTracker.Result? {
                abs(to - src) > 0.02 ? try await RotoTracker.track(media: m.url, from: src, to: to, points: points, mode: mode, quad: quad, pointSize: a.optDouble("size") ?? 0.08, fps: fps, cuts: cuts) : nil
            }
            let forward = try await run(hi), backward = try await run(lo)
            keys = ((backward?.keys ?? []).filter { $0.t < src - 1e-6 } + (forward?.keys ?? [RotoTracker.Key(t: src, points: points, confidence: 1)])).sorted { $0.t < $1.t }
            let stops = [backward?.cut, forward?.cut].compactMap { $0 }.map { Toolbox.cutNote($0) }
            if !stops.isEmpty { notes.append("Tracking stopped at " + stops.joined(separator: " and ") + "; the shape holds its last position beyond.") }
        }
        guard !keys.isEmpty else { throw EditError("The tracker found nothing to follow; try mode points or translate, or a larger shape") }
        let lost = keys.filter { $0.confidence < ObjectTrack.lostConfidence }
        if !lost.isEmpty { notes.append("Low confidence at \(lost.count) of \(keys.count) samples (\(fmt2(lost.first!.t))–\(fmt2(lost.last!.t))s source); check those frames.") }
        let refine = a.optString("refine") ?? "none"
        if refine != "none" {
            let kind: Segmentation.Kind
            switch refine {
            case "subject": kind = .subject
            case "person": kind = .person(.balanced)
            default: throw EditError("refine is subject, person or none")
            }
            let snapped = try await RotoTracker.snapped(keys, media: m.url, kind: kind, radius: a.optDouble("snap") ?? 0.02, aspect: aspect)
            keys = snapped.keys
            let total = keys.count * points.count
            notes.append("Snapped \(snapped.moved) of \(total) point positions to the \(refine) matte's edge.")
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
        let summary = "\(clipId): \(path) follows the footage (\(modeName)\(refine != "none" ? " + \(refine) edges" : "")), \(curveKeys.count) keyframes from \(all) tracked samples over \(fmt2(span.min()!))–\(fmt2(span.max()!))s. " + notes.joined(separator: " ") + " Check the matte with timeline_frames {view: \"matte\", clip: \"\(clipId)\", effect: \"\(effectId)\"}."
        return try runEdit(label, dry: dry) { p in
            guard let loc = p.locateClip(clipId) else { throw EditError("No clip \(clipId)") }
            p.tracks[loc.track].clips[loc.clip].anim[path] = Curve(keys: curveKeys)
            return summary
        }
    }
}
