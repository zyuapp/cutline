import Foundation

/// Times are seconds. Timeline times are relative to the start of the timeline;
/// source times are relative to the start of a media file.
public typealias Seconds = Double

public struct Project: Codable, Equatable, Sendable {
    /// 2 added effects, blend modes, adjustment clips and animation of any parameter.
    public static let currentFormat = 2

    public var formatVersion: Int
    public var name: String
    public var canvas: Canvas
    public var media: [MediaAsset]
    /// Index 0 is the bottom layer.
    public var tracks: [Track]
    public var captions: Captions
    public var markers: [Marker]
    public var master: MasterAudio
    public var transitions: [Transition]
    /// Groups of tracks nested into single clips.
    public var sequences: [NestedSequence]
    /// Media recorded together (multicam angles, separate sound): each media's offset from the group's
    /// reference, so the same moment is at source time t in the reference and t + offset in the member.
    public var syncGroups: [[String: Seconds]]
    /// Name of the timeline in `tracks`; the project's other timelines wait in `timelines`.
    public var timelineName: String?
    public var timelines: [StoredTimeline]

    public init(name: String, canvas: Canvas = Canvas()) {
        formatVersion = Project.currentFormat
        self.name = name
        self.canvas = canvas
        media = []
        tracks = [
            Track(id: "V1", kind: .video, name: "Main"),
            Track(id: "A1", kind: .audio, name: "Music"),
        ]
        captions = Captions()
        markers = []
        master = MasterAudio()
        transitions = []
        sequences = []
        syncGroups = []
        timelines = []
    }

    enum CodingKeys: String, CodingKey { case formatVersion, name, canvas, media, tracks, captions, markers, master, transitions, sequences, syncGroups, timelineName, timelines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        name = try c.decode(String.self, forKey: .name)
        canvas = try c.decode(Canvas.self, forKey: .canvas)
        media = try c.decodeIfPresent([MediaAsset].self, forKey: .media) ?? []
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        captions = try c.decodeIfPresent(Captions.self, forKey: .captions) ?? Captions()
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        master = try c.decodeIfPresent(MasterAudio.self, forKey: .master) ?? MasterAudio()
        transitions = try c.decodeIfPresent([Transition].self, forKey: .transitions) ?? []
        sequences = try c.decodeIfPresent([NestedSequence].self, forKey: .sequences) ?? []
        syncGroups = try c.decodeIfPresent([[String: Seconds]].self, forKey: .syncGroups) ?? []
        timelineName = try c.decodeIfPresent(String.self, forKey: .timelineName)
        timelines = try c.decodeIfPresent([StoredTimeline].self, forKey: .timelines) ?? []
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
    /// Output color: Rec.709 SDR (default), Display P3, or HDR as Rec.2100 HLG or PQ.
    public var colorSpace: WorkingSpace
    /// Timecode of the first timeline frame ("hh:mm:ss:ff"); nil uses TimecodeFormat.defaultStart.
    public var timecodeStart: String?
    /// Timecode counting for interchange; nil is drop frame at 29.97 and 59.94 fps.
    public var dropFrame: Bool?

    public init(width: Int = 1920, height: Int = 1080, fps: Double = 30, background: RGBA = .black, colorSpace: WorkingSpace = .rec709, timecodeStart: String? = nil) {
        self.width = width
        self.height = height
        self.fps = fps
        self.background = background
        self.colorSpace = colorSpace
        self.timecodeStart = timecodeStart
    }

    enum CodingKeys: String, CodingKey { case width, height, fps, background, colorSpace, timecodeStart, dropFrame }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        fps = try c.decode(Double.self, forKey: .fps)
        background = try c.decodeIfPresent(RGBA.self, forKey: .background) ?? .black
        colorSpace = try c.decodeIfPresent(WorkingSpace.self, forKey: .colorSpace) ?? .rec709
        timecodeStart = try c.decodeIfPresent(String.self, forKey: .timecodeStart)
        dropFrame = try c.decodeIfPresent(Bool.self, forKey: .dropFrame)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(fps, forKey: .fps)
        try c.encode(background, forKey: .background)
        if colorSpace != .rec709 { try c.encode(colorSpace, forKey: .colorSpace) }
        try c.encodeIfPresent(timecodeStart, forKey: .timecodeStart)
        try c.encodeIfPresent(dropFrame, forKey: .dropFrame)
    }

