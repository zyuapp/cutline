import Foundation

extension Project {
    /// A clip that plays its media's sound, with the track it is on.
    struct Audible {
        var clip: Clip
        var track: String
        /// Source time minus timeline time × speed: equal for clips playing the same moment in sync.
        var sync: Seconds { clip.sourceIn - clip.start * clip.speed }
    }

    /// Media clips whose sound plays (audible track, volume above zero or automated), on every top-level track.
    func audibleClips() -> [Audible] {
        var out: [Audible] = []
        for t in tracks where !t.muted {
            for c in t.clips where c.kind == .media && (c.volume > 1e-6 || c.anim["audio.volume"] != nil) {
                guard let m = c.mediaId.flatMap(mediaAsset), m.hasAudio, !m.isImage else { continue }
                out.append(Audible(clip: c, track: t.id))
            }
        }
        return out
    }

    /// Source channels a clip plays; as recorded is the first track's channels 1 and 2.
    static func playedChannels(_ c: Clip) -> Set<Int> {
        guard let r = c.channels, !r.isAsRecorded else { return [1, 2] }
        return Set(r.sourceChannels)
    }

    /// The same source sound playing twice at the same moment (e.g. a picture clip's own sound and the same media on
    /// an audio track in sync): it sounds louder and phasey.
    func doubledSound(minimum: Seconds = 0.1) -> [String] {
        let heard = audibleClips().filter { !$0.clip.isRetimed }
        var out: [String] = []
        var reported = Set<String>()
        for (i, a) in heard.enumerated() {
            for b in heard[(i + 1)...] where a.clip.mediaId == b.clip.mediaId && a.clip.id != b.clip.id {
                guard abs(a.clip.speed - b.clip.speed) < 1e-6, a.clip.reverse == b.clip.reverse, !a.clip.reverse,
                      abs(a.sync - b.sync) < canvas.frameDuration / 2 * max(1, a.clip.speed),
                      !Project.playedChannels(a.clip).isDisjoint(with: Project.playedChannels(b.clip)),
                      let both = a.clip.audioRange.intersection(b.clip.audioRange), both.duration >= minimum else { continue }
                let key = [a.clip.id, b.clip.id].sorted().joined(separator: "|")
                guard reported.insert(key).inserted else { continue }
                let picture = [a, b].first { x in tracks.first { $0.id == x.track }?.kind == .video }
                let fix = picture.map { "clip_update \($0.clip.id) detach_audio:true moves its sound to an audio track, or param_set audio.volume 0 mutes it" } ?? "mute one (param_set audio.volume 0)"
                out.append("doubled sound: \(a.clip.id) on \(a.track) and \(b.clip.id) on \(b.track) play the same sound of \(a.clip.mediaId ?? "") at \(fmt2(both.start))–\(fmt2(both.end))s (louder and phasey); \(fix)")
            }
        }
        return out
    }

    /// Words inside a clip's picture that its split sound never plays (its sound starts after, or ends before, its
    /// picture) and no other clip plays at that moment: speech an L or J cut drops.
    func droppedWords(transcripts: [String: Transcript], dialogue: Set<String>) -> [String] {
        let heard = audibleClips()
        var out: [String] = []
        for a in heard where dialogue.contains(a.track) && !a.clip.reverse && !a.clip.isRetimed && playsTranscribedChannels(a.clip) {
            let c = a.clip
            guard c.audioLead < -1e-6 || c.audioLag < -1e-6, let mid = c.mediaId, let tr = transcripts[mid] else { continue }
            let picture = TimeRange(c.sourceIn, c.sourceOut), sound = c.audioSourceRange
            let lost = tr.words.filter { w in
                guard w.start >= picture.start - 0.02, w.end <= picture.end + 0.02, w.end <= sound.start + 0.04 || w.start >= sound.end - 0.04 else { return false }
                let t = c.timelineTime(atSource: (w.start + w.end) / 2)
                return !heard.contains { o in
                    o.clip.id != c.id && o.clip.mediaId == mid && abs(o.clip.speed - c.speed) < 1e-6 && abs(o.sync - a.sync) < 0.02 && o.clip.audioRange.start <= t && t < o.clip.audioRange.end
                }
            }
            guard !lost.isEmpty else { continue }
            let text = lost.prefix(6).map(\.text).joined(separator: " ") + (lost.count > 6 ? " …" : "")
            let how = c.audioLead < -1e-6 ? "sound starts \(fmt2(-c.audioLead))s after its picture" : "sound ends \(fmt2(-c.audioLag))s before its picture"
            out.append("\(c.id)'s \(how), so “\(text)” (\(mid) \(fmt2(lost[0].start))–\(fmt2(lost[lost.count - 1].end))) is never heard; shorten the split edit or trim the picture to a word edge")
        }
        return out
    }
}
