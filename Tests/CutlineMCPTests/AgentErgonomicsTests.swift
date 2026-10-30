import AVFoundation
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

private func resolved(_ box: Toolbox, _ tool: String, _ args: JSON) throws -> JSON {
    let schema = try #require(box.tools[tool]?.schema)
    let out = try #require(try box.resolvingAliases(tool, args, schema: schema))
    try box.checkArguments(tool, out, schema: schema)
    return out
}

private func refusal(_ box: Toolbox, _ tool: String, _ args: JSON) -> String {
    do { _ = try resolved(box, tool, args); return "" } catch { return error.localizedDescription }
}

@Test func enumValuesAreCheckedAndListed() throws {
    let box = Toolbox()
    #expect(try resolved(box, "timeline_frames", ["view": "before_after"])["view"] == "compare")
    let view = refusal(box, "timeline_frames", ["view": "side_by_sid"])
    #expect(view.contains("Invalid value 'side_by_sid' for 'view'") && view.contains("Valid: picture, matte, compare"), "\(view)")
    #expect(try resolved(box, "text_add", ["animation_in": "fade_up", "animation_out": "slide_up"])["animation_in"] == "slideUp")
    #expect(try resolved(box, "text_add", ["animation_in": "rise"])["animation_in"] == "slideUp")
    let anim = refusal(box, "text_add", ["animation_in": "fade_in_up_x"])
    #expect(anim.contains("for 'animation_in'") && anim.contains("Valid: none, fade, pop, slideUp, typewriter"), "\(anim)")
    let typo = refusal(box, "transition_set", ["cut": "a|b", "type": "disolve"])
    #expect(typo.contains("did you mean dissolve?"), "\(typo)")
    #expect(try resolved(box, "transition_set", ["cut": "a|b", "ease": "ease_in_out"])["ease"] == "easeInOut")
    #expect(try resolved(box, "audio_bus", ["bus": "FX", "layout": "5.1"])["layout"] == "surround51")
    let batch = refusal(box, "batch", ["operations": [["tool": "text_add", "args": ["text": "x", "animation_in": "zoomy"]]]])
    #expect(batch.contains("operations[0] (text_add): Invalid value 'zoomy'"), "\(batch)")
    let nested = refusal(box, "markers", ["add": [["time": 1, "label": "x", "kind": "chaptr"]]])
    #expect(nested.contains("for 'add[0].kind' (did you mean chapter?)"), "\(nested)")
    #expect(Toolbox.recipeArgumentProblems("beat_cut", ["align": "first_bet"]).contains { $0.contains("did you mean first_beat?") })
    let pip = try box.resolvingAliases("recipe", ["name": "pip", "args": ["clip": "c", "corner": "Top-Left"]], schema: box.tools["recipe"]!.schema)
    #expect(pip?["args"]?["corner"] == "top_left" && Toolbox.recipeArgumentProblems("pip", pip?["args"]).isEmpty)
    let mode = #expect(throws: EditError.self) { try Args(["mode": "rippel"]).enumValue("mode", TrimMode.self) }
    #expect(mode?.message.contains("did you mean ripple?") == true && mode?.message.contains("Valid: ") == true, "\(String(describing: mode))")
    #expect(try Args(["mode": "Ripple"]).enumValue("mode", TrimMode.self) == .ripple)
}

