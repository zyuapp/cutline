import Foundation

/// One audio track (or group of channels) of a delivered master: what it carries, its layout and its name.
public struct AudioTrackSpec: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        /// The master mix, through the master effects and conformed to the master loudness target.
        case mix
        /// Music and effects: everything but dialogue, pre-master.
        case musicAndEffects
        /// One top-level bus's path to the master, pre-master.
        case bus(String)
        /// One stem: dialogue, music, effects, ambience or a custom role, pre-master.
        case role(String)
        case silence
        /// Line-up tone, 1 kHz at −20 dBFS, for the whole file.
        case tone
    }

    public var content: Content
    public var layout: AudioLayout
    public var name: String

    public init(_ content: Content, layout: AudioLayout? = nil, name: String? = nil) {
        self.content = content
        self.layout = layout ?? content.defaultLayout
        self.name = name ?? content.defaultName(self.layout)
    }

    /// One name per channel: "Mix L", "Mix R", "DIA".
    public var channelNames: [String] {
        layout == .mono ? [name] : layout.channelNames.map { "\(name) \($0)" }
    }

    /// The compact form `parse` reads back: "mix", "dia@stereo", "bus:DIA".
    public var token: String {
        let base = content.token
        return layout == content.defaultLayout ? base : base + "@" + layout.title
    }

    /// How tracks fold into a QuickTime file: one track each, or every channel in one track.
    public enum Packing: String, CaseIterable, Sendable { case tracks, channels }

    /// Named layouts. broadcast_8ch: ch1-2 stereo mix, ch3-4 stereo M&E, ch5-8 mono DIA, MUS, FX, AMB.
    public static let presets: [(name: String, layout: String)] = [
        ("broadcast_8ch", "mix,me,dia,mus,fx,amb"),
        ("mix_me", "mix,me"),
        ("netflix_51_20", "mix@5.1,mix"),
        ("netflix_51_20_me", "mix@5.1,mix,me@5.1,me"),
        ("stems", "dia,mus,fx,amb"),
    ]

    /// A preset name or a comma-separated list of tokens, each `content[@layout]`: mix, me, dia, mus, fx, amb,
    /// bus:<id>, role:<name>, silence, tone; layouts mono, stereo, 5.1, 7.1.
    public static func parse(_ text: String) throws -> [AudioTrackSpec] {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let preset = presets.first(where: { $0.name == t.lowercased() }) { return try parse(preset.layout) }
        let tokens = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw EditError("audio_tracks is empty; use a preset (\(presets.map(\.name).joined(separator: ", "))) or a list like \"mix,me,dia,mus,fx,amb\"") }
        return try tokens.map { tok in
            let parts = tok.split(separator: "@", maxSplits: 1).map(String.init)
            let layout = try parts.count > 1 ? parseLayout(parts[1]) : nil
            return AudioTrackSpec(try parseContent(parts[0]), layout: layout)
        }
    }

    public static func parseLayout(_ s: String) throws -> AudioLayout {
        guard let l = AudioLayout(name: s.lowercased()) else { throw EditError("Audio track layout \(s) isn't one of mono, stereo, 5.1, 7.1") }
        return l
    }

    public static func parseContent(_ s: String) throws -> Content {
        let k = s.trimmingCharacters(in: .whitespaces)
        let lower = k.lowercased()
        switch lower {
        case "mix", "printmaster": return .mix
        case "me", "m&e", "music_and_effects": return .musicAndEffects
        case "dia", "dialogue", "dx": return .role("dialogue")
        case "mus", "music", "mx": return .role("music")
        case "fx", "effects", "sfx": return .role("effects")
        case "amb", "ambience", "atmos": return .role("ambience")
        case "silence", "silent", "none": return .silence
        case "tone": return .tone
        default: break
        }
        if lower.hasPrefix("bus:"), k.count > 4 { return .bus(String(k.dropFirst(4))) }
        if lower.hasPrefix("role:"), k.count > 5 { return .role(Project.stemSlot(String(k.dropFirst(5)), trackName: "")) }
        throw EditError("Audio track content \(s) isn't mix, me, dia, mus, fx, amb, bus:<id>, role:<name>, silence or tone")
    }

    /// Every channel of the layout in order: which track it is in and its name.
    public static func channels(_ specs: [AudioTrackSpec]) -> [(track: Int, name: String)] {
        specs.enumerated().flatMap { i, s in s.channelNames.map { (i, $0) } }
    }

    /// "ch1-2 Mix (stereo), ch3-4 M&E (stereo), ch5 DIA".
    public static func describe(_ specs: [AudioTrackSpec]) -> String {
        var at = 1
        return specs.map { s in
            let n = s.layout.channelCount
            defer { at += n }
            return (n == 1 ? "ch\(at)" : "ch\(at)-\(at + n - 1)") + " \(s.name) (\(s.layout.title))"
        }.joined(separator: ", ")
    }
}

extension AudioTrackSpec.Content {
    var defaultLayout: AudioLayout {
        switch self {
        case .mix, .musicAndEffects: .stereo
        default: .mono
        }
    }

