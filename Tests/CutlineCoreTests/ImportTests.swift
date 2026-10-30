import Foundation
import Testing
@testable import CutlineCore

// MARK: Fixtures

/// V1: c1 (a 0–4 from 2 s) dissolving into c2 (b 4–7 from 1 s), gap, c3 (a 8–10 from 10 s at 2×).
/// V2: o1 (b 1.5–3.5 from 3 s), title t1 5–6.5. A1: a1 (music 0–6 at half volume). Markers at 2 and 8.5 s.
private func roundTripProject(align: TransitionAlign = .start) -> Project {
    var p = Project(name: "Round Trip")
    p.media = [
        MediaAsset(id: "a", path: "/tmp/cutline import/a.mov", name: "a", duration: 20, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: true),
        MediaAsset(id: "b", path: "/tmp/b.mov", name: "b", duration: 10, width: 1920, height: 1080, fps: 30, hasVideo: true, hasAudio: false),
        MediaAsset(id: "music", path: "/tmp/music.m4a", name: "music", duration: 30, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
    ]
    p.tracks[0].clips = [
        Clip(id: "c1", kind: .media, mediaId: "a", start: 0, duration: 4, sourceIn: 2),
        Clip(id: "c2", kind: .media, mediaId: "b", start: 4, duration: 3, sourceIn: 1),
        Clip(id: "c3", kind: .media, mediaId: "a", start: 8, duration: 2, sourceIn: 10, speed: 2),
    ]
    p.tracks[1].clips = [Clip(id: "a1", kind: .media, mediaId: "music", start: 0, duration: 6, volume: 0.5)]
    p.tracks.append(Track(id: "V2", kind: .video, name: "Overlay", clips: [
        Clip(id: "o1", kind: .media, mediaId: "b", start: 1.5, duration: 2, sourceIn: 3),
        Clip(id: "t1", kind: .text, start: 5, duration: 1.5, text: TextSpec(text: "Hello")),
    ]))
    p.transitions = [Transition(id: "tr1", from: "c1", to: "c2", type: "dissolve", duration: 1, align: align)]
    p.markers = [Marker(id: "k2", time: 8.5, label: "Fast"), Marker(id: "k1", time: 2, label: "Hook")]
    return p
}

private struct Shape: Equatable, CustomStringConvertible {
    var kind: ClipKind
    var media: String?
    var start: Int
    var duration: Int
    var sourceIn: Int
    var speed: Double
    var text: String?

    var description: String { "\(kind.rawValue) \(media ?? "-") @\(start)+\(duration) in \(sourceIn) ×\(speed)\(text.map { " \"\($0)\"" } ?? "")" }
}

/// Clip timing in whole frames; fails when a time is off the frame grid.
private func shapes(_ t: Track, fps: Double = 30) -> [Shape] {
    func f(_ s: Seconds) -> Int {
        #expect(abs(s * fps - (s * fps).rounded()) < 1e-6, "\(s) is off the \(fps) fps grid")
        return Int((s * fps).rounded())
    }
    return t.clips.map { Shape(kind: $0.kind, media: $0.mediaId, start: f($0.start), duration: f($0.duration), sourceIn: f($0.sourceIn), speed: $0.speed, text: $0.text?.text) }
}

private func markers(_ p: Project, fps: Double = 30) -> [String] {
    p.markers.map { "\(Int(($0.time * fps).rounded())) \($0.label)" }
}

// MARK: Round trips

