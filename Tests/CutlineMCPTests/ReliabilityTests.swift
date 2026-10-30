import AVFoundation
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

private func scratch(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// `seconds` of 320×180 ProRes at `fps`, a gray ramp that brightens frame by frame.
private func rampMovie(_ url: URL, fps: Int32, seconds: Double) async throws {
    let w = 320, h = 180
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    let frames = Int(seconds * Double(fps))
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let v = UInt8(60 + (i * 120) / max(1, frames))
        for y in 0..<h { memset(base + y * rowBytes, Int32(v), w * 4) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

// MARK: Read paths build what export builds

@Test func pictureMeasureReadsWhenSoundOutlastsThePicture() async throws {
    let dir = try scratch("measure")
    defer { try? FileManager.default.removeItem(at: dir) }
    let movie = dir.appendingPathComponent("ramp.mov"), tone = dir.appendingPathComponent("tone.wav")
    try await rampMovie(movie, fps: 30, seconds: 2)
    try writeTone(tone)
    var project = Project(name: "Measure", canvas: Canvas(width: 320, height: 180, fps: 30))
    project.media = [try await MediaProbe.probe(movie, id: "ramp"), try await MediaProbe.probe(tone, id: "tone")]
    try project.addClip(Clip(id: "v", kind: .media, mediaId: "ramp", start: 0, duration: 1.5), trackId: "V1", mode: .place)
    // Room tone's last piece keeps half a crossfade of sound past the end of the picture.
    var sound = Clip(id: "s", kind: .media, mediaId: "tone", start: 0, duration: 1.5, sourceIn: 0.5)
    sound.audioLag = 0.125
    try project.addClip(sound, trackId: "A1", mode: .place)
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("m.cutline"), project: project)

    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])
    let built = try await box.session.timeline(for: try bundle.loadProject(), renderScale: 0.5)
    #expect(built.composition.duration.seconds > built.duration + 0.1, "the sound runs past the picture")
    let report = try await PictureMeter.measure(built)
    #expect(report.frames.count == 45)

    let measured = await box.call("timeline_measure", ["what": ["picture", "compare", "scopes", "text", "sound"]])
    #expect(!measured.isError, "\(measured.plainText)")
    #expect(measured.plainText.contains("Picture (45 frames)"), "\(measured.plainText)")
    let frames = await box.call("timeline_frames", ["times": [0.5, 1.4]])
    #expect(!frames.isError, "\(frames.plainText)")
    let ranged = await box.call("timeline_measure", ["what": ["picture"], "start": 1, "end": 5])
    #expect(ranged.plainText.contains("Picture (15 frames)"), "\(ranged.plainText)")
}

// MARK: Canvas follows the footage

@Test func firstImportSetsTheCanvasAndLaterOnesWarn() async throws {
    let dir = try scratch("canvas")
    defer { try? FileManager.default.removeItem(at: dir) }
    let film = dir.appendingPathComponent("film.mov"), pal = dir.appendingPathComponent("pal.mov")
    try await rampMovie(film, fps: 24, seconds: 1)
    try await rampMovie(pal, fps: 25, seconds: 1)

    let box = Toolbox()
    _ = await box.call("project_create", ["path": .string(dir.appendingPathComponent("a.cutline").path), "open_preview": false])
    let first = await box.call("media_import", ["paths": [.string(film.path)], "analyze": false])
    #expect(first.plainText.contains("Canvas set to film's 320×180 @24fps"), "\(first.plainText)")
    var p = try box.session.project()
    #expect(p.canvas.width == 320 && p.canvas.fps == 24 && p.canvasSet == true)
    let second = await box.call("media_import", ["paths": [.string(pal.path)], "analyze": false])
    #expect(second.plainText.contains("judder") && second.plainText.contains("canvas_set fps:25"), "\(second.plainText)")
    p = try box.session.project()
    #expect(p.canvas.fps == 24)

    // A canvas chosen at create time stays.
    _ = await box.call("project_create", ["path": .string(dir.appendingPathComponent("b.cutline").path), "open_preview": false, "preset": "vertical", "fps": 30])
    let kept = await box.call("media_import", ["paths": [.string(film.path)], "analyze": false])
    #expect(kept.plainText.contains("judder") && !kept.plainText.contains("Canvas set"), "\(kept.plainText)")
    p = try box.session.project()
    #expect(p.canvas.width == 1080 && p.canvas.height == 1920 && p.canvas.fps == 30)
}

