import CutlineCore
import CutlineEngine
import Foundation

extension Session {
    func analyzePerception(_ media: MediaAsset, _ want: Set<Feature>, bundle b: ProjectBundle, heard: URL? = nil, progress: (@Sendable (Double) -> Void)?, finished: (Feature, [String]) -> Void = { _, _ in }) async throws -> [String] {
        var notes: [String] = []
        let project = try? self.project()
        let quality = Proxies.Quality(project?.playbackSettings.proxySize ?? .half)
        var needsProxy = false
        if want.contains(.proxy), media.hasVideo, !media.isImage, Proxies.cached(media, quality: quality) == nil, project?.previewUsesProxy(media) ?? true {
            if project?.wantsProxy(media, heavy: false) == true { needsProxy = true }
            else { needsProxy = Proxies.shouldProxy(media, format: await Proxies.format(of: media)) }
        }
        if needsProxy {
            let made = try await Proxies.transcode(media, quality: quality) { p in progress?(0.65 * p) }
            try? sendPreview(["action": "rebuild"])
            notes.append("proxy: \(Int(made.size.width))×\(Int(made.size.height)) ProRes Proxy for smooth preview (\(String(format: "%.1f", made.realtimeFactor))× realtime); export uses the original")
            finished(.proxy, [notes.last!])
        } else if want.contains(.proxy) {
            finished(.proxy, [])
        }
        if want.contains(.shots), media.hasVideo {
            let cuts = b.visualAnalysis(media.id)?.sceneCuts ?? []
            let checkpoint = b.cacheURL.appendingPathComponent("checkpoints", isDirectory: true).appendingPathComponent("\(media.id)-shots.json")
            var shots = try await VisionAnalyzer.analyze(url: media.url, mediaId: media.id, sceneCuts: cuts, duration: media.isImage ? 1 : media.duration, checkpoint: checkpoint) { p in progress?(0.65 + 0.25 * p) }
            if !media.isImage, !shots.faces.isEmpty { shots.faces = try await FaceIdentity.identify(url: media.url, tracks: shots.faces) }
            try b.saveAnalysis(shots, media.id, "shots")
            let people = shots.shots.map(\.people).max() ?? 0
            notes.append("shots: \(shots.shots.count) described (\(media.id).s0…s\(max(0, shots.shots.count - 1))), \(people == 0 ? "no people" : "up to \(people) people"), \(shots.faces.count) face tracks")
        }
        if want.contains(.sounds), media.hasAudio {
            let events = try await SoundEventDetector.analyze(url: heard ?? media.url, mediaId: media.id)
            try b.saveAnalysis(events, media.id, "sounds")
            let labels = Dictionary(grouping: events.events, by: \.label).map { ($0.key, $0.value.map(\.duration).reduce(0, +)) }.sorted { $0.1 > $1.1 }.prefix(5)
            notes.append("sounds: " + (labels.isEmpty ? "nothing distinct" : labels.map { "\($0.0) \(fmt1($0.1))s" }.joined(separator: ", ")))
            finished(.sounds, [notes.last!])
        }
        if (want.contains(.shots) || want.contains(.speakers)), media.hasVideo, !media.isImage,
           let speakers = b.analysis(SpeakerAnalysis.self, media.id, "speakers"), let shots = b.analysis(ShotAnalysis.self, media.id, "shots"), !shots.faces.isEmpty,
           let transcript = b.transcript(media.id) {
            var active = try await ActiveSpeakerDetector.analyze(url: media.url, transcript: transcript, speakers: speakers, shots: shots)
            // Faces talking together are two people, and one face talking is one: label the voices again with that.
            let refined = try await Diarizer.analyze(url: media.url, transcript: transcript, faces: active, faceTracks: shots.faces, enrollment: Session.enrollment(speakers, transcript: transcript))
            if refined.wordSpeakers != speakers.wordSpeakers {
                try b.saveAnalysis(refined, media.id, "speakers")
                active = ActiveSpeakerDetector.relabel(active, with: refined, transcript: transcript)
                notes.append("speakers with face evidence: \(refined.speakers.count) (\(refined.speakers.joined(separator: ", ")))")
            }
            try b.saveAnalysis(active, media.id, "activespeakers")
            if !active.speakerFaces.isEmpty {
                notes.append("on-screen speakers: " + active.speakerFaces.sorted { $0.key < $1.key }.map { "\($0.key)=face\($0.value)" }.joined(separator: ", "))
            }
        }
        // Shots count as done only with the active speakers that read them.
        if want.contains(.shots), media.hasVideo { finished(.shots, notes.filter { $0.hasPrefix("shots:") || $0.hasPrefix("speakers with") || $0.hasPrefix("on-screen") }) }
        progress?(1)
        return notes
    }
}