@Test func fcpxmlRoundTripKeepsTimingLanesSpeedAndMarkers() throws {
    let p = roundTripProject()
    // The exporter leaves transitions out; add the dissolve the way Final Cut writes one.
    let doc = try XMLDocument(xmlString: p.fcpxml(), options: [])
    let spine = try #require(try doc.nodes(forXPath: "//project/sequence/spine").first as? XMLElement)
    spine.insertChild(try XMLElement(xmlString: #"<transition name="Cross Dissolve" offset="4s" duration="1s"/>"#), at: 1)

    let r = try Importer.fcpxml(doc.xmlData, relativeTo: nil)
    let q = r.project
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    #expect(q.canvas == p.canvas)
    #expect(q.name == "Round Trip")
    #expect(q.tracks.map(\.id) == ["V1", "V2", "A1"])
    #expect(q.tracks.map(\.kind) == [.video, .video, .audio])
    #expect(shapes(q.tracks[0]) == shapes(p.tracks[0]))
    #expect(shapes(q.tracks[1]) == shapes(p.tracks[2]))
    #expect(shapes(q.tracks[2]) == shapes(p.tracks[1]))
    #expect(abs(q.tracks[2].clips[0].volume - 0.5) < 1e-3)
    #expect(q.media.map(\.id) == ["a", "b", "music"])
    #expect(q.media.map(\.path) == p.media.map(\.path))
    #expect(q.media.map(\.duration) == [20, 10, 30])
    #expect(q.media.map(\.hasAudio) == [true, false, true])
    #expect(q.media.map(\.hasVideo) == [true, true, false])
    #expect(r.missingMedia.contains("/tmp/cutline import/a.mov"))
    #expect(markers(q) == ["60 Hook", "255 Fast"])

    let tr = try #require(q.transitions.first)
    #expect(q.transitions.count == 1)
    #expect(tr.from == q.tracks[0].clips[0].id && tr.to == q.tracks[0].clips[1].id)
    #expect(tr.type == "dissolve" && tr.duration == 1 && tr.align == .start)
    #expect(try q.window(tr).start == 4)
}

@Test func otioRoundTripKeepsIdsTimingSpeedAndMarkers() throws {
    let p = roundTripProject()
    var root = try #require(try JSONSerialization.jsonObject(with: p.otio()) as? [String: Any])
    // Insert an OTIO dissolve that starts at the cut, as the exporter has none.
    var stack = try #require(root["tracks"] as? [String: Any])
    var tracks = try #require(stack["children"] as? [[String: Any]])
    var main = try #require(tracks[0]["children"] as? [[String: Any]])
    func rt(_ v: Double) -> [String: Any] { ["OTIO_SCHEMA": "RationalTime.1", "rate": 30.0, "value": v] }
    main.insert(["OTIO_SCHEMA": "Transition.1", "name": "Cross Dissolve", "transition_type": "SMPTE_Dissolve",
                 "in_offset": rt(0), "out_offset": rt(30), "metadata": [String: Any]()], at: 1)
    tracks[0]["children"] = main
    stack["children"] = tracks
    root["tracks"] = stack

    let r = try Importer.otio(try JSONSerialization.data(withJSONObject: root), relativeTo: nil)
    let q = r.project
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    #expect(q.canvas == p.canvas)
    #expect(q.tracks.map(\.id) == ["V1", "V2", "A1"])
    #expect(q.tracks.map(\.name) == ["Main", "Overlay", "Music"])
    #expect(q.tracks.map { $0.clips.map(\.id) } == [["c1", "c2", "c3"], ["o1", "t1"], ["a1"]])
    #expect(shapes(q.tracks[0]) == shapes(p.tracks[0]))
    #expect(shapes(q.tracks[1]) == shapes(p.tracks[2]))
    #expect(shapes(q.tracks[2]) == shapes(p.tracks[1]))
    #expect(q.tracks[2].clips[0].volume == 0.5)
    #expect(q.media.map(\.id) == ["a", "b", "music"])
    #expect(q.media.map(\.hasAudio) == [true, false, true])
    #expect(q.media.map(\.duration) == [20, 10, 30])
    #expect(markers(q) == ["60 Hook", "255 Fast"])
    #expect(q.transitions == [Transition(id: "tr1", from: "c1", to: "c2", type: "dissolve", duration: 1, align: .start)])
}

@Test func edlRoundTripKeepsTimingSpeedDissolveAndMarkers() throws {
    let p = roundTripProject()
    let edl = p.edl(title: "Round Trip")
    #expect(edl.hasPrefix("TITLE: Round Trip\nFCM: NON-DROP FRAME\n\n001  A        V     C        00:00:02:00 00:00:06:00 01:00:00:00 01:00:04:00\n"))
    #expect(edl.contains("002  A        V     C        00:00:06:00 00:00:06:00 01:00:04:00 01:00:04:00\n002  B        V     D    030 00:00:01:00 00:00:04:00 01:00:04:00 01:00:07:00\n"))
    #expect(edl.contains("M2   A              060.0                00:00:10:00"))
    #expect(edl.contains("* SOURCE FILE: /tmp/cutline import/a.mov"))
    #expect(edl.contains("* LOC: 01:00:02:00 RED     Hook"))
    #expect(edl.contains("004  MUSIC    A     C        00:00:00:00 00:00:06:00 01:00:00:00 01:00:06:00"))

    let ids = ["a": "a", "b": "b", "music": "music"]
    let r = try Importer.edl(edl, fps: 30) { ids[$0] }
    let q = r.project
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    #expect(r.missingMedia.isEmpty)
    #expect(q.name == "Round Trip")
    #expect(q.tracks.map(\.kind) == [.video, .audio])
    #expect(shapes(q.tracks[0]) == shapes(p.tracks[0]))
    #expect(shapes(q.tracks[1]) == shapes(p.tracks[1]))
    #expect(markers(q) == ["60 Hook", "255 Fast"])
    let tr = try #require(q.transitions.first)
    #expect(tr.from == q.tracks[0].clips[0].id && tr.to == q.tracks[0].clips[1].id)
    #expect(tr.type == "dissolve" && tr.duration == 1 && tr.align == .start)
    #expect(Set(q.media.map(\.id)) == ["a", "b", "music"])
    #expect(q.media.first { $0.id == "a" }?.path == "/tmp/cutline import/a.mov")
}

@Test func edlMovesCenteredAndBlackTransitionsToTheirEdits() throws {
    var p = roundTripProject(align: .center)
    p.transitions += [
        Transition(id: "in", from: nil, to: "c1", type: "dissolve", duration: 0.5),
        Transition(id: "out", from: "c3", to: nil, type: "dissolve", duration: 1),
    ]
    let edl = p.edl(title: "Fades")
    #expect(edl.contains("BL       V     C        00:00:00:00 00:00:00:00 01:00:00:00 01:00:00:00"))
    #expect(edl.contains("BL       V     D    030 00:00:00:00 00:00:01:00 01:00:09:00 01:00:10:00"))

    let r = try Importer.edl(edl, fps: 30) { ["a": "a", "b": "b", "music": "music"][$0] }
    let q = r.project
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    // The centered dissolve now starts at the edit, which moved to its start; the picture is the same.
    let v1 = shapes(q.tracks[0])
    #expect(v1.map(\.start) == [0, 105, 240])
    #expect(v1.map(\.duration) == [105, 105, 60])
    #expect(v1.map(\.sourceIn) == [60, 15, 300])
    func windows(_ p: Project) -> [String] {
        p.transitionWindows.map { "\($0.transition.from == nil ? "-" : "from") \($0.transition.to == nil ? "-" : "to") \(Int(($0.start * 30).rounded()))–\(Int(($0.end * 30).rounded()))" }.sorted()
    }
    #expect(windows(q) == windows(p))
    #expect(windows(q) == ["- to 0–15", "from - 270–300", "from to 105–135"])
}

// MARK: Final Cut Pro samples

/// Final Cut Pro 11 style export at 23.976 fps starting at 01:00:00:00: a compound clip, a clip with a
/// connected title and a secondary storyline, a cross dissolve into a 50% retimed clip with connected music,
/// and a gap holding a connected title.
private let fcp11 = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>

<fcpxml version="1.11">
    <resources>
        <format id="r1" name="FFVideoFormat1080p2398" frameDuration="1001/24000s" width="1920" height="1080" colorSpace="1-1-1 (Rec. 709)"/>
        <asset id="r2" name="A001_C003" uid="5A3F0E1B7C2D4E6F8A9B0C1D2E3F4A5B" start="3600s" duration="1201200/24000s" hasVideo="1" format="r1" videoSources="1" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000">
            <media-rep kind="original-media" sig="5A3F0E1B7C2D4E6F8A9B0C1D2E3F4A5B" src="file:///Volumes/Footage/A001_C003.mov">
                <bookmark>Ym9va21hcms=</bookmark>
            </media-rep>
            <metadata>
                <md key="com.apple.proapps.studio.rawToLogConversion" value="0"/>
            </metadata>
        </asset>
        <asset id="r3" name="B-Roll City" uid="9C8B7A6F5E4D3C2B1A0F9E8D7C6B5A49" start="0s" duration="1441440/24000s" hasVideo="1" format="r1" videoSources="1">
            <media-rep kind="original-media" src="Media/B-Roll%20City.mov"/>
        </asset>
        <asset id="r4" name="Music Bed" uid="0F1E2D3C4B5A69788796A5B4C3D2E1F0" start="0s" duration="120s" hasAudio="1" audioSources="1" audioChannels="2" audioRate="48000">
            <media-rep kind="original-media" src="file:///Users/editor/Music/bed.m4a"/>
        </asset>
        <effect id="r5" name="Basic Title" uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>
        <effect id="r6" name="Cross Dissolve" uid="FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265"/>
        <effect id="r8" name="Audio Crossfade" uid="FFAudioTransition"/>
        <media id="r7" name="Intro Compound" uid="b7Tn0y5bQ1aV3a0mG1D7kw">
            <sequence format="r1" duration="72072/24000s" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                <spine>
                    <asset-clip ref="r3" offset="0s" name="B-Roll City" start="120120/24000s" duration="48048/24000s" tcFormat="NDF"/>
                    <title ref="r5" offset="48048/24000s" name="Intro" start="86486400/24000s" duration="24024/24000s">
                        <text>
                            <text-style ref="ts3">Day One</text-style>
                        </text>
                        <text-style-def id="ts3">
                            <text-style font="Helvetica Neue" fontSize="120" fontFace="Medium" fontColor="1 1 1 1" alignment="center"/>
                        </text-style-def>
                    </title>
                </spine>
            </sequence>
        </media>
    </resources>
    <library location="file:///Users/editor/Movies/Untitled.fcpbundle/">
        <event name="Day 1" uid="7E1C4A0B-2D3F-4E5A-8B9C-0D1E2F3A4B5C">
            <project name="Rough Cut" uid="1A2B3C4D-5E6F-7A8B-9C0D-1E2F3A4B5C6D" modDate="2026-10-01 10:00:00 -0700">
                <sequence format="r1" duration="336336/24000s" tcStart="3600s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                    <spine>
                        <ref-clip ref="r7" offset="3600s" name="Intro Compound" duration="72072/24000s"/>
                        <asset-clip ref="r2" offset="86472072/24000s" name="A001_C003" start="86640240/24000s" duration="120120/24000s" format="r1" tcFormat="NDF" audioRole="dialogue">
                            <adjust-transform position="10 -5" scale="1.2 1.2" rotation="15"/>
                            <adjust-volume amount="-3dB"/>
                            <title ref="r5" lane="1" offset="86664264/24000s" name="Lower Third" start="86486400/24000s" duration="48048/24000s">
                                <param name="Position" key="9999/999166631/999166633/1/100/101" value="0 -380"/>
                                <text>
                                    <text-style ref="ts1">Jane Doe</text-style>
                                </text>
                                <text-style-def id="ts1">
                                    <text-style font="Helvetica" fontSize="63" fontFace="Bold" fontColor="1 1 1 1" alignment="center"/>
                                </text-style-def>
                            </title>
                            <spine lane="2" offset="86688288/24000s">
                                <asset-clip ref="r3" offset="86688288/24000s" name="B-Roll City" start="0s" duration="24024/24000s" tcFormat="NDF"/>
                                <asset-clip ref="r3" offset="86712312/24000s" name="B-Roll City" start="240240/24000s" duration="36036/24000s" tcFormat="NDF"/>
                            </spine>
                            <marker start="86652252/24000s" duration="1001/24000s" value="Good take"/>
                            <keyword start="86640240/24000s" duration="120120/24000s" value="interview, wide"/>
                        </asset-clip>
                        <transition name="Cross Dissolve" offset="86580180/24000s" duration="24024/24000s">
                            <filter-video ref="r6" name="Cross Dissolve">
                                <param name="Look" key="1" value="11 (Video)"/>
                            </filter-video>
                            <filter-audio ref="r8" name="Audio Crossfade"/>
                        </transition>
                        <asset-clip ref="r2" offset="86592192/24000s" name="A001_C003" start="86640240/24000s" duration="96096/24000s" format="r1" tcFormat="NDF" audioRole="dialogue">
                            <timeMap>
                                <timept time="3600s" value="3600s" interp="smooth2"/>
                                <timept time="3700s" value="3650s" interp="smooth2"/>
                            </timeMap>
                            <asset-clip ref="r4" lane="-1" offset="86640240/24000s" name="Music Bed" start="0s" duration="96096/24000s" audioRole="music">
                                <adjust-volume amount="-12dB"/>
                            </asset-clip>
                            <chapter-marker start="86688288/24000s" duration="1001/24000s" value="Chapter 2" posterOffset="11/24s"/>
                        </asset-clip>
                        <gap name="Gap" offset="86688288/24000s" start="86400000/24000s" duration="48048/24000s">
                            <title ref="r5" lane="1" offset="86412012/24000s" name="Outro" start="86486400/24000s" duration="24024/24000s">
                                <text>
                                    <text-style ref="ts2">Thanks for watching</text-style>
                                </text>
                                <text-style-def id="ts2">
                                    <text-style font="Helvetica Neue" fontSize="90" fontFace="Regular" fontColor="1 0.8 0 1" alignment="left"/>
                                </text-style-def>
                                <adjust-transform position="0 20"/>
                            </title>
                        </gap>
                    </spine>
                </sequence>
            </project>
        </event>
    </library>
</fcpxml>
"""

@Test func fcpxmlFromFinalCutPro11() throws {
    let r = try Importer.fcpxml(Data(fcp11.utf8), relativeTo: URL(fileURLWithPath: "/tmp/fcp-fixture/Rough Cut.fcpxml"))
    let p = r.project
    let fps = 24000.0 / 1001
    #expect(p.name == "Rough Cut")
    #expect(p.canvas.fps == 23.976 && p.canvas.width == 1920 && p.canvas.height == 1080)
    #expect(r.warnings == ["Keywords on A001_C003 not kept: interview, wide"])

    #expect(p.media.map(\.id) == ["a001-c003", "b-roll-city", "music-bed"])
    #expect(p.media.map(\.path) == ["/Volumes/Footage/A001_C003.mov", "/tmp/fcp-fixture/Media/B-Roll City.mov", "/Users/editor/Music/bed.m4a"])
    #expect(r.missingMedia == p.media.map(\.path))
    #expect(abs(p.media[0].duration - 50.05) < 1e-9 && p.media[0].fps == 23.976 && p.media[0].hasAudio && p.media[0].hasVideo)
    #expect(!p.media[1].hasAudio && p.media[1].width == 1920)
    #expect(!p.media[2].hasVideo && p.media[2].hasAudio && p.media[2].duration == 120)

    #expect(p.tracks.map(\.id) == ["V1", "V2", "V3", "A1"])
    #expect(shapes(p.tracks[0], fps: fps) == [
        Shape(kind: .sequence, media: "intro-compound", start: 0, duration: 72, sourceIn: 0, speed: 1),
        Shape(kind: .media, media: "a001-c003", start: 72, duration: 120, sourceIn: 240, speed: 1),
        Shape(kind: .media, media: "a001-c003", start: 192, duration: 96, sourceIn: 120, speed: 0.5),
    ])
    #expect(shapes(p.tracks[1], fps: fps) == [
        Shape(kind: .text, start: 96, duration: 48, sourceIn: 0, speed: 1, text: "Jane Doe"),
        Shape(kind: .text, start: 300, duration: 24, sourceIn: 0, speed: 1, text: "Thanks for watching"),
    ])
    #expect(shapes(p.tracks[2], fps: fps) == [
        Shape(kind: .media, media: "b-roll-city", start: 120, duration: 24, sourceIn: 0, speed: 1),
        Shape(kind: .media, media: "b-roll-city", start: 144, duration: 36, sourceIn: 240, speed: 1),
    ])
    #expect(shapes(p.tracks[3], fps: fps) == [Shape(kind: .media, media: "music-bed", start: 192, duration: 96, sourceIn: 0, speed: 1)])
    #expect(abs(p.tracks[3].clips[0].volume - pow(10, -12.0 / 20)) < 1e-9)

    let a = p.tracks[0].clips[1]
    #expect(abs(a.transform.x - 0.05625) < 1e-9 && abs(a.transform.y - 0.05) < 1e-9)
    #expect(a.transform.scale == 1.2 && a.transform.rotation == -15)
    #expect(abs(a.volume - pow(10, -3.0 / 20)) < 1e-9)

    let lower = try #require(p.tracks[1].clips[0].text)
    #expect(lower.font == "Helvetica" && lower.weight == 700 && abs(lower.size - 63.0 / 1080) < 1e-9)
    #expect(lower.x == 0.5 && abs(lower.y - (0.5 + 380.0 / 1080)) < 1e-9)
    let outro = try #require(p.tracks[1].clips[1].text)
    #expect(outro.font == "system" && outro.weight == 400 && outro.align == .left)
    #expect(abs(outro.y - 0.3) < 1e-9 && outro.color == RGBA(r: 1, g: 0.8, b: 0))

    let tr = try #require(p.transitions.first)
    #expect(p.transitions.count == 1)
    #expect(tr.type == "dissolve" && tr.align == .center && abs(tr.duration - 1.001) < 1e-9)
    #expect(tr.from == a.id && tr.to == p.tracks[0].clips[2].id)
    #expect(markers(p, fps: fps) == ["84 Good take", "240 Chapter 2"])

    let seq = try #require(p.sequences.first)
    #expect(p.sequences.count == 1 && seq.name == "Intro Compound")
    #expect(seq.tracks.count == 1)
    #expect(shapes(seq.tracks[0], fps: fps) == [
        Shape(kind: .media, media: "b-roll-city", start: 0, duration: 48, sourceIn: 120, speed: 1),
        Shape(kind: .text, start: 48, duration: 24, sourceIn: 0, speed: 1, text: "Day One"),
    ])
    try p.validate()
}

/// FCPXML 1.6 with the project at the root and `src` on the asset.
private let fcpBare = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.6">
    <resources>
        <format id="r1" frameDuration="100/2500s" width="1280" height="720"/>
        <asset id="r2" name="Clip One" src="file:///tmp/clip%20one.mov" start="0s" duration="20s" hasVideo="1" hasAudio="1" format="r1"/>
        <effect id="r9" name="Gaussian Blur" uid=".../Effects.localized/Blur.localized/Gaussian.localized/Gaussian.moef"/>
    </resources>
    <project name="Bare">
        <sequence format="r1" duration="10s" tcStart="0s">
            <spine>
                <clip name="Wrapped" offset="0s" start="2s" duration="4s" format="r1">
                    <video ref="r2" offset="0s" start="1s" duration="20s">
                        <audio ref="r2" lane="-1" offset="0s" start="1s" duration="20s" role="dialogue"/>
                    </video>
                    <adjust-crop mode="trim">
                        <trim-rect left="10" right="10" top="5"/>
                    </adjust-crop>
                    <audio-channel-source srcCh="1, 2" role="dialogue" enabled="0"/>
                    <filter-video ref="r9" name="Gaussian Blur"/>
                </clip>
                <transition name="Fade To Color" offset="3s" duration="2s"/>
                <asset-clip ref="r2" offset="4s" name="Ramp" start="10s" duration="4s">
                    <timeMap>
                        <timept time="0s" value="0s" interp="linear"/>
                        <timept time="10s" value="10s" interp="linear"/>
                        <timept time="20s" value="30s" interp="linear"/>
                    </timeMap>
                </asset-clip>
                <transition name="Page Curl" offset="8s" duration="1s"/>
                <asset-clip ref="r2" offset="8s" name="Off" start="0s" duration="2s" enabled="0"/>
            </spine>
        </sequence>
    </project>
</fcpxml>
"""

@Test func fcpxmlBareProjectWithClipsCropsRampsAndDisabledClips() throws {
    let r = try Importer.fcpxml(Data(fcpBare.utf8), relativeTo: nil)
    let p = r.project
    #expect(p.name == "Bare" && p.canvas.fps == 25 && p.canvas.width == 1280)
    #expect(p.media.map(\.id) == ["clip-one"] && p.media[0].path == "/tmp/clip one.mov")
    #expect(p.tracks.map(\.id) == ["V1", "V2"])
    #expect(p.tracks[1].hidden && !p.tracks[0].hidden)
    #expect(shapes(p.tracks[0], fps: 25) == [
        Shape(kind: .media, media: "clip-one", start: 0, duration: 100, sourceIn: 75, speed: 1),
        Shape(kind: .media, media: "clip-one", start: 100, duration: 100, sourceIn: 250, speed: 1.5),
    ])
    #expect(shapes(p.tracks[1], fps: 25) == [Shape(kind: .media, media: "clip-one", start: 200, duration: 50, sourceIn: 0, speed: 1)])

    let wrapped = p.tracks[0].clips[0]
    #expect(wrapped.name == "Wrapped" && wrapped.volume == 0)
    #expect(abs(wrapped.transform.crop.left - 0.05625) < 1e-9 && abs(wrapped.transform.crop.top - 0.05) < 1e-9 && wrapped.transform.crop.bottom == 0)

    #expect(p.transitions.count == 1)
    #expect(p.transitions[0].type == "dip" && p.transitions[0].align == .center && p.transitions[0].duration == 2)
    #expect(r.warnings.contains { $0.contains("Gaussian Blur") })
    #expect(r.warnings.contains { $0.contains("\"Ramp\" changes speed") })
    #expect(r.warnings.contains("Transition Page Curl imported as a dissolve"))
    #expect(r.warnings.contains { $0.hasPrefix("Dropped transition tr2") })
}

