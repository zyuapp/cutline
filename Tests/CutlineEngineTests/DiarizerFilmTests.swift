import Foundation
import Testing
@testable import CutlineCore
@testable import CutlineEngine

/// The first four minutes of Tears of Steel (Blender Foundation, CC-BY), as transcribed by `Transcriber`:
/// "text@start-end" in seconds.
private let tearsOfSteelWords = """
    We@3.78-5.04 have@5.04-5.22 main@5.22-5.46 engine@5.46-5.76 start,@5.76-6.66 four,@6.66-7.86 three,@7.86-8.4
    two,@8.4-9.12 one...@9.12-11.58 You're@22.02-23.4 a@23.4-23.52 jerk,@23.52-24 Tom.@24-24.3 Look,@24.36-24.84
    Celia,@24.84-25.44 we@25.44-25.62 have@25.62-25.74 to@25.74-25.8 follow@25.8-25.92 our@25.92-26.16
    passion.@26.16-26.64 You@26.76-27.48 have@27.48-27.6 your@27.6-27.72 robotics,@27.72-28.26 and@28.26-28.38
    I@28.38-28.5 just@28.5-28.62 want@28.62-28.8 to@28.8-28.86 be@28.86-28.98 awesome@28.98-29.16 in@29.16-29.46
    space.@29.46-29.7 Why@29.76-30.96 don't@30.96-31.2 you@31.2-31.26 just@31.26-31.44 admit@31.44-31.8
    that@31.8-31.98 you're@31.98-32.28 freaked@32.28-32.94 out@32.94-33.18 by@33.18-33.36 my@33.36-33.48
    robot@33.48-33.66 hand?@33.66-34.26 I'm@34.32-35.1 not@35.1-35.16 freaked@35.16-35.34 out,@35.34-35.52
    but@35.52-35.58 it's...@35.58-36.84 All@37.5-37.68 right,@37.68-37.98 fine.@37.98-38.22 I'm@38.28-38.82
    freaked@38.82-39 out.@39-39.3 I'm@39.36-39.6 having@39.6-39.72 nightmares@39.72-40.2 that@40.2-40.32
    I'm@40.32-40.56 being@40.56-40.62 chased@40.62-40.8 by@40.8-41.04 these@41.04-41.16 giant,@41.16-41.58
    robotic@41.58-42.12 glasses.@42.12-42.54 Oh,@42.6-42.78 God,@42.78-43.2 we're@43.2-43.38 dumb.@43.38-43.62
    We're@43.74-44.52 done.@44.52-44.7 Robot's@49.02-50.76 memory@50.76-51.06 synced,@51.06-51.84 and...@51.84-53.04
    locked.@53.04-53.82 This@59.94-61.02 is@61.02-61.5 pretty@61.5-61.62 freaky.@61.62-62.04 Shouldn't@116.4-117.96
    you@117.96-118.02 be@118.02-118.14 down@118.14-118.2 there?@118.2-118.38 I@130.44-131.4 heard@131.4-131.52
    you@131.52-131.76 guys@131.76-131.88 talking@131.88-132.12 last@132.12-132.36 night.@132.36-132.54
    It's@135.6-136.56 not@136.56-136.68 my@136.68-136.86 fault,@136.86-137.1 you@137.1-137.22 know?@137.22-137.4
    Are@190.08-191.34 you@191.34-191.52 ready?@191.52-192.06 Of@192.12-192.78 course@192.78-192.84
    you're@192.84-193.2 ready.@193.2-193.38 You're@193.44-193.8 a@193.8-193.92 rock@193.92-194.04 star.@194.04-194.4
    How's@195.9-197.28 it@197.28-197.4 looking,@197.4-197.76 Barley?@197.76-198.18 We@198.3-198.96
    should@198.96-199.14 have@199.14-199.38 about@199.38-199.74 ten@199.74-199.92 minutes.@199.92-200.1
    Well,@200.52-201.9 that's@201.9-202.08 perfect.@202.08-202.32 We're@202.5-203.94 only@203.94-204 one.@204-204.3
    All@204.36-205.38 systems@205.38-205.86 go!@205.86-206.16 Yeah,@206.22-206.82 you,@206.82-207.06
    go!@207.06-207.48 Go!@207.6-208.26 Go,@208.8-210.3 your@210.3-210.42 ass!@210.42-211.08 Go,@211.2-211.56
    go,@211.56-211.8 go!@211.8-212.22 I@212.34-213.24 move@213.24-213.66 it!@213.66-214.02 Come@214.08-214.44
    on!@214.44-214.98 Go!@215.1-216.24 That's@222.3-223.02 nice.@223.02-223.2 Nothing@223.5-224.76 to@224.76-225
    worry@225-225.12 about.@225.12-225.36 Dumb.@225.42-226.08 Done.@229.56-231.3 There@231.42-232.08
    she@232.08-232.26 is.@232.26-232.5 Now,@232.62-234.06 you@234.06-235.38 love@235.38-235.68 her.@235.68-235.98
    She's@236.34-237.78 your@237.78-237.9 passion.@237.9-238.38 The...@238.5-240.001
"""

