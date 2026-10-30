import Foundation
import Testing
@testable import CutlineCore

// MARK: Fixture

private let rates: [Double] = [24000.0 / 1001, 25, 30000.0 / 1001]

/// V1: c1 J-cuts into c2 (sound 12 frames early) with a 6-frame audio-only crossfade on the sound cut; c2 L-cuts into c3
/// (sound 12 frames late); c3 dissolves into c4 with a crossfade (one second); c4 dissolves into c5, picture only.
/// A1: two music clips crossfaded for one second. `align` places the two one-second transitions.
private func splitProject(fps: Double, align: TransitionAlign = .center) -> Project {
    var p = Project(name: "Splits", canvas: Canvas(fps: fps))
    let grid = FrameGrid(fps: fps)
    let n = Int(grid.rate.rounded())
    func t(_ frames: Int) -> Seconds { Double(frames * grid.num) / Double(grid.den) }
    p.media = [
        MediaAsset(id: "a", path: "/tmp/exact/a.mov", name: "a", duration: 120, width: 1920, height: 1080, fps: fps, hasVideo: true, hasAudio: true),
        MediaAsset(id: "b", path: "/tmp/exact/b.mov", name: "b", duration: 120, width: 1920, height: 1080, fps: fps, hasVideo: true, hasAudio: true),
        MediaAsset(id: "m", path: "/tmp/exact/m.wav", name: "m", duration: 120, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: true),
    ]
    p.tracks[0].clips = [
        Clip(id: "c1", kind: .media, mediaId: "a", start: t(0), duration: t(4 * n), sourceIn: t(10 * n)),
        Clip(id: "c2", kind: .media, mediaId: "b", start: t(4 * n), duration: t(4 * n), sourceIn: t(20 * n)),
        Clip(id: "c3", kind: .media, mediaId: "a", start: t(8 * n), duration: t(4 * n), sourceIn: t(40 * n)),
        Clip(id: "c4", kind: .media, mediaId: "b", start: t(12 * n), duration: t(4 * n), sourceIn: t(60 * n)),
        Clip(id: "c5", kind: .media, mediaId: "a", start: t(16 * n), duration: t(3 * n), sourceIn: t(80 * n)),
    ]
    try! p.splitEdit(left: "c1", right: "c2", offset: t(12))
    try! p.splitEdit(left: "c2", right: "c3", offset: -t(12))
    p.tracks[1].clips = [
        Clip(id: "m1", kind: .media, mediaId: "m", start: t(0), duration: t(9 * n), sourceIn: t(5 * n)),
        Clip(id: "m2", kind: .media, mediaId: "m", start: t(9 * n), duration: t(10 * n), sourceIn: t(40 * n)),
    ]
    p.transitions = [
        Transition(id: "tr1", from: "c1", to: "c2", type: "dissolve", duration: t(6), align: .start, part: .audio),
        Transition(id: "tr2", from: "c3", to: "c4", type: "dissolve", duration: t(n), align: align),
        Transition(id: "tr3", from: "c4", to: "c5", type: "dissolve", duration: t(10), align: .start, part: .video),
        Transition(id: "tr4", from: "m1", to: "m2", type: "dissolve", duration: t(n), align: align, part: .audio),
    ]
    try! p.validate()
    for tr in p.transitions { try! p.checkTransition(tr) }
    return p
}

private func frames(_ t: Seconds, _ grid: FrameGrid) -> Int { grid.frames(t) }

