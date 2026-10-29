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