@Test func fcpxmlRejectsOtherDocuments() {
    #expect(throws: EditError.self) { try Importer.fcpxml(Data("not xml".utf8), relativeTo: nil) }
    #expect(throws: EditError.self) { try Importer.fcpxml(Data("<xmeml version=\"5\"/>".utf8), relativeTo: nil) }
    #expect(throws: EditError.self) { try Importer.fcpxml(Data("<fcpxml version=\"1.11\"><resources/></fcpxml>".utf8), relativeTo: nil) }
}

// MARK: OpenTimelineIO sample

private func rt(_ v: Int) -> String { #"{"OTIO_SCHEMA": "RationalTime.1", "rate": 24.0, "value": \#(v).0}"# }
private func tr(_ start: Int, _ duration: Int) -> String { #"{"OTIO_SCHEMA": "TimeRange.1", "start_time": \#(rt(start)), "duration": \#(rt(duration))}"# }
private func ref(_ url: String, _ start: Int, _ duration: Int) -> String {
    #"{"OTIO_SCHEMA": "ExternalReference.1", "target_url": "\#(url)", "available_range": \#(tr(start, duration)), "metadata": {}}"#
}

/// Resolve-style OTIO: Clip.1 with timecode-based ranges, a centered dissolve, a 50% LinearTimeWarp,
/// a nested stack, a clip without media, linked audio and a music track.
private let resolveOTIO = """
{
    "OTIO_SCHEMA": "Timeline.1", "name": "Resolve Cut", "metadata": {"Resolve_OTIO": {}},
    "global_start_time": \(rt(86400)),
    "tracks": {
        "OTIO_SCHEMA": "Stack.1", "name": "", "metadata": {}, "effects": [], "source_range": null,
        "markers": [{"OTIO_SCHEMA": "Marker.2", "name": "Act 2", "color": "BLUE", "marked_range": \(tr(144, 0)), "metadata": {}}],
        "children": [
            {"OTIO_SCHEMA": "Track.1", "name": "Video 1", "kind": "Video", "metadata": {}, "effects": [], "markers": [], "source_range": null, "children": [
                {"OTIO_SCHEMA": "Clip.1", "name": "A001.mov", "source_range": \(tr(86448, 96)), "effects": [], "metadata": {},
                 "media_reference": \(ref("file:///Volumes/Media/A001.mov", 86400, 2400)),
                 "markers": [{"OTIO_SCHEMA": "Marker.2", "name": "Smile", "color": "GREEN", "marked_range": \(tr(86460, 0)), "metadata": {}}]},
                {"OTIO_SCHEMA": "Transition.1", "name": "Cross Dissolve", "transition_type": "SMPTE_Dissolve", "in_offset": \(rt(12)), "out_offset": \(rt(12)), "metadata": {}},
                {"OTIO_SCHEMA": "Clip.1", "name": "B002.mov", "source_range": \(tr(240, 48)), "markers": [], "metadata": {},
                 "media_reference": \(ref("media/B002.mov", 0, 1200)),
                 "effects": [{"OTIO_SCHEMA": "LinearTimeWarp.1", "name": "", "effect_name": "", "time_scalar": 0.5, "metadata": {}}]},
                {"OTIO_SCHEMA": "Gap.1", "name": "", "source_range": \(tr(0, 24)), "effects": [], "markers": [], "metadata": {}},
                {"OTIO_SCHEMA": "Stack.1", "name": "Nest", "source_range": \(tr(12, 36)), "effects": [], "markers": [], "metadata": {}, "children": [
                    {"OTIO_SCHEMA": "Track.1", "name": "V", "kind": "Video", "source_range": null, "effects": [], "markers": [], "metadata": {}, "children": [
                        {"OTIO_SCHEMA": "Clip.1", "name": "B002.mov", "source_range": \(tr(0, 48)), "effects": [], "markers": [], "metadata": {},
                         "media_reference": \(ref("media/B002.mov", 0, 1200))}
                    ]}
                ]},
                {"OTIO_SCHEMA": "Clip.1", "name": "Missing", "source_range": \(tr(0, 24)), "markers": [], "metadata": {},
                 "media_reference": {"OTIO_SCHEMA": "MissingReference.1", "metadata": {}}, "effects": []}
            ]},
            {"OTIO_SCHEMA": "Track.1", "name": "Audio 1", "kind": "Audio", "metadata": {}, "effects": [], "markers": [], "source_range": null, "children": [
                {"OTIO_SCHEMA": "Clip.1", "name": "A001.mov", "source_range": \(tr(86448, 96)), "effects": [], "markers": [], "metadata": {},
                 "media_reference": \(ref("file:///Volumes/Media/A001.mov", 86400, 2400))}
            ]},
            {"OTIO_SCHEMA": "Track.1", "name": "Music", "kind": "Audio", "metadata": {}, "effects": [], "markers": [], "source_range": null, "children": [
                {"OTIO_SCHEMA": "Gap.1", "name": "", "source_range": \(tr(0, 24)), "effects": [], "markers": [], "metadata": {}},
                {"OTIO_SCHEMA": "Clip.1", "name": "music.wav", "source_range": \(tr(0, 192)), "effects": [], "markers": [], "metadata": {},
                 "media_reference": \(ref("file:///Volumes/Media/music.wav", 0, 4800))}
            ]}
        ]
    }
}
"""

@Test func otioFromResolve() throws {
    let r = try Importer.otio(Data(resolveOTIO.utf8), relativeTo: URL(fileURLWithPath: "/tmp/otio-fixture/", isDirectory: true))
    let p = r.project
    #expect(p.name == "Resolve Cut" && p.canvas.fps == 24)
    #expect(r.warnings == ["Clip Missing has no media file; left as a gap"])
    #expect(p.media.map(\.id) == ["a001", "b002", "music"])
    #expect(p.media.map(\.path) == ["/Volumes/Media/A001.mov", "/tmp/otio-fixture/media/B002.mov", "/Volumes/Media/music.wav"])
    #expect(p.media.map(\.hasAudio) == [true, false, true])
    #expect(p.media.map(\.hasVideo) == [true, true, false])
    #expect(p.media[0].duration == 100)
    #expect(r.missingMedia.contains("Missing"))

    // The linked audio of A001 folds into its video clip; its emptied track goes away.
    #expect(p.tracks.map(\.id) == ["V1", "A1"])
    #expect(p.tracks.map(\.name) == ["Video 1", "Music"])
    #expect(shapes(p.tracks[0], fps: 24) == [
        Shape(kind: .media, media: "a001", start: 0, duration: 96, sourceIn: 48, speed: 1),
        Shape(kind: .media, media: "b002", start: 96, duration: 48, sourceIn: 240, speed: 0.5),
        Shape(kind: .sequence, media: "nest", start: 168, duration: 36, sourceIn: 12, speed: 1),
    ])
    #expect(shapes(p.tracks[1], fps: 24) == [Shape(kind: .media, media: "music", start: 24, duration: 192, sourceIn: 0, speed: 1)])
    #expect(p.sequences.map(\.id) == ["nest"])
    #expect(shapes(p.sequences[0].tracks[0], fps: 24) == [Shape(kind: .media, media: "b002", start: 0, duration: 48, sourceIn: 0, speed: 1)])

    let t = try #require(p.transitions.first)
    #expect(p.transitions.count == 1)
    #expect(t.type == "dissolve" && t.align == .center && t.duration == 1)
    #expect(t.from == p.tracks[0].clips[0].id && t.to == p.tracks[0].clips[1].id)
    #expect(markers(p, fps: 24) == ["12 Smile", "144 Act 2"])
    try p.validate()
}

