import Foundation

/// A transition across a cut between two adjacent clips on one track, or over a single clip edge.
///
/// Across a cut the clips keep their timeline positions; the transition borrows media from just
/// past the outgoing clip's end and just before the incoming clip's start (the handles).
/// With only `to`, the incoming clip transitions in from what lies beneath it; with only `from`,
/// the outgoing clip transitions out to what lies beneath.
public struct Transition: Codable, Equatable, Sendable {
    public var id: String
    public var from: String?
    public var to: String?
    public var type: String
    public var duration: Seconds
    public var align: TransitionAlign
    public var part: TransitionPart
    public var ease: Easing
    public var params: [String: ParamValue]

    public init(id: String, from: String?, to: String?, type: String, duration: Seconds, align: TransitionAlign = .center, part: TransitionPart = .both, ease: Easing = .easeInOut, params: [String: ParamValue] = [:]) {
        self.id = id
        self.from = from
        self.to = to
        self.type = type
        self.duration = duration
        self.align = align
        self.part = part
        self.ease = ease
        self.params = params
    }

    enum CodingKeys: String, CodingKey { case id, from, to, type, duration, align, part, ease, params }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        to = try c.decodeIfPresent(String.self, forKey: .to)
        type = try c.decode(String.self, forKey: .type)
        duration = try c.decode(Seconds.self, forKey: .duration)
        align = try c.decodeIfPresent(TransitionAlign.self, forKey: .align) ?? .center
        part = try c.decodeIfPresent(TransitionPart.self, forKey: .part) ?? .both
        ease = try c.decodeIfPresent(Easing.self, forKey: .ease) ?? .easeInOut
        params = try c.decodeIfPresent([String: ParamValue].self, forKey: .params) ?? [:]
    }

    public var hasVideo: Bool { part != .audio }
    public var hasAudio: Bool { part != .video }

    public func number(_ name: String) -> Double {
        params[name]?.number ?? TransitionCatalog.type(type)?.spec(name)?.defaultValue.number ?? 0
    }

    public func string(_ name: String) -> String {
        params[name]?.string ?? TransitionCatalog.type(type)?.spec(name)?.defaultValue.string ?? ""
    }
}

public enum TransitionAlign: String, Codable, Sendable, CaseIterable {
    /// Centered on the cut.
    case center
    /// Starts at the cut, running into the incoming clip.
    case start
    /// Ends at the cut, running over the end of the outgoing clip.
    case end
}

public enum TransitionPart: String, Codable, Sendable, CaseIterable {
    case video, audio, both
}

/// Where a transition sits on the timeline and how much media it borrows.
public struct TransitionWindow: Equatable, Sendable {
    public var transition: Transition
    public var trackId: String
    public var start: Seconds
    public var end: Seconds
    /// Seconds the outgoing clip plays past its end.
    public var tail: Seconds
    /// Seconds the incoming clip plays before its start.
    public var head: Seconds

    public func progress(at t: Seconds) -> Double {
        guard end > start else { return 1 }
        return transition.ease.apply((t - start) / (end - start))
    }

    public func contains(_ t: Seconds) -> Bool { t >= start - 1e-9 && t < end - 1e-9 }
}

