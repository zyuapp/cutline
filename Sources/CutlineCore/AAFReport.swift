import Foundation

extension Project {
    /// First line of an AAF's notes file.
    static let aafCaveat = "Not yet opened in Pro Tools, Media Composer or Resolve: the file is checked against Cutline's own AAF reader and the structure of sample AAFs from Media Composer and pyaaf2. Media is linked (nothing embedded); relink to the files named in each source's locator."

    /// What an AAF export can't carry, clip by clip.
    func aafLosses(_ options: InterchangeOptions) -> [String] {
        var out: [String] = []
        let flat = flattenedSequences()
        func label(_ c: Clip) -> String { c.name.map { "\(c.id) (\($0))" } ?? c.id }
        if !sequences.isEmpty { out.append("\(sequences.count) nested sequence(s) → flattened into the clips they play") }
        var short: [String] = []
        for track in flat.tracks {
            if track.kind == .audio, track.muted, !track.clips.isEmpty { out.append("Track \(track.id) (\(track.name)) is muted → left out of the AAF, which has no track mute") }
            if track.kind == .video, track.hidden, !track.clips.isEmpty { out.append("Track \(track.id) (\(track.name)) is hidden → written anyway; AAF has no track enable") }
            let fx = track.effects.filter(\.enabled).map(\.type)
            if !fx.isEmpty { out.append("Track \(track.id) effects \(fx.joined(separator: ", ")) → not carried") }
            if track.volume != 1 || track.volumeCurve != nil { out.append("Track \(track.id) fader → folded into its clips' gain") }
            for c in track.clips {
                let name = label(c)
                switch c.kind {
                case .text: out.append("\(name) text \"\(c.text?.text.prefix(40) ?? "")\" → filler; other apps show a gap (render_graphics bakes titles to media); Cutline reads it back from its comment")
                case .solid: out.append("\(name) solid → filler; Cutline reads it back from its comment")
                case .generator:
                    if let file = options.graphics[c.id] {
                        out.append("\(name) \(Project.graphicName(c)) → rendered to \((file as NSString).lastPathComponent) and linked as media")
                    } else if Project.titleSpec(c) != nil {
                        out.append("\(name) \(Project.graphicName(c)) → filler; render_graphics bakes it to media the AAF can link; Cutline reads its text back")
                    } else {
                        out.append("\(name) \(Project.graphicName(c)) → offline placeholder \(Project.safeFileName(c.id)).mov; render_graphics bakes it to that file")
                    }
                case .adjustment: out.append("\(name) adjustment layer → not carried")
                case .sequence, .media: break
                }
                guard c.kind == .media, let m = c.mediaId.flatMap(flat.mediaAsset) else { continue }
                var lost: [String] = []
                if track.kind == .video {
                    let t = c.transform
                    if t != Transform() { lost.append("position, scale, rotation, crop and opacity") }
                    let keyed = c.anim.keys.filter { $0 != "audio.volume" }.sorted()
                    if !keyed.isEmpty { lost.append("keyframes on " + keyed.prefix(4).joined(separator: ", ")) }
                    if c.blend != .normal { lost.append("\(c.blend.rawValue) blend") }
                    if c.fadeIn > 0 || c.fadeOut > 0 { lost.append("picture fades") }
                    let fx = c.effects.filter { $0.enabled && EffectCatalog.type($0.type)?.category != "audio" }.map(\.type)
                    if !fx.isEmpty { lost.append("effects and grade (\(fx.prefix(4).joined(separator: ", ")))") }
                }
                if c.isRetimed { lost.append("speed ramp (written at 1×)") }
                if c.reverse { lost.append("reverse (plays forward)") }
                if m.hasAudio, !m.isImage {
                    let afx = c.effects.filter { $0.enabled && EffectCatalog.type($0.type)?.category == "audio" }.map(\.type)
                    if !afx.isEmpty { lost.append(afx.joined(separator: ", ")) }
                    if c.surround != nil { lost.append("surround panning") }
                    if c.channels != nil { lost.append("channel routing (every source channel is written)") }
                    if let role = c.role { lost.append("audio role \(role)") }
                }
                if !lost.isEmpty { out.append("\(name) → \(lost.joined(separator: ", ")) not carried") }
                if !m.isImage, options.aafHandles > 0 {
                    let r = c.audioSourceRange
                    let lo = min(c.sourceIn, m.hasAudio ? r.start : c.sourceIn), hi = max(c.sourceOut, m.hasAudio ? r.end : c.sourceOut)
                    if lo < options.aafHandles - 1e-6 || m.duration - hi < options.aafHandles - 1e-6 { short.append(name) }
                }
            }
        }
        if !short.isEmpty {
            out.append("Handles: \(short.count) clip(s) have less than \(fmt2(options.aafHandles))s of media before or after them, so their handles stop at the media's ends: " + short.prefix(5).joined(separator: ", ") + (short.count > 5 ? ", …" : ""))
        }
        for tr in flat.transitions {
            if tr.type != "dissolve" { out.append("Transition \(tr.id) \(tr.type) → a dissolve") }
            if !tr.params.isEmpty { out.append("Transition \(tr.id) settings → not carried") }
        }
        if markers.contains(where: { $0.color != nil || ($0.duration ?? 0) > 0 }) { out.append("Marker colors and durations → not carried; markers keep their time and text") }
        if captions.enabled { out.append("Captions → not in AAF; export subtitles (srt, vtt, ttml) beside it") }
        if !master.effects.isEmpty || master.loudnessTarget != nil { out.append("Master bus processing → not carried") }
        if master.gainDb != 0 { out.append("Master gain → folded into the clips' gain") }
        if !buses.isEmpty { out.append("\(buses.count) audio bus(es) → not carried; levels fold into the clips") }
        return out
    }
}