    public func snap(_ t: Seconds) -> Seconds {
        (t * fps).rounded() / fps
    }

    public var frameDuration: Seconds { 1 / fps }

    /// Whether interchange timecode counts drop frame: only NTSC 29.97 and 59.94 can, and they do unless `dropFrame` is false.
    /// Every exporter (EDL FCM, FCPXML tcFormat, xmeml displayformat) asks this.
    public var isDropFrame: Bool { timecodeFormat.dropFrame }

    public var timecodeFormat: TimecodeFormat { TimecodeFormat(fps: fps, dropFrame: dropFrame) }

    /// The `dropFrame` an importer should keep for a file that counts `drop`: nil when that is the default or the rate can't.
    static func dropFrame(_ drop: Bool, fps: Double) -> Bool? {
        let auto = Canvas(fps: fps).isDropFrame
        return auto == drop || (drop && !auto) ? nil : drop
    }
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
    /// Source timecode of the first frame, in seconds (e.g. 3600 for 01:00:00:00).
    public var timecodeStart: Seconds?
    public var reel: String?
    /// Audio sample rate in Hz, when known.
    public var sampleRate: Double?
    /// Keyword ranges, favorites and rejects, in source time.
    public var tags: [MediaTag]?
    /// Camera log encoding, detected at import or set by hand; nil is display-referred video.
    public var log: LogProfile?
    /// Whether log code values were recorded in legal (video) or full range.
    public var signalRange: SignalRange?
    /// Folder in the media browser, "/"-separated, e.g. "Interviews/Day 1".
    public var bin: String?
    /// Free-form columns such as scene, take, camera, angle, notes.
    public var metadata: [String: String]?
    /// The camera file when `path` is a mezzanine transcode of it. Interchange and conform name this file.
    public var originalPath: String?
    /// What the import transcode did, e.g. "mpeg2video 4:2:2 in MXF → ProRes 422 HQ".
    public var transcoded: String?
    /// Scan of the picture; nil is unknown (treated as progressive).
    public var fieldOrder: FieldOrder?
    /// false shows interlaced frames woven; nil or true deinterlaces them.
    public var deinterlace: Bool?

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
    /// The file an online conform should use: the original when `path` is a mezzanine.
    public var conformPath: String { originalPath ?? path }
    public var conformURL: URL { URL(fileURLWithPath: conformPath) }
    public var isInterlaced: Bool { fieldOrder == .tff || fieldOrder == .bff }
    /// Imported, but its mezzanine is still being made; `path` is the undecodable original until then.
    public var isTranscoding: Bool { transcoded?.hasPrefix(MediaAsset.pendingTranscode) == true }
    public static let pendingTranscode = "pending: "
    /// Whether the compositor deinterlaces this media's frames.
    public var deinterlaces: Bool { isInterlaced && deinterlace != false }
}

/// How a video's two fields are ordered.
public enum FieldOrder: String, Codable, Sendable, CaseIterable {
    case progressive
    /// Interlaced, top field first.
    case tff
    /// Interlaced, bottom field first.
    case bff
}

/// A labeled source range of a media file, like Final Cut's keywords and ratings.
public struct MediaTag: Codable, Equatable, Sendable {
    public var label: String
    public var start: Seconds
    public var end: Seconds
    /// favorite or reject, for ratings.
    public var rating: String?

    public init(label: String, start: Seconds, end: Seconds, rating: String? = nil) {
        self.label = label
        self.start = start
        self.end = end
        self.rating = rating
    }
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
    /// Applied to the track's picture after each clip's own effects.
    public var effects: [Effect]
    /// Sorted by start, never overlapping.
    public var clips: [Clip]
    /// Audio role for stem delivery: dialogue, music, effects, or any custom name.
    public var role: String?
    /// Fader automation: track volume over timeline time, replacing `volume` where set.
    public var volumeCurve: Curve?

    public init(id: String, kind: TrackKind, name: String, muted: Bool = false, hidden: Bool = false, volume: Double = 1, effects: [Effect] = [], clips: [Clip] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.muted = muted
        self.hidden = hidden
        self.volume = volume
        self.effects = effects
        self.clips = clips
    }

