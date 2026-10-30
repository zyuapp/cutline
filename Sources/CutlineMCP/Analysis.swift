import CutlineCore
import CutlineEngine
import Foundation

enum Feature: String, CaseIterable {
    case transcript, scenes, beats, speakers, shots, sounds, proxy
}

extension Session {
    /// What import analyzes right away; everything else runs in the background.
    static func defaultFeatures(_ m: MediaAsset) -> (now: [Feature], later: [Feature]) {
        var now: [Feature] = [], later: [Feature] = []
        if m.hasAudio { now += [.transcript, .beats, .speakers] }
        if m.hasVideo && !m.isImage { now.append(.scenes); later += [.proxy, .shots] }
        if m.isImage { later.append(.shots) }
        if m.hasAudio { later.append(.sounds) }
        return (now, later)
    }

    /// Runs analysis features for one media file and stores the results in the bundle.
    /// Beats run only on music-like media (little speech) unless asked for explicitly. `finished` hears each
    /// feature as it is saved, with its notes; long transcripts and shot analysis also checkpoint within a feature.
    /// `enroll`: true makes every hand-named word a pin, false starts speakers afresh, nil keeps pins and names.
    func analyze(_ media: MediaAsset, features: [Feature], language: String, explicit: Bool, enroll: Bool? = nil, progress: (@Sendable (Double) -> Void)? = nil, finished: (@Sendable (String, [String]) -> Void)? = nil) async throws -> String {
        let b = try requireBundle()
        var notes: [String] = []
        var reported = 0
        func step(_ f: Feature) {
            guard features.contains(f) else { return }
            finished?(f.rawValue, Array(notes[reported...]))
            reported = notes.count
        }
        let checkpoints = b.cacheURL.appendingPathComponent("checkpoints", isDirectory: true)
        let want = Set(features)
        var transcript = b.transcript(media.id)
        // Multichannel files and a chosen analysis channel are heard through a mono copy of those channels.
        var heard = media
        let audioWork: Set<Feature> = [.transcript, .speakers, .beats, .sounds]
        if media.hasAudio, !media.isImage, !want.isDisjoint(with: audioWork),
           let source = try await SourceChannels.analysisSource(media, channel: media.analysisChannel, cache: b.cacheURL.appendingPathComponent("analysis-audio", isDirectory: true)) {
            heard.path = source.url.path
            notes.append("audio from \(source.heard)")
        }
        if media.hasAudio && (want.contains(.transcript) || want.contains(.speakers) && transcript == nil) {
            try FileManager.default.createDirectory(at: b.cacheURL, withIntermediateDirectories: true)
            let pcm = b.cacheURL.appendingPathComponent("\(media.id).caf")
            defer { try? FileManager.default.removeItem(at: pcm) }
            let a = try await AudioAnalyzer.analyze(media: heard, pcmURL: pcm)
            try b.saveAudioAnalysis(a)
            let long = a.silences.filter { $0.duration >= 0.5 }
            notes.append("audio: loudness \(String(format: "%.1f", a.loudnessDb)) dB, \(long.count) pauses ≥0.5s totaling \(fmt1(long.map(\.duration).reduce(0, +)))s")
            do {
                let bounds = Transcriber.chunkBounds(duration: media.duration, silences: a.silences)
                let vocabulary = transcriptVocabulary(media, bundle: b)
                let (raw, steps) = try await Transcriber.analyze(pcmURL: pcm, mediaId: media.id, locale: language, vocabulary: vocabulary, bounds: bounds, checkpoints: checkpoints) { p in progress?(0.3 * p) }
                let t = Transcriber.tighten(raw, audio: a)
                try b.saveTranscript(t)
                transcript = t
                let unsure = t.words.filter(\.isLowConfidence).count
                notes.append("transcript: \(t.words.count) words, \(t.words.filter(\.isFiller).count) fillers, \(unsure) low-confidence" + (steps.isEmpty ? "" : " (" + steps.joined(separator: "; ") + ")"))
            } catch {
                notes.append("transcript failed: \(error.localizedDescription)")
            }
        }
        step(.transcript)
        progress?(0.3)
        let words = transcript?.words.count ?? 0
        let musicLike = media.hasAudio && Double(words) < max(4, media.duration / 6)
        if want.contains(.beats), media.hasAudio, explicit || musicLike {
            let beats = try await BeatTracker.analyze(url: heard.url, mediaId: media.id)
            try b.saveAnalysis(beats, media.id, "beats")
            notes.append(beats.beats.isEmpty ? "beats: none found" : "beats: \(Int(beats.tempo.rounded())) BPM, \(beats.beats.count) beats (\(media.id).b0…b\(beats.beats.count - 1)), \(beats.downbeats.count) downbeats")
        }
        step(.beats)
        progress?(0.45)
        if want.contains(.speakers), let transcript, words >= (explicit ? 1 : 20) {
            let enrollment = enroll == false ? nil : Session.enrollment(b.analysis(SpeakerAnalysis.self, media.id, "speakers"), transcript: transcript, namedArePins: enroll == true)
            let s = try await Diarizer.analyze(url: heard.url, transcript: transcript, enrollment: enrollment)
            try b.saveAnalysis(s, media.id, "speakers")
            notes.append("speakers: \(s.speakers.count) (\(s.speakers.joined(separator: ", ")))" + Session.enrollmentNote(s))
        }
        step(.speakers)
        progress?(0.55)
        if want.contains(.scenes), media.hasVideo, !media.isImage {
            let cuts = try await SceneDetector.detect(media)
            try b.saveVisualAnalysis(VisualAnalysis(mediaId: media.id, sceneCuts: cuts))
            let shots = Shot.spans(cuts: cuts, duration: media.duration).count
            notes.append("scenes: \(cuts.count) cuts, \(shots) shots (\(media.id).s0…s\(max(0, shots - 1)), long takes split every 8 s)")
        }
        step(.scenes)
        progress?(0.65)
        let perception = try await analyzePerception(media, want, bundle: b, heard: heard.url, progress: progress) { f, found in
            notes += found
            step(f)
        }
        notes += perception.filter { !notes.contains($0) }
        built = nil
        return notes.joined(separator: "; ")
    }

    /// Pins and names of `previous` to keep; with `namedArePins`, every hand-named word is pinned too.
    static func enrollment(_ previous: SpeakerAnalysis?, transcript: Transcript, namedArePins: Bool = false) -> Diarizer.Enrollment? {
        guard var e = Diarizer.Enrollment(previous, wordCount: transcript.words.count) else { return nil }
        if namedArePins { e.pinned = zip(e.pinned, e.named).map { $0 ?? $1 } }
        return e
    }

    static func enrollmentNote(_ s: SpeakerAnalysis) -> String {
        let pins = s.pins?.count ?? 0
        let named = s.namedSpeakers
        guard pins > 0 || !named.isEmpty else { return "" }
        return " — kept \(pins) pinned turn(s)" + (named.isEmpty ? "" : "; named " + named.joined(separator: ", ") + " from pinned and earlier-named turns")
    }

    /// Spellings transcription should use for `media`: its vocabulary, caption replacement targets and named speakers.
    func transcriptVocabulary(_ media: MediaAsset, bundle b: ProjectBundle) -> [String] {
        guard let p = try? project() else { return media.vocabulary ?? [] }
        let names = p.media.flatMap { b.analysis(SpeakerAnalysis.self, $0.id, "speakers")?.speakers ?? [] }
        return Vocabulary.terms(p, media: media, speakerNames: names)
    }
}
