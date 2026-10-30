import CutlineCore
import CutlineEngine
import Foundation

/// Strings shared across threads.
final class KeySet: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []

    /// False when `key` was already there.
    func insert(_ key: String) -> Bool { lock.withLock { keys.insert(key).inserted } }
    func remove(_ key: String) { lock.withLock { _ = keys.remove(key) } }
}

extension Session {
    static let pictureJob = "picture"

    /// Queues background renders of the processed pictures `p` needs that aren't cached or queued yet; one line per clip.
    func queuePictures(_ p: Project) -> [String] {
        guard let b = bundle else { return [] }
        var lines: [String] = []
        for r in ProcessedPicture.requests(p) where ProcessedPicture.cached(r) == nil && pictureJobs.insert(r.key) {
            let id = jobs.enqueue(r.media.id, named: [Session.pictureJob], bundle: b.url, pictureWork([r]))
            lines.append("\(r.summary) on \(r.clipId) renders in the background (\(id), \(fmt1(r.range.duration))s of source); the preview plays the unprocessed picture until it is done, and timeline_frames and export wait for it.")
        }
        return lines
    }

    func pictureWork(_ requests: [ProcessedPicture.Request]) -> JobBoard.Work {
        { [self] progress in
            defer { requests.forEach { pictureJobs.remove($0.key) } }
            let began = Date()
            for (k, r) in requests.enumerated() {
                let n = Double(requests.count)
                _ = try await ProcessedPicture.render(r) { p in progress((Double(k) + p) / n) }
            }
            try? sendPreview(["action": "rebuild"])
            return requests.map { "\($0.summary) on \($0.clipId)" }.joined(separator: ", ") + " ready in \(fmt1(Date().timeIntervalSince(began)))s"
        }
    }

    /// Re-queues a processed-picture job an exited server left unfinished; false when nothing is left to render.
    func resumePictures(_ job: JobBoard.Job, _ p: Project) -> Bool {
        let pending = ProcessedPicture.requests(p).filter { $0.media.id == job.mediaId && ProcessedPicture.cached($0) == nil && pictureJobs.insert($0.key) }
        guard !pending.isEmpty else { return false }
        jobs.resume(job, pictureWork(pending))
        return true
    }
}

extension Toolbox {
    /// Points a mask.object or video.remove_object effect at a media_track track: copies the track's confident boxes
    /// into its boxes parameter.
    func fillTrackedBoxes(_ c: inout Clip, effectId: String, project p: Project) throws {
        guard let i = c.effects.firstIndex(where: { $0.id == effectId }), c.effects[i].params["track"] != nil else { return }
        let raw = c.effects[i].params["track"]?.string ?? ""
        let id = raw.hasPrefix("track:") ? String(raw.dropFirst(6)) : raw
        guard !id.isEmpty else { return }
        let b = try session.requireBundle()
        guard let found = Toolbox.objectTrack(id, b, p) else { throw EditError("No tracked object \(id); create one with media_track") }
        guard found.mediaId == c.mediaId else { throw EditError("\(id) follows an object in \(found.mediaId), but \(c.id) plays \(c.mediaId ?? "no media")") }
        guard !found.samples.isEmpty else { throw EditError("\(id) has no confident samples; re-track with media_track") }
        c.effects[i].params["track"] = .string(id)
        c.effects[i].params["boxes"] = .string(ObjectTrack.encodeBoxes(found.samples.map { TrackSample(t: $0.t, box: $0.box, confidence: 1) }))
    }

