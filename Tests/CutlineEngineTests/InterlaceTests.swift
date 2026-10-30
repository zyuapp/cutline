import AVFoundation
import CoreMedia
import CutlineCore
@testable import CutlineEngine
import Foundation
import Testing

private func filled(_ value: UInt8) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 8, 6, kCVPixelFormatType_32BGRA, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    memset(CVPixelBufferGetBaseAddress(pb!), Int32(value), CVPixelBufferGetBytesPerRow(pb!) * 6)
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}

private func rowValues(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    return (0..<6).map { base[$0 * CVPixelBufferGetBytesPerRow(pb)] }
}

@Test func weavePutsTheEarlierFieldOnTheLeadingLines() throws {
    let early = filled(0), late = filled(200)
    #expect(rowValues(try #require(Interlace.weave(early, late, order: .tff))) == [0, 200, 0, 200, 0, 200])
    #expect(rowValues(try #require(Interlace.weave(early, late, order: .bff))) == [200, 0, 200, 0, 200, 0])
}

@Test func interlacedProResIsFlaggedAndKeepsFrameRate() async throws {
    var p = Project(name: "Fields", canvas: Canvas(width: 320, height: 180, fps: 25))
    p.tracks[0].clips = [Clip(id: "s", kind: .solid, start: 0, duration: 1, color: RGBA(r: 0.2, g: 0.4, b: 0.8))]
    let built = try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-fields-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: url) }
    var options = ExportOptions(preset: .prores_hq)
    options.interlaced = .tff
    try await Exporter.export(built, to: url, options: options)
    let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FieldCount) as? Int == 2)
    #expect(abs(try await track.load(.nominalFrameRate) - 25) < 0.01)
    let duration = try await AVURLAsset(url: url).load(.duration).seconds
    #expect(abs(duration - 1) < 0.05)

    var h264 = ExportOptions(preset: .h264)
    h264.interlaced = .tff
    await #expect(throws: EditError.self) { try await Exporter.export(built, to: url, options: h264) }
}