@Test func otioRejectsOtherDocuments() {
    #expect(throws: EditError.self) { try Importer.otio(Data("[]".utf8), relativeTo: nil) }
    #expect(throws: EditError.self) { try Importer.otio(Data(#"{"OTIO_SCHEMA": "Clip.2"}"#.utf8), relativeTo: nil) }
}

// MARK: EDL samples

/// Premiere Pro style CMX 3600 at 25 fps: six-digit events, AX reels named by comments, a dissolve,
/// an M2 speed change, an audio-only event, a fade up from black and a LOC marker.
private let premiereEDL = """
TITLE: Promo_v3
FCM: NON-DROP FRAME\r
\r
000001  AX       AA/V  C        00:00:10:00 00:00:14:00 01:00:00:00 01:00:04:00
* FROM CLIP NAME:  Interview_A.mov
* SOURCE FILE: /Volumes/Media/Interview_A.mov
* LOC: 01:00:02:12 YELLOW  Pickup line

000002  AX       V     C        00:00:14:00 00:00:14:00 01:00:04:00 01:00:04:00
000002  AX       V     D    012 00:01:00:00 00:01:03:00 01:00:04:00 01:00:07:00
* FROM CLIP NAME:  Interview_A.mov
* TO CLIP NAME:  Broll_City.mov
* SOURCE FILE: /Volumes/Media/Broll_City.mov

000003  AX       V     C        00:00:30:00 00:00:32:00 01:00:07:00 01:00:09:00
M2   AX       050.0                00:00:30:00
* FROM CLIP NAME:  Broll_City.mov

000004  AX       A     C        00:00:00:00 00:00:09:00 01:00:00:00 01:00:09:00
* FROM CLIP NAME:  Music.wav

000005  BL       V     C        00:00:00:00 00:00:00:00 01:00:10:00 01:00:10:00
000005  AX       V     D    024 00:00:05:00 00:00:07:00 01:00:10:00 01:00:12:00
* TO CLIP NAME:  Interview_A.mov
"""