let tearsOfSteelPath = "/tmp/cl-real/downloads/tears_of_steel_720p.mp4"

func tearsOfSteelTranscript() -> Transcript {
    let words = tearsOfSteelWords.split(whereSeparator: \.isWhitespace).map { tok -> Word in
        let parts = tok.split(separator: "@")
        let times = parts[1].split(separator: "-").map { Double($0)! }
        return Word(text: String(parts[0]), start: times[0], end: times[1])
    }
    return Transcript(mediaId: "tos", locale: "en-US", words: words)
}

/// Sentences as numbered in the reference: words split at sentence ends and at gaps over 0.3 s.
private func referenceSentences(_ words: [Word]) -> [[Int]] {
    var out: [[Int]] = []
    var cur: [Int] = []
    for (i, w) in words.enumerated() {
        if let l = cur.last, w.start - words[l].end > 0.3 { out.append(cur); cur = [] }
        cur.append(i)
        if Diarizer.endsSentence(w.text) { out.append(cur); cur = [] }
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

/// Hand-built without listening, from who is addressed in the text, who is on screen and talking in the shot
/// (frames at each sentence), shot changes, and the median voiced pitch of each sentence measured with
/// `FrameFeatures` (Hz): 0 male voice-over on the title card, 155; 1 "You're a jerk, Tom." Celia, 290; 2–3 "Look,
/// Celia… awesome in space." Thom, 197–211; 4 "…my robot hand?" Celia, 283; 5–8 Thom's reply running on with
/// 0.06 s gaps, 238–297; 11–12 one line split by an ellipsis; 17–19 "Are you ready? Of course you're ready. You're a
/// rock star." one steady voice, 144–155; 20 "How's it looking, Barley?" not Barley and 243, against 17–19;
/// 21 "We should have about ten minutes." answers 20; 37–38 Barley talking to Thom in one two-shot. Sentences whose
/// speaker can't be told this way (the shouting at 26–31, lines over cutaways) are left out.
private let sameSpeaker = [(2, 3), (5, 6), (6, 7), (7, 8), (5, 8), (1, 4), (11, 12), (17, 18), (18, 19), (37, 38)]
private let differentSpeakers = [(0, 1), (1, 2), (1, 3), (4, 5), (4, 8), (2, 4), (19, 20), (20, 21), (17, 20)]

@Test(.enabled(if: FileManager.default.fileExists(atPath: tearsOfSteelPath)))
func tearsOfSteelTurnsFollowSentences() async throws {
    let transcript = tearsOfSteelTranscript()
    let words = transcript.words
    var samples = try await Diarizer.decodeMono(url: URL(fileURLWithPath: tearsOfSteelPath))
    samples = Array(samples.prefix(Int(240 * Diarizer.decodeRate)))
    let result = Diarizer.analyze(samples: samples, sampleRate: Diarizer.decodeRate, transcript: transcript)
    for s in result.segments {
        let text = words.filter { $0.start >= s.start - 0.01 && $0.end <= s.end + 0.01 }.map(\.text).joined(separator: " ")
        print(String(format: "tos %7.2f–%7.2f %@ %.2f %@", s.start, s.end, s.speaker, s.confidence ?? -1, text))
    }

    // Turns change only at sentence ends or real pauses, so no turn is a lone word from inside a sentence.
    for i in 1..<words.count where result.wordSpeakers[i] != result.wordSpeakers[i - 1] {
        #expect(Diarizer.endsSentence(words[i - 1].text) || words[i].start - words[i - 1].end >= Diarizer.turnPause, "turn inside a sentence at \(words[i].start)")
    }
    let sentences = referenceSentences(words)
    #expect(sentences.count == 40)
    let label = sentences.map { s in result.wordSpeakers[s[s.count / 2]] }
    let same = sameSpeaker.filter { label[$0.0] == label[$0.1] }.count
    let different = differentSpeakers.filter { label[$0.0] != label[$0.1] }.count
    let agreement = Double(same + different) / Double(sameSpeaker.count + differentSpeakers.count)
    print("tos speakers \(result.speakers.count), turns \(result.segments.count), same \(same)/\(sameSpeaker.count), different \(different)/\(differentSpeakers.count)")
    #expect((2...6).contains(result.speakers.count))
    #expect(agreement >= 0.75)
    #expect(result.segments.allSatisfy { ($0.confidence ?? -1) >= 0 && ($0.confidence ?? 2) <= 1 })
}

@Test func talkingFacesLinkSentences() {
    let units = [
        Diarizer.Segment(start: 0, end: 2, words: [0]), Diarizer.Segment(start: 2.2, end: 4, words: [1]),
        Diarizer.Segment(start: 4.2, end: 6, words: [2]), Diarizer.Segment(start: 6.2, end: 8, words: [3]),
    ]
    let spans = [
        ActiveSpeakers.Span(start: 0, end: 2, speaker: "S1", face: 1, activity: 0.04, margin: 3),
        ActiveSpeakers.Span(start: 2.2, end: 4, speaker: "S1", face: 2, activity: 0.05, margin: 2.5),
        ActiveSpeakers.Span(start: 4.2, end: 6, speaker: "S1", face: 1, activity: 0.015),
        ActiveSpeakers.Span(start: 6.2, end: 8, speaker: "S1", face: 3, activity: 0.05, margin: 1.1),
    ]
    let tracks = [FaceTrack(id: 1, samples: [FaceSample(t: 0, box: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)), FaceSample(t: 8, box: NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3))]),
                  FaceTrack(id: 2, samples: [FaceSample(t: 0, box: NormRect(x: 0.6, y: 0.1, width: 0.2, height: 0.3)), FaceSample(t: 8, box: NormRect(x: 0.6, y: 0.1, width: 0.2, height: 0.3))])]
    let (faceOf, cannot) = Diarizer.faceLinks(ActiveSpeakers(mediaId: "m", spans: spans, speakerFaces: [:]), tracks: tracks, units: units)
    // Faint lips and a face barely ahead of another don't count.
    #expect(faceOf == [1, 2, nil, nil])
    #expect(cannot == [Diarizer.Pair(0, 1)])
}

