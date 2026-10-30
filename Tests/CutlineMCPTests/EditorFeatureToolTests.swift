import AVFoundation
import CoreGraphics
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

private func tempDir(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A PNG drawn with y down.
private func writeImage(_ url: URL, _ w: Int, _ h: Int, _ draw: (CGContext) -> Void) throws {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
}

private func fill(_ c: CGContext, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
    c.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    c.fill(rect)
}

/// RGBA of a pixel, y from the top.
private func rgba(_ img: CGImage, _ x: Int, _ y: Int) -> [Int] {
    var px = [UInt8](repeating: 0, count: 4)
    let c = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: -x, y: y - img.height + 1, width: img.width, height: img.height))
    return px.map(Int.init)
}

@Test func skyReplaceKeysTheSkyOverANewOne() async throws {
    let dir = try tempDir("sky")
    defer { try? FileManager.default.removeItem(at: dir) }
    let shot = dir.appendingPathComponent("shot.png"), sunset = dir.appendingPathComponent("sunset.png")
    try writeImage(shot, 384, 216) { c in
        for y in 0..<110 { let f = CGFloat(y) / 110; fill(c, 0.35 + 0.3 * f, 0.55 + 0.2 * f, 0.92, CGRect(x: 0, y: y, width: 384, height: 1)) }
        var seed: UInt64 = 3
        for y in stride(from: 110, to: 216, by: 2) {
            for x in stride(from: 0, to: 384, by: 2) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let v = CGFloat((seed >> 33) % 100) / 100
                fill(c, 0.2 + 0.2 * v, 0.3 + 0.2 * v, 0.15, CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
    }
    try writeImage(sunset, 384, 216) { c in fill(c, 0.95, 0.55, 0.25, CGRect(x: 0, y: 0, width: 384, height: 216)) }
    let night = dir.appendingPathComponent("night.png")
    try writeImage(night, 384, 216) { c in fill(c, 0.04, 0.04, 0.07, CGRect(x: 0, y: 0, width: 384, height: 216)) }
    var p = Project(name: "Sky", canvas: Canvas(width: 384, height: 216, fps: 24))
    p.media = [
        MediaAsset(id: "shot", path: shot.path, name: "shot", duration: 0, width: 384, height: 216, fps: 0, hasVideo: true, hasAudio: false, isImage: true),
        MediaAsset(id: "night", path: night.path, name: "night", duration: 0, width: 384, height: 216, fps: 0, hasVideo: true, hasAudio: false, isImage: true),
    ]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "shot", start: 0, duration: 4), Clip(id: "c2", kind: .media, mediaId: "night", start: 4, duration: 2)]
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])
    let r = await box.call("recipe", ["name": "sky_replace", "args": ["clip": "c1", "image": .string(sunset.path), "blend": 0.6]])
    #expect(!r.isError, "\(r.plainText)")
    #expect(r.plainText.contains("heuristic") && r.plainText.contains("relit"), "\(r.plainText)")
    let after = try bundle.loadProject()
    let clip = try #require(after.clip("c1"))
    #expect(clip.effects.first?.type == "mask.sky" && clip.effects.first?.params["invert"] == .bool(true))
    let match = try #require(clip.effects.first { $0.type == "color.wheels" })
    #expect((match.params["gain_r"]?.number ?? 0) > 0 && (match.params["gain_b"]?.number ?? 0) < 0, "warmer horizon warms the foreground: \(match.params)")
    let skyTrack = try #require(after.tracks.first { $0.name == "Sky" })
    #expect(after.tracks.firstIndex { $0.id == skyTrack.id }! < after.tracks.firstIndex { $0.clips.contains { $0.id == "c1" } }!, "new sky under the shot")
    let built = try await TimelineBuilder.build(after, transcripts: [:], library: MediaLibrary())
    let frame = try #require(try await Frames.timeline(built, times: [1], maxSize: CGSize(width: 384, height: 216)).first?.image)
    let top = rgba(frame, 100, 20), ground = rgba(frame, 100, 180)
    #expect(top[0] > 200 && top[2] < 120, "the sunset shows where the sky was: \(top)")
    #expect(ground[1] > ground[2], "the ground stays: \(ground)")

    let none = await box.call("recipe", ["name": "sky_replace", "args": ["clip": "c2", "media": "shot"]])
    #expect(none.isError && none.plainText.contains("No sky found"), "\(none.plainText)")
}