    enum CodingKeys: String, CodingKey { case id, kind, name, muted, hidden, volume, effects, clips, role, volumeCurve }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(TrackKind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        effects = try c.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        role = try c.decodeIfPresent(String.self, forKey: .role)
        volumeCurve = try c.decodeIfPresent(Curve.self, forKey: .volumeCurve)
    }

    public var end: Seconds { clips.last?.end ?? 0 }

    /// Fader level at a timeline time.
    public func volume(at t: Seconds) -> Double { volumeCurve?.value(at: t)?.number ?? volume }

    public func clip(at t: Seconds, epsilon: Seconds = 1e-6) -> Clip? {
        clips.first { t >= $0.start - epsilon && t < $0.end - epsilon }
    }
}

public enum ClipKind: String, Codable, Sendable, CaseIterable {
    case media
    case text
    case solid
    /// Has no picture of its own; its effects apply to everything composited below it.
    case adjustment
    /// A nested sequence (`Project.sequences`), played as one clip.
    case sequence
    /// Drawn graphics (shapes, arrows, lower thirds, counters); the first effect is the generator, fx.gen.<param>.
    case generator
}

public enum BlendMode: String, Codable, Sendable, Hashable, CaseIterable {
    case normal, multiply, screen, overlay, softLight, hardLight, darken, lighten
    case colorDodge, colorBurn, difference, exclusion, add, hue, saturation, color, luminosity
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
    /// Split edits: audio starts this long before the picture (J cut); negative starts it later.
    public var audioLead: Seconds
    /// Audio continues this long after the picture ends (L cut); negative ends it earlier.
    public var audioLag: Seconds
    /// Opacity fades of the picture.
    public var fadeIn: Seconds
    public var fadeOut: Seconds
    public var transform: Transform
    public var blend: BlendMode
    /// Applied in order, in the clip's own frame before it is placed on the canvas.
    public var effects: [Effect]
    /// Animated parameters by path, e.g. "transform.scale" or "fx.blur1.radius".
    /// Key times are seconds from the clip start.
    public var anim: [String: Curve]
    public var text: TextSpec?
    public var color: RGBA?
    /// Plays the source range backwards.
    public var reverse: Bool = false
    /// How slowed-down footage fills in frames: nil repeats frames, "blend" mixes neighbours, "flow" uses optical flow.
    public var interpolate: String?
    /// Clips sharing a link id move, split and delete together (picture with its separately recorded sound).
    public var link: String?
    /// How log footage is brought into the working space: tone map ("aces" default) and exposure in stops.
    public var inputTone: ToneMap?
    public var inputExposure: Double?
    /// Position in a surround mix; nil is the default (front center, full center share, no LFE).
    public var surround: SurroundPan?
    /// Which source channels play; nil is stereo as recorded.
    public var channels: ChannelRouting?

