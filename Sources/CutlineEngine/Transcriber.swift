import AVFoundation
import CutlineCore
import Foundation
import Speech

/// On-device speech-to-text with word timings.
public enum Transcriber {
    /// Words recognized in `pcmURL` with their times and the recognizer's confidence, by SpeechAnalyzer's
    /// SpeechTranscriber (installing the locale's model when missing). `vocabulary` (names, product terms) goes in as
    /// contextual strings, and where the recognizer offers an alternative reading of a phrase that spells a term its
    /// best reading doesn't, that alternative is taken.
    public static func transcribe(pcmURL: URL, mediaId: String, locale identifier: String, vocabulary: [String] = []) async throws -> Transcript {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw EditError("Speech recognition does not support \(identifier)")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: vocabulary.isEmpty ? [] : [.alternativeTranscriptions], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        let file = try AVAudioFile(forReading: pcmURL)
        let collector = Task { () -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results {
                let pick = Vocabulary.preferred(result.alternatives.map { String($0.characters) }, terms: vocabulary)
                let chosen = pick > 0 ? Self.words(result.alternatives[pick]) : []
                words += chosen.isEmpty ? Self.words(result.text) : chosen
            }
            return words
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let words = try await collector.value.sorted { $0.start < $1.start }
        return Transcript(mediaId: mediaId, locale: locale.identifier, words: words)
    }

    /// One word per timed run of a result, with its confidence.
    static func words(_ text: AttributedString) -> [Word] {
        var out: [Word] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let t = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let confidence = run.transcriptionConfidence.map { ($0 * 100).rounded() / 100 }
            out.append(Word(text: t, start: range.start.seconds, end: range.end.seconds, confidence: confidence))
        }
        return out
    }

    /// Second pass over `gaps`, spans where speech is heard but the first pass found no words: each is transcribed
    /// alone with `pad` seconds around it, through voice isolation when `isolate`, and the words that land inside it
    /// are added. Returns the transcript and how many words were added.
    public static func recover(_ transcript: Transcript, gaps: [TimeRange], pcmURL: URL, vocabulary: [String] = [], isolate: Bool = true, pad: Seconds = 1) async throws -> (Transcript, added: Int) {
        guard !gaps.isEmpty else { return (transcript, 0) }
        let file = try AVAudioFile(forReading: pcmURL)
        let rate = file.processingFormat.sampleRate
        var t = transcript
        var added = 0
        let dir = pcmURL.deletingLastPathComponent()
        for (i, gap) in gaps.enumerated() {
            let from = max(0, gap.start - pad)
            let lo = AVAudioFramePosition(from * rate), hi = min(file.length, AVAudioFramePosition((gap.end + pad) * rate))
            guard hi - lo > AVAudioFramePosition(0.3 * rate),
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(hi - lo)) else { continue }
            file.framePosition = lo
            try file.read(into: buffer, frameCount: AVAudioFrameCount(hi - lo))
            var piece = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            if isolate { let dry = piece; piece = (try? await runBlocking { _ in try isolateVoice(dry, sampleRate: rate) }) ?? piece }
            let url = dir.appendingPathComponent("\(transcript.mediaId)-gap\(i).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            try AudioDSP.write([piece], sampleRate: rate, to: url)
            let found = try await transcribe(pcmURL: url, mediaId: transcript.mediaId, locale: transcript.locale, vocabulary: vocabulary).words
                .map { var w = $0; w.start += from; w.end += from; return w }
            added += t.addRecovered(found, in: [gap])
        }
        return (t, added)
    }

    /// Mono `samples` through Apple's voice isolation (AUSoundIsolation), time-aligned with the input.
    public static func isolateVoice(_ samples: [Float], sampleRate: Double) throws -> [Float] {
        let unit = AudioChain.apple(kAudioUnitSubType_AUSoundIsolation)
        AudioChain.set(unit, 0, 100)
        return try AudioUnitHost.render([samples], sampleRate: sampleRate, units: [unit], tail: 0)[0]
    }

    /// Where a long recording is cut for chunked transcription: the middle of the pause nearest each multiple of
    /// `every` seconds (within a quarter chunk), else at the multiple itself. Empty for recordings under two chunks.
    public static func chunkBounds(duration: Seconds, silences: [TimeRange], every: Seconds = 120) -> [Seconds] {
        guard duration >= 2 * every else { return [] }
        var out: [Seconds] = []
        var target = every
        while target < duration - every / 2 {
            let near = silences.filter { $0.duration >= 0.25 && abs($0.start + $0.duration / 2 - target) <= every / 4 }
            let cut = near.min { abs($0.start + $0.duration / 2 - target) < abs($1.start + $1.duration / 2 - target) }.map { $0.start + $0.duration / 2 } ?? target
            if cut > (out.last ?? 0) + every / 4 { out.append(cut) }
            target += every
        }
        return out
    }

    /// Words of the chunks transcribed so far.
    struct Checkpoint: Codable {
        var bounds: [Seconds]
        var locale: String
        var done: Int
        var words: [Word]
    }