@Test func edlFromPremiere() throws {
    let names = ["Interview_A.mov": "interview", "Broll_City.mov": "broll", "Music.wav": "music"]
    var asked: [String] = []
    let r = try Importer.edl(premiereEDL, fps: 25) { asked.append($0); return names[$0] }
    let p = r.project
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    #expect(p.name == "Promo_v3" && p.canvas.fps == 25)
    #expect(asked.first == "Interview_A.mov")
    #expect(p.tracks.map(\.id) == ["V1", "A1"])
    #expect(shapes(p.tracks[0], fps: 25) == [
        Shape(kind: .media, media: "interview", start: 0, duration: 100, sourceIn: 250, speed: 1),
        Shape(kind: .media, media: "broll", start: 100, duration: 75, sourceIn: 1500, speed: 1),
        Shape(kind: .media, media: "broll", start: 175, duration: 50, sourceIn: 750, speed: 2),
        Shape(kind: .media, media: "interview", start: 250, duration: 50, sourceIn: 125, speed: 1),
    ])
    #expect(shapes(p.tracks[1], fps: 25) == [Shape(kind: .media, media: "music", start: 0, duration: 225, sourceIn: 0, speed: 1)])
    let v1 = p.tracks[0].clips
    #expect(p.transitions.map(\.from) == [v1[0].id, nil])
    #expect(p.transitions.map(\.to) == [v1[1].id, v1[3].id])
    #expect(p.transitions.map(\.duration) == [0.48, 0.96])
    #expect(p.transitions.allSatisfy { $0.type == "dissolve" && $0.align == .start })
    #expect(markers(p, fps: 25) == ["62 Pickup line"])

    let interview = try #require(p.media.first { $0.id == "interview" })
    #expect(interview.path == "/Volumes/Media/Interview_A.mov" && interview.hasVideo && interview.hasAudio)
    #expect(abs(interview.duration - 14.48) < 1e-9)
    #expect(p.media.first { $0.id == "music" }.map { !$0.hasVideo && $0.hasAudio } == true)
    try p.validate()
}