    public init(id: String, kind: ClipKind, name: String? = nil, mediaId: String? = nil, start: Seconds, duration: Seconds, sourceIn: Seconds = 0, speed: Double = 1, volume: Double = 1, audioFadeIn: Seconds = 0, audioFadeOut: Seconds = 0, fadeIn: Seconds = 0, fadeOut: Seconds = 0, transform: Transform = Transform(), blend: BlendMode = .normal, effects: [Effect] = [], anim: [String: Curve] = [:], text: TextSpec? = nil, color: RGBA? = nil) {
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
        audioLead = 0
        audioLag = 0
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.transform = transform
        self.blend = blend
        self.effects = effects
        self.anim = anim
        self.text = text
        self.color = color
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, mediaId, start, duration, sourceIn, speed, volume, audioFadeIn, audioFadeOut, audioLead, audioLag
        case fadeIn, fadeOut, transform, blend, effects, anim, text, color, keyframes, reverse, interpolate, link, inputTone, inputExposure, surround, channels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(ClipKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        mediaId = try c.decodeIfPresent(String.self, forKey: .mediaId)
        start = try c.decode(Double.self, forKey: .start)
        duration = try c.decode(Double.self, forKey: .duration)
        sourceIn = try c.decodeIfPresent(Double.self, forKey: .sourceIn) ?? 0
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        audioFadeIn = try c.decodeIfPresent(Double.self, forKey: .audioFadeIn) ?? 0
        audioFadeOut = try c.decodeIfPresent(Double.self, forKey: .audioFadeOut) ?? 0
        audioLead = try c.decodeIfPresent(Double.self, forKey: .audioLead) ?? 0
        reverse = try c.decodeIfPresent(Bool.self, forKey: .reverse) ?? false
        interpolate = try c.decodeIfPresent(String.self, forKey: .interpolate)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        inputTone = try c.decodeIfPresent(ToneMap.self, forKey: .inputTone)
        inputExposure = try c.decodeIfPresent(Double.self, forKey: .inputExposure)
        surround = try c.decodeIfPresent(SurroundPan.self, forKey: .surround)
        channels = try c.decodeIfPresent(ChannelRouting.self, forKey: .channels)
        audioLag = try c.decodeIfPresent(Double.self, forKey: .audioLag) ?? 0
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        transform = try c.decodeIfPresent(Transform.self, forKey: .transform) ?? Transform()
        blend = try c.decodeIfPresent(BlendMode.self, forKey: .blend) ?? .normal
        effects = try c.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        anim = try c.decodeIfPresent([String: Curve].self, forKey: .anim) ?? [:]
        text = try c.decodeIfPresent(TextSpec.self, forKey: .text)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color)
        // Format 1 stored transform keyframes as a list of partial transforms.
        if let legacy = try c.decodeIfPresent([LegacyKeyframe].self, forKey: .keyframes), !legacy.isEmpty {
            let sorted = legacy.sorted { $0.time < $1.time }
            let fields: [(String, KeyPath<LegacyKeyframe, Double?>)] = [
                ("transform.scale", \.scale), ("transform.x", \.x), ("transform.y", \.y),
                ("transform.rotation", \.rotation), ("transform.opacity", \.opacity),
            ]
            for (path, kp) in fields {
                let keys = sorted.compactMap { k in k[keyPath: kp].map { CurveKey(t: k.time, v: .number($0), ease: k.easing) } }
                if !keys.isEmpty && anim[path] == nil { anim[path] = Curve(keys: keys) }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(mediaId, forKey: .mediaId)
        try c.encode(start, forKey: .start)
        try c.encode(duration, forKey: .duration)
        try c.encode(sourceIn, forKey: .sourceIn)
        try c.encode(speed, forKey: .speed)
        try c.encode(volume, forKey: .volume)
        try c.encode(audioFadeIn, forKey: .audioFadeIn)
        try c.encode(audioFadeOut, forKey: .audioFadeOut)
        if audioLead != 0 { try c.encode(audioLead, forKey: .audioLead) }
        if audioLag != 0 { try c.encode(audioLag, forKey: .audioLag) }
        try c.encode(fadeIn, forKey: .fadeIn)
        try c.encode(fadeOut, forKey: .fadeOut)
        try c.encode(transform, forKey: .transform)
        try c.encode(blend, forKey: .blend)
        try c.encode(effects, forKey: .effects)
        try c.encode(anim, forKey: .anim)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(color, forKey: .color)
        if reverse { try c.encode(reverse, forKey: .reverse) }
        try c.encodeIfPresent(interpolate, forKey: .interpolate)
        try c.encodeIfPresent(link, forKey: .link)
        try c.encodeIfPresent(inputTone, forKey: .inputTone)
        try c.encodeIfPresent(inputExposure, forKey: .inputExposure)
        try c.encodeIfPresent(surround, forKey: .surround)
        try c.encodeIfPresent(channels, forKey: .channels)
    }

    public var end: Seconds { start + duration }
    /// The end of the source range the clip uses (played backwards when reversed).
    public var sourceOut: Seconds { sourceIn + sourceOffset(atLocal: duration) }

    /// A speed curve ("time.speed" animation) makes speed vary over the clip: ramps, holds, slow motion.
    public var isRetimed: Bool { anim["time.speed"] != nil }

    /// Speed at a time from the clip start.
    public func speed(atLocal t: Seconds) -> Double {
        guard let c = anim["time.speed"] else { return speed }
        return max(0, c.value(at: t)?.number ?? speed)
    }

    /// Source seconds consumed from the clip start until local time `t`: the integral of speed.
    public func sourceOffset(atLocal t: Seconds) -> Seconds {
        guard let c = anim["time.speed"] else { return t * speed }
        guard t > 0 else { return t * max(0, c.value(at: 0)?.number ?? speed) }
        let steps = max(8, Int(t * 240))
        let h = t / Double(steps)
        var sum = 0.0
        var prev = speed(atLocal: 0)
        for i in 1...steps {
            let cur = speed(atLocal: Double(i) * h)
            sum += (prev + cur) * h / 2
            prev = cur
        }
        return sum
    }

    public func sourceTime(atTimeline t: Seconds) -> Seconds {
        let offset = sourceOffset(atLocal: t - start)
        return reverse ? sourceOut - offset : sourceIn + offset
    }

    public func timelineTime(atSource s: Seconds) -> Seconds {
        if !isRetimed && !reverse { return start + (s - sourceIn) / speed }
        let target = reverse ? sourceOut - s : s - sourceIn
        if !isRetimed { return start + target / speed }
        var lo = 0.0, hi = duration
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if sourceOffset(atLocal: mid) < target { lo = mid } else { hi = mid }
        }
        return start + (lo + hi) / 2
    }

    public func effect(_ id: String) -> Effect? { effects.first { $0.id == id } }

    /// Where this clip's sound plays on the timeline, including split-edit lead and lag.
    public var audioRange: TimeRange { TimeRange(start - audioLead, end + audioLag) }
    /// The source range heard over `audioRange`.
    public var audioSourceRange: TimeRange { TimeRange(sourceIn - audioLead * speed(atLocal: 0), sourceOut + audioLag * speed(atLocal: duration)) }
}

public struct MasterAudio: Codable, Equatable, Sendable {
    /// Gain applied to the whole mix, in decibels, before the master effects.
    public var gainDb: Double
    /// Audio effects on the whole mix, e.g. a limiter after loudness normalization.
    public var effects: [Effect]
    /// Channel layout the timeline is mixed and delivered in.
    public var layout: AudioLayout