    /// `transcribe` in chunks cut at `bounds` (source seconds), each saved to `checkpoint` as it finishes so a
    /// restarted transcription continues with the next chunk. The checkpoint is removed when all are done.
    /// `isolate` runs each chunk through voice isolation first.
    public static func transcribe(pcmURL: URL, mediaId: String, locale identifier: String, vocabulary: [String] = [], bounds: [Seconds], isolate: Bool = false, checkpoint: URL?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        guard !bounds.isEmpty || isolate else { return try await transcribe(pcmURL: pcmURL, mediaId: mediaId, locale: identifier, vocabulary: vocabulary) }
        let file = try AVAudioFile(forReading: pcmURL)
        let rate = file.processingFormat.sampleRate
        let total = Seconds(file.length) / rate
        let edges = [0] + bounds + [total]
        var state = checkpoint.flatMap { try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: $0)) }
            .flatMap { $0.bounds == bounds && $0.locale == identifier ? $0 : nil } ?? Checkpoint(bounds: bounds, locale: identifier, done: 0, words: [])
        var localeId = identifier
        let dir = pcmURL.deletingLastPathComponent()
        for i in state.done..<(edges.count - 1) {
            let lo = AVAudioFramePosition(edges[i] * rate), hi = min(file.length, AVAudioFramePosition(edges[i + 1] * rate))
            guard hi > lo, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(hi - lo)) else { continue }
            file.framePosition = lo
            try file.read(into: buffer, frameCount: AVAudioFrameCount(hi - lo))
            let piece = dir.appendingPathComponent("\(mediaId)-chunk\(i).caf")
            defer { try? FileManager.default.removeItem(at: piece) }
            if isolate, let data = buffer.floatChannelData {
                let mono = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
                try AudioDSP.write([try await runBlocking { _ in try isolateVoice(mono, sampleRate: rate) }], sampleRate: rate, to: piece)
            } else {
                let out = try AVAudioFile(forWriting: piece, settings: file.fileFormat.settings, commonFormat: file.processingFormat.commonFormat, interleaved: file.processingFormat.isInterleaved)
                try out.write(from: buffer)
            }
            let t = try await transcribe(pcmURL: piece, mediaId: mediaId, locale: identifier, vocabulary: vocabulary)
            localeId = t.locale
            state.words += t.words.map { var w = $0; w.start += edges[i]; w.end += edges[i]; return w }
            state.done = i + 1
            if let checkpoint {
                try? FileManager.default.createDirectory(at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(state).write(to: checkpoint, options: .atomic)
            }
            progress?(Double(i + 1) / Double(edges.count - 1))
        }
        if let checkpoint { try? FileManager.default.removeItem(at: checkpoint) }
        return Transcript(mediaId: mediaId, locale: localeId, words: state.words.sorted { $0.start < $1.start })
    }

    /// Above this share of low-confidence words, a voice-isolated reading is made and taken where it scores higher.
    public static let isolationTrigger = 0.05

    /// The full transcription analysis runs: the chunked first pass; when many words are uncertain, a second reading
    /// of voice-isolated audio taken stretch by stretch where it is more confident (`Transcript.adoptBetter`); the
    /// vocabulary's spellings; and a pass over speech the sound classifier hears but no word covers. `notes` says
    /// what each step changed.
    public static func analyze(pcmURL: URL, mediaId: String, locale: String, vocabulary: [String] = [], bounds: [Seconds], checkpoints: URL?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> (transcript: Transcript, notes: [String]) {
        var notes: [String] = []
        let plainCheckpoint = checkpoints?.appendingPathComponent("\(mediaId)-transcript.json")
        var t = try await transcribe(pcmURL: pcmURL, mediaId: mediaId, locale: locale, vocabulary: vocabulary, bounds: bounds, checkpoint: plainCheckpoint) { p in progress?(0.6 * p) }
        if t.lowConfidenceShare >= isolationTrigger {
            let isolatedCheckpoint = checkpoints?.appendingPathComponent("\(mediaId)-transcript-isolated.json")
            let isolated = try await transcribe(pcmURL: pcmURL, mediaId: mediaId, locale: locale, vocabulary: vocabulary, bounds: bounds, isolate: true, checkpoint: isolatedCheckpoint) { p in progress?(0.6 + 0.3 * p) }
            let n = t.adoptBetter(isolated)
            if n > 0 { notes.append("voice-isolated reading taken in \(n) stretch\(n == 1 ? "" : "es")") }
        }
        let respelled = t.applyVocabulary(vocabulary)
        if !respelled.isEmpty { notes.append("vocabulary respelled " + respelled.prefix(4).map { "\"\($0.1)\" → \"\($0.2)\"" }.joined(separator: ", ") + (respelled.count > 4 ? " (+\(respelled.count - 4))" : "")) }
        let speech = try await SoundEventDetector.speech(pcmURL: pcmURL)
        let gaps = t.unheardSpeech(speech)
        if !gaps.isEmpty {
            let (r, added) = try await recover(t, gaps: gaps, pcmURL: pcmURL, vocabulary: vocabulary)
            t = r
            notes.append("second pass over \(gaps.count) span\(gaps.count == 1 ? "" : "s") of speech without words added \(added)")
        }
        progress?(1)
        return (t, notes)
    }

    /// Recognizer word spans often include the surrounding pause. Shrinks each word to the
    /// span where its audio is above the silence threshold, keeping a little padding.
    public static func tighten(_ transcript: Transcript, audio: AudioAnalysis) -> Transcript {
        var t = transcript
        let rate = audio.levelRate
        let pad = 0.06
        for i in t.words.indices {
            let w = t.words[i]
            let lo = max(0, Int(w.start * rate)), hi = min(Int(w.end * rate), audio.levels.count)
            guard hi > lo else { continue }
            let voiced = (lo..<hi).filter { Double(audio.levels[$0]) > audio.silenceThresholdDb }
            guard let first = voiced.first, let last = voiced.last else { continue }
            let start = max(w.start, Double(first) / rate - pad)
            let end = min(w.end, Double(last + 1) / rate + pad)
            if end - start >= 0.08 {
                t.words[i].start = start
                t.words[i].end = end
            }
        }
        return t
    }
}