extension Toolbox {
    func registerAnalysisTools() {
        add(Tool(name: "analysis_read", description: "Read what analysis found, compactly, so you know the footage without looking at frames. what: summary (default; everything known about the media), beats (tempo, beat and downbeat times with anchor ids), speakers (turns with voice confidence, identity across scenes and whether a turn was pinned or named from a pinned voice), shots (descriptions, shot size, people, text, aesthetics), sounds (events), faces, levels (loudness over time). Without media_id: beats on the timeline (beat:N anchors) and analysis jobs. Times are source seconds unless noted.", schema: Schema.object([
            "media_id": Schema.string("Media id; omit for the timeline"),
            "what": Schema.string("What to read", values: ["summary", "beats", "speakers", "shots", "sounds", "faces", "levels", "jobs"]),
            "start": Schema.time("From this source time"),
            "end": Schema.time("Until this source time"),
            "wait": Schema.number("Seconds to wait for running or resumed analysis of this media (all media without media_id) to finish first (up to 600), e.g. before reframing on face data"),
            "start_missing": Schema.bool("When the requested analysis was never run and isn't queued, start it in the background (then wait applies to it); default false"),
        ])) { [unowned self] args in
            let b = try session.requireBundle()
            let p = try session.project()
            let what = args.optString("what") ?? "summary"
            var lines: [String] = []
            if let id = args.optString("media_id"), let m = p.mediaAsset(id), let feature = Toolbox.feature(for: what),
               !Toolbox.hasAnalysis(feature, id, b), !session.jobs.active.contains(where: { $0.mediaId == id && $0.features.contains(feature.rawValue) }) {
                if args.bool("start_missing", default: false) {
                    let job = session.jobs.enqueue(id, [feature], bundle: b.url, explicit: true)
                    lines.append("Started \(feature.rawValue) analysis of \(id) (\(job)).")
                } else {
                    lines.append("\(feature.rawValue) analysis of \(id) was never run and isn't queued, so waiting won't help. Pass start_missing:true (with wait) or run media_analyze media_id:\"\(id)\" features:[\"\(feature.rawValue)\"].")
                }
            }
            if let w = args.optDouble("wait"), w > 0, !(await session.jobs.wait(timeout: min(w, 600), mediaId: args.optString("media_id"))) {
                lines.append("Analysis still running after \(Int(min(w, 600)))s.")
            }
            let lo = try args.optSourceTime("start") ?? 0, hi = try args.optSourceTime("end") ?? .infinity
            guard let id = args.optString("media_id") else {
                let index = b.anchorIndex(for: p)
                if what == "summary" || what == "beats" {
                    let beats = p.timelineBeats(index), downs = p.timelineBeats(index, downbeats: true)
                    if beats.isEmpty { lines.append("No analyzed music on the timeline.") } else {
                        lines.append("Timeline beats (timeline time; anchors beat:N, downbeat:N): \(beats.count) beats, \(downs.count) downbeats")
                        lines.append("  beats: " + Toolbox.indexed(beats.filter { $0 >= lo && $0 < hi }, from: beats))
                        lines.append("  downbeats: " + Toolbox.indexed(downs.filter { $0 >= lo && $0 < hi }, from: downs))
                    }
                }
                let jobs = session.jobs.all
                if !jobs.isEmpty {
                    lines.append("Jobs:")
                    for j in jobs { lines.append("  \(j.id) \(j.mediaId) \(j.features.joined(separator: "+")): \(j.status)" + (j.status == "running" ? " \(Int(j.progress * 100))%" : "") + (j.message.map { " — \($0)" } ?? "")) }
                }
                return .text(lines.joined(separator: "\n").ifEmptyText("Nothing analyzed yet."))
            }
            guard let m = p.mediaAsset(id) else { throw EditError("No media \(id)") }
            let pending = session.jobs.active.filter { $0.mediaId == id }
            if !pending.isEmpty { lines.append("Still analyzing: " + pending.map { "\($0.features.joined(separator: "+")) \(Int($0.progress * 100))%" }.joined(separator: ", ") + " (pass wait: 300 to block until it finishes)") }
            let all = what == "summary"
            if all {
                lines.append("\(id): \(m.isImage ? "image" : fmt2(m.duration) + "s") \(m.hasVideo ? "\(m.width)×\(m.height)" : "audio only")" + (m.hasVideo && !m.isImage ? " \(Describe.fmtFps(m.fps))fps" : ""))
                if let t = b.transcript(id) { lines.append("Transcript: \(t.words.count) words, \(t.words.filter(\.isFiller).count) fillers (media_transcript)") }
                if let a = b.audioAnalysis(id) { lines.append("Audio: \(fmt1(a.loudnessDb)) dB average, \(a.silences.filter { $0.duration >= 0.5 }.count) pauses ≥0.5s") }
            }
            if all || what == "beats" {
                if let beat = b.analysis(BeatAnalysis.self, id, "beats") {
                    let inRange = beat.beats.enumerated().filter { $0.element >= lo && $0.element < hi }
                    lines.append("Beats: \(fmt1(beat.tempo)) BPM, \(beat.beats.count) beats, \(beat.downbeats.count) downbeats (anchors \(id).bN, \(id).dN)")
                    if what == "beats" {
                        let sorted = beat.energy.sorted()
                        let accent = sorted.isEmpty ? 2 : max(sorted[Int(Double(sorted.count) * 0.9)], sorted[sorted.count / 2] + 0.1)
                        lines.append("  beats: " + inRange.map { "b\($0.offset) \(fmt2($0.element))" + (beat.energy.indices.contains($0.offset) && beat.energy[$0.offset] >= accent ? "!" : "") }.joined(separator: ", "))
                        lines.append("  downbeats: " + beat.downbeats.enumerated().filter { $0.element >= lo && $0.element < hi }.map { "d\($0.offset) \(fmt2($0.element))" }.joined(separator: ", "))
                        lines.append("  (! marks the loudest beats; energy sections: " + Toolbox.energySections(beat) + ")")
                    }
                } else if what == "beats" { lines.append("No beat analysis; run media_analyze features:[\"beats\"].") }
            }
            if all || what == "speakers" {
                if let s = b.analysis(SpeakerAnalysis.self, id, "speakers") {
                    var talk: [String: Seconds] = [:]
                    for seg in s.segments { talk[seg.speaker, default: 0] += seg.end - seg.start }
                    let active = b.analysis(ActiveSpeakers.self, id, "activespeakers")
                    lines.append("Speakers: " + s.speakers.map { "\($0) \(fmt1(talk[$0] ?? 0))s" + (active?.speakerFaces[$0].map { " (on screen as face\($0))" } ?? "") }.joined(separator: ", "))
                    if what == "speakers" {
                        let t = b.transcript(id)
                        for seg in s.segments where seg.end > lo && seg.start < hi {
                            let words = t?.words.filter { $0.start >= seg.start - 0.01 && $0.end <= seg.end + 0.01 }.map(\.text) ?? []
                            lines.append("  \(fmt2(seg.start))–\(fmt2(seg.end)) \(seg.speaker)\(Toolbox.turnEvidence(seg)): " + words.prefix(14).joined(separator: " ") + (words.count > 14 ? " …" : ""))
                        }
                        lines.append("  (voice: how clearly the voice is this speaker's within the file; identity: whether it is the same person as this speaker's turns in other scenes, by voice; pinned/enrolled/named: set by hand, named from a pinned turn in the scene, or carried from one.)")
                        if s.segments.contains(where: { ($0.identity ?? 1) < 0.6 }) {
                            lines.append("Low identity: voices change with each scene's room and mic. Pin a turn per character and scene with transcript_edit from/to + speaker:\"<name>\", then media_analyze features:[\"speakers\"] names the rest of each pinned voice (enroll:true also pins every hand-named word).")
                        }
                    }
                } else if what == "speakers" { lines.append("No speaker analysis; run media_analyze features:[\"speakers\"].") }
            }
            lines += try perceptionLines(id, what: what, bundle: b, lo: lo, hi: hi)
            if all || what == "levels", let a = b.audioAnalysis(id), what == "levels" {
                let step = max(1, Int(a.levelRate))
                let points = stride(from: 0, to: a.levels.count, by: step).compactMap { i -> String? in
                    let t = Double(i) / a.levelRate
                    guard t >= lo && t < hi else { return nil }
                    return "\(Int(t))s \(Int(a.levels[i].rounded()))"
                }
                lines.append("Loudness (dB per second): " + points.joined(separator: ", "))
            }
            return .text(lines.joined(separator: "\n").ifEmptyText("No \(what) analysis for \(id)."))
        })
    }

