import AVFoundation
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

private func tempDir(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A song with quiet first five seconds and loud next five, a 430×360 angle whose speaker's face sits high in
/// the frame, and a landscape b-roll file; shots differ in aesthetics and motion.
private func beatProject(_ dir: URL) throws -> ProjectBundle {
    var p = Project(name: "Beat", canvas: Canvas(width: 1920, height: 1080, fps: 25))
    p.media = [
        MediaAsset(id: "song", path: "/tmp/song.m4a", name: "song", duration: 60, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
        MediaAsset(id: "a", path: "/tmp/a.mov", name: "a", duration: 20, width: 430, height: 360, fps: 25, hasVideo: true, hasAudio: false),
        MediaAsset(id: "b", path: "/tmp/b.mov", name: "b", duration: 20, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: false),
        MediaAsset(id: "c", path: "/tmp/missing-c.mov", name: "c", duration: 30, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: false),
    ]
    p.tracks[1].clips = [Clip(id: "music", kind: .media, mediaId: "song", start: 0, duration: 10)]
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let beats = stride(from: 0.0, to: 20, by: 0.5).map { $0 }
    try bundle.saveAnalysis(BeatAnalysis(mediaId: "song", tempo: 120, beats: beats, downbeats: stride(from: 0, to: beats.count, by: 4).map { beats[$0] }, onsets: beats, energy: beats.map { $0 < 5 ? 0.2 : 1 }), "song", "beats")
    func shots(_ id: String, _ specs: [(Double, Double)]) -> ShotAnalysis {
        ShotAnalysis(mediaId: id, shots: specs.enumerated().map { i, s in
            Shot(index: i, start: Double(i) * 4, end: Double(i + 1) * 4, size: id == "a" ? "medium" : "no people", people: id == "a" ? 1 : 0, aesthetics: s.0, brightness: 0.4, motion: s.1)
        }, faces: id == "a" ? [FaceTrack(id: 0, samples: stride(from: 0.0, to: 20, by: 0.5).map { FaceSample(t: $0, box: NormRect(x: 0.4, y: 0.08, width: 0.18, height: 0.22)) })] : [], samplesPerSecond: 2)
    }
    try bundle.saveAnalysis(shots("a", [(0.7, 0.05), (-0.8, 0.1), (0.5, 0.8), (0.6, 0.15), (0.3, 0.9)]), "a", "shots")
    try bundle.saveAnalysis(shots("b", [(0.6, 0.9), (0.65, 0.1), (-0.9, 0.5), (0.4, 0.85), (0.5, 0.2)]), "b", "shots")
    return bundle
}

@Test func beatCutPicksShotsByQualityAndEnergyAndFramesFaces() async throws {
    let dir = try tempDir("beatcut")
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try beatProject(dir)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])
    let r = await box.call("recipe", ["name": "beat_cut", "args": ["media": ["a", "b"], "start": 0, "end": 10, "every": 2]])
    #expect(!r.isError, "\(r.plainText)")
    #expect(r.plainText.contains("motion following the music") && r.plainText.contains("framed"), "\(r.plainText)")
    let p = try bundle.loadProject()
    let track = try #require(p.tracks.first { $0.name == "Beat cut" })
    let clips = track.clips
    #expect(clips.count == 9, "\(clips.count)")
    let analyses = ["a": try #require(bundle.analysis(ShotAnalysis.self, "a", "shots")), "b": try #require(bundle.analysis(ShotAnalysis.self, "b", "shots"))]
    func shot(_ c: Clip) -> Shot { analyses[c.mediaId!]!.shot(at: c.sourceIn + 0.01)! }
    // The poor shots (aesthetics -0.8, -0.9) are never used while better ones remain.
    #expect(!clips.contains { (shot($0).aesthetics ?? 0) < 0 }, "\(clips.map { "\($0.mediaId!)@\($0.sourceIn)" })")
    // Loud music gets busier shots than quiet music.
    let quiet = clips.filter { $0.start < 5 }.map { shot($0).motion }, loud = clips.filter { $0.start >= 5 }.map { shot($0).motion }
    let mean = { (v: [Double]) in v.reduce(0, +) / Double(max(v.count, 1)) }
    print("beat_cut motion: quiet \(mean(quiet)), loud \(mean(loud)); media \(clips.map { $0.mediaId! }.joined(separator: " "))")
    #expect(mean(loud) > mean(quiet) + 0.3)
    // No moment twice, and both sources used.
    for id in ["a", "b"] {
        let spans = clips.filter { $0.mediaId == id }.map { TimeRange($0.sourceIn, $0.sourceOut) }.sorted { $0.start < $1.start }
        for (x, y) in zip(spans, spans.dropFirst()) { #expect(x.end <= y.start + 1e-6, "\(id) repeats \(x) \(y)") }
        #expect(!spans.isEmpty)
    }
    // The 430×360 angle fills 16:9 with its face brought down into frame.
    let angle = try #require(clips.first { $0.mediaId == "a" })
    let ph = (16.0 / 9) / (430.0 / 360)
    let faceTop = 0.5 + angle.transform.y + (0.08 - 0.5) * ph
    #expect(angle.transform.y > 0.1 && faceTop > 0.02, "y \(angle.transform.y), face top \(faceTop)")
    #expect(clips.filter { $0.mediaId == "b" }.allSatisfy { $0.transform.y == 0 })

    // clip_add with fill frames the same way unless the position is given.
    let added = await box.call("clip_add", ["media_id": "a", "track": "new", "start": 0, "duration": 2, "set": ["transform.fit": "fill"]])
    #expect(added.plainText.contains("framed to keep faces"), "\(added.plainText)")
    let placed = await box.call("clip_add", ["media_id": "a", "track": "new", "start": 0, "duration": 2, "set": ["transform.fit": "fill", "transform.y": 0]])
    #expect(!placed.plainText.contains("framed"), "\(placed.plainText)")
}

@Test func beatCutWithoutAnalysisSpreadsSourcesAndSaysHowItPicked() async throws {
    let dir = try tempDir("beatcut-raw")
    defer { try? FileManager.default.removeItem(at: dir) }
    let bundle = try beatProject(dir)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])
    let r = await box.call("recipe", ["name": "beat_cut", "args": ["sources": [["media": "zz", "start": 0, "end": 12]], "end": 6]])
    #expect(r.isError && r.plainText.contains("No media \"zz\""), "\(r.plainText)")
    let cut = await box.call("recipe", ["name": "beat_cut", "args": ["sources": [["media": "c", "start": 0, "end": 12]], "end": 6, "every": 2]])
    #expect(!cut.isError && cut.plainText.contains("No shot analysis for c"), "\(cut.plainText)")
    let clips = try #require(try bundle.loadProject().tracks.first { $0.name == "Beat cut" }).clips
    let starts = clips.map(\.sourceIn)
    // Windows across the whole span, not consecutive one-second chunks from its start.
    #expect((starts.max() ?? 0) - (starts.min() ?? 0) > 6, "\(starts)")
    for (x, y) in zip(clips, clips.dropFirst()) { #expect(abs(y.sourceIn - x.sourceOut) > 0.05, "\(starts)") }
}

/// One second of PQ ProRes: left half 100 cd/m² gray, right half 2000 cd/m².
private func writePQ(_ url: URL) async throws {
    let w = 128, h = 64
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: w, AVVideoHeightKey: h, AVVideoColorPropertiesKey: ColorManagement.writerColorProperties(.rec2020_pq)])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<24 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!, row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<h {
            let line = (base + y * row).assumingMemoryBound(to: Float16.self)
            for x in 0..<w {
                let v = Float16(Transfer.pqEncode(nits: x < w / 2 ? 100 : 2000))
                for k in 0..<3 { line[x * 4 + k] = v }
                line[x * 4 + 3] = 1
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        ColorManagement.tag(buffer, .rec2020_pq)
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 24)))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

