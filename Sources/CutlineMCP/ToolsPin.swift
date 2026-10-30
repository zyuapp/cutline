import CutlineCore
import Foundation

extension Toolbox {
    /// Corner-pins `clipId` onto a surface track: the clip is stretched to the frame and its corners follow the track's
    /// corners wherever the tracked media plays under it.
    static func pin(_ p: inout Project, clipId: String, corners samples: [TrackSample], mediaId: String) throws -> String {
        guard let loc = p.locateClip(clipId) else { throw EditError("No clip \(clipId)") }
        guard let m = p.mediaAsset(mediaId) else { throw EditError("No media \(mediaId)") }
        var c = p.tracks[loc.track].clips[loc.clip]
        let names = ["tl", "tr", "br", "bl"]
        var keys: [String: [CurveKey]] = [:]
        for s in samples where s.confidence >= ObjectTrack.lostConfidence {
            guard let q = s.corners, q.count == 8 else { continue }
            for host in p.tracks.flatMap(\.clips) where host.kind == .media && host.mediaId == mediaId && s.t >= min(host.sourceIn, host.sourceOut) - 1e-6 && s.t <= max(host.sourceIn, host.sourceOut) + 1e-6 {
                let t = host.timelineTime(atSource: s.t)
                guard t >= c.start - 1e-6, t <= c.end + 1e-6 else { continue }
                for k in 0..<4 {
                    let r = Toolbox.canvasRect(NormRect(x: q[2 * k], y: q[2 * k + 1], width: 0, height: 0), in: host, media: m, canvas: p.canvas, at: t - host.start)
                    keys["fx.pin.\(names[k])_x", default: []].append(CurveKey(t: t - c.start, v: .number(r.midX), ease: .linear))
                    keys["fx.pin.\(names[k])_y", default: []].append(CurveKey(t: t - c.start, v: .number(r.midY), ease: .linear))
                }
            }
        }
        guard let first = keys["fx.pin.tl_x"], first.count >= 2 else { throw EditError("The track's corners never play under \(clipId); place it over the tracked shot") }
        c.transform.fit = .stretch
        c.transform.scale = 1
        c.transform.x = 0
        c.transform.y = 0
        c.effects.removeAll { $0.id == "pin" }
        c.effects.insert(Effect(id: "pin", type: "distort.corner_pin"), at: 0)
        for (path, list) in keys { c.anim[path] = Curve(keys: list) }
        p.tracks[loc.track].clips[loc.clip] = c
        return "\(clipId) is corner-pinned to the tracked surface (\(first.count) keyframes per corner, effect id pin)"
    }
}
