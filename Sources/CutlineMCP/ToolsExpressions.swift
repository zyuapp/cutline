import CutlineCore
import Foundation

extension Toolbox {
    static let expressionDocs = """
         Procedural sources (live, layered on the path's keys or value): \
        {"source": "wiggle", "freq": 2, "amp": 0.02, "octaves": 1, "seed": 7} adds smooth random motion of ±amp (in the parameter's units) freq times a second — camera shake, handheld drift, flicker; \
        {"source": "time", "rate": 90} adds rate per second since the clip start (AE time*k: spin 90°/s, drift, counters); \
        {"source": "loop", "mode": "cycle"|"pingpong"|"none"} repeats the path's keys after the last one; \
        {"source": "link:<clip id>.<path>", "scale": 1, "offset": 0, "delay": 0} follows another clip's parameter (value × scale + offset, delay seconds later on the timeline), kept in sync after every edit — chain links with growing delays for follow-through. \
        Any animate on the path replaces its expression; bind the expression after animating.
        """

    /// Example calls for a generator's catalog entry.
    static func generatorExample(_ t: EffectType) -> [String] {
        switch t.id {
        case "shape":
            return [
                ##"Example: clip_add {"generator": "shape", "track": "new", "duration": 4, "params": {"shapes": [{"id": "ring", "type": "ellipse", "width": 0.3, "height": 0.3, "fill": "none", "stroke": "#FFD60A", "stroke_width": 0.015, "trim_end": 0}, {"id": "tick", "type": "path", "d": "M -0.06 0 L -0.015 0.045 L 0.07 -0.05", "stroke": "#FFFFFF", "stroke_width": 0.02, "trim_end": 0}]}}"##,
                #"Animate: param_set {"target": "<clip>", "relative": true, "animate": {"fx.gen.ring.trim_end": [[0, 0], [0.8, 1, "easeOut"]], "fx.gen.tick.trim_end": [[0.6, 0], [1.0, 1, "easeOut"]]}}"#,
                "Gradient fill: \"fill\": {\"gradient\": \"linear\", \"colors\": [\"#FF375F\", \"#FFD60A\"], \"angle\": 90}. Icons: \"d\" from a 24×24 SVG with \"view_box\": [0, 0, 24, 24] and width/height. Morph: \"d\" and \"d_to\" with matching segments, animate fx.gen.<id>.morph. Repeater: \"repeat_count\": 12, \"repeat_rotation\": 30.",
            ]
        case "camera":
            return [
                #"Example: param_set {"target": ["<title clip>", "<shape clip>"], "set": {"transform.3d": true}} then param_set {"target": "<title>", "set": {"transform.z": 1.5}} to push one layer back."#,
                #"Camera: clip_add {"generator": "camera", "track": "new", "start": 0, "duration": 6} then param_set {"target": "<camera clip>", "relative": true, "animate": {"fx.gen.orbit": [[0, -25], [6, 25, "easeInOut"]], "fx.gen.distance": [[0, 2.2], [6, 1.4, "easeInOut"]]}}"#,
            ]
        default:
            let first = t.params.prefix(2).map { "\"\($0.name)\": \($0.defaultValue)" }.joined(separator: ", ")
            var lines = ["Example: clip_add {\"generator\": \"\(t.id)\", \"track\": \"new\", \"duration\": 5, \"params\": {\(first)}}"]
            if let p = t.params.first(where: { $0.animatable }) {
                lines.append("Animate: param_set {\"target\": \"<clip>\", \"animate\": {\"fx.gen.\(p.name)\": [[\"<clip>.start\", \(p.defaultValue)], [\"<clip>.end\", …]]}}")
            }
            if t.id.hasPrefix("title.") { lines.append("Builds on over `in` seconds and off over `out` seconds by itself; set in/out to 0 to animate it yourself.") }
            return lines
        }
    }

    /// Applies a procedural source to one clip path; nil when `source` is an analysis source.
    func applyExpression(_ source: String, path: String, clip c: inout Clip, project p: Project, args a: Args) throws -> String? {
        let canonical = Clip.canonical(path)
        switch source {
        case "wiggle":
            let freq = a.optDouble("freq") ?? a.optDouble("frequency") ?? 2
            guard let amp = a.optDouble("amp") ?? a.optDouble("amplitude") else { throw EditError("wiggle needs amp, the size of the motion in \(canonical)'s units") }
            let seed = a.optInt("seed").map { StableRandom.mix(UInt64(max(0, $0))) }
            try c.wiggle(canonical, freq: freq, amp: amp, octaves: a.optInt("octaves") ?? 1, seed: seed)
        case "time":
            guard let rate = a.optDouble("rate") ?? a.optDouble("k") else { throw EditError("time needs rate: how much \(canonical) changes per second") }
            try c.addRate(canonical, rate: rate)
        case "loop":
            let mode = a.optString("mode") ?? "cycle"
            guard mode == "none" || CurveExpression.Loop(rawValue: mode) != nil else { throw EditError("loop mode is cycle, pingpong or none") }
            try c.loop(canonical, CurveExpression.Loop(rawValue: mode))
        default:
            guard source.hasPrefix("link:") else { return nil }
            let target = String(source.dropFirst(5))
            guard let dot = target.firstIndex(of: "."), dot != target.startIndex else { throw EditError("link sources look like link:<clip id>.<path>, e.g. link:clip_ab12cd.transform.rotation") }
            let link = CurveLink(clip: String(target[..<dot]), path: String(target[target.index(after: dot)...]), scale: a.optDouble("scale") ?? 1, offset: a.optDouble("offset") ?? 0, delay: a.optDouble("delay") ?? 0)
            try p.link(&c, path: canonical, to: link)
            let keys = c.anim[canonical]?.keys.count ?? 0
            return "\(canonical) follows \(link.clip).\(Clip.canonical(link.path))" + (link.scale != 1 ? " × \(fmt2(link.scale))" : "") + (link.offset != 0 ? " + \(fmt2(link.offset))" : "") + (link.delay != 0 ? ", \(fmt2(link.delay))s later" : "") + " (\(keys) keys, kept in sync)"
        }
        let summary = c.anim[canonical]?.expression?.summary ?? ""
        return "\(canonical): " + (summary.isEmpty ? "expression removed" : summary)
    }
}
