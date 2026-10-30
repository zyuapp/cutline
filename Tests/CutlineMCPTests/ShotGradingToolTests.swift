import AVFoundation
import CoreGraphics
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// Four seconds at 30 fps, 320×180, with a cut at 2 s: an orange square on blue at the left, then an orange square
/// on green at the right.
private func writeTwoShots(_ url: URL) async throws {
    let w = 320, h = 180
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<120 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!, row = CVPixelBufferGetBytesPerRow(buffer)
        let second = i >= 60
        let square = second ? 200..<280 : 40..<120
        for y in 0..<h {
            let line = (base + y * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let orange = square.contains(x) && (50..<130).contains(y)
                let (r, g, b): (UInt8, UInt8, UInt8) = orange ? (230, 140, 50) : second ? (40, 130, 60) : (70, 100, 160)
                line[x * 4] = b
                line[x * 4 + 1] = g
                line[x * 4 + 2] = r
                line[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

private func openShots() async throws -> (Toolbox, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-shots-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try await writeTwoShots(dir.appendingPathComponent("film.mov"))
    try writePNG(dir.appendingPathComponent("ref.png"))
    var p = Project(name: "Shots", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("film.mov"), id: "film"), try await MediaProbe.probe(dir.appendingPathComponent("ref.png"), id: "ref")]
    p.tracks[0].clips = [Clip(id: "a", kind: .media, mediaId: "film", start: 0, duration: 4), Clip(id: "r", kind: .media, mediaId: "ref", start: 4, duration: 2)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    try b.saveVisualAnalysis(VisualAnalysis(mediaId: "film", sceneCuts: [2]))
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, dir)
}

/// Percent of the frame white in each matte frame, in time order.
private func matteWhite(_ box: Toolbox, clip: String, effect: String, times: [Double]) async throws -> [Int] {
    let r = await box.call("timeline_frames", ["view": "matte", "clip": .string(clip), "effect": .string(effect), "times": .array(times.map { .number($0) })])
    #expect(!r.isError, "\(r.plainText)")
    return r.plainText.components(separatedBy: "\n").filter { $0.contains("% of the frame white") }.compactMap { line in
        line.components(separatedBy: "  ").dropFirst().first.flatMap { Int($0.components(separatedBy: "%").first ?? "") }
    }
}

@Test func qualifyKeysOnlyTheShotAtItsTime() async throws {
    let (box, dir) = try await openShots()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Keyed in the second shot, the matte stays black in the first even though it shows the same orange.
    let q = await box.call("recipe", ["name": "qualify", "args": ["clip": "a", "x": 0.75, "y": 0.5, "at": 3]])
    #expect(!q.isError && q.plainText.contains("only in shot 2/2") && q.plainText.contains("plays 2 shots"), "\(q.plainText)")
    let fx = try #require(try box.session.project().clip("a")?.effects.last)
    #expect(fx.sourceRange == TimeRange(2, 4), "\(String(describing: fx.sourceRange))")
    let shot = try await matteWhite(box, clip: "a", effect: fx.id, times: [1, 3])
    #expect(shot.count == 2 && shot[0] == 0 && shot[1] > 5, "matte per shot: \(shot)")

    // The same key over the whole clip catches the first shot's square too.
    let whole = await box.call("recipe", ["name": "qualify", "args": ["clip": "a", "x": 0.75, "y": 0.5, "at": 3, "scope": "clip"]])
    #expect(!whole.isError, "\(whole.plainText)")
    let wholeFx = try #require(try box.session.project().clip("a")?.effects.last)
    #expect(wholeFx.sourceRange == nil)
    let spread = try await matteWhite(box, clip: "a", effect: wholeFx.id, times: [1, 3])
    #expect(spread.count == 2 && spread[0] > 5, "a clip-wide key reaches the other shot: \(spread)")

    // each_shot samples every shot on its own.
    let each = await box.call("recipe", ["name": "qualify", "args": ["clip": "a", "x": 0.2, "y": 0.5, "scope": "each_shot"]])
    #expect(!each.isError && each.plainText.contains("shot 1/2") && each.plainText.contains("shot 2/2"), "\(each.plainText)")
    let ranged = try box.session.project().clip("a")!.effects.compactMap(\.sourceRange)
    #expect(ranged.filter { $0 == TimeRange(0, 2) }.count == 1 && ranged.filter { $0 == TimeRange(2, 4) }.count == 2, "\(ranged)")

    // effect_add takes a shot too, and project_status says where it acts.
    let added = await box.call("effect_add", ["target": "a", "type": "color.wheels", "id": "warm", "params": ["temperature": 20], "at": 1])
    #expect(!added.isError && added.plainText.contains("Acts only in shot 1/2"), "\(added.plainText)")
    let status = await box.call("project_status", ["target": "a"])
    #expect(status.plainText.contains("warm acts only in the shot at 0.00–2.00s"), "\(status.plainText)")
    let lifted = await box.call("effect_add", ["target": "a", "id": "warm", "scope": "clip"])
    let warm = try box.session.project().clip("a")?.effects.first { $0.id == "warm" }
    #expect(!lifted.isError && warm != nil && warm?.sourceRange == nil, "\(lifted.plainText)")
}

@Test func matchColorAndSplitWorkPerShot() async throws {
    let (box, dir) = try await openShots()
    defer { try? FileManager.default.removeItem(at: dir) }

    let m = await box.call("recipe", ["name": "match_color", "args": ["clips": ["a"], "reference": "r"]])
    #expect(!m.isError && m.plainText.contains("a shot 1/2") && m.plainText.contains("a shot 2/2"), "\(m.plainText)")
    let luts = try box.session.project().clip("a")!.effects.filter { $0.type == "color.lut" }
    #expect(luts.map(\.id).sorted() == ["match_s1", "match_s2"] && luts.compactMap(\.sourceRange).count == 2, "\(luts)")
    let again = await box.call("recipe", ["name": "match_color", "args": ["clips": ["a"], "reference": "r", "scope": "clip"]])
    #expect(!again.isError)
    #expect(try box.session.project().clip("a")!.effects.filter { $0.type == "color.lut" }.map(\.id) == ["match"], "rematching replaces the per-shot LUTs")

    let s = await box.call("recipe", ["name": "split_at_shots", "args": ["clips": ["a"]]])
    #expect(!s.isError && s.plainText.contains("a → a 0.00–2.00s"), "\(s.plainText)")
    let v1 = try box.session.project().tracks[0].clips
    #expect(v1.count == 3 && v1[1].start == 2 && v1[1].sourceIn == 2, "\(v1.map { ($0.id, $0.start) })")
    let missing = await box.call("recipe", ["name": "split_at_shots", "args": ["clips": ["r"]]])
    #expect(missing.plainText.contains("no moving picture"), "\(missing.plainText)")
}

/// Four seconds of tone with a transcript of long words, on a 9:16 canvas, with a wide title near the bottom.
private func openVertical() async throws -> (Toolbox, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-vertical-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writeTone(dir.appendingPathComponent("tone.caf"))
    var p = Project(name: "Vertical", canvas: Canvas(width: 360, height: 640, fps: 30))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("tone.caf"), id: "tone")]
    p.tracks[1].name = "Interview"
    p.tracks[1].clips = [Clip(id: "talk", kind: .media, mediaId: "tone", start: 0, duration: 3)]
    var title = Clip(id: "title", kind: .text, start: 0, duration: 3)
    title.text = TextSpec(text: "Subscribe for the whole story", size: 0.06, y: 0.9, maxWidth: 0.95)
    p.tracks[0].clips = [title]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    try b.saveTranscript(Transcript(mediaId: "tone", locale: "en-US", words: [
        Word(text: "Unbelievably", start: 0.1, end: 0.7), Word(text: "extraordinary", start: 0.7, end: 1.3), Word(text: "circumstances", start: 1.3, end: 2),
        Word(text: "everywhere", start: 2, end: 2.8),
    ]))
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, dir)
}

