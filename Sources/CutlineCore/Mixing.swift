import Foundation

/// A submix: tracks (and other buses) feed it, its effects and fader process their sum, and it feeds the
/// master or another bus. Tracks reach buses through their `output` and their `sends`.
public struct AudioBus: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Audio effects on the bus sum, in order (EQ, compressor, limiter, reverb, Audio Units…).
    public var effects: [Effect]
    /// Fader gain after the effects.
    public var volume: Double
    /// Fader automation over timeline time, replacing `volume` where set.
    public var volumeCurve: Curve?
    public var muted: Bool
    /// While any bus is soloed, only soloed buses, the buses feeding them and the path to the master are heard.
    public var solo: Bool
    /// The bus this one feeds; nil is the master.
    public var output: String?
    /// Channel layout of the bus; nil follows the mix (stereo under a mono master). Inputs fold into it.
    public var layout: AudioLayout?

    public init(id: String, name: String? = nil, effects: [Effect] = [], volume: Double = 1, volumeCurve: Curve? = nil, muted: Bool = false, solo: Bool = false, output: String? = nil, layout: AudioLayout? = nil) {
        self.id = id
        self.name = name ?? id
        self.effects = effects
        self.volume = volume
        self.volumeCurve = volumeCurve
        self.muted = muted
        self.solo = solo
        self.output = output
        self.layout = layout
    }

    enum CodingKeys: String, CodingKey { case id, name, effects, volume, volumeCurve, muted, solo, output, layout }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        effects = try c.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        volumeCurve = try c.decodeIfPresent(Curve.self, forKey: .volumeCurve)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        output = try c.decodeIfPresent(String.self, forKey: .output)
        layout = try c.decodeIfPresent(AudioLayout.self, forKey: .layout)
    }

    public func volume(at t: Seconds) -> Double { volumeCurve?.value(at: t)?.number ?? volume }

    public var hasEffects: Bool { effects.contains { EffectCatalog.isAudio($0.type) && $0.enabled } }
}

/// A copy of a track's sound into a bus, at `levelDb`, taken after the track fader or before it.
public struct AudioSend: Codable, Equatable, Hashable, Sendable {
    public var bus: String
    public var levelDb: Double
    /// Taken before the track fader and its automation (after clip gain and track effects).
    public var preFader: Bool

    public init(bus: String, levelDb: Double = 0, preFader: Bool = false) {
        self.bus = bus
        self.levelDb = levelDb
        self.preFader = preFader
    }

    enum CodingKeys: String, CodingKey { case bus, levelDb, preFader }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bus = try c.decode(String.self, forKey: .bus)
        levelDb = try c.decodeIfPresent(Double.self, forKey: .levelDb) ?? 0
        preFader = try c.decodeIfPresent(Bool.self, forKey: .preFader) ?? false
    }

    public var gain: Double { levelDb <= -96 ? 0 : pow(10, levelDb / 20) }
}

/// Which parts of the routing are heard under the buses' mute and solo.
public struct MixRouting: Sendable {
    /// Buses whose sum is needed, every bus after the buses that feed it.
    public let order: [AudioBus]
    let heardBuses: Set<String>
    let inputs: Set<String>
    let soloing: Bool

    /// Whether a bus's output reaches the master.
    public func busHeard(_ id: String) -> Bool { heardBuses.contains(id) }

    /// Whether sound sent to `bus` (nil: the master) is heard.
    public func destinationHeard(_ bus: String?) -> Bool {
        guard let bus else { return !soloing }
        return heardBuses.contains(bus) && inputs.contains(bus)
    }
}

extension Project {
    public func bus(_ id: String) -> AudioBus? { buses.first { $0.id == id } }

    /// Whether the mix goes through buses: any bus exists, or a track has an output or sends.
    public var usesBuses: Bool { !buses.isEmpty || tracks.contains { $0.output != nil || !$0.sends.isEmpty } }

    /// A clip's audio role: its own, else its track's.
    public static func role(of clip: Clip, trackRole: String?) -> String? { clip.role ?? trackRole }

    /// Every bus id `id` feeds, nearest first.
    public func busChain(from id: String) -> [String] {
        var out: [String] = []
        var at = bus(id)?.output
        while let next = at, !out.contains(next), next != id {
            out.append(next)
            at = bus(next)?.output
        }
        return out
    }

