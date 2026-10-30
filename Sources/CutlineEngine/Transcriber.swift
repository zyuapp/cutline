import AVFoundation
import CutlineCore
import Foundation
import Speech

/// On-device speech-to-text with word timings.
public enum Transcriber {
    public static func transcribe(pcmURL: URL, mediaId: String, locale identifier: String) async throws -> Transcript {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw EditError("Speech recognition does not support \(identifier)")
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: pcmURL)
        let collector = Task { () -> [Word] in
            var words: [Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    words.append(Word(text: text, start: range.start.seconds, end: range.end.seconds))
                }
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
    public static func transcribe(pcmURL: URL, mediaId: String, locale identifier: String, bounds: [Seconds], checkpoint: URL?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        guard !bounds.isEmpty else { return try await transcribe(pcmURL: pcmURL, mediaId: mediaId, locale: identifier) }
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
            do {
                let out = try AVAudioFile(forWriting: piece, settings: file.fileFormat.settings, commonFormat: file.processingFormat.commonFormat, interleaved: file.processingFormat.isInterleaved)
                try out.write(from: buffer)
            }
            let t = try await transcribe(pcmURL: piece, mediaId: mediaId, locale: identifier)
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
