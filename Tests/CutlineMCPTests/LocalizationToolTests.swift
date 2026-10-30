import AVFoundation
import CutlineCore
import CutlineEngine
@testable import CutlineMCP
import Foundation
import Testing

/// An open project with a still on V1 and two transcribed sentences on A1.
private func openProject() async throws -> (Toolbox, ProjectBundle, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cutline-lang-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try writePNG(dir.appendingPathComponent("img.png"))
    try writeTone(dir.appendingPathComponent("tone.caf"))
    var p = Project(name: "Lang", canvas: Canvas(width: 320, height: 180, fps: 30))
    p.media = [try await MediaProbe.probe(dir.appendingPathComponent("img.png"), id: "img"), try await MediaProbe.probe(dir.appendingPathComponent("tone.caf"), id: "tone")]
    p.tracks[0].clips = [Clip(id: "pic", kind: .media, mediaId: "img", start: 0, duration: 3)]
    p.tracks[1].name = "Interview"
    p.tracks[1].clips = [Clip(id: "talk", kind: .media, mediaId: "tone", start: 0, duration: 3)]
    let b = try ProjectBundle.create(at: dir.appendingPathComponent("p.cutline"), project: p)
    try b.saveTranscript(Transcript(mediaId: "tone", locale: "en-US", words: [
        Word(text: "Hello", start: 0.2, end: 0.6, confidence: 0.95), Word(text: "there.", start: 0.7, end: 1.2, confidence: 0.9),
        Word(text: "Next", start: 1.7, end: 2.1, confidence: 0.2), Word(text: "part.", start: 2.2, end: 2.6, confidence: 0.85),
    ]))
    let box = Toolbox()
    _ = await box.call("project_open", ["path": .string(b.url.path)])
    return (box, b, dir)
}