extension Project {
    /// Timeline placement of a transition, or why it can't be placed.
    public func window(_ tr: Transition) throws -> TransitionWindow {
        let a = tr.from.flatMap { locateClip($0) }
        let b = tr.to.flatMap { locateClip($0) }
        if let id = tr.from, a == nil { throw EditError("No clip \(id)") }
        if let id = tr.to, b == nil { throw EditError("No clip \(id)") }
        guard tr.duration > 0 else { throw EditError("Transition duration must be positive") }
        switch (a, b) {
        case let (a?, b?):
            guard a.track == b.track else { throw EditError("\(tr.from!) and \(tr.to!) are on different tracks") }
            let ca = tracks[a.track].clips[a.clip], cb = tracks[b.track].clips[b.clip]
            guard b.clip == a.clip + 1, abs(cb.start - ca.end) < canvas.frameDuration / 2 else {
                throw EditError("\(ca.id) and \(cb.id) aren't adjacent: a transition needs \(cb.id) to start where \(ca.id) ends (\(fmt2(ca.end))s), but it starts at \(fmt2(cb.start))s")
            }
            let cut = cb.start, d = tr.duration
            let (s, e): (Seconds, Seconds) = switch tr.align {
            case .center: (cut - d / 2, cut + d / 2)
            case .start: (cut, cut + d)
            case .end: (cut - d, cut)
            }
            return TransitionWindow(transition: tr, trackId: tracks[a.track].id, start: s, end: e, tail: e - cut, head: cut - s)
        case let (a?, nil):
            let c = tracks[a.track].clips[a.clip]
            return TransitionWindow(transition: tr, trackId: tracks[a.track].id, start: c.end - min(tr.duration, c.duration), end: c.end, tail: 0, head: 0)
        case let (nil, b?):
            let c = tracks[b.track].clips[b.clip]
            return TransitionWindow(transition: tr, trackId: tracks[b.track].id, start: c.start, end: c.start + min(tr.duration, c.duration), tail: 0, head: 0)
        default:
            throw EditError("A transition needs from, to, or both")
        }
    }

    /// Windows of every transition that still fits the edit.
    public var transitionWindows: [TransitionWindow] {
        transitions.compactMap { try? window($0) }
    }

    /// Where a transition's sound crossfade sits. Across a cut it is placed on the sound cut, where the outgoing
    /// sound ends and the incoming one begins (midway if they overlap), which a split edit moves off the picture cut.
    /// `tail` and `head` are how far the sounds must run past their pictures' edges; negative when they stop short.
    public func audioWindow(_ tr: Transition) throws -> TransitionWindow {
        let w = try window(tr)
        guard let f = tr.from, let t = tr.to, let a = clip(f), let b = clip(t) else { return w }
        let cut = (a.audioRange.end + b.audioRange.start) / 2, d = tr.duration
        let (s, e): (Seconds, Seconds) = switch tr.align {
        case .center: (cut - d / 2, cut + d / 2)
        case .start: (cut, cut + d)
        case .end: (cut - d, cut)
        }
        return TransitionWindow(transition: tr, trackId: w.trackId, start: s, end: e, tail: e - a.end, head: b.start - s)
    }

