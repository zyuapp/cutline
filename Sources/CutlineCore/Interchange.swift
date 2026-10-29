import Foundation

/// Frames of exactly `num/den` seconds, e.g. 1001/30000 for 29.97 fps and 100/3000 for 30 fps.
struct FrameGrid: Equatable {
    let num: Int
    let den: Int

    init(fps: Double) {
        let fps = fps > 0 ? fps : 30
        let whole = fps.rounded()
        if abs(fps - whole) > 1e-6, abs(fps - whole * 1000 / 1001) < 0.01 {
            num = 1001; den = Int(whole) * 1000
        } else if abs(fps * 100 - (fps * 100).rounded()) < 1e-6 {
            num = 100; den = Int((fps * 100).rounded())
        } else {
            num = 1000; den = Int((fps * 1000).rounded())
        }
    }

    var rate: Double { Double(den) / Double(num) }

    func frames(_ t: Seconds) -> Int { Int((t * rate).rounded()) }

    /// FCPXML time of a frame count, reduced, e.g. "3/2s" or "5s".
    func fcp(_ frames: Int) -> String { FrameGrid.fcp(frames * num, den) }

    static func fcp(_ n: Int, _ d: Int) -> String {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? abs(a) : gcd(b, a % b) }
        let g = max(1, gcd(n, d))
        return d / g == 1 ? "\(n / g)s" : "\(n / g)/\(d / g)s"
    }
}

// MARK: OpenTimelineIO

extension Project {
    /// OpenTimelineIO JSON (Clip.2 with `media_references`, OTIO 0.15+), timed in frames at the canvas fps.
    /// Video tracks come first, bottom layer first, then the embedded audio of video tracks, then audio tracks.
    /// Text, solid and adjustment clips become gaps carrying `{"cutline": {kind, text}}` metadata;
    /// speed is a LinearTimeWarp with `source_range` duration in timeline frames.
    public func otio() throws -> Data {
        let grid = FrameGrid(fps: canvas.fps)
        let rate = canvas.fps > 0 ? canvas.fps : 30

        func rt(_ value: Int) -> [String: Any] { ["OTIO_SCHEMA": "RationalTime.1", "rate": rate, "value": Double(value)] }
        func range(_ start: Int, _ duration: Int) -> [String: Any] {
            ["OTIO_SCHEMA": "TimeRange.1", "start_time": rt(start), "duration": rt(duration)]
        }
        func gap(_ frames: Int, name: String = "", metadata: [String: Any] = [:]) -> [String: Any] {
            ["OTIO_SCHEMA": "Gap.1", "name": name, "source_range": range(0, frames), "effects": [Any](), "markers": [Any](),
             "metadata": metadata, "enabled": true]
        }
        func summary(_ clip: Clip) -> [String: Any] {
            var md: [String: Any] = [
                "clipId": clip.id, "kind": clip.kind.rawValue, "speed": clip.speed, "volume": clip.volume,
                "effects": clip.effects.map { ["id": $0.id, "type": $0.type, "enabled": $0.enabled, "mix": $0.mix] as [String: Any] },
            ]
            if clip.blend != .normal { md["blend"] = clip.blend.rawValue }
            if clip.fadeIn > 0 { md["fadeIn"] = clip.fadeIn }
            if clip.fadeOut > 0 { md["fadeOut"] = clip.fadeOut }
            if !clip.anim.isEmpty { md["animated"] = clip.anim.keys.sorted() }
            if let t = clip.text { md["text"] = t.text }
            if let c = clip.color { md["color"] = c.hex }
            return md
        }
        func reference(_ asset: MediaAsset?) -> [String: Any] {
            guard let m = asset else {
                return ["OTIO_SCHEMA": "MissingReference.1", "name": "", "available_range": NSNull(), "available_image_bounds": NSNull(), "metadata": [String: Any]()]
            }
            let available: Any = m.isImage ? NSNull() : range(0, Int((m.duration * grid.rate + 1e-6).rounded(.down)))
            return ["OTIO_SCHEMA": "ExternalReference.1", "name": m.name, "target_url": m.url.absoluteString,
                    "available_range": available, "available_image_bounds": NSNull(), "metadata": [String: Any]()]
        }
        func clipItem(_ clip: Clip, frames: Int) -> [String: Any] {
            let asset = clip.mediaId.flatMap(mediaAsset)
            var effects: [Any] = []
            if abs(clip.speed - 1) > 1e-9 {
                effects.append(["OTIO_SCHEMA": "LinearTimeWarp.1", "name": "", "effect_name": "LinearTimeWarp",
                                "time_scalar": clip.speed, "metadata": [String: Any]()] as [String: Any])
            }
            return ["OTIO_SCHEMA": "Clip.2", "name": clip.name ?? asset?.name ?? clip.id,
                    "source_range": range(grid.frames(clip.sourceIn), frames),
                    "media_references": ["DEFAULT_MEDIA": reference(asset)], "active_media_reference_key": "DEFAULT_MEDIA",
                    "effects": effects, "markers": [Any](), "metadata": ["cutline": summary(clip)], "enabled": true]
        }
        func otioTrack(_ track: Track, name: String, kind: String, embeddedAudio: Bool) -> [String: Any] {
            var children: [[String: Any]] = []
            var cursor = 0
            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                let s = max(grid.frames(clip.start), cursor), e = grid.frames(clip.end)
                guard e > s else { continue }
                if s > cursor { children.append(gap(s - cursor)) }
                let audible = clip.mediaId.flatMap(mediaAsset).map { $0.hasAudio && !$0.isImage } ?? false
                if clip.kind == .media && (!embeddedAudio || audible) {
                    children.append(clipItem(clip, frames: e - s))
                } else if embeddedAudio {
                    children.append(gap(e - s))
                } else {
                    var md: [String: Any] = ["kind": clip.kind.rawValue]
                    if let t = clip.text?.text { md["text"] = t }
                    children.append(gap(e - s, name: clip.name ?? clip.text?.text ?? clip.kind.rawValue,
                                        metadata: ["cutline": summary(clip).merging(md) { _, b in b }]))
                }
                cursor = e
            }
            let enabled = embeddedAudio || track.kind == .audio ? !track.muted : !track.hidden
            var md: [String: Any] = ["trackId": track.id, "volume": track.volume]
            if embeddedAudio { md["embeddedAudio"] = true }
            if !track.effects.isEmpty { md["effects"] = track.effects.map(\.type) }
            return ["OTIO_SCHEMA": "Track.1", "name": name, "kind": kind, "children": children, "effects": [Any](),
                    "markers": [Any](), "metadata": ["cutline": md], "source_range": NSNull(), "enabled": enabled]
        }

