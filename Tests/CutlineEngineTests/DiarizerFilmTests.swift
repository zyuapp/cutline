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

/// The whole film (12 min) as transcribed by `Transcriber` in a separate run from the excerpt above.
private let tearsOfSteelFilmWords = """
    We@3.72-4.98 have@4.98-5.16 main@5.16-5.46 engine@5.46-5.7 start,@5.7-6.6 four,@6.6-7.8 three,@7.8-8.34
    two,@8.34-9.12 one...@9.12-11.58 You're@21.96-23.34 a@23.34-23.46 jerk,@23.46-23.88 Tom.@23.88-24.24
    Look,@24.3-24.78 Celia,@24.78-25.38 we@25.38-25.56 have@25.56-25.68 to@25.68-25.74 follow@25.74-25.86
    our@25.86-26.1 passions.@26.1-26.94 You@27.06-27.42 have@27.42-27.54 your@27.54-27.66 robotics,@27.66-28.2
    and@28.2-28.38 I@28.38-28.5 just@28.5-28.62 want@28.62-28.74 to@28.74-28.86 be@28.86-28.92 awesome@28.92-29.1
    in@29.1-29.4 space.@29.4-29.64 Why@29.7-30.9 don't@30.9-31.14 you@31.14-31.2 just@31.2-31.38 admit@31.38-31.74
    that@31.74-31.92 you're@31.92-32.22 freaked@32.22-32.88 out@32.88-33.12 by@33.12-33.3 my@33.3-33.42
    robe@33.42-33.72 on@33.72-33.96 hand?@33.96-34.62 I'm@34.68-35.04 not@35.04-35.1 freed@35.1-35.28
    out,@35.28-35.52 but@35.52-35.58 it's...@35.58-36.84 All@37.44-37.62 right,@37.62-37.92 fine.@37.92-38.16
    I'm@38.22-38.76 freaked@38.76-38.94 out.@38.94-39.24 I'm@39.3-39.54 having@39.54-39.66 nightmares@39.66-40.14
    that@40.14-40.26 I'm@40.26-40.5 being@40.5-40.56 chased@40.56-40.74 by@40.74-40.98 these@40.98-41.1
    giant@41.1-41.4 robotic@41.4-42.06 glasses.@42.06-42.48 Oh,@42.54-42.72 God,@42.72-43.14 you're@43.14-43.32
    dumb.@43.32-43.62 We're@43.68-44.52 done.@44.52-44.7 Robot's@48.96-50.7 memory@50.7-51 synced,@51-51.84
    and...@51.84-52.62 locked.@52.62-53.82 Is@59.94-61.02 this@61.02-61.5 pretty@61.5-61.62 freaky?@61.62-61.98
    Shouldn't@116.4-117.9 you@117.9-117.96 be@117.96-118.08 down@118.08-118.14 there?@118.14-118.32 I@130.32-131.58
    heard@131.58-131.7 you@131.7-131.88 guys@131.88-132 talking@132-132.18 last@132.18-132.48 night.@132.48-132.9
    It's@136.02-136.62 not@136.62-136.74 my@136.74-136.86 fault,@136.86-137.22 you@137.22-137.34 know?@137.34-137.7
    Are@190.02-191.28 you@191.28-191.52 ready?@191.52-191.76 Of@191.82-193.02 course,@193.02-193.14
    you're@193.14-193.32 ready.@193.32-193.5 You're@193.56-193.8 a@193.8-193.86 rock@193.86-193.98
    star.@193.98-194.34 How's@195.84-197.28 it@197.28-197.34 looking,@197.34-197.7 Barley?@197.7-198.12
    We@198.18-198.96 should@198.96-199.14 have@199.14-199.38 about@199.38-199.56 ten@199.56-199.86
    minutes.@199.86-200.04 Well,@200.46-201.84 that's@201.84-202.08 perfect.@202.08-202.26 We're@202.44-203.88
    only@203.88-204 one!@204-204.54 All@204.6-205.32 systems@205.32-205.74 go!@205.74-206.1 Yeah,@206.16-206.76
    you,@206.76-207 go!@207-207.3 Go!@207.36-208.56 Move,@208.8-210.3 your@210.3-210.42 ass!@210.42-211.14
    Go,@211.2-211.5 go,@211.5-211.8 go!@211.8-212.34 I@212.4-213.18 love@213.18-213.6 it!@213.6-213.96
    Go@214.02-214.44 on!@214.44-214.92 Go!@214.98-216.3 That's@222.36-222.96 nice.@222.96-223.2 Nothing@223.5-224.76
    to@224.76-224.94 worry@224.94-225.06 about.@225.06-225.3 Done.@225.36-226.02 Dumb.@229.38-230.88
    There@231-232.08 she@232.08-232.2 is.@232.2-232.44 Now.@232.5-234 You@234.36-235.38 love@235.38-235.62
    her.@235.62-235.92 She's@236.28-237.66 your@237.66-237.84 passion.@237.84-238.38 The@238.44-239.22
    Be@240.42-241.68 honest.@241.68-242.22 Be@242.82-243.96 tender.@243.96-244.56 Reminder,@244.68-246.48
    what@246.48-247.2 love@247.2-247.74 is.@247.74-248.28 And...@291.66-294.18 action!@294.18-294.96
    Memory@295.62-297 override@297-297.66 in@297.66-297.78 progress.@297.78-298.08 You're@298.2-299.52
    in@299.52-299.7 jerk,@299.7-300.24 Tom.@300.24-300.66 Oh,@300.84-302.22 I'm@302.22-302.46 sorry.@302.46-302.64
    Sorry.@302.76-303.48 Sorry.@303.48-303.78 Sorry.@303.84-305.04 Sorry.@305.04-305.4 Look,@314.64-316.08
    Celia,@316.08-316.8 we@316.8-318.42 have@318.42-318.6 to@318.6-318.72 follow@318.72-318.9 our@318.9-319.2
    passions.@319.2-319.74 You@320.16-321.42 have@321.42-321.6 your@321.6-321.72 robotics.@321.72-322.38
    And@324-325.26 I@325.26-325.92 just@325.92-326.1 want@326.1-326.28 to@326.28-326.46 be@326.46-326.52
    awesome@326.52-326.76 in@326.76-327.06 space.@327.06-327.3 Get@337.86-339.12 it@339.12-339.36
    coming.@339.36-339.84 Two@339.9-340.38 minutes@340.38-340.5 left.@340.5-340.74 Two@340.8-341.58
    minutes.@341.58-341.94 Speed@342-343.14 it@343.14-343.26 up,@343.26-343.5 Thorn.@343.5-343.98
    Leave@344.04-345.12 it,@345.12-345.42 CCO!@345.42-346.08 Why@346.14-347.04 don't@347.04-347.34 you@347.34-347.4
    just@347.4-347.64 admit@347.64-347.94 that@347.94-348.12 you're@348.12-348.36 freaked@348.36-348.6
    out@348.6-348.78 by@348.78-348.96 my@348.96-349.08 robot@349.08-349.2 hand?@349.2-349.68 Listen,@355.74-357.12
    Celia.@357.12-357.72 I@357.9-358.08 was@358.08-358.32 young.@358.32-358.98 And@360-360.18 a@360.18-360.36
    dick.@360.36-360.84 But@360.9-361.32 there's@361.32-361.62 no@361.62-361.68 reason@361.68-361.8 to@361.8-361.98
    destroy@361.98-362.28 the@362.28-362.46 world.@362.46-363.9 Why@363.96-365.1 does@365.1-365.28 she@365.28-365.46
    do@365.46-365.58 this?@365.58-365.88 Have@365.94-367.14 we@367.14-367.38 already@367.38-367.8 tried@367.8-367.98
    that@367.98-368.22 one?@368.22-368.58 Abort!@371.7-372.66 No!@378.78-379.92 No!@379.92-382.62 You@382.62-383.64
    broke@383.64-384 my@384-384.24 heart.@384.24-384.48 No.@385.08-386.7 You@386.7-387.24 forgot@387.24-387.54
    me@387.54-387.84 on@387.84-387.96 Earth.@387.96-388.26 No.@388.38-389.46 I@389.58-390.54 should@390.54-390.84
    just@390.84-391.08 brush@391.08-391.5 you.@391.5-391.86 Un...@395.76-397.92 I'm@406.38-407.76
    sorry.@407.76-407.94 Go,@409.08-410.52 Dad,@410.52-410.76 lip.@410.76-411.12 Not@418.08-419.34 my@419.34-419.64
    fault.@419.64-419.88 It's@420.9-422.34 time.@422.34-422.52 Wire,@428.58-429.3 sir.@429.3-429.66
    We're@429.72-430.32 out@430.32-430.44 of@430.44-430.56 time.@430.56-430.8 Round@430.86-431.04 of@431.04-431.22
    time.@431.22-431.52 Emory@502.8-504.24 over@504.24-504.42 at@504.42-504.66 it,@504.66-504.96 90%.@504.96-505.44
    Captain,@505.5-506.82 we@506.82-507.36 have@507.36-507.48 to@507.48-507.6 abort.@507.6-508.2 The@517.98-519.24
    world's@519.24-519.54 changed,@519.54-519.84 Celia.@519.84-520.5 Maybe@533.82-535.08 we@535.08-535.5
    can,@535.5-535.74 too.@535.74-535.86 Memory@537.06-538.5 override@538.5-538.91 complete.@538.91-539.28
    You@557.75-559.01 know...@559.01-559.8 There's@560.75-562.2 a@562.2-562.5 lesson@562.5-562.68 to@562.68-562.74
    be@562.74-562.86 learned@562.86-563.04 from@563.04-563.1 this.@563.1-563.28 Could@565.08-566.34
    have@566.34-566.39 gone@566.39-566.51 worse.@566.51-567
"""

