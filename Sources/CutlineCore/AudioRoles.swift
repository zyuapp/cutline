import Foundation

/// Peak level of every source channel of one media file, per window of source time.
public struct ChannelLevels: Codable, Equatable, Sendable {
    public var mediaId: String
    /// Windows per second.
    public var rate: Double
    /// `levels[c][i]`: ch(c+1)'s peak in window i, dBFS clamped to −80.
    public var levels: [[Float]]

    public init(mediaId: String, rate: Double, levels: [[Float]]) {
        self.mediaId = mediaId
        self.rate = rate
        self.levels = levels
    }
}

/// What analysis knows about each media file's sound, keyed by media id.
public struct SoundEvidence: Sendable {
    public var transcripts: [String: Transcript]
    /// Levels of what analysis heard (the analysis channel).
    public var audio: [String: AudioAnalysis]
    public var channels: [String: ChannelLevels]
    public var beats: [String: BeatAnalysis]
    public var sounds: [String: SoundEvents]

    public init(transcripts: [String: Transcript] = [:], audio: [String: AudioAnalysis] = [:], channels: [String: ChannelLevels] = [:], beats: [String: BeatAnalysis] = [:], sounds: [String: SoundEvents] = [:]) {
        self.transcripts = transcripts
        self.audio = audio
        self.channels = channels
        self.beats = beats
        self.sounds = sounds
    }
}

/// A clip's or track's audio role and why.
public struct RoleGuess: Equatable, Sendable {
    public enum Basis: String, Sendable {
        /// Set on the clip or track.
        case explicit
        /// Speech, music or sound found by analysis.
        case evidence
        /// The track's name ("VO", "Score", "SFX").
        case name
        /// Below the silence floor, muted, or media without sound.
        case silent
        /// Nothing to go on: not analyzed.
        case unknown
    }

    /// dialogue, music, effects, or an explicit custom role; nil for silent or unknown.
    public var role: String?
    public var basis: Basis
    /// "speech 88% of its length".
    public var why: String
    public var speechFraction = 0.0
    public var musicFraction = 0.0
    /// Timeline spans of speech, words bridged across short pauses.
    public var speech: [TimeRange] = []

    public init(role: String?, basis: Basis, why: String) {
        self.role = role
        self.basis = basis
        self.why = why
    }

    /// The main role: "dialogue" for "dialogue.room tone".
    public var mainRole: String? { role.map(Project.normalizedRole) }
}

/// Roles of every track and clip with sound.
public struct RoleInference: Sendable {
    public var tracks: [String: RoleGuess] = [:]
    public var clips: [String: RoleGuess] = [:]
    /// Track ids in project order.
    public var order: [String] = []

    /// Each track's main role; tracks without one are left out.
    public var trackRoles: [String: String] { tracks.compactMapValues(\.mainRole) }

    /// Track roles for stems: tracks with sound but no known role fall in effects so every stem sums back to the mix.
    public var stemRoles: [String: String] {
        var out = trackRoles
        for (id, g) in tracks where g.role == nil && g.basis == .unknown { out[id] = "effects" }
        return out
    }

    /// Whether a clip carries speech: its own role or evidence says dialogue, or it's unknown on a dialogue track.
    public func isSpeech(_ clipId: String, track: String) -> Bool {
        guard let g = clips[clipId] else { return tracks[track]?.mainRole == "dialogue" }
        if g.basis != .explicit, let t = tracks[track], t.basis == .explicit { return t.mainRole == "dialogue" }
        switch g.basis {
        case .explicit, .evidence, .name: return g.mainRole == "dialogue"
        case .silent: return false
        case .unknown: return tracks[track]?.mainRole == "dialogue"
        }
    }

    /// Timeline spans of speech on these tracks (every track when empty), from dialogue clips only unless `anyRole`.
    public func speechRanges(_ p: Project, trackIds: [String] = [], anyRole: Bool = false, bridge: Seconds = 0.6) -> [TimeRange] {
        var spans: [TimeRange] = []
        for t in p.flattenedForSound where trackIds.isEmpty || trackIds.contains(t.id) {
            for c in t.clips { if let g = clips[c.id], anyRole || isSpeech(c.id, track: t.id) { spans += g.speech } }
        }
        return TimeRange.merged(spans, tolerance: bridge)
    }

    /// "A2 "Interview ch2" → dialogue: speech 88% of its length", one per track with sound.
    public func lines(_ p: Project, target: (String) -> String = { $0 }) -> [String] {
        order.compactMap { id in
            guard let g = tracks[id], let t = p.tracks.first(where: { $0.id == id }) else { return nil }
            let name = "\(id) \"\(t.name)\""
            guard let r = g.mainRole else { return "\(name): no role, \(g.why)" }
            return "\(name) → \(target(r)): \(g.why)"
        }
    }
}

