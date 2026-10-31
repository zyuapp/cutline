import AVFoundation
import CoreGraphics
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// Two seconds at 25 fps, 320×180: `rgb` with a gentle left-to-right ramp so the picture has a spread of tones.
private func writeFlat(_ url: URL, _ rgb: (Int, Int, Int)) async throws {
    let w = 320, h = 180
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<50 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!, row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<h {
            let line = (base + y * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let ramp = x * 30 / w
                line[x * 4] = UInt8(min(255, rgb.2 + ramp))
                line[x * 4 + 1] = UInt8(min(255, rgb.1 + ramp))
                line[x * 4 + 2] = UInt8(min(255, rgb.0 + ramp))
                line[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 25)))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

private func tempDir(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The number after `key` on the line containing `marker`.
private func number(after key: String, on marker: String, in text: String) -> Double? {
    guard let line = text.components(separatedBy: "\n").first(where: { $0.contains(marker) }), let r = line.range(of: key) else { return nil }
    return Double(line[r.upperBound...].prefix { "0123456789.-".contains($0) })
}

@Test func matchColorReadsLogFootageTheWayCompareDoes() async throws {
    let dir = try tempDir("logmatch")
    defer { try? FileManager.default.removeItem(at: dir) }
    // S-Log3 code values around mid gray read bright when undecoded; decoded they are darker.
    try await writeFlat(dir.appendingPathComponent("slog.mov"), (105, 110, 100))
    try await writeFlat(dir.appendingPathComponent("rec.mov"), (150, 140, 120))
    var p = Project(name: "Log", canvas: Canvas(width: 320, height: 180, fps: 25))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("slog.mov"), id: "slog"), try await MediaProbe.probe(dir.appendingPathComponent("rec.mov"), id: "rec")]
    p.tracks[0].clips = [Clip(id: "a", kind: .media, mediaId: "slog", start: 0, duration: 2), Clip(id: "b", kind: .media, mediaId: "rec", start: 2, duration: 2)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    let log = await box.call("media_organize", ["media_ids": ["slog"], "log": "slog3"])
    #expect(!log.isError, "\(log.plainText)")

    let before = await box.call("timeline_measure", ["what": ["compare"], "reference": "a"])
    let refL = try #require(number(after: ": L ", on: " a: L", in: before.plainText), "\(before.plainText)")
    let gapBefore = try #require(number(after: "ΔE ", on: " b: L", in: before.plainText), "\(before.plainText)")

    let m = await box.call("recipe", ["name": "match_color", "args": ["clips": ["b"], "reference": "start", "strength": 1, "allow_large": true]])
    #expect(!m.isError && m.plainText.contains("Matched to a"), "\(m.plainText)")
    let measured = try #require(number(after: "(reference ", on: "b: median L", in: m.plainText), "\(m.plainText)")
    #expect(abs(measured - refL) < 3, "match_color reads the reference at L \(measured), compare at \(refL)")

    let after = await box.call("timeline_measure", ["what": ["compare"], "reference": "a"])
    let gapAfter = try #require(number(after: "ΔE ", on: " b: L", in: after.plainText), "\(after.plainText)")
    #expect(gapAfter < gapBefore / 2, "ΔE \(gapBefore) → \(gapAfter)\n\(after.plainText)")
}

@Test func matchColorReferenceTakesATime() async throws {
    let dir = try tempDir("refat")
    defer { try? FileManager.default.removeItem(at: dir) }
    try await writeFlat(dir.appendingPathComponent("x.mov"), (60, 80, 120))
    try await writeFlat(dir.appendingPathComponent("y.mov"), (150, 120, 90))
    var p = Project(name: "Ref", canvas: Canvas(width: 320, height: 180, fps: 25))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("x.mov"), id: "x"), try await MediaProbe.probe(dir.appendingPathComponent("y.mov"), id: "y")]
    p.tracks[0].clips = [Clip(id: "a", kind: .media, mediaId: "x", start: 0, duration: 2), Clip(id: "b", kind: .media, mediaId: "y", start: 2, duration: 2)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    let end = await box.call("recipe", ["name": "match_color", "args": ["reference": "end"], "dry_run": true])
    #expect(!end.isError && end.plainText.contains("Matched to b (the clip at 3.99s)"), "\(end.plainText)")
    let num = await box.call("recipe", ["name": "match_color", "args": ["reference": 1], "dry_run": true])
    #expect(!num.isError && num.plainText.contains("Matched to a (the clip at 1.00s)"), "\(num.plainText)")
    let bad = await box.call("recipe", ["name": "match_color", "args": ["reference": "nope"]])
    #expect(bad.isError && bad.plainText.contains("No clip nope; reference is a media clip id or a timeline time"), "\(bad.plainText)")
}

