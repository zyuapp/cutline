import Foundation
import Testing
@testable import CutlineCore

private func transcodedProject() -> Project {
    var p = Project(name: "Conform", canvas: Canvas(width: 1920, height: 1080, fps: 25))
    var m = MediaAsset(id: "a001", path: "/proj.cutline/cache/mezzanine/A001_C002-0123456789.mov", name: "A001 C002", duration: 10, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true)
    m.originalPath = "/Volumes/CARD/Clip/A001_C002.MXF"
    m.transcoded = "MPEG-2 video (mpeg2video, 4:2:2) in MXF → ProRes 422 HQ"
    m.fieldOrder = .tff
    m.timecodeStart = 36000
    p.media = [m]
    p.tracks[0].clips = [Clip(id: "c1", kind: .media, mediaId: "a001", start: 0, duration: 4, sourceIn: 2)]
    return p
}

@Test func interchangeNamesTheCameraOriginalNotTheMezzanine() throws {
    let p = transcodedProject()
    for (kind, text) in [("otio", String(decoding: try p.otio(), as: UTF8.self)), ("fcpxml", p.fcpxml()), ("xml", p.xmeml()), ("edl", p.edl(title: "Conform"))] {
        #expect(text.contains("A001_C002.MXF"), "\(kind)")
        #expect(!text.contains("mezzanine"), "\(kind)")
    }
}

@Test func interlaceAndConformPathsDefaultSensibly() {
    var m = MediaAsset(id: "x", path: "/a/x.mov", name: "X", duration: 1, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: false)
    #expect(m.conformPath == "/a/x.mov" && !m.isInterlaced && !m.deinterlaces)
    m.fieldOrder = .bff
    #expect(m.isInterlaced && m.deinterlaces)
    m.deinterlace = false
    #expect(m.isInterlaced && !m.deinterlaces)
    m.fieldOrder = .progressive
    m.deinterlace = nil
    #expect(!m.deinterlaces)
}

@Test func relinkingATranscodedItemFindsItsOriginalByName() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-relink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("x".utf8).write(to: dir.appendingPathComponent("A001_C002.MXF"))
    var p = transcodedProject()
    let found = p.relinkAll(searchRoots: [dir]) { FileManager.default.fileExists(atPath: $0) }
    #expect(found.map(\.0) == ["a001"])
    let m = try #require(p.mediaAsset("a001"))
    #expect(m.path.hasSuffix("A001_C002.MXF") && m.originalPath == nil && m.transcoded == nil)
}

@Test func consolidationKeepsTheOriginalUnlessTrimmed() throws {
    let p = transcodedProject()
    let dir = URL(fileURLWithPath: "/archive/Media")
    let whole = ConsolidatePlan(p, trim: false, handles: 1).apply(to: p, directory: dir)
    #expect(whole.media[0].path.hasPrefix("/archive/Media/") && whole.media[0].originalPath == "/Volumes/CARD/Clip/A001_C002.MXF")
    let trimmed = ConsolidatePlan(p, trim: true, handles: 1).apply(to: p, directory: dir)
    #expect(trimmed.media.count == 1 && trimmed.media[0].originalPath == nil && trimmed.media[0].transcoded == nil)
    #expect(trimmed.media[0].fieldOrder == .tff)
}

@Test func mediaWithoutTheNewFieldsStillDecodes() throws {
    let json = #"{"id":"a","path":"/a.mov","name":"A","duration":1,"width":10,"height":10,"fps":25,"hasVideo":true,"hasAudio":false,"isImage":false}"#
    let m = try JSONDecoder().decode(MediaAsset.self, from: Data(json.utf8))
    #expect(m.originalPath == nil && m.fieldOrder == nil && m.deinterlace == nil)
}
