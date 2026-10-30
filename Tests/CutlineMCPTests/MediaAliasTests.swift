import CutlineCore
import Testing
@testable import CutlineMCP

@Test func mediaNamesResolveToIds() throws {
    let media = [
        MediaAsset(id: "caml", path: "/x/camL.mov", name: "Cam L", duration: 10, width: 1920, height: 1080, fps: 25, hasVideo: true, hasAudio: true),
        MediaAsset(id: "tears-of-steel-720p", path: "/x/tears_of_steel_720p.mp4", name: "Tears", duration: 10, width: 1280, height: 720, fps: 24, hasVideo: true, hasAudio: true),
    ]
    let args: JSON = .object([
        "media_id": .string("camL"),
        "start": .string("tears_of_steel_720p.w12.end"),
        "sources": .array([.object(["media": .string("tears_of_steel_720p.mp4")])]),
        "clip": .string("camL"),
    ])
    let out = try Toolbox.resolveMediaAliases(args, media: media)
    #expect(out["media_id"]?.string == "caml")
    #expect(out["start"]?.string == "tears-of-steel-720p.w12.end")
    #expect(out["sources"]?.array?.first?["media"]?.string == "tears-of-steel-720p")
    #expect(out["clip"]?.string == "camL")
    #expect(throws: EditError.self) { try Toolbox.resolveMediaAliases(.object(["media_id": .string("camX")]), media: media) }
}