    /// " (voice 0.93, identity 0.40)", " (pinned)"… for a speaker turn.
    static func turnEvidence(_ seg: SpeakerSegment) -> String {
        var parts: [String] = []
        if let via = seg.via { parts.append(via) }
        if let c = seg.confidence { parts.append("voice \(fmt2(c))") }
        if let i = seg.identity, seg.via != "pinned", seg.via != "enrolled" { parts.append("identity \(fmt2(i))") }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }

    /// The analysis feature an analysis_read `what` needs; nil for reads of import-time results.
    static func feature(for what: String) -> Feature? {
        switch what {
        case "shots", "faces": .shots
        case "beats": .beats
        case "speakers": .speakers
        case "sounds": .sounds
        default: nil
        }
    }

    static func hasAnalysis(_ f: Feature, _ mediaId: String, _ b: ProjectBundle) -> Bool {
        FileManager.default.fileExists(atPath: b.analysisURL.appendingPathComponent("\(mediaId).\(f.rawValue).json").path)
    }

    /// "12:3.50, 13:4.00 …" with each time's index in the full list.
    static func indexed(_ times: [Seconds], from all: [Seconds]) -> String {
        let shown = times.prefix(64).map { t in "\(all.firstIndex(of: t) ?? 0):\(fmt2(t))" }
        return shown.joined(separator: " ") + (times.count > 64 ? " …(\(times.count - 64) more; narrow with start/end)" : "")
    }

