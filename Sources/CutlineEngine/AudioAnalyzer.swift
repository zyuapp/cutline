import AVFoundation
import CutlineCore
import Foundation

public enum AudioAnalyzer {
    public static let levelRate = 100.0
    static let sampleRate = 16_000.0

    /// Decodes the first audio track to 16 kHz mono, computing RMS levels per 10 ms.
    /// When `pcmURL` is given the decoded audio is also written there for transcription.
    public static func analyze(media: MediaAsset, pcmURL: URL? = nil) async throws -> AudioAnalysis {
        let asset = AVURLAsset(url: media.url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EditError("\(media.id) has no audio")
        }
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
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read audio of \(media.id)") }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        var file: AVAudioFile?
        if let pcmURL {
            try? FileManager.default.removeItem(at: pcmURL)
            file = try AVAudioFile(forWriting: pcmURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        let window = Int(sampleRate / levelRate)
        var levels: [Float] = []
        levels.reserveCapacity(Int(media.duration * levelRate) + 1)
        var acc: Float = 0
        var count = 0

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { continue }
            let n = length / MemoryLayout<Float>.size
            ptr.withMemoryRebound(to: Float.self, capacity: n) { samples in
                for i in 0..<n {
                    let s = samples[i]
                    acc += s * s
                    count += 1
                    if count == window {
                        levels.append(db(acc / Float(count)))
                        acc = 0
                        count = 0
                    }
                }
                if let file, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) {
                    pcm.frameLength = AVAudioFrameCount(n)
                    pcm.floatChannelData![0].update(from: samples, count: n)
                    try? file.write(from: pcm)
                }
            }
        }
        if count > 0 { levels.append(db(acc / Float(count))) }
        if reader.status == .failed { throw reader.error ?? EditError("Audio decode failed for \(media.id)") }

        let threshold = AudioAnalysis.adaptiveThreshold(levels: levels)
        let silences = AudioAnalysis.detectSilences(levels: levels, rate: levelRate, thresholdDb: threshold, minDuration: 0.3)
        let voiced = levels.filter { Double($0) > threshold }
        let loudness = voiced.isEmpty ? -80 : Double(voiced.reduce(0, +)) / Double(voiced.count)
        return AudioAnalysis(mediaId: media.id, levelRate: levelRate, levels: levels.map { ($0 * 10).rounded() / 10 }, silences: silences, silenceThresholdDb: threshold, loudnessDb: loudness)
    }

    static func db(_ meanSquare: Float) -> Float {
        max(-80, 10 * log10(max(meanSquare, 1e-10)))
    }
}
