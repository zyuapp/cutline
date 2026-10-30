import CutlineCore
import CutlineEngine
import Foundation

extension Toolbox {
    static let busDocs = "Mixing: audio_bus adds submix buses (e.g. DIA, MUS, FX, a reverb bus) with effects (any audio.* or Audio Unit), a fader with automation (volume_keys), mute, solo and an output (master or another bus). track_update output routes a track to a bus; sends copy it into more buses at level_db, pre_fader or after the fader. param_set a clip's audio.role (e.g. \"ambience\" for room tone on the dialogue track) to split stems by subrole. recipe dme_buses sets up DIA/MUS/FX buses, a light DIA compressor and a master limiter. export deliver:\"stems\" stems:\"buses\" writes one file per bus plus M&E; project_status shows the routing tree."

    func registerBusTools() {
        addEdit(EditTool(name: "audio_bus", description: "Add, change or remove a submix bus. Tracks feed a bus with track_update output (and sends); its effects, fader and automation process their sum, then it feeds the master or another bus (no loops). While buses are used the mix renders offline through them (preview plays the plain mix until it is ready). Bus effects take the same type/params as effect_add, including Audio Units.", schema: Schema.object([
            "bus": Schema.string("Bus id, e.g. DIA, MUS, FX, VERB (letters, digits, _ and -)"),
            "action": Schema.string("add (default for a new id), update (default for an existing one) or remove (tracks feeding it go to its output)", values: ["add", "update", "remove"]),
            "name": Schema.string("Display name"),
            "output": Schema.string("\"master\" (default) or another bus id"),
            "tracks": Schema.strings("Route these tracks' output to this bus"),
            "layout": Schema.string("Channel layout of the bus: mix (default, follows the master; stereo under a mono master), stereo or mono; a surround master also takes its own layout", values: ["mix"] + AudioLayout.allCases.map(\.rawValue)),
            "volume": Schema.number("Fader gain 0–4 (1 unchanged)"),
            "gain_db": Schema.number("Fader gain in dB instead of volume"),
            "volume_keys": ["type": "array", "items": ["type": "array"], "description": "Fader automation [[timeline time, 0…4, ease?], …]; [] removes it"],
            "muted": Schema.bool("Mute the bus"),
            "solo": Schema.bool("Solo the bus: only soloed buses, what feeds them and their path to the master are heard"),
            "type": Schema.string("Add or update an effect of this type on the bus (audio.eq, audio.compressor, audio.limiter, audio.reverb, audio.delay, … or an Audio Unit id)"),
            "params": ["type": "object", "description": "The effect's parameter values"],
            "effect_id": Schema.string("Effect to update or remove; default type-based such as \"compressor1\""),
            "index": Schema.integer("Effect position in the bus chain, 0 first"),
            "mix": Schema.number("Effect wet amount 0…1"),
            "enabled": Schema.bool("Turn the effect on or off"),
            "remove_effect": Schema.bool("Remove the effect named by effect_id (or every effect of type)"),
        ], required: ["bus"]), label: { a, p in
            let id = a.optString("bus") ?? ""
            let action = a.optString("action") ?? (p.bus(id) == nil ? "add" : "update")
            return action == "remove" ? "Remove bus \(id)" : action == "add" ? "Add bus \(id)" : (a.has("type") || a.has("effect_id") ? "Bus \(id) effects" : "Update bus \(id)")
        }) { p, args in
            try Toolbox.applyBus(&p, args)
        })
    }