/// Sentences named by a time inside them. The first 240 s repeat the excerpt's pairs. From 290 s the memory replay,
/// judged the same way from frames and pitch: Thom on screen and talking, 108–135 Hz, at 317 ("Look, Celia…"),
/// 356.5 ("Listen, Celia."), 358.3, 360.4 and 362 ("…destroy the world."); Celia on screen at 348 ("…my robot
/// hand?", 238 Hz); the robot's "You're a jerk, Tom." at 299.5 (351 Hz); Barley in close-up at 343 ("Speed it up");
/// the captain at 365 ("Why does she do this?", 239 Hz). Lines over music or unseen talkers are left out.
private let filmSame: [(Seconds, Seconds)] = [
    (25.5, 28), (35, 37.8), (37.8, 38.7), (38.7, 40.5), (35, 40.5), (23, 32), (50.5, 53.4), (191, 192.9), (192.9, 194), (235, 237),
    (317, 356.5), (356.5, 358.3), (358.3, 360.4), (360.4, 362), (317, 362),
]
private let filmDifferent: [(Seconds, Seconds)] = [
    (7, 23), (23, 25.5), (23, 28), (32, 35), (32, 40.5), (25.5, 32), (194, 197), (197, 199), (191, 197),
    (348, 362), (317, 348), (348, 356.5), (362, 365), (299.5, 317), (343, 317), (343, 348),
]