@Test func edlDropFrameAndUnresolvedSources() throws {
    let edl = """
    TITLE: DF
    FCM: DROP FRAME

    001  AX       V     C        00:00:00;00 00:01:00;02 01:00:00;00 01:01:00;02
    * FROM CLIP NAME: long.mov

    002  TAPE9    V     C        00:00:00;00 00:00:01;00 01:01:00;02 01:01:01;02

    003  AX       V     C        00:00:00;00 00:00:01;00 01:01:01;02 01:01:02;02
    * FROM CLIP NAME: found.mov
    * SOURCE FILE: /nowhere/found.mov
    """
    let r = try Importer.edl(edl, fps: 29.97) { $0 == "long.mov" ? "long" : nil }
    let p = r.project
    let clips = p.tracks[0].clips
    #expect(clips.count == 2)
    #expect(abs(clips[0].duration - 1800 * 1001 / 30000.0) < 1e-9)
    #expect(clips[1].mediaId == "found" && abs(clips[1].start - 1830 * 1001 / 30000.0) < 1e-9)
    #expect(r.missingMedia == ["TAPE9", "/nowhere/found.mov"])
    #expect(r.warnings == ["Event 002: no media for TAPE9; left as a gap"])
    #expect(p.media.first { $0.id == "found" }?.path == "/nowhere/found.mov")

    #expect(EDLTimecode.string(107892 + 1800, nominal: 30, drop: true) == "01:01:00;02")
    #expect(EDLTimecode.parse("01:01:00;02", nominal: 30, drop: false)?.frames == 107892 + 1800)
    var out = Project(name: "NTSC", canvas: Canvas(fps: 29.97))
    out.media = [MediaAsset(id: "long", path: "/tmp/long.mov", name: "long", duration: 120, width: 1920, height: 1080, fps: 29.97, hasVideo: true, hasAudio: true)]
    out.tracks[0].clips = [Clip(id: "c", kind: .media, mediaId: "long", start: 0, duration: 1800 * 1001 / 30000.0)]
    let text = out.edl(title: "NTSC")
    #expect(text.contains("FCM: DROP FRAME"))
    #expect(text.contains("00:00:00;00 00:01:00;02 01:00:00;00 01:01:00;02"))
    #expect(throws: EditError.self) { try Importer.edl("TITLE: Empty\n", fps: 25) { _ in nil } }
}