    public init(gainDb: Double = 0, effects: [Effect] = [], layout: AudioLayout = .stereo) {
        self.gainDb = gainDb
        self.effects = effects
        self.layout = layout
    }

    enum CodingKeys: String, CodingKey { case gainDb, effects, layout }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gainDb = try c.decodeIfPresent(Double.self, forKey: .gainDb) ?? 0
        effects = try c.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        layout = try c.decodeIfPresent(AudioLayout.self, forKey: .layout) ?? .stereo
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(gainDb, forKey: .gainDb)
        try c.encode(effects, forKey: .effects)
        if layout != .stereo { try c.encode(layout, forKey: .layout) }
    }

    public var gain: Double { pow(10, gainDb / 20) }
}

struct LegacyKeyframe: Decodable {
    var time: Seconds
    var scale: Double?
    var x: Double?
    var y: Double?
    var rotation: Double?
    var opacity: Double?
    var easing: Easing
}

public enum FitMode: String, Codable, Sendable, Hashable, CaseIterable {
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
    /// Point that scale and rotation pivot around, as fractions of the clip's frame (0.5, 0.5 is the center).
    public var anchorX: Double = 0.5
    public var anchorY: Double = 0.5
    /// 3D tilt in degrees: around the horizontal axis (top away is positive) and the vertical axis (right side away is positive).
    public var rotateX: Double = 0
    public var rotateY: Double = 0
    /// Camera distance for 3D tilts, in frame heights; smaller is more dramatic.
    public var perspective: Double = 2
    /// Shutter angle in degrees for motion blur on moving layers; 0 is off, 180 is film-like.
    public var motionBlur: Double = 0

    public init(fit: FitMode = .fit, scale: Double = 1, x: Double = 0, y: Double = 0, rotation: Double = 0, opacity: Double = 1, crop: Crop = Crop()) {
        self.fit = fit
        self.scale = scale
        self.x = x
        self.y = y
        self.rotation = rotation
        self.opacity = opacity
        self.crop = crop
    }

