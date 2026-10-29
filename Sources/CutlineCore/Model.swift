import Foundation

/// Times are seconds. Timeline times are relative to the start of the timeline;
/// source times are relative to the start of a media file.
public typealias Seconds = Double

public struct Project: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var name: String
    public var canvas: Canvas
    public var media: [MediaAsset]
    /// Index 0 is the bottom layer.
    public var tracks: [Track]
    public var captions: Captions
    public var markers: [Marker]

    public init(name: String, canvas: Canvas = Canvas()) {
        formatVersion = 1
        self.name = name
        self.canvas = canvas
        media = []
        tracks = [
            Track(id: "V1", kind: .video, name: "Main"),
            Track(id: "A1", kind: .audio, name: "Music"),
        ]
        captions = Captions()
        markers = []
    }

    public var duration: Seconds {
        tracks.flatMap(\.clips).map(\.end).max() ?? 0
    }

    public func mediaAsset(_ id: String) -> MediaAsset? {
        media.first { $0.id == id }
    }

    public func trackIndex(_ id: String) -> Int? {
        tracks.firstIndex { $0.id == id }
    }

    public func locateClip(_ id: String) -> (track: Int, clip: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) { return (t, c) }
        }
        return nil
    }

    public func clip(_ id: String) -> Clip? {
        locateClip(id).map { tracks[$0.track].clips[$0.clip] }
    }
}

public struct Canvas: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var fps: Double
    public var background: RGBA

    public init(width: Int = 1920, height: Int = 1080, fps: Double = 30, background: RGBA = .black) {
        self.width = width
        self.height = height
        self.fps = fps
        self.background = background
    }

    public func snap(_ t: Seconds) -> Seconds {
        (t * fps).rounded() / fps
    }

    public var frameDuration: Seconds { 1 / fps }
}

public struct MediaAsset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var name: String
    public var duration: Seconds
    public var width: Int
    public var height: Int
    public var fps: Double
    public var hasVideo: Bool
    public var hasAudio: Bool
    /// True for still images, which can be shown for any duration.
    public var isImage: Bool

    public init(id: String, path: String, name: String, duration: Seconds, width: Int, height: Int, fps: Double, hasVideo: Bool, hasAudio: Bool, isImage: Bool = false) {
        self.id = id
        self.path = path
        self.name = name
        self.duration = duration
        self.width = width
        self.height = height
        self.fps = fps
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.isImage = isImage
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

public enum TrackKind: String, Codable, Sendable, CaseIterable {
    /// Visual layers: media (with its audio), text and solid clips.
    case video
    /// Audio only: music, voice-over, sound effects.
    case audio
}

public struct Track: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: TrackKind
    public var name: String
    public var muted: Bool
    public var hidden: Bool
    public var volume: Double
    /// Sorted by start, never overlapping.
    public var clips: [Clip]

    public init(id: String, kind: TrackKind, name: String, muted: Bool = false, hidden: Bool = false, volume: Double = 1, clips: [Clip] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.muted = muted
        self.hidden = hidden
        self.volume = volume
        self.clips = clips
    }

    public var end: Seconds { clips.last?.end ?? 0 }

    public func clip(at t: Seconds, epsilon: Seconds = 1e-6) -> Clip? {
        clips.first { t >= $0.start - epsilon && t < $0.end - epsilon }
    }
}

public enum ClipKind: String, Codable, Sendable {
    case media
    case text
    case solid
}

