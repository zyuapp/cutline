import Foundation

/// Which source channels a clip plays. Source channels are numbered across the file's audio tracks in order:
/// a camera file with four mono tracks is ch1–ch4, a six-channel poly WAV ch1–ch6, and a mezzanine whose
/// channels 1+2 were paired into one stereo track still calls its next track ch3.
public struct ChannelRouting: RawRepresentable, Codable, Hashable, Sendable {
    public enum Form: Hashable, Sendable {
        /// The first audio track as recorded.
        case asRecorded
        /// One channel on both sides.
        case single(Int)
        /// Left and right from two channels.
        case pair(Int, Int)
        /// Channels summed at 1/n on both sides.
        case mix([Int])
    }

    public let rawValue: String
    public let form: Form

    /// The first audio track as recorded.
    public static let stereo = ChannelRouting(rawValue: "stereo")!
    /// The left channel on both sides.
    public static let left = ChannelRouting(rawValue: "left")!
    /// The right channel on both sides.
    public static let right = ChannelRouting(rawValue: "right")!
    /// Both channels summed at half level on both sides.
    public static let monoMix = ChannelRouting(rawValue: "mono_mix")!
    /// Left and right exchanged.
    public static let swap = ChannelRouting(rawValue: "swap")!
    /// The named routings for one- and two-channel files.
    public static let named: [ChannelRouting] = [.stereo, .left, .right, .monoMix, .swap]

    public static let help = "stereo (the first track as recorded), left, right, mono_mix, swap, \"ch3\" (one source channel on both sides), \"ch3+ch4\" (two channels as left and right), \"mix:1,3\" (channels summed at 1/n); channels count across all of the file's audio tracks"

    /// A named routing, "ch3", "ch3+ch4", "mix:1,3", or bare numbers ("3", "3+4").
    public init?(rawValue: String) {
        let s = rawValue.trimmingCharacters(in: .whitespaces).lowercased()
        func channel(_ t: Substring) -> Int? {
            let d = t.trimmingCharacters(in: .whitespaces)
            let n = Int(d.hasPrefix("ch") ? String(d.dropFirst(2)) : d)
            return n.flatMap { (1...64).contains($0) ? $0 : nil }
        }
        let parsed: Form
        switch s {
        case "stereo": parsed = .asRecorded
        case "left": parsed = .single(1)
        case "right": parsed = .single(2)
        case "mono_mix": parsed = .mix([1, 2])
        case "swap": parsed = .pair(2, 1)
        default:
            if s.hasPrefix("mix:") {
                let list = s.dropFirst(4).split(separator: ",").map(channel)
                guard !list.isEmpty, !list.contains(nil) else { return nil }
                var seen: [Int] = []
                for c in list.compactMap({ $0 }) where !seen.contains(c) { seen.append(c) }
                parsed = seen.count == 1 ? .single(seen[0]) : .mix(seen)
            } else if s.contains("+") {
                let parts = s.split(separator: "+", omittingEmptySubsequences: false)
                guard parts.count == 2, let a = channel(parts[0]), let b = channel(parts[1]) else { return nil }
                parsed = a == b ? .single(a) : .pair(a, b)
            } else if let c = channel(Substring(s)) {
                parsed = .single(c)
            } else {
                return nil
            }
            form = parsed
            self.rawValue = ChannelRouting.canonical(parsed)
            return
        }
        form = parsed
        self.rawValue = s
    }

    static func canonical(_ f: Form) -> String {
        switch f {
        case .asRecorded: "stereo"
        case .single(let c): "ch\(c)"
        case .pair(let a, let b): "ch\(a)+ch\(b)"
        case .mix(let list): "mix:" + list.map(String.init).joined(separator: ",")
        }
    }

    public static func == (a: ChannelRouting, b: ChannelRouting) -> Bool { a.rawValue == b.rawValue }
    public func hash(into h: inout Hasher) { h.combine(rawValue) }

    public var isAsRecorded: Bool { form == .asRecorded }

    /// Plays a single channel image, so it pans as a point source.
    public var isMono: Bool {
        switch form {
        case .single, .mix: true
        case .asRecorded, .pair: false
        }
    }

