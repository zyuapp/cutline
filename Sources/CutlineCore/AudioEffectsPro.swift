import Foundation

/// Restoration and stereo effects rendered offline by `AudioDSP`, plus the naming rule for hosted plug-ins.
///
/// Plug-in effects use the plug-in's id as their type, `au.<manufacturer>.<subtype>.<type>` with four-character
/// codes (e.g. `au.appl.dely.aufx`, as `AudioUnitHost.installedEffects()` reports). Their params are free-form:
/// each key is a parameter key path, identifier or display name from `AudioUnitHost.parameters(of:)`, and the
/// reserved key `preset` names a factory preset applied before the other params.
public enum ProAudioCatalog {
    public static let pluginPrefix = "au."
    public static let presetParam = "preset"

    public static func isPlugin(_ type: String) -> Bool { type.hasPrefix(pluginPrefix) }

    public static func type(_ id: String) -> EffectType? { all.first { $0.id == id } }

    public static let all: [EffectType] = [
        EffectType(id: "audio.denoise", category: "audio", summary: "Spectral noise reduction: learns the steady noise floor (hiss, hum bed, air conditioning, room tone) and lowers it while keeping speech", params: [
            EffectCatalog.db("reduction", 12, 0, 40, "How far the noise floor is lowered; 6–12 is natural, above 20 can sound processed"),
            EffectCatalog.num("sensitivity", 0.5, 0, 1, "", "How much counts as noise; higher removes more but can thin quiet speech"),
        ]),
        EffectType(id: "audio.deess", category: "audio", summary: "De-esser: tames harsh s, sh and t sounds by turning down only the highs while they are loud", params: [
            EffectCatalog.num("frequency", 6000, 4000, 10000, "Hz", "Where sibilance starts; 5000–7000 for most voices"),
            EffectCatalog.db("threshold", -30, -60, 0, "Sibilance level where reduction starts"),
            EffectCatalog.db("reduction", 8, 0, 24, "Most the highs are turned down"),
        ]),
        EffectType(id: "audio.dehum", category: "audio", summary: "Removes mains hum and its harmonics with narrow notches", params: [
            EffectCatalog.num("fundamental", 0, 0, 1000, "Hz", "Hum frequency: 50 (Europe, Asia, Africa), 60 (Americas); 0 detects it"),
            EffectCatalog.num("harmonics", 4, 1, 16, "", "How many multiples of the fundamental to notch"),
        ]),
        EffectType(id: "audio.pan", category: "audio", summary: "Places the sound left or right with a constant-power law", params: [
            EffectCatalog.num("pan", 0, -1, 1, "", "-1 hard left, 0 center (unchanged), 1 hard right"),
        ]),
        EffectType(id: "audio.width", category: "audio", summary: "Narrows or widens the stereo image (mid/side)", params: [
            EffectCatalog.num("width", 1, 0, 2, "", "0 mono, 1 unchanged, 2 twice as wide"),
        ]),
    ]
}

/// Installed Audio Unit plug-ins described as effect types once they've been inspected, so their
/// parameters validate and animate like built-in effects.
public enum PluginRegistry {
    nonisolated(unsafe) static var types: [String: EffectType] = [:]
    static let lock = NSLock()

    public static func type(_ id: String) -> EffectType? { lock.withLock { types[id] } }

    public static func register(_ t: EffectType) { lock.withLock { types[t.id] = t } }
}