    var token: String {
        switch self {
        case .mix: "mix"
        case .musicAndEffects: "me"
        case .bus(let id): "bus:\(id)"
        case .role("dialogue"): "dia"
        case .role("music"): "mus"
        case .role("effects"): "fx"
        case .role("ambience"): "amb"
        case .role(let r): "role:\(r)"
        case .silence: "silence"
        case .tone: "tone"
        }
    }

    func defaultName(_ layout: AudioLayout) -> String {
        switch self {
        case .mix: layout.isSurround ? "Mix \(layout.title)" : "Mix"
        case .musicAndEffects: layout.isSurround ? "M&E \(layout.title)" : "M&E"
        case .bus(let id): id
        case .role("dialogue"): "DIA"
        case .role("music"): "MUS"
        case .role("effects"): "FX"
        case .role("ambience"): "AMB"
        case .role(let r): r.uppercased()
        case .silence: "Silence"
        case .tone: "Tone"
        }
    }

    /// Whether it carries timeline sound.
    public var isProgram: Bool {
        switch self {
        case .silence, .tone: false
        default: true
        }
    }
}

extension Project {
    static let ambienceWords: Set<String> = ["ambience", "ambiance", "amb", "ambient", "atmos", "atmosphere", "atmospheres", "bg", "bgs", "background", "backgrounds"]

    /// The stem a role plays in for audio track layouts: dialogue, music, effects, ambience (effects whose role or
    /// track name says ambience, atmos or BG) or a custom role, lowercased.
    public static func stemSlot(_ role: String, trackName: String) -> String {
        let main = normalizedRole(stemRole(role))
        guard main == "effects" else { return main }
        func words(_ s: String) -> Set<String> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)) }
        return words(role).isDisjoint(with: ambienceWords) && words(trackName).isDisjoint(with: ambienceWords) ? "effects" : "ambience"
    }

    /// The project with only clips whose stem slot passes `keep` audible; `roles` gives each track's role.
    /// Tracks left with no such clip are muted, so the slots sum back to the mix.
    public func keepingStemSlots(_ roles: [String: String], _ keep: (String) -> Bool) -> Project {
        var p = self
        for t in p.tracks.indices {
            let track = p.tracks[t]
            let trackRole = track.role ?? roles[track.id]
            var any = false
            for c in track.clips.indices {
                let clip = track.clips[c]
                guard clip.kind == .media || clip.kind == .sequence else { continue }
                if keep(Project.stemSlot(Project.role(of: clip, trackRole: trackRole) ?? "effects", trackName: track.name)) {
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

    /// Stem slots in use, with the tracks playing them.
    public func stemSlots(_ roles: [String: String]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for t in tracks {
            let trackRole = t.role ?? roles[t.id]
            var used = Set<String>()
            for c in t.clips where c.kind == .sequence || (c.kind == .media && (c.mediaId.flatMap { mediaAsset($0) }?.hasAudio ?? false)) {
                used.insert(Project.stemSlot(Project.role(of: c, trackRole: trackRole) ?? "effects", trackName: t.name))
            }
            for s in used.sorted() { out[s, default: []].append(t.id) }
        }
        return out
    }

    /// Timeline spans of audible clips in the dialogue stem: the dialogue gate when nothing is transcribed.
    public func dialogueClipSpans(_ roles: [String: String]) -> [TimeRange] {
        var out: [TimeRange] = []
        for t in tracks where !t.muted {
            let trackRole = t.role ?? roles[t.id]
            for c in t.clips where (c.kind == .media || c.kind == .sequence) && c.volume > 0 {
                if Project.stemSlot(Project.role(of: c, trackRole: trackRole) ?? "effects", trackName: t.name) == "dialogue" { out.append(TimeRange(c.start, c.start + c.duration)) }
            }
        }
        return TimeRange.merged(out)
    }

    /// The project whose mix is a track's content: itself for the mix, else pre-master (master effects and
    /// loudness target off) with only that content audible; nil for silence and tone. The effects stem also takes
    /// stems no other track of `layout` carries (ambience, custom roles), so DIA + MUS + FX (+ AMB) sum to the mix.
    public func audioTrackSource(_ content: AudioTrackSpec.Content, roles: [String: String], layout: [AudioTrackSpec]) throws -> Project? {
        var base = self
        base.master.effects = []
        base.master.loudnessTarget = nil
        let placed = Set(layout.compactMap { s -> String? in if case .role(let r) = s.content { return r } else { return nil } })
        switch content {
        case .mix: return self
        case .silence, .tone: return nil
        case .musicAndEffects: return base.keepingStemSlots(roles) { $0 != "dialogue" }
        case .role(let r):
            if r == "effects" { return base.keepingStemSlots(roles) { $0 == "effects" || (!placed.contains($0) && $0 != "dialogue" && $0 != "music") } }
            return base.keepingStemSlots(roles) { $0 == r }
        case .bus(let id):
            guard let bus = bus(id) else { throw EditError("No bus \(id)" + (buses.isEmpty ? "; add buses with audio_bus or recipe dme_buses" : ". Buses: " + buses.map(\.id).joined(separator: ", "))) }
            if let parent = bus.output { throw EditError("Bus \(id) feeds \(parent); an audio track takes a bus feeding the master (\(topLevelBuses.map(\.id).joined(separator: ", ")))") }
            return base.isolatingBus(id)
        }
    }
}
