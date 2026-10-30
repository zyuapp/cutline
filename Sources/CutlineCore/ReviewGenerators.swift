import Foundation

/// End credits and timecode burn-ins.
extension GeneratorCatalog {
    static let sampleCredits = """
    # CUTLINE

    ## Directed by
    Ada Lovelace

    ## Cast
    The Captain | Grace Hopper
    The Engineer | Alan Turing

    ## Music
    Clara Schumann
    """

    static let review: [EffectType] = [
        EffectType(id: "credits", category: "generator", summary: "End credits that roll up (or crawl sideways) over the clip's duration, so the clip's length sets the speed: \"# Title\", \"## Heading\", \"Role | Name\" two-column rows and centered name lines, or a JSON list [{\"title\"}, {\"heading\", \"rows\": [[role, name]], \"names\": [...]}]; end_hold holds the last lines centered", params: [
            text("text", sampleCredits, "Credits: one entry per line. \"# Title\" big title, \"## Heading\" section heading, \"Role | Name\" a row with the role right of center-left and the name left-aligned, any other line a centered name, blank lines add space. Or a JSON list of sections {\"title\"}, {\"heading\", \"rows\": [[\"Role\", \"Name\"]], \"names\": [\"Name\"]}"),
            ParamSpec("mode", .choice(["roll", "crawl"]), .string("roll"), "roll: up the frame; crawl: one line right to left along y"),
            num("end_hold", 0, 0, 60, unit: "seconds", animatable: false, "Roll: stop with the last lines centered and hold them this long at the end; 0 rolls everything off the top"),
            num("progress", -1, -1, 1, "Position through the roll, 0 start to 1 end; -1 follows the clip's time"),
            len("size", 0.042, 0.3, "Name size"),
            len("heading_size", 0.032, 0.3, "Heading and role size"),
            len("title_size", 0.085, 0.5, "Title size"),
            num("line_spacing", 1.45, 0.8, 4, "Line height as a multiple of each line's size"),
            num("section_gap", 1.6, 0, 10, "Space before a heading or title, in name lines"),
            len("gutter", 0.03, 0.5, "Gap between the role and name columns"),
            pos("x", 0.5, "Column center, 0 left to 1 right"),
            pos("y", 0.88, "Crawl: vertical center"),
            font,
            text("heading_font", "", "Font of headings and roles; empty uses font"),
            num("weight", 500, 100, 900, animatable: false, "Name weight; headings are 600, titles 800"),
            color("color", "#FFFFFF", "Names and title"),
            color("heading_color", "#FFFFFFB3", "Headings"),
            color("role_color", "#FFFFFF99", "Roles"),
            color("background", "#00000000", "Fill behind the credits; transparent to roll over the picture"),
        ]),
        EffectType(id: "timecode_burn", category: "generator", summary: "Burn-in for review copies: record (timeline) timecode, source timecode, clip name, frame count, media name or reel of the picture below, in a box at a corner, plus an optional watermark", params: [
            text("show", "record", "Comma-separated fields in order: record, source, clip, frame, media, reel, e.g. \"record,source,clip\""),
            ParamSpec("position", .choice(["top_left", "top", "top_right", "bottom_left", "bottom", "bottom_right"]), .string("bottom"), "Where the burn-in sits"),
            text("source_track", "", "Track to read source timecode and names from; empty takes the topmost visible picture below"),
            text("label", "", "Text placed before the fields, e.g. a reviewer's name or \"DRAFT v3\""),
            len("size", 0.034, 0.2, "Text size"),
            len("margin", 0.035, 0.3, "Distance from the frame edge"),
            ParamSpec("font", .text, .string("mono"), "\"mono\" (default), \"system\", \"rounded\", \"serif\" or a font family name"),
            color("color", "#FFFFFF", "Text color"),
            color("box", "#000000A6", "Box behind the text; transparent for none"),
            text("watermark", "", "Large text across the picture, e.g. \"CONFIDENTIAL\" or a recipient's name"),
            len("watermark_size", 0.12, 1, "Watermark size"),
            num("watermark_opacity", 0.22, 0, 1, "Watermark opacity"),
            num("watermark_angle", -20, -90, 90, unit: "degrees", "Watermark rotation, clockwise"),
        ]),
    ]
}

/// The lines of a credits roll laid out top to bottom.
public enum Credits {
    public enum Kind: String, Sendable {
        case title, heading, row, name, space
    }

    public struct Line: Equatable, Sendable {
        public var kind: Kind
        /// Name, title or heading; for rows the name.
        public var text: String
        public var role: String = ""
        /// Top of the line from the top of the credits, in frame heights.
        public var top: Double = 0
        public var height: Double = 0
    }

