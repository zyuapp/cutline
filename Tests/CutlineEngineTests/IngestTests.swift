import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

private let tools = FFmpeg.tools()
private let skip: Testing.Comment = "ffmpeg not found (CUTLINE_FFMPEG, PATH, /opt/homebrew/bin, /usr/local/bin); brew install ffmpeg to run"

private func tempDir(_ tag: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-\(tag)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func ffmpeg(_ args: [String]) async throws {
    try await FFmpeg.run(tools!.ffmpeg, ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"] + args)
}

private func ffprobe(_ url: URL) async throws -> ProbeInfo {
    try await FFmpeg.probe(url, ffprobe: try #require(tools?.ffprobe))
}

/// XDCAM-style MPEG-2 4:2:2 in MXF: 50i woven from 50p test pattern, four mono PCM tracks, TC 10:00:00:00.
private func makeXDCAM(_ url: URL, seconds: Int = 2) async throws {
    try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=50", "-f", "lavfi", "-i", "sine=f=440:sample_rate=48000", "-t", "\(seconds)",
                      "-filter_complex", "[0:v]interlace=scan=tff,setfield=tff[v];[1:a]asplit=4[a0][a1][a2][a3]",
                      "-map", "[v]", "-map", "[a0]", "-map", "[a1]", "-map", "[a2]", "-map", "[a3]",
                      "-c:v", "mpeg2video", "-flags", "+ildct+ilme", "-b:v", "50M", "-pix_fmt", "yuv422p", "-c:a", "pcm_s24le", "-timecode", "10:00:00:00", url.path])
}

private func makeDNxHD(_ url: URL) async throws {
    try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=25", "-t", "1", "-c:v", "dnxhd", "-profile:v", "dnxhr_hq", "-pix_fmt", "yuv422p", url.path])
}

/// Luma of an image, row-major from the top.
private func luma(_ img: CGImage) -> (w: Int, h: Int, px: [Float]) {
    let w = img.width, h = img.height
    var bytes = [UInt8](repeating: 0, count: w * h)
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, bytes.map { Float($0) / 255 })
}

/// Mean distance of each line from the average of its neighbours: high where fields comb.
private func combing(_ l: (w: Int, h: Int, px: [Float]), rows: Range<Int>? = nil, columns: Range<Int>? = nil) -> Float {
    let rs = rows ?? 1..<(l.h - 1), cs = columns ?? 0..<l.w
    var sum: Float = 0
    var n = 0
    for r in rs where r > 0 && r < l.h - 1 {
        for c in cs {
            sum += abs(l.px[r * l.w + c] - (l.px[(r - 1) * l.w + c] + l.px[(r + 1) * l.w + c]) / 2)
            n += 1
        }
    }
    return sum / Float(max(n, 1))
}

private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

