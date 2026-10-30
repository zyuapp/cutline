import AVFoundation
import CutlineCore
import Foundation

/// Collects a project's media into one folder, whole or trimmed to the ranges the edit uses.
public enum Consolidate {
    /// Copies media into `dir` following `ConsolidatePlan`. Trimmed copies are passthrough exports
    /// (no re-encode) of each used range plus `handles`. Returns the project pointing at the copies,
    /// the bytes written and the plan, whose items re-time analysis to the copies.
    public static func collect(_ project: Project, to dir: URL, trim: Bool, handles: Seconds = 1, transcripts: [String: Transcript] = [:], progress: (@Sendable (Double) -> Void)? = nil) async throws -> (project: Project, bytes: Int64, plan: ConsolidatePlan) {
        let plan = ConsolidatePlan(project, trim: trim, handles: handles)
        let fm = FileManager.default
        let missing = Set(plan.items.map(\.sourcePath).filter { !fm.fileExists(atPath: $0) })
        guard missing.isEmpty else { throw EditError("Missing media: \(missing.sorted().joined(separator: ", ")); relink it first") }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var out = plan.apply(to: project, directory: dir, transcripts: transcripts)
        var bytes: Int64 = 0
        for (n, item) in plan.items.enumerated() {
            let dest = dir.appendingPathComponent(item.fileName)
            if let range = item.range {
                try await export(URL(fileURLWithPath: item.sourcePath), range: range, to: dest)
                let probed = try await MediaProbe.probe(dest, id: item.newId)
                if let i = out.media.firstIndex(where: { $0.id == item.newId }) {
                    // Passthrough audio can come back a few milliseconds short of the range; keep the planned length.
                    let planned = item.range?.duration ?? probed.duration
                    out.media[i].duration = abs(planned - probed.duration) < 0.1 ? max(planned, probed.duration) : probed.duration
                    out.media[i].hasAudio = probed.hasAudio
                    out.media[i].hasVideo = probed.hasVideo
                }
            } else if URL(fileURLWithPath: item.sourcePath).standardizedFileURL != dest.standardizedFileURL {
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: URL(fileURLWithPath: item.sourcePath), to: dest)
            }
            bytes += (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            progress?(Double(n + 1) / Double(max(plan.items.count, 1)))
        }
        return (out, bytes, plan)
    }

    /// A passthrough copy of a source range; the copy's time 0 is `range.start`.
    static func export(_ source: URL, range: TimeRange, to dest: URL) async throws {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw EditError("Cannot copy \(source.lastPathComponent)")
        }
        let t = { (s: Seconds) in CMTime(value: CMTimeValue((s * 600_000).rounded()), timescale: 600_000) }
        session.timeRange = CMTimeRange(start: t(range.start), end: t(range.end))
        try? FileManager.default.removeItem(at: dest)
        try await session.export(to: dest, as: .mov)
    }
}