    /// Checks a transition against the clips: adjacency, enough media in the handles, and no
    /// overlap with other transitions on the same clips.
    public func checkTransition(_ tr: Transition) throws {
        guard TransitionCatalog.type(tr.type) != nil else {
            throw EditError("Unknown transition \(tr.type). Types: \(TransitionCatalog.all.map(\.id).joined(separator: ", "))")
        }
        let w = try window(tr)
        for id in [tr.from, tr.to].compactMap({ $0 }) where clip(id)?.kind == .adjustment {
            throw EditError("Adjustment clips don't take transitions; animate their mix instead")
        }
        let pictureChecked = tr.hasVideo || tr.from == nil || tr.to == nil
        if pictureChecked, let id = tr.from, let c = clip(id) {
            if w.tail > 0, let avail = handle(c, after: true), avail + 1e-3 < w.tail {
                throw EditError("\(id) has \(fmt2(avail))s of media after its out point but the transition needs \(fmt2(w.tail))s. Use a shorter duration, align:\"end\", or trim \(id) shorter first")
            }
            if w.start < c.start - 1e-6 { throw EditError("The transition is longer than \(id)") }
        }
        if pictureChecked, let id = tr.to, let c = clip(id) {
            if w.head > 0, let avail = handle(c, after: false), avail + 1e-3 < w.head {
                throw EditError("\(id) has \(fmt2(avail))s of media before its in point but the transition needs \(fmt2(w.head))s. Use a shorter duration, align:\"start\", or trim \(id)'s start later first")
            }
            if w.end > c.end + 1e-6 { throw EditError("The transition is longer than \(id)") }
        }
        var aw: TransitionWindow?
        if tr.hasAudio, let f = tr.from, let t = tr.to, let a = clip(f), let b = clip(t) {
            let sw = try audioWindow(tr)
            aw = sw
            if sw.tail > 1e-6, let avail = handle(a, after: true), avail + 1e-3 < sw.tail {
                throw EditError("\(f)'s sound needs \(fmt2(sw.tail))s of media past its picture's end for the crossfade but has \(fmt2(avail))s. Use a shorter duration or align:\"end\"")
            }
            if sw.head > 1e-6, let avail = handle(b, after: false), avail + 1e-3 < sw.head {
                throw EditError("\(t)'s sound needs \(fmt2(sw.head))s of media before its picture's start for the crossfade but has \(fmt2(avail))s. Use a shorter duration or align:\"start\"")
            }
            if sw.start < a.audioRange.start - 1e-6 { throw EditError("The crossfade is longer than \(f)'s sound") }
            if sw.end > b.audioRange.end + 1e-6 { throw EditError("The crossfade is longer than \(t)'s sound") }
        }
        for other in transitions where other.id != tr.id {
            if tr.hasVideo, other.hasVideo, let ow = try? window(other), ow.trackId == w.trackId, ow.start < w.end - 1e-6, w.start < ow.end - 1e-6 {
                throw EditError("Overlaps transition \(other.id) (\(fmt2(ow.start))–\(fmt2(ow.end))s); shorten one of them")
            }
            if let aw, other.hasAudio, let ow = try? audioWindow(other), ow.trackId == aw.trackId, ow.start < aw.end - 1e-6, aw.start < ow.end - 1e-6 {
                throw EditError("Its crossfade overlaps transition \(other.id)'s (\(fmt2(ow.start))–\(fmt2(ow.end))s); shorten one of them")
            }
        }
    }

    /// Seconds of media available past a clip's end (`after`) or before its start, or nil when unlimited.
    func handle(_ c: Clip, after: Bool) -> Seconds? {
        guard c.kind == .media, let m = c.mediaId.flatMap({ mediaAsset($0) }), !m.isImage else { return nil }
        if c.reverse { return 0 }
        let edge = max(c.speed(atLocal: after ? c.duration : 0), 0.01)
        return after ? max(0, (m.duration - c.sourceOut) / edge) : max(0, c.sourceIn / edge)
    }

    /// Drops transitions whose clips are gone; follows clips that were split or renamed by id.
    public mutating func pruneTransitions() {
        var kept: [Transition] = []
        for tr in transitions {
            var probe = self
            probe.transitions = kept
            if (try? probe.checkTransition(tr)) != nil { kept.append(tr) }
        }
        transitions = kept
    }

    public func nextTransitionId() -> String {
        let used = Set(transitions.map(\.id))
        var n = 1
        while used.contains("tr\(n)") { n += 1 }
        return "tr\(n)"
    }

    /// The project with audio crossfades written into the clips' sound: the outgoing clip's sound
    /// runs on (or stops) to the end of the crossfade and fades out across it while the incoming one fades in. Idempotent.
    public func resolvingAudioTransitions() -> Project {
        var p = self
        for (i, tr) in transitions.enumerated() where tr.hasAudio {
            guard let w = try? audioWindow(tr) else { continue }
            if let id = tr.from, let loc = p.locateClip(id) {
                var c = p.tracks[loc.track].clips[loc.clip]
                c.audioLag = max(c.audioLag, w.tail)
                c.audioFadeOut = max(c.audioFadeOut, w.end - w.start)
                p.tracks[loc.track].clips[loc.clip] = c
            }
            if let id = tr.to, let loc = p.locateClip(id) {
                var c = p.tracks[loc.track].clips[loc.clip]
                c.audioLead = max(c.audioLead, w.head)
                c.audioFadeIn = max(c.audioFadeIn, w.end - w.start)
                p.tracks[loc.track].clips[loc.clip] = c
            }
            p.transitions[i].part = .video
        }
        let audioOnly = Set(transitions.filter { $0.part == .audio }.map(\.id))
        p.transitions.removeAll { audioOnly.contains($0.id) }
        return p
    }
}

