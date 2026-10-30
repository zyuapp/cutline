import Foundation

/// Rectangle in fractions of the frame, origin at the top left.
public struct NormRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { max(0, width) * max(0, height) }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func union(_ other: NormRect) -> NormRect {
        let x0 = min(x, other.x), y0 = min(y, other.y)
        let x1 = max(x + width, other.x + other.width), y1 = max(y + height, other.y + other.height)
        return NormRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func iou(_ other: NormRect) -> Double {
        let w = min(x + width, other.x + other.width) - max(x, other.x)
        let h = min(y + height, other.y + other.height) - max(y, other.y)
        guard w > 0, h > 0 else { return 0 }
        let inter = w * h
        return inter / (area + other.area - inter)
    }

    /// Center distance in units of the larger box's larger side.
    public func centerDistance(_ other: NormRect) -> Double {
        let d = hypot(midX - other.midX, midY - other.midY)
        return d / max(width, height, other.width, other.height, 1e-6)
    }
}

/// What one span of a video file shows.
public struct Shot: Codable, Equatable, Sendable {
    public var index: Int
    public var start: Seconds
    public var end: Seconds
    /// Scene classification labels, most confident first.
    public var labels: [String]
    /// "extreme close-up", "close-up", "medium", "wide" or "no people".
    public var size: String
    /// Most faces or people seen in one sample.
    public var people: Int
    /// Recognized text lines in the middle frame.
    public var text: [String]
    /// Overall aesthetics score, -1…1.
    public var aesthetics: Double?
    /// Screenshots, documents and other non-memorable footage.
    public var utility: Bool?
    /// Mean luma, 0…1.
    public var brightness: Double
    /// Mean change between samples, 0…1.
    public var motion: Double
    /// Union of the salient objects in the middle frame.
    public var saliency: NormRect?
    /// Image feature print of the middle frame.
    public var featurePrint: [Float]?

    public init(index: Int, start: Seconds, end: Seconds, labels: [String] = [], size: String = "no people", people: Int = 0, text: [String] = [], aesthetics: Double? = nil, utility: Bool? = nil, brightness: Double = 0, motion: Double = 0, saliency: NormRect? = nil, featurePrint: [Float]? = nil) {
        self.index = index
        self.start = start
        self.end = end
        self.labels = labels
        self.size = size
        self.people = people
        self.text = text
        self.aesthetics = aesthetics
        self.utility = utility
        self.brightness = brightness
        self.motion = motion
        self.saliency = saliency
        self.featurePrint = featurePrint
    }

    public var duration: Seconds { end - start }

    /// Shot size from the height of the largest face, or of the largest body when no face is visible.
    public static func size(faceHeight: Double?, bodyHeight: Double?) -> String {
        if let f = faceHeight, f > 0 {
            if f > 0.45 { return "extreme close-up" }
            if f > 0.2 { return "close-up" }
            if f > 0.07 { return "medium" }
            return "wide"
        }
        if let b = bodyHeight, b > 0 { return b > 0.9 ? "medium" : "wide" }
        return "no people"
    }

    /// Spans between cuts, with spans longer than `maxLength` split evenly.
    public static func spans(cuts: [Seconds], duration: Seconds, maxLength: Seconds = 8) -> [TimeRange] {
        let bounds = [0] + cuts.filter { $0 > 0.01 && $0 < duration - 0.01 }.sorted() + [max(duration, 0)]
        var out: [TimeRange] = []
        for (s, e) in zip(bounds, bounds.dropFirst()) where e > s {
            let parts = max(1, Int(ceil((e - s) / maxLength - 1e-9)))
            let step = (e - s) / Double(parts)
            for i in 0..<parts { out.append(TimeRange(s + step * Double(i), i == parts - 1 ? e : s + step * Double(i + 1))) }
        }
        if out.isEmpty { out.append(TimeRange(0, max(duration, 0))) }
        return out
    }
}

public struct FaceSample: Codable, Equatable, Sendable {
    public var t: Seconds
    public var box: NormRect

    public init(t: Seconds, box: NormRect) {
        self.t = t
        self.box = box
    }
}

/// One face followed across samples.
public struct FaceTrack: Codable, Equatable, Sendable {
    public var id: Int
    public var samples: [FaceSample]
    /// The same number on every track showing one person across shots; nil until faces are compared.
    public var person: Int?

    public init(id: Int, samples: [FaceSample], person: Int? = nil) {
        self.id = id
        self.samples = samples
        self.person = person
    }

    public var start: Seconds { samples.first?.t ?? 0 }
    public var end: Seconds { samples.last?.t ?? 0 }

