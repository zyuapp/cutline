import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// An uncompressed RGGB DNG (camera space linear sRGB, gray card), 24 fps.
private func writeDNG(_ url: URL, width w: Int = 320, height h: Int = 240) throws {
    var entries: [(tag: UInt16, type: UInt16, count: UInt32, data: Data)] = []
    func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func add(_ tag: UInt16, _ type: UInt16, _ count: Int, _ data: Data) { entries.append((tag, type, UInt32(count), data)) }
    var pixels = Data(capacity: w * h * 2)
    for _ in 0..<(w * h) { pixels += le16(11796) }
    for (tag, v) in [(254, 0), (256, w), (257, h), (273, 0), (278, h), (279, pixels.count), (50714, 0), (50717, 65535)] { add(UInt16(tag), 4, 1, le32(UInt32(v))) }
    for (tag, v) in [(258, 16), (259, 1), (262, 32803), (274, 1), (277, 1), (284, 1), (50778, 21)] { add(UInt16(tag), 3, 1, le16(UInt16(v))) }
    add(33421, 3, 2, le16(2) + le16(2))
    add(33422, 1, 4, Data([0, 1, 1, 2]))
    add(50706, 1, 4, Data([1, 4, 0, 0]))
    add(50707, 1, 4, Data([1, 1, 0, 0]))
    add(50708, 2, 12, Data("Test Camera".utf8) + Data([0]))
    let m: [Double] = [3.2404542, -1.5371385, -0.4985314, -0.9692660, 1.8760108, 0.0415560, 0.0556434, -0.2040259, 1.0572252]
    add(50721, 10, 9, m.reduce(Data()) { $0 + le32(UInt32(bitPattern: Int32(($1 * 1_000_000).rounded()))) + le32(1_000_000) })
    add(50728, 5, 3, Data((0..<3).flatMap { _ in [UInt8](le32(1) + le32(1)) }))
    add(51044, 10, 1, le32(24) + le32(1))
    entries.sort { $0.tag < $1.tag }
    let extraBase = 8 + 2 + entries.count * 12 + 4
    var ifd = le16(UInt16(entries.count)), extra = Data(), strip = 0
    for e in entries {
        ifd += le16(e.tag) + le16(e.type) + le32(e.count)
        if e.tag == 273 { strip = ifd.count }
        if e.data.count <= 4 { ifd += e.data + Data(count: 4 - e.data.count) } else { ifd += le32(UInt32(extraBase + extra.count)); extra += e.data }
    }
    ifd += le32(0)
    ifd.replaceSubrange(strip..<(strip + 4), with: le32(UInt32(extraBase + extra.count)))
    try (Data([0x49, 0x49, 42, 0]) + le32(8) + ifd + extra + pixels).write(to: url)
}

@Test func cameraRawImportsDevelopsAndTakesRawControls() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-rawtool-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let card = dir.appendingPathComponent("card", isDirectory: true)
    let clipFolder = card.appendingPathComponent("A001_C007", isDirectory: true)
    try FileManager.default.createDirectory(at: clipFolder, withIntermediateDirectories: true)
    for i in 1...4 { try writeDNG(clipFolder.appendingPathComponent(String(format: "A001_C007_%05d.dng", i))) }
    try (Data([0, 0, 0, 20]) + Data("ftypqt  ".utf8) + Data(count: 64)).write(to: card.appendingPathComponent("B001_C001.braw"))
    let box = Toolbox()
    let made = await box.call("project_create", ["path": .string(dir.appendingPathComponent("p.cutline").path), "open_preview": false])
    #expect(!made.isError, "\(made.plainText)")

    let imported = await box.call("media_import", ["paths": [.string(card.path)], "analyze": false])
    #expect(!imported.isError, "\(imported.plainText)")
    #expect(imported.plainText.contains("camera RAW: CinemaDNG sequence") && imported.plainText.contains("4 frames"), "\(imported.plainText)")
    #expect(imported.plainText.contains("Not imported (1)") && imported.plainText.contains("Blackmagic RAW SDK") && imported.plainText.contains("Blackmagic RAW Player"), "\(imported.plainText)")
    let media = try #require(try box.session.project().media.first { $0.raw != nil })
    #expect(media.raw?.format == .cinemadng && media.fps == 24 && media.originalPath.map { URL(fileURLWithPath: $0).lastPathComponent } == "A001_C007" && !media.isTranscoding, "\(media)")

    let listed = await box.call("media_list", ["kind": "raw"])
    #expect(listed.plainText.contains("cinemadng (as shot)"), "\(listed.plainText)")

    let added = await box.call("clip_add", ["media_id": .string(media.id)])
    #expect(!added.isError, "\(added.plainText)")
    let clip = try #require(try box.session.project().tracks.flatMap(\.clips).first { $0.mediaId == media.id })
    let exposed = await box.call("param_set", ["target": .string(clip.id), "set": ["raw.exposure": 1]])
    #expect(!exposed.isError && !exposed.plainText.contains("renders in the background"), "\(exposed.plainText)")
    let balanced = await box.call("param_set", ["target": .string(clip.id), "set": ["raw.temperature": 3200]])
    #expect(balanced.plainText.contains("developed 3200K renders in the background"), "\(balanced.plainText)")
    let params = await box.call("project_status", ["target": .string(clip.id)])
    #expect(params.plainText.contains("raw.temperature"), "\(params.plainText)")

    let organized = await box.call("media_organize", ["media_ids": [.string(media.id)], "raw": ["exposure": 0.5, "tint": 5]])
    #expect(!organized.isError && organized.plainText.contains("exposure +0.50, tint +5.00"), "\(organized.plainText)")
    #expect(try box.session.project().mediaAsset(media.id)?.raw?.settings == RawSettings(exposure: 0.5, tint: 5))
    let logged = await box.call("media_organize", ["media_ids": [.string(media.id)], "log": "slog3"])
    #expect(logged.isError && logged.plainText.contains("camera RAW"), "\(logged.plainText)")

    let catalog = await box.call("catalog", ["type": "raw"])
    #expect(catalog.plainText.contains("raw.noise_reduction") && catalog.plainText.contains("\(media.id): CinemaDNG sequence"), "\(catalog.plainText)")
    let status = await box.call("project_status", [:])
    #expect(status.plainText.contains("camera RAW CinemaDNG sequence"), "\(status.plainText)")

    // The timeline waits for the 3200 K copy and plays it.
    let t = try await box.session.timeline()
    #expect(t.missingPictures.isEmpty)
    #expect(CameraRawDevelop.requests(try box.session.project()).allSatisfy { CameraRawDevelop.cached($0) != nil })
}
