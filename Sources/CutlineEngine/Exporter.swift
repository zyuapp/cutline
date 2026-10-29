import AVFoundation
import CutlineCore
import Foundation

public enum ExportPreset: String, CaseIterable, Sendable {
    case hevc
    case h264
    case prores

    var avPreset: String {
        switch self {
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        case .h264: AVAssetExportPresetHighestQuality
        case .prores: AVAssetExportPresetAppleProRes422LPCM
        }
    }

    public var fileType: AVFileType { self == .prores ? .mov : .mp4 }
    public var fileExtension: String { self == .prores ? "mov" : "mp4" }
}

public enum Exporter {
    public static func export(_ built: BuiltTimeline, to url: URL, preset: ExportPreset, range: TimeRange? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset.avPreset) else {
            throw EditError("Export preset \(preset.rawValue) is not available")
        }
        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.audioTimePitchAlgorithm = .spectral
        if let range {
            session.timeRange = CMTimeRange(start: TimelineBuilder.time(range.start), end: TimelineBuilder.time(min(range.end, built.duration)))
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let watcher = Task {
            for await state in session.states(updateInterval: 0.5) {
                if case .exporting(let p) = state { progress?(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: preset.fileType)
    }
}