/// A woven frame: a bright box that moved 60 px between fields, over a static horizontal edge.
private func wovenFrame(width w: Int = 480, height h: Int = 270) -> CGImage {
    var px = [UInt8](repeating: 40, count: w * h)
    for r in 0..<h {
        for c in 0..<w {
            if r >= 200 { px[r * w + c] = 200 }
            let x = r % 2 == 0 ? 100 : 160
            if (60..<160).contains(r), (x..<(x + 120)).contains(c) { px[r * w + c] = 230 }
        }
    }
    let provider = CGDataProvider(data: Data(px) as CFData)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

@Test func deinterlaceRemovesCombingAndKeepsStillDetail() throws {
    let woven = wovenFrame()
    let input = CIImage(cgImage: woven, options: [.colorSpace: NSNull()])
    let out = try #require(context.createCGImage(Deinterlace.apply(input, order: .tff), from: input.extent))
    let before = luma(woven), after = luma(out)
    let moving = combing(before, rows: 60..<160, columns: 100..<280)
    let fixed = combing(after, rows: 60..<160, columns: 100..<280)
    #expect(moving > 0.05)
    #expect(fixed < moving * 0.25, "combing \(moving) → \(fixed)")
    // The static edge at line 200 and the flat areas are untouched.
    for r in [190, 199, 200, 201, 230] {
        for c in [10, 240, 470] {
            #expect(abs(after.px[r * after.w + c] - before.px[r * before.w + c]) < 0.02, "line \(r) column \(c)")
        }
    }
    // Lines of the kept (top) field never change.
    for r in stride(from: 60, to: 160, by: 2) {
        #expect(abs(after.px[r * after.w + 130] - before.px[r * before.w + 130]) < 0.02)
    }
    #expect(Deinterlace.apply(input, order: .progressive) === input)
    #expect(Deinterlace.apply(input, order: nil) === input)
}

@Test func fieldOrderComesFromTheFormatDescription() throws {
    func fd(_ ext: [CFString: Any]) throws -> CMFormatDescription {
        var out: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_AppleProRes422HQ, width: 1920, height: 1080, extensions: ext as CFDictionary, formatDescriptionOut: &out)
        return try #require(out)
    }
    #expect(MediaProbe.fieldOrder(try fd([:])) == nil)
    #expect(MediaProbe.fieldOrder(try fd([kCMFormatDescriptionExtension_FieldCount: 1])) == .progressive)
    #expect(MediaProbe.fieldOrder(try fd([kCMFormatDescriptionExtension_FieldCount: 2, kCMFormatDescriptionExtension_FieldDetail: kCMFormatDescriptionFieldDetail_SpatialFirstLineEarly])) == .tff)
    #expect(MediaProbe.fieldOrder(try fd([kCMFormatDescriptionExtension_FieldCount: 2, kCMFormatDescriptionExtension_FieldDetail: kCMFormatDescriptionFieldDetail_TemporalBottomFirst])) == .bff)
}

@Test func ffmpegIsFoundOrDisabled() {
    #expect(FFmpeg.tools(environment: ["CUTLINE_FFMPEG": "none", "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin"]) == nil)
    #expect(FFmpeg.tools(environment: ["CUTLINE_FFMPEG": "/nonexistent/ffmpeg"]) == nil)
    #expect(ExportPreset.unavailable("dnxhr_hq", ffmpeg: false)?.contains("brew install ffmpeg") == true)
    #expect(ExportPreset.unavailable("xdcam_hd422", ffmpeg: true) == nil)
    #expect(ExportPreset.unavailable("prores_hq", ffmpeg: false) == nil)
}