    /// Source channels read, from 1; empty when as recorded.
    public var sourceChannels: [Int] {
        switch form {
        case .asRecorded: []
        case .single(let c): [c]
        case .pair(let a, let b): [a, b]
        case .mix(let list): list
        }
    }

    /// Gains from each of `count` source channels (index 0 is ch1) to left and right. On a mono file the named
    /// routings read its one channel wherever they ask for ch2; other missing channels are silent.
    public func matrix(count: Int) -> (left: [Double], right: [Double]) {
        let n = max(count, 1)
        var l = [Double](repeating: 0, count: n), r = l
        let named = ChannelRouting.named.contains(self)
        func index(_ c: Int) -> Int? {
            if c <= n { return c - 1 }
            return n == 1 && c == 2 && named ? 0 : nil
        }
        switch form {
        case .asRecorded:
            l[0] = 1
            r[n > 1 ? 1 : 0] = 1
        case .single(let c):
            if let i = index(c) { l[i] = 1; r[i] = 1 }
        case .pair(let a, let b):
            if let i = index(a) { l[i] += 1 }
            if let i = index(b) { r[i] += 1 }
        case .mix(let list):
            let g = 1 / Double(list.count)
            for c in list { if let i = index(c) { l[i] += g; r[i] += g } }
        }
        return (l, r)
    }

    /// Why this routing doesn't fit a file with `count` source channels; nil when it does or the count is unknown.
    public func problem(count: Int) -> String? {
        guard count > 0, !ChannelRouting.named.contains(self) else { return nil }
        let missing = sourceChannels.filter { $0 > count }
        guard !missing.isEmpty else { return nil }
        return "\(missing.map { "ch\($0)" }.joined(separator: ", ")) doesn't exist: the media has \(count) source channel\(count == 1 ? "" : "s") (ch1\(count > 1 ? "–ch\(count)" : ""))"
    }
}

/// One source channel of a media file: where it is and what the recorder called it.
public struct SourceChannel: Codable, Equatable, Sendable {
    /// Audio track in the file, from 1.
    public var track: Int
    /// Channel within that track, from 1.
    public var channel: Int
    /// Speaker label from the track's channel layout (L, R, C, LFE, Ls, Rs…) when it has one.
    public var label: String?
    /// Name from the recorder (iXML or bext track names) or the file's track title.
    public var name: String?
    /// Audio track in the camera original, when the playable file is a mezzanine that regrouped the channels.
    public var originalTrack: Int?

    public init(track: Int, channel: Int, label: String? = nil, name: String? = nil, originalTrack: Int? = nil) {
        self.track = track
        self.channel = channel
        self.label = label
        self.name = name
        self.originalTrack = originalTrack
    }
}

extension MediaAsset {
    /// Source channels as `audio.channels` and analysis count them; 0 when unknown.
    public var sourceChannelCount: Int { audioChannels?.count ?? 0 }

    /// Whether the sound is more than one mono or stereo track: extra channels, extra tracks or named channels.
    public var isMultichannel: Bool {
        guard let chs = audioChannels else { return false }
        return chs.count > 2 || Set(chs.map(\.track)).count > 1
    }

