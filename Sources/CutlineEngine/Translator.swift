import CutlineCore
import Foundation
import Translation

/// On-device translation of cue text with Apple's Translation framework. Runs headless with languages already
/// installed (System Settings › General › Language & Region › Translation Languages); a process without a window
/// can't download one.
public enum Translator {
    public enum Availability: Equatable, Sendable {
        case installed, notInstalled, unsupported
    }

    public static func availability(from source: String, to target: String) async -> Availability {
        switch await LanguageAvailability().status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target)) {
        case .installed: .installed
        case .supported: .notInstalled
        case .unsupported: .unsupported
        @unknown default: .unsupported
        }
    }

    /// How the translation addresses the listener where the target language distinguishes (tu/vous, du/Sie).
    public enum Register: String, Sendable, CaseIterable {
        case formal, informal
    }

    /// `texts` translated from `source` to `target`, in order. With `context` (consecutive cues of one
    /// conversation), runs of cues are translated as one document with numbered markers and split back, so pronouns,
    /// gender and register stay consistent across cues; a run whose markers don't survive is translated cue by cue.
    /// `register` steers the form of address (for English sources) by opening each document with a line in it.
    public static func translate(_ texts: [String], from source: String, to target: String, context: Bool = false, register: Register? = nil) async throws -> [String] {
        switch await availability(from: source, to: target) {
        case .installed: break
        case .notInstalled:
            throw EditError("On-device translation from \(source) to \(target) isn't installed. Add \(name(target)) in System Settings › General › Language & Region › Translation Languages (the server can't download it), or pass the translated text with cues or file")
        case .unsupported:
            throw EditError("On-device translation doesn't support \(source) to \(target); pass the translated text with cues or file")
        }
        guard !texts.isEmpty else { return [] }
        let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        let primer = register.flatMap { primers[Locale.Language(identifier: source).languageCode?.identifier ?? source]?[$0] }
        var out = texts
        var single: [Int] = []
        if context || primer != nil {
            let docs = documents(texts, primer: primer, context: context)
            let requests = docs.enumerated().map { TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset)) }
            for r in try await session.translations(from: requests) {
                guard let d = r.clientIdentifier.flatMap(Int.init), docs.indices.contains(d) else { continue }
                if let parts = split(r.targetText, count: docs[d].cues.count) {
                    for (i, t) in zip(docs[d].cues, parts) { out[i] = t }
                } else {
                    single += docs[d].cues
                }
            }
        } else {
            single = Array(texts.indices)
        }
        guard !single.isEmpty else { return out }
        let requests = single.map { i in TranslationSession.Request(sourceText: primer.map { "<0>\($0) <1>\(flat(texts[i]))" } ?? texts[i], clientIdentifier: String(i)) }
        for r in try await session.translations(from: requests) {
            guard let id = r.clientIdentifier.flatMap(Int.init), out.indices.contains(id) else { continue }
            out[id] = primer == nil ? r.targetText : split(r.targetText, count: 1)?.first ?? r.targetText
        }
        return out
    }

    /// Lines in the source language that set the form of address the rest of a document follows; dropped after.
    static let primers: [String: [Register: String]] = [
        "en": [.formal: "Excuse me, sir.", .informal: "Hey buddy!"],
    ]

    static func flat(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "<", with: "‹").replacingOccurrences(of: ">", with: "›")
    }

    /// Runs of up to 12 cues (about 900 characters) as "<0>primer <1>cue <2>cue …", with their cue indices. Without
    /// a primer, a run after the first opens with the previous run's last cue as <0>, for continuity.
    static func documents(_ texts: [String], primer: String?, context: Bool) -> [(text: String, cues: [Int])] {
        var runs: [[Int]] = []
        var current: [Int] = []
        var length = 0
        for i in texts.indices {
            let n = texts[i].count
            if !context || (!current.isEmpty && (current.count >= 12 || length + n > 900)) {
                if !current.isEmpty { runs.append(current) }
                current = []
                length = 0
            }
            current.append(i)
            length += n
        }
        if !current.isEmpty { runs.append(current) }
        return runs.map { run in
            let lead = primer ?? (context ? run.first.flatMap { $0 > 0 ? flat(texts[$0 - 1]) : nil } : nil)
            let body = run.enumerated().map { "<\($0.offset + 1)>" + flat(texts[$0.element]) }.joined(separator: " ")
            return ((lead.map { "<0>\($0) " } ?? "") + body, run)
        }
    }

    /// The text after each marker <1>…<count> of a translated document, dropping <0>; nil unless every marker
    /// came back once, in order.
    static func split(_ text: String, count: Int) -> [String]? {
        let regex = try! NSRegularExpression(pattern: #"<\s*(\d+)\s*>"#)
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let numbers = matches.map { Int(ns.substring(with: $0.range(at: 1))) ?? -1 }
        let kept = numbers.filter { $0 != 0 }
        guard kept == Array(1...max(1, count)), count > 0 else { return nil }
        var out: [String] = []
        for (k, m) in matches.enumerated() where numbers[k] != 0 {
            let start = m.range.location + m.range.length
            let end = k + 1 < matches.count ? matches[k + 1].range.location : ns.length
            let piece = ns.substring(with: NSRange(location: start, length: max(0, end - start))).trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(piece.replacingOccurrences(of: "‹", with: "<").replacingOccurrences(of: "›", with: ">"))
        }
        return out.contains(where: \.isEmpty) ? nil : out
    }

    static func name(_ tag: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: tag) ?? tag
    }
}