@Test func argumentNamesAgentsTriedLand() throws {
    let box = Toolbox()
    #expect(try resolved(box, "transition_set", ["edit": "a|b"])["cut"] == "a|b")
    let range = try resolved(box, "range_delete", ["from": 1, "to": 2])
    #expect(range["start"] == 1 && range["end"] == 2)
    #expect(try resolved(box, "multicam_create", ["media_ids": ["a", "b"]])["angles"] == ["a", "b"])
    #expect(try resolved(box, "canvas_set", ["layout": "5.1"])["audio_layout"] == "5.1")
    func recipe(_ name: String, _ args: JSON) throws -> JSON? {
        let out = try box.resolvingAliases("recipe", ["name": .string(name), "args": args], schema: box.tools["recipe"]!.schema)
        let problems = Toolbox.recipeArgumentProblems(name, out?["args"])
        #expect(problems.isEmpty, "recipe \(name): \(problems)")
        return out?["args"]
    }
    let loud = try recipe("loudness_normalize", ["target": -16, "true_peak": -1])
    #expect(loud?["target_lufs"] == -16 && loud?["ceiling_db"] == -1)
    #expect(try recipe("beat_cut", ["music": "song", "media": ["a"]])?["music"] == "song")
    #expect(try recipe("split_edit", ["cut": "a|b", "offset": 0.5])?["edit"] == "a|b")
    let add = try resolved(box, "markers", ["action": "add", "at": 2, "label": "Intro"])
    #expect(add["add"] == [["time": 2, "label": "Intro"]], "\(add.encoded())")
    #expect(try resolved(box, "markers", ["action": "delete", "label": "Intro"])["remove"] == ["Intro"])
    #expect(try resolved(box, "markers", ["id": "Intro", "kind": "done"])["update"] == [["id": "Intro", "kind": "done"]])
    #expect(try resolved(box, "markers", ["add": ["time": 1, "label": "One"]])["add"] == [["time": 1, "label": "One"]])
    let bad = refusal(box, "markers", ["action": "lst"])
    #expect(bad.contains("Valid: add, update, remove, remove_all"), "\(bad)")
}

@Test func faceSearchPrefersTimesWithTheLargestFaces() {
    let c = Clip(id: "c", kind: .media, mediaId: "m", start: 10, duration: 10, sourceIn: 5)
    let small = FaceTrack(id: 0, samples: (0..<20).map { FaceSample(t: 5 + Double($0) * 0.5, box: NormRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)) })
    let big = FaceTrack(id: 1, samples: [FaceSample(t: 12, box: NormRect(x: 0.5, y: 0.2, width: 0.3, height: 0.4)), FaceSample(t: 30, box: NormRect(x: 0.5, y: 0.2, width: 0.5, height: 0.5))])
    let times = Toolbox.faceSearchTimes([small, big], clip: c, range: TimeRange(10, 20), n: 0)
    #expect(times.first == 17, "source 12 plays at 17: \(times)")
    #expect(!times.contains { $0 < 10 || $0 >= 20 })
    #expect(Toolbox.faceSearchTimes([small, big], clip: c, range: TimeRange(10, 20), n: 1) == [17], "two faces at once only at source 12")
    #expect(Toolbox.faceSearchTimes([small], clip: c, range: TimeRange(10, 20), n: 1).isEmpty)
}

/// Seconds of a flat-colored 160×90 movie.
private func writeFlatMovie(_ url: URL, seconds: Int = 2) async throws {
    let w = 160, h = 90
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<(seconds * 30) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for k in 0..<(CVPixelBufferGetBytesPerRow(buffer) * h / 4) { base[k * 4] = 160; base[k * 4 + 1] = 120; base[k * 4 + 2] = 90; base[k * 4 + 3] = 255 }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// Ten seconds of dialogue: a loud tone where `speech` says, a faint steady hiss elsewhere.
private let speech = [TimeRange(0, 3), TimeRange(7, 8.5)]
private func writeDialogue(_ url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let n = 480_000
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
    buffer.frameLength = AVAudioFrameCount(n)
    var seed: UInt32 = 1
    for i in 0..<n {
        let t = Double(i) / 48_000
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let hiss = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.006
        buffer.floatChannelData![0][i] = speech.contains { $0.start <= t && t < $0.end } ? 0.3 * sin(Float(t) * 2 * .pi * 220) : hiss
    }
    try file.write(from: buffer)
}

private func openProject() async throws -> (Toolbox, ProjectBundle, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-ergo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writePNG(dir.appendingPathComponent("img.png"))
    try writeDialogue(dir.appendingPathComponent("talk.wav"))
    try await writeFlatMovie(dir.appendingPathComponent("flat.mov"))
    var p = Project(name: "Ergo", canvas: Canvas(width: 320, height: 180, fps: 25))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("img.png"), id: "img"), try await MediaProbe.probe(dir.appendingPathComponent("talk.wav"), id: "talk"), try await MediaProbe.probe(dir.appendingPathComponent("flat.mov"), id: "flat")]
    p.tracks[0].clips = [Clip(id: "pic", kind: .media, mediaId: "img", start: 0, duration: 4), Clip(id: "mov", kind: .media, mediaId: "flat", start: 4, duration: 2)]
    p.tracks[1].clips = [Clip(id: "d1", kind: .media, mediaId: "talk", start: 0, duration: 3), Clip(id: "d2", kind: .media, mediaId: "talk", start: 4, duration: 1.5, sourceIn: 7)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    try b.saveTranscript(Transcript(mediaId: "talk", locale: "en-US", words: [
        Word(text: "Hello", start: 0.2, end: 1.2), Word(text: "there.", start: 1.4, end: 2.8), Word(text: "Again.", start: 7.1, end: 8.3),
    ]))
    try b.saveAudioAnalysis(try await AudioAnalyzer.analyze(media: p.media[1]))
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, b, dir)
}