@Test(.enabled(if: voicesAvailable(["Samantha", "Karen"])))
func faceEvidenceKeepsVoicesApartAndTogether() async throws {
    let scene = try await spokenScene(voices: ["Samantha", "Karen"])
    let words = scene.transcript.words
    // Each line's talker is seen: Samantha as face 1, Karen as face 2, both on screen throughout.
    var spans: [ActiveSpeakers.Span] = []
    var i = 0
    while i < words.count {
        var j = i
        while j + 1 < words.count, scene.truth[j + 1] == scene.truth[i] { j += 1 }
        spans.append(.init(start: words[i].start, end: words[j].end, speaker: "S1", face: scene.truth[i] + 1, activity: 0.05, margin: 3))
        i = j + 1
    }
    let end = words.last!.end
    let box = NormRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)
    let tracks = [FaceTrack(id: 1, samples: [FaceSample(t: 0, box: box), FaceSample(t: end, box: box)]), FaceTrack(id: 2, samples: [FaceSample(t: 0, box: box), FaceSample(t: end, box: box)])]
    let active = ActiveSpeakers(mediaId: "say", spans: spans, speakerFaces: [:])
    let result = Diarizer.analyze(samples: scene.samples, sampleRate: Diarizer.decodeRate, transcript: scene.transcript, faces: active, faceTracks: tracks)
    #expect(result.speakers.count == 2)
    #expect(wordAccuracy(result, truth: scene.truth, voices: 2) >= 0.9)
    let relabelled = ActiveSpeakerDetector.relabel(active, with: result, transcript: scene.transcript)
    #expect(Set(relabelled.speakerFaces.values) == [1, 2])

    let single = try await spokenScene(voices: ["Samantha"])
    let one = ActiveSpeakers(mediaId: "say", spans: [.init(start: 0, end: single.transcript.words.last!.end, speaker: "S1", face: 1, activity: 0.05)], speakerFaces: [:])
    #expect(Diarizer.analyze(samples: single.samples, sampleRate: Diarizer.decodeRate, transcript: single.transcript, faces: one, faceTracks: [tracks[0]]).speakers == ["S1"])
}

@Test(.enabled(if: voicesAvailable(["Samantha", "Daniel"])))
func turnsCarryConfidence() async throws {
    let scene = try await spokenScene(voices: ["Samantha", "Daniel"])
    let result = Diarizer.analyze(samples: scene.samples, sampleRate: Diarizer.decodeRate, transcript: scene.transcript)
    let scores = result.segments.compactMap(\.confidence)
    #expect(scores.count == result.segments.count)
    #expect(scores.allSatisfy { (0...1).contains($0) })
    // Distinct voices in whole sentences are told apart with confidence.
    #expect(scores.sorted()[scores.count / 2] >= 0.8)
}
