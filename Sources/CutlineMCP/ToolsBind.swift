import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    static let bindDocs = """
        Drive parameters from analysis; written as ordinary animation keys you can inspect and edit. {path: {source, map: [in_lo, in_hi, out_lo, out_hi], smooth: seconds, offset, decay}}. \
        Sources: "beats" / "downbeats" (pulses out_hi on each beat of the timeline's music, decaying to out_lo over decay=0.25s), \
        "audio:<media id>" (loudness where that media plays; map dB, default [-40, 0, out_lo, out_hi]), \
        "face:<media id>[:n].x|y|size" and "track:<track id>.x|y|width|height" (a face or tracked object, in canvas fractions where the media plays; \
        for transform.x/y the value is the offset from center, for anything else (text.x/y, effect centers) the absolute position; add offset to place beside it). \
        On the clip that plays the media, fx.<id>.* paths (limit_x/limit_y, limit_width/limit_height, center_x/center_y) get the position and size inside that clip's own picture, which is what its effects use, so a window follows the subject even when the picture is letterboxed, cropped or scaled: \
        {"fx.skin1.limit_x": {"source": "face:<media>.x"}, "fx.skin1.limit_y": {"source": "face:<media>.y"}, "fx.skin1.limit_height": {"source": "face:<media>.size", "offset": 0.05}}. \
        Example: {"transform.scale": {"source": "beats", "map": [0, 1, 1, 1.06]}} pumps scale on every beat. \
        To reframe a clip on a face or object in its own picture, add "keep_centered": true on transform.x/y: the picture pans so the subject stays centered (clamped so the frame stays covered).
        """ + expressionDocs

    func applyBindings(_ p: inout Project, targets: [Target], _ bind: [String: JSON]) throws -> String {
        let b = try session.requireBundle()
        var lines: [String] = []
        for target in targets {
            guard case .clip(let id) = target, let loc = p.locateClip(id) else { throw EditError("bind works on clips") }
            var c = p.tracks[loc.track].clips[loc.clip]
            for (path, spec) in bind.sorted(by: { $0.key < $1.key }) {
                let a = Args(spec)
                let source = try a.string("source")
                if let line = try applyExpression(source, path: path, clip: &c, project: p, args: a) {
                    lines.append("\(id): \(line)")
                    continue
                }
                let curve = try bindingCurve(source, path: Clip.canonical(path), clip: c, project: p, bundle: b, args: a)
                guard curve.keys.count >= 1 else { throw EditError("\(source) has no data over \(id) (\(fmt2(c.start))–\(fmt2(c.end))s)") }
                try c.animate(path, keys: curve.keys)
                lines.append("\(id): \(Clip.canonical(path)) follows \(source) (\(curve.keys.count) keys)")
            }
            p.tracks[loc.track].clips[loc.clip] = c
        }
        return lines.joined(separator: "\n")
    }

    func bindingCurve(_ source: String, path: String, clip c: Clip, project p: Project, bundle b: ProjectBundle, args a: Args) throws -> Curve {
        let map = a.raw["map"]?.array?.compactMap(\.double)
        let smooth = a.optDouble("smooth") ?? 0
        let offset = a.optDouble("offset") ?? 0
        func mapped(_ v: Double, _ dflt: [Double]) -> Double {
            let m = (map?.count == 4 ? map! : dflt)
            let u = m[1] != m[0] ? (v - m[0]) / (m[1] - m[0]) : 0
            return m[2] + (m[3] - m[2]) * min(1, max(0, u)) + offset
        }
        if source == "beats" || source == "downbeats" {
            let beats = p.timelineBeats(b.anchorIndex(for: p), downbeats: source == "downbeats").filter { $0 >= c.start - 0.01 && $0 < c.end }
            guard !beats.isEmpty else { throw EditError("No analyzed music beats over this clip") }
            let decay = a.optDouble("decay") ?? 0.25
            let lo = mapped(0, [0, 1, 0, 1]), hi = mapped(1, [0, 1, 0, 1])
            var keys = [CurveKey(t: 0, v: .number(lo), ease: .linear)]
            for t in beats {
                let local = t - c.start
                if let last = keys.last, local - last.t < 0.02 { continue }
                if local > 0.02 { keys.append(CurveKey(t: local - 0.01, v: .number(lo), ease: .linear)) }
                keys.append(CurveKey(t: max(0, local), v: .number(hi), ease: .easeOut))
                keys.append(CurveKey(t: local + decay, v: .number(lo), ease: .easeOut))
            }
            return Curve(keys: keys.sorted { $0.t < $1.t })
        }
        // Sampled sources: evaluate at 15 Hz over the clip, smooth, then thin to keys.
        let rate = 15.0
        let times = stride(from: 0.0, through: c.duration, by: 1 / rate).map { $0 }
        var values: [Double?] = []
        if source.hasPrefix("audio:") {
            let mid = String(source.dropFirst(6))
            guard let levels = b.audioAnalysis(mid) else { throw EditError("No audio analysis for \(mid)") }
            values = times.map { local in
                let t = c.start + local
                guard let host = p.tracks.flatMap(\.clips).first(where: { $0.mediaId == mid && t >= $0.start && t < $0.end }) else { return nil }
                let i = Int(host.sourceTime(atTimeline: t) * levels.levelRate)
                guard levels.levels.indices.contains(i) else { return nil }
                return mapped(Double(levels.levels[i]), [-40, 0, 0, 1])
            }
        } else if source.hasPrefix("face:") || source.hasPrefix("track:") {
            let (base, field) = Toolbox.splitField(source)
            let samples: [(t: Seconds, box: NormRect)]
            let mediaId: String
            if base.hasPrefix("face:") {
                let parts = base.dropFirst(5).split(separator: ":").map(String.init)
                mediaId = parts[0]
                guard let shots = b.analysis(ShotAnalysis.self, mediaId, "shots") else { throw EditError("No shot analysis for \(mediaId); run media_analyze features:[\"shots\"]") }
                let index = parts.count > 1 ? Int(parts[1]) : nil
                let track = index.flatMap { i in shots.faces.first { $0.id == i } } ?? shots.faces.max { $0.samples.count < $1.samples.count }
                guard let track else { throw EditError("\(mediaId) has no tracked faces") }
                samples = track.samples.map { ($0.t, $0.box) }
            } else {
                let tid = String(base.dropFirst(6))
                guard let found = Toolbox.objectTrack(tid, b, p) else { throw EditError("No tracked object \(tid); create one with media_track") }
                mediaId = found.mediaId
                samples = found.samples
            }
            guard let m = p.mediaAsset(mediaId) else { throw EditError("No media \(mediaId)") }
            let absolute = !path.hasPrefix("transform.")
            let centering = a.bool("keep_centered", default: false) && (path == "transform.x" || path == "transform.y")
            values = times.map { local in
                let t = c.start + local
                guard let host = p.tracks.flatMap(\.clips).first(where: { $0.mediaId == mediaId && $0.kind == .media && t >= $0.start && t < $0.end }) else { return nil }
                let s = host.sourceTime(atTimeline: t)
                guard let near = samples.min(by: { abs($0.t - s) < abs($1.t - s) }), abs(near.t - s) < 0.75 else { return nil }
                if centering, host.id == c.id {
                    // Pan the clip's own picture: with no offset the subject sits at `r`; shift by the distance to center.
                    var still = host
                    still.anim["transform.x"] = nil
                    still.anim["transform.y"] = nil
                    still.transform.x = 0
                    still.transform.y = 0
                    let r0 = Toolbox.canvasRect(near.box, in: still, media: m, canvas: p.canvas, at: local + c.start - host.start)
                    let xf = still.resolvedTransform(at: local)
                    let cw = Double(p.canvas.width), ch = Double(p.canvas.height)
                    let pw = (xf.fit == .fill ? max(cw / Double(m.width), ch / Double(m.height)) : min(cw / Double(m.width), ch / Double(m.height))) * Double(m.width) * xf.scale / cw
                    let ph = (xf.fit == .fill ? max(cw / Double(m.width), ch / Double(m.height)) : min(cw / Double(m.width), ch / Double(m.height))) * Double(m.height) * xf.scale / ch
                    let room = field == "y" ? max(0, (ph - 1) / 2) : max(0, (pw - 1) / 2)
                    let shift = field == "y" ? 0.5 - r0.midY : 0.5 - r0.midX
                    return min(room, max(-room, shift)) + offset
                }
                if path.hasPrefix("fx."), host.id == c.id {
                    // The clip's own effects work in fractions of its cropped picture, not of the canvas.
                    let crop = host.resolvedTransform(at: local).crop
                    let cw = max(0.0001, 1 - crop.left - crop.right), ch = max(0.0001, 1 - crop.top - crop.bottom)
                    let v: Double = switch field {
                    case "y": (near.box.midY - crop.top) / ch
                    case "width": near.box.width / cw
                    case "height", "size": near.box.height / ch
                    default: (near.box.midX - crop.left) / cw
                    }
                    return v + offset
                }
                let r = Toolbox.canvasRect(near.box, in: host, media: m, canvas: p.canvas, at: local + c.start - host.start)
                let v: Double = switch field {
                case "y": absolute ? r.midY : r.midY - 0.5
                case "width": r.width
                case "height", "size": r.height
                default: absolute ? r.midX : r.midX - 0.5
                }
                return v + offset
            }
        } else {
            throw EditError("Unknown bind source \(source). Sources: beats, downbeats, audio:<media>, face:<media>[:n].x|y|size, track:<id>.x|y|width|height, wiggle, time, loop, link:<clip>.<path>")
        }
        var filled = values
        if smooth > 0 {
            let w = max(1, Int(smooth * rate))
            filled = values.indices.map { i in
                let window = values[max(0, i - w)...min(values.count - 1, i + w)].compactMap { $0 }
                return values[i] == nil || window.isEmpty ? values[i] : window.reduce(0, +) / Double(window.count)
            }
        }
        var keys: [CurveKey] = []
        for (t, v) in zip(times, filled) {
            guard let v else { continue }
            if keys.count >= 2, let last = keys.last, abs(last.v.number! - v) < 0.002 { continue }
            keys.append(CurveKey(t: t, v: .number(v), ease: .linear))
        }
        return Curve(keys: keys)
    }

    static func splitField(_ s: String) -> (String, String) {
        for f in [".x", ".y", ".width", ".height", ".size"] where s.hasSuffix(f) { return (String(s.dropLast(f.count)), String(f.dropFirst())) }
        return (s, "x")
    }

    static func objectTrack(_ id: String, _ b: ProjectBundle, _ p: Project) -> (mediaId: String, samples: [(t: Seconds, box: NormRect)])? {
        for m in p.media {
            if let t = (b.analysis([ObjectTrack].self, m.id, "tracks") ?? []).first(where: { $0.id == id }) {
                return (t.mediaId, t.samples.filter { $0.confidence >= ObjectTrack.lostConfidence }.map { ($0.t, $0.box) })
            }
        }
        return nil
    }

    /// Where a box in a clip's source frame lands on the canvas, in canvas fractions (top-left origin).
    static func canvasRect(_ box: NormRect, in c: Clip, media m: MediaAsset, canvas: Canvas, at local: Seconds) -> NormRect {
        let xf = c.resolvedTransform(at: local)
        let cw = Double(canvas.width), ch = Double(canvas.height)
        let sw = Double(m.width) * max(0.0001, 1 - xf.crop.left - xf.crop.right), sh = Double(m.height) * max(0.0001, 1 - xf.crop.top - xf.crop.bottom)
        let fitScale: Double = switch xf.fit {
        case .fit: min(cw / sw, ch / sh)
        case .fill: max(cw / sw, ch / sh)
        case .stretch: 1
        }
        let w = (xf.fit == .stretch ? cw : sw * fitScale) * xf.scale / cw
        let h = (xf.fit == .stretch ? ch : sh * fitScale) * xf.scale / ch
        let bx = (box.midX - xf.crop.left) / max(0.0001, 1 - xf.crop.left - xf.crop.right)
        let by = (box.midY - xf.crop.top) / max(0.0001, 1 - xf.crop.top - xf.crop.bottom)
        let cx = 0.5 + xf.x + (bx - 0.5) * w
        let cy = 0.5 + xf.y + (by - 0.5) * h
        return NormRect(x: cx - box.width * w / 2, y: cy - box.height * h / 2, width: box.width * w, height: box.height * h)
    }
}