@Test func reviewerCallsWorkEndToEnd() async throws {
    let (box, b, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }

    let marker = await box.call("markers", ["action": "add", "at": 1, "label": "Intro"])
    #expect(try !marker.isError && box.session.project().markers.map(\.label) == ["Intro"], "\(marker.plainText)")

    let layout = await box.call("canvas_set", ["audio_layout": "5.1"])
    #expect(try !layout.isError && box.session.project().master.layout == .surround51, "\(layout.plainText)")
    let badLayout = await box.call("canvas_set", ["audio_layout": "quad"])
    #expect(badLayout.isError && badLayout.plainText.contains("Valid: stereo, mono, surround51, surround71"), "\(badLayout.plainText)")

    let noBus = await box.call("effect_add", ["target": "bus:dialogue", "type": "audio.compressor"])
    #expect(noBus.isError && noBus.plainText.contains("audio_bus bus:\"DIA\""), "\(noBus.plainText)")
    #expect(!(await box.call("audio_bus", ["bus": "DIA", "name": "Dialogue", "tracks": ["A1"]])).isError)
    let onBus = await box.call("effect_add", ["target": "bus:dialogue", "type": "audio.compressor"])
    #expect(try !onBus.isError && box.session.project().bus("DIA")?.effects.map(\.type) == ["audio.compressor"], "\(onBus.plainText)")
    let busParam = await box.call("param_set", ["target": "bus:DIA", "set": ["volume": 0.5]])
    #expect(busParam.isError && busParam.plainText.contains("audio_bus"), "\(busParam.plainText)")

    let what = await box.call("timeline_measure", ["what": ["sond"]])
    #expect(what.isError && what.plainText.contains("did you mean sound?"), "\(what.plainText)")

    // view compare: the vignette off and on, and an earlier version beside the current edit.
    let before = try #require(b.loadHistory().current?.id)
    #expect(!(await box.call("effect_add", ["target": "pic", "type": "stylize.vignette", "params": ["amount": 1.5]])).isError)
    let compare = await box.call("timeline_frames", ["view": "before_after", "clip": "pic", "effect": "vignette1", "count": 2])
    #expect(!compare.isError && compare.plainText.contains("Left: vignette1 off; right: now.") && compare.plainText.contains("changed"), "\(compare.plainText)")
    #expect(compare.content.contains { $0["type"]?.string == "image" })
    let version = await box.call("timeline_frames", ["view": "compare", "version": .string(before), "times": [1]])
    #expect(!version.isError && version.plainText.contains("version \(before)") && version.plainText.contains("changed"), "\(version.plainText)")
    let lost = await box.call("timeline_frames", ["view": "compare"])
    #expect(lost.isError && lost.plainText.contains("needs effect"), "\(lost.plainText)")
    let ignored = await box.call("timeline_frames", ["view": "beforeafter2"])
    #expect(ignored.isError && ignored.plainText.contains("Valid: picture, matte, compare"), "\(ignored.plainText)")

    // room_tone and fill_gaps find the quiet stretch themselves.
    let tone = await box.call("recipe", ["name": "room_tone", "args": ["start": 6, "end": 9]])
    #expect(!tone.isError && tone.plainText.contains("Room tone picked from talk (the dialogue clip d2 nearest the range)"), "\(tone.plainText)")
    var p = try box.session.project()
    let pieces = p.tracks.first { $0.name == "Room tone" }?.clips ?? []
    #expect(!pieces.isEmpty && pieces.allSatisfy { $0.sourceIn >= 3 - 1e-6 && $0.sourceIn < 7 }, "\(pieces.map(\.sourceIn))")
    let gaps = await box.call("recipe", ["name": "fill_gaps", "args": ["track": "A1"]])
    #expect(!gaps.isError && gaps.plainText.contains("the media most heard on A1") && gaps.plainText.contains("3.00–4.00s"), "\(gaps.plainText)")
    let half = await box.call("recipe", ["name": "room_tone", "args": ["start": 6, "end": 9, "source_start": 3]])
    #expect(half.isError && half.plainText.contains("both source_start and source_end"), "\(half.plainText)")

    // qualify face:true looks across the clip before giving up.
    let face = await box.call("recipe", ["name": "qualify", "args": ["clip": "mov", "face": true]])
    #expect(face.isError && face.plainText.contains("No face found in mov at 5.00s nor at 8 frames across 4.00–6.00s"), "\(face.plainText)")

    p = try box.session.project()
    #expect(try Toolbox.musicClips(["A1"], p).map(\.id) == ["d1", "d2"])
    #expect(throws: EditError.self) { try Toolbox.musicClips(["nope"], p) }
}