    static func applyBus(_ p: inout Project, _ args: Args) throws -> String {
        let id = try args.string("bus")
        let action = args.optString("action") ?? (p.bus(id) == nil ? "add" : "update")
        switch action {
        case "remove":
            try p.removeBus(id)
            return "Removed bus \(id); what fed it now feeds its output."
        case "add":
            guard p.bus(id) == nil else { throw EditError("There is already a bus \(id); use action update") }
            p.buses.append(AudioBus(id: id, name: args.optString("name")))
        case "update":
            guard p.bus(id) != nil else { throw EditError("No bus \(id)" + (p.buses.isEmpty ? "" : ". Buses: " + p.buses.map(\.id).joined(separator: ", "))) }
        default:
            throw EditError("action is add, update or remove")
        }
        let i = p.buses.firstIndex { $0.id == id }!
        var bus = p.buses[i]
        var notes: [String] = []
        if let v = args.optString("name") { bus.name = v }
        if let o = args.optString("output") { bus.output = o == "master" || o.isEmpty ? nil : o }
        if let l = args.optString("layout") {
            if l == "mix" {
                bus.layout = nil
            } else {
                guard let layout = AudioLayout(name: l) else { throw EditError("layout is mix, stereo, mono, surround51 or surround71") }
                guard layout.channelCount <= max(2, p.master.layout.channelCount), !layout.isSurround || layout == p.master.layout else { throw EditError("A \(layout.title) bus needs a \(layout.title) master; the master is \(p.master.layout.title)") }
                bus.layout = layout
            }
        }
        if let v = args.optDouble("volume") { bus.volume = v }
        if let db = args.optDouble("gain_db") {
            guard db >= -96, db <= 12 else { throw EditError("gain_db is −96…12") }
            bus.volume = pow(10, db / 20)
        }
        if let list = args.raw["volume_keys"]?.array {
            var keys: [CurveKey] = []
            for k in list {
                guard let arr = k.array, arr.count >= 2, let v = arr[1].double, v >= 0, v <= 4 else { throw EditError("volume_keys are [timeline time, 0…4, ease?]") }
                keys.append(CurveKey(t: try Args.parseTime(arr[0], name: "time"), v: .number(v), ease: arr.count > 2 ? Easing(rawValue: arr[2].string ?? "") ?? .easeInOut : .easeInOut))
            }
            bus.volumeCurve = keys.isEmpty ? nil : Curve(keys: keys.sorted { $0.t < $1.t })
        }
        if let m = args.optBool("muted") { bus.muted = m }
        if let s = args.optBool("solo") { bus.solo = s }
        if args.has("type") || args.has("effect_id") {
            if let t = args.optString("type"), !EffectCatalog.isAudio(t) { throw EditError("Buses take audio effects (audio.* or an Audio Unit); \(t) isn't one") }
            var o: [String: JSON] = [:]
            for (from, to) in [("effect_id", "id"), ("type", "type"), ("params", "params"), ("index", "index"), ("mix", "mix"), ("enabled", "enabled"), ("remove_effect", "remove")] {
                if let v = args.raw[from] { o[to] = v }
            }
            var probe = Track(id: id, kind: .audio, name: bus.name, effects: bus.effects)
            let plan = try Toolbox.planEffect(&probe.effects, Args(raw: o), owner: "bus \(id)")
            for (path, v) in plan.values { try probe.set(path, v) }
            bus.effects = probe.effects
            notes.append(Toolbox.describePlan(plan, effects: probe.effects, owner: "bus \(id)").replacingOccurrences(of: " Animate with param_set path fx.\(plan.effectId).<param>.", with: ""))
        }
        p.buses[i] = bus
        for t in args.strings("tracks") ?? [] {
            guard let ti = p.trackIndex(t) else { throw EditError("No track \(t)") }
            p.tracks[ti].output = id
        }
        let fed = p.tracks.filter { $0.output == id }.map(\.id) + p.buses.filter { $0.output == id }.map { "bus " + $0.id }
        let sent = p.tracks.filter { $0.sends.contains { $0.bus == id } }.map(\.id)
        var line = "\(action == "add" ? "Added" : "Updated") bus \(id) \"\(bus.name)\" → \(bus.output ?? "master")" + Describe.busFlags(bus)
        line += fed.isEmpty && sent.isEmpty ? ". Nothing feeds it yet: track_update output:\"\(id)\" or sends." : ". Fed by " + (fed + sent.map { "send from \($0)" }).joined(separator: ", ") + "."
        return ([line] + notes).joined(separator: "\n")
    }