private func outside(_ text: String, _ prefix: String) -> [String] {
    text.components(separatedBy: "\n").filter { $0.contains(prefix) && $0.contains("outside") }
}

@Test func captionsAndTitlesKeepClearOfPlatformUI() async throws {
    let (box, dir) = try await openVertical()
    defer { try? FileManager.default.removeItem(at: dir) }

    let on = await box.call("captions_set", ["preset": "bold"])
    #expect(!on.isError && on.plainText.contains("kept inside the area clear of"), "\(on.plainText)")
    let measured = await box.call("timeline_measure", ["what": ["text"], "platform": "tiktok"])
    #expect(measured.plainText.contains("caption \"") && outside(measured.plainText, "caption").isEmpty, "\(measured.plainText)")
    #expect(outside(measured.plainText, "title").first?.contains("recipe safe_zone_fix {\"platform\": \"tiktok\"}") == true, "\(measured.plainText)")

    // Placed exactly as set, the bold captions poke into TikTok's buttons; export for TikTok pulls them back in.
    _ = await box.call("captions_set", ["platform": "none"])
    let loose = await box.call("timeline_measure", ["what": ["text"], "platform": "tiktok"])
    #expect(!outside(loose.plainText, "caption").isEmpty, "\(loose.plainText)")
    _ = await box.call("captions_set", ["platform": "youtube"])
    let check = await box.call("export", ["platform": "tiktok", "check_only": true])
    #expect(outside(check.plainText, "caption").isEmpty && check.plainText.contains("Captions kept inside TikTok's UI-free area"), "\(check.plainText)")

    let fix = await box.call("recipe", ["name": "safe_zone_fix", "args": ["platform": "tiktok"]])
    #expect(!fix.isError && fix.plainText.contains("title: moved"), "\(fix.plainText)")
    #expect(try box.session.project().captions.platform == "tiktok")
    let after = await box.call("timeline_measure", ["what": ["text"], "platform": "tiktok"])
    #expect(outside(after.plainText, "").isEmpty, "\(after.plainText)")
    let again = await box.call("recipe", ["name": "safe_zone_fix", "args": ["platform": "tiktok"]])
    #expect(again.plainText.contains("nothing to move"), "\(again.plainText)")
}

