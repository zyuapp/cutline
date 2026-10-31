import CutlineCore
import CutlineEngine
import Foundation

/// Dialogue recipes: clip-gain rides, match EQ and spectral repair.
extension Toolbox {
    static let stemRate = 48_000.0

    func dialogueRecipe(_ name: String, _ a: Args, dry: Bool) async throws -> ToolResult {
        switch name {
        case "clip_gain_ride": return try await clipGainRide(a, dry: dry)
        case "match_eq": return try await matchEQ(a, dry: dry)
        default: return try await spectralRepair(a, dry: dry)
        }
    }

    /// A clip's sound as it plays on its own: its clip effects and volume, no track, bus or master processing.
    /// `adjust` changes the clip first. Starts at the clip's start.
    func soloSound(_ clip: Clip, adjust: (inout Clip) -> Void = { _ in }) async throws -> [[Float]] {
        var c = clip
        adjust(&c)
        var p = try session.project()
        p.tracks = [Track(id: "solo", kind: .audio, name: "solo", clips: [c])]
        p.transitions = []
        p.master = MasterAudio()
        let built = try await session.timeline(for: p, shared: false)
        let x = try await AudioDSP.mix(of: built, range: TimeRange(c.start, c.end))
        guard x.contains(where: { $0.contains { $0 != 0 } }) else { throw EditError("\(clip.id) plays no sound") }
        return x
    }

    func soundClip(_ id: String, _ p: Project) throws -> Clip {
        guard let c = p.clip(id) else { throw EditError("No clip \(id)") }
        guard c.kind == .sequence || (c.kind == .media && (c.mediaId.flatMap { p.mediaAsset($0) }?.hasAudio ?? false)) else { throw EditError("\(id) has no sound") }
        return c
    }

    static func spread(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }

    // MARK: clip_gain_ride

    func clipGainRide(_ a: Args, dry: Bool) async throws -> ToolResult {
        let p = try session.project()
        let named = a.strings("clips") ?? []
        var listed = named
        if let tid = a.optString("track") {
            guard let t = p.tracks.first(where: { $0.id == tid }) else { throw EditError("No track \(tid)") }
            listed += t.clips.filter { c in c.kind == .media && (c.mediaId.flatMap { p.mediaAsset($0) }?.hasAudio ?? false) }.map(\.id)
        }
        guard !listed.isEmpty else { throw EditError("Pass clips or track") }
        // A muted clip (its sound detached or split off) is ridden through its linked sound clips.
        func silent(_ c: Clip) -> Bool { c.volume <= 1e-6 && c.anim["audio.volume"] == nil }
        var ids: [String] = [], notes: [String] = []
        for id in listed {
            guard let c = p.clip(id) else { throw EditError("No clip \(id)") }
            guard silent(c) else {
                if !ids.contains(id) { ids.append(id) }
                continue
            }
            let sound = p.linked(id).compactMap { p.clip($0) }.filter { o in
                !silent(o) && o.kind == .media && (o.mediaId.flatMap { p.mediaAsset($0) }?.hasAudio ?? false)
            }.map(\.id)
            if sound.isEmpty {
                notes.append("\(id) is muted and has no linked sound; skipped")
            } else {
                notes.append("\(id) is muted; rode its linked sound \(sound.joined(separator: ", ")) instead")
                ids += sound.filter { !ids.contains($0) }
            }
        }
        let target = a.optDouble("target_lufs") ?? -23
        let maxDb = a.optDouble("max_db") ?? 10
        let ramp = a.optDouble("ramp") ?? 0.2
        guard (-40 ... -10).contains(target), (0...24).contains(maxDb), (0.02...2).contains(ramp) else { throw EditError("target_lufs is −40…−10, max_db 0…24 and ramp 0.02…2") }
        let words = p.timelineWords(transcripts: try session.requireBundle().transcripts(for: p))
        var plans: [(id: String, phrases: [RidePhrase], how: String)] = []
        for id in ids {
            let c = try soundClip(id, p)
            let x: [[Float]]
            do { x = try await soloSound(c) { $0.anim["audio.volume"] = nil } } catch where !named.contains(id) {
                notes.append("\(id): \(error.localizedDescription); skipped")
                continue
            }
            var own = words.filter { $0.clipId == id }
            if own.isEmpty, let mid = c.mediaId { own = words.filter { $0.mediaId == mid && $0.start >= c.start - 0.01 && $0.end <= c.end + 0.01 } }
            let spans: [(range: TimeRange, text: String)]
            let how: String
            if own.isEmpty {
                spans = AudioDSP.soundSpans(x, sampleRate: Self.stemRate).map { ($0, "") }
                how = "the sound's own pauses (no transcript)"
            } else {
                spans = DialogueRide.phrases(own.map { ($0.start - c.start, $0.end - c.start, $0.text) })
                how = "transcript phrases"
            }
            let phrases = spans.map { s in
                RidePhrase(range: s.range, lufs: AudioDSP.loudness(x, sampleRate: Self.stemRate, from: max(0, s.range.start - 0.02), to: s.range.end + 0.02), text: s.text)
            }
            plans.append((id, phrases, how))
        }
        guard !plans.isEmpty else { throw EditError("Nothing to ride: " + notes.joined(separator: "; ")) }
        return try runEdit("Ride clip gain to \(fmt1(target)) LUFS", dry: dry) { p in
            var lines = notes
            for plan in plans {
                let results = try p.rideClipGain(plan.id, phrases: plan.phrases, targetLufs: target, maxDb: maxDb, ramp: ramp)
                let held = results.filter { abs($0.lufs - target) > 0.5 }.count
                lines.append("\(plan.id): \(results.count) phrase(s) from \(plan.how), loudness spread \(fmt1(Toolbox.spread(results.map(\.phrase.lufs)))) → \(fmt1(Toolbox.spread(results.map(\.lufs)))) LU" + (held > 0 ? "; \(held) held at the ±\(fmt1(maxDb)) dB limit" : ""))
                for r in results.prefix(12) {
                    let words = r.phrase.text.isEmpty ? "" : " \"" + Toolbox.excerpt(r.phrase.text, 40) + "\""
                    lines.append("  \(fmt2(r.phrase.range.start))–\(fmt2(r.phrase.range.end))s\(words): \(fmt1(r.phrase.lufs)) LUFS, \(r.gainDb >= 0 ? "+" : "")\(fmt1(r.gainDb)) dB")
                }
                if results.count > 12 { lines.append("  … \(results.count - 12) more") }
            }
            return lines.joined(separator: "\n") + "\nRides are audio.volume keys (clip-local seconds) changing level in the pauses; adjust with param_set, check with timeline_measure."
        }
    }