    enum CodingKeys: String, CodingKey { case fit, scale, x, y, rotation, opacity, crop, anchorX, anchorY, rotateX, rotateY, perspective, motionBlur }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fit = try c.decodeIfPresent(FitMode.self, forKey: .fit) ?? .fit
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        crop = try c.decodeIfPresent(Crop.self, forKey: .crop) ?? Crop()
        anchorX = try c.decodeIfPresent(Double.self, forKey: .anchorX) ?? 0.5
        anchorY = try c.decodeIfPresent(Double.self, forKey: .anchorY) ?? 0.5
        rotateX = try c.decodeIfPresent(Double.self, forKey: .rotateX) ?? 0
        rotateY = try c.decodeIfPresent(Double.self, forKey: .rotateY) ?? 0
        perspective = try c.decodeIfPresent(Double.self, forKey: .perspective) ?? 2
        motionBlur = try c.decodeIfPresent(Double.self, forKey: .motionBlur) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fit, forKey: .fit)
        try c.encode(scale, forKey: .scale)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(crop, forKey: .crop)
        if anchorX != 0.5 { try c.encode(anchorX, forKey: .anchorX) }
        if anchorY != 0.5 { try c.encode(anchorY, forKey: .anchorY) }
        if rotateX != 0 { try c.encode(rotateX, forKey: .rotateX) }
        if rotateY != 0 { try c.encode(rotateY, forKey: .rotateY) }
        if perspective != 2 { try c.encode(perspective, forKey: .perspective) }
        if motionBlur != 0 { try c.encode(motionBlur, forKey: .motionBlur) }
    }

    /// Whether the picture needs the 3D path.
    public var is3D: Bool { rotateX != 0 || rotateY != 0 }
}

public enum Easing: String, Codable, Sendable, Hashable, CaseIterable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    /// Holds the previous value, then jumps.
    case hold
    /// Overshoots slightly, then settles.
    case back
    /// Springs past the target and oscillates to rest.
    case elastic
    /// Drops in and bounces.
    case bounce

    public func apply(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear: return t
        case .easeIn: return t * t * t
        case .easeOut: return 1 - pow(1 - t, 3)
        case .easeInOut: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .hold: return t < 1 ? 0 : 1
        case .back:
            let c1 = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        case .elastic:
            if t == 0 || t == 1 { return t }
            return pow(2, -10 * t) * sin((t * 10 - 0.75) * (2 * .pi / 3)) + 1
        case .bounce:
            let n1 = 7.5625, d1 = 2.75
            var x = t
            if x < 1 / d1 { return n1 * x * x }
            if x < 2 / d1 { x -= 1.5 / d1; return n1 * x * x + 0.75 }
            if x < 2.5 / d1 { x -= 2.25 / d1; return n1 * x * x + 0.9375 }
            x -= 2.625 / d1
            return n1 * x * x + 0.984375
        }
    }
}

public enum TextAlign: String, Codable, Sendable, Hashable, CaseIterable {
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
    /// Animates each word, letter or line on its own; replaces the in/out presets.
    public var animator: TextAnimator?
    /// When each unit starts, in seconds from the clip start (spoken word times for kinetic captions).
    public var unitTimes: [Seconds]?
    /// Restyles parts of the text, later spans over earlier ones.
    public var spans: [TextSpan]?

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

/// A style for part of a title: every occurrence of `match`, or characters `from..<to`.
public struct TextSpan: Codable, Equatable, Hashable, Sendable {
    public var match: String?
    public var from: Int?
    public var to: Int?
    public var color: RGBA?
    public var font: String?
    public var weight: Int?
    /// Multiplies the title's size.
    public var scale: Double?
    public var italic: Bool?
    public var underline: Bool?
    /// Marker-style box behind the characters.
    public var highlight: RGBA?

    public init(match: String? = nil, from: Int? = nil, to: Int? = nil, color: RGBA? = nil, font: String? = nil, weight: Int? = nil, scale: Double? = nil, italic: Bool? = nil, underline: Bool? = nil, highlight: RGBA? = nil) {
        self.match = match
        self.from = from
        self.to = to
        self.color = color
        self.font = font
        self.weight = weight
        self.scale = scale
        self.italic = italic
        self.underline = underline
        self.highlight = highlight
    }

