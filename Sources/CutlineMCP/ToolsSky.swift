import CoreGraphics
import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    /// recipe sky_replace: keys the clip's sky with mask.sky, puts the replacement on a new track under it and moves
    /// the foreground's highlights toward the new sky's horizon light.
    func skyReplaceRecipe(_ a: Args, dry: Bool) async throws -> ToolResult {
        var current = try session.project()
        let clipId = try a.string("clip")
        guard let c = current.clip(clipId), c.kind == .media, let m = c.mediaId.flatMap({ current.mediaAsset($0) }), m.hasVideo else { throw EditError("clip must be a media clip with a picture") }
        var skyId = a.optString("media")
        if skyId == nil, let image = a.optString("image") {
            let path = session.resolve(image).path
            guard FileManager.default.fileExists(atPath: path) else { throw EditError("No file \(path)") }
            if current.media.first(where: { $0.path == path }) == nil, !dry {
                _ = try await importMedia([path], args: Args(raw: ["analyze": .bool(false)]))
                current = try session.project()
            }
            skyId = current.media.first { $0.path == path }?.id
            if skyId == nil { return .text("Would import \(path) as the new sky and key \(clipId)'s sky over it (dry run).") }
        }
        guard let skyId, let sky = current.mediaAsset(skyId), sky.hasVideo else { throw EditError("Pass media (a media id of the new sky: a still or a clip) or image (a file)") }
        let settings = SkyMask.Settings(sensitivity: a.optDouble("sensitivity") ?? 0.5)
        let at = try a.optTime("at") ?? (c.start + c.duration / 2)
        let source = m.isImage ? 0 : c.sourceTime(atTimeline: min(max(at, c.start), c.end - 0.01))
        guard let frame = try await Frames.media(m, times: [source], maxSize: CGSize(width: 960, height: 960)).first?.image else { throw EditError("Cannot read a frame of \(m.id)") }
        let measured = SkyMask.measure(frame, settings: settings)
        guard let oldSky = measured.sky, measured.coverage > 0.02 else {
            throw EditError("No sky found in \(clipId) at \(fmt2(at))s (mask.sky finds bright, smooth blue, gray or sunset sky touching the top of the frame). Try another at, sensitivity 0.7–0.9, or mask the sky by hand with mask.shape")
        }
        let skyFrame = try await Frames.media(sky, times: [0], maxSize: CGSize(width: 640, height: 640)).first?.image
        let horizon = skyFrame.flatMap(SkyMask.horizon) ?? oldSky
        let blend = min(max(a.optDouble("blend") ?? 0.5, 0), 1)
        let gains = SkyMatch.gains(oldSky: oldSky, newHorizon: horizon, blend: blend)
        let feather = a.optDouble("feather") ?? 0.004
        return try runEdit("Replace the sky of \(Toolbox.clipName(clipId, current))", dry: dry) { p in
            guard let loc = p.locateClip(clipId) else { throw EditError("No clip \(clipId)") }
            var clip = p.tracks[loc.track].clips[loc.clip]
            let maskId = clip.effects.first { $0.type == "mask.sky" }?.id ?? clip.nextEffectId("mask.sky")
            clip.effects.removeAll { $0.id == maskId }
            clip.effects.insert(Effect(id: maskId, type: "mask.sky", params: ["invert": .bool(true), "feather": .number(feather), "sensitivity": .number(settings.sensitivity)]), at: 0)
            var lines: [String] = []
            if blend > 0.001 {
                let matchId = clip.effects.first { $0.type == "color.wheels" && $0.id.hasPrefix("skylight") }?.id ?? "skylight"
                clip.effects.removeAll { $0.id == matchId }
                clip.effects.append(Effect(id: matchId, type: "color.wheels", params: gains.mapValues { .number($0) }))
                lines.append("Foreground relit toward the new horizon with \(matchId) (color.wheels " + gains.sorted { $0.key < $1.key }.map { "\($0.key) \(fmt2($0.value))" }.joined(separator: ", ") + ", blend \(fmt2(blend))).")
            }
            p.tracks[loc.track].clips[loc.clip] = clip
            let track = p.addTrack(kind: .video, name: "Sky", index: loc.track)
            var xf = Transform()
            xf.fit = .fill
            let length = sky.isImage ? clip.duration : min(clip.duration, sky.duration)
            let placed = try p.addClip(Clip(id: Project.newClipId(), kind: .media, name: "sky", mediaId: sky.id, start: clip.start, duration: length, transform: xf), trackId: track.id, mode: .place)
            lines.insert(String(format: "Keyed the sky of %@ with %@ (mask.sky inverted, %.0f%% of the frame at %@s) over %@ on new track %@ below it.", clipId, maskId, measured.coverage * 100, fmt2(at), placed.id, track.id), at: 0)
            if length < clip.duration - 0.01 { lines.append("\(sky.id) is shorter than \(clipId); the sky ends at \(fmt2(placed.end))s (use a still or a longer plate).") }
            lines.append("mask.sky is a heuristic (bright, smooth, sky-colored pixels connected to the top), not a trained model: check edges with timeline_frames view:\"matte\" clip:\(clipId) effect:\(maskId); tune fx.\(maskId).sensitivity, smoothness, feather or expand, and expect trouble with hair, fine branches, haze, night skies and sky-colored walls or water.")
            return lines.joined(separator: "\n")
        }
    }
}