// MARK: Sound edits on the frame grid

@Test func soundEditsReportTheirFrameSnap() async throws {
    let dir = try scratch("grid")
    defer { try? FileManager.default.removeItem(at: dir) }
    let tone = dir.appendingPathComponent("tone.wav")
    try writeTone(tone)
    var project = Project(name: "Grid", canvas: Canvas(fps: 24))
    project.media = [try await MediaProbe.probe(tone, id: "tone")]
    try project.addClip(Clip(id: "a", kind: .media, mediaId: "tone", start: 0, duration: 1.5, sourceIn: 0), trackId: "A1", mode: .place)
    try project.addClip(Clip(id: "b", kind: .media, mediaId: "tone", start: 1.5, duration: 1.5, sourceIn: 1.5), trackId: "A1", mode: .place)
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("g.cutline"), project: project)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])

    let j = await box.call("recipe", ["name": "split_edit", "args": ["edit": "a|b", "offset": 0.6]])
    #expect(!j.isError && j.plainText.contains("14 frames"), "\(j.plainText)")
    #expect(abs((try bundle.loadProject().clip("b")?.audioLead ?? 0) - 14.0 / 24) < 1e-9)

    let fade = await box.call("param_set", ["target": "b", "set": ["audio.fade_out": 0.3]])
    #expect(fade.plainText.contains("snapped"), "\(fade.plainText)")
    #expect(abs((try bundle.loadProject().clip("b")?.audioFadeOut ?? 0) - 7.0 / 24) < 1e-9)
    _ = await box.call("param_set", ["target": "b", "set": ["audio.fade_out": 0.3], "subframe": true])
    #expect(try bundle.loadProject().clip("b")?.audioFadeOut == 0.3)

    let trim = await box.call("trim", ["clip_id": "b", "edge": "end", "part": "audio", "by": -0.11])
    #expect(trim.plainText.contains("3 frames"), "\(trim.plainText)")
}

// MARK: Recipes say what analysis they lack

@Test func recipesWarnAboutMissingOrRunningAnalysis() async throws {
    let dir = try scratch("ready")
    defer { try? FileManager.default.removeItem(at: dir) }
    let movie = dir.appendingPathComponent("cam.mov")
    try await rampMovie(movie, fps: 30, seconds: 2)
    var project = Project(name: "Ready", canvas: Canvas(width: 320, height: 180, fps: 30))
    project.media = [try await MediaProbe.probe(movie, id: "cam")]
    try project.addClip(Clip(id: "c1", kind: .media, mediaId: "cam", start: 0, duration: 1), trackId: "V1", mode: .place)
    try project.addClip(Clip(id: "c2", kind: .media, mediaId: "cam", start: 1, duration: 1, sourceIn: 1), trackId: "V1", mode: .place)
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("r.cutline"), project: project)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])

    let never = await box.call("recipe", ["name": "punch_in", "args": ["clips": ["c2"]], "dry_run": true])
    #expect(!never.isError && never.plainText.contains("cam has no shots analysis") && never.plainText.contains("centered on the frame"), "\(never.plainText)")

    // A shots job another runner holds: the recipe waits as long as asked, then says it's still running.
    let held = try #require(FileLock(bundle.url.appendingPathComponent(".worker.lock"), wait: false))
    defer { held.release() }
    let job = box.session.jobs.enqueue("cam", [.shots], bundle: bundle.url)
    let began = Date()
    let running = await box.call("recipe", ["name": "reframe", "args": ["aspect": "9:16"], "dry_run": true, "wait": 1])
    #expect(Date().timeIntervalSince(began) >= 1)
    #expect(running.plainText.contains("shots analysis of cam is still running (\(job)") && running.plainText.contains("instead of following faces"), "\(running.plainText)")

    let needs = box.recipeNeeds("multicam_switch", Args(["angles": ["cam", "cam"]]), try bundle.loadProject())
    #expect(needs.contains { $0.feature == .shots && $0.without.contains("S1 to the first angle") })
    #expect(needs.contains { $0.feature == .transcript })
}