private let film = "/tmp/cl-real/downloads/tears_of_steel_720p.mp4"

/// qualify face:true at a time without a face samples where shot analysis saw one and says when.
@Test(.enabled(if: FileManager.default.fileExists(atPath: film)))
func faceQualifyFindsAFaceElsewhereInTheClip() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-face-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let excerpt = dir.appendingPathComponent("tos.mov")
    let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: URL(fileURLWithPath: film)), presetName: AVAssetExportPreset1280x720))
    session.timeRange = CMTimeRange(start: CMTime(seconds: 43, preferredTimescale: 600), duration: CMTime(seconds: 20, preferredTimescale: 600))
    try await session.export(to: excerpt, as: .mov)
    var p = Project(name: "TOS", canvas: Canvas(width: 1280, height: 720, fps: 24))
    let media = try await MediaProbe.probe(excerpt, id: "tos")
    p.media = [media]
    p.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "tos", start: 0, duration: 20)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let cuts = try await SceneDetector.detect(media)
    try b.saveVisualAnalysis(VisualAnalysis(mediaId: "tos", sceneCuts: cuts))
    try b.saveAnalysis(try await VisionAnalyzer.analyze(url: excerpt, mediaId: "tos", sceneCuts: cuts, duration: 20), "tos", "shots")
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    let faces = try #require(b.analysis(ShotAnalysis.self, "tos", "shots")).faces
    let seen = faces.flatMap(\.samples).map(\.t)
    let empty = try #require(stride(from: 0.5, to: 19.5, by: 0.25).first { t in !seen.contains { abs($0 - t) < 1.5 } }, "no faceless second")
    let q = await box.call("recipe", ["name": "qualify", "args": ["clip": "c", "face": true, "at": .number(empty), "scope": "clip"]])
    print("qualify at a faceless \(fmt2(empty))s: " + q.plainText.split(separator: "\n").prefix(2).joined(separator: " | "))
    #expect(!q.isError && q.plainText.contains("No face at \(fmt2(empty))s; sampled at") && q.plainText.contains("where shot analysis shows the largest face"), "\(q.plainText)")
}
