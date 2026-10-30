import Testing
@testable import CutlineCore

@Test func mainPictureIsTheLayerShowingMostOfTheFrame() {
    var p = Project(name: "Layers")
    p.media = [
        MediaAsset(id: "cam", path: "/tmp/cam.mov", name: "cam", duration: 10, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true),
        MediaAsset(id: "logo", path: "/tmp/logo.png", name: "logo", duration: 0, width: 400, height: 400, fps: 0, hasVideo: true, hasAudio: false, isImage: true),
    ]
    p.tracks[0].clips = [Clip(id: "main", kind: .media, mediaId: "cam", start: 0, duration: 10)]
    var logo = Clip(id: "bug", kind: .media, mediaId: "logo", start: 0, duration: 10)
    logo.transform.scale = 0.12
    logo.transform.x = 0.4
    logo.transform.y = -0.4
    p.tracks.append(Track(id: "V2", kind: .video, name: "Logo", clips: [logo]))
    #expect(p.mainPicture(at: 5)?.id == "main")
    let layers = p.pictureLayers(at: 5)
    #expect(layers.map(\.clip.id) == ["bug", "main"])
    #expect(layers[0].coverage < 0.02 && layers[1].visible > 0.95)

    // A full-frame layer on top hides the one below.
    p.tracks[2].clips[0] = Clip(id: "full", kind: .media, mediaId: "cam", start: 0, duration: 10)
    #expect(p.mainPicture(at: 5)?.id == "full")
}

@Test func changesListMediaOrganizingCaptionEditsAndTextSpans() {
    var old = Project(name: "Diff")
    old.media = [MediaAsset(id: "m1", path: "/tmp/a.mov", name: "a", duration: 10, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true)]
    old.tracks[0].clips = [Clip(id: "t1", kind: .text, start: 0, duration: 2, text: TextSpec(text: "Hello Ada"))]
    var p = old
    p.media[0].bin = "Interviews/Day 1"
    p.media[0].metadata = ["scene": "12A"]
    p.media[0].name = "Interview A"
    let lines = p.changes(from: old)
    let media = lines.first { $0.hasPrefix("~ media m1") }
    #expect(media?.contains("bin none→Interviews/Day 1") == true)
    #expect(media?.contains("scene –→12A") == true)
    #expect(media?.contains("name \"a\"→\"Interview A\"") == true)

    var q = old
    q.captions.edits = [CaptionEdit(mediaId: "m1", fromWord: 3, toWord: 3, mergeNext: true)]
    q.tracks[0].clips[0].text?.spans = [TextSpan(match: "ada", color: .black)]
    let more = q.changes(from: old)
    #expect(more.contains { $0.hasPrefix("~ captions: cue edits +m1.w3(merge)") })
    #expect(more.contains { $0.contains("text spans 0→1") })
    #expect(old.changes(from: old).isEmpty)
}