/// Transcodes and exports one at a time so they don't crowd the decoders other suites use.
@Suite(.serialized) struct FFmpegIngestTests {
@Test(.enabled(if: tools != nil, skip)) func mxfImportTranscodesToADecodableMezzanine() async throws {
    let dir = try tempDir("mxf")
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("A001_C002.mxf")
    try await makeXDCAM(src)
    #expect(await MediaIngest.verify(src) != nil)
    guard case .ready(let m) = try await MediaIngest.prepare(src, id: "a001", cache: dir.appendingPathComponent("cache"), tools: tools) else { Issue.record("deferred"); return }
    #expect(m.originalPath == src.path)
    #expect(m.conformPath == src.path)
    #expect(m.path.contains("/cache/mezzanine/") && m.path.hasSuffix(".mov"))
    #expect(m.transcoded?.contains("mpeg2video") == true && m.transcoded?.contains("ProRes 422 HQ") == true, "\(m.transcoded ?? "")")
    #expect(m.name == "A001 C002")
    #expect(await MediaIngest.verify(m.url) == nil)
    #expect(m.fieldOrder == .tff)
    #expect(m.width == 1920 && m.height == 1080 && abs(m.fps - 25) < 0.01)
    #expect(abs((m.timecodeStart ?? 0) - 36000) < 0.001, "\(String(describing: m.timecodeStart))")
    #expect(abs(m.duration - 2) < 0.1)
    // Channels 1+2 are the stereo program track; 3 and 4 stay as their own tracks.
    let tracks = try await AVURLAsset(url: m.url).loadTracks(withMediaType: .audio)
    var channels: [Int] = []
    for t in tracks {
        let fd = try #require(try await t.load(.formatDescriptions).first)
        channels.append(Int(CMAudioFormatDescriptionGetStreamBasicDescription(fd)!.pointee.mChannelsPerFrame))
    }
    #expect(channels == [2, 1, 1])
    let mezz = try await ffprobe(m.url)
    #expect(mezz.video?.codec == "prores" && mezz.video?.profile == "HQ")
    #expect(mezz.timecode == "10:00:00:00")
    let frames = try await Frames.media(m, times: [0.5, 1.5], maxSize: CGSize(width: 480, height: 270))
    #expect(frames.count == 2)
    // A second import reuses the mezzanine.
    guard case .ready(let again) = try await MediaIngest.prepare(src, id: "a001", cache: dir.appendingPathComponent("cache"), tools: tools) else { Issue.record("deferred"); return }
    #expect(again.path == m.path)
}

@Test(.enabled(if: tools != nil, skip)) func dnxhdMovIsCaughtAtImportAndTranscoded() async throws {
    let dir = try tempDir("dnx")
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("dnx.mov")
    try await makeDNxHD(src)
    // AVFoundation opens the container, so only decoding a frame finds the problem.
    _ = try await MediaProbe.probe(src, id: "dnx")
    let why = try #require(await MediaIngest.verify(src))
    #expect(why.contains("Decode"), "\(why)")
    do {
        _ = try await MediaIngest.prepare(src, id: "dnx", cache: dir, tools: nil)
        Issue.record("imported without ffmpeg")
    } catch let f as MediaIngest.Failure {
        #expect(f.description.hasPrefix("dnx.mov: "), "\(f)")
        #expect(f.description.contains("DNxHR"), "\(f)")
        #expect(f.description.contains("brew install ffmpeg"), "\(f)")
    }
    guard case .ready(let m) = try await MediaIngest.prepare(src, id: "dnx", cache: dir, tools: tools) else { Issue.record("deferred"); return }
    #expect(m.transcoded?.contains("dnxhd") == true)
    #expect(m.fieldOrder == .progressive)
    #expect(await MediaIngest.verify(m.url) == nil)
}

@Test(.enabled(if: tools != nil, skip)) func longFilesAreDeferredToTheBackground() async throws {
    let dir = try tempDir("defer")
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("long.mxf")
    try await makeXDCAM(src, seconds: 1)
    guard case .deferred(let m, let info) = try await MediaIngest.prepare(src, id: "long", cache: dir, tools: tools, syncLimit: 0.5) else { Issue.record("not deferred"); return }
    #expect(m.path == src.path && m.originalPath == src.path && m.isTranscoding)
    #expect(m.width == 1920 && m.fieldOrder == .tff)
    let done = try await MediaIngest.finish(src, id: "long", info: info, cache: dir, tools: tools!)
    #expect(await MediaIngest.verify(done.url) == nil)
}

@Test(.enabled(if: tools != nil, skip)) func interlacedMediaIsDetectedAndDeinterlacedByTheCompositor() async throws {
    let dir = try tempDir("interlace")
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("i50.mov")
    // A white box moving 24 px per field over gray, woven into 25i.
    try await ffmpeg(["-f", "lavfi", "-i", "color=c=gray:s=1920x1080:r=50", "-f", "lavfi", "-i", "color=c=white:s=200x400:r=50", "-t", "1",
                      "-filter_complex", "[0][1]overlay=x='mod(t*1200,1600)':y=300,interlace=scan=tff:lowpass=0,setfield=tff",
                      "-c:v", "prores_ks", "-profile:v", "3", "-flags", "+ildct+ilme", "-field_order", "tt", src.path])
    var m = try await MediaProbe.probe(src, id: "i50")
    #expect(m.fieldOrder == .tff)
    #expect(m.deinterlaces)
    var p = Project(name: "Interlace", canvas: Canvas(width: 1920, height: 1080, fps: 25))
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "i50", start: 0, duration: 1)]
    func comb(_ media: MediaAsset) async throws -> Float {
        p.media = [media]
        let built = try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
        let frames = try await Frames.timeline(built, times: [0.48], maxSize: CGSize(width: 1920, height: 1080))
        let img = try #require(frames.first?.image)
        #expect(img.height == 1080)
        return combing(luma(img), rows: 300..<700)
    }
    let deinterlaced = try await comb(m)
    m.deinterlace = false
    let woven = try await comb(m)
    #expect(woven > 0.002)
    #expect(deinterlaced < woven * 0.3, "combing woven \(woven), deinterlaced \(deinterlaced)")
}

