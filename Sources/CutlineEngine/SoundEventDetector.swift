import AVFoundation
import CutlineCore
import Foundation
import SoundAnalysis

public enum SoundEventDetector {
    static let sampleRate = 16_000.0
    static let windowDuration = 1.5
    static let overlap = 0.5

    /// Classifies the first audio track in 1.5 s windows with Apple's built-in sound classifier
    /// and merges runs of the same label (confidence ≥ 0.5, at least 0.5 s) into events.
    public static func analyze(url: URL, mediaId: String) async throws -> SoundEvents {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EditError("\(mediaId) has no audio")
        }
        return try await runBlocking { _ in
            let windows = try classify(asset: asset, track: track, mediaId: mediaId)
            return SoundEvents(mediaId: mediaId, events: SoundEvents.merge(windows).map(rounded))
        }
    }

    /// Classifier labels that are someone talking.
    static let speechLabels: Set<String> = ["speech", "shout", "yell", "whispering", "battle cry", "children shouting", "chatter"]

    /// Where the sound classifier hears talking in a mono PCM file (any rate), windows of speech labels at
    /// `minConfidence` or more merged across gaps under 0.3 s.
    public static func speech(pcmURL: URL, minConfidence: Double = 0.3) async throws -> [TimeRange] {
        try await runBlocking { _ in
            let file = try AVAudioFile(forReading: pcmURL)
            let format = file.processingFormat
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = window(for: request.windowDurationConstraint)
            request.overlapFactor = overlap
            let observer = Observer(minimum: minConfidence, labels: speechLabels)
            try analyzer.add(request, withObserver: observer)
            let chunk: AVAudioFrameCount = 1 << 16
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw EditError("Cannot allocate audio") }
            while file.framePosition < file.length {
                let at = file.framePosition
                try file.read(into: buffer, frameCount: chunk)
                guard buffer.frameLength > 0 else { break }
                analyzer.analyze(buffer, atAudioFramePosition: at)
            }
            analyzer.completeAnalysis()
            if let error = observer.error { throw error }
            return TimeRange.merged(observer.windows.map { TimeRange($0.start, $0.end) }, tolerance: 0.3)
        }
    }

    static func classify(asset: AVAsset, track: AVAssetTrack, mediaId: String) throws -> [SoundEvent] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read audio of \(mediaId)") }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = window(for: request.windowDurationConstraint)
        request.overlapFactor = overlap
        let observer = Observer()
        try analyzer.add(request, withObserver: observer)

        var position: AVAudioFramePosition = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { continue }
            let n = length / MemoryLayout<Float>.size
            guard n > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { continue }
            pcm.frameLength = AVAudioFrameCount(n)
            ptr.withMemoryRebound(to: Float.self, capacity: n) { pcm.floatChannelData![0].update(from: $0, count: n) }
            analyzer.analyze(pcm, atAudioFramePosition: position)
            position += AVAudioFramePosition(n)
        }
        analyzer.completeAnalysis()
        if reader.status == .failed { throw reader.error ?? EditError("Audio decode failed for \(mediaId)") }
        if let error = observer.error { throw error }
        return observer.windows
    }

    /// The supported window duration closest to `windowDuration`.
    static func window(for constraint: SNTimeDurationConstraint) -> CMTime {
        let target = CMTime(seconds: windowDuration, preferredTimescale: 48_000)
        switch constraint {
        case .enumeratedDurations(let durations):
            return durations.min { abs($0.seconds - windowDuration) < abs($1.seconds - windowDuration) } ?? target
        case .durationRange(let range):
            return CMTimeClampToRange(target, range: range)
        @unknown default:
            return target
        }
    }

    static func rounded(_ e: SoundEvent) -> SoundEvent {
        SoundEvent(label: e.label, start: (e.start * 100).rounded() / 100, end: (e.end * 100).rounded() / 100, confidence: (e.confidence * 100).rounded() / 100)
    }

    final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var _windows: [SoundEvent] = []
        private var _error: Error?
        let minimum: Double
        /// Only these labels, when set.
        let labels: Set<String>?

        init(minimum: Double = 0.5, labels: Set<String>? = nil) {
            self.minimum = minimum
            self.labels = labels
        }

        var windows: [SoundEvent] { lock.withLock { _windows } }
        var error: Error? { lock.withLock { _error } }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let r = result as? SNClassificationResult else { return }
            let start = r.timeRange.start.seconds, end = r.timeRange.end.seconds
            guard start.isFinite, end.isFinite, end > start else { return }
            let hits = r.classifications.filter { $0.confidence >= minimum }.map {
                SoundEvent(label: $0.identifier.replacingOccurrences(of: "_", with: " "), start: start, end: end, confidence: $0.confidence)
            }.filter { labels?.contains($0.label) ?? true }
            lock.withLock { _windows += hits }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            lock.withLock { _error = error }
        }
    }
}
