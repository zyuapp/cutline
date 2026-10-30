import Foundation

extension Project {
    /// Parameter paths that belong to a clip's sound: audio.*, and the parameters of its audio effects.
    static func soundPath(_ path: String, audioEffects: Set<String>) -> Bool {
        if path.hasPrefix("audio.") { return true }
        guard path.hasPrefix("fx.") else { return false }
        let parts = path.split(separator: ".", maxSplits: 2)
        return parts.count >= 2 && audioEffects.contains(String(parts[1]))
    }

    /// Moves a picture clip's sound to a clip of its own on an audio track: its split lead and lag, channel routing,
    /// surround position, role, level and automation, fades and audio effects. The picture goes silent and the two
    /// are linked so they move, split and delete together. `trackId` nil uses a free "Sound of <track>" track,
    /// adding one when needed. Returns the new clip and its track.
    public mutating func detachAudio(_ id: String, to trackId: String? = nil) throws -> (clip: Clip, track: String) {
        guard let loc = locateClip(id) else { throw EditError("No clip \(id)") }
        let pictureTrack = tracks[loc.track]
        var pic = pictureTrack.clips[loc.clip]
        guard pictureTrack.kind == .video else { throw EditError("\(id) is already on audio track \(pictureTrack.id)") }
        guard pic.kind == .media, let mid = pic.mediaId, let m = mediaAsset(mid) else { throw EditError("detach_audio is for media clips; \(id) is a \(pic.kind.rawValue) clip") }
        guard m.hasAudio, !m.isImage else { throw EditError("\(mid) has no sound to detach") }
        guard pic.volume > 1e-6 || pic.anim["audio.volume"] != nil else { throw EditError("\(id)'s own sound is already off (volume 0); nothing to detach. param_set audio.volume brings it back") }
        if (pic.isRetimed || pic.reverse), pic.audioLead != 0 || pic.audioLag != 0 { throw EditError("\(id) is reversed or speed-ramped with a split edit; remove the split (trim part:\"audio\") before detaching") }

        let audioFx = Set(pic.effects.filter { EffectCatalog.isAudio($0.type) }.map(\.id))
        var a = Clip(id: Project.newClipId(), kind: .media, mediaId: mid, start: pic.start - pic.audioLead, duration: pic.duration + pic.audioLead + pic.audioLag, sourceIn: pic.audioSourceRange.start)
        a.name = (pic.name ?? m.name) + " sound"
        a.speed = pic.speed
        a.reverse = pic.reverse
        a.volume = pic.volume
        a.audioFadeIn = pic.audioFadeIn
        a.audioFadeOut = pic.audioFadeOut
        a.channels = pic.channels
        a.surround = pic.surround
        a.role = pic.role
        a.effects = pic.effects.filter { audioFx.contains($0.id) }
        for (path, curve) in pic.anim where Project.soundPath(path, audioEffects: audioFx) || path == "time.speed" {
            a.anim[path] = curve.shifted(by: pic.audioLead)
        }
        if a.reverse { a.sourceIn = pic.sourceIn }
        // Sound that would start before the timeline starts loses its head.
        if a.start < 0 {
            let cut = -a.start
            a.sourceIn += cut * a.speed
            a.duration -= cut
            a.start = 0
            for (path, curve) in a.anim { a.anim[path] = curve.shifted(by: -cut) }
            a.audioFadeIn = max(0, a.audioFadeIn - cut)
        }
        let link = pic.link ?? IDs.make("lnk")
        a.link = link

        let range = TimeRange(canvas.snap(a.start), canvas.snap(a.start) + canvas.snap(a.duration))
        func free(_ t: Track) -> Bool { !t.clips.contains { $0.start < range.end - 1e-6 && $0.end > range.start + 1e-6 } }
        let target: String
        if let trackId {
            guard let i = trackIndex(trackId) else { throw EditError("No track \(trackId)") }
            guard tracks[i].kind == .audio else { throw EditError("\(trackId) is a video track; detached sound goes on an audio track") }
            target = trackId
        } else {
            let name = "Sound of \(pictureTrack.id)"
            target = tracks.first { $0.kind == .audio && $0.name == name && free($0) }?.id ?? addTrack(kind: .audio, name: name).id
        }
        let placed = try addClip(a, trackId: target, mode: .place)

        guard let now = locateClip(id) else { throw EditError("No clip \(id)") }
        pic.volume = 0
        pic.audioFadeIn = 0
        pic.audioFadeOut = 0
        pic.audioLead = 0
        pic.audioLag = 0
        pic.channels = nil
        pic.surround = nil
        pic.effects.removeAll { audioFx.contains($0.id) }
        for path in pic.anim.keys where Project.soundPath(path, audioEffects: audioFx) { pic.anim[path] = nil }
        pic.link = link
        tracks[now.track].clips[now.clip] = pic
        return (placed, target)
    }

