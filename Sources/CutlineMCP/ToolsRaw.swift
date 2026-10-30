import CutlineCore
import CutlineEngine
import Foundation

extension Session {
    static let developJob = "develop"
    static let rawJob = "raw"

    /// Background work that develops a RAW media item, links it to the copy, then runs the default analysis.
    func developWork(_ m: MediaAsset, language: String, analyze: Bool = true) -> JobBoard.Work {
        let b = bundle
        return { [self] progress in
            guard let b else { throw EditError("No project is open") }
            let linked = try await CameraRawIngest.finish(m, cache: b.cacheURL) { progress(0.8 * $0) }
            var p = try b.loadProject()
            guard let i = p.media.firstIndex(where: { $0.id == m.id }) else { throw EditError("media \(m.id) is no longer in the project") }
            p.media[i] = Session.relinkedRaw(p.media[i], to: linked)
            try b.commit(p, label: "Link \(m.id) to its developed copy")
            try? sendPreview(["action": "rebuild"])
            var note = "\(m.id) developed → \(linked.path)"
            if analyze {
                let (now, later) = Session.defaultFeatures(linked)
                let notes = try await self.analyze(p.media[i], features: now + later, language: language, explicit: false) { progress(0.8 + 0.2 * $0) }
                if !notes.isEmpty { note += "; " + notes }
            }
            return note
        }
    }

    /// `linked` with the user's settings kept, the media's RAW development included.
    static func relinkedRaw(_ old: MediaAsset, to linked: MediaAsset) -> MediaAsset {
        var m = relinked(old, to: linked)
        m.log = linked.log
        m.signalRange = linked.signalRange
        if let s = old.raw?.settings { m.raw?.settings = s }
        return m
    }

    /// Queues the developed copies DNG clips need that aren't cached or queued yet; one line each.
    func queueRawDevelops(_ p: Project) -> [String] {
        guard let b = bundle else { return [] }
        var lines: [String] = []
        for r in CameraRawDevelop.requests(p) where CameraRawDevelop.cached(r) == nil && pictureJobs.insert(r.key) {
            let id = jobs.enqueue(r.media.id, named: [Session.rawJob], bundle: b.url, rawWork([r]))
            lines.append("\(r.summary) renders in the background (\(id)); the preview plays the as-shot development until it is done, and timeline_frames and export wait for it.")
        }
        return lines
    }

    func rawWork(_ requests: [CameraRawDevelop.Request]) -> JobBoard.Work {
        { [self] progress in
            defer { requests.forEach { pictureJobs.remove($0.key) } }
            let began = Date()
            for (k, r) in requests.enumerated() {
                let n = Double(requests.count)
                _ = try await CameraRawDevelop.render(r) { p in progress((Double(k) + p) / n) }
            }
            try? sendPreview(["action": "rebuild"])
            return requests.map(\.summary).joined(separator: ", ") + " ready in \(fmt1(Date().timeIntervalSince(began)))s"
        }
    }

    /// Re-queues RAW work an exited server left unfinished; false when nothing is left to do.
    func resumeRaw(_ job: JobBoard.Job, _ p: Project) -> Bool {
        if job.features == [Session.developJob] {
            guard let m = p.mediaAsset(job.mediaId), m.isTranscoding, m.raw != nil else { return false }
            jobs.resume(job, developWork(m, language: job.language ?? "en-US"))
            return true
        }
        let pending = CameraRawDevelop.requests(p).filter { $0.media.id == job.mediaId && CameraRawDevelop.cached($0) == nil && pictureJobs.insert($0.key) }
        guard !pending.isEmpty else { return false }
        jobs.resume(job, rawWork(pending))
        return true
    }
}

extension Toolbox {
    static let rawExtensions: Set<String> = CameraRawIngest.stillExtensions.union(CameraRawIngest.vendorExtensions.keys)

