import AVFoundation
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// One second of a textured background with a red square moving right 3 px a frame.
private func squareMovie(_ url: URL) async throws {
    let w = 320, h = 180
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<30 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<h {
            for x in 0..<w {
                let p = base + y * rowBytes + x * 4
                let inSquare = x >= 60 + 3 * i && x < 90 + 3 * i && y >= 70 && y < 100
                let v = UInt8(90 + (x * 7 + y * 13) % 40 + ((x / 9 + y / 7) % 2) * 50)
                p[0] = inSquare ? 30 : v
                p[1] = inSquare ? 30 : v
                p[2] = inSquare ? 230 : v
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

@Test func finishingToolsTrackMaskAndRemoveAnObject() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-finishing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let movie = dir.appendingPathComponent("square.mov")
    try await squareMovie(movie)
    var project = Project(name: "Finishing", canvas: Canvas(width: 320, height: 180, fps: 30))
    project.media = [try await MediaProbe.probe(movie, id: "sq")]
    try project.addClip(Clip(id: "c1", kind: .media, mediaId: "sq", start: 0, duration: 0.9), trackId: "V1", mode: .place)
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: project)
    let samples = (0..<30).map { i in TrackSample(t: Double(i) / 30, box: NormRect(x: Double(60 + 3 * i) / 320, y: 70.0 / 180, width: 30.0 / 320, height: 30.0 / 180), confidence: 1) }
    try bundle.saveAnalysis([ObjectTrack(id: "trk1", mediaId: "sq", label: "square", samples: samples)], "sq", "tracks")

    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])
    let found = await box.call("catalog", ["search": "roto"])
    #expect(found.plainText.contains("mask.object"))

    let mask = await box.call("effect_add", ["target": "c1", "type": "mask.object", "params": ["track": "track:trk1"]])
    #expect(!mask.isError, "\(mask.plainText)")
    let masked = try #require(try bundle.loadProject().clip("c1")?.effects.first { $0.type == "mask.object" })
    #expect(masked.params["track"]?.string == "trk1")
    let boxes = ObjectTrack.decodeBoxes(masked.params["boxes"]?.string ?? "")
    #expect(boxes.count >= 2 && abs((ObjectTrack.box(boxes, at: 0.5)?.x ?? 0) - 105.0 / 320) < 0.005, "\(boxes)")

    // A box tracked on the spot, previewed without saving the track.
    let dry = await box.call("recipe", ["name": "remove_object", "args": ["clip": "c1", "box": ["x": .number(60.0 / 320), "y": .number(70.0 / 180), "width": .number(30.0 / 320), "height": .number(30.0 / 180)], "at": 0], "dry_run": true])
    #expect(dry.plainText.contains("Dry run") && dry.plainText.contains("removal1"), "\(dry.plainText)")
    #expect(bundle.analysis([ObjectTrack].self, "sq", "tracks")?.count == 1)

    let removed = await box.call("recipe", ["name": "remove_object", "args": ["clip": "c1", "track": "track:trk1", "padding": 0.03]])
    #expect(!removed.isError, "\(removed.plainText)")
    #expect(removed.plainText.contains("renders in the background"), "\(removed.plainText)")
    let p = try bundle.loadProject()
    let req = try #require(ProcessedPicture.requests(p).first)
    defer { try? FileManager.default.removeItem(at: req.url) }
    #expect(req.summary == "object removal")
    #expect(await box.session.jobs.wait(timeout: 300))
    #expect(ProcessedPicture.cached(req) != nil)
    #expect(box.session.jobs.all.contains { $0.features == [Session.pictureJob] && $0.status == "done" })
    let built = try await box.session.timeline(for: p)
    #expect(built.missingPictures.isEmpty)

    let matte = await box.call("timeline_frames", ["times": [0.5], "view": "matte", "clip": "c1", "effect": .string(masked.id)])
    #expect(!matte.isError, "\(matte.plainText)")
}