    /// Folds a detached sound clip back into its linked picture as the picture's own sound (a split edit where they
    /// start or end apart). `id` is either clip. Throws when they don't play the same media in sync or the picture
    /// has sound of its own.
    public mutating func attachAudio(_ id: String) throws -> (picture: String, sound: String) {
        guard let c = clip(id), let loc = locateClip(id) else { throw EditError("No clip \(id)") }
        let onVideo = tracks[loc.track].kind == .video
        let partners = linked(id).compactMap { o -> Clip? in clip(o) }.filter { o in
            guard let l = locateClip(o.id) else { return false }
            return (tracks[l.track].kind == .video) != onVideo && o.kind == .media && o.mediaId == c.mediaId
        }
        guard !partners.isEmpty else { throw EditError("\(id) has no linked \(onVideo ? "sound clip" : "picture clip") of the same media; attach_audio rejoins a sound that detach_audio split off") }
        let syncOf = { (x: Clip) in x.sourceIn - x.start * x.speed }
        guard let other = partners.first(where: { o in
            abs(o.speed - c.speed) < 1e-6 && abs(syncOf(o) - syncOf(c)) < canvas.frameDuration / 2 * max(1, c.speed) && o.reverse == c.reverse
        }) else { throw EditError("\(id) and its linked clips (\(partners.map(\.id).joined(separator: ", "))) don't play \(c.mediaId ?? "") in sync at the same speed, so the sound can't ride on the picture; move one back in sync first") }
        var pic = onVideo ? c : other
        let snd = onVideo ? other : c
        guard pic.volume <= 1e-6, pic.anim["audio.volume"] == nil else { throw EditError("\(pic.id) already plays its own sound; mute it (param_set audio.volume 0) or delete \(snd.id) instead") }
        guard !(pic.isRetimed || snd.isRetimed || pic.reverse) || (abs(snd.start - pic.start) < 1e-6 && abs(snd.duration - pic.duration) < 1e-6) else {
            throw EditError("\(snd.id) starts or ends apart from its reversed or speed-ramped picture; a split edit needs constant forward speed")
        }
        let lead = pic.start - snd.start, lag = snd.end - pic.end
        guard pic.duration + lead + lag > canvas.frameDuration else { throw EditError("\(snd.id) barely overlaps \(pic.id)") }
        let audioFx = Set(snd.effects.filter { EffectCatalog.isAudio($0.type) }.map(\.id))
        let taken = Set(pic.effects.map(\.id))
        if let clash = audioFx.first(where: { taken.contains($0) }) { throw EditError("\(pic.id) already has an effect \(clash); rename or remove it first") }
        pic.volume = snd.volume
        pic.audioFadeIn = snd.audioFadeIn
        pic.audioFadeOut = snd.audioFadeOut
        pic.audioLead = canvas.snap(lead)
        pic.audioLag = canvas.snap(lag)
        pic.channels = snd.channels
        pic.surround = snd.surround
        if pic.role == nil { pic.role = snd.role }
        pic.effects += snd.effects.filter { audioFx.contains($0.id) }
        for (path, curve) in snd.anim where Project.soundPath(path, audioEffects: audioFx) { pic.anim[path] = curve.shifted(by: -lead) }
        guard let sl = locateClip(snd.id) else { throw EditError("No clip \(snd.id)") }
        tracks[sl.track].clips.remove(at: sl.clip)
        if let link = pic.link, !tracks.flatMap(\.clips).contains(where: { $0.link == link && $0.id != pic.id }) { pic.link = nil }
        try replaceClip(pic)
        return (pic.id, snd.id)
    }
}
