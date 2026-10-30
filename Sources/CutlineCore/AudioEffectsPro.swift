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
        EffectType(id: "audio.deess", category: "audio", summary: "De-esser: tames sibilance, the harsh s, sh and t sounds, by turning down only the highs while they are loud", params: [
            EffectCatalog.num("frequency", 6000, 4000, 10000, "Hz", "Where sibilance starts; 5000–7000 for most voices"),
            EffectCatalog.db("threshold", -30, -60, 0, "Sibilance level where reduction starts"),
            EffectCatalog.db("reduction", 8, 0, 24, "Most the highs are turned down"),
        ]),
        EffectType(id: "audio.dehum", category: "audio", summary: "Removes mains hum and its harmonics with narrow notches", params: [
            EffectCatalog.num("fundamental", 0, 0, 1000, "Hz", "Hum frequency: 50 (Europe, Asia, Africa), 60 (Americas); 0 detects it"),
            EffectCatalog.num("harmonics", 4, 1, 16, "", "How many multiples of the fundamental to notch"),
        ]),
        EffectType(id: "audio.declick", category: "audio", summary: "Removes clicks, pops and crackle (mouth clicks, cable ticks, vinyl) by bridging short impulses", params: [
            EffectCatalog.num("sensitivity", 0.5, 0, 1, "", "How readily a spike counts as a click; higher catches quieter clicks but can soften sharp consonants"),
        ]),
        EffectType(id: "audio.leveler", category: "audio", summary: "Dialogue leveler (auto-level, like Resolve's Dialogue Leveler or Premiere's Auto Match): rides the gain so speech holds a target loudness over a moving window, holding the gain through pauses and background so noise is never pumped up; peaks stay under −1 dBFS. For visible, editable rides use recipe clip_gain_ride", params: [
            EffectCatalog.num("target", -23, -40, -10, "LUFS", "Loudness speech is held at (short-term, speech only); −23 sits dialogue for a DME mix, the master loudness target lifts the whole mix later"),
            EffectCatalog.db("max_boost", 12, 0, 24, "Most a quiet line is raised"),
            EffectCatalog.db("max_cut", 12, 0, 24, "Most a loud line is lowered"),
            EffectCatalog.num("speed", 0.5, 0, 1, "", "How fast the gain follows: 0 slow (3 s window, whole lines), 1 fast (0.4 s, words)"),
            EffectCatalog.num("floor", -50, -80, -20, "LUFS", "Noise floor: sound below this, or near the background noise, holds the gain instead of driving it"),
        ]),
        EffectType(id: "audio.match_eq", category: "audio", summary: "Match EQ: a smooth third-octave curve that gives this sound another clip's tone (lav to boom, pickup to production sound). recipe match_eq learns the curve from both clips' speech", params: [
            ParamSpec("curve", .text, .string(""), "Gains as \"hz:dB\" pairs, e.g. \"125:+2.0 250:-1.5 4000:+3.0\", interpolated over log frequency; recipe match_eq fills it"),
            EffectCatalog.num("amount", 1, 0, 1, "", "Scales the curve; 0.5 goes halfway to the reference"),
        ]),
        EffectType(id: "audio.dereverb", category: "audio", summary: "De-reverb: lowers room echo and reverb tails in speech by subtracting the late reverb predicted from the room's decay (measured from the sound itself)", params: [
            EffectCatalog.num("strength", 0.6, 0, 1, "", "How much of the predicted reverb is removed; above 0.8 can make speech dry and thin"),
            EffectCatalog.db("reduction", 12, 0, 30, "Most any moment is turned down"),
            EffectCatalog.num("rt60", 0, 0, 4, "s", "Reverb time of the room; 0 measures it from the decays in the sound"),
        ]),
        EffectType(id: "audio.spectral_repair", category: "audio", summary: "Spectral repair: removes a cough, bump, click, phone ring or beep in a time range and frequency band by rebuilding that patch from the sound just before and after (time-frequency inpainting), or turns the patch down. recipe spectral_repair finds clicks and tones", params: [
            EffectCatalog.num("start", 0, 0, 86_400, "s", "Start of the patch, seconds from the clip's start (timeline time on tracks and the master)"),
            EffectCatalog.num("end", 0, 0, 86_400, "s", "End of the patch"),
            EffectCatalog.num("freq_low", 0, 0, 24_000, "Hz", "Bottom of the band; 0 from the lowest frequency"),
            EffectCatalog.num("freq_high", 0, 0, 24_000, "Hz", "Top of the band; 0 up to the highest"),
            ParamSpec("mode", .choice(["interpolate", "attenuate"]), .string("interpolate"), "interpolate rebuilds the patch's level from the surrounding sound (never louder than it was); attenuate turns it down by reduction"),
            EffectCatalog.db("reduction", 30, 0, 80, "attenuate: how far the patch is turned down"),
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