public struct Clip: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: ClipKind
    public var name: String?
    public var mediaId: String?
    public var start: Seconds
    public var duration: Seconds
    public var sourceIn: Seconds
    public var speed: Double
    public var volume: Double
    public var audioFadeIn: Seconds
    public var audioFadeOut: Seconds
    /// Opacity fades of the picture.
    public var fadeIn: Seconds
    public var fadeOut: Seconds
    public var transform: Transform
    /// Times relative to the clip start. When present they override `transform` values they set.
    public var keyframes: [Keyframe]
    public var text: TextSpec?
    public var color: RGBA?

    public init(id: String, kind: ClipKind, name: String? = nil, mediaId: String? = nil, start: Seconds, duration: Seconds, sourceIn: Seconds = 0, speed: Double = 1, volume: Double = 1, audioFadeIn: Seconds = 0, audioFadeOut: Seconds = 0, fadeIn: Seconds = 0, fadeOut: Seconds = 0, transform: Transform = Transform(), keyframes: [Keyframe] = [], text: TextSpec? = nil, color: RGBA? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.mediaId = mediaId
        self.start = start
        self.duration = duration
        self.sourceIn = sourceIn
        self.speed = speed
        self.volume = volume
        self.audioFadeIn = audioFadeIn
        self.audioFadeOut = audioFadeOut
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.transform = transform
        self.keyframes = keyframes
        self.text = text
        self.color = color
    }

    public var end: Seconds { start + duration }
    public var sourceOut: Seconds { sourceIn + duration * speed }

    public func sourceTime(atTimeline t: Seconds) -> Seconds {
        sourceIn + (t - start) * speed
    }

    public func timelineTime(atSource s: Seconds) -> Seconds {
        start + (s - sourceIn) / speed
    }
}

public enum FitMode: String, Codable, Sendable, Hashable {
    /// Letterbox inside the canvas.
    case fit
    /// Cover the canvas, cropping overflow.
    case fill
    case stretch
}

public struct Crop: Codable, Equatable, Hashable, Sendable {
    /// Fractions of the source size removed from each edge.
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var isEmpty: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
}

public struct Transform: Codable, Equatable, Hashable, Sendable {
    public var fit: FitMode
    /// 1 is the size given by `fit`.
    public var scale: Double
    /// Offset of the center as a fraction of canvas width, positive moves right.
    public var x: Double
    /// Offset of the center as a fraction of canvas height, positive moves down.
    public var y: Double
    /// Degrees clockwise.
    public var rotation: Double
    public var opacity: Double
    public var crop: Crop

    public init(fit: FitMode = .fit, scale: Double = 1, x: Double = 0, y: Double = 0, rotation: Double = 0, opacity: Double = 1, crop: Crop = Crop()) {
        self.fit = fit
        self.scale = scale
        self.x = x
        self.y = y
        self.rotation = rotation
        self.opacity = opacity
        self.crop = crop
    }
}

public enum Easing: String, Codable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut

    public func apply(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: return 1 - pow(1 - t, 3)
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        }
    }
}

public struct Keyframe: Codable, Equatable, Hashable, Sendable {
    public var time: Seconds
    public var scale: Double?
    public var x: Double?
    public var y: Double?
    public var rotation: Double?
    public var opacity: Double?
    /// Easing of the segment that ends at this keyframe.
    public var easing: Easing

    public init(time: Seconds, scale: Double? = nil, x: Double? = nil, y: Double? = nil, rotation: Double? = nil, opacity: Double? = nil, easing: Easing = .easeInOut) {
        self.time = time
        self.scale = scale
        self.x = x
        self.y = y
        self.rotation = rotation
        self.opacity = opacity
        self.easing = easing
    }
}

public enum TextAlign: String, Codable, Sendable, Hashable {
    case left, center, right
}

public enum TextAnimation: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    case fade
    case pop
    case slideUp
    case typewriter
}

public struct TextSpec: Codable, Equatable, Hashable, Sendable {
    public var text: String
    /// "system", "rounded", "serif", "mono", or a font family name.
    public var font: String
    /// Font size as a fraction of the canvas's shorter side.
    public var size: Double
    /// 100–900.
    public var weight: Int
    public var color: RGBA
    public var background: RGBA?
    public var stroke: RGBA?
    /// Stroke width as a fraction of font size.
    public var strokeWidth: Double
    public var shadow: Bool
    public var align: TextAlign
    /// Center of the text box as fractions of the canvas, origin top-left.
    public var x: Double
    public var y: Double
    /// Wrap width as a fraction of canvas width.
    public var maxWidth: Double
    public var letterSpacing: Double
    public var animationIn: TextAnimation
    public var animationOut: TextAnimation