    // MARK: match_eq

    func matchEQ(_ a: Args, dry: Bool) async throws -> ToolResult {
        let p = try session.project()
        guard let ids = a.strings("clips"), !ids.isEmpty else { throw EditError("Pass clips") }
        let refId = try a.string("reference")
        let amount = a.optDouble("amount") ?? 1
        let maxDb = a.optDouble("max_db") ?? 12
        guard (0...1).contains(amount), (1...12).contains(maxDb) else { throw EditError("amount is 0…1 and max_db 1…12") }
        let refSound = try await soloSound(try soundClip(refId, p))
        let reference = AudioDSP.longTermSpectrum(refSound, sampleRate: Self.stemRate), refNoise = AudioDSP.noiseProfile(refSound, sampleRate: Self.stemRate)
        func distance(_ s: [Float]) -> Double { AudioDSP.spectralDistance(s, reference, sampleRate: Self.stemRate) }
        var plans: [(id: String, curve: EQCurve, before: Double, after: Double)] = []
        for id in ids where id != refId {
            let x = try await soloSound(try soundClip(id, p)) { $0.effects.removeAll { $0.type == "audio.match_eq" } }
            let source = AudioDSP.longTermSpectrum(x, sampleRate: Self.stemRate)
            let curve = AudioDSP.matchCurve(source: source, reference: reference, sampleRate: Self.stemRate, maxDb: maxDb, sourceNoise: AudioDSP.noiseProfile(x, sampleRate: Self.stemRate), referenceNoise: refNoise)
            let matched = AudioDSP.matchEQ(x, sampleRate: Self.stemRate, curve: curve, amount: amount)
            plans.append((id, curve, distance(source), distance(AudioDSP.longTermSpectrum(matched, sampleRate: Self.stemRate))))
        }
        guard !plans.isEmpty else { throw EditError("Pass clips other than the reference") }
        return try runEdit("Match EQ to \(refId)", dry: dry) { p in
            var lines: [String] = []
            for plan in plans {
                guard let loc = p.locateClip(plan.id) else { throw EditError("No clip \(plan.id)") }
                var c = p.tracks[loc.track].clips[loc.clip]
                let fx = Effect(id: c.effects.first { $0.type == "audio.match_eq" }?.id ?? "match_eq", type: "audio.match_eq", params: ["curve": .string(plan.curve.text), "amount": .number(amount)])
                if let i = c.effects.firstIndex(where: { $0.type == "audio.match_eq" }) {
                    c.effects[i] = fx
                } else if let i = c.effects.firstIndex(where: { ["audio.limiter", "audio.leveler"].contains($0.type) }) {
                    c.effects.insert(fx, at: i)
                } else {
                    c.effects.append(fx)
                }
                p.tracks[loc.track].clips[loc.clip] = c
                let big = plan.curve.points.filter { abs($0.db) >= 3 }.map { String(format: "%.0f Hz %+.1f", $0.hz, $0.db) }
                lines.append("\(plan.id): effect \(fx.id), spectral distance to \(refId) \(fmt1(plan.before)) → \(fmt1(plan.after)) dB (third-octave RMS over 100 Hz–8 kHz of speech frames)" + (big.isEmpty ? "" : "; main moves " + big.prefix(8).joined(separator: ", ") + " dB"))
            }
            return lines.joined(separator: "\n") + "\nThe curve is fx.<id>.curve (\"hz:dB\" pairs); fx.<id>.amount scales it."
        }
    }

