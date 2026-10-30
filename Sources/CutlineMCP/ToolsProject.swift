import AppKit
import CutlineCore
import CutlineEngine
import Foundation

enum CanvasPreset: String, CaseIterable {
    case landscape, vertical, square, portrait, uhd

    var size: (Int, Int) {
        switch self {
        case .landscape: (1920, 1080)
        case .vertical: (1080, 1920)
        case .square: (1080, 1080)
        case .portrait: (1080, 1350)
        case .uhd: (3840, 2160)
        }
    }
}

extension Toolbox {
    func registerProjectTools() {
        let canvasProps: [String: JSON] = [
            "preset": Schema.string("Canvas size preset: landscape 1920×1080, vertical 1080×1920 (Shorts/Reels/TikTok), square 1080×1080, portrait 1080×1350, uhd 3840×2160", values: CanvasPreset.allCases.map(\.rawValue)),
            "width": Schema.integer("Canvas width in pixels (overrides preset)"),
            "height": Schema.integer("Canvas height in pixels (overrides preset)"),
            "fps": Schema.number("Frame rate, default 30"),
            "background": Schema.string("Background color as hex, default #000000"),
            "color_space": Schema.string("Output color: rec709 (SDR, default), p3 (Display P3), rec2020_hlg or rec2020_pq (HDR, exports as 10-bit HEVC)", values: WorkingSpace.allCases.map(\.rawValue)),
            "timecode_start": Schema.string("Timecode of the first timeline frame in exports, \"hh:mm:ss:ff\" (drop frame at 29.97 and 59.94); default 01:00:00:00"),
            "drop_frame": Schema.bool("Timecode in exported EDL, FCPXML and XML: drop frame (default at 29.97 and 59.94) or false for non-drop"),
        ]

        add(Tool(name: "project_create", description: "Create a new Cutline project (a .cutline folder holding the timeline, history, comments and analysis), open it in this session and, by default, in the preview app the human watches.", schema: Schema.object(canvasProps.merging([
            "path": Schema.string("Where to create the project; .cutline is appended if missing. Relative paths resolve against the working directory."),
            "name": Schema.string("Display name, default from the path"),
            "open_preview": Schema.bool("Open the preview app, default true"),
            "import": Schema.string("Start from another editor's timeline: an .fcpxml/.fcpxmld (Final Cut Pro), .otio (DaVinci Resolve, Premiere via OTIO) or .edl (CMX 3600) file"),
            "edl_fps": Schema.number("Frame rate of an EDL, default 30"),
        ]) { a, _ in a }, required: ["path"])) { [unowned self] args in
            var url = session.resolve(try args.string("path"))
            if url.pathExtension != ProjectBundle.fileExtension { url.appendPathExtension(ProjectBundle.fileExtension) }
            var canvas = Canvas()
            try Toolbox.applyCanvas(&canvas, args)
            let name = args.optString("name") ?? url.deletingPathExtension().lastPathComponent
            var project = Project(name: name, canvas: canvas)
            var notes: [String] = []
            if let source = args.optString("import") {
                let (imported, report) = try await importTimeline(session.resolve(source), name: name, edlFps: args.optDouble("edl_fps") ?? 30)
                project = imported
                notes = report
            }
            try ProjectBundle.create(at: url, project: project)
            let b = try session.open(url)
            var msg = "Created \(url.path)\n" + (notes.isEmpty ? "" : notes.joined(separator: "\n") + "\n")
            if args.bool("open_preview", default: true) { msg += try session.openPreview() + "\n" }
            return .text(msg + Describe.project(try b.loadProject(), bundle: b))
        })

        add(Tool(name: "project_open", description: "Open an existing .cutline project for this session.", schema: Schema.object([
            "path": Schema.string("Path to the .cutline folder"),
            "open_preview": Schema.bool("Also open it in the preview app, default false"),
        ], required: ["path"])) { [unowned self] args in
            var url = session.resolve(try args.string("path"))
            if !ProjectBundle.isBundle(url), url.pathExtension != ProjectBundle.fileExtension { url.appendPathExtension(ProjectBundle.fileExtension) }
            let b = try session.open(url)
            var msg = ""
            if args.bool("open_preview", default: false) { msg = try session.openPreview() + "\n" }
            if !session.resumed.isEmpty { msg += "Resumed analysis an exited server left unfinished: " + session.resumed.joined(separator: ", ") + " (analysis_read wait:300 blocks until done)\n" }
            return .text(msg + Describe.project(try b.loadProject(), bundle: b))
        })

        add(Tool(name: "project_status", description: "Describe the open project: canvas, media and their analysis, every track and clip with timeline and source times, effects, animation, captions, open comments, and warnings such as gaps or flash frames. Call it before editing and whenever you are unsure of ids or times. target=<clip id> lists every parameter path of that clip with its value and animation keys. detail=json returns the raw project.json.", schema: Schema.object([
            "target": Schema.string("A clip id, to list its parameters"),
            "detail": Schema.string("summary (default) or json", values: ["summary", "json"]),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            let p = try b.loadProject()
            if let id = args.optString("target") {
                guard let c = p.clip(id) else { throw EditError("No clip \(id)") }
                if args.optString("detail") == "json" { return .text(String(data: try ProjectBundle.encoder.encode(c), encoding: .utf8) ?? "") }
                return .text(Describe.clipParams(c, p))
            }
            if args.optString("detail") == "json" {
                return .text(String(data: try ProjectBundle.encoder.encode(p), encoding: .utf8) ?? "")
            }
            return .text(Describe.project(p, bundle: b, mix: try? session.measuredMix[session.stems().masterKey(for: p)]) + (session.jobs.statusLine.map { "\n" + $0 } ?? ""))
        })

        addEdit(EditTool(name: "canvas_set", description: "Change the canvas size, frame rate or background. Media clips refit automatically; text and captions scale with the canvas. A new frame rate conforms the timeline: cuts, sound edges, transitions, markers, keyframes and caption offsets snap to the new frame grid (cuts that met still meet), or keep their frame counts with conform:\"keep_frames\".", schema: Schema.object(canvasProps.merging([
            "conform": Schema.string("With fps: snap (default) moves every time to the nearest new frame and keeps the edit's length; keep_frames keeps frame counts, like a sequence frame-rate change, so the edit runs longer or shorter", values: FrameRateConform.allCases.map(\.rawValue)),
        ]) { a, _ in a }), label: { a, _ in a.optString("preset").map { "Make it \($0)" } ?? "Change canvas" }) { p, args in
            let mode = try args.enumValue("conform", FrameRateConform.self) ?? .snap
            let old = p.canvas.fps
            try Toolbox.applyCanvas(&p.canvas, args)
            var lines = ["Canvas is \(p.canvas.width)×\(p.canvas.height) @\(Describe.fmtFps(p.canvas.fps))fps"]
            if abs(old - p.canvas.fps) > 1e-3 {
                lines.append(p.conformFrameRate(from: old, mode: mode).summary)
            }
            return lines.joined(separator: "\n")
        })

        add(Tool(name: "history", description: "The edit history: list entries, undo or redo, jump to any entry, diff two versions, or fork the project into a separate copy (same media, own history) to explore an alternative cut. Every edit is one entry. A new edit after undo discards the undone entries.", schema: Schema.object([
            "action": Schema.string("list (default), undo, redo, restore, diff, fork", values: ["list", "undo", "redo", "restore", "diff", "fork"]),
            "path": Schema.string("For fork: where the copy goes (a .cutline folder); it becomes the open project"),
            "steps": Schema.integer("For undo/redo, default 1"),
            "id": Schema.string("For restore: the entry to jump to. For diff: the version to compare against the current one"),
            "limit": Schema.integer("For list, default 20"),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            switch args.optString("action") ?? "list" {
            case "undo", "redo":
                let undo = args.optString("action") == "undo"
                var names: [String] = []
                var p = try b.loadProject()
                for _ in 0..<max(1, args.optInt("steps") ?? 1) {
                    let h = b.loadHistory()
                    guard undo ? h.canUndo : h.canRedo else { break }
                    let (proj, e) = undo ? try b.undo() : try b.redo()
                    p = proj
                    names.append(e.label)
                }
                guard !names.isEmpty else { return .text(undo ? "Nothing to undo." : "Nothing to redo.") }
                return .text((undo ? "Undid: " : "Redid: ") + names.joined(separator: ", ") + "\n" + footer(p))
            case "fork":
                let dest = session.resolve(try args.string("path"))
                guard dest.pathExtension == "cutline" else { throw EditError("Fork paths end in .cutline") }
                guard !FileManager.default.fileExists(atPath: dest.path) else { throw EditError("\(dest.path) already exists") }
                try FileManager.default.copyItem(at: b.url, to: dest)
                try? FileManager.default.removeItem(at: dest.appendingPathComponent("comments.json"))
                try? FileManager.default.removeItem(at: dest.appendingPathComponent("jobs.json"))
                let nb = try session.open(dest)
                var p = try nb.loadProject()
                p.name += " (fork)"
                try nb.commit(p, label: "Fork of \(b.url.lastPathComponent)")
                _ = try? session.openPreview()
                return .text("Forked to \(dest.path) and opened it; \(b.url.lastPathComponent) is unchanged. project_open switches back.\n" + footer(p))
            case "restore":
                let id = try args.string("id")
                let p = try b.checkout(id)
                return .text("Restored \(id)\n" + footer(p))
            case "diff":
                let id = try args.string("id")
                let old = try b.snapshot(id)
                let now = try b.loadProject()
                let lines = now.changes(from: old)
                return .text(lines.isEmpty ? "No differences from \(id)." : "Changes since \(id):\n" + lines.map { "  " + $0 }.joined(separator: "\n"))
            default:
                let h = b.loadHistory()
                let limit = args.optInt("limit") ?? 20
                let lines = h.entries.enumerated().suffix(limit).map { i, e in
                    (i == h.cursor ? "→ " : "  ") + "\(e.id)  \(e.label)  \(ISO8601DateFormatter().string(from: e.createdAt))"
                }
                return .text((lines + (h.canRedo ? ["(entries after → can be redone; a new edit discards them)"] : [])).joined(separator: "\n"))
            }
        })

        add(Tool(name: "preview_seek", description: "Control the human's preview: open the app, move the playhead, or play a range so they can review a specific edit.", schema: Schema.object([
            "open": Schema.bool("Open (or bring forward) the preview app"),
            "time": Schema.time("Timeline time or anchor to show"),
            "play": Schema.bool("Start playback, default false"),
            "end": Schema.time("Stop playback here; implies play"),
        ])) { [unowned self] args in
            var lines: [String] = []
            if args.bool("open", default: false) { lines.append(try session.openPreview()) }
            if let t = try args.optTime("time") {
                var info: [String: Any] = ["action": "seek", "time": t, "play": args.bool("play", default: false) || args.has("end")]
                if let end = try args.optTime("end") { info["end"] = end }
                try session.sendPreview(info)
                lines.append("Preview at \(Frames.timecode(t))" + (args.has("end") ? ", playing to \(Frames.timecode(try args.time("end")))" : ""))
            }
            guard !lines.isEmpty else { throw EditError("Pass open:true and/or time") }
            return .text(lines.joined(separator: "\n"))
        })

        add(Tool(name: "preview_state", description: "Where the human's preview playhead is and whether it is playing. Use it when the human says \"here\" or \"this part\".", schema: Schema.object([:])) { [unowned self] _ in
            let b = try session.requireBundle()
            let url = b.url.appendingPathComponent("preview.json")
            guard let data = try? Data(contentsOf: url), let j = try? JSONDecoder().decode(JSON.self, from: data) else {
                return .text("The preview app has not reported a playhead yet. Is it open? Call preview_open.")
            }
            return .text(j.encoded(pretty: true))
        })
    }

    static func applyCanvas(_ c: inout Canvas, _ args: Args) throws {
        if let preset = try args.enumValue("preset", CanvasPreset.self) {
            (c.width, c.height) = preset.size
        }
        if let w = args.optInt("width") { c.width = w }
        if let h = args.optInt("height") { c.height = h }
        if let f = args.optDouble("fps") { c.fps = f }
        if let bg = try args.color("background") { c.background = bg }
        if let cs = try args.enumValue("color_space", WorkingSpace.self) { c.colorSpace = cs }
        guard c.fps >= 1, c.fps <= 240 else { throw EditError("fps must be between 1 and 240") }
        if let df = args.optBool("drop_frame") { c.dropFrame = df }
        if let tc = args.optString("timecode_start") {
            let format = c.timecodeFormat
            guard let frames = format.frames(tc) else { throw EditError("timecode_start is hh:mm:ss:ff, e.g. 01:00:00:00, with frames below \(format.nominal)") }
            c.timecodeStart = format.string(frames)
        }
        guard c.width >= 16, c.height >= 16, c.width <= 8192, c.height <= 8192 else { throw EditError("Canvas must be between 16 and 8192 pixels") }
        guard c.fps >= 1, c.fps <= 240 else { throw EditError("fps must be between 1 and 240") }
        c.width -= c.width % 2
        c.height -= c.height % 2
    }
}

extension Toolbox {
    /// Reads another editor's timeline and swaps in real media details from the files it points at.
    func importTimeline(_ file: URL, name: String, edlFps: Double) async throws -> (Project, [String]) {
        var source = file
        if file.pathExtension == "fcpxmld" { source = file.appendingPathComponent("Info.fcpxml") }
        guard let data = try? Data(contentsOf: source) else { throw EditError("Cannot read \(file.path)") }
        let base = file.deletingLastPathComponent()
        var result: ImportResult
        switch file.pathExtension.lowercased() {
        case "xml" where String(decoding: data.prefix(4096), as: UTF8.self).contains("<xmeml"): result = try Importer.xmeml(data, relativeTo: base)
        case "fcpxml", "fcpxmld", "xml": result = try Importer.fcpxml(data, relativeTo: base)
        case "otio": result = try Importer.otio(data, relativeTo: base)
        case "edl":
            let text = String(decoding: data, as: UTF8.self)
            var media: [String: String] = [:]
            result = try Importer.edl(text, fps: edlFps) { ref in
                let candidates = [ref, base.appendingPathComponent(ref).path]
                guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return nil }
                if let known = media[path] { return known }
                let id = Toolbox.mediaId(for: URL(fileURLWithPath: path), existing: Set(media.values))
                media[path] = id
                return id
            }
        default: throw EditError("Import reads .fcpxml, .fcpxmld, .otio or .edl")
        }
        var p = result.project
        p.name = name
        var notes = ["Imported \(file.lastPathComponent): \(p.tracks.flatMap(\.clips).count) clips on \(p.tracks.count) tracks, \(p.media.count) media, \(fmt2(p.duration))s."]
        for i in p.media.indices where FileManager.default.fileExists(atPath: p.media[i].path) {
            if var real = try? await MediaProbe.probe(p.media[i].url, id: p.media[i].id) {
                real.name = p.media[i].name
                real.tags = p.media[i].tags
                real.reel = real.reel ?? p.media[i].reel
                p.replaceMediaKeepingTimecode(real)
            }
        }
        if !result.missingMedia.isEmpty { notes.append("Missing media (relink with media_import, then clip_update media_id): " + result.missingMedia.prefix(10).joined(separator: ", ")) }
        if !result.warnings.isEmpty { notes.append("Import notes: " + result.warnings.prefix(12).joined(separator: "; ") + (result.warnings.count > 12 ? "; …\(result.warnings.count - 12) more" : "")) }
        return (p, notes)
    }
}