    public init(text: String, font: String = "system", size: Double = 0.07, weight: Int = 700, color: RGBA = .white, background: RGBA? = nil, stroke: RGBA? = nil, strokeWidth: Double = 0, shadow: Bool = true, align: TextAlign = .center, x: Double = 0.5, y: Double = 0.5, maxWidth: Double = 0.85, letterSpacing: Double = 0, animationIn: TextAnimation = .fade, animationOut: TextAnimation = .fade) {
        self.text = text
        self.font = font
        self.size = size
        self.weight = weight
        self.color = color
        self.background = background
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.shadow = shadow
        self.align = align
        self.x = x
        self.y = y
        self.maxWidth = maxWidth
        self.letterSpacing = letterSpacing
        self.animationIn = animationIn
        self.animationOut = animationOut
    }
}

public enum CaptionAnimation: String, Codable, Sendable, Hashable, CaseIterable {
    case none
    /// Lines pop in.
    case pop
    /// The spoken word is highlighted.
    case karaoke
    /// Words appear as they are spoken.
    case reveal
}

public struct CaptionStyle: Codable, Equatable, Hashable, Sendable {
    public var font: String
    /// Fraction of the canvas's shorter side.
    public var size: Double
    public var weight: Int
    public var color: RGBA
    public var highlightColor: RGBA
    public var background: RGBA?
    public var stroke: RGBA?
    public var strokeWidth: Double
    public var shadow: Bool
    public var uppercase: Bool
    /// Vertical center as a fraction of canvas height.
    public var y: Double
    public var maxWidth: Double
    public var maxWordsPerLine: Int
    public var maxLines: Int
    public var animation: CaptionAnimation

    public init(font: String = "system", size: Double = 0.055, weight: Int = 800, color: RGBA = .white, highlightColor: RGBA = RGBA(hex: "#FFD60A")!, background: RGBA? = nil, stroke: RGBA? = .black, strokeWidth: Double = 0.12, shadow: Bool = true, uppercase: Bool = false, y: Double = 0.82, maxWidth: Double = 0.86, maxWordsPerLine: Int = 6, maxLines: Int = 2, animation: CaptionAnimation = .karaoke) {
        self.font = font
        self.size = size
        self.weight = weight
        self.color = color
        self.highlightColor = highlightColor
        self.background = background
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.shadow = shadow
        self.uppercase = uppercase
        self.y = y
        self.maxWidth = maxWidth
        self.maxWordsPerLine = maxWordsPerLine
        self.maxLines = maxLines
        self.animation = animation
    }
}

public struct Captions: Codable, Equatable, Sendable {
    /// Captions are derived from transcripts of the clips on the timeline, so they follow every edit.
    public var enabled: Bool
    public var style: CaptionStyle
    /// Whole-word replacements applied case-insensitively, e.g. ["cut line": "Cutline"].
    public var replacements: [String: String]
    /// Words never shown, e.g. filler words left in the edit.
    public var hiddenWords: [String]
    /// Restricts captions to clips on these tracks. Empty means every unmuted track.
    public var trackIds: [String]

    public init(enabled: Bool = false, style: CaptionStyle = CaptionStyle(), replacements: [String: String] = [:], hiddenWords: [String] = [], trackIds: [String] = []) {
        self.enabled = enabled
        self.style = style
        self.replacements = replacements
        self.hiddenWords = hiddenWords
        self.trackIds = trackIds
    }
}

public struct Marker: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var time: Seconds
    public var label: String

    public init(id: String, time: Seconds, label: String) {
        self.id = id
        self.time = time
        self.label = label
    }
}

public struct RGBA: Codable, Equatable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let white = RGBA(r: 1, g: 1, b: 1)

    /// Accepts #RGB, #RRGGBB and #RRGGBBAA.
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        if s.count == 6 { s += "FF" }
        guard s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        r = Double((v >> 24) & 0xFF) / 255
        g = Double((v >> 16) & 0xFF) / 255
        b = Double((v >> 8) & 0xFF) / 255
        a = Double(v & 0xFF) / 255
    }

    public var hex: String {
        func c(_ v: Double) -> String { String(format: "%02X", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + c(r) + c(g) + c(b) + (a < 1 ? c(a) : "")
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = RGBA(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid color \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }
}