@Test func lowConfidenceWordsAreMarkedAndListed() async throws {
    let (box, _, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let read = await box.call("media_transcript", ["media_id": "tone"])
    #expect(read.plainText.contains("[Next?] part.") && read.plainText.contains("[word?] is uncertain"), "\(read.plainText)")
    let low = await box.call("media_transcript", ["media_id": "tone", "low_confidence": true])
    #expect(low.plainText.contains("1 of 4 words") && low.plainText.contains("w2 1.70–2.10 \"Next\" 0.20"), "\(low.plainText)")
    let cues = await box.call("captions_list", [:])
    #expect(cues.plainText.contains("[Next?]") && cues.plainText.contains("1 word(s) the recognizer was unsure of"), "\(cues.plainText)")
    _ = await box.call("transcript_edit", ["media_id": "tone", "from": "w2", "text": "Next"])
    let fixed = await box.call("media_transcript", ["media_id": "tone", "low_confidence": true])
    #expect(fixed.plainText.contains("No low-confidence words"), "a corrected word is trusted: \(fixed.plainText)")
}

@Test func translatedSubtitlesExportAsTaggedTracksAndSidecars() async throws {
    let (box, b, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let missing = await box.call("export", ["subtitle_languages": ["fr"], "path": .string(dir.appendingPathComponent("x.mp4").path)])
    #expect(missing.isError && missing.plainText.contains("captions_translate"), "\(missing.plainText)")
    let set = await box.call("captions_translate", ["language": "fr", "cues": [["id": 0, "text": "Bonjour."], ["id": 1, "text": "Partie suivante."]]])
    #expect(!set.isError && set.plainText.contains("2/2 cues have fr text"), "\(set.plainText)")
    let srt = dir.appendingPathComponent("de.srt")
    try "1\n00:00:01,700 --> 00:00:02,900\nNächster Teil.\n".write(to: srt, atomically: true, encoding: .utf8)
    let imported = await box.call("captions_translate", ["language": "de", "file": .string(srt.path)])
    #expect(imported.plainText.contains("1/2 cues have de text"), "\(imported.plainText)")
    let list = await box.call("captions_list", ["language": "fr"])
    #expect(list.plainText.contains("fr: Bonjour.") && list.plainText.contains("Translation de: 1/2 cues, untranslated #0"), "\(list.plainText)")
    let burn = await box.call("captions_set", ["language": "fr"])
    let burned = try b.loadProject().captions.language
    #expect(!burn.isError && burned == "fr", "\(burn.plainText)")
    let ja = await box.call("captions_set", ["language": "ja"])
    #expect(ja.isError)

    let out = dir.appendingPathComponent("out.mov")
    let r = await box.call("export", ["path": .string(out.path), "subtitles": "both", "subtitle_formats": ["srt", "imsc"], "subtitle_languages": ["fr", "de"], "subtitle_default": "fr", "subtitle_forced": ["de"]])
    #expect(!r.isError, "\(r.plainText)")
    #expect(r.plainText.contains("Embedded subtitles: en, fr, de (forced), default fr") && r.plainText.contains("de: 1 of 2 cues have no translation"), "\(r.plainText)")
    let fr = try String(contentsOf: dir.appendingPathComponent("out.fr.srt"), encoding: .utf8)
    let en = try String(contentsOf: dir.appendingPathComponent("out.srt"), encoding: .utf8)
    #expect(fr.contains("Bonjour.") && fr.contains("Partie suivante.") && en.contains("Hello there."))
    #expect(fr.components(separatedBy: "\n").filter { $0.contains("-->") } == en.components(separatedBy: "\n").filter { $0.contains("-->") }, "cue times are shared")
    let imsc = try String(contentsOf: dir.appendingPathComponent("out.fr.imsc.ttml"), encoding: .utf8)
    #expect(imsc.contains("xml:lang=\"fr\"") && Project.timedTextProblems(imsc, format: .imsc).isEmpty)

    let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .subtitle)
    var seen: [String: (Bool, String?)] = [:]
    for t in tracks {
        let (lang, tag, enabled) = try await t.load(.languageCode, .extendedLanguageTag, .isEnabled)
        seen[lang ?? "?"] = (enabled, tag)
    }
    #expect(Set(seen.keys) == ["eng", "fra", "deu"], "\(seen)")
    #expect(seen["fra"]?.0 == true && seen["eng"]?.0 == false && seen["fra"]?.1 == "fr", "\(seen)")
    let groups = try await AVURLAsset(url: out).load(.trackGroups)
    let ids = Set(tracks.map { NSNumber(value: $0.trackID) })
    #expect(groups.contains { Set($0.trackIDs) == ids }, "one alternate group")
}

/// Uses Apple's on-device translation when English→French is installed; otherwise the tool must say how to install it.
@Test func onDeviceTranslationRunsHeadlessOrExplainsTheInstall() async throws {
    let (box, b, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let r = await box.call("captions_translate", ["language": "fr"])
    switch await Translator.availability(from: "en", to: "fr") {
    case .installed:
        #expect(!r.isError, "\(r.plainText)")
        let texts = try b.loadProject().captions.translations["fr"]?.map(\.text) ?? []
        #expect(texts.count == 2 && !texts.contains("Hello there."), "\(texts)")
        print("on-device fr: \(texts)")
    case .notInstalled:
        #expect(r.isError && r.plainText.contains("Translation Languages"), "\(r.plainText)")
    case .unsupported:
        #expect(r.isError)
    }
}

@Test func severalLanguagesTranslateInOneCall() async throws {
    let (box, b, dir) = try await openProject()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mixed = await box.call("captions_translate", ["languages": ["fr", "de"], "cues": [["id": 0, "text": "Bonjour."]]])
    #expect(mixed.isError && mixed.plainText.contains("single language"), "\(mixed.plainText)")
    let r = await box.call("captions_translate", ["languages": ["fr", "de", "ja"]])
    let status = [await Translator.availability(from: "en", to: "fr"), await Translator.availability(from: "en", to: "de"), await Translator.availability(from: "en", to: "ja")]
    let stored = try b.loadProject().captions.translations
    if status.contains(.installed) {
        #expect(!r.isError, "\(r.plainText)")
        for (lang, s) in zip(["fr", "de", "ja"], status) {
            #expect((stored[lang]?.count == 2) == (s == .installed), "\(lang): \(r.plainText)")
            #expect(r.plainText.contains(s == .installed ? "\(lang): 2 cue(s) translated" : "\(lang): not translated"), "\(r.plainText)")
        }
        print("several languages:\n\(r.plainText)")
    } else {
        #expect(r.isError && r.plainText.contains("fr:") && r.plainText.contains("ja:"), "\(r.plainText)")
        #expect(stored.isEmpty)
    }
    _ = await box.call("captions_translate", ["language": "fr", "cues": [["id": 0, "text": "Bonjour."]]])
    _ = await box.call("captions_translate", ["language": "de", "cues": [["id": 0, "text": "Hallo."]]])
    let cleared = await box.call("captions_translate", ["languages": ["fr", "de"], "clear": true])
    let after = try b.loadProject().captions.translations
    #expect(cleared.plainText.contains("fr, de") && after["fr"] == nil && after["de"] == nil, "\(cleared.plainText)")
}
