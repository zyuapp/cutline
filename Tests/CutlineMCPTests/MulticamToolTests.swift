import AVFoundation
import CoreGraphics
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// Four seconds at 25 fps, 320×180, one flat color whose green channel counts frames (2 per frame), so a frame's
/// source time can be read back from its pixels.
private func writeAngle(_ url: URL, red: UInt8, blue: UInt8) async throws {
    let w = 320, h = 180
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for i in 0..<100 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!, row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<h {
            let line = (base + y * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                line[x * 4] = blue
                line[x * 4 + 1] = UInt8(i * 2)
                line[x * 4 + 2] = red
                line[x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 25)))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// The center pixel as (r, g, b).
private func center(_ img: CGImage) -> (Int, Int, Int) {
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2, width: CGFloat(img.width), height: CGFloat(img.height)))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return (Int(p[0]), Int(p[1]), Int(p[2]))
}

@Test func multicamClipSwitchesRendersAndReviewsAngles() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-mc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await writeAngle(dir.appendingPathComponent("red.mov"), red: 220, blue: 20)
    try await writeAngle(dir.appendingPathComponent("blue.mov"), red: 20, blue: 220)
    let box = Toolbox()
    _ = await box.call("project_create", ["path": .string(dir.appendingPathComponent("mc").path), "width": 320, "height": 180, "fps": 25, "open_preview": false])
    let imported = await box.call("media_import", ["paths": [.string(dir.appendingPathComponent("red.mov").path), .string(dir.appendingPathComponent("blue.mov").path)], "analyze": false])
    #expect(!imported.isError, "\(imported.plainText)")

    // A clap at red 1.0 s and blue 0.6 s: red starts 0.4 s earlier, so blue source = red source - 0.4.
    let made = await box.call("multicam_create", ["angles": ["red", "blue"], "names": ["Wide", "Close"], "sync": "marker", "points": ["red": 1.0, "blue": 0.6], "name": "Talk"])
    #expect(!made.isError && made.plainText.contains("2 Close") && made.plainText.contains("Placed"), "\(made.plainText)")
    var p = try box.session.project()
    let clip = try #require(p.tracks[0].clips.first)
    #expect(p.multicamSetup(clip)?.angles.map(\.name) == ["Wide", "Close"])

    let cut = await box.call("multicam_cut", ["at": 1.2, "angle": 2])
    #expect(!cut.isError && cut.plainText.contains("angle 2 Close"), "\(cut.plainText)")
    let range = await box.call("multicam_cut", ["from": 2.0, "to": 2.8, "angle": "Wide"])
    #expect(!range.isError, "\(range.plainText)")
    let listed = await box.call("multicam_angles", [:])
    #expect(listed.plainText.contains("0.00–1.20s  angle 1 Wide") && listed.plainText.contains("1.20–2.00s  angle 2 Close") && listed.plainText.contains("2.80–"), "\(listed.plainText)")
    let one = await box.call("multicam_angles", ["at": 2.4])
    #expect(one.plainText.contains("At 2.40s: angle 1 Wide"), "\(one.plainText)")
    let undo = await box.call("history", ["action": "undo"])
    #expect(!undo.isError)
    #expect((await box.call("multicam_angles", ["at": 2.4])).plainText.contains("angle 2 Close"))
    _ = await box.call("history", ["action": "redo"])

    // The compositor plays the live angle, in sync: timeline t is red source t, blue source t - 0.4.
    p = try box.session.project()
    let built = try await box.session.timeline()
    let frames = try await Frames.timeline(built, times: [0.6, 1.6, 2.4, 3.2], maxSize: CGSize(width: 320, height: 180))
    let px = frames.map { center($0.image) }
    #expect(px[0].0 > 150 && px[1].2 > 150 && px[2].0 > 150 && px[3].2 > 150, "\(px)")
    #expect(abs(px[0].1 - 30) <= 8, "red source 0.6 s is frame 15: \(px[0])")
    #expect(abs(px[1].1 - 60) <= 8, "blue source 1.2 s is frame 30: \(px[1])")

    // The angle viewer shows both angles at a time, the live one marked.
    let grid = await box.call("timeline_frames", ["multicam": true, "times": [1.6]])
    #expect(!grid.isError && grid.plainText.contains("2 Close@1.20 LIVE") && grid.plainText.contains("1 Wide@1.60"), "\(grid.plainText)")

    // Recipe cuts by hand on the multicam clip keep it one clip.
    let recut = await box.call("recipe", ["name": "multicam_switch", "args": ["clip": .string(clip.id), "cuts": [["at": 3.0, "angle": "1"]]]])
    let afterRecut = try box.session.project().tracks[0].clips.count
    #expect(!recut.isError && afterRecut == 1, "\(recut.plainText)")

    // Export flattens to the live angles; interchange writes them as a compound clip with a note.
    let out = dir.appendingPathComponent("out.mp4")
    let exported = await box.call("export", ["path": .string(out.path)])
    #expect(!exported.isError, "\(exported.plainText)")
    let duration = try await AVURLAsset(url: out).load(.duration).seconds
    #expect(abs(duration - clip.duration) < 0.1)
    let xml = dir.appendingPathComponent("out.fcpxml")
    let fcp = await box.call("export", ["path": .string(xml.path)])
    #expect(fcp.plainText.contains("multicam clip → an mc-clip per angle switch"), "\(fcp.plainText)")
}

@Test(.enabled(if: FileManager.default.fileExists(atPath: "/tmp/cl-real/work/camL.mov") && FileManager.default.fileExists(atPath: "/tmp/cl-real/work/camR.mov")))
func realCamerasSyncBySoundIntoAMulticamClip() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-mcr-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let box = Toolbox()
    _ = await box.call("project_create", ["path": .string(dir.appendingPathComponent("mc").path), "open_preview": false])
    _ = await box.call("media_import", ["paths": ["/tmp/cl-real/work/camL.mov", "/tmp/cl-real/work/camR.mov"], "analyze": false])
    let ids = try box.session.project().media.map(\.id)
    let made = await box.call("multicam_create", .object(["angles": .array(ids.map { .string($0) }), "audio_follows_video": true]))
    print("real multicam:\n\(made.plainText)")
    #expect(!made.isError && made.plainText.contains("synced by sound") && !made.plainText.contains("low confidence"), "\(made.plainText)")
    let grid = await box.call("timeline_frames", ["multicam": true, "count": 2])
    #expect(!grid.isError && grid.plainText.contains("LIVE"), "\(grid.plainText)")
    let clip = try #require(try box.session.project().tracks[0].clips.first)
    _ = await box.call("media_analyze", .object(["media_id": .string(ids[0]), "features": ["transcript", "speakers"]]))
    let auto = await box.call("recipe", ["name": "multicam_switch", "args": ["clip": .string(clip.id)]])
    print("real multicam switch:\n\(auto.plainText)")
    #expect(!auto.isError, "\(auto.plainText)")
    let after = try box.session.project()
    #expect(after.tracks[0].clips.count == 1 && after.multicamSetup(after.tracks[0].clips[0]) != nil)
    print((await box.call("multicam_angles", [:])).plainText)
}