/// Ten seconds of white noise, mono.
private func writeNoise(_ url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000)!
    buffer.frameLength = 480_000
    var g = SystemRandomNumberGenerator()
    for i in 0..<480_000 { buffer.floatChannelData![0][i] = Float.random(in: -0.2...0.2, using: &g) }
    try file.write(from: buffer)
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: "/tmp/cl-real/work/camL.mov") && FileManager.default.fileExists(atPath: "/tmp/cl-real/work/camR.mov")))
func multicamLeavesOutAnglesItCannotSync() async throws {
    let dir = try tempDir("mcweak")
    defer { try? FileManager.default.removeItem(at: dir) }
    try writeNoise(dir.appendingPathComponent("noise.wav"))
    let box = Toolbox()
    _ = await box.call("project_create", ["path": .string(dir.appendingPathComponent("mc").path), "open_preview": false])
    _ = await box.call("media_import", ["paths": ["/tmp/cl-real/work/camL.mov", "/tmp/cl-real/work/camR.mov", .string(dir.appendingPathComponent("noise.wav").path)], "analyze": false])
    let ids = try box.session.project().media.map(\.id)
    let cams = ids.filter { try! box.session.project().mediaAsset($0)!.hasVideo }, noise = try #require(ids.first { $0.contains("noise") })
    let made = await box.call("multicam_create", .object(["angles": .array(cams.map { .string($0) }), "audio": [.string(noise)], "dry_run": true]))
    #expect(!made.isError && made.plainText.contains("left out \(noise) (confidence") && made.plainText.contains("sync:\"timecode\""), "\(made.plainText)")
    #expect(!made.plainText.contains("\(noise): "), "the noise isn't an angle: \(made.plainText)")
    let forced = await box.call("multicam_create", .object(["angles": .array(cams.map { .string($0) }), "audio": [.string(noise)], "force": true]))
    #expect(!forced.isError && forced.plainText.contains("kept \(noise)"), "\(forced.plainText)")
    let clip = try #require(try box.session.project().tracks[0].clips.first)
    #expect(try box.session.project().multicamSetup(clip)?.angles.count == 3)
    let alone = await box.call("multicam_create", .object(["angles": .array([.string(cams[0])]), "audio": [.string(noise)]]))
    #expect(alone.isError && alone.plainText.contains("Sound sync failed"), "\(alone.plainText)")
}

