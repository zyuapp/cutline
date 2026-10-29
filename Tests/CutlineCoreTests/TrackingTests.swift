import Foundation
import Testing
@testable import CutlineCore

private func sample(_ t: Seconds, x: Double, conf: Double = 1) -> TrackSample {
    TrackSample(t: t, box: NormRect(x: x, y: 0.2, width: 0.1, height: 0.2), confidence: conf)
}

@Test func trackBoxInterpolatesBetweenSamples() throws {
    let track = ObjectTrack(id: "t1", mediaId: "m1", label: "ball", samples: [sample(1, x: 0.5), sample(0, x: 0.1), sample(2, x: 0.5)])
    #expect(track.samples.map(\.t) == [0, 1, 2])
    #expect(track.range == TimeRange(0, 2))
    let mid = try #require(track.box(at: 0.25))
    #expect(abs(mid.x - 0.2) < 1e-9 && abs(mid.width - 0.1) < 1e-9)
    #expect(track.box(at: 1)?.x == 0.5)
    #expect(track.box(at: 1.5)?.x == 0.5)
    #expect(track.box(at: -0.01) == nil)
    #expect(track.box(at: 2.01) == nil)
    #expect(ObjectTrack(id: "e", mediaId: "m", label: "", samples: []).box(at: 0) == nil)
}

@Test func trackLostSpansCoverLowConfidenceRuns() {
    let track = ObjectTrack(id: "t1", mediaId: "m1", label: "car", samples: [
        sample(0, x: 0.1), sample(0.5, x: 0.1, conf: 0.2), sample(1, x: 0.1, conf: 0.1), sample(1.5, x: 0.1, conf: 0.9),
        sample(2, x: 0.1), sample(2.5, x: 0.1, conf: 0),
    ])
    #expect(track.lost == [TimeRange(0.5, 1.5), TimeRange(2.5, 2.5)])
}

@Test func smoothingRemovesJitterAndKeepsSteadyMotion() {
    let steady = (0..<40).map { sample(Double($0) / 10, x: 0.3) }
    for s in ObjectTrack.smoothed(steady, sigma: 0.3) { #expect(abs(s.box.x - 0.3) < 1e-9) }

    let jittery = (0..<40).map { sample(Double($0) / 10, x: 0.3 + ($0 % 2 == 0 ? 0.02 : -0.02)) }
    let smooth = ObjectTrack.smoothed(jittery, sigma: 0.2)
    #expect(smooth.count == jittery.count)
    #expect(smooth.map(\.t) == jittery.map(\.t))
    for s in smooth.dropFirst(5).dropLast(5) { #expect(abs(s.box.x - 0.3) < 0.003) }

    let outlier = (0..<21).map { sample(Double($0) / 10, x: $0 == 10 ? 0.9 : 0.3, conf: $0 == 10 ? 0.01 : 1) }
    #expect(abs(ObjectTrack.smoothed(outlier, sigma: 0.2)[10].box.x - 0.3) < 0.01)
    #expect(ObjectTrack.smoothed(jittery, sigma: 0) == jittery)
}
