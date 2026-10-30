import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    func registerTrackTool() {
        add(Tool(name: "media_track", description: "Follow an object through a media file so graphics, text, blurs or masks can stick to it. Give the object's box at a source time (fractions of the frame, top-left origin; media_frames overlay shows faces and subjects) or face:<n> from shot analysis. Tracks until end (default: the end of that shot). The result is a track id usable as bind source track:<id>.x|y|width|height in param_set, or with recipe follow. list:true shows existing tracks.", schema: Schema.object([
            "media_id": Schema.string("Media to track in"),
            "at": Schema.time("Source time where the box is given"),
            "box": ["type": "object", "description": "{x, y, width, height} as fractions of the frame, top-left origin"],
            "face": Schema.integer("Use this face track's box at the given time instead of box"),
            "corners": ["type": "array", "items": ["type": "array", "items": ["type": "number"]], "description": "Track a flat surface (screen, sign, wall) instead of a box: its four corners [[x,y] top-left, top-right, bottom-right, bottom-left] at `at`, as frame fractions. recipe follow then corner-pins a clip onto it, perspective included"],
            "end": Schema.time("Track until this source time (earlier than at tracks backwards)"),
            "label": Schema.string("What is being tracked, e.g. \"red car\""),
            "list": Schema.bool("List the media's tracks"),
        ], required: ["media_id"])) { [unowned self] args in
            let b = try session.requireBundle()
            let p = try session.project()
            let id = try args.string("media_id")
            guard let m = p.mediaAsset(id), m.hasVideo, !m.isImage else { throw EditError("\(id) is not a video") }
            var tracks = b.analysis([ObjectTrack].self, id, "tracks") ?? []
            if args.bool("list", default: false) {
                return .text(tracks.isEmpty ? "No tracks in \(id)." : tracks.map { Toolbox.describeTrack($0) }.joined(separator: "\n"))
            }
            let at = try args.sourceTime("at")
            if let list = args.raw["corners"]?.array {
                let pts = list.compactMap { $0.array.flatMap { xy in xy.count == 2 ? xy.compactMap(\.double) : nil } }.filter { $0.count == 2 }
                guard pts.count == 4 else { throw EditError("corners is four [x, y] pairs: top-left, top-right, bottom-right, bottom-left") }
                var end = try args.optSourceTime("end")
                if end == nil {
                    let shotEnd = b.analysis(ShotAnalysis.self, id, "shots")?.shot(at: at)?.end ?? b.visualAnalysis(id).flatMap { v in ([m.duration] + v.sceneCuts).filter { $0 > at }.min() }
                    end = min(m.duration, shotEnd ?? at + 10)
                }
                let run = try await PlanarTracker.run(media: m.url, from: at, to: end!, corners: pts.map { SIMD2($0[0], $0[1]) }, fps: min(30, m.fps), cuts: b.visualAnalysis(id)?.sceneCuts ?? [])
                let samples = run.samples
                var n = tracks.count + 1
                while tracks.contains(where: { $0.id == "trk\(n)" }) { n += 1 }
                let track = ObjectTrack(id: "trk\(n)", mediaId: id, label: args.optString("label") ?? "surface", samples: samples)
                tracks.append(track)
                try b.saveAnalysis(tracks, id, "tracks")
                return .text(Toolbox.describeTrack(track) + (run.cut.map { "\nStopped at " + Toolbox.cutNote($0) + "; track the next shot separately." } ?? "") + "\nSurface track: corner-pin a clip onto it with recipe follow {clip, target: \"track:\(track.id)\"}; its box also works as bind source track:\(track.id).x|y|width|height.")
            }
            var box: NormRect
            if let f = args.optInt("face") {
                guard let shots = b.analysis(ShotAnalysis.self, id, "shots"), let face = shots.faces.first(where: { $0.id == f }),
                      let s = face.samples.min(by: { abs($0.t - at) < abs($1.t - at) }) else { throw EditError("No face\(f) near \(fmt2(at))s in \(id); run media_analyze features:[\"shots\"]") }
                box = s.box
            } else {
                let o = args.raw["box"]?.object ?? [:]
                guard let x = o["x"]?.double, let y = o["y"]?.double, let w = o["width"]?.double, let h = o["height"]?.double, w > 0, h > 0 else { throw EditError("box is {x, y, width, height} in frame fractions") }
                box = NormRect(x: x, y: y, width: w, height: h)
            }
            var end = try args.optSourceTime("end")
            if end == nil {
                let shotEnd = b.analysis(ShotAnalysis.self, id, "shots")?.shot(at: at)?.end ?? b.visualAnalysis(id).flatMap { v in ([m.duration] + v.sceneCuts).filter { $0 > at }.min() }
                end = min(m.duration, shotEnd ?? at + 10)
            }
            let run = try await ObjectTracker.run(media: m.url, from: at, to: end!, box: box, cuts: b.visualAnalysis(id)?.sceneCuts ?? [])
            let samples = run.samples
            var n = tracks.count + 1
            while tracks.contains(where: { $0.id == "trk\(n)" }) { n += 1 }
            let track = ObjectTrack(id: "trk\(n)", mediaId: id, label: args.optString("label") ?? "object", samples: ObjectTrack.smoothed(samples, sigma: 0.1))
            tracks.append(track)
            try b.saveAnalysis(tracks, id, "tracks")
            return .text(Toolbox.describeTrack(track) + (run.cut.map { "\nStopped at " + Toolbox.cutNote($0) + "; track the next shot separately." } ?? "") + "\nUse it with recipe follow {clip, target: \"track:\(track.id)\"} or param_set bind {\"transform.x\": {\"source\": \"track:\(track.id).x\"}}.")
        })
    }

    /// "the cut at 12.34s (scene analysis)".
    static func cutNote(_ b: ShotBoundary) -> String {
        "the cut at \(fmt2(b.time))s" + (b.fromAnalysis ? " (scene analysis)" : " (detected from the frames)")
    }

    static func describeTrack(_ t: ObjectTrack) -> String {
        guard let r = t.range, let first = t.samples.first, let last = t.samples.last else { return "\(t.id) \(t.label): empty" }
        var s = "\(t.id) \"\(t.label)\" in \(t.mediaId) \(fmt2(r.start))–\(fmt2(r.end))s, \(t.samples.count) samples; moves from \(fmt2(first.box.midX)),\(fmt2(first.box.midY)) to \(fmt2(last.box.midX)),\(fmt2(last.box.midY))"
        if !t.lost.isEmpty { s += "; lost " + t.lost.map { "\(fmt2($0.start))–\(fmt2($0.end))" }.joined(separator: ", ") + " (re-track from there with a new box)" }
        return s
    }
}