    /// track_update output and sends. Sends merge by bus; `remove:true` drops one, [] clears them.
    static func applyTrackRouting(_ t: inout Track, _ args: Args) throws {
        if let o = args.optString("output") { t.output = o == "master" || o.isEmpty ? nil : o }
        guard let list = args.raw["sends"]?.array else { return }
        if list.isEmpty { t.sends = []; return }
        for item in list {
            let s = Args(item)
            let bus = try s.string("bus")
            if s.bool("remove", default: false) {
                t.sends.removeAll { $0.bus == bus }
                continue
            }
            var send = t.sends.first { $0.bus == bus } ?? AudioSend(bus: bus)
            if let db = s.optDouble("level_db") { send.levelDb = db }
            if let pre = s.optBool("pre_fader") { send.preFader = pre }
            if let i = t.sends.firstIndex(where: { $0.bus == bus }) { t.sends[i] = send } else { t.sends.append(send) }
        }
    }

    static let trackRoutingSchema: [String: JSON] = [
        "output": Schema.string("Bus the track feeds after its fader (audio_bus), or \"master\""),
        "sends": ["type": "array", "description": "Sends into buses, merged by bus: [{bus, level_db (default 0), pre_fader (default false), remove}]; [] removes every send", "items": Schema.object([
            "bus": Schema.string("Bus id"),
            "level_db": Schema.number("Send level in dB, ≤ +12 (−96 is off)"),
            "pre_fader": Schema.bool("Take the sound before the track fader and its automation"),
            "remove": Schema.bool("Remove this send"),
        ])],
    ]

    func dmeBuses(_ a: Args, dry: Bool) throws -> ToolResult {
        let b = try session.requireBundle()
        let current = try session.project()
        let roles = current.roles(transcripts: b.transcripts(for: current))
        return try runEdit("Route tracks to DIA/MUS/FX buses", dry: dry) { p in
            let lines = p.applyDMEBuses(roles: roles, compressor: a.bool("compressor", default: true), limiter: a.bool("limiter", default: true))
            if lines.isEmpty { return "Already routed to DIA/MUS/FX; nothing changed." }
            return "DME buses: " + lines.joined(separator: "; ") + ". Change a track's bus with track_update output, the buses with audio_bus. Deliver one file per bus plus M&E with export deliver:\"stems\" stems:\"buses\"."
        }
    }

    /// One audio file per role (clip roles included) or per bus feeding the master, plus M&E, pre-master.
    func deliverStems(_ args: Args, project p: Project, bundle b: ProjectBundle, range: TimeRange?, name stem: String) async throws -> ToolResult {
        let format = try args.enumValue("audio_format", Delivery.AudioFormat.self) ?? .wav24
        let layout = try args.enumValue("downmix", AudioLayout.self)
        let mode = args.optString("stems") ?? "roles"
        guard mode == "roles" || mode == "buses" else { throw EditError("stems is roles or buses") }
        if mode == "buses", p.buses.isEmpty { throw EditError("The project has no buses; add them with audio_bus or recipe dme_buses, or deliver stems by roles") }
        let dir = args.optString("path").map { session.resolve($0) } ?? b.exportsURL.appendingPathComponent(stem + " stems", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var base = p
        base.master.effects = []
        base.master.loudnessTarget = nil
        let roles = p.roles(transcripts: b.transcripts(for: p))
        let used = base.audioRoles(roles)
        var jobs: [(label: String, project: Project, detail: String)] = []
        if mode == "roles" {
            for (role, tracks) in used.sorted(by: { $0.key < $1.key }) {
                jobs.append((role, base.keepingRoles(roles) { $0 == role }, tracks.joined(separator: ", ")))
            }
        } else {
            for bus in base.topLevelBuses {
                let feeding = Describe.feeders(of: bus.id, in: base)
                jobs.append((bus.name == bus.id ? bus.id : "\(bus.id) \(bus.name)", base.isolatingBus(bus.id), feeding.joined(separator: ", ")))
            }
            if base.hasDirectSound {
                jobs.append(("direct", base.isolatingBus(nil), base.tracks.filter { $0.output == nil && !$0.muted && !$0.clips.isEmpty }.map(\.id).joined(separator: ", ")))
            }
        }
        if args.bool("music_and_effects", default: mode == "buses"), used["dialogue"] != nil, used.count > 1 {
            jobs.append(("M&E", base.keepingRoles(roles) { $0 != "dialogue" }, "everything but dialogue"))
        }
        var lines: [String] = []
        for job in jobs {
            let url = dir.appendingPathComponent("\(stem) - \(job.label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-"))").appendingPathExtension(format.fileExtension)
            try await Delivery.audio(try await session.timeline(for: job.project), range: range, to: url, format: format, layout: layout)
            lines.append("\(job.label): \(url.lastPathComponent) (\(job.detail))")
        }
        var notes = ["Stems are pre-master (master effects\(p.master.loudnessTarget == nil ? "" : " and loudness target") off), so they sum back to the mix."]
        if mode == "buses" {
            if p.buses.contains(where: { $0.output != nil }) { notes.append("Buses feeding other buses are inside their parent's stem.") }
        } else {
            notes.append("Set roles with track_update role, a clip's subrole with param_set audio.role" + (p.buses.isEmpty ? "." : "; stems:\"buses\" writes one file per bus."))
        }
        return .text("Wrote \(jobs.count) stems to \(dir.path):\n" + lines.joined(separator: "\n") + "\n" + notes.joined(separator: " "))
    }
}