// MARK: Subtitles

@Test func srtToleratesBomCrlfTagsAndMissingBlankLines() throws {
    let srt = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,500 X1:100 X2:200\r\n<i>Hello</i> {\\an8}there\r\n\r\n2\r\n00:00:03.000 --> 00:00:04,250\r\n<font color=\"#ff0\">Line one</font>\r\nLine &amp; two\r\n3\r\n00:00:05,000 --> 00:00:06,000\r\nNo blank line before me\r\n\r\n\r\n"
    let cues = try Importer.srt(srt)
    #expect(cues.map(\.start) == [1, 3, 5])
    #expect(cues.map(\.end) == [2.5, 4.25, 6])
    #expect(cues.map(\.text) == ["Hello there", "Line one\nLine & two", "No blank line before me"])
    #expect(throws: EditError.self) { try Importer.srt("just some words") }
    #expect(try Importer.srt("").isEmpty)
}

@Test func vttSkipsHeaderBlocksIdentifiersSettingsAndTags() throws {
    let vtt = """
    WEBVTT - Odd file
    Kind: captions

    STYLE
    ::cue { color: yellow }

    NOTE this is a comment
    spanning lines

    intro
    00:01.000 --> 00:02.000 align:start position:10%
    <v Roger Bingham>We are in New York City</v>

    00:00:02.500 --> 00:00:04.000 line:0
    <c.yellow>Sure,</c> <00:00:03.000>it's <b>great</b> &lt;3

    3
    00:00:05.000 --> 00:00:05.000
    zero length is skipped

    01:00:00.000 --> 01:00:01.500
      Late &amp; indented
    """
    let cues = try Importer.vtt(vtt)
    #expect(cues.map(\.start) == [1, 2.5, 3600])
    #expect(cues.map(\.end) == [2, 4, 3601.5])
    #expect(cues.map(\.text) == ["We are in New York City", "Sure, it's great <3", "Late & indented"])
    #expect(try Importer.vtt("WEBVTT\n\nNOTE nothing yet\n").isEmpty)
}