/// Every transition the engine can render.
public enum TransitionCatalog {
    public static func type(_ id: String) -> EffectType? { byId[id] }

    static let direction = ParamSpec("direction", .choice(["left", "right", "up", "down"]), .string("left"), "Which way the motion goes")
    static let softness = ParamSpec("softness", .number, .number(0.05), min: 0, max: 0.5, unit: "of frame", "Edge softness")

    public static let all: [EffectType] = [
        EffectType(id: "dissolve", category: "transition", summary: "Cross-dissolve: the outgoing picture fades into the incoming one", params: []),
        EffectType(id: "dip", category: "transition", summary: "Fade to a color, then up from it (dip to black or white)", params: [
            ParamSpec("color", .color, .string("#000000"), animatable: false, "Color to dip through"),
            ParamSpec("hold", .number, .number(0), min: 0, max: 0.8, animatable: false, "Fraction of the duration spent fully on the color"),
        ]),
        EffectType(id: "flash", category: "transition", summary: "Quick bright flash that hides the cut", params: [
            ParamSpec("color", .color, .string("#FFFFFF"), animatable: false, "Flash color"),
            ParamSpec("intensity", .number, .number(1), min: 0, max: 1, animatable: false, "Peak strength"),
        ]),
        EffectType(id: "wipe", category: "transition", summary: "A moving edge reveals the incoming picture", params: [
            direction, softness,
            ParamSpec("angle", .number, .number(0), min: -45, max: 45, unit: "degrees", animatable: false, "Tilt of the edge"),
        ]),
        EffectType(id: "iris", category: "transition", summary: "A growing circle reveals the incoming picture", params: [
            softness,
            ParamSpec("center_x", .number, .number(0.5), min: 0, max: 1, animatable: false, "Circle center, 0 left to 1 right"),
            ParamSpec("center_y", .number, .number(0.5), min: 0, max: 1, animatable: false, "Circle center, 0 top to 1 bottom"),
        ]),
        EffectType(id: "slide", category: "transition", summary: "The incoming picture slides in over the outgoing one", params: [direction]),
        EffectType(id: "push", category: "transition", summary: "The incoming picture pushes the outgoing one off screen", params: [direction]),
        EffectType(id: "zoom", category: "transition", summary: "Punch through: the outgoing picture zooms in and dissolves into the incoming one settling from a zoom", params: [
            ParamSpec("amount", .number, .number(0.4), min: 0.05, max: 3, animatable: false, "Extra scale at the peak"),
            ParamSpec("blur", .number, .number(0.02), min: 0, max: 0.2, unit: "of frame height", animatable: false, "Zoom blur at the peak"),
        ]),
        EffectType(id: "whip", category: "transition", summary: "Whip pan: a fast motion-blurred push", params: [
            direction,
            ParamSpec("blur", .number, .number(0.08), min: 0, max: 0.3, unit: "of frame height", animatable: false, "Streak length at the peak"),
        ]),
        EffectType(id: "blur", category: "transition", summary: "The outgoing picture blurs out as the incoming one blurs in", params: [
            ParamSpec("radius", .number, .number(0.03), min: 0, max: 0.2, unit: "of frame height", animatable: false, "Peak blur"),
        ]),
        EffectType(id: "spin", category: "transition", summary: "Rotational blur spin between the pictures", params: [
            ParamSpec("turns", .number, .number(0.25), min: -2, max: 2, animatable: false, "Rotation at the peak, in turns"),
        ]),
        EffectType(id: "glitch", category: "transition", summary: "Digital glitch: RGB split and pixelated slices around the cut", params: [
            ParamSpec("intensity", .number, .number(0.6), min: 0, max: 1, animatable: false, "Strength"),
        ]),
    ]

    static let byId = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