@Test(.enabled(if: FileManager.default.fileExists(atPath: tearsOfSteelPath)))
func tearsOfSteelWholeFilmKeepsVoicesApart() async throws {
    let words = tearsOfSteelFilmWords.split(whereSeparator: \.isWhitespace).map { tok -> Word in
        let parts = tok.split(separator: "@")
        let times = parts[1].split(separator: "-").map { Double($0)! }
        return Word(text: String(parts[0]), start: times[0], end: times[1])
    }
    let transcript = Transcript(mediaId: "tos", locale: "en-US", words: words)
    let samples = try await Diarizer.decodeMono(url: URL(fileURLWithPath: tearsOfSteelPath))
    let result = Diarizer.analyze(samples: samples, sampleRate: Diarizer.decodeRate, transcript: transcript)
    for s in result.segments where s.start < 372 {
        let text = words.filter { $0.start >= s.start - 0.01 && $0.end <= s.end + 0.01 }.map(\.text).joined(separator: " ")
        print(String(format: "film %7.2f–%7.2f %@ %.2f %@", s.start, s.end, s.speaker, s.confidence ?? -1, text))
    }
    func speaker(_ t: Seconds) -> String? {
        let i = words.indices.min { abs((words[$0].start + words[$0].end) / 2 - t) < abs((words[$1].start + words[$1].end) / 2 - t) }!
        return result.wordSpeakers[i]
    }
    func score(_ range: ClosedRange<Seconds>) -> (same: Int, of: Int, different: Int, ofDifferent: Int) {
        let s = filmSame.filter { range.contains($0.0) }, d = filmDifferent.filter { range.contains($0.0) }
        return (s.filter { speaker($0.0) == speaker($0.1) }.count, s.count, d.filter { speaker($0.0) != speaker($0.1) }.count, d.count)
    }
    let early = score(0...240), replay = score(290...372)
    print("film speakers \(result.speakers.count), 0–240 s same \(early.same)/\(early.of) different \(early.different)/\(early.ofDifferent), 290–372 s same \(replay.same)/\(replay.of) different \(replay.different)/\(replay.ofDifferent)")
    #expect((2...6).contains(result.speakers.count))
    // Over the whole film Thom and Celia share the room and mic of their scenes, yet stay two voices.
    #expect(Double(early.same + early.different) / Double(early.of + early.ofDifferent) >= 0.85)
    #expect(Double(replay.same + replay.different) / Double(replay.of + replay.ofDifferent) >= 0.8)
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