    /// Spans where the music is quiet, building or loud, from per-beat energy.
    static func energySections(_ b: BeatAnalysis) -> String {
        guard b.beats.count >= 8 else { return "too short" }
        var out: [String] = []
        var startIdx = 0
        func level(_ e: Float) -> String { e < 0.45 ? "quiet" : e < 0.75 ? "medium" : "loud" }
        let smooth = b.energy.indices.map { i in b.energy[max(0, i - 4)...min(b.energy.count - 1, i + 4)].reduce(0, +) / Float(min(b.energy.count - 1, i + 4) - max(0, i - 4) + 1) }
        for i in 1...smooth.count where i == smooth.count || level(smooth[i]) != level(smooth[startIdx]) {
            if i - startIdx >= 4 || i == smooth.count { out.append("\(level(smooth[startIdx])) \(fmt1(b.beats[startIdx]))–\(fmt1(i < b.beats.count ? b.beats[i] : b.beats.last!))") }
            startIdx = i
        }
        return out.joined(separator: ", ")
    }

    func perceptionLines(_ id: String, what: String, bundle b: ProjectBundle, lo: Seconds, hi: Seconds) throws -> [String] {
        var lines: [String] = []
        let all = what == "summary"
        if all || what == "shots" {
            if let a = b.analysis(ShotAnalysis.self, id, "shots") {
                let shots = a.shots.filter { $0.end > lo && $0.start < hi }
                lines.append("Shots (\(a.shots.count); anchors \(id).sN, \(id).sN.end):")
                for s in shots.prefix(all ? 12 : 60) {
                    var parts = [s.labels.prefix(all ? 3 : 6).joined(separator: ", ").ifEmptyText("unlabeled"), s.size]
                    if s.people > 0 { parts.append("\(s.people) \(s.people == 1 ? "person" : "people")") }
                    if !s.text.isEmpty { parts.append("text \"" + s.text.prefix(2).joined(separator: " / ") + "\"") }
                    if let ae = s.aesthetics { parts.append("aesthetics \(fmt2(ae))" + (s.utility == true ? " (utility shot)" : "")) }
                    parts.append(s.motion > 0.25 ? "lots of motion" : s.motion > 0.08 ? "some motion" : "still")
                    parts.append("brightness \(fmt2(s.brightness))")
                    if !all, let sal = s.saliency { parts.append("subject at \(fmt2(sal.midX)),\(fmt2(sal.midY))") }
                    lines.append("  s\(s.index) \(fmt2(s.start))–\(fmt2(s.end)): " + parts.joined(separator: "; "))
                }
                if shots.count > (all ? 12 : 60) { lines.append("  …\(shots.count - (all ? 12 : 60)) more; read what:\"shots\" with start/end") }
            } else if what == "shots" { lines.append("No shot analysis; run media_analyze features:[\"shots\"].") }
        }
        if all || what == "faces", let a = b.analysis(ShotAnalysis.self, id, "shots") {
            if what == "faces" {
                lines.append("Face tracks (boxes are fractions of the frame, top-left origin):")
                for f in a.faces where f.end > lo && f.start < hi {
                    let mid = f.samples[f.samples.count / 2].box
                    lines.append("  face\(f.id) \(fmt2(f.start))–\(fmt2(f.end)): center \(fmt2(mid.midX)),\(fmt2(mid.midY)), height \(fmt2(mid.height)), \(f.samples.count) samples")
                }
                if a.faces.isEmpty { lines.append("  none") }
            } else if !a.faces.isEmpty {
                lines.append("Faces: \(a.faces.count) tracks (what:\"faces\")")
            }
        }
        if all || what == "sounds" {
            if let e = b.analysis(SoundEvents.self, id, "sounds") {
                let events = e.events.filter { $0.end > lo && $0.start < hi }
                if all {
                    let totals = Dictionary(grouping: events, by: \.label).map { ($0.key, $0.value.map(\.duration).reduce(0, +)) }.sorted { $0.1 > $1.1 }.prefix(6)
                    lines.append("Sounds: " + totals.map { "\($0.0) \(fmt1($0.1))s" }.joined(separator: ", ").ifEmptyText("nothing distinct"))
                } else {
                    lines.append("Sound events:")
                    lines += events.prefix(80).map { "  \(fmt2($0.start))–\(fmt2($0.end)) \($0.label) (\(Int($0.confidence * 100))%)" }
                }
            } else if what == "sounds" { lines.append("No sound analysis; run media_analyze features:[\"sounds\"].") }
        }
        return lines
    }
}