/// A short gray H.264 movie.
private func writeMovie(_ url: URL, _ w: Int, _ h: Int) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<6 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 100, CVPixelBufferGetBytesPerRow(buffer) * h)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 24)))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

@Test func proxyControlsPerMediaAndProject() async throws {
    let dir = try tempDir("proxy")
    defer { try? FileManager.default.removeItem(at: dir) }
    let movie = dir.appendingPathComponent("light.mov")
    try await writeMovie(movie, 320, 180)
    var p = Project(name: "Proxy", canvas: Canvas(width: 320, height: 180, fps: 24))
    p.media = [MediaAsset(id: "light", path: movie.path, name: "light", duration: 0.25, width: 320, height: 180, fps: 24, hasVideo: true, hasAudio: false)]
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])
    #expect(await box.call("media_list", [:]).plainText.contains("original (light footage)"))
    let organize = await box.call("media_organize", ["media_ids": ["light"], "proxy": "always"])
    #expect(organize.plainText.contains("media_analyze") && organize.plainText.contains("proxy:true"), "\(organize.plainText)")
    #expect(await box.call("media_list", [:]).plainText.contains("half not made"))
    let made = await box.call("media_analyze", ["media_id": "light", "proxy": true])
    #expect(!made.isError && made.plainText.contains("160×90"), "\(made.plainText)")
    defer { try? FileManager.default.removeItem(at: Proxies.url(for: p.media[0], quality: .half)) }
    #expect(await box.call("media_list", [:]).plainText.contains("half ready (always)"))
    let set = await box.call("canvas_set", ["playback": "original", "proxy_size": 720])
    #expect(!set.isError && set.plainText.contains("originals"), "\(set.plainText)")
    let after = try bundle.loadProject()
    #expect(after.playback == Playback(mode: .original, proxySize: .sd) && after.canvasSet == nil, "only playback changed")
    let listed = await box.call("media_list", [:]).plainText
    #expect(listed.contains("off (playback original)") && listed.contains("Preview playback: original, proxy size 720"), "\(listed)")
    #expect(after.media[0].proxy == .always)
    _ = await box.call("media_organize", ["media_ids": ["light"], "proxy": "auto"])
    #expect(try bundle.loadProject().media[0].proxy == nil)
}

@Test func reviewGeneratorsAndKeysGoThroughTheTools() async throws {
    let dir = try tempDir("review")
    defer { try? FileManager.default.removeItem(at: dir) }
    let still = dir.appendingPathComponent("still.png")
    try writePNG(still)
    var p = Project(name: "Review", canvas: Canvas(width: 320, height: 180, fps: 25))
    p.media = [MediaAsset(id: "still", path: still.path, name: "still", duration: 0, width: 64, height: 36, fps: 0, hasVideo: true, hasAudio: false, isImage: true)]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "still", start: 0, duration: 4)]
    let bundle = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(bundle.url.path)])
    let burn = await box.call("clip_add", ["generator": "timecode_burn", "track": "new", "start": 0, "duration": 4, "params": ["show": "record,source,clip", "position": "top_left"]])
    #expect(!burn.isError, "\(burn.plainText)")
    let credits = await box.call("clip_add", ["generator": "credits", "track": "new", "start": 4, "duration": 8, "params": ["text": "# END\n## Cast\nHero | Ada", "end_hold": 2]])
    #expect(!credits.isError, "\(credits.plainText)")
    for type in ["key.luma", "key.difference", "mask.sky"] {
        let r = await box.call("effect_add", ["target": "c1", "type": .string(type)])
        #expect(!r.isError, "\(type): \(r.plainText)")
    }
    let fx = try #require(try bundle.loadProject().clip("c1")).effects.map(\.type)
    #expect(fx == ["key.luma", "key.difference", "mask.sky"], "\(fx)")
}