    /// Credits text (lines or a JSON list) as entries.
    public static func parse(_ text: String) -> [Line] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            var out: [Line] = []
            for item in list {
                if let s = item as? String { out.append(Line(kind: .name, text: s)); continue }
                guard let d = item as? [String: Any] else { continue }
                if let t = d["title"] as? String { out.append(Line(kind: .title, text: t)) }
                if let h = d["heading"] as? String { out.append(Line(kind: .heading, text: h)) }
                for r in d["rows"] as? [Any] ?? [] {
                    if let pair = r as? [Any], pair.count >= 2 { out.append(Line(kind: .row, text: "\(pair[1])", role: "\(pair[0])")) }
                    else if let o = r as? [String: Any] { out.append(Line(kind: .row, text: "\(o["name"] ?? "")", role: "\(o["role"] ?? "")")) }
                }
                for n in d["names"] as? [Any] ?? [] { out.append(Line(kind: .name, text: "\(n)")) }
            }
            return out
        }
        return text.components(separatedBy: .newlines).map { raw in
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return Line(kind: .space, text: "") }
            if s.hasPrefix("## ") || s == "##" { return Line(kind: .heading, text: String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
            if s.hasPrefix("#") { return Line(kind: .title, text: String(s.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)) }
            if let bar = s.firstIndex(of: "|") {
                return Line(kind: .row, text: String(s[s.index(after: bar)...]).trimmingCharacters(in: .whitespaces), role: String(s[..<bar]).trimmingCharacters(in: .whitespaces))
            }
            return Line(kind: .name, text: s)
        }
    }

    /// Entries with their positions: each line `line_spacing` × its size tall, a section gap before headings and
    /// titles after the first line, blank lines half a name line. Returns the lines and the total height.
    public static func layout(_ lines: [Line], size: Double, headingSize: Double, titleSize: Double, spacing: Double, sectionGap: Double) -> (lines: [Line], height: Double) {
        var y = 0.0
        var out: [Line] = []
        for var l in lines {
            let s: Double
            switch l.kind {
            case .title: s = titleSize
            case .heading: s = headingSize
            case .row, .name: s = size
            case .space:
                y += size * spacing * 0.5
                continue
            }
            if (l.kind == .heading || l.kind == .title), !out.isEmpty { y += size * spacing * sectionGap }
            l.top = y
            l.height = s * spacing
            y += l.height
            out.append(l)
        }
        return (out, y)
    }

    /// Top of the credits in frame heights from the frame's top at `progress`: from just below the frame to fully
    /// above it, or with `hold`, to the last line centered.
    public static func rollTop(progress p: Double, height: Double, lastCenter: Double, hold: Bool) -> Double {
        let end = hold ? 0.5 - lastCenter : -height
        return 1 + (end - 1) * min(max(p, 0), 1)
    }

    /// How far through the roll a clip-local time is, with the last `endHold` seconds held at the end.
    public static func progress(time: Double, duration: Double, endHold: Double) -> Double {
        let moving = max(duration - max(endHold, 0), 1e-3)
        return min(max(time / moving, 0), 1)
    }
}

/// What a timecode burn-in shows at a timeline time.
public enum BurnIn {
    public static let fields = ["record", "source", "clip", "frame", "media", "reel"]

    /// The burn-in text of generator clip `clipId` at timeline time `t`: its fields read from the topmost visible
    /// media picture below it (or on `sourceTrack`), separated by wide spaces.
    public static func text(_ p: Project, clip clipId: String, at t: Seconds, show: String, label: String = "", sourceTrack: String = "") -> String {
        let fps = p.canvas.fps
        let format = p.canvas.timecodeFormat
        let below = source(p, clip: clipId, at: t, track: sourceTrack)
        var parts: [String] = label.isEmpty ? [] : [label]
        for f in show.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            switch f {
            case "record", "rec":
                let start = format.frames(p.canvas.startTimecode) ?? 0
                parts.append(format.string(start + format.frameCount(t)))
            case "source", "src":
                guard let (c, m) = below else { parts.append("--:--:--:--"); continue }
                let src = m.isImage ? 0 : c.sourceTime(atTimeline: t)
                parts.append("SRC " + m.timecodeFormat(fallback: fps).string(m.sourceFrames(at: src, fallback: fps)))
            case "clip", "name":
                parts.append(below.map { ($0.0.name ?? "").isEmpty ? $0.1.name : $0.0.name ?? "" } ?? "")
            case "media", "file":
                parts.append(below?.1.name ?? "")
            case "reel":
                parts.append(below?.1.reel ?? "")
            case "frame", "frames":
                parts.append(String(format: "FR %06d", format.frameCount(t)))
            default:
                continue
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "   ")
    }

    /// The media clip under the burn-in at `t`.
    static func source(_ p: Project, clip clipId: String, at t: Seconds, track: String) -> (Clip, MediaAsset)? {
        let video = p.tracks.enumerated().filter { $0.element.kind == .video }
        let own = video.first { $0.element.clips.contains { $0.id == clipId } }?.offset ?? p.tracks.count
        let candidates = track.isEmpty ? video.filter { $0.offset < own && !$0.element.hidden }.reversed().map(\.element) : p.tracks.filter { $0.id == track }
        for tr in candidates {
            guard let c = tr.clip(at: t), c.kind == .media, let m = c.mediaId.flatMap({ p.mediaAsset($0) }), m.hasVideo else { continue }
            return (c, m)
        }
        return nil
    }
}