    /// Character ranges of `text` this span covers.
    public func ranges(in text: String) -> [Range<Int>] {
        let n = text.count
        if let match, !match.isEmpty {
            var out: [Range<Int>] = []
            var search = text.startIndex
            while let r = text.range(of: match, options: .caseInsensitive, range: search..<text.endIndex) {
                out.append(text.distance(from: text.startIndex, to: r.lowerBound)..<text.distance(from: text.startIndex, to: r.upperBound))
                search = r.upperBound
            }
            return out
        }
        let lo = max(0, min(n, from ?? 0)), hi = max(lo, min(n, to ?? n))
        return hi > lo ? [lo..<hi] : []
    }

    /// Fields set here override `other`'s.
    func over(_ other: TextSpan) -> TextSpan {
        TextSpan(color: color ?? other.color, font: font ?? other.font, weight: weight ?? other.weight, scale: scale ?? other.scale, italic: italic ?? other.italic, underline: underline ?? other.underline, highlight: highlight ?? other.highlight)
    }
}

extension TextSpec {
    /// The text cut where its style changes, each piece with its merged span style (nil for the base style).
    public func styledPieces() -> [(text: String, style: TextSpan?)] {
        let chars = Array(text)
        guard let spans, !spans.isEmpty, !chars.isEmpty else { return [(text, nil)] }
        var per = [TextSpan?](repeating: nil, count: chars.count)
        for span in spans {
            for r in span.ranges(in: text) {
                for i in r where i < chars.count { per[i] = per[i].map { span.over($0) } ?? span.over(TextSpan()) }
            }
        }
        var out: [(text: String, style: TextSpan?)] = []
        for (i, c) in chars.enumerated() {
            if let last = out.last, last.style == per[i] { out[out.count - 1].text.append(c) } else { out.append((String(c), per[i])) }
        }
        return out
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
    /// Restricts captions to clips on these tracks. Empty means the dialogue tracks (see `Project.captionTrackIds`).
    public var trackIds: [String]
    /// Corrections to individual cues, keyed by the source words they cover.
    public var edits: [CaptionEdit]

    public init(enabled: Bool = false, style: CaptionStyle = CaptionStyle(), replacements: [String: String] = [:], hiddenWords: [String] = [], trackIds: [String] = [], edits: [CaptionEdit] = []) {
        self.enabled = enabled
        self.style = style
        self.replacements = replacements
        self.hiddenWords = hiddenWords
        self.trackIds = trackIds
        self.edits = edits
    }

    enum CodingKeys: String, CodingKey { case enabled, style, replacements, hiddenWords, trackIds, edits }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        style = try c.decodeIfPresent(CaptionStyle.self, forKey: .style) ?? CaptionStyle()
        replacements = try c.decodeIfPresent([String: String].self, forKey: .replacements) ?? [:]
        hiddenWords = try c.decodeIfPresent([String].self, forKey: .hiddenWords) ?? []
        trackIds = try c.decodeIfPresent([String].self, forKey: .trackIds) ?? []
        edits = try c.decodeIfPresent([CaptionEdit].self, forKey: .edits) ?? []
    }
}

/// A correction to the caption words spoken between two transcript words of one media file.
/// Because it is keyed by source words, it follows the words through later edits.
public struct CaptionEdit: Codable, Equatable, Sendable {
    public var mediaId: String
    public var fromWord: Int
    public var toWord: Int
    /// Replaces the words' text; their time span is shared out by length.
    public var text: String?
    /// Seconds added to the first word's start and the last word's end.
    public var startOffset: Seconds?
    public var endOffset: Seconds?
    public var hidden: Bool?
    /// Starts a new cue at the first word.
    public var breakBefore: Bool?

    public init(mediaId: String, fromWord: Int, toWord: Int, text: String? = nil, startOffset: Seconds? = nil, endOffset: Seconds? = nil, hidden: Bool? = nil, breakBefore: Bool? = nil) {
        self.mediaId = mediaId
        self.fromWord = fromWord
        self.toWord = toWord
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.hidden = hidden
        self.breakBefore = breakBefore
    }

    public func covers(_ mediaId: String, _ word: Int) -> Bool {
        mediaId == self.mediaId && word >= fromWord && word <= toWord
    }
}

public struct Marker: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var time: Seconds
    public var label: String
    /// standard (default), chapter, todo, done or comment.
    public var kind: String?
    public var color: RGBA?
    public var note: String?
    /// Ranged markers span this many seconds.
    public var duration: Seconds?

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