extension Project {
    /// Role of room tone made by room_tone and fill_gaps: dialogue, subrole room tone.
    public static let roomToneRole = "dialogue.room tone"
    /// Share of a clip's length in speech that makes it dialogue.
    static let speechShare = 0.25
    /// Peak level under which a window counts as silent.
    static let silenceFloorDb: Float = -50

    /// Each clip's and track's audio role from evidence: transcript words in the range it plays for the channels it
    /// plays, speech and music sound events, beats and levels. Roles set on a clip or track win; a track without one
    /// takes the role most of its clips' length has, else what its name says. Silent clips and tracks get none.
    public func inferRoles(_ e: SoundEvidence) -> RoleInference {
        var out = RoleInference()
        for t in flattenedForSound {
            guard t.clips.contains(where: { $0.kind == .media && $0.mediaId.flatMap { mediaAsset($0) }?.isImage == false }) else { continue }
            out.order.append(t.id)
            var guesses: [(Clip, RoleGuess)] = []
            for c in t.clips where c.kind == .media {
                let g = clipRole(c, e)
                out.clips[c.id] = g
                guesses.append((c, g))
            }
            out.tracks[t.id] = trackRole(t, guesses)
        }
        return out
    }

    func trackRole(_ t: Track, _ guesses: [(Clip, RoleGuess)]) -> RoleGuess {
        if let r = t.role, !r.isEmpty { return RoleGuess(role: r, basis: .explicit, why: "role \(r) set on the track") }
        var weight: [String: Double] = [:]
        var length = 0.0, speech = 0.0, music = 0.0
        var silent = 0, unknown = 0
        for (c, g) in guesses {
            let d = c.audioRange.duration
            switch g.basis {
            case .silent: silent += 1; continue
            case .unknown: unknown += 1; continue
            default: break
            }
            guard let r = g.mainRole else { continue }
            weight[r, default: 0] += d
            length += d
            speech += g.speechFraction * d
            music += g.musicFraction * d
        }
        if let (role, w) = weight.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
            let voted = guesses.filter { $0.1.mainRole == role }
            var g = RoleGuess(role: role, basis: .evidence, why: "")
            g.speechFraction = length > 0 ? speech / length : 0
            g.musicFraction = length > 0 ? music / length : 0
            if guesses.count == 1 {
                g.why = guesses[0].1.why
            } else if voted.allSatisfy({ $0.1.basis == .explicit }) {
                let roles = Set(voted.compactMap(\.1.role)).sorted().joined(separator: ", ")
                g.why = "\(voted.count) of \(guesses.count) clips have role \(roles)"
            } else {
                let share = length > 0 ? Int((w / length * 100).rounded()) : 0
                let detail = role == "dialogue" ? "speech \(Project.percent(g.speechFraction)) of their length"
                    : role == "music" ? "music \(Project.percent(g.musicFraction)) of their length" : "sound without speech or music"
                g.why = "\(detail) (\(voted.count) of \(guesses.count) clips, \(share)% of the sounding length)"
            }
            return g
        }
        if unknown == 0, silent > 0 { return RoleGuess(role: nil, basis: .silent, why: silent == 1 ? guesses[0].1.why : "every clip is silent") }
        if let r = Project.roleFromName(t.name) { return RoleGuess(role: r, basis: .name, why: "not analyzed; its name \"\(t.name)\" says \(r)") }
        return RoleGuess(role: nil, basis: .unknown, why: guesses.isEmpty ? "no sound" : "not analyzed (media_analyze, or set track_update role)")
    }

    /// One clip's role from what it plays.
    public func clipRole(_ c: Clip, _ e: SoundEvidence) -> RoleGuess {
        guard let mid = c.mediaId, let m = mediaAsset(mid), m.hasAudio, !m.isImage else { return RoleGuess(role: nil, basis: .silent, why: "its media has no sound") }
        var g = evidenceRole(c, m, e)
        if let r = c.role, !r.isEmpty {
            g.role = r
            g.basis = .explicit
            g.why = "role \(r) set on the clip"
        } else if c.volume <= 0.001, c.anim["audio.volume"] == nil {
            g.role = nil
            g.basis = .silent
            g.why = "volume 0"
            g.speech = []
        }
        return g
    }

    func evidenceRole(_ c: Clip, _ m: MediaAsset, _ e: SoundEvidence) -> RoleGuess {
        let heard = c.audioSourceRange
        let range = TimeRange(max(0, min(heard.start, heard.end)), min(m.duration > 0 ? m.duration : .infinity, max(heard.start, heard.end)))
        let length = range.duration
        guard length > 0 else { return RoleGuess(role: nil, basis: .silent, why: "plays no source time") }
        let transcript = e.transcripts[m.id]
        let sounds = e.sounds[m.id]
        let beats = e.beats[m.id]
        let analyzed = e.audio[m.id]
        let channelLevels = e.channels[m.id]
        guard transcript != nil || sounds != nil || beats != nil || analyzed != nil || channelLevels != nil else {
            return RoleGuess(role: nil, basis: .unknown, why: "not analyzed")
        }

        // Which channels the clip plays, and whether analysis heard exactly those.
        let played = playedChannels(c, m)
        let direct: Bool
        if let played, let byAnalysis = analysisChannels(m, channelLevels) { direct = played == byAnalysis } else { direct = playsTranscribedChannels(c) }
        var level: ((Seconds) -> Float)?
        if !direct, let cl = channelLevels, let played, !played.isEmpty {
            level = { t in
                let i = Int(t * cl.rate)
                return played.map { ch in ch - 1 < cl.levels.count && i >= 0 && i < cl.levels[ch - 1].count ? cl.levels[ch - 1][i] : -80 }.max() ?? -80
            }
        } else if let a = analyzed, direct || channelLevels == nil {
            level = { t in
                let i = Int(t * a.levelRate)
                return i >= 0 && i < a.levels.count ? a.levels[i] : -80
            }
        }
        // Without levels for its own channels, a clip playing channels analysis didn't hear has no usable evidence.
        if !direct, level == nil, !playsTranscribedChannels(c) { return RoleGuess(role: nil, basis: .unknown, why: "plays \(c.channels?.rawValue ?? "channels") analysis didn't hear; run media_analyze channel:\"\(c.channels?.rawValue ?? "")\"") }

        let step = 0.1
        var windows: [Seconds] = []
        var t = range.start
        while t < range.end { windows.append(t); t += step }
        func active(_ s: TimeRange) -> Double {
            guard let level else { return 1 }
            var n = 0, on = 0
            var x = s.start
            while x < s.end { n += 1; if level(x) >= Project.silenceFloorDb { on += 1 }; x += step / 2 }
            return n == 0 ? (level(s.start) >= Project.silenceFloorDb ? 1 : 0) : Double(on) / Double(n)
        }
        let silentShare = level.map { lv in windows.isEmpty ? 1 : Double(windows.filter { lv($0) < Project.silenceFloorDb }.count) / Double(windows.count) }

        // Speech: words (and speech sound events) in range; through other channels only when this one is louder while they're spoken.
        var words = (transcript?.words ?? []).filter { w in let mid = (w.start + w.end) / 2; return mid >= range.start && mid < range.end }.map { TimeRange($0.start, $0.end) }
        if !direct, level != nil {
            words = words.filter { active($0) >= 0.5 }
            if let level, !words.isEmpty {
                let spoken = TimeRange.merged(words, tolerance: 0.3)
                let padded = TimeRange.merged(spoken.map { TimeRange($0.start - 0.2, $0.end + 0.2) })
                let inWords = windows.filter { Project.covers(spoken, $0) }.map { level($0) }
                let outside = windows.filter { !Project.covers(padded, $0) }.map { level($0) }
                if outside.count >= 5, Project.median(inWords) - Project.median(outside) < 6 { words = [] }
            }
        }
        // Speech events are heard on the analysis channel too: through other channels they count only alongside words.
        let speechEvents = (sounds?.events ?? []).filter { Project.isSpeechLabel($0.label) }.map { TimeRange($0.start, $0.end) }.filter { direct || (!words.isEmpty && active($0) >= 0.5) }
        let speechSpans = TimeRange.merged(words + speechEvents, tolerance: 0.6).compactMap { $0.intersection(range) }
        let speechTime = speechSpans.map(\.duration).reduce(0, +)

        // Music: music sound events and a steady beat; through other channels, where this one sounds outside speech.
        let musicEvents = (sounds?.events ?? []).filter { Project.isMusicLabel($0.label) }.map { TimeRange($0.start, $0.end) }
        var beatSpans: [TimeRange] = []
        if let b = beats?.beats, b.count >= 4 {
            for (x, y) in zip(b, b.dropFirst()) where y - x <= 2 { beatSpans.append(TimeRange(x, y)) }
        }
        let musicSpans = TimeRange.merged(musicEvents + beatSpans, tolerance: 0.6).compactMap { $0.intersection(range) }
        var musicTime = musicSpans.map(\.duration).reduce(0, +)
        if !direct, let level {
            musicTime = Double(windows.filter { Project.covers(musicSpans, $0) && level($0) >= Project.silenceFloorDb && !Project.covers(speechSpans, $0) }.count) * step
        }
        let fromBeats = musicEvents.isEmpty && !beatSpans.isEmpty

        let speechShare = speechTime / length, musicShare = musicTime / length
        var g = RoleGuess(role: nil, basis: .evidence, why: "")
        g.speechFraction = speechShare
        g.musicFraction = musicShare
        g.speech = speechSpans.map { s in
            let a = c.timelineTime(atSource: s.start), b = c.timelineTime(atSource: s.end)
            return TimeRange(max(c.audioRange.start, min(a, b)), min(c.audioRange.end, max(a, b)))
        }.filter { $0.duration > 0 }
        let through = direct ? "" : " on \(c.channels?.rawValue ?? "its channels")"
        if let s = silentShare, s >= 0.95 {
            g.basis = .silent
            g.speech = []
            g.why = "silent\(through) (below \(Int(Project.silenceFloorDb)) dBFS for \(Project.percent(s)) of its length)"
            return g
        }
        if musicShare >= 0.5, musicShare >= speechShare {
            g.role = "music"
            g.why = "music \(Project.percent(musicShare)) of its length" + (fromBeats ? " (steady beat, \(Int((beats?.tempo ?? 0).rounded())) BPM)" : "") + (speechShare > 0.05 ? ", words \(Project.percent(speechShare)) (sung or over music)" : "")
        } else if speechShare >= Project.speechShare {
            g.role = "dialogue"
            g.why = "speech \(Project.percent(speechShare)) of its length\(through)"
        } else if musicShare >= 0.3 {
            g.role = "music"
            g.why = "music \(Project.percent(musicShare)) of its length"
        } else if silentShare != nil || transcript != nil || sounds != nil {
            g.role = "effects"
            g.why = "sound without speech or music" + (speechShare > 0 ? " (speech only \(Project.percent(speechShare)))" : "") + (silentShare.map { ", sound \(Project.percent(1 - $0)) of its length" } ?? "")
        } else {
            g.basis = .unknown
            g.why = "not analyzed for speech"
        }
        return g
    }

    /// Source channels a clip plays, from 1; nil when as recorded on a file whose channels aren't known.
    func playedChannels(_ c: Clip, _ m: MediaAsset) -> Set<Int>? {
        if let r = c.channels, !r.isAsRecorded {
            let n = m.sourceChannelCount
            // Named routings of a mono file read its one channel.
            return Set(r.sourceChannels.map { n == 1 && ChannelRouting.named.contains(r) ? 1 : $0 })
        }
        guard let chs = m.audioChannels, let first = chs.first?.track else { return nil }
        return Set(chs.enumerated().filter { $0.element.track == first }.map { $0.offset + 1 })
    }

    /// Source channels analysis listened to: the analysis channel, else every channel with sound of a multichannel
    /// file, else the first track.
    func analysisChannels(_ m: MediaAsset, _ levels: ChannelLevels?) -> Set<Int>? {
        if let r = m.analysisChannel, !r.isAsRecorded { return Set(r.sourceChannels) }
        if m.isMultichannel, m.analysisChannel == nil {
            guard let levels else { return nil }
            let peaks = levels.levels.map { $0.max() ?? -80 }
            let loudest = peaks.max() ?? -80
            return Set(peaks.indices.filter { peaks[$0] > -80 && peaks[$0] >= loudest - 40 }.map { $0 + 1 })
        }
        guard let chs = m.audioChannels, let first = chs.first?.track else { return nil }
        return Set(chs.enumerated().filter { $0.element.track == first }.map { $0.offset + 1 })
    }

    static func isSpeechLabel(_ label: String) -> Bool {
        let l = label.lowercased()
        return ["speech", "conversation", "narration", "monologue", "whispering", "babbling", "chatter"].contains { l.contains($0) }
    }

    static func isMusicLabel(_ label: String) -> Bool {
        let l = label.lowercased()
        return ["music", "singing", "song", "choir", "rapping", "guitar", "piano", "drum", "orchestra", "violin", "cello", "bass", "synthesizer", "organ", "trumpet", "saxophone", "flute", "harp", "ukulele", "banjo", "accordion", "harmonica", "keyboard", "percussion", "cymbal", "hi hat", "snare", "tabla", "marimba", "xylophone", "bell"].contains { l.contains($0) }
    }

    /// Whether merged, sorted `spans` contain `t`.
    static func covers(_ spans: [TimeRange], _ t: Seconds) -> Bool {
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].end <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo < spans.count && spans[lo].start <= t
    }

    static func median(_ xs: [Float]) -> Float {
        guard !xs.isEmpty else { return -80 }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    static func percent(_ x: Double) -> String { "\(Int((min(max(x, 0), 1) * 100).rounded()))%" }
}
