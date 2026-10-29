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
        ]

        add(Tool(name: "project_create", description: "Create a new Cutline project (a .cutline folder holding the timeline, history, comments and analysis), open it in this session and, by default, in the preview app the human watches.", schema: Schema.object(canvasProps.merging([
            "path": Schema.string("Where to create the project; .cutline is appended if missing. Relative paths resolve against the working directory."),
            "name": Schema.string("Display name, default from the path"),
            "open_preview": Schema.bool("Open the preview app, default true"),
        ]) { a, _ in a }, required: ["path"])) { [unowned self] args in
            var url = session.resolve(try args.string("path"))
            if url.pathExtension != ProjectBundle.fileExtension { url.appendPathExtension(ProjectBundle.fileExtension) }
            var canvas = Canvas()
            try Toolbox.applyCanvas(&canvas, args)
            let name = args.optString("name") ?? url.deletingPathExtension().lastPathComponent
            try ProjectBundle.create(at: url, project: Project(name: name, canvas: canvas))
            let b = try session.open(url)
            var msg = "Created \(url.path)\n"
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
            return .text(msg + Describe.project(try b.loadProject(), bundle: b))
        })

        add(Tool(name: "project_status", description: "Describe the open project: canvas, media and their analysis, every track and clip with timeline and source times, captions, open comments, and warnings such as gaps or flash frames. Call this before editing and whenever you are unsure of clip ids or times. detail=json returns the raw project.json.", schema: Schema.object([
            "detail": Schema.string("summary (default) or json", values: ["summary", "json"]),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            let p = try b.loadProject()
            if args.optString("detail") == "json" {
                return .text(String(data: try ProjectBundle.encoder.encode(p), encoding: .utf8) ?? "")
            }
            return .text(Describe.project(p, bundle: b))
        })

        addEdit(EditTool(name: "canvas_set", description: "Change the canvas size, frame rate or background. Media clips refit automatically; text and captions scale with the canvas.", schema: Schema.object(canvasProps), label: { a, _ in a.optString("preset").map { "Make it \($0)" } ?? "Change canvas" }) { p, args in
            try Toolbox.applyCanvas(&p.canvas, args)
            return "Canvas is \(p.canvas.width)×\(p.canvas.height) @\(Describe.fmtFps(p.canvas.fps))fps"
        })

        add(Tool(name: "history", description: "List recent edit history. Every edit is one entry; undo, redo and history_restore move between them.", schema: Schema.object([
            "limit": Schema.integer("Entries to show, default 20"),
        ])) { [unowned self] args in
            let h = try session.requireBundle().loadHistory()
            let limit = args.optInt("limit") ?? 20
            let lines = h.entries.enumerated().suffix(limit).map { i, e in
                (i == h.cursor ? "→ " : "  ") + "\(e.id)  \(e.label)  \(ISO8601DateFormatter().string(from: e.createdAt))"
            }
            return .text((lines + (h.canRedo ? ["(entries after → can be redone; a new edit discards them)"] : [])).joined(separator: "\n"))
        })

        add(Tool(name: "undo", description: "Undo the last edit(s).", schema: Schema.object(["steps": Schema.integer("How many edits to undo, default 1")])) { [unowned self] args in
            let b = try session.requireBundle()
            var undone: [String] = []
            var p = try b.loadProject()
            for _ in 0..<max(1, args.optInt("steps") ?? 1) {
                guard b.loadHistory().canUndo else { break }
                let (proj, e) = try b.undo()
                p = proj
                undone.append(e.label)
            }
            guard !undone.isEmpty else { return .text("Nothing to undo.") }
            return .text("Undid: " + undone.joined(separator: ", ") + "\n" + footer(p))
        })

        add(Tool(name: "redo", description: "Redo edit(s) that were undone.", schema: Schema.object(["steps": Schema.integer("How many edits to redo, default 1")])) { [unowned self] args in
            let b = try session.requireBundle()
            var redone: [String] = []
            var p = try b.loadProject()
            for _ in 0..<max(1, args.optInt("steps") ?? 1) {
                guard b.loadHistory().canRedo else { break }
                let (proj, e) = try b.redo()
                p = proj
                redone.append(e.label)
            }
            guard !redone.isEmpty else { return .text("Nothing to redo.") }
            return .text("Redid: " + redone.joined(separator: ", ") + "\n" + footer(p))
        })

        add(Tool(name: "history_restore", description: "Jump to any history entry by id (from history). Later entries stay available to redo until the next edit.", schema: Schema.object(["id": Schema.string("History entry id")], required: ["id"])) { [unowned self] args in
            let p = try session.requireBundle().checkout(try args.string("id"))
            return .text("Restored \(try args.string("id"))\n" + footer(p))
        })

        add(Tool(name: "preview_open", description: "Open the project in the Cutline preview app so the human can watch, scrub and leave comments.", schema: Schema.object([:])) { [unowned self] _ in
            .text(try session.openPreview())
        })

        add(Tool(name: "preview_seek", description: "Move the human's preview playhead, optionally playing a range so they can review a specific edit.", schema: Schema.object([
            "time": Schema.time("Timeline time to show"),
            "play": Schema.bool("Start playback, default false"),
            "end": Schema.time("Stop playback here; implies play"),
        ], required: ["time"])) { [unowned self] args in
            let t = try args.time("time")
            var info: [String: Any] = ["action": "seek", "time": t, "play": args.bool("play", default: false) || args.has("end")]
            if let end = try args.optTime("end") { info["end"] = end }
            try session.sendPreview(info)
            return .text("Preview seeking to \(Frames.timecode(t))" + (args.has("end") ? " and playing to \(Frames.timecode(try args.time("end")))" : ""))
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
        guard c.width >= 16, c.height >= 16, c.width <= 8192, c.height <= 8192 else { throw EditError("Canvas must be between 16 and 8192 pixels") }
        guard c.fps >= 1, c.fps <= 240 else { throw EditError("fps must be between 1 and 240") }
        c.width -= c.width % 2
        c.height -= c.height % 2
    }
}
