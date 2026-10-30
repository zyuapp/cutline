import AVFoundation
import CutlineCore
import CutlineEngine
import Foundation

extension Session {
    static let transcodeJob = "transcode"

    /// Background work that makes a media item's mezzanine, links it, then runs the default analysis.
    func transcodeWork(_ m: MediaAsset, info: ProbeInfo?, language: String, analyze: Bool = true) -> JobBoard.Work {
        let b = bundle
        return { [self] progress in
            guard let b else { throw EditError("No project is open") }
            guard let tools = FFmpeg.tools() else { throw EditError("ffmpeg is gone; \(FFmpeg.installHint) and re-import \(m.conformPath)") }
            let original = m.conformURL
            var probed = info
            if probed == nil {
                guard let ffprobe = tools.ffprobe else { throw EditError("ffprobe wasn't found beside \(tools.ffmpeg.path)") }
                probed = try await FFmpeg.probe(original, ffprobe: ffprobe)
            }
            let linked = try await MediaIngest.finish(original, id: m.id, info: probed!, cache: b.cacheURL, tools: tools) { progress(0.8 * $0) }
            var p = try b.loadProject()
            guard let i = p.media.firstIndex(where: { $0.id == m.id }) else { throw EditError("media \(m.id) is no longer in the project") }
            p.media[i] = Session.relinked(p.media[i], to: linked)
            try b.commit(p, label: "Link \(m.id) to its ProRes mezzanine")
            try? sendPreview(["action": "rebuild"])
            var note = "\(m.id) → \(linked.path)"
            if analyze {
                let (now, later) = Session.defaultFeatures(linked)
                let notes = try await self.analyze(p.media[i], features: now + later, language: language, explicit: false) { progress(0.8 + 0.2 * $0) }
                if !notes.isEmpty { note += "; " + notes }
            }
            return note
        }
    }

    /// `linked`'s file facts with the user's own settings (name, bin, metadata, tags, log, deinterlace) kept.
    static func relinked(_ old: MediaAsset, to linked: MediaAsset) -> MediaAsset {
        var m = linked
        m.name = old.name
        m.bin = old.bin
        m.metadata = old.metadata
        m.tags = old.tags
        m.log = old.log
        m.signalRange = old.signalRange
        m.deinterlace = old.deinterlace
        m.reel = m.reel ?? old.reel
        return m
    }
}

