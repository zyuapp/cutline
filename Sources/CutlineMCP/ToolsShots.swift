import CoreGraphics
import CutlineCore
import CutlineEngine
import Foundation

/// Shot-aware grading: grades that act in one shot of a clip spanning several, per-shot keys and windows, and
/// splitting clips at their media's scene cuts.
extension Toolbox {
    /// Scene cuts of a clip's media in source seconds; nil when it has no scene analysis.
    func sceneCuts(_ c: Clip, _ p: Project) -> [Seconds]? {
        guard c.kind == .media, let mid = c.mediaId, let m = p.mediaAsset(mid), m.hasVideo, !m.isImage else { return nil }
        return session.bundle?.visualAnalysis(mid)?.sceneCuts
    }

    /// The shots a clip plays, as source spans in play order; its whole span when the media has no scene cuts.
    func clipShots(_ c: Clip, _ p: Project) -> [TimeRange] {
        guard let cuts = sceneCuts(c, p), let m = c.mediaId.flatMap({ p.mediaAsset($0) }) else { return [c.sourceSpan] }
        let shots = c.shots(cuts: cuts, mediaDuration: m.duration)
        return shots.isEmpty ? [c.sourceSpan] : shots
    }

    enum GradeScope: String { case clip, shot, each_shot }

    /// The grade's scope: as passed, else per shot when the clip plays several.
    static func gradeScope(_ a: Args, shots: Int, each: Bool = false) throws -> GradeScope {
        guard let raw = a.optString("scope") else { return shots > 1 ? .shot : .clip }
        guard let s = GradeScope(rawValue: raw), each || s != .each_shot else { throw EditError("scope is clip or shot" + (each ? " or each_shot" : "")) }
        return s
    }

    /// Index of the shot showing timeline time `t` of `c`.
    static func shotIndex(_ shots: [TimeRange], clip c: Clip, at t: Seconds) -> Int {
        let s = c.sourceTime(atTimeline: min(max(t, c.start), c.end - 0.001))
        return shots.firstIndex { s >= $0.start - 1e-6 && s < $0.end } ?? shots.indices.min { abs(shots[$0].start - s) < abs(shots[$1].start - s) } ?? 0
    }

    static func shotLabel(_ shots: [TimeRange], _ i: Int, clip c: Clip) -> String {
        let t = c.timelineSpan(ofSource: shots[i])
        return "shot \(i + 1)/\(shots.count) (\(fmt2(t.start))–\(fmt2(t.end))s)"
    }

    /// effect_add scope: limits the effect to the shot at `at` (scope shot, or a color effect given `at` on a clip that
    /// plays several shots), or clears that limit (scope clip). Returns the shot it now acts in.
    func limitToShot(_ c: inout Clip, effectId: String, _ a: Args, _ p: Project) throws -> String? {
        guard let i = c.effects.firstIndex(where: { $0.id == effectId }) else { return nil }
        let at = try a.optTime("at")
        let scope = a.optString("scope")
        if scope == "clip" { c.effects[i].sourceRange = nil; return nil }
        guard scope == "shot" || (at != nil && EffectCatalog.type(c.effects[i].type)?.category == "color") else { return nil }
        let shots = clipShots(c, p)
        guard shots.count > 1 else {
            if scope == "shot" { throw EditError("\(c.id) plays one shot" + (sceneCuts(c, p) == nil ? " as far as known: its media has no scene analysis (media_analyze features:[\"scenes\"])" : "") + "; leave out scope") }
            return nil
        }
        let t = at ?? (c.start + c.duration / 2)
        guard t >= c.start - 1e-6, t <= c.end + 1e-6 else { throw EditError("at \(fmt2(t))s is outside \(c.id) (\(fmt2(c.start))–\(fmt2(c.end))s)") }
        let k = Toolbox.shotIndex(shots, clip: c, at: t)
        c.effects[i].sourceRange = shots[k]
        return Toolbox.shotLabel(shots, k, clip: c)
    }

    // MARK: qualify

    struct QualifySample {
        var at: Seconds
        var q: Qualifier
        var sampled: Int
        var region: CGRect
        var faceBox: CGRect?
        var hit: Double
        var coverage: Double
        /// Why the sample is from another time than asked.
        var note: String?
    }