/// Every clip's timeline range, source range and split, and every transition (ends, type, duration, alignment, part),
/// are the same frames in `q`, with no fraction of a frame between them.
private func expectExact(_ p: Project, _ q: Project, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let grid = FrameGrid(fps: p.canvas.fps)
    #expect(abs(q.canvas.fps - p.canvas.fps) < 1e-3, "\(label) fps \(q.canvas.fps)", sourceLocation: sourceLocation)
    func same(_ a: Seconds, _ b: Seconds) -> Bool { abs(a - b) < 1e-6 }
    var ids: [String: String] = [:]
    for kind in [TrackKind.video, .audio] {
        let mine = p.tracks.filter { $0.kind == kind && !$0.clips.isEmpty }, theirs = q.tracks.filter { $0.kind == kind && !$0.clips.isEmpty }
        #expect(mine.count == theirs.count, "\(label) \(kind) tracks \(theirs.map(\.id))", sourceLocation: sourceLocation)
        for (s, t) in zip(mine, theirs) {
            #expect(s.clips.count == t.clips.count, "\(label) \(s.id) has \(t.clips.count) clips", sourceLocation: sourceLocation)
            for (a, b) in zip(s.clips, t.clips) {
                ids[a.id] = b.id
                let what = "\(label) \(a.id)"
                #expect(b.mediaId == a.mediaId, "\(what) media \(b.mediaId ?? "nil")", sourceLocation: sourceLocation)
                #expect(same(b.start, a.start) && same(b.duration, a.duration), "\(what) at \(frames(b.start, grid))+\(frames(b.duration, grid)), not \(frames(a.start, grid))+\(frames(a.duration, grid))", sourceLocation: sourceLocation)
                #expect(same(b.sourceIn, a.sourceIn) && b.speed == a.speed, "\(what) source \(frames(b.sourceIn, grid)) at \(b.speed)×, not \(frames(a.sourceIn, grid))", sourceLocation: sourceLocation)
                #expect(same(b.audioLead, a.audioLead) && same(b.audioLag, a.audioLag), "\(what) lead/lag \(frames(b.audioLead, grid))/\(frames(b.audioLag, grid)), not \(frames(a.audioLead, grid))/\(frames(a.audioLag, grid))", sourceLocation: sourceLocation)
                #expect(same(b.audioSourceRange.start, a.audioSourceRange.start) && same(b.audioSourceRange.end, a.audioSourceRange.end), "\(what) sound source", sourceLocation: sourceLocation)
                #expect(b.volume == a.volume, "\(what) volume \(b.volume)", sourceLocation: sourceLocation)
            }
        }
    }
    func key(_ tr: Transition, _ map: [String: String]) -> String {
        "\(tr.from.flatMap { map[$0] ?? $0 } ?? "-")>\(tr.to.flatMap { map[$0] ?? $0 } ?? "-")"
    }
    #expect(q.transitions.count == p.transitions.count, "\(label) transitions \(q.transitions.map { "\(key($0, [:])) \($0.part)" })", sourceLocation: sourceLocation)
    for a in p.transitions {
        guard let b = q.transitions.first(where: { key($0, [:]) == key(a, ids) }) else {
            Issue.record("\(label) lost \(a.id) \(key(a, ids))", sourceLocation: sourceLocation)
            continue
        }
        #expect(b.type == a.type && b.part == a.part, "\(label) \(a.id) is a \(b.part) \(b.type)", sourceLocation: sourceLocation)
        #expect(same(b.duration, a.duration) && b.align == a.align && b.cutOffset == a.cutOffset, "\(label) \(a.id) \(frames(b.duration, grid)) frames \(b.align) \(b.cutOffset.map { "\($0)" } ?? "")", sourceLocation: sourceLocation)
    }
    do {
        try q.validate()
        for tr in q.transitions { try q.checkTransition(tr) }
    } catch {
        Issue.record("\(label): \(error)", sourceLocation: sourceLocation)
    }
}

// MARK: Round trips

@Test(arguments: rates) func xmemlRoundTripIsFrameExact(fps: Double) throws {
    let p = splitProject(fps: fps)
    let xml = p.xmeml()
    // Each sound clipitem plays as many source frames as it lasts.
    let doc = try XMLDocument(xmlString: xml, options: [])
    for case let item as XMLElement in try doc.nodes(forXPath: "//audio//clipitem") {
        func n(_ k: String) -> Int? { item.elements(forName: k).first?.stringValue.flatMap { Int($0) } }
        guard let s = n("start"), let e = n("end"), let i = n("in"), let o = n("out"), s >= 0, e >= 0 else { continue }
        #expect(o - i == e - s, "\(item.attribute(forName: "id")?.stringValue ?? "") plays \(o - i) source frames over \(e - s)")
    }
    #expect(try doc.nodes(forXPath: "//audio//transitionitem").count == 3)
    let r = try Importer.xmeml(Data(xml.utf8), relativeTo: nil)
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    expectExact(p, r.project, "xmeml \(fps)")
}

@Test(arguments: rates) func fcpxmlRoundTripIsFrameExact(fps: Double) throws {
    let p = splitProject(fps: fps)
    let xml = p.fcpxml()
    let doc = try XMLDocument(xmlString: xml, options: [])
    let transitions = try doc.nodes(forXPath: "//transition").compactMap { $0 as? XMLElement }
    #expect(transitions.count == 4)
    #expect(transitions.filter { $0.elements(forName: "filter-audio").count == 1 }.count == 3)
    #expect(transitions.filter { $0.elements(forName: "filter-video").count == 1 }.count == 2)
    let r = try Importer.fcpxml(Data(xml.utf8), relativeTo: nil)
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    expectExact(p, r.project, "fcpxml \(fps)")
}

@Test(arguments: rates) func otioRoundTripIsFrameExact(fps: Double) throws {
    let p = splitProject(fps: fps)
    let r = try Importer.otio(p.otio(), relativeTo: nil)
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    expectExact(p, r.project, "otio \(fps)")
}