    /// "4 source channels in 4 mono tracks: ch1 "Boom", ch2 "Lav 1", ch3, ch4", or "…: ch1–ch4" without names. The
    /// layout is the camera original's, with how a mezzanine regrouped it. nil for one plain mono or stereo track.
    public var channelSummary: String? {
        guard let chs = audioChannels, !chs.isEmpty, isMultichannel || chs.contains(where: { $0.name != nil || $0.originalTrack != nil }) else { return nil }
        func layout(_ track: (SourceChannel) -> Int) -> (text: String, groups: [[Int]]) {
            var groups: [(track: Int, channels: [Int])] = []
            for (i, c) in chs.enumerated() {
                if let g = groups.firstIndex(where: { $0.track == track(c) }) { groups[g].channels.append(i + 1) } else { groups.append((track(c), [i + 1])) }
            }
            let text: String
            if groups.count == 1 {
                text = "1 track"
            } else if groups.allSatisfy({ $0.channels.count == 1 }) {
                text = "\(groups.count) mono tracks"
            } else {
                text = "\(groups.count) tracks (" + groups.map { $0.channels.map { "ch\($0)" }.joined(separator: "+") }.joined(separator: ", ") + ")"
            }
            return (text, groups.map(\.channels))
        }
        let original = layout { $0.originalTrack ?? $0.track }
        let playable = layout(\.track)
        let named = chs.contains { $0.label != nil || $0.name != nil }
        let list = named || chs.count < 3
            ? chs.enumerated().map { i, c in
                let about = [c.label, c.name.map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
                return "ch\(i + 1)" + (about.isEmpty ? "" : " " + about)
            }.joined(separator: ", ")
            : "ch1–ch\(chs.count)"
        var s = "\(chs.count) source channel\(chs.count == 1 ? "" : "s") in \(original.text): " + list
        if original.groups != playable.groups {
            let paired = playable.groups.filter { $0.count > 1 }.map { $0.map { "ch\($0)" }.joined(separator: "+") }
            s += " (the mezzanine carries " + (paired.isEmpty ? "them as \(playable.text)" : paired.joined(separator: " and ") + " as one stereo track") + "; channel numbers are the same)"
        }
        return s
    }
}

extension Project {
    /// Lays every source channel of `clip`'s media on its own audio track as a mono clip ("ch1", "ch2"…), like a
    /// multichannel-to-mono-clips split. With picture, `clip` goes on `pictureTrack` with its own sound off. All
    /// pieces share a link id so they move, trim, split and delete together. New audio tracks are made unless
    /// `audioTracks` names one per channel. Returns the picture clip id (if any) and each channel's (clip, track).
    @discardableResult
    public mutating func addSplitChannels(_ clip: Clip, pictureTrack: String?, audioTracks: [String]? = nil, mode: PlaceMode) throws -> (picture: String?, channels: [(clip: String, track: String)]) {
        guard let mid = clip.mediaId, let media = mediaAsset(mid) else { throw EditError("No media \(clip.mediaId ?? "")") }
        guard media.hasAudio, !media.isImage else { throw EditError("\(mid) has no sound to split") }
        guard let chs = media.audioChannels, !chs.isEmpty else { throw EditError("\(mid)'s source channels aren't known; import it again to read them") }
        if let audioTracks, audioTracks.count != chs.count { throw EditError("audio_tracks names \(audioTracks.count) track(s); \(mid) has \(chs.count) source channels") }
        let link = clip.link ?? IDs.make("lnk")
        var start = clip.start
        var pictureId: String?
        if media.hasVideo {
            var pic = clip
            pic.link = link
            pic.volume = 0
            pic.channels = nil
            let placed = try addClip(pic, trackId: pictureTrack ?? "V1", mode: mode)
            pictureId = placed.id
            start = placed.start
        } else if mode == .append {
            start = audioTracks.flatMap { $0.compactMap { trackIndex($0) }.map { tracks[$0].end }.max() } ?? duration
        }
        var out: [(clip: String, track: String)] = []
        for (i, ch) in chs.enumerated() {
            let n = i + 1
            let label = ch.name ?? ch.label
            let trackId: String
            if let audioTracks {
                guard trackIndex(audioTracks[i]) != nil else { throw EditError("No track \(audioTracks[i])") }
                trackId = audioTracks[i]
            } else {
                trackId = addTrack(kind: .audio, name: "\(media.name) ch\(n)" + (label.map { " \($0)" } ?? "")).id
            }
            var c = clip
            c.id = Project.newClipId()
            c.name = "\(clip.name ?? media.name) ch\(n)" + (label.map { " \($0)" } ?? "")
            c.start = start
            c.channels = ChannelRouting(rawValue: "ch\(n)")
            c.link = link
            c.effects = clip.effects.filter { EffectCatalog.isAudio($0.type) }
            out.append((try addClip(c, trackId: trackId, mode: mode == .append ? .place : mode).id, trackId))
        }
        return (pictureId, out)
    }
}
