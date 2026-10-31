@testable import CutlineEngine
import Foundation
import Testing

@Test func cueDocumentsSplitBack() {
    let texts = ["So you made it.", "I wasn't sure\nyou'd come.", "Do <you> remember?"]
    let docs = Translator.documents(texts, primer: "Excuse me, sir.", context: true)
    #expect(docs.count == 1 && docs[0].cues == [0, 1, 2])
    #expect(docs[0].text == "<0>Excuse me, sir. <1>So you made it. <2>I wasn't sure you'd come. <3>Do ‹you› remember?")
    let back = Translator.split("<0>Excusez-moi, monsieur. <1>Vous êtes venu. < 2 >Je ne savais pas. <3>Vous ‹vous› souvenez ?", count: 3)
    #expect(back == ["Vous êtes venu.", "Je ne savais pas.", "Vous <vous> souvenez ?"])
    #expect(Translator.split("<1>Un. <3>Trois.", count: 3) == nil, "a lost marker falls back")
    #expect(Translator.split("<2>Deux. <1>Un.", count: 2) == nil)
    // Long runs break up; later runs open with the cue before them.
    let many = (0..<30).map { "Line \($0)." }
    let runs = Translator.documents(many, primer: nil, context: true)
    #expect(runs.count == 3 && runs[1].text.hasPrefix("<0>Line 11. <1>Line 12."), "\(runs.map(\.text))")
    #expect(Translator.documents(many, primer: nil, context: false).count == 30)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CUTLINE_SLOW"] != nil))
func translationKeepsOneRegisterAcrossCues() async throws {
    guard await Translator.availability(from: "en", to: "fr") == .installed else { return }
    let cues = ["Are you coming with me?", "I need you here.", "You know what to do.", "Thank you, you are very kind.", "Where are you going?"]
    let perCue = try await Translator.translate(cues, from: "en", to: "fr")
    let inContext = try await Translator.translate(cues, from: "en", to: "fr", context: true)
    let formal = try await Translator.translate(cues, from: "en", to: "fr", context: true, register: .formal)
    func vous(_ s: [String]) -> Int { s.filter { $0.lowercased().contains("vous") }.count }
    func tu(_ s: [String]) -> Int { s.filter { $0.range(of: #"\b(tu|toi|te|ta|ton|tes)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }.count }
    print("per cue: \(perCue)\nin context: \(inContext)\nformal: \(formal)")
    #expect(vous(inContext) == 0 || tu(inContext) == 0, "one register in context: \(inContext)")
    #expect(vous(formal) == cues.count, "\(formal)")
}
