import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    /// The bundle's analysis of the project's media, with per-channel levels for media whose clips pick source
    /// channels or that carry several tracks (read once, then cached as "<media>.channels").
    func soundEvidence(_ p: Project) async -> SoundEvidence {
        guard let b = session.bundle else { return SoundEvidence() }
        var e = SoundEvidence(transcripts: b.transcripts(for: p))
        let used = Set(p.flattenedForSound.flatMap(\.clips).compactMap(\.mediaId))
        for m in p.media where used.contains(m.id) && m.hasAudio && !m.isImage {
            if let a = b.audioAnalysis(m.id) { e.audio[m.id] = a }
            if let beats = b.analysis(BeatAnalysis.self, m.id, "beats") { e.beats[m.id] = beats }
            if let s = b.analysis(SoundEvents.self, m.id, "sounds") { e.sounds[m.id] = s }
            let picks = p.flattenedForSound.flatMap(\.clips).contains { $0.mediaId == m.id && $0.channels.map { !$0.isAsRecorded } == true }
            guard m.isMultichannel || picks else { continue }
            if let cached = b.analysis(ChannelLevels.self, m.id, "channels"), m.sourceChannelCount == 0 || cached.levels.count == m.sourceChannelCount {
                e.channels[m.id] = cached
            } else if !m.isTranscoding, FileManager.default.fileExists(atPath: m.path), let levels = try? await SourceChannels.levels(m) {
                try? b.saveAnalysis(levels, m.id, "channels")
                e.channels[m.id] = levels
            }
        }
        return e
    }

    func roleInference(_ p: Project) async -> RoleInference {
        p.inferRoles(await soundEvidence(p))
    }

    /// The inferred roles, one line per track, plus clips whose evidence disagrees with their track's role.
    static func describeRoles(_ r: RoleInference, _ p: Project, target: (String) -> String = { $0 }) -> String {
        var lines = r.lines(p, target: target).map { "  " + $0 }
        var odd: [String] = []
        for t in p.flattenedForSound {
            guard let role = r.tracks[t.id]?.mainRole else { continue }
            for c in t.clips {
                guard let g = r.clips[c.id], g.basis == .evidence, let own = g.mainRole, own != role else { continue }
                odd.append("  \(c.id) on \(t.id) reads as \(own): \(g.why)")
            }
        }
        lines += odd.prefix(6)
        if odd.count > 6 { lines.append("  …and \(odd.count - 6) more clips") }
        return "Roles (override with track_update role, a clip's with param_set audio.role):\n" + lines.joined(separator: "\n")
    }
}