    /// Timeline times inside `range` where analyzed faces show, best first: at least n + 1 faces at once, the
    /// largest n-th face first, at most `limit` times at least half a second apart.
    static func faceSearchTimes(_ faces: [FaceTrack], clip c: Clip, range: TimeRange, n: Int, limit: Int = 5) -> [Seconds] {
        let span = c.sourceSpan
        var byTime: [Seconds: [Double]] = [:]
        for f in faces {
            for s in f.samples where s.t >= span.start - 1e-6 && s.t < span.end {
                let t = c.timelineTime(atSource: s.t)
                guard t >= range.start - 1e-6, t < range.end else { continue }
                byTime[(t * 100).rounded() / 100, default: []].append(s.box.width * s.box.height)
            }
        }
        let ranked = byTime.compactMap { t, areas -> (Seconds, Double)? in
            let sorted = areas.sorted(by: >)
            return sorted.count > n ? (t, sorted[n]) : nil
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        var out: [Seconds] = []
        for (t, _) in ranked where !out.contains(where: { abs($0 - t) < 0.5 }) {
            out.append(min(max(t, c.start), c.end - 0.01))
            if out.count == limit { break }
        }
        return out
    }

    /// qualifySample with face:true that looks elsewhere in `range` when no face shows at `at`, inside `shot` first:
    /// at the analyzed faces (largest first), else at evenly spaced frames, keeping the largest face found.
    static func faceSample(_ c: Clip, _ m: MediaAsset, before existing: String?, at: Seconds, explicit: Bool, range: TimeRange, shot: TimeRange? = nil, faces: [FaceTrack]?, _ a: Args) async throws -> QualifySample {
        let firstError: Error
        do { return try await qualifySample(c, m, before: existing, at: at, a) } catch { firstError = error }
        guard a.bool("face", default: false), !m.isImage else { throw firstError }
        let n = a.optInt("n") ?? 0
        func inShot(_ t: Seconds) -> Bool { shot.map { t >= $0.start && t < $0.end } ?? false }
        let analyzed: [Seconds] = faces.map { f -> [Seconds] in
            let all = faceSearchTimes(f, clip: c, range: range, n: n)
            return all.filter(inShot) + all.filter { !inShot($0) }
        } ?? []
        let times = analyzed.isEmpty ? Frames.spread(8, from: range.start, to: max(range.start + 0.01, range.end - 0.01)) : analyzed
        var best: QualifySample?
        func score(_ s: QualifySample) -> Double { (s.faceBox.map { $0.width * $0.height } ?? 0) + (inShot(s.at) ? 10 : 0) }
        for t in times where abs(t - at) > 0.04 {
            guard let s = try? await qualifySample(c, m, before: existing, at: t, a), s.faceBox != nil else { continue }
            if !analyzed.isEmpty { best = s; break }
            if score(s) > best.map(score) ?? 0 { best = s }
        }
        guard var found = best else {
            throw EditError("No face\(n > 0 ? " \(n)" : "") found in \(c.id) at \(fmt2(at))s nor \(analyzed.isEmpty ? "at \(times.count) frames across" : "where shot analysis saw faces in") \(fmt2(range.start))–\(fmt2(range.end))s; pass x and y of a skin area instead")
        }
        let place = shot == nil ? "" : inShot(found.at) ? " in the same shot" : " in another shot (none in this one)"
        found.note = "No face\(n > 0 ? " \(n)" : "") at \(fmt2(at))s\(explicit ? "" : " (the default, the clip's middle)"); sampled at \(fmt2(found.at))s\(place) instead, " + (analyzed.isEmpty ? "the largest face among \(times.count) frames checked" : "where shot analysis shows the largest face") + "."
        return found
    }

    /// The eyedropper at timeline time `at`: the qualifier covering a face's skin (face) or the patch at x, y, sampled
    /// from the picture as the effect receives it.
    static func qualifySample(_ c: Clip, _ m: MediaAsset, before existing: String?, at: Seconds, _ a: Args) async throws -> QualifySample {
        let source = m.isImage ? 0 : c.sourceTime(atTimeline: min(at, c.end - 0.01))
        guard let frame = try await Frames.media(m, times: [source], maxSize: CGSize(width: 960, height: 960)).first?.image else { throw EditError("Cannot read a frame of \(m.id)") }
        let picture = ShotColor.picture(frame, effects: c.effects, before: existing, clip: c, at: at - c.start)
        var region: CGRect
        var faceBox: CGRect?
        if a.bool("face", default: false) {
            let faces = ShotColor.faces(picture)
            let n = a.optInt("n") ?? 0
            guard n >= 0, n < faces.count else { throw EditError(faces.isEmpty ? "No face found in \(c.id) at \(fmt2(at))s; pass x and y of a skin area instead" : "Only \(faces.count) face(s) at \(fmt2(at))s; n counts from 0, largest first") }
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
        guard let q = Qualifier.pick(samples) else { throw EditError("The sampled pixels at \(fmt2(at))s are nearly gray, so there is no hue to key; sample a colored area, or set q_hue_width 360 for a luma-only key") }
        let frameSamples = ShotColor.pictureSamples(picture, step: 4)
        let coverage = Double(frameSamples.filter { q.clean(Double(q.weight($0))) > 0.5 }.count) / Double(max(1, frameSamples.count))
        let hit = Double(samples.filter { q.clean(Double(q.weight($0))) > 0.9 }.count) / Double(max(1, samples.count))
        return QualifySample(at: at, q: q, sampled: samples.count, region: region, faceBox: faceBox, hit: hit, coverage: coverage)
    }

    /// Clip-local window keys (limit_x, limit_y, limit_width, limit_height) following the analyzed face track that
    /// matches `box` near source time `source`, within `shot`; nil without such a track.
    static func faceWindowKeys(_ faces: [FaceTrack], box: CGRect, source: Seconds, shot: TimeRange, clip c: Clip) -> [String: [CurveKey]]? {
        let target = NormRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
        let span = c.sourceSpan
        let lo = max(shot.start, span.start) - 1e-3, hi = min(shot.end, span.end) + 1e-3
        var best: (samples: [FaceSample], distance: Double)?
        for f in faces {
            let inside = f.samples.filter { $0.t >= lo && $0.t <= hi }
            guard inside.count >= 2, let near = inside.min(by: { abs($0.t - source) < abs($1.t - source) }), abs(near.t - source) < 1 else { continue }
            let d = near.box.centerDistance(target)
            if d < 0.75, d < best?.distance ?? .infinity { best = (inside, d) }
        }
        guard let samples = best?.samples else { return nil }
        func r3(_ v: Double) -> ParamValue { .number((v * 1000).rounded() / 1000) }
        var out: [String: [CurveKey]] = [:]
        for s in samples {
            let t = c.timelineTime(atSource: s.t) - c.start
            out["limit_x", default: []].append(CurveKey(t: t, v: r3(s.box.midX), ease: .linear))
            out["limit_y", default: []].append(CurveKey(t: t, v: r3(s.box.midY), ease: .linear))
            out["limit_width", default: []].append(CurveKey(t: t, v: r3(min(3, s.box.width * 1.35)), ease: .linear))
            out["limit_height", default: []].append(CurveKey(t: t, v: r3(min(3, s.box.height * 1.5)), ease: .linear))
        }
        return out.mapValues { $0.sorted { $0.t < $1.t } }
    }

    struct QualifyPlan {
        enum Range { case keep, set(TimeRange), clear }
        var sample: QualifySample
        var range: Range
        var shotText: String?
        var keys: [String: [CurveKey]]?
    }

    func qualifyRecipe(_ a: Args, dry: Bool) async throws -> ToolResult {
        let current = try session.project()
        let clipId = try a.string("clip")
        guard let c = current.clip(clipId), c.kind == .media, let m = c.mediaId.flatMap({ current.mediaAsset($0) }), m.hasVideo else { throw EditError("clip must be a media clip with a picture") }
        let given = try a.optTime("at")
        let at = given ?? (c.start + c.duration / 2)
        guard at >= c.start - 1e-6, at <= c.end + 1e-6 else { throw EditError("at \(fmt2(at))s is outside \(clipId) (\(fmt2(c.start))–\(fmt2(c.end))s)") }
        let effectId = a.optString("effect")
        let existing = effectId.flatMap { id in c.effects.first { $0.id == id } }
        let type = existing?.type ?? a.optString("type") ?? "color.wheels"
        guard EffectCatalog.type(type)?.spec("q_hue") != nil else { throw EditError("\(type) can't be limited to a qualifier; use a color, blur or stylize effect") }
        let shots = clipShots(c, current)
        let scope = try Toolbox.gradeScope(a, shots: shots.count, each: true)
        if scope == .each_shot, effectId != nil { throw EditError("scope each_shot adds one effect per shot; leave out effect") }
        let faces = a.bool("face", default: false) ? session.bundle?.analysis(ShotAnalysis.self, m.id, "shots")?.faces : nil
        let search = TimeRange(c.start, c.end)
        let window = a.bool("window", default: a.bool("face", default: false))
        func keys(_ s: QualifySample, shot i: Int) -> [String: [CurveKey]]? {
            guard window, let box = s.faceBox, let faces else { return nil }
            return Toolbox.faceWindowKeys(faces, box: box, source: c.sourceTime(atTimeline: min(s.at, c.end - 0.01)), shot: shots[i], clip: c)
        }
        var plans: [QualifyPlan] = []
        var skipped: [String] = []
        if scope == .each_shot {
            for i in shots.indices {
                let span = c.timelineSpan(ofSource: shots[i])
                let t = at >= span.start && at < span.end ? at : (span.start + span.end) / 2
                let label = Toolbox.shotLabel(shots, i, clip: c)
                do {
                    let s = try await Toolbox.faceSample(c, m, before: nil, at: t, explicit: t == given, range: span, faces: faces, a)
                    plans.append(QualifyPlan(sample: s, range: shots.count > 1 ? .set(shots[i]) : .clear, shotText: label, keys: keys(s, shot: i)))
                } catch {
                    skipped.append("\(label) skipped: \(error.localizedDescription)")
                }
            }
            guard !plans.isEmpty else { throw EditError("No shot of \(clipId) could be qualified: " + skipped.joined(separator: "; ")) }
        } else {
            let s = try await Toolbox.faceSample(c, m, before: existing?.id, at: at, explicit: given != nil, range: search, shot: shots.count > 1 ? c.timelineSpan(ofSource: shots[Toolbox.shotIndex(shots, clip: c, at: at)]) : nil, faces: faces, a)
            let i = Toolbox.shotIndex(shots, clip: c, at: s.at)
            let range: QualifyPlan.Range = existing != nil && !a.has("scope") ? .keep : scope == .shot ? .set(shots[i]) : .clear
            var text: String?
            if case .set = range { text = Toolbox.shotLabel(shots, i, clip: c) }
            plans.append(QualifyPlan(sample: s, range: range, shotText: text, keys: keys(s, shot: i)))
        }
        let defaulted = !a.has("scope") && scope == .shot && existing == nil
        return try runEdit("Qualify \(Toolbox.clipName(clipId, current))", dry: dry) { p in
            guard let loc = p.locateClip(clipId) else { throw EditError("No clip \(clipId)") }
            var clip = p.tracks[loc.track].clips[loc.clip]
            var lines: [String] = []
            var last = ""
            for plan in plans {
                let s = plan.sample
                var e = existing ?? Effect(id: effectId ?? clip.nextEffectId(type), type: type)
                let limit = e.params["limit"]?.string ?? "none"
                var shape = limit.split(separator: "+").map(String.init).first { $0 == "rect" || $0 == "ellipse" }
                if window, let box = s.faceBox {
                    shape = "ellipse"
                    e.params["limit_x"] = .number((box.midX * 1000).rounded() / 1000)
                    e.params["limit_y"] = .number((box.midY * 1000).rounded() / 1000)
                    e.params["limit_width"] = .number(min(3, (box.width * 1.35 * 1000).rounded() / 1000))
                    e.params["limit_height"] = .number(min(3, (box.height * 1.5 * 1000).rounded() / 1000))
                    e.params["limit_feather"] = .number(0.03)
                    for k in ["limit_x", "limit_y", "limit_width", "limit_height"] { clip.anim["fx.\(e.id).\(k)"] = plan.keys?[k].map { Curve(keys: $0) } }
                }
                e.params["limit"] = .string(shape.map { "\($0)+qualifier" } ?? "qualifier")
                e.params["q_preset"] = nil
                e.params["q_softness"] = nil
                for (k, v) in s.q.params { e.params[k] = v }
                switch plan.range {
                case .keep: break
                case .set(let r): e.sourceRange = r
                case .clear: e.sourceRange = nil
                }
                if let i = clip.effects.firstIndex(where: { $0.id == e.id }) { clip.effects[i] = e } else { clip.effects.append(e) }
                let place = s.faceBox.map { String(format: "face %d (%.2f, %.2f, %.2f×%.2f)", a.optInt("n") ?? 0, $0.minX, $0.minY, $0.width, $0.height) } ?? String(format: "(%.2f, %.2f)", s.region.midX, s.region.midY)
                var text = (s.note.map { $0 + "\n" } ?? "") + "Qualifier on \(clipId) effect \(e.id) (\(e.type), limit \(e.params["limit"]!.string!))" + (plan.shotText.map { ", only in \($0)" } ?? "") + " sampled from \(s.sampled) pixels at \(place), \(fmt2(s.at))s: \(s.q.summary). "
                text += String(format: "%.0f%% of the sampled area keys fully; the colors cover %.0f%% of the whole frame.", s.hit * 100, s.coverage * 100)
                if let n = plan.keys?["limit_x"]?.count { text += " The ellipse window follows the face through the shot (\(n) keys)." }
                else if shape != nil && window && s.faceBox != nil { text += " An ellipse window on the face keeps the key there" + (faces == nil ? "; run media_analyze features:[\"shots\"] for face tracks and qualify again to make it follow the face." : ".") }
                else if shape == nil && s.coverage > 0.35 { text += " That is a lot of the frame: narrow it with q_hue_width or q_sat_max, or add a window (limit ellipse+qualifier)." }
                lines.append(text)
                last = e.id
            }
            p.tracks[loc.track].clips[loc.clip] = clip
            if defaulted { lines.append("\(clipId) plays \(shots.count) shots, so the grade acts only in the shot at \(fmt2(plans.first?.sample.at ?? at))s; scope:\"each_shot\" keys every shot, scope:\"clip\" the whole clip.") }
            lines += skipped
            return lines.joined(separator: "\n") + "\nCheck it with timeline_frames view:\"matte\" clip:\(clipId) effect:\(last); refine with q_clean_black, q_clean_white, q_denoise and q_blur."
        }
    }

    // MARK: split_at_shots

    func splitAtShotsRecipe(_ a: Args, dry: Bool) throws -> ToolResult {
        let current = try session.project()
        var ids = a.strings("clips") ?? []
        if let tid = a.optString("track") {
            guard let i = current.trackIndex(tid) else { throw EditError("No track \(tid)") }
            ids += current.tracks[i].clips.filter { $0.kind == .media }.map(\.id)
        }
        if ids.isEmpty, let v1 = current.tracks.first(where: { $0.kind == .video }) { ids = v1.clips.filter { $0.kind == .media }.map(\.id) }
        guard !ids.isEmpty else { throw EditError("No clips to split; pass clips or track") }
        var cuts: [String: [Seconds]] = [:]
        var notes: [String] = []
        for id in ids {
            guard let c = current.clip(id) else { throw EditError("No clip \(id)") }
            guard let mid = c.mediaId, current.mediaAsset(mid).map({ $0.hasVideo && !$0.isImage }) == true else { notes.append("\(id): no moving picture, left whole"); continue }
            guard let found = sceneCuts(c, current) else { notes.append("\(id): \(mid) has no scene analysis; run media_analyze media_id:\"\(mid)\" features:[\"scenes\"]"); continue }
            cuts[id] = found
        }
        return try runEdit("Split \(ids.count) clip(s) at shot cuts", dry: dry) { p in
            var lines: [String] = []
            for id in ids {
                guard let found = cuts[id] else { continue }
                let pieces = try p.splitAtShots(id, cuts: found)
                if pieces.count == 1 { lines.append("\(id): one shot, left whole"); continue }
                lines.append("\(id) → " + pieces.compactMap { pid in p.clip(pid).map { "\(pid) \(fmt2($0.start))–\(fmt2($0.end))s" } }.joined(separator: ", "))
            }
            return (["Split at the media's scene cuts, so each shot grades on its own:"] + lines.map { "  " + $0 } + notes).joined(separator: "\n")
                + "\nGrade a shot with effect_add, recipe qualify or match_color; linked sound is split with its picture."
        }
    }
}