@Test func anSDRVersionNeverReplacesTheHDRMaster() async throws {
    let dir = try tempDir("hdr-names")
    defer { try? FileManager.default.removeItem(at: dir) }
    let movie = dir.appendingPathComponent("pq.mov")
    try await writePQ(movie)
    var p = Project(name: "PQ", canvas: Canvas(width: 128, height: 64, fps: 24, colorSpace: .rec2020_pq))
    p.media = [try await MediaProbe.probe(movie, id: "m")]
    p.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "m", start: 0, duration: 1)]
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])

    let hdr = dir.appendingPathComponent("hdr.mov")
    let master = await box.call("export", ["path": .string(hdr.path), "preset": "prores_proxy"])
    #expect(!master.isError, "\(master.plainText)")
    let sdr = await box.call("export", ["path": .string(hdr.path), "preset": "prores_proxy", "sdr_from_hdr": true])
    #expect(!sdr.isError && sdr.plainText.contains("hdr-sdr.mov"), "\(sdr.plainText)")
    #expect(await HDRMetadata.isHDR(hdr) == true, "the HDR master is still there")
    #expect(await HDRMetadata.isHDR(dir.appendingPathComponent("hdr-sdr.mov")) == false)

    // An HDR render aimed at an existing SDR file keeps that file.
    let again = await box.call("export", ["path": .string(dir.appendingPathComponent("hdr-sdr.mov").path), "preset": "prores_proxy"])
    #expect(!again.isError && again.plainText.contains("hdr-sdr-2.mov") && again.plainText.contains("was kept"), "\(again.plainText)")
    #expect(await HDRMetadata.isHDR(dir.appendingPathComponent("hdr-sdr.mov")) == false)
}