    // MARK: spectral_repair

    func spectralRepair(_ a: Args, dry: Bool) async throws -> ToolResult {
        let p = try session.project()
        let c = try soundClip(try a.string("clip"), p)
        let mode = a.optString("mode") ?? "interpolate"
        guard ["interpolate", "attenuate"].contains(mode) else { throw EditError("mode is interpolate or attenuate") }
        let reduction = a.optDouble("reduction") ?? 30
        var band: (Double, Double) = (0, 0)
        if let v = a.value("band") {
            let parts = v.array?.compactMap(\.double) ?? (v.string ?? "").split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == " " || $0 == "," }).compactMap { Double($0) }
            guard parts.count == 2, parts[0] >= 0, parts[1] > parts[0] else { throw EditError("band is \"low-high\" in Hz, e.g. \"900-1100\", or [900, 1100]") }
            band = (parts[0], parts[1])
        }
        var patches: [(start: Double, end: Double, low: Double, high: Double, why: String)] = []
        if let at = try a.optTime("at") {
            let duration = a.optDouble("duration") ?? 0.2
            guard duration > 0, duration <= 10 else { throw EditError("duration is 0…10 seconds") }
            let start = at - c.start
            guard start >= 0, start + duration <= c.duration + 1e-6 else { throw EditError("at \(fmt2(at))s + \(fmt2(duration))s is outside \(c.id) (\(fmt2(c.start))–\(fmt2(c.end))s)") }
            patches.append((start, start + duration, band.0, band.1, ""))
        } else {
            let found = AudioDSP.repairCandidates(try await soloSound(c), sampleRate: Self.stemRate)
            func describe(_ e: RepairCandidate) -> String {
                "\(e.kind.rawValue) at \(fmt2(c.start + e.start))s for \(fmt2(e.end - e.start))s" + (e.high > 0 ? ", \(Int(e.low))–\(Int(e.high)) Hz" : ", full band") + ", \(fmt1(e.strength)) dB over its surroundings"
            }
            guard !found.isEmpty else { return .text("No clicks, thumps or tones stand out in \(c.id). For a cough or other sound, pass at, duration and band.") }
            guard a.bool("fix_all", default: false) else {
                return .text("Repair candidates in \(c.id) (timeline times):\n" + found.prefix(30).map { "  " + describe($0) }.joined(separator: "\n") + (found.count > 30 ? "\n  … \(found.count - 30) more" : "")
                    + "\nRepair one with recipe spectral_repair {clip, at, duration, band}, or all with fix_all:true.")
            }
            let pad = 0.01
            patches = found.map { (max(0, $0.start - pad), min(c.duration, $0.end + pad), $0.low, $0.high, describe($0)) }
        }
        return try runEdit("Spectral repair on \(c.id)", dry: dry) { p in
            guard let loc = p.locateClip(c.id) else { throw EditError("No clip \(c.id)") }
            var clip = p.tracks[loc.track].clips[loc.clip]
            var lines: [String] = []
            var n = 1
            for patch in patches {
                while clip.effects.contains(where: { $0.id == "repair\(n)" }) { n += 1 }
                clip.effects.append(Effect(id: "repair\(n)", type: "audio.spectral_repair", params: [
                    "start": .number((patch.start * 1000).rounded() / 1000), "end": .number((patch.end * 1000).rounded() / 1000),
                    "freq_low": .number(patch.low), "freq_high": .number(patch.high), "mode": .string(mode), "reduction": .number(reduction),
                ]))
                lines.append("repair\(n): \(fmt2(c.start + patch.start))–\(fmt2(c.start + patch.end))s, " + (patch.high > 0 ? "\(Int(patch.low))–\(Int(patch.high)) Hz" : patch.low > 0 ? "above \(Int(patch.low)) Hz" : "full band") + ", \(mode)" + (patch.why.isEmpty ? "" : " (\(patch.why))"))
            }
            p.tracks[loc.track].clips[loc.clip] = clip
            return "Added \(patches.count) spectral repair(s) to \(c.id):\n  " + lines.joined(separator: "\n  ") + "\nTimes in the effect are clip-local (fx.<id>.start/end); listen with preview_seek."
        }
    }
}
