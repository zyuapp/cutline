import CutlineCore
import Foundation

/// An analysis a recipe or tool reads, and how its result changes without it.
struct AnalysisNeed: Equatable {
    var mediaId: String
    var feature: Feature
    var without: String
}

extension Toolbox {
    /// Whether `feature` of `mediaId` is saved and no job is still working on it (a transcode job runs every feature).
    func analysisPending(_ need: AnalysisNeed, _ jobs: [JobBoard.Job]) -> JobBoard.Job? {
        jobs.first { $0.mediaId == need.mediaId && ($0.features.contains(need.feature.rawValue) || $0.features == [Session.transcodeJob]) && !($0.done ?? []).contains(need.feature.rawValue) }
    }

    static func hasAnalysis(_ need: AnalysisNeed, _ b: ProjectBundle) -> Bool {
        switch need.feature {
        case .transcript: b.transcript(need.mediaId) != nil
        case .scenes: b.visualAnalysis(need.mediaId) != nil
        default: hasAnalysis(need.feature, need.mediaId, b)
        }
    }

    /// Waits up to `wait` seconds for the needed analyses still running, then returns one warning per analysis that
    /// is still running or was never run, naming what the result does without it.
    func analysisWarnings(_ needs: [AnalysisNeed], wait: Seconds) async throws -> [String] {
        let b = try session.requireBundle()
        var unique: [AnalysisNeed] = []
        for n in needs where !unique.contains(where: { $0.mediaId == n.mediaId && $0.feature == n.feature }) { unique.append(n) }
        guard !unique.isEmpty else { return [] }
        let deadline = Date().addingTimeInterval(min(max(0, wait), 600))
        while Date() < deadline, unique.contains(where: { analysisPending($0, session.jobs.active) != nil }) {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let active = session.jobs.active
        var out: [String] = []
        for n in unique {
            if let job = analysisPending(n, active) {
                out.append("Warning: \(n.feature.rawValue) analysis of \(n.mediaId) is still running (\(job.id), \(Int(job.progress * 100))%), so \(n.without). Run it again after analysis_read media_id:\"\(n.mediaId)\" wait:300, or pass wait (seconds) to hold this call for it.")
            } else if !Toolbox.hasAnalysis(n, b) {
                out.append("Warning: \(n.mediaId) has no \(n.feature.rawValue) analysis, so \(n.without). Run media_analyze media_id:\"\(n.mediaId)\" features:[\"\(n.feature.rawValue)\"] first for the analyzed result.")
            }
        }
        return out
    }

    /// The analyses a recipe reads, from its arguments and the project.
    func recipeNeeds(_ name: String, _ a: Args, _ p: Project) -> [AnalysisNeed] {
        func media(ofClips ids: [String]) -> [String] { ids.compactMap { p.clip($0)?.mediaId }.filter { p.mediaAsset($0).map { $0.hasVideo && !$0.isImage } ?? false } }
        func pictureMedia(track: String? = nil) -> [String] {
            var seen: [String] = []
            for t in p.tracks where t.kind == .video && (track == nil || t.id == track) {
                for c in t.clips where c.kind == .media { if let id = c.mediaId, !seen.contains(id), p.mediaAsset(id)?.hasVideo == true, p.mediaAsset(id)?.isImage == false { seen.append(id) } }
            }
            return seen
        }
        switch name {
        case "reframe":
            return pictureMedia().map { AnalysisNeed(mediaId: $0, feature: .shots, without: "its clips are framed on the picture's center or salient region instead of following faces") }
        case "punch_in":
            let ids = a.strings("clips").map(media(ofClips:)) ?? pictureMedia(track: a.optString("track") ?? "V1")
            return ids.map { AnalysisNeed(mediaId: $0, feature: .shots, without: "punch-ins are centered on the frame instead of the face") }
        case "follow":
            guard let target = a.optString("target"), target.hasPrefix("face:") else { return [] }
            let id = target.dropFirst(5).split(separator: ":").first.map(String.init)?.split(separator: ".").first.map(String.init) ?? ""
            return p.mediaAsset(id) == nil ? [] : [AnalysisNeed(mediaId: id, feature: .shots, without: "there are no face tracks to follow and the clip stays where it is")]
        case "multicam_switch":
            let setup = a.optString("clip").flatMap { p.clip($0) }.flatMap { p.multicamSetup($0) }
            guard a.value("cuts") == nil, let angles = a.strings("angles") ?? setup?.videoAngles.map(\.mediaId) else { return [] }
            let audio = a.optString("audio").map { setup?.angle($0)?.mediaId ?? $0 } ?? setup?.audio.first.flatMap { setup?.angle($0)?.mediaId } ?? angles.first ?? ""
            var needs = [AnalysisNeed(mediaId: audio, feature: .transcript, without: "there are no speaker turns to cut on")]
            if a.optString("signal") != "mics" {
                needs.append(AnalysisNeed(mediaId: audio, feature: .speakers, without: "voices are told apart only by which mic is loudest"))
                needs += angles.filter { p.mediaAsset($0)?.hasVideo == true }.map {
                    AnalysisNeed(mediaId: $0, feature: .shots, without: "when the mics don't tell speakers apart, speakers go to angles in the order they first talk (S1 to the first angle) instead of the angle where their face is seen talking, and may land on the wrong camera")
                }
            }
            return needs.filter { p.mediaAsset($0.mediaId) != nil }
        case "beat_cut":
            let index = (try? session.requireBundle().anchorIndex(for: p))
            var needs: [AnalysisNeed] = []
            for t in p.tracks where !t.muted {
                for c in t.clips where c.kind == .media {
                    guard let id = c.mediaId, let m = p.mediaAsset(id), m.hasAudio, index?.music.contains(id) == true || !m.hasVideo else { continue }
                    needs.append(AnalysisNeed(mediaId: id, feature: .beats, without: "its beats aren't there to cut on"))
                }
            }
            for id in a.strings("media") ?? [] where p.mediaAsset(id).map({ $0.hasVideo && !$0.isImage }) ?? false {
                needs.append(AnalysisNeed(mediaId: id, feature: .shots, without: "its shots are taken from evenly spaced windows (or scene cuts) instead of the analyzed shots ranked best first"))
            }
            return needs
        case "split_at_shots", "match_color":
            var ids = a.strings("clips") ?? []
            if let tid = a.optString("track"), let t = p.tracks.first(where: { $0.id == tid }) { ids += t.clips.map(\.id) }
            if ids.isEmpty, let v1 = p.tracks.first(where: { $0.kind == .video }) { ids = v1.clips.map(\.id) }
            if name == "match_color" { ids += [a.optString("reference")].compactMap { $0 } }
            return media(ofClips: ids).map { AnalysisNeed(mediaId: $0, feature: .scenes, without: name == "match_color" ? "each clip gets one LUT even where it plays several shots" : "there are no shot cuts to split at") }
        case "qualify":
            let ids = media(ofClips: [a.optString("clip")].compactMap { $0 })
            var needs = ids.map { AnalysisNeed(mediaId: $0, feature: .scenes, without: "the grade acts on the whole clip, in every shot it plays") }
            if a.bool("face", default: false) { needs += ids.map { AnalysisNeed(mediaId: $0, feature: .shots, without: "the face window stays where the face was at at instead of following it") } }
            return needs
        case "remove_object", "track_mask":
            return media(ofClips: [a.optString("clip")].compactMap { $0 }).map { AnalysisNeed(mediaId: $0, feature: .scenes, without: name == "track_mask" ? "tracking stops only at cuts it detects from the frames, which can miss a soft cut" : "shot cuts are found only by comparing neighbouring frames while it renders, which can miss a soft cut") }
        default:
            return []
        }
    }
}