    /// recipe remove_object: tracks (or takes) the object's box and adds video.remove_object to the clip.
    func removeObject(_ a: Args, dry: Bool) async throws -> ToolResult {
        let b = try session.requireBundle()
        let current = try session.project()
        let clipId = try a.string("clip")
        guard let c = current.clip(clipId), c.kind == .media, let mid = c.mediaId, let m = current.mediaAsset(mid), m.hasVideo, !m.isImage else { throw EditError("\(clipId) is not a video clip") }
        let lo = max(0, min(c.sourceIn, c.sourceOut) - 0.5), hi = min(m.duration, max(c.sourceIn, c.sourceOut) + 0.5)
        var samples: [TrackSample]
        var note: String
        var trackId: String?
        if let t = a.optString("track") {
            let id = t.hasPrefix("track:") ? String(t.dropFirst(6)) : t
            guard let found = Toolbox.objectTrack(id, b, current) else { throw EditError("No tracked object \(id); create one with media_track or pass box") }
            guard found.mediaId == mid else { throw EditError("\(id) follows an object in \(found.mediaId), but \(clipId) plays \(mid)") }
            samples = found.samples.map { TrackSample(t: $0.t, box: $0.box, confidence: 1) }
            trackId = id
            note = "Using \(id) (\(samples.count) samples)."
        } else {
            let o = a.value("box")?.object ?? [:]
            guard let x = o["x"]?.double, let y = o["y"]?.double, let w = o["width"]?.double, let h = o["height"]?.double, w > 0, h > 0 else {
                throw EditError("Pass track: \"track:<id>\" from media_track, or box: {x, y, width, height} (source frame fractions) with at")
            }
            let box = NormRect(x: x, y: y, width: w, height: h)
            let at = try a.optTime("at") ?? c.start
            let src = min(hi, max(lo, c.sourceTime(atTimeline: min(max(at, c.start), c.end - 1e-3))))
            if a.bool("fixed", default: false) {
                samples = [TrackSample(t: lo, box: box, confidence: 1), TrackSample(t: hi, box: box, confidence: 1)]
                note = "Fixed box over \(fmt2(lo))–\(fmt2(hi))s."
            } else {
                let forward = hi - src > 0.02 ? try await ObjectTracker.track(media: m.url, from: src, to: hi, box: box, fps: min(30, max(10, m.fps))) : [TrackSample(t: src, box: box, confidence: 1)]
                let backward = src - lo > 0.02 ? try await ObjectTracker.track(media: m.url, from: src, to: lo, box: box, fps: min(30, max(10, m.fps))) : []
                let all = (backward.filter { $0.t < src - 1e-6 } + forward).sorted { $0.t < $1.t }
                var tracks = b.analysis([ObjectTrack].self, mid, "tracks") ?? []
                var n = tracks.count + 1
                while tracks.contains(where: { $0.id == "trk\(n)" }) { n += 1 }
                let track = ObjectTrack(id: "trk\(n)", mediaId: mid, label: a.optString("label") ?? "removed object", samples: ObjectTrack.smoothed(all, sigma: 0.1))
                if !dry {
                    tracks.append(track)
                    try b.saveAnalysis(tracks, mid, "tracks")
                    trackId = track.id
                }
                samples = track.samples.filter { $0.confidence >= ObjectTrack.lostConfidence }
                note = Toolbox.describeTrack(track)
            }
        }
        guard !samples.isEmpty else { throw EditError("The object's track has no confident samples; give a tighter box or a media_track track") }
        let boxes = ObjectTrack.encodeBoxes(samples)
        var params: [String: ParamValue] = ["boxes": .string(boxes)]
        if let trackId { params["track"] = .string(trackId) }
        for name in ["padding", "window", "feather"] { if let v = a.optDouble(name) { params[name] = .number(v) } }
        if let fill = a.optString("fill") { params["fill"] = .string(fill) }
        if let plate = a.optString("clean_plate") {
            let path = (plate as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw EditError("No clean plate image at \(plate)") }
            params["clean_plate"] = .string(path)
            note += " Clean plate \((path as NSString).lastPathComponent)."
        }
        if let at = try a.optTime("clean_plate_at") {
            let src = c.sourceTime(atTimeline: min(max(at, c.start), c.end - 1e-3))
            params["clean_plate_at"] = .number(src)
            note += " Clean plate from source \(fmt2(src))s."
        }
        var result = try runEdit("Remove object from \(Toolbox.clipName(clipId, current))", dry: dry) { p in
            guard let loc = p.locateClip(clipId), let type = EffectCatalog.type("video.remove_object") else { throw EditError("No clip \(clipId)") }
            var clip = p.tracks[loc.track].clips[loc.clip]
            var k = 1
            while clip.effects.contains(where: { $0.id == "removal\(k)" }) { k += 1 }
            for (name, v) in params { params[name] = try type.spec(name)?.validate(v, path: "fx.removal\(k).\(name)") ?? v }
            clip.effects.append(Effect(id: "removal\(k)", type: "video.remove_object", params: params))
            p.tracks[loc.track].clips[loc.clip] = clip
            return "\(clipId): added removal\(k) (video.remove_object). \(note)"
        }
        if !dry {
            let queued = session.queuePictures(try session.project())
            if !queued.isEmpty { result.addText(queued.joined(separator: "\n")) }
        }
        return result
    }
}
