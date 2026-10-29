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
        registerReviewTools()
    }

    func add(_ tool: Tool) {
        tools[tool.name] = tool
        order.append(tool.name)
    }

    func addEdit(_ e: EditTool) {
        edits[e.name] = e
        add(Tool(name: e.name, description: e.description, schema: e.schema) { [unowned self] args in
            var summary = ""
            let p = try session.edit(e.label(args, try session.project())) { summary = try e.apply(&$0, args) }
            return .text(summary + "\n" + self.footer(p))
        })
    }

    var definitions: [JSON] { order.compactMap { tools[$0]?.definition } }

    func call(_ name: String, _ args: JSON?) async -> ToolResult {
        guard let tool = tools[name] else {
            var r = ToolResult.text("Unknown tool \(name)")
            r.isError = true
            return r
        }
        do {
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
        return "Timeline \(Frames.timecode(p.duration)) · \(p.tracks.map { "\($0.id):\($0.clips.count)" }.joined(separator: " ")) · history \(h?.id ?? "-")"
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
            lines.append("  \(t.id) \(t.kind.rawValue) \"\(t.name)\"\(flags.isEmpty ? "" : " [" + flags.joined(separator: ", ") + "]"): \(t.clips.count) clips")
            for c in t.clips { lines.append("    " + clip(c, p)) }
        }
        lines.append("")
        let cs = p.captions
        lines.append("Captions: " + (cs.enabled ? "on, \(cs.style.animation.rawValue), size \(fmt2(cs.style.size)), y \(fmt2(cs.style.y)), \(cs.style.maxWordsPerLine) words/line" : "off"))
        if !p.markers.isEmpty { lines.append("Markers: " + p.markers.map { "\(fmt2($0.time)) \($0.label)" }.joined(separator: ", ")) }
        let open = bundle.loadComments().comments.filter { $0.status == .open }
        lines.append("Comments: \(open.count) open" + (open.isEmpty ? "" : " — call comments_list"))
        let w = warnings(p)
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
        }
        var extra: [String] = []
        if c.speed != 1 { extra.append("speed \(fmt2(c.speed))") }
        if c.volume != 1 { extra.append("vol \(fmt2(c.volume))") }
        if c.fadeIn > 0 || c.fadeOut > 0 { extra.append("fade \(fmt2(c.fadeIn))/\(fmt2(c.fadeOut))") }
        if c.audioFadeIn > 0 || c.audioFadeOut > 0 { extra.append("audio fade \(fmt2(c.audioFadeIn))/\(fmt2(c.audioFadeOut))") }
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
        if !c.keyframes.isEmpty { extra.append("\(c.keyframes.count) keyframes") }
        return s + (extra.isEmpty ? "" : "  (" + extra.joined(separator: ", ") + ")")
    }

    static func warnings(_ p: Project) -> [String] {
        var out: [String] = []
        if let main = p.tracks.first(where: { $0.kind == .video && !$0.clips.isEmpty }) {
            var cursor = 0.0
            for c in main.clips {
                if c.start - cursor > 0.02 { out.append("gap on \(main.id) at \(fmt2(cursor))–\(fmt2(c.start)) shows background") }
                cursor = c.end
            }
        }
        for t in p.tracks {
            for c in t.clips where c.duration < 0.25 && c.kind == .media {
                out.append("\(c.id) on \(t.id) is only \(fmt2(c.duration))s, likely a flash frame")
            }
        }
        let pictureEnd = p.tracks.filter { $0.kind == .video }.map(\.end).max() ?? 0
        for t in p.tracks where t.kind == .audio {
            if let last = t.clips.last, pictureEnd > 0, last.end > pictureEnd + 0.5 {
                out.append("\(last.id) on \(t.id) runs \(fmt2(last.end - pictureEnd))s past the picture; trim it or fade it out")
            }
        }
        for m in p.media where !FileManager.default.fileExists(atPath: m.path) { out.append("media \(m.id) is missing at \(m.path)") }
        return out
    }

    /// Sentences from words, breaking on punctuation and long gaps.
    static func sentences<W>(_ words: [W], text: (W) -> String, start: (W) -> Seconds, end: (W) -> Seconds) -> [(Seconds, Seconds, String, Seconds?)] {
        var out: [(Seconds, Seconds, String, Seconds?)] = []
        var cur: [W] = []
        func flush(gapAfter: Seconds?) {
            guard let f = cur.first, let l = cur.last else { return }
            out.append((start(f), end(l), cur.map(text).joined(separator: " "), gapAfter))
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
