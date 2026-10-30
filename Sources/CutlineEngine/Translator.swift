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

    /// `texts` translated from `source` to `target`, in order.
    public static func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        switch await availability(from: source, to: target) {
        case .installed: break
        case .notInstalled:
            throw EditError("On-device translation from \(source) to \(target) isn't installed. Add \(name(target)) in System Settings › General › Language & Region › Translation Languages (the server can't download it), or pass the translated text with cues or file")
        case .unsupported:
            throw EditError("On-device translation doesn't support \(source) to \(target); pass the translated text with cues or file")
        }
        guard !texts.isEmpty else { return [] }
        let session = TranslationSession(installedSource: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        var out = texts
        for r in try await session.translations(from: requests) {
            if let id = r.clientIdentifier.flatMap(Int.init), out.indices.contains(id) { out[id] = r.targetText }
        }
        return out
    }

    static func name(_ tag: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: tag) ?? tag
    }
}