    /// Import paths with folders expanded: a folder of DNG frames (or each such sub-folder) is one CinemaDNG clip,
    /// other folders contribute the media files inside.
    static func expandImportPaths(_ urls: [URL]) -> (files: [URL], missing: [String]) {
        var files: [URL] = [], missing: [String] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.exists(url, &isDir) else { missing.append("\(url.path): not found"); continue }
            guard isDir.boolValue else { files.append(url); continue }
            if CameraRawIngest.sequenceFrames(in: url) != nil { files.append(url); continue }
            let items = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            for item in items {
                var sub: ObjCBool = false
                if fm.exists(item, &sub), sub.boolValue {
                    if CameraRawIngest.sequenceFrames(in: item) != nil { files.append(item) }
                } else if mediaExtensions.contains(item.pathExtension.lowercased()) {
                    files.append(item)
                }
            }
        }
        return (files, missing)
    }

    /// "ProRes RAW, as shot 5400K gain ×8.45; developed copy … (raw.* adjust it …)".
    static func rawNote(_ m: MediaAsset) -> String? {
        guard let raw = m.raw else { return nil }
        let live = raw.format == .prores_raw ? "raw.exposure/iso/temperature/tint/highlights apply live" : (m.isImage ? "raw.* develop it (exposure live)" : "raw.exposure applies live; raw.temperature/tint/highlights/noise_reduction render a developed copy in the background")
        return "camera RAW: \(raw.summary); \(live); media_organize raw sets its defaults; catalog type=raw explains"
    }

    /// " prores_raw (as shot)" for RAW media, " slog3" for log, "" otherwise.
    static func encodingTag(_ m: MediaAsset) -> String {
        if let raw = m.raw { return " \(raw.format.rawValue) (\(raw.settings.summary))" }
        return m.log.map { " \($0.rawValue)" } ?? ""
    }

    /// Applies media_organize's `raw` object to one media item.
    static func applyRaw(_ m: inout MediaAsset, _ args: Args) throws {
        guard let obj = args.raw["raw"]?.object else { return }
        guard var raw = m.raw else { throw EditError("\(m.id) isn't camera RAW; raw settings develop ProRes RAW, CinemaDNG and raw stills") }
        if obj["reset"]?.bool == true { raw.settings = RawSettings() }
        for (k, v) in obj.sorted(by: { $0.key < $1.key }) where k != "reset" {
            guard let n = v.double else { throw EditError("raw.\(k) needs a number, got \(v)") }
            try raw.settings.set(k, n)
        }
        if raw.format == .prores_raw, raw.settings.noiseReduction != nil { throw EditError("noise_reduction applies to DNG and raw stills; ProRes RAW is debayered by AVFoundation without it (add a denoise effect instead)") }
        m.raw = raw
    }

    /// catalog type=raw: formats, controls and this project's RAW media.
    func rawCatalog() -> String {
        var lines = [
            "Camera RAW. Imported with media_import (a CinemaDNG clip is a folder of .dng frames; fps sets its rate when the frames record none).",
            "Decoded on this Mac: Apple ProRes RAW/RAW HQ (AVFoundation debayer, as-shot ISO gain, white balance and color matrix read from the frames), CinemaDNG and camera raw stills (CIRAWFilter: DNG, CR2/CR3, NEF, ARW, RAF, ORF, RW2…).",
            "Video is developed to ProRes 4444 XQ holding scene-linear light in \(CameraRaw.workingLog.name) (12-bit), so it goes through the log/ACES input like camera log: input.tone and input.exposure still apply.",
            "Not decodable (vendor SDK needed; import reports what to export instead): " + RawFormat.allCases.filter { !$0.isDecodable }.map(\.title).joined(separator: ", ") + ".",
            "Clip parameters (param_set; project_status target=<clip> shows them on RAW clips):",
        ]
        lines += CameraRaw.specs.map { "  " + $0.line }
        lines.append("ProRes RAW: every control applies live and exactly on white-balanced camera RGB (temperature/tint re-balance through the clip's color matrix). DNG: exposure is live; temperature, tint, highlights and noise_reduction render a developed copy per setting in the background (the preview shows the as-shot copy until then; export waits). Stills develop on the fly.")
        lines.append("Media defaults (like Resolve's camera RAW tab): media_organize raw:{exposure, iso, temperature, tint, highlights, noise_reduction, reset}; clip values add (exposure, tint) or override.")
        if let p = try? session.project() {
            let raws = p.media.filter { $0.raw != nil }
            lines.append(raws.isEmpty ? "This project has no RAW media." : "This project's RAW media:")
            for m in raws {
                var state = m.isTranscoding ? "developing from \(m.conformPath)" : (m.isImage ? "still \(m.path)" : "developed copy \(m.path)")
                let reqs = CameraRawDevelop.requests(p).filter { $0.media.id == m.id }
                if !reqs.isEmpty { state += "; copies " + reqs.map { "\($0.settings.summary) " + (CameraRawDevelop.cached($0) != nil ? "ready" : "pending") }.joined(separator: ", ") }
                lines.append("  \(m.id): \(m.raw!.summary); \(state)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

private extension FileManager {
    func exists(_ url: URL, _ isDir: inout ObjCBool) -> Bool { fileExists(atPath: url.path, isDirectory: &isDir) }
}