    /// Links per-sample face boxes into tracks by overlap and center distance.
    /// Tracks never span a cut or a gap longer than `maxGap`; tracks with fewer than two samples are dropped.
    public static func link(_ detections: [(t: Seconds, boxes: [NormRect])], cuts: [Seconds] = [], maxGap: Seconds = 1.5) -> [FaceTrack] {
        let cuts = cuts.sorted()
        func segment(_ t: Seconds) -> Int { cuts.firstIndex { $0 > t } ?? cuts.count }
        var tracks: [[FaceSample]] = []
        var open: [Int] = []
        for d in detections.sorted(by: { $0.t < $1.t }) {
            let seg = segment(d.t)
            open.removeAll { i in
                guard let last = tracks[i].last else { return true }
                return d.t - last.t > maxGap || segment(last.t) != seg
            }
            var pairs: [(score: Double, track: Int, box: Int)] = []
            for i in open {
                let last = tracks[i].last!.box
                for (j, b) in d.boxes.enumerated() {
                    let iou = last.iou(b)
                    let dist = last.centerDistance(b)
                    let ratio = min(last.height, b.height) / max(last.height, b.height, 1e-6)
                    guard iou > 0.1 || (dist < 1 && ratio > 0.5) else { continue }
                    pairs.append((iou + max(0, 1 - dist) * 0.5, i, j))
                }
            }
            var usedTracks = Set<Int>(), usedBoxes = Set<Int>()
            for p in pairs.sorted(by: { $0.score > $1.score }) where !usedTracks.contains(p.track) && !usedBoxes.contains(p.box) {
                usedTracks.insert(p.track)
                usedBoxes.insert(p.box)
                tracks[p.track].append(FaceSample(t: d.t, box: d.boxes[p.box]))
            }
            for (j, b) in d.boxes.enumerated() where !usedBoxes.contains(j) {
                tracks.append([FaceSample(t: d.t, box: b)])
                open.append(tracks.count - 1)
            }
        }
        return tracks.filter { $0.count >= 2 }.enumerated().map { FaceTrack(id: $0.offset, samples: $0.element) }
    }
}

/// Visual description of one media file in source time.
public struct ShotAnalysis: Codable, Equatable, Sendable {
    public var mediaId: String
    public var shots: [Shot]
    public var faces: [FaceTrack]
    /// Frames sampled per second for faces, people, brightness and motion.
    public var samplesPerSecond: Double

    public init(mediaId: String, shots: [Shot], faces: [FaceTrack], samplesPerSecond: Double) {
        self.mediaId = mediaId
        self.shots = shots
        self.faces = faces
        self.samplesPerSecond = samplesPerSecond
    }

    public func shot(at t: Seconds) -> Shot? {
        shots.first { t >= $0.start && t < $0.end } ?? shots.last.flatMap { abs(t - $0.end) < 1e-6 ? $0 : nil }
    }

    /// Other shots ranked by feature-print cosine similarity, most similar first.
    public func similarShots(to index: Int, limit: Int) -> [(Shot, Double)] {
        guard let target = shots.first(where: { $0.index == index }), let fp = target.featurePrint else { return [] }
        return shots
            .filter { $0.index != index }
            .compactMap { s in s.featurePrint.map { (s, ShotAnalysis.similarity(fp, $0)) } }
            .sorted { $0.1 > $1.1 }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// Cosine similarity of two feature prints, -1…1; 0 when they cannot be compared.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}

public struct SoundEvent: Codable, Equatable, Sendable {
    public var label: String
    public var start: Seconds
    public var end: Seconds
    /// Highest classifier confidence over the event, 0…1.
    public var confidence: Double

    public init(label: String, start: Seconds, end: Seconds, confidence: Double) {
        self.label = label
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    public var duration: Seconds { end - start }
}

/// Non-speech sounds (and speech) of one media file in source time.
public struct SoundEvents: Codable, Equatable, Sendable {
    public var mediaId: String
    public var events: [SoundEvent]

    public init(mediaId: String, events: [SoundEvent]) {
        self.mediaId = mediaId
        self.events = events
    }

    /// Merges overlapping or touching classifier windows with the same label into events.
    public static func merge(_ windows: [SoundEvent], minConfidence: Double = 0.5, minDuration: Seconds = 0.5, tolerance: Seconds = 0.05) -> [SoundEvent] {
        var out: [SoundEvent] = []
        let byLabel = Dictionary(grouping: windows.filter { $0.confidence >= minConfidence && $0.end > $0.start }, by: \.label)
        for (_, ws) in byLabel {
            var current: SoundEvent?
            for w in ws.sorted(by: { $0.start < $1.start }) {
                if var c = current, w.start <= c.end + tolerance {
                    c.end = max(c.end, w.end)
                    c.confidence = max(c.confidence, w.confidence)
                    current = c
                } else {
                    if let c = current { out.append(c) }
                    current = w
                }
            }
            if let c = current { out.append(c) }
        }
        return out.filter { $0.duration >= minDuration }.sorted { ($0.start, $0.label) < ($1.start, $1.label) }
    }
}