/// A 2 s ProRes source with stereo sound and a timeline playing it at 1920×1080 25 fps from 10:00:00:00.
func deliveryTimeline(_ dir: URL) async throws -> BuiltTimeline {
    let src = dir.appendingPathComponent("src.mov")
    try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=25", "-f", "lavfi", "-i", "sine=f=1000:sample_rate=48000", "-t", "2",
                      "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", "-ac", "2", src.path])
    var p = Project(name: "Deliver", canvas: Canvas(width: 1920, height: 1080, fps: 25, timecodeStart: "10:00:00:00"))
    p.media = [try await MediaProbe.probe(src, id: "src")]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "src", start: 0, duration: 2)]
    return try await TimelineBuilder.build(p, transcripts: [:], library: MediaLibrary())
}

@Test(.enabled(if: tools != nil, skip)) func dnxhrMXFAndXDCAMExportsProbeAsDelivered() async throws {
    let dir = try tempDir("deliver")
    defer { try? FileManager.default.removeItem(at: dir) }
    let built = try await deliveryTimeline(dir)

    let dnx = dir.appendingPathComponent("master.mxf")
    try await Exporter.export(built, to: dnx, options: ExportOptions(preset: .dnxhr_hq))
    let d = try await ffprobe(dnx)
    #expect(d.formatName == "mxf")
    #expect(d.video?.codec == "dnxhd" && d.video?.profile == "DNXHR HQ", "\(String(describing: d.video))")
    #expect(d.video?.pixelFormat == "yuv422p")
    #expect(d.video?.colorPrimaries == "bt709" && d.video?.colorTransfer == "bt709")
    #expect(d.timecode == "10:00:00:00")
    #expect(d.audio.count == 2 && d.audio.allSatisfy { $0.channels == 1 && $0.codec == "pcm_s24le" && $0.sampleRate == 48000 })
    #expect(abs(d.duration - 2) < 0.1)

    let hqx = dir.appendingPathComponent("master.mov")
    try await Exporter.export(built, to: hqx, options: ExportOptions(preset: .dnxhr_hqx, range: TimeRange(0, 1)))
    let h = try await ffprobe(hqx)
    #expect(h.video?.profile == "DNXHR HQX" && h.video?.pixelFormat == "yuv422p10le", "\(String(describing: h.video))")
    #expect(h.audio.count == 1 && h.audio.first?.channels == 2)
    #expect(h.timecode == "10:00:00:00")

    let xd = dir.appendingPathComponent("air.mxf")
    try await Exporter.export(built, to: xd, options: ExportOptions(preset: .xdcam_hd422))
    let x = try await ffprobe(xd)
    #expect(x.formatName == "mxf")
    #expect(x.video?.codec == "mpeg2video" && x.video?.profile == "4:2:2" && x.video?.pixelFormat == "yuv422p")
    #expect(x.video?.width == 1920 && x.video?.height == 1080)
    #expect(x.video?.bitRate == 50_000_000)
    #expect(x.timecode == "10:00:00:00")
    #expect(x.audio.count == 8)
    #expect(x.audio.allSatisfy { $0.channels == 1 && $0.codec == "pcm_s24le" && $0.sampleRate == 48000 && $0.bitsPerSample == 24 })
}

@Test func xdcamRejectsFrameRatesItCantCarry() {
    var p = Project(name: "Rates", canvas: Canvas(width: 1920, height: 1080, fps: 60))
    #expect(FFmpegDelivery.check(p, preset: .xdcam_hd422, container: "mxf")?.contains("29.97") == true)
    p.canvas.fps = 25
    #expect(FFmpegDelivery.check(p, preset: .xdcam_hd422, container: "mxf") == nil)
    #expect(FFmpegDelivery.check(p, preset: .xdcam_hd422, container: "mov") != nil)
    p.canvas.colorSpace = .rec2020_pq
    #expect(FFmpegDelivery.check(p, preset: .dnxhr_hq, container: "mov")?.contains("dnxhr_hqx") == true)
    #expect(FFmpegDelivery.check(p, preset: .dnxhr_hqx, container: "mxf") == nil)
}
}