    /// Rejects unknown or looping outputs, sends to unknown buses and out-of-range levels.
    public func validateRouting() throws {
        var ids = Set<String>()
        for b in buses {
            guard b.id.range(of: #"^[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { throw EditError("Bus ids are letters, digits, _ and -, starting with a letter; got \"\(b.id)\"") }
            guard b.id.lowercased() != "master" else { throw EditError("\"master\" is the master bus; name the bus something else") }
            guard trackIndex(b.id) == nil else { throw EditError("Bus \(b.id) has the same id as a track") }
            guard ids.insert(b.id).inserted else { throw EditError("Two buses are called \(b.id)") }
            guard b.volume >= 0, b.volume <= 4 else { throw EditError("Bus \(b.id) volume must be 0…4") }
        }
        for b in buses {
            if let o = b.output {
                guard o != b.id else { throw EditError("Bus \(b.id) can't feed itself") }
                guard ids.contains(o) else { throw EditError("Bus \(b.id) feeds unknown bus \(o)") }
            }
            var seen: Set<String> = [b.id]
            var at = b.output
            while let next = at {
                guard seen.insert(next).inserted else { throw EditError("Bus routing loops back through \(next) (from \(b.id)); a bus can't feed one that feeds it") }
                at = bus(next)?.output
            }
        }
        for t in tracks {
            if let o = t.output, !ids.contains(o) { throw EditError("Track \(t.id) feeds unknown bus \(o)" + (buses.isEmpty ? "; add it with audio_bus first" : ". Buses: " + buses.map(\.id).joined(separator: ", "))) }
            var sent = Set<String>()
            for s in t.sends {
                guard ids.contains(s.bus) else { throw EditError("Track \(t.id) sends to unknown bus \(s.bus)") }
                guard sent.insert(s.bus).inserted else { throw EditError("Track \(t.id) sends to \(s.bus) twice") }
                guard s.levelDb <= 12 else { throw EditError("Send levels are at most +12 dB") }
            }
        }
    }

    /// Buses in processing order with what mute and solo let through.
    public func mixRouting() -> MixRouting {
        var order: [AudioBus] = []
        var placed = Set<String>()
        var pending = buses
        while !pending.isEmpty {
            let ready = pending.filter { b in pending.allSatisfy { $0.output != b.id } }
            // Loops are rejected by validation; should one get here, the rest go in project order.
            let next = ready.isEmpty ? pending : ready
            for b in next where !placed.contains(b.id) {
                order.append(b)
                placed.insert(b.id)
            }
            pending.removeAll { placed.contains($0.id) }
        }
        let soloed = Set(buses.filter(\.solo).map(\.id))
        var below = soloed
        var above = Set<String>()
        for b in buses {
            let chain = busChain(from: b.id)
            if !soloed.isDisjoint(with: chain) { below.insert(b.id) }
            if soloed.contains(b.id) { above.formUnion(chain) }
        }
        var heard = Set<String>()
        for b in buses where !b.muted {
            let path = busChain(from: b.id)
            guard !path.contains(where: { bus($0)?.muted == true }) else { continue }
            if soloed.isEmpty || below.contains(b.id) || above.contains(b.id) { heard.insert(b.id) }
        }
        let inputs = soloed.isEmpty ? Set(buses.map(\.id)) : below
        return MixRouting(order: order, heardBuses: heard, inputs: inputs, soloing: !soloed.isEmpty)
    }

    /// Removes a bus; what fed it feeds its output instead and sends to it are dropped.
    public mutating func removeBus(_ id: String) throws {
        guard let b = bus(id) else { throw EditError("No bus \(id)") }
        for i in tracks.indices {
            if tracks[i].output == id { tracks[i].output = b.output }
            tracks[i].sends.removeAll { $0.bus == id }
        }
        for i in buses.indices where buses[i].output == id { buses[i].output = b.output }
        buses.removeAll { $0.id == id }
    }

    /// The project with only clips whose role passes `keep` audible; `roles` gives each track's role.
    /// Tracks left with no such clip are muted, so every role's stem sums back to the mix.
    public func keepingRoles(_ roles: [String: String], _ keep: (String) -> Bool) -> Project {
        var p = self
        for t in p.tracks.indices {
            let trackRole = roles[p.tracks[t].id] ?? p.tracks[t].role
            var any = false
            for c in p.tracks[t].clips.indices {
                let clip = p.tracks[t].clips[c]
                guard clip.kind == .media || clip.kind == .sequence else { continue }
                if keep(Project.role(of: clip, trackRole: trackRole) ?? "effects") {
                    any = true
                } else {
                    p.tracks[t].clips[c].volume = 0
                    p.tracks[t].clips[c].anim["audio.volume"] = nil
                }
            }
            if !any { p.tracks[t].muted = true }
        }
        return p
    }

    /// Every audio role in use: tracks' roles and clips' own roles.
    public func audioRoles(_ roles: [String: String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for t in tracks {
            guard let trackRole = roles[t.id] else { continue }
            var used = Set<String>()
            for c in t.clips where c.kind == .sequence || (c.kind == .media && (c.mediaId.flatMap { mediaAsset($0) }?.hasAudio ?? false)) {
                used.insert(c.role ?? trackRole)
            }
            for r in used.sorted() { out[r, default: []].append(t.id) }
        }
        return out
    }

    /// Buses that feed the master directly, in project order.
    public var topLevelBuses: [AudioBus] { buses.filter { $0.output == nil } }

    /// The mix with only `bus`'s path to the master heard (nil: only tracks routed straight to the master).
    /// Other top-level buses are muted; tracks routed to the master go to a muted stand-in bus so their sends still play.
    public func isolatingBus(_ id: String?) -> Project {
        var p = self
        for i in p.buses.indices where p.buses[i].output == nil && p.buses[i].id != id { p.buses[i].muted = true }
        guard id != nil else { return p }
        let off = "stem_off"
        p.buses.append(AudioBus(id: off, muted: true))
        for i in p.tracks.indices where p.tracks[i].output == nil { p.tracks[i].output = off }
        return p
    }

    /// Whether any audible track feeds the master without a bus.
    public var hasDirectSound: Bool {
        tracks.contains { t in t.output == nil && !t.muted && t.clips.contains { $0.kind == .media || $0.kind == .sequence } }
    }

    /// Creates DIA, MUS and FX buses (or reuses them), routes each track by its role, else its name, else its
    /// detected role, adds a light compressor to DIA and a limiter to the master. `roles` are detected track roles.
    public mutating func applyDMEBuses(roles: [String: String], compressor: Bool = true, limiter: Bool = true) -> [String] {
        let plan = [("DIA", "Dialogue"), ("MUS", "Music"), ("FX", "Effects")]
        var lines: [String] = []
        for (id, name) in plan where bus(id) == nil {
            buses.append(AudioBus(id: id, name: name))
            lines.append("added bus \(id) \"\(name)\"")
        }
        if compressor, let i = buses.firstIndex(where: { $0.id == "DIA" }), !buses[i].effects.contains(where: { $0.type == "audio.compressor" }) {
            buses[i].effects.append(Effect(id: "bus_comp", type: "audio.compressor", params: ["threshold": .number(-20), "headroom": .number(10), "attack_ms": .number(15), "release_ms": .number(200), "makeup": .number(0)]))
            lines.append("DIA: light compressor (threshold −20 dB, headroom 10 dB)")
        }
        if limiter, !master.effects.contains(where: { $0.type == "audio.limiter" }) {
            master.effects.append(Effect(id: "master_limiter", type: "audio.limiter", params: ["ceiling": .number(-1), "release_ms": .number(10)]))
            lines.append("master: limiter at −1 dBFS")
        }
        for i in tracks.indices where tracks[i].clips.contains(where: { $0.kind == .media || $0.kind == .sequence }) {
            let t = tracks[i]
            let role = t.role.map(Project.normalizedRole) ?? Project.roleFromName(t.name) ?? roles[t.id].map(Project.normalizedRole) ?? (t.kind == .audio ? "music" : "dialogue")
            let target = role == "dialogue" ? "DIA" : role == "music" ? "MUS" : "FX"
            guard t.output != target else { continue }
            tracks[i].output = target
            lines.append("\(t.id) \"\(t.name)\" (\(role)) → \(target)")
        }
        return lines
    }

    static func normalizedRole(_ r: String) -> String {
        roleFromName(r) ?? r.lowercased()
    }

    /// dialogue, music or effects from words like "VO", "Score", "SFX", "Room tone".
    static func roleFromName(_ name: String) -> String? {
        let words = Set(name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let n = name.lowercased()
        if !words.isDisjoint(with: ["dialogue", "dialog", "dia", "dx", "vo", "voice", "voiceover", "narration", "interview", "speech", "adr", "boom", "lav"]) { return "dialogue" }
        if !words.isDisjoint(with: ["music", "mus", "mx", "score", "song", "songs"]) { return "music" }
        if !words.isDisjoint(with: ["effects", "fx", "sfx", "foley", "ambience", "ambiance", "amb", "bg", "bgs", "atmos", "hits", "whooshes"]) || n.contains("room tone") || n.contains("roomtone") { return "effects" }
        return nil
    }
}

extension Project {
    func busChanges(from old: Project) -> [String] {
        var out: [String] = []
        let before = Dictionary(old.buses.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Set(buses.map(\.id))
        for b in buses {
            guard let o = before[b.id] else {
                out.append("+ bus \(b.id) \"\(b.name)\" → \(b.output ?? "master")")
                continue
            }
            guard o != b else { continue }
            var f: [String] = []
            if o.name != b.name { f.append("name") }
            if o.output != b.output { f.append("output \(o.output ?? "master")→\(b.output ?? "master")") }
            if o.volume != b.volume { f.append("volume \(fmt2(o.volume))→\(fmt2(b.volume))") }
            if o.volumeCurve != b.volumeCurve { f.append(b.volumeCurve == nil ? "volume automation removed" : "volume automation (\(b.volumeCurve!.keys.count) keys)") }
            if o.muted != b.muted { f.append(b.muted ? "muted" : "unmuted") }
            if o.solo != b.solo { f.append(b.solo ? "soloed" : "unsoloed") }
            if o.layout != b.layout { f.append("layout \(b.layout?.title ?? "mix")") }
            if o.effects != b.effects { f.append("effects " + b.effects.map { "\($0.id)(\($0.type))" }.joined(separator: " → ").ifEmpty("none")) }
            out.append("~ bus \(b.id): " + f.joined(separator: ", "))
        }
        for b in old.buses where !now.contains(b.id) { out.append("- bus \(b.id)") }
        return out
    }
}