@Test func hdrTimelinesMeasureInNitsAndDeliverAnSDRVersion() async throws {
    let dir = try tempDir("hdr-tools")
    defer { try? FileManager.default.removeItem(at: dir) }
    let movie = dir.appendingPathComponent("pq.mov")
    try await writePQ(movie)
    var p = Project(name: "PQ", canvas: Canvas(width: 128, height: 64, fps: 24, colorSpace: .rec2020_pq))
    p.media = [try await MediaProbe.probe(movie, id: "m")]
    p.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "m", start: 0, duration: 1)]
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])

    let scopes = await box.call("timeline_measure", ["what": ["scopes"], "at": 0.5])
    #expect(scopes.plainText.contains("Light (cd/m²): peak 19") || scopes.plainText.contains("Light (cd/m²): peak 20"), "\(scopes.plainText)")
    let picture = await box.call("timeline_measure", ["what": ["picture"]])
    #expect(picture.plainText.contains("MaxCLL") && picture.plainText.contains("above a 1000 cd/m² mastering display"), "\(picture.plainText)")

    let peak = await box.call("canvas_set", ["master_peak_nits": 1000])
    #expect(peak.plainText.contains("roll off"), "\(peak.plainText)")
    let rolled = await box.call("timeline_measure", ["what": ["picture"]])
    #expect(rolled.plainText.contains("master peak of 1000"), "\(rolled.plainText)")
    let maxCLL = rolled.plainText.components(separatedBy: "MaxCLL ").dropFirst().first.flatMap { Int($0.prefix { $0.isNumber }) } ?? 0
    print("MaxCLL after master_peak_nits 1000: \(maxCLL)")
    #expect(maxCLL <= 1000 && maxCLL > 900)

    let bad = await box.call("export", ["sdr_from_hdr": ["method": "aces"]])
    #expect(bad.isError && bad.plainText.contains("bt2390"), "\(bad.plainText)")
    let sdr = await box.call("export", ["sdr_from_hdr": true, "preset": "prores_proxy"])
    #expect(!sdr.isError && sdr.plainText.contains("SDR version") && sdr.plainText.contains("-sdr.mov"), "\(sdr.plainText)")
    #expect(!sdr.plainText.contains("HDR10:"), "\(sdr.plainText)")
}