        let video = tracks.filter { $0.kind == .video }
        let embedded = video.filter { t in
            t.clips.contains { $0.kind == .media && ($0.mediaId.flatMap(mediaAsset).map { $0.hasAudio && !$0.isImage } ?? false) }
        }
        var children = video.map { otioTrack($0, name: $0.name, kind: "Video", embeddedAudio: false) }
        children += embedded.map { otioTrack($0, name: "\($0.name) Audio", kind: "Audio", embeddedAudio: true) }
        children += tracks.filter { $0.kind == .audio }.map { otioTrack($0, name: $0.name, kind: "Audio", embeddedAudio: false) }

        let markerItems: [[String: Any]] = markers.sorted { $0.time < $1.time }.map {
            ["OTIO_SCHEMA": "Marker.2", "name": $0.label, "color": "RED", "comment": "",
             "marked_range": range(grid.frames($0.time), 0), "metadata": ["cutline": ["markerId": $0.id]]]
        }
        let stack: [String: Any] = ["OTIO_SCHEMA": "Stack.1", "name": "tracks", "children": children, "effects": [Any](),
                                    "markers": markerItems, "metadata": [String: Any](), "source_range": NSNull(), "enabled": true]
        let timeline: [String: Any] = [
            "OTIO_SCHEMA": "Timeline.1", "name": name, "global_start_time": rt(0), "tracks": stack,
            "metadata": ["cutline": ["width": canvas.width, "height": canvas.height, "fps": canvas.fps, "background": canvas.background.hex]],
        ]
        return try JSONSerialization.data(withJSONObject: timeline, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

// MARK: FCPXML

/// A minimal XML element tree that escapes on output.
struct XMLElem {
    var name: String
    var attrs: [(String, String)] = []
    var children: [XMLElem] = []
    var text: String?

    /// Mixed content, like a title's `<text>`, is written without indentation, which would become part of it.
    var inline: Bool

    init(_ name: String, _ attrs: [(String, String)] = [], children: [XMLElem] = [], text: String? = nil, inline: Bool = false) {
        self.name = name
        self.attrs = attrs
        self.children = children
        self.text = text
        self.inline = inline
    }

    /// Indented by `depth`, or on one line when `depth` is nil.
    func write(_ out: inout String, depth: Int?) {
        let pad = depth.map { String(repeating: "    ", count: $0) } ?? ""
        let newline = depth == nil ? "" : "\n"
        out += pad + "<" + name
        for (k, v) in attrs { out += " \(k)=\"\(XMLElem.escape(v, attribute: true))\"" }
        if let text {
            out += ">" + XMLElem.escape(text, attribute: false) + "</\(name)>" + newline
        } else if children.isEmpty {
            out += "/>" + newline
        } else if inline || depth == nil {
            out += ">"
            for c in children { c.write(&out, depth: nil) }
            out += "</\(name)>" + newline
        } else {
            out += ">\n"
            for c in children { c.write(&out, depth: depth.map { $0 + 1 }) }
            out += pad + "</\(name)>\n"
        }
    }

    static func escape(_ s: String, attribute: Bool) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "'" where attribute: out += "&apos;"
            case "\n" where attribute: out += "&#10;"
            case "\t" where attribute: out += "&#9;"
            case "\r": out += "&#13;"
            default:
                // Characters XML 1.0 cannot carry.
                if u.value < 0x20 && u != "\n" && u != "\t" { continue }
                if u.value == 0xFFFE || u.value == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

extension Project {
    /// FCPXML 1.11 for Final Cut Pro. The lowest video track is the primary storyline (gaps fill holes);
    /// higher video tracks connect at lanes 1, 2, … and audio tracks at lanes -1, -2, …, each attached to
    /// the storyline item under its start. Text clips become Basic Titles; speed becomes a `timeMap`.
    /// Solid and adjustment clips have no FCP equivalent and become gaps on the storyline or are left out above it.
    public func fcpxml() -> String {
        let grid = FrameGrid(fps: canvas.fps)
        var nextId = 1
        func makeId() -> String { defer { nextId += 1 }; return "r\(nextId)" }

        // Resources
        var resources: [XMLElem] = []
        var formats: [String: String] = [:]
        func format(width: Int, height: Int, fps: Double?) -> String {
            let fg = fps.map { FrameGrid(fps: $0) }
            let key = "\(width)x\(height)@\(fg.map { "\($0.num)/\($0.den)" } ?? "still")"
            if let id = formats[key] { return id }
            let id = makeId()
            var attrs = [("id", id)]
            if let name = Self.fcpFormatName(width: width, height: height, grid: fg) { attrs.append(("name", name)) }
            if let fg { attrs.append(("frameDuration", "\(fg.num)/\(fg.den)s")) }
            attrs += [("width", "\(width)"), ("height", "\(height)")]
            resources.append(XMLElem("format", attrs))
            formats[key] = id
            return id
        }
        let sequenceFormat = format(width: canvas.width, height: canvas.height, fps: canvas.fps)

        var assetIds: [String: String] = [:]
        for m in media {
            let id = makeId()
            assetIds[m.id] = id
            var attrs = [("id", id), ("name", m.name), ("start", "0s")]
            if m.isImage {
                attrs.append(("duration", "0s"))
            } else {
                let mg = FrameGrid(fps: m.hasVideo && m.fps > 0 ? m.fps : canvas.fps)
                attrs.append(("duration", mg.fcp(Int((m.duration * mg.rate + 1e-6).rounded(.down)))))
            }
            attrs.append(("hasVideo", m.hasVideo ? "1" : "0"))
            if m.hasVideo {
                attrs.append(("format", format(width: m.width, height: m.height, fps: m.isImage ? nil : (m.fps > 0 ? m.fps : canvas.fps))))
                attrs.append(("videoSources", "1"))
            }
            attrs.append(("hasAudio", m.hasAudio ? "1" : "0"))
            if m.hasAudio { attrs += [("audioSources", "1"), ("audioChannels", "2"), ("audioRate", "48000")] }
            resources.append(XMLElem("asset", attrs, children: [XMLElem("media-rep", [("kind", "original-media"), ("src", m.url.absoluteString)])]))
        }
        let titleRef = "r_title"
        if tracks.contains(where: { $0.kind == .video && $0.clips.contains { $0.kind == .text } }) {
            resources.append(XMLElem("effect", [("id", titleRef), ("name", "Basic Title"),
                                                ("uid", ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti")]))
        }

        // Story elements
        var styleCount = 0
        func volumeChildren(_ gain: Double) -> [XMLElem] {
            guard abs(gain - 1) > 1e-6 else { return [] }
            let db = gain <= 1e-5 ? "-96dB" : String(format: "%.2fdB", 20 * log10(gain))
            return [XMLElem("adjust-volume", [("amount", db)])]
        }
        /// The clip's local start, which is in retimed time when the speed is not 1.
        func localStart(_ clip: Clip) -> Int {
            abs(clip.speed - 1) > 1e-9 && clip.speed > 0 ? grid.frames(clip.sourceIn / clip.speed) : grid.frames(clip.sourceIn)
        }
        func mediaElement(_ clip: Clip, asset: MediaAsset, track: Track, lane: Int?, offset: Int, frames: Int) -> XMLElem {
            let audioOnly = track.kind == .audio
            let start = localStart(clip)
            var attrs: [(String, String)] = [("ref", assetIds[asset.id]!)]
            if let lane { attrs.append(("lane", "\(lane)")) }
            attrs += [("offset", grid.fcp(offset)), ("name", clip.name ?? asset.name), ("start", grid.fcp(start)), ("duration", grid.fcp(frames))]
            if audioOnly && asset.hasVideo { attrs.append(("srcEnable", "audio")) }
            if audioOnly ? track.muted : track.hidden { attrs.append(("enabled", "0")) }
            var children: [XMLElem] = []
            if abs(clip.speed - 1) > 1e-9, clip.speed > 0, !asset.isImage {
                let end = start + frames
                let p = Int((clip.speed * 1000).rounded())
                children.append(XMLElem("timeMap", children: [
                    XMLElem("timept", [("time", "0s"), ("value", "0s"), ("interp", "linear")]),
                    XMLElem("timept", [("time", grid.fcp(end)), ("value", FrameGrid.fcp(end * grid.num * p, grid.den * 1000)), ("interp", "linear")]),
                ]))
            }
            if !asset.isImage {
                children += volumeChildren(track.kind == .video && track.muted ? 0 : track.volume * clip.volume)
            }
            return XMLElem(asset.isImage ? "video" : "asset-clip", attrs, children: children)
        }
        func titleElement(_ clip: Clip, track: Track, lane: Int?, offset: Int, frames: Int) -> XMLElem {
            let spec = clip.text ?? TextSpec(text: clip.name ?? "")
            styleCount += 1
            let styleId = "ts\(styleCount)"
            var attrs: [(String, String)] = [("ref", titleRef)]
            if let lane { attrs.append(("lane", "\(lane)")) }
            attrs += [("offset", grid.fcp(offset)), ("name", clip.name ?? spec.text), ("duration", grid.fcp(frames))]
            if track.hidden { attrs.append(("enabled", "0")) }
            let c = spec.color
            let style = XMLElem("text-style", [
                ("font", Self.fcpFont(spec.font)),
                ("fontSize", "\(Int((spec.size * Double(min(canvas.width, canvas.height))).rounded()))"),
                ("fontFace", spec.weight >= 600 ? "Bold" : "Regular"),
                ("fontColor", [c.r, c.g, c.b, c.a].map { String(format: "%.4g", $0) }.joined(separator: " ")),
                ("alignment", spec.align.rawValue),
            ])
            return XMLElem("title", attrs, children: [
                XMLElem("text", children: [XMLElem("text-style", [("ref", styleId)], text: spec.text)], inline: true),
                XMLElem("text-style-def", [("id", styleId)], children: [style]),
            ])
        }

        // Primary storyline
        struct SpineItem {
            var elem: XMLElem
            var offset: Int
            var localStart: Int
            var frames: Int
            var anchored: [(offset: Int, lane: Int, elem: XMLElem)] = []
            var markers: [XMLElem] = []
        }
        func gapItem(_ offset: Int, _ frames: Int, name: String = "Gap") -> SpineItem {
            SpineItem(elem: XMLElem("gap", [("name", name), ("offset", grid.fcp(offset)), ("duration", grid.fcp(frames))]), offset: offset, localStart: 0, frames: frames)
        }
        let videoTracks = tracks.filter { $0.kind == .video }
        var spine: [SpineItem] = []
        var cursor = 0
        if let primary = videoTracks.first {
            for clip in primary.clips.sorted(by: { $0.start < $1.start }) {
                let s = max(grid.frames(clip.start), cursor), e = grid.frames(clip.end)
                guard e > s else { continue }
                if s > cursor { spine.append(gapItem(cursor, s - cursor)) }
                if clip.kind == .media, let asset = clip.mediaId.flatMap(mediaAsset) {
                    spine.append(SpineItem(elem: mediaElement(clip, asset: asset, track: primary, lane: nil, offset: s, frames: e - s), offset: s, localStart: localStart(clip), frames: e - s))
                } else if clip.kind == .text {
                    spine.append(SpineItem(elem: titleElement(clip, track: primary, lane: nil, offset: s, frames: e - s), offset: s, localStart: 0, frames: e - s))
                } else {
                    spine.append(gapItem(s, e - s, name: clip.name ?? clip.kind.rawValue.capitalized))
                }
                cursor = e
            }
        }
        let markerEnd = markers.filter { $0.time >= 0 }.map { grid.frames($0.time) + 1 }.max() ?? 0
        let end = max(grid.frames(duration), markerEnd, cursor, 1)
        if end > cursor { spine.append(gapItem(cursor, end - cursor)) }

        func parent(of frame: Int) -> Int {
            spine.firstIndex { frame >= $0.offset && frame < $0.offset + $0.frames } ?? (spine.count - 1)
        }

        // Connected clips
        let connected: [(track: Track, lane: Int)] =
            videoTracks.dropFirst().enumerated().map { (track: $0.element, lane: $0.offset + 1) }
            + tracks.filter { $0.kind == .audio }.enumerated().map { (track: $0.element, lane: -($0.offset + 1)) }
        for (track, lane) in connected {
            for clip in track.clips {
                let s = grid.frames(clip.start), e = grid.frames(clip.end)
                guard e > s, s >= 0 else { continue }
                let p = parent(of: s)
                let offset = spine[p].localStart + (s - spine[p].offset)
                let elem: XMLElem
                if clip.kind == .media, let asset = clip.mediaId.flatMap(mediaAsset) {
                    if track.kind == .audio && !asset.hasAudio { continue }
                    elem = mediaElement(clip, asset: asset, track: track, lane: lane, offset: offset, frames: e - s)
                } else if clip.kind == .text, track.kind == .video {
                    elem = titleElement(clip, track: track, lane: lane, offset: offset, frames: e - s)
                } else {
                    continue
                }
                spine[p].anchored.append((offset, lane, elem))
            }
        }

        // Markers
        for m in markers.filter({ $0.time >= 0 }).sorted(by: { $0.time < $1.time }) {
            let f = grid.frames(m.time)
            let p = parent(of: f)
            spine[p].markers.append(XMLElem("marker", [("start", grid.fcp(spine[p].localStart + f - spine[p].offset)), ("duration", grid.fcp(1)), ("value", m.label)]))
        }

        let spineElems: [XMLElem] = spine.map { item in
            var e = item.elem
            e.children += item.anchored.sorted { ($0.offset, $0.lane) < ($1.offset, $1.lane) }.map(\.elem)
            e.children += item.markers
            return e
        }
        let sequence = XMLElem("sequence", [
            ("format", sequenceFormat), ("duration", grid.fcp(end)), ("tcStart", "0s"), ("tcFormat", "NDF"),
            ("audioLayout", "stereo"), ("audioRate", "48k"),
        ], children: [XMLElem("spine", children: spineElems)])
        let root = XMLElem("fcpxml", [("version", "1.11")], children: [
            XMLElem("resources", children: resources),
            XMLElem("library", children: [
                XMLElem("event", [("name", name)], children: [XMLElem("project", [("name", name)], children: [sequence])]),
            ]),
        ])
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n\n"
        root.write(&out, depth: 0)
        return out
    }

    static func fcpFont(_ font: String) -> String {
        switch font {
        case "system", "rounded": return "Helvetica Neue"
        case "serif": return "Times New Roman"
        case "mono": return "Menlo"
        default: return font
        }
    }

    /// Final Cut's name for common formats, e.g. "FFVideoFormat1080p2997"; nil for custom sizes.
    static func fcpFormatName(width: Int, height: Int, grid: FrameGrid?) -> String? {
        guard let grid else { return "FFVideoFormatRateUndefined" }
        let sizes = [(1280, 720, "720p"), (1920, 1080, "1080p"), (3840, 2160, "3840x2160p")]
        guard let size = sizes.first(where: { $0.0 == width && $0.1 == height })?.2 else { return nil }
        let rates: [String: String] = ["1001/24000": "2398", "100/2400": "24", "100/2500": "25", "1001/30000": "2997",
                                       "100/3000": "30", "100/5000": "50", "1001/60000": "5994", "100/6000": "60"]
        return rates["\(grid.num)/\(grid.den)"].map { "FFVideoFormat\(size)\($0)" }
    }
}