@Test(arguments: rates) func edlRoundTripIsFrameExact(fps: Double) throws {
    // CMX dissolves start at their edit, so start-aligned transitions come back as they are.
    let p = splitProject(fps: fps, align: .start)
    let edl = p.edl(title: "Splits")
    #expect(edl.contains(" D    "))
    let r = try Importer.edl(edl, into: p)
    #expect(r.warnings.isEmpty, "\(r.warnings)")
    expectExact(p, r.project, "edl \(fps)")
    expectNoOverlaps(edl)
}

/// A centered transition comes back from an EDL starting at its edit: the same frames play, the cut moves to its start.
@Test(arguments: rates) func edlCenteredTransitionsKeepTheirWindows(fps: Double) throws {
    let p = splitProject(fps: fps)
    let edl = p.edl(title: "Splits")
    expectNoOverlaps(edl)
    let q = try Importer.edl(edl, into: p).project
    try q.validate()
    let grid = FrameGrid(fps: fps)
    func windows(_ x: Project) -> [String] {
        x.transitions.compactMap { tr in
            guard let w = try? (tr.hasVideo ? x.window(tr) : x.audioWindow(tr)) else { return nil }
            let a = try? x.audioWindow(tr)
            return "\(tr.part) \(grid.frames(w.start))-\(grid.frames(w.end)) sound \(a.map { "\(grid.frames($0.start))-\(grid.frames($0.end))" } ?? "")"
        }.sorted()
    }
    #expect(windows(q) == windows(p))
    for tr in q.transitions { try q.checkTransition(tr) }
}

/// No two events on one EDL channel overlap in record time.
private func expectNoOverlaps(_ edl: String, sourceLocation: SourceLocation = #_sourceLocation) {
    var byChannel: [String: [(r0: Int, r1: Int, event: String)]] = [:]
    let lines = edl.components(separatedBy: "\n")
    func tc(_ s: String) -> Int? {
        let p = s.split(whereSeparator: { ":;".contains($0) }).compactMap { Int($0) }
        return p.count == 4 ? ((p[0] * 60 + p[1]) * 60 + p[2]) * 100 + p[3] : nil
    }
    for (i, line) in lines.enumerated() {
        let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 8, tokens[0].allSatisfy(\.isNumber) else { continue }
        var names = tokens[2].split(separator: "/").flatMap { $0 == "AA" ? ["A1", "A2"] : $0 == "B" ? ["V", "A1", "A2"] : [$0 == "A" ? "A1" : String($0)] }
        if tokens[2] == "NONE" { names = lines.dropFirst(i + 1).first { $0.hasPrefix("AUD") }.map { $0.split(separator: " ").dropFirst().map { "A\($0)" } } ?? [] }
        guard let r0 = tc(tokens[tokens.count - 2]), let r1 = tc(tokens[tokens.count - 1]), r1 > r0 else { continue }
        for ch in names { byChannel[ch, default: []].append((r0, r1, tokens[0])) }
    }
    for (ch, list) in byChannel {
        let sorted = list.sorted { $0.r0 < $1.r0 }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.r1 > b.r0 {
            Issue.record("Events \(a.event) and \(b.event) overlap on \(ch)", sourceLocation: sourceLocation)
        }
    }
}

/// Sound that overlaps without a crossfade goes on channels of its own rather than overlapping on one.
@Test func edlKeepsOverlappingSoundOnSeparateChannels() throws {
    var p = splitProject(fps: 25, align: .start)
    p.transitions = []
    // c2's sound runs 10 frames into c3's, which starts on time: both play there.
    p.tracks[0].clips[2].audioLead = 0
    try p.validate()
    let edl = p.edl(title: "Overlap")
    expectNoOverlaps(edl)
    let q = try Importer.edl(edl, into: p).project
    try q.validate()
    let v = q.tracks[0].clips
    #expect(v.map { FrameGrid(fps: 25).frames($0.audioLag) } == [-12, 12, 0, 0, 0])
    #expect(v.map { FrameGrid(fps: 25).frames($0.audioLead) } == [0, 12, 0, 0, 0])
}

/// What an export renders (crossfades written into the clips' sound) still makes an EDL that reads back.
@Test func edlOfResolvedCrossfadesReadsBack() throws {
    let p = splitProject(fps: 25).resolvingAudioTransitions()
    let edl = p.edl(title: "Resolved")
    expectNoOverlaps(edl)
    let q = try Importer.edl(edl, into: p).project
    try q.validate()
    // As timeline_import brings it in.
    var host = splitProject(fps: 25)
    try host.adoptTimeline(try Importer.edl(edl, fps: 25).project, name: "From EDL")
    try host.validate()
}