@Test func agentPaperCutsLand() async throws {
    let dir = try tempDir("papercuts")
    defer { try? FileManager.default.removeItem(at: dir) }
    try await writeFlat(dir.appendingPathComponent("x.mov"), (60, 80, 120))
    var p = Project(name: "Cuts", canvas: Canvas(width: 320, height: 180, fps: 25))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("x.mov"), id: "x")]
    p.tracks[0].clips = [Clip(id: "a", kind: .media, mediaId: "x", start: 0, duration: 2), Clip(id: "b", kind: .media, mediaId: "x", start: 2, duration: 2)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    try? FileManager.default.removeItem(at: b.url.appendingPathComponent("preview.json"))

    let state = await box.call("preview_state", [:])
    #expect(state.plainText.contains("preview_seek open:true") && !state.plainText.contains("preview_open"), "\(state.plainText)")

    let assembled = await box.call("assemble", ["segments": [["media": "x", "from": 0.2, "to": 1.0]], "track": "V1", "dry_run": true])
    #expect(!assembled.isError && assembled.plainText.contains("Dry run"), "\(assembled.plainText)")

    let title = await box.call("text_add", ["text": "Hi", "start": 0, "duration": 1, "animate": "fade_in"])
    #expect(!title.isError, "\(title.plainText)")
    let words = await box.call("text_add", ["text": "Hello there", "start": 1, "duration": 1, "animate": "wave"])
    #expect(!words.isError, "\(words.plainText)")
    let texts = try box.session.project().tracks.flatMap(\.clips).filter { $0.kind == .text }
    #expect(texts.first { $0.text?.text == "Hi" }?.text?.animationIn == .fade)
    #expect(texts.first { $0.text?.text == "Hello there" }?.text?.animator?.preset == .wave)
    let wrong = await box.call("text_add", ["text": "x", "animate": "zoomy"])
    #expect(wrong.isError && wrong.plainText.contains("animator"), "\(wrong.plainText)")

    let rev = await box.call("clip_update", ["clip_id": "b", "reverse": true])
    #expect(!rev.isError && rev.plainText.contains("reversed (plays backwards)"), "\(rev.plainText)")
    #expect(try box.session.project().clip("b")?.reverse == true)
    _ = await box.call("param_set", ["target": "a", "animate": ["time.speed": [["t": 0, "v": 1], ["t": 1, "v": 0.5]]]])
    let status = await box.call("project_status", [:])
    #expect(status.plainText.contains("reversed (plays backwards)") && status.plainText.contains("retimed: speed ramp"), "\(status.plainText)")

    let tr = await box.call("transition_set", ["between": ["a", "b"], "dry_run": true])
    #expect(!tr.plainText.contains("doesn't take"), "\(tr.plainText)")
    let tr2 = await box.call("transition_set", ["between": "a|b", "dry_run": true])
    #expect(!tr2.plainText.contains("doesn't take"), "\(tr2.plainText)")

    let caps = await box.call("captions_set", ["style": "subtitle"])
    #expect(!caps.isError, "\(caps.plainText)")
    #expect(try box.session.project().captions.style.background != nil, "subtitle → the clean preset's box")

    // view matte finds the one clip with a masked effect.
    let none = await box.call("timeline_frames", ["view": "matte", "times": [1]])
    #expect(none.isError && none.plainText.contains("no clip with a masked effect"), "\(none.plainText)")
    _ = await box.call("effect_add", ["target": "a", "type": "color.wheels", "id": "spot", "params": ["limit": "ellipse"]])
    let found = await box.call("timeline_frames", ["view": "matte", "times": [1]])
    #expect(!found.isError && found.plainText.contains("Matte of spot (color.wheels) on a"), "\(found.plainText)")
    _ = await box.call("effect_add", ["target": "b", "type": "color.wheels", "id": "spot2", "params": ["limit": "ellipse"]])
    let two = await box.call("timeline_frames", ["view": "matte"])
    #expect(two.isError && two.plainText.contains("several clips") && two.plainText.contains("a, b"), "\(two.plainText)")
    let at = await box.call("timeline_frames", ["view": "matte", "times": [3]])
    #expect(!at.isError && at.plainText.contains("on b"), "\(at.plainText)")

    // Switching timelines reads as a switch, not a list of every clip.
    let made = await box.call("timelines", ["action": "new", "name": "Short"])
    #expect(made.plainText.contains("new timeline Short, now current (Main kept)") && !made.plainText.contains("- a from"), "\(made.plainText)")
    let back = await box.call("timelines", ["action": "switch", "name": "Main"])
    #expect(back.plainText.contains("switched to timeline Main (from Short)") && !back.plainText.contains("+ a on"), "\(back.plainText)")
}

private let film = "/tmp/cl-real/downloads/tears_of_steel_720p.mp4"

/// The person outline finds a head where face detection does: the box overlaps the face.
@Test(.enabled(if: FileManager.default.fileExists(atPath: film)))
func personOutlineFindsTheHead() async throws {
    let media = try await MediaProbe.probe(URL(fileURLWithPath: film), id: "tos")
    var checked = 0
    for t in stride(from: 40.0, to: 200, by: 4) {
        guard let img = try await Frames.media(media, times: [t], maxSize: CGSize(width: 960, height: 960)).first?.image else { continue }
        let faces = ShotColor.faces(img)
        guard let face = faces.first, faces.count == 1, face.width > 0.1 else { continue }
        guard let head = ShotColor.personHead(img) else { continue }
        checked += 1
        let overlap = head.intersection(face)
        #expect(!overlap.isNull && overlap.width * overlap.height > 0.3 * face.width * face.height, "at \(t)s head \(head) face \(face)")
        if checked == 3 { break }
    }
    #expect(checked > 0, "no frame with one face and a person outline")
}
