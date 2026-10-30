import Foundation
import Testing
@testable import CutlineCore

@Test func trackedBoxesRoundTripAndThinStraightRuns() {
    // A steady move from 0 to 1 s, then a turn: the straight run needs only its ends.
    var samples: [TrackSample] = []
    for i in 0...15 {
        let t = Double(i) / 15
        samples.append(TrackSample(t: t, box: NormRect(x: 0.1 + 0.3 * t, y: 0.2, width: 0.1, height: 0.2), confidence: 1))
    }
    for i in 1...10 {
        let t = 1 + Double(i) / 15
        samples.append(TrackSample(t: t, box: NormRect(x: 0.4, y: 0.2 + 0.3 * (t - 1), width: 0.1, height: 0.2), confidence: 1))
    }
    let text = ObjectTrack.encodeBoxes(samples)
    let decoded = ObjectTrack.decodeBoxes(text)
    #expect(decoded.count == 3, "\(text)")
    for s in samples {
        let b = ObjectTrack.box(decoded, at: s.t)!
        #expect(abs(b.x - s.box.x) < 0.003 && abs(b.y - s.box.y) < 0.003)
    }
    #expect(ObjectTrack.box(decoded, at: 2) == nil)
    #expect(ObjectTrack.decodeBoxes("0 0.1 0.1 0.2 0.2;junk;1 0.2 0.1 0 0.2").count == 1)
}

@Test func catalogSearchFindsFinishingTools() {
    func search(_ q: String) -> [String] {
        EffectCatalog.listed.filter { t in
            t.id.contains(q) || t.summary.lowercased().contains(q) || t.params.contains { $0.name.contains(q) || $0.summary.lowercased().contains(q) }
        }.map(\.id)
    }
    #expect(search("noise").contains("video.denoise"))
    #expect(search("remove").contains("video.remove_object"))
    #expect(search("roto").contains("mask.object"))
    #expect(EffectCatalog.categories.contains { $0.0 == "video" })
    #expect(EffectCatalog.isTemporal("video.denoise") && !EffectCatalog.isTemporal("mask.object"))
    let nr = EffectCatalog.type("video.denoise")!
    #expect(nr.spec("temporal_frames")?.min == 1 && nr.spec("temporal_frames")?.max == 5)
    #expect(nr.spec("spatial")?.max == 1 && nr.spec("motion_threshold") != nil && nr.spec("strength") != nil)
    // Temporal effects take no limit windows: they render ahead of the compositor.
    #expect(nr.spec("limit") == nil)
}
