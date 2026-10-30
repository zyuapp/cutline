import CoreGraphics
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    /// recipe safe_zone_fix: moves (and if needed shrinks) every title and text graphic that pokes out of a platform's
    /// UI-free area back inside it, and keeps captions inside it too.
    func safeZoneFixRecipe(_ a: Args, dry: Bool) throws -> ToolResult {
        let current = try session.project()
        let platform = try a.optString("platform").map { id -> Platform in
            guard let pl = Platform.named(id) else { throw EditError("Unknown platform \(id). Platforms: \(Platform.all.map(\.id).joined(separator: ", "))") }
            return pl
        }
        guard let area = platform.map({ ("\($0.name)'s UI-free area", $0.safe) }) ?? current.captionSafeArea else {
            throw EditError("Pass platform (\(Platform.all.map(\.id).joined(separator: ", "))): the canvas isn't 9:16 and captions name no platform")
        }
        let only = a.strings("clips").map(Set.init)
        let margin = a.optDouble("margin") ?? 0.01
        let inner = area.1.insetBy(dx: margin, dy: margin)
        var moves: [(id: String, dx: Double, dy: Double, scale: Double)] = []
        for (clip, _, time, box) in PictureMeter.textBoxes(current) {
            guard let clip, only?.contains(clip) ?? true, let c = current.clip(clip) else { continue }
            let outside = max(0, area.1.minX - box.minX, box.maxX - area.1.maxX, area.1.minY - box.minY, box.maxY - area.1.maxY)
            guard outside > 0.001 else { continue }
            let f = min(1, inner.width / box.width, inner.height / box.height)
            // Text scales about its center; a graphic about the frame center moved by its transform.
            let xf = c.resolvedTransform(at: time - c.start)
            let pivot = c.kind == .text ? CGPoint(x: box.midX, y: box.midY) : CGPoint(x: 0.5 + xf.x, y: 0.5 + xf.y)
            let scaled = CGRect(x: pivot.x + (box.minX - pivot.x) * f, y: pivot.y + (box.minY - pivot.y) * f, width: box.width * f, height: box.height * f)
            func shift(_ lo: CGFloat, _ hi: CGFloat, _ min: CGFloat, _ max: CGFloat) -> Double { Double(lo < min ? min - lo : hi > max ? max - hi : 0) }
            moves.append((clip, shift(scaled.minX, scaled.maxX, inner.minX, inner.maxX), shift(scaled.minY, scaled.maxY, inner.minY, inner.maxY), Double(f)))
        }
        let fixCaptions = current.captions.enabled && current.captions.platform != "none" && platform != nil && current.captions.platform != platform?.id
        guard !moves.isEmpty || fixCaptions else { return .text("Every title and graphic already sits inside \(area.0); nothing to move.") }
        return try runEdit("Move text inside \(platform?.name ?? "the safe area")", dry: dry) { p in
            var lines: [String] = []
            for m in moves {
                guard let loc = p.locateClip(m.id) else { continue }
                var c = p.tracks[loc.track].clips[loc.clip]
                let text = c.kind == .text
                try Toolbox.offset(&c, text ? "text.x" : "transform.x", by: m.dx)
                try Toolbox.offset(&c, text ? "text.y" : "transform.y", by: m.dy)
                if m.scale < 0.999 { try Toolbox.offset(&c, text ? "text.size" : "transform.scale", times: m.scale) }
                p.tracks[loc.track].clips[loc.clip] = c
                lines.append("\(m.id): moved \(fmt2(m.dx)), \(fmt2(m.dy))" + (m.scale < 0.999 ? ", scaled ×\(fmt2(m.scale)) to fit" : ""))
            }
            if fixCaptions, let platform {
                p.captions.platform = platform.id
                lines.append("captions kept inside it (y \(fmt2(p.captionStyle.y)), max_width \(fmt2(p.captionStyle.maxWidth)))")
            }
            return "Inside \(area.0): " + lines.joined(separator: "; ") + ". Check with timeline_measure what:[\"text\"]" + (platform.map { " platform:\"\($0.id)\"" } ?? "") + "."
        }
    }

    /// Adds `by` to (or multiplies by `times`) a numeric parameter's value and every key of its animation.
    static func offset(_ c: inout Clip, _ path: String, by: Double = 0, times: Double = 1) throws {
        guard by != 0 || times != 1 else { return }
        func f(_ v: ParamValue) -> ParamValue { v.number.map { .number($0 * times + by) } ?? v }
        if let v = c.staticValue(path) { try c.set(path, f(v)) }
        if var curve = c.anim[path] {
            curve.keys = curve.keys.map { var k = $0; k.v = f(k.v); return k }
            c.anim[path] = curve
        }
    }
}
