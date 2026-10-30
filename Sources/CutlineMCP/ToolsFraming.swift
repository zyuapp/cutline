import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    /// transform.x/y for a fill-framed media clip that keep the faces it shows (else its salient subject) in frame,
    /// from shot analysis over the clip's source range; nil without analysis or room to move.
    static func fillFraming(_ c: Clip, _ p: Project, _ shots: [String: ShotAnalysis]) -> (x: Double, y: Double)? {
        guard c.kind == .media, c.transform.fit == .fill, let id = c.mediaId, let m = p.mediaAsset(id), m.width > 0, m.height > 0, let a = shots[id] else { return nil }
        let lo = min(c.sourceIn, c.sourceOut), hi = max(c.sourceIn, c.sourceOut)
        let sourceAspect = Double(m.width) / Double(m.height), canvasAspect = Double(p.canvas.width) / Double(p.canvas.height)
        let faces = a.faces.flatMap(\.samples).filter { $0.t >= lo - 0.25 && $0.t <= hi + 0.25 }.map(\.box)
        let biggest = faces.map(\.height).max() ?? 0
        let kept = faces.filter { $0.height >= biggest * 0.4 }
        if !kept.isEmpty { return Transform.fillOffset(sourceAspect: sourceAspect, canvasAspect: canvasAspect, scale: c.transform.scale, subjects: kept, faces: true) }
        let salient = a.shots.filter { $0.end > lo && $0.start < max(hi, lo + 0.01) }.compactMap(\.saliency)
        guard !salient.isEmpty else { return nil }
        return Transform.fillOffset(sourceAspect: sourceAspect, canvasAspect: canvasAspect, scale: c.transform.scale, subjects: salient, faces: false)
    }

    /// Scored footage for beat_cut from media (whole files) or source spans: shot analysis when it exists (after
    /// waiting briefly for a running one), otherwise a quick sharpness and motion sample of evenly spread windows.
    func beatFootage(_ spans: [(mediaId: String, range: TimeRange?)], project p: Project, bundle b: ProjectBundle) async throws -> ([BeatFootage], [String], [String: ShotAnalysis]) {
        let ids = Set(spans.map(\.mediaId))
        if session.jobs.active.contains(where: { ids.contains($0.mediaId) && $0.features.contains("shots") }) {
            _ = await session.jobs.wait(timeout: 90)
        }
        let running = Set(session.jobs.active.filter { ids.contains($0.mediaId) && $0.features.contains("shots") }.map(\.mediaId))
        let shots = Toolbox.shotIndex(b, p, media: ids)
        var footage: [BeatFootage] = []
        var sampled: [String] = []
        for (id, given) in spans {
            guard let m = p.mediaAsset(id) else { continue }
            if m.isImage {
                footage.append(BeatFootage(mediaId: id, range: TimeRange(0, 3600)))
                continue
            }
            let span = given ?? TimeRange(0, m.duration)
            if let a = shots[id], !running.contains(id) {
                for s in a.shots where s.end > span.start + 0.05 && s.start < span.end - 0.05 {
                    footage.append(BeatFootage(shot: s, mediaId: id, range: TimeRange(max(s.start, span.start), min(s.end, span.end))))
                }
                continue
            }
            let n = max(1, min(12, Int(span.duration / 2.5)))
            let windows = (0..<n).map { k in TimeRange(span.start + span.duration * Double(k) / Double(n), span.start + span.duration * Double(k + 1) / Double(n)) }
            let samples = (try? await FootageSampler.sample(m.url, times: windows.map { ($0.start + $0.end) / 2 })) ?? []
            for w in windows {
                let s = samples.first { abs($0.time - (w.start + w.end) / 2) < 1e-6 }
                footage.append(BeatFootage(mediaId: id, range: w, quality: s?.quality, energy: s?.motion))
            }
            sampled.append(id)
        }
        var notes: [String] = []
        if !running.isEmpty {
            notes.append("Shot analysis of \(running.sorted().joined(separator: ", ")) is still running, so those shots were picked by a quick sharpness and motion sample; after analysis_read wait:300, run beat_cut again for picks by aesthetics and faces.")
        }
        let unanalyzed = sampled.filter { !running.contains($0) }
        if !unanalyzed.isEmpty {
            notes.append("No shot analysis for \(Array(Set(unanalyzed)).sorted().joined(separator: ", ")): picked by a quick sharpness and motion sample; media_analyze features:[\"shots\"] adds aesthetics, faces and face-aware framing.")
        }
        return (footage, notes, shots)
    }
}