extension Toolbox {
    /// media_import without relink: every file is imported or listed as failed, never both.
    func importMedia(_ paths: [String], args: Args) async throws -> ToolResult {
        let b = try session.requireBundle()
        var files: [URL] = []
        var failures: [String] = []
        for path in paths {
            let url = session.resolve(path)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { failures.append("\(url.path): not found"); continue }
            if isDir.boolValue {
                let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                files += items.filter { Toolbox.mediaExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
            } else {
                files.append(url)
            }
        }
        var project = try b.loadProject()
        let tools = FFmpeg.tools()
        var imported: [MediaAsset] = []
        var deferred: [String: ProbeInfo] = [:]
        var lines: [String] = []
        for url in files {
            if let existing = project.media.first(where: { $0.path == url.path || $0.originalPath == url.path }) {
                lines.append("\(url.path) → \(existing.id) (already imported)")
                continue
            }
            let id = Toolbox.mediaId(for: url, existing: Set(project.media.map(\.id)))
            do {
                var m: MediaAsset
                switch try await MediaIngest.prepare(url, id: id, cache: b.cacheURL, tools: tools) {
                case .ready(let ready): m = ready
                case .deferred(let placeholder, let info):
                    m = placeholder
                    deferred[id] = info
                }
                if m.hasVideo, !m.isImage, deferred[id] == nil { m.log = await ColorManagement.detectLog(AVURLAsset(url: m.url)) }
                project.media.append(m)
                imported.append(m)
            } catch let f as MediaIngest.Failure {
                failures.append(f.description)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        var canvasNotes: [String] = []
        if !imported.isEmpty {
            try session.edit("Import \(imported.map(\.name).joined(separator: ", "))") { p in
                p.media += imported
                canvasNotes = imported.compactMap { p.fitCanvas(toImported: $0) }
            }
        }
        let analyze = args.bool("analyze", default: true)
        let language = args.optString("language") ?? "en-US"
        for m in imported {
            var line = "\(m.conformPath) → \(m.id): " + Toolbox.mediaFacts(m)
            if let info = deferred[m.id] {
                let job = session.jobs.enqueue(m.id, named: [Session.transcodeJob], bundle: b.url, language: language, analyze: analyze)
                line += " — \(fmt1(m.duration))s of \(info.codecSummary) is transcoding to ProRes 422 HQ in the background (\(job)); don't use \(m.id) until analysis_read wait:600 shows it done"
                lines.append(line)
                continue
            }
            if analyze {
                let (now, later) = Session.defaultFeatures(m)
                let notes = try await session.analyze(m, features: now, language: language, explicit: false)
                if !notes.isEmpty { line += " — " + notes }
                if !later.isEmpty {
                    let job = session.jobs.enqueue(m.id, later, bundle: b.url, language: language)
                    line += " — \(later.map(\.rawValue).joined(separator: " and ")) analyzing in the background (\(job))"
                }
            }
            lines.append(line)
        }
        var out: [String] = []
        if !lines.isEmpty { out.append("Media ids (made from file names: lowercase, other characters become \"-\"); use the id after → in every edit:") }
        out += lines.map { "  " + $0 }
        out += canvasNotes
        if !failures.isEmpty {
            out.append("Not imported (\(failures.count)):")
            out += failures.map { "  " + $0 }
        }
        if imported.isEmpty && lines.isEmpty { throw EditError(out.joined(separator: "\n")) }
        return .text(out.joined(separator: "\n") + "\nNext: media_transcript to read speech, media_frames to look at footage.")
    }

    /// "3.00s 1920×1080 25fps, interlaced top field first (deinterlaced), transcoded from …".
    static func mediaFacts(_ m: MediaAsset) -> String {
        var s = (m.isImage ? "image" : fmt2(m.duration) + "s") + " " + (m.hasVideo ? "\(m.width)×\(m.height)" + (m.isImage ? "" : " \(Describe.fmtFps(m.fps))fps") : "audio only")
        if m.isInterlaced { s += ", " + interlaceNote(m) }
        if let tc = sourceTimecodeNote(m) { s += ", " + tc }
        if let t = m.transcoded, !m.isTranscoding { s += ", transcoded \(t) at \(m.path); the original stays the conform source" }
        if let ch = m.channelSummary { s += "; " + ch + " (play any with audio.channels \"ch3\", \"ch3+ch4\" or \"mix:1,3\"; clip_add channels:\"split\" lays each on its own track)" }
        return s
    }

    /// "TC 14:22:10:05 (non-drop), reel A001"; nil without source timecode or reel.
    static func sourceTimecodeNote(_ m: MediaAsset) -> String? {
        var parts: [String] = []
        if let tc = m.timecodeString() {
            let f = m.timecodeFormat()
            parts.append("TC \(tc)" + (f.frameNum == 1001 && f.nominal % 30 == 0 ? (f.dropFrame ? " (drop frame)" : " (non-drop)") : ""))
        }
        if let r = m.reel { parts.append("reel \(r)") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    static func interlaceNote(_ m: MediaAsset) -> String {
        "interlaced \(m.fieldOrder == .tff ? "top" : "bottom") field first (" + (m.deinterlaces ? "deinterlaced in preview and export; media_organize deinterlace:false keeps the fields" : "fields kept, not deinterlaced") + ")"
    }

    /// After relinking: files that don't decode get a mezzanine (now, or in the background when long).
    func transcodeRelinked(_ ids: [String]) async throws -> [String] {
        let b = try session.requireBundle()
        let tools = FFmpeg.tools()
        var notes: [String] = []
        for id in ids {
            guard let m = try b.loadProject().mediaAsset(id), !m.isImage else { continue }
            do {
                switch try await MediaIngest.prepare(m.url, id: id, cache: b.cacheURL, tools: tools) {
                case .ready(let ready):
                    guard ready.originalPath != nil else { continue }
                    try session.edit("Link \(id) to its ProRes mezzanine") { p in
                        if let i = p.media.firstIndex(where: { $0.id == id }) { p.media[i] = Session.relinked(p.media[i], to: ready) }
                    }
                    notes.append("\(id): transcoded \(ready.transcoded ?? "")")
                case .deferred(let placeholder, _):
                    try session.edit("Mark \(id) for transcoding") { p in
                        if let i = p.media.firstIndex(where: { $0.id == id }) { p.media[i].originalPath = placeholder.originalPath; p.media[i].transcoded = placeholder.transcoded }
                    }
                    let job = session.jobs.enqueue(id, named: [Session.transcodeJob], bundle: b.url, analyze: false)
                    notes.append("\(id): transcoding in the background (\(job))")
                }
            } catch {
                notes.append("\(error)")
            }
        }
        return notes
    }
}