extension Describe {
    static func busFlags(_ b: AudioBus) -> String {
        var f: [String] = []
        if b.muted { f.append("muted") }
        if b.solo { f.append("solo") }
        if b.volume != 1 { f.append(String(format: "vol %.2f (%+.1f dB)", b.volume, b.volume > 0 ? 20 * log10(b.volume) : -96)) }
        if let c = b.volumeCurve { f.append("automation \(c.keys.count) keys") }
        if let l = b.layout { f.append(l.title) }
        let fx = b.effects.map { "\($0.id)(\($0.type))\($0.enabled ? "" : " off")" }
        return (f.isEmpty ? "" : " [" + f.joined(separator: ", ") + "]") + (fx.isEmpty ? "" : " fx " + fx.joined(separator: " → "))
    }

    /// Tracks and buses feeding a bus, directly or through others.
    static func feeders(of id: String, in p: Project) -> [String] {
        var out = p.tracks.filter { $0.output == id }.map(\.id) + p.tracks.filter { $0.sends.contains { $0.bus == id } }.map { "\($0.id) send" }
        for child in p.buses where child.output == id { out += ["bus \(child.id)"] + feeders(of: child.id, in: p) }
        return out
    }

    /// The routing tree from the master down, and clips whose role differs from their track's.
    static func routing(_ p: Project) -> [String] {
        var lines: [String] = []
        if p.usesBuses {
            lines.append("Mix routing (bus mix renders offline; tracks → buses → master):")
            func describe(_ t: Track) -> String {
                "track \(t.id) \"\(t.name)\"" + (t.muted ? " [muted]" : "") + (t.volume != 1 ? String(format: " vol %.2f", t.volume) : "")
            }
            func children(of bus: String?, depth: Int) {
                let pad = String(repeating: "  ", count: depth + 2)
                for t in p.tracks where t.output == bus && t.clips.contains(where: { $0.kind == .media || $0.kind == .sequence }) { lines.append(pad + describe(t)) }
                if let bus {
                    for t in p.tracks {
                        for s in t.sends where s.bus == bus { lines.append(pad + "send from \(t.id) " + String(format: "%+.1f dB", s.levelDb) + (s.preFader ? " pre-fader" : " post-fader")) }
                    }
                }
                for b in p.buses where b.output == bus {
                    lines.append(pad + "bus \(b.id) \"\(b.name)\"" + busFlags(b))
                    children(of: b.id, depth: depth + 1)
                }
            }
            lines.append("  master" + String(format: " gain %+.1f dB", p.master.gainDb) + (p.master.effects.isEmpty ? "" : " fx " + p.master.effects.map { "\($0.id)(\($0.type))" }.joined(separator: " → ")))
            children(of: nil, depth: 0)
        }
        var roles: [String] = []
        for t in p.tracks { for c in t.clips where c.role != nil && c.role != t.role { roles.append("\(c.id) \(c.role!)") } }
        if !roles.isEmpty { lines.append("Clip roles: " + roles.prefix(12).joined(separator: ", ") + (roles.count > 12 ? " …and \(roles.count - 12) more" : "")) }
        return lines
    }
}
