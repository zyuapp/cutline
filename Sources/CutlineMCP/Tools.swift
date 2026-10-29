import CutlineCore
import CutlineEngine
import Foundation

struct ToolResult {
    var content: [JSON] = []
    var isError = false

    static func text(_ s: String) -> ToolResult { ToolResult(content: [["type": "text", "text": .string(s)]]) }

    mutating func addText(_ s: String) { content.append(["type": "text", "text": .string(s)]) }

    mutating func addImage(_ data: Data, mime: String = "image/jpeg") {
        content.append(["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mime)])
    }

    var json: JSON { ["content": .array(content), "isError": .bool(isError)] }

    var plainText: String { content.compactMap { $0["text"]?.string }.joined(separator: "\n") }
}

struct Tool {
    let name: String
    let description: String
    let schema: JSON
    let run: (Args) async throws -> ToolResult

    var definition: JSON {
        ["name": .string(name), "description": .string(description), "inputSchema": schema]
    }
}

/// An edit that can run alone or inside `batch`. Returns a one-line summary.
struct EditTool {
    let name: String
    let description: String
    let schema: JSON
    let label: (Args, Project) -> String
    let apply: (inout Project, Args) throws -> String
}

final class Toolbox {
    let session = Session()
    private(set) var tools: [String: Tool] = [:]
    private(set) var order: [String] = []
    private(set) var edits: [String: EditTool] = [:]

    init() {
        registerProjectTools()
        registerMediaTools()
        registerEditTools()
        registerLookTools()
        registerTransitionTools()
        registerTrimTool()
        registerPatchTool()
        registerTemplateTool()
        registerNestTool()
        registerTrackTool()
        registerAnalysisTools()
        registerExportTools()
        registerAudioTools()
        registerBatchTool()
        registerReviewTools()
    }

    func add(_ tool: Tool) {
        tools[tool.name] = tool
        order.append(tool.name)
    }

    func addEdit(_ e: EditTool) {
        edits[e.name] = e
        add(Tool(name: e.name, description: e.description, schema: Toolbox.withDryRun(e.schema)) { [unowned self] args in
            let before = try session.project()
            if args.bool("dry_run", default: false) {
                var p = before
                let summary = try e.apply(&p, args)
                p.pruneTransitions()
                try p.validate()
                return .text("Dry run, nothing changed.\n" + summary + Toolbox.changesText(p, before))
            }
            var summary = ""
            let p = try session.edit(e.label(args, before)) { summary = try e.apply(&$0, args) }
            let analyzed = try await self.session.analyzeMotion(p)
            if !analyzed.isEmpty { try? self.session.sendPreview(["action": "rebuild"]) }
            return .text(summary + Toolbox.changesText(p, before) + self.newIssues(p, before) + (analyzed.isEmpty ? "" : "\nAnalyzed camera motion of " + analyzed.joined(separator: ", ")) + "\n" + self.footer(p))
        })
    }

    static func withDryRun(_ schema: JSON) -> JSON {
        guard case .object(var o) = schema, case .object(var props)? = o["properties"] else { return schema }
        props["dry_run"] = Schema.bool("Report what would change without applying it")
        o["properties"] = .object(props)
        return .object(o)
    }

    /// The structural diff of an edit, capped so responses stay small.
    static func changesText(_ p: Project, _ before: Project) -> String {
        let lines = p.changes(from: before)
        guard !lines.isEmpty else { return "\nNo changes." }
        let shown = lines.prefix(14).map { "  " + $0 }
        return "\nChanges:\n" + shown.joined(separator: "\n") + (lines.count > 14 ? "\n  …and \(lines.count - 14) more" : "")
    }

    /// Lets time arguments use anchors ("talk.w12", "clip_x.end", "marker:Intro") for this project state.
    func installResolvers(_ p: Project?) {
        guard let p, let b = session.bundle else {
            Args.timelineResolver = nil
            Args.sourceResolver = nil
            return
        }
        let transcripts = b.transcripts(for: p)
        let index = b.anchorIndex(for: p)
        Args.timelineResolver = { try p.resolveTime($0, transcripts: transcripts, index: index) }
        Args.sourceResolver = { try p.resolveSourceTime($0, transcripts: transcripts, index: index) }
    }

    var definitions: [JSON] { order.compactMap { tools[$0]?.definition } }

    func call(_ name: String, _ args: JSON?) async -> ToolResult {
        guard let tool = tools[name] else {
            var r = ToolResult.text("Unknown tool \(name)")
            r.isError = true
            return r
        }
        do {
            installResolvers(try? session.project())
            return try await tool.run(Args(args))
        } catch {
            var r = ToolResult.text("Error: \(error.localizedDescription)")
            r.isError = true
            return r
        }
    }

    /// Short state line appended to edit results.
    func footer(_ p: Project) -> String {
        let h = session.bundle?.loadHistory().current
        return "Timeline \(Frames.timecode(p.duration)) · \(p.tracks.map { "\($0.id):\($0.clips.count)" }.joined(separator: " ")) · history \(h?.id ?? "-")" + (session.jobs.statusLine.map { " · " + $0 } ?? "")
    }
}

// MARK: Formatting

enum Describe {
    static func project(_ p: Project, bundle: ProjectBundle) -> String {
        var lines: [String] = []
        let history = bundle.loadHistory()
        lines.append("Project \"\(p.name)\" at \(bundle.url.path)")
        lines.append("Canvas \(p.canvas.width)×\(p.canvas.height) @\(fmtFps(p.canvas.fps))fps, background \(p.canvas.background.hex), duration \(Frames.timecode(p.duration)) (\(fmt(p.duration))s)")
        if let cur = history.current { lines.append("History \(cur.id) \"\(cur.label)\" (\(history.cursor + 1)/\(history.entries.count))") }
        lines.append("")
        lines.append("Media:")
        if p.media.isEmpty { lines.append("  (none — call media_import)") }
        for m in p.media {
            var a: [String] = []
            if let t = bundle.transcript(m.id) { a.append("transcript \(t.words.count) words") }
            if let au = bundle.audioAnalysis(m.id) { a.append("\(au.silences.filter { $0.duration >= 0.5 }.count) pauses") }
            if let v = bundle.visualAnalysis(m.id), !v.sceneCuts.isEmpty { a.append("\(v.sceneCuts.count) scene cuts") }
            let kind = m.isImage ? "image" : [m.hasVideo ? "video" : nil, m.hasAudio ? "audio" : nil].compactMap { $0 }.joined(separator: "+")
            let dims = m.hasVideo ? " \(m.width)×\(m.height)" + (m.isImage ? "" : " \(fmtFps(m.fps))fps") : ""
            let missing = FileManager.default.fileExists(atPath: m.path) ? "" : " MISSING FILE"
            lines.append("  \(m.id): \(kind)\(dims)" + (m.isImage ? "" : " \(fmt(m.duration))s") + (a.isEmpty ? "" : " · " + a.joined(separator: ", ")) + missing)
        }
        lines.append("")
        lines.append("Tracks (listed top layer first):")
        for t in p.tracks.reversed() {
            var flags: [String] = []
            if t.muted { flags.append("muted") }
            if t.hidden { flags.append("hidden") }
            if t.volume != 1 { flags.append("vol \(fmt2(t.volume))") }
            let fx = t.effects.isEmpty ? "" : " fx " + t.effects.map { "\($0.id)(\($0.type))" }.joined(separator: " → ")
            lines.append("  \(t.id) \(t.kind.rawValue) \"\(t.name)\"\(flags.isEmpty ? "" : " [" + flags.joined(separator: ", ") + "]"): \(t.clips.count) clips\(fx)")
            for c in t.clips { lines.append("    " + clip(c, p)) }
        }
        lines.append("")
        let cs = p.captions
        if p.master.gainDb != 0 || !p.master.effects.isEmpty {
            lines.append("Master: gain \(fmt1(p.master.gainDb)) dB" + (p.master.effects.isEmpty ? "" : ", fx " + p.master.effects.map { "\($0.id)(\($0.type))" }.joined(separator: " → ")))
        }
        lines.append("Captions: " + (cs.enabled ? "on, \(cs.style.animation.rawValue), size \(fmt2(cs.style.size)), y \(fmt2(cs.style.y)), \(cs.style.maxWordsPerLine) words/line" : "off"))
        if !p.transitions.isEmpty { lines.append("Transitions: " + p.transitions.map { "\($0.id) \($0.type) \(fmt2($0.duration))s \($0.from ?? "∅")→\($0.to ?? "∅")" }.joined(separator: ", ")) }
        if !p.markers.isEmpty { lines.append("Markers: " + p.markers.map { "\(fmt2($0.time)) \($0.label)" }.joined(separator: ", ")) }
        let open = bundle.loadComments().comments.filter { $0.status == .open }
        lines.append("Comments: \(open.count) open" + (open.isEmpty ? "" : " — call comments_list"))
        let w = warnings(p, transcripts: bundle.transcripts(for: p))
        if !w.isEmpty {
            lines.append("")
            lines.append("Warnings:")
            lines += w.map { "  - " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    static func clip(_ c: Clip, _ p: Project) -> String {
        var s = "\(c.id)  \(fmt(c.start))–\(fmt(c.end))  "
        switch c.kind {
        case .media:
            s += "\(c.mediaId ?? "?")"
            if let m = c.mediaId.flatMap(p.mediaAsset), !m.isImage { s += " [src \(fmt(c.sourceIn))–\(fmt(c.sourceOut))]" }
        case .text: s += "text \"\(c.text?.text.prefix(40) ?? "")\""
        case .solid: s += "solid \(c.color?.hex ?? "")"
        case .adjustment: s += "adjustment layer"
        case .generator: s += "generator " + (c.effects.first.map(\.type) ?? "?")
        case .sequence:
            let seq = c.mediaId.flatMap { p.sequence($0) }
            s += "nested \"\(seq?.name ?? "?")\" [\(fmt(c.sourceIn))–\(fmt(c.sourceIn + c.duration)) of \(fmt(seq?.duration ?? 0))s, \(seq?.tracks.flatMap(\.clips).count ?? 0) clips]"
        }
        var extra: [String] = []
        if c.speed != 1 { extra.append("speed \(fmt2(c.speed))") }
        if c.volume != 1 { extra.append("vol \(fmt2(c.volume))") }
        if c.fadeIn > 0 || c.fadeOut > 0 { extra.append("fade \(fmt2(c.fadeIn))/\(fmt2(c.fadeOut))") }
        if c.audioFadeIn > 0 || c.audioFadeOut > 0 { extra.append("audio fade \(fmt2(c.audioFadeIn))/\(fmt2(c.audioFadeOut))") }
        if c.audioLead != 0 { extra.append("audio leads \(fmt2(c.audioLead))s") }
        if c.audioLag != 0 { extra.append("audio lags \(fmt2(c.audioLag))s") }
        let t = c.transform
        if t != Transform() {
            var parts: [String] = []
            if t.fit != .fit { parts.append(t.fit.rawValue) }
            if t.scale != 1 { parts.append("scale \(fmt2(t.scale))") }
            if t.x != 0 || t.y != 0 { parts.append("pos \(fmt2(t.x)),\(fmt2(t.y))") }
            if t.rotation != 0 { parts.append("rot \(fmt1(t.rotation))°") }
            if t.opacity != 1 { parts.append("opacity \(fmt2(t.opacity))") }
            if !t.crop.isEmpty { parts.append("crop") }
            extra.append(parts.joined(separator: " "))
        }
        if c.blend != .normal { extra.append("blend \(c.blend.rawValue)") }
        if !c.effects.isEmpty { extra.append("fx " + c.effects.map { $0.enabled ? $0.id : "\($0.id)(off)" }.joined(separator: ",")) }
        if !c.anim.isEmpty { extra.append("animates " + c.anim.keys.sorted().joined(separator: ",")) }
        return s + (extra.isEmpty ? "" : "  (" + extra.joined(separator: ", ") + ")")
    }

    /// Every parameter of one clip, for project_status with a target.
    static func clipParams(_ c: Clip, _ p: Project) -> String {
        var lines = ["\(clip(c, p))", "Parameters (set with param_set; animated values show their keys):"]
        for (path, value, keys) in c.parameterTree() {
            var line = "  \(path) = \(value)"
            if keys > 0, let curve = c.anim[path] {
                line += "  animated: " + curve.keys.prefix(8).map { "\(fmt2($0.t))s→\($0.v)\($0.ease == .easeInOut ? "" : " " + $0.ease.rawValue)" }.joined(separator: ", ")
                if curve.keys.count > 8 { line += " …(\(curve.keys.count) keys)" }
            }
            lines.append(line)
        }
        if c.effects.isEmpty { lines.append("Effects: none (effect_add to add; catalog lists types)") }
        else { lines.append("Effects, applied in order: " + c.effects.map { "\($0.id) \($0.type)\($0.enabled ? "" : " (off)")" }.joined(separator: " → ")) }
        lines.append("Key times are seconds from the clip start (\(fmt2(c.start)) on the timeline).")
        return lines.joined(separator: "\n")
    }

    static func warnings(_ p: Project, transcripts: [String: Transcript] = [:]) -> [String] {
        var out = p.qualityIssues(transcripts: transcripts)
        for m in p.media where !FileManager.default.fileExists(atPath: m.path) { out.append("media \(m.id) is missing at \(m.path)") }
        return out
    }

    /// Sentences from words, breaking on punctuation and long gaps.
    struct Sentence<W> {
        var start: Seconds
        var end: Seconds
        var text: String
        var pauseAfter: Seconds?
        var first: W
        var last: W
    }

    /// Sentences from words, breaking on punctuation and long gaps.
    static func sentences<W>(_ words: [W], text: (W) -> String, start: (W) -> Seconds, end: (W) -> Seconds) -> [Sentence<W>] {
        var out: [Sentence<W>] = []
        var cur: [W] = []
        func flush(gapAfter: Seconds?) {
            guard let f = cur.first, let l = cur.last else { return }
            out.append(Sentence(start: start(f), end: end(l), text: cur.map(text).joined(separator: " "), pauseAfter: gapAfter, first: f, last: l))
            cur = []
        }
        for (i, w) in words.enumerated() {
            cur.append(w)
            let next = i + 1 < words.count ? words[i + 1] : nil
            let gap = next.map { start($0) - end(w) }
            let endsSentence = text(w).last.map { ".?!".contains($0) } ?? false
            if next == nil || endsSentence || (gap ?? 0) > 0.7 || cur.count >= 30 {
                flush(gapAfter: gap.flatMap { $0 > 0.4 ? $0 : nil })
            }
        }
        return out
    }

    static func fmtFps(_ f: Double) -> String { f.rounded() == f ? String(Int(f)) : String(format: "%.3f", f) }
}

extension Toolbox {
    /// Issues an edit introduced, for the edit's response.
    func newIssues(_ p: Project, _ before: Project) -> String {
        guard let b = session.bundle else { return "" }
        let tr = b.transcripts(for: p)
        let fresh = Set(p.qualityIssues(transcripts: tr)).subtracting(before.qualityIssues(transcripts: b.transcripts(for: before)))
        guard !fresh.isEmpty else { return "" }
        return "\nCheck: " + fresh.sorted().prefix(5).joined(separator: "; ")
    }
}