private let film = "/tmp/cl-real/downloads/tears_of_steel_720p.mp4"

/// A 20 s stretch of Tears of Steel (43–63 s) with several cuts: a face key made in one shot never keys another.
@Test(.enabled(if: FileManager.default.fileExists(atPath: film)))
func faceKeyOnRealFootageStaysInItsShot() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-tos-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let asset = AVURLAsset(url: URL(fileURLWithPath: film))
    let excerpt = dir.appendingPathComponent("tos.mov")
    let session = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720))
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
    #expect(cuts.count >= 4, "cuts \(cuts)")

    let shots = Shot.ranges(cuts: cuts, duration: 20)
    // The shot with a face nearest its middle: the bespectacled man at the lab bench, or another one Vision finds.
    let faces = try #require(b.analysis(ShotAnalysis.self, "tos", "shots")).faces
    let track = try #require(faces.max { $0.samples.count < $1.samples.count }, "no face tracks")
    let at = track.samples[track.samples.count / 2].t
    let q = await box.call("recipe", ["name": "qualify", "args": ["clip": "c", "face": true, "at": .number(at)]])
    #expect(!q.isError && q.plainText.contains("follows the face"), "\(q.plainText)")
    let fx = try #require(try box.session.project().clip("c")?.effects.last)
    let mine = try #require(shots.first { at >= $0.start && at < $0.end })
    #expect(fx.sourceRange == mine, "\(String(describing: fx.sourceRange)) vs \(mine)")
    let others = shots.filter { $0 != mine }.map { ($0.start + $0.end) / 2 }
    let white = try await matteWhite(box, clip: "c", effect: fx.id, times: others + [at])
    print("Tears of Steel 43–63 s: cuts \(cuts.map { fmt2($0) }), face key at \(fmt2(at))s, matte white % in the other shots then its own: \(white)")
    #expect(white.count == others.count + 1 && white.dropLast().allSatisfy { $0 == 0 } && white.last! > 0, "matte in other shots, then its own: \(white)")
}
