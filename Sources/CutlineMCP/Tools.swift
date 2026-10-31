import CutlineCore
import CutlineEngine
import Foundation

struct ToolResult {
    var content: [JSON] = []
    var isError = false

    static func text(_ s: String) -> ToolResult { ToolResult(content: [["type": "text", "text": .string(s)]]) }

    mutating func addText(_ s: String) { content.append(["type": "text", "text": .string(s)]) }

    mutating func addImage(_ data: Data, mime: String = "image/jpeg") {
        content.append(["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mime)])
    }

    var json: JSON { ["content": .array(content), "isError": .bool(isError)] }

    var plainText: String { content.compactMap { $0["text"]?.string }.joined(separator: "\n") }
}

struct Tool {
    let name: String
    let description: String
    let schema: JSON
    let run: (Args) async throws -> ToolResult
}

/// An edit that can run alone or inside `batch`. Returns a one-line summary.
struct EditTool {
    let name: String
    let description: String
    let schema: JSON
    let label: (Args, Project) -> String
    let apply: (inout Project, Args) throws -> String
}

final class Toolbox {
    let session = Session()
    let resolverBox = AnchorResolvers()
    private(set) var tools: [String: Tool] = [:]
    private(set) var order: [String] = []
    private(set) var edits: [String: EditTool] = [:]
    /// Argument names the last recipe call read.
    var lastRecipeReads: ArgReads?

    init() {
        registerProjectTools()
        registerMediaTools()
        registerEditTools()
        registerLookTools()
        registerTransitionTools()
        registerTrimTool()
        registerPatchTool()
        registerTemplateTool()
        registerNestTool()
        registerMulticamTools()
        registerTrackTool()
        registerAnalysisTools()
        registerExportTools()
        registerAudioTools()
        registerBatchTool()
        registerReviewTools()
        registerVoiceOverTool()
        registerCaptionTools()
        registerBinTools()
        registerTimelineTools()
    }

    func add(_ tool: Tool) {
        tools[tool.name] = tool
        order.append(tool.name)
    }

    func addEdit(_ e: EditTool) {
        edits[e.name] = e
        add(Tool(name: e.name, description: e.description, schema: Toolbox.withDryRun(e.schema)) { [unowned self] args in
            try await registerPlugins(args)
            await primeChannels(args, try session.project())
            let before = try session.project()
            if args.bool("dry_run", default: false) {
                var p = before
                let summary = try e.apply(&p, args)
                p.pruneTransitions()
                try p.validate()
                return .text("Dry run, nothing changed.\n" + summary + Toolbox.changesText(p, before))
            }
            var summary = ""
            let p = try session.edit(e.label(args, before)) { summary = try e.apply(&$0, args) }
            let analyzed = try await self.session.analyzeMotion(p)
            if !analyzed.isEmpty { try? self.session.sendPreview(["action": "rebuild"]) }
            let queued = self.session.queuePictures(p).map { "\n" + $0 }.joined()
            return .text(summary + Toolbox.changesText(p, before) + self.newIssues(p, before) + (analyzed.isEmpty ? "" : "\nAnalyzed camera motion of " + analyzed.joined(separator: ", ")) + queued + "\n" + self.footer(p))
        })
    }

    static func withDryRun(_ schema: JSON) -> JSON {
        guard case .object(var o) = schema, case .object(var props)? = o["properties"] else { return schema }
        props["dry_run"] = Schema.bool("Report what would change without applying it")
        o["properties"] = .object(props)
        return .object(o)
    }

    /// The structural diff of an edit, capped so responses stay small.
    static func changesText(_ p: Project, _ before: Project) -> String {
        let lines = p.changes(from: before)
        guard !lines.isEmpty else { return "\nNo changes." }
        let shown = lines.prefix(14).map { "  " + $0 }
        return "\nChanges:\n" + shown.joined(separator: "\n") + (lines.count > 14 ? "\n  …and \(lines.count - 14) more" : "")
    }

    /// Lets time arguments use anchors ("talk.w12", "clip_x.end", "marker:Intro") for this project state.
    func installResolvers(_ p: Project?) {
        guard let p, let b = session.bundle else {
            Args.timelineResolver = nil
            Args.sourceResolver = nil
            return
        }
        let transcripts = b.transcripts(for: p)
        let index = b.anchorIndex(for: p)
        Args.timelineResolver = { try p.resolveTime($0, transcripts: transcripts, index: index) }
        Args.sourceResolver = { try p.resolveSourceTime($0, transcripts: transcripts, index: index) }
    }

    var definitions: [JSON] { order.compactMap { tools[$0].map(Toolbox.listing) } }

    func call(_ name: String, _ args: JSON?) async -> ToolResult {
        await Args.$resolvers.withValue(Args.resolvers ?? resolverBox) { await callResolved(name, args) }
    }

    private func callResolved(_ name: String, _ args: JSON?) async -> ToolResult {
        guard let tool = tools[name] else {
            var r = ToolResult.text("Unknown tool \(name)")
            r.isError = true
            return r
        }
        do {
            var given = name == "batch" ? Toolbox.liftingBatchNames(args) : try args.map { try Toolbox.resolveLast(Toolbox.substitute($0, session.names, skippingText: true), session.lastRefs) }
            var alias: String?
            if name != "batch", case .object(var o)? = given, let v = o.removeValue(forKey: "as") {
                guard let s = v.string, Toolbox.isName(s) else { throw EditError("as names what this call creates for \"$name\" in later calls: letters, digits and _, e.g. as:\"intro\"") }
                alias = s
                given = .object(o)
            }
            let args = try resolvingAliases(name, given, schema: tool.schema)
            try checkArguments(name, args, schema: tool.schema)
            let project = try? session.project()
            installResolvers(project)
            let resolved = try args.map { try Toolbox.resolveMediaAliases($0, media: project?.media ?? []) }
            var result = try await tool.run(Args(resolved))
            let after = try? session.project()
            var notes: [String] = []
            if !result.isError, let note = recordCreated(name, before: project, after: after) { notes.append(note) }
            if !result.isError, let alias {
                let dry = resolved?["dry_run"]?.bool == true
                if !dry, let made = after.flatMap({ Toolbox.created(project, $0).first?.ids.first }) {
                    session.names[alias] = made
                    notes.append("$\(alias) = \(made)")
                } else {
                    notes.append("as:\"\(alias)\" named nothing: this call \(dry ? "was a dry run" : "created no clip, effect, track or media")")
                }
            }
            if !notes.isEmpty, let i = result.content.firstIndex(where: { $0["text"]?.string != nil }), let text = result.content[i]["text"]?.string {
                result.content[i] = ["type": "text", "text": .string(text + "\n" + notes.joined(separator: "; "))]
            }
            return result
        } catch {
            var r = ToolResult.text("Error: \(error.localizedDescription)")
            r.isError = true
            return r
        }
    }

    /// Short state line appended to edit results.
    func footer(_ p: Project) -> String {
        let h = session.bundle?.loadHistory().current
        return "Timeline \(Frames.timecode(p.duration)) · \(p.tracks.map { "\($0.id):\($0.clips.count)" }.joined(separator: " ")) · history \(h?.id ?? "-")" + (session.jobs.statusLine.map { " · " + $0 } ?? "") + (session.renders.statusLine.map { " · " + $0 } ?? "")
    }
}

// MARK: Argument names

extension Toolbox {
    /// Rejects argument names a tool's schema doesn't declare, at the top level and inside nested objects
    /// whose schema lists properties. Batch operations are checked against their edit tool's schema.
    func checkArguments(_ tool: String, _ args: JSON?, schema: JSON) throws {
        var problems = Toolbox.unknownArguments(args ?? [:], schema: schema, path: "")
        if tool == "batch", let ops = args?["operations"]?.array {
            for (i, op) in ops.enumerated() {
                guard let name = op["tool"]?.string, let e = edits[name], let opArgs = op["args"], opArgs.object != nil else { continue }
                problems += Toolbox.unknownArguments(opArgs, schema: Toolbox.withDryRun(e.schema), path: "operations[\(i)].args.")
                    .map { "\($0) (for \(name))" }
            }
        }
        if !problems.isEmpty { throw EditError("\(tool) doesn't take " + problems.joined(separator: "; ") + ".") }
        let unusable = args?.unusableNumbers() ?? []
        if !unusable.isEmpty { throw EditError("\(unusable.joined(separator: ", ")) must be a finite number within ±\(Int(JSON.numberLimit))") }
        var invalid = Toolbox.invalidValues(args ?? [:], schema: schema, path: "", name: "")
        if tool == "batch", let ops = args?["operations"]?.array {
            for (i, op) in ops.enumerated() {
                guard let name = op["tool"]?.string, let e = edits[name], let opArgs = op["args"] else { continue }
                invalid += Toolbox.invalidValues(opArgs, schema: e.schema, path: "", name: "").map { "operations[\(i)] (\(name)): " + $0 }
            }
        }
        if !invalid.isEmpty { throw EditError(invalid.joined(separator: "\n")) }
        if tool == "recipe", let name = args?["name"]?.string {
            let issues = Toolbox.recipeArgumentProblems(name, args?["args"])
            if !issues.isEmpty { throw EditError("recipe \(name): " + issues.joined(separator: "; ") + (Toolbox.recipe(name) == nil ? "." : ". catalog recipe=\(name) lists its arguments.")) }
        }
    }

    /// "name (did you mean x?)" for every key of `value` its schema doesn't declare.
    static func unknownArguments(_ value: JSON, schema: JSON, path: String) -> [String] {
        switch value {
        case .object(let o):
            guard let props = schema["properties"]?.object else { return [] }
            var out: [String] = []
            for (k, v) in o.sorted(by: { $0.key < $1.key }) {
                if let sub = props[k] {
                    out += unknownArguments(v, schema: sub, path: path + k + ".")
                } else {
                    let names = props.keys.sorted()
                    let close = names.map { ($0, editDistance($0, k)) }.filter { $0.1 <= max(2, k.count / 3) || $0.0.hasPrefix(k) || k.hasPrefix($0.0) }.sorted { $0.1 < $1.1 }.prefix(3).map(\.0)
                    out.append("'\(path)\(k)'" + (close.isEmpty ? " (arguments: \(names.joined(separator: ", ")))" : " (did you mean \(close.joined(separator: " or "))?)"))
                }
            }
            return out
        case .array(let a):
            guard let items = schema["items"] else { return [] }
            return a.enumerated().flatMap { unknownArguments($0.element, schema: items, path: String(path.dropLast()) + "[\($0.offset)].") }
        default:
            return []
        }
    }
}

extension Toolbox {
    /// History label for effect_add: add, update, turn on/off, reorder or remove, named by the effect's type.
    static func describeEffectEdit(_ a: Args, _ p: Project) -> String {
        let target = targetLabel(a.raw["target"], p)
        let id = a.optString("id")
        let all = p.tracks.flatMap { $0.effects + $0.clips.flatMap(\.effects) } + p.master.effects
        let existing = id.flatMap { id in all.first { $0.id == id } }
        let name = (a.optString("type") ?? existing?.type).map { EffectCatalog.title($0) } ?? id ?? "effect"
        if a.bool("remove", default: false) { return "Remove \(name) from \(target)" }
        guard existing != nil else { return "Add \(name) to \(target)" }
        let changes = Set(a.raw.keys).subtracting(["target", "id", "type", "dry_run"])
        if changes == ["enabled"] { return (a.bool("enabled", default: true) ? "Turn on \(name) on " : "Turn off \(name) on ") + target }
        if changes == ["index"] { return "Reorder \(name) on \(target)" }
        if changes == ["mix"] { return "Set \(name) mix on \(target)" }
        return "Adjust \(name) on \(target)"
    }
}

// MARK: Formatting

enum Describe {
    static func project(_ p: Project, bundle: ProjectBundle, mix: LoudnessReport? = nil) -> String {
        var lines: [String] = []
        let history = bundle.loadHistory()
        lines.append("Project \"\(p.name)\" at \(bundle.url.path)")
        lines.append("Canvas \(p.canvas.width)×\(p.canvas.height)" + (p.canvas.colorSpace == .rec709 ? "" : " \(p.canvas.colorSpace.rawValue)") + " @\(fmtFps(p.canvas.fps))fps, background \(p.canvas.background.hex), duration \(Frames.timecode(p.duration)) (\(fmt(p.duration))s), start timecode \(p.canvas.startTimecode)")
        if let cur = history.current { lines.append("History \(cur.id) \"\(cur.label)\" (\(history.cursor + 1)/\(history.entries.count))") }
        lines.append("")
        lines.append("Media:")
        if p.media.isEmpty { lines.append("  (none — call media_import)") }
        for m in p.media {
            var a: [String] = []
            if let t = bundle.transcript(m.id) { a.append("transcript \(t.words.count) words") }
            if let au = bundle.audioAnalysis(m.id) { a.append("\(au.silences.filter { $0.duration >= 0.5 }.count) pauses") }
            if let shots = bundle.analysis(ShotAnalysis.self, m.id, "shots"), !m.isImage {
                a.append("\(shots.shots.count) shots")
            } else if let v = bundle.visualAnalysis(m.id), !v.sceneCuts.isEmpty {
                a.append("\(Shot.spans(cuts: v.sceneCuts, duration: m.duration).count) shots from \(v.sceneCuts.count) scene cuts")
            }
            if let raw = m.raw {
                a.append("camera RAW \(raw.summary)" + (m.isTranscoding ? ", developing from \(m.conformPath)" : m.isImage ? "" : ", developed copy of \(m.conformPath)"))
            } else {
                if let log = m.log { a.append("log \(log.rawValue)") }
                if let t = m.transcoded { a.append(m.isTranscoding ? "transcoding from \(m.conformPath)" : "ProRes mezzanine of \(m.conformPath) (\(t))") }
            }
            if m.isInterlaced { a.append(Toolbox.interlaceNote(m)) }
            if let tc = Toolbox.sourceTimecodeNote(m) { a.append(tc) }
            if let ch = m.channelSummary { a.append(ch) }
            if let tags = m.tags, !tags.isEmpty { a.append("tags " + tags.map { tag in tag.rating.map { "\(tag.label) (\($0))" } ?? tag.label }.joined(separator: ", ")) }
            let kind = m.isImage ? "image" : [m.hasVideo ? "video" : nil, m.hasAudio ? "audio" : nil].compactMap { $0 }.joined(separator: "+")
            let dims = m.hasVideo ? " \(m.width)×\(m.height)" + (m.isImage ? "" : " \(fmtFps(m.fps))fps") : ""
            let missing = FileManager.default.fileExists(atPath: m.path) ? "" : " MISSING FILE"
            lines.append("  \(m.id): \(kind)\(dims)" + (m.isImage ? "" : " \(fmt(m.duration))s") + (a.isEmpty ? "" : " · " + a.joined(separator: ", ")) + missing)
        }
        lines.append("")
        lines.append("Tracks (listed top layer first):")
        for t in p.tracks.reversed() {
            var flags: [String] = []
            if t.muted { flags.append("muted") }
            if t.hidden { flags.append("hidden") }
            if t.volume != 1 { flags.append("vol \(fmt2(t.volume))") }
            let fx = t.effects.isEmpty ? "" : " fx " + t.effects.map { "\($0.id)(\($0.type))" }.joined(separator: " → ")
            lines.append("  \(t.id) \(t.kind.rawValue) \"\(t.name)\"\(flags.isEmpty ? "" : " [" + flags.joined(separator: ", ") + "]"): \(t.clips.count) clips\(fx)")
            for c in t.clips { lines.append("    " + clip(c, p)) }
        }
        lines.append("")
        let cs = p.captions
        if p.master.gainDb != 0 || !p.master.effects.isEmpty || p.master.layout != .stereo {
            lines.append("Master: \(p.master.layout.title), gain \(fmt1(p.master.gainDb)) dB" + (p.master.effects.isEmpty ? "" : ", fx " + p.master.effects.map { "\($0.id)(\($0.type))" }.joined(separator: " → ")))
        }
        if let target = p.master.targetSummary {
            let drift = mix.flatMap { p.master.drift(integrated: $0.integrated, truePeak: $0.truePeakDb) } ?? "not measured since the last mix change (timeline_measure what:[\"sound\"] shows the drift)"
            lines.append("Loudness target: \(target), conformed at export; \(drift)")
        }
        lines += routing(p)
        lines.append("Captions: " + (cs.enabled ? "on, \(cs.style.animation.rawValue), size \(fmt2(cs.style.size)), y \(fmt2(cs.style.y)), \(cs.style.maxWordsPerLine) words/line" : "off"))
        if !p.transitions.isEmpty { lines.append("Transitions: " + p.transitions.map { "\($0.id) \($0.type) \(fmt2($0.duration))s \($0.from ?? "∅")→\($0.to ?? "∅")" }.joined(separator: ", ")) }
        if !p.markers.isEmpty { lines.append("Markers: " + p.markers.map { "\(fmt2($0.time)) \($0.label)" + ($0.kind.map { " [\($0)]" } ?? "") }.joined(separator: ", ")) }
        let open = bundle.loadComments().comments.filter { $0.status == .open }
        lines.append("Comments: \(open.count) open" + (open.isEmpty ? "" : " — call comments_list"))
        let w = warnings(p, transcripts: bundle.transcripts(for: p))
        if !w.isEmpty {
            lines.append("")
            lines.append("Warnings:")
            lines += w.map { "  - " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    static func clip(_ c: Clip, _ p: Project) -> String {
        var s = "\(c.id)  \(fmt(c.start))–\(fmt(c.end))  "
        switch c.kind {
        case .media:
            s += "\(c.mediaId ?? "?")"
            if let m = c.mediaId.flatMap(p.mediaAsset), !m.isImage { s += " [src \(fmt(c.sourceIn))–\(fmt(c.sourceOut))]" }
        case .text: s += "text \"\(c.text?.text.prefix(40) ?? "")\""
        case .solid: s += "solid \(c.color?.hex ?? "")"
        case .adjustment: s += "adjustment layer"
        case .generator: s += "generator " + (c.effects.first.map(\.type) ?? "?")
        case .sequence where p.multicamSetup(c) != nil:
            let setup = p.multicamSetup(c)!
            let ranges = p.visibleAngleRanges(c)
            s += "multicam \"\(c.mediaId.flatMap { p.sequence($0)?.name } ?? "?")\" [\(setup.angles.count) angles: " + setup.angles.map(\.name).joined(separator: ", ") + "; \(ranges.count) range(s), starts on \(ranges.first?.angle ?? "?")]"
        case .sequence:
            let seq = c.mediaId.flatMap { p.sequence($0) }
            s += "nested \"\(seq?.name ?? "?")\" [\(fmt(c.sourceIn))–\(fmt(c.sourceIn + c.duration)) of \(fmt(seq?.duration ?? 0))s, \(seq?.tracks.flatMap(\.clips).count ?? 0) clips]"
        }
        var extra: [String] = []
        if c.speed != 1 { extra.append("speed \(fmt2(c.speed))") }
        if let link = c.link { extra.append("linked with " + p.linked(c.id).joined(separator: ",").ifEmptyText(link)) }
        if c.volume != 1 { extra.append("vol \(fmt2(c.volume))") }
        if c.fadeIn > 0 || c.fadeOut > 0 { extra.append("fade \(fmt2(c.fadeIn))/\(fmt2(c.fadeOut))") }
        if c.audioFadeIn > 0 || c.audioFadeOut > 0 { extra.append("audio fade \(fmt2(c.audioFadeIn))/\(fmt2(c.audioFadeOut))") }
        if c.audioLead != 0 { extra.append("audio leads \(fmt2(c.audioLead))s") }
        if c.audioLag != 0 { extra.append("audio lags \(fmt2(c.audioLag))s") }
        if let ch = c.channels, ch != .stereo { extra.append("channels \(ch.rawValue)") }
        let t = c.transform
        if t != Transform() {
            var parts: [String] = []
            if t.fit != .fit { parts.append(t.fit.rawValue) }
            if t.scale != 1 { parts.append("scale \(fmt2(t.scale))") }
            if t.x != 0 || t.y != 0 { parts.append("pos \(fmt2(t.x)),\(fmt2(t.y))") }
            if t.rotation != 0 { parts.append("rot \(fmt1(t.rotation))°") }
            if t.opacity != 1 { parts.append("opacity \(fmt2(t.opacity))") }
            if !t.crop.isEmpty { parts.append("crop") }
            extra.append(parts.joined(separator: " "))
        }
        if c.blend != .normal { extra.append("blend \(c.blend.rawValue)") }
        if !c.effects.isEmpty { extra.append("fx " + c.effects.map { $0.enabled ? $0.id : "\($0.id)(off)" }.joined(separator: ",")) }
        if !c.anim.isEmpty { extra.append("animates " + c.anim.keys.sorted().joined(separator: ",")) }
        return s + (extra.isEmpty ? "" : "  (" + extra.joined(separator: ", ") + ")")
    }

    /// Every parameter of one clip, for project_status with a target.
    static func clipParams(_ c: Clip, _ p: Project) -> String {
        var lines = ["\(clip(c, p))", "Parameters (set with param_set; animated values show their keys):"]
        for (path, value, keys) in c.parameterTree() {
            var line = "  \(path) = \(value)"
            if keys > 0, let curve = c.anim[path] {
                line += "  animated: " + curve.keys.prefix(8).map { "\(fmt2($0.t))s→\($0.v)\($0.ease == .easeInOut ? "" : " " + $0.ease.rawValue)" }.joined(separator: ", ")
                if curve.keys.count > 8 { line += " …(\(curve.keys.count) keys)" }
            }
            lines.append(line)
        }
        if c.effects.isEmpty { lines.append("Effects: none (effect_add to add; catalog lists types)") }
        else if let graph = EffectNodes.describe(c.effects) { lines.append(graph) }
        else { lines.append("Effects, applied in order: " + c.effects.map { "\($0.id) \($0.type)\($0.enabled ? "" : " (off)")" }.joined(separator: " → ")) }
        for e in c.effects { if let r = e.sourceRange { let t = c.timelineSpan(ofSource: r); lines.append("\(e.id) acts only in the shot at \(fmt2(t.start))–\(fmt2(t.end))s (source \(fmt2(r.start))–\(fmt2(r.end))s); effect_add id:\(e.id) scope:\"clip\" lifts that") } }
        lines.append("Key times are seconds from the clip start (\(fmt2(c.start)) on the timeline).")
        return lines.joined(separator: "\n")
    }

    static func warnings(_ p: Project, transcripts: [String: Transcript] = [:]) -> [String] {
        var out = p.qualityIssues(transcripts: transcripts)
        for m in p.media where !FileManager.default.fileExists(atPath: m.path) { out.append("media \(m.id) is missing at \(m.path)") }
        return out
    }

    /// Sentences from words, breaking on punctuation and long gaps.
    struct Sentence<W> {
        var start: Seconds
        var end: Seconds
        var text: String
        var pauseAfter: Seconds?
        var first: W
        var last: W
    }

    /// Sentences from words, breaking on punctuation and long gaps.
    static func sentences<W>(_ words: [W], text: (W) -> String, start: (W) -> Seconds, end: (W) -> Seconds) -> [Sentence<W>] {
        var out: [Sentence<W>] = []
        var cur: [W] = []
        func flush(gapAfter: Seconds?) {
            guard let f = cur.first, let l = cur.last else { return }
            out.append(Sentence(start: start(f), end: end(l), text: cur.map(text).joined(separator: " "), pauseAfter: gapAfter, first: f, last: l))
            cur = []
        }
        for (i, w) in words.enumerated() {
            cur.append(w)
            let next = i + 1 < words.count ? words[i + 1] : nil
            let gap = next.map { start($0) - end(w) }
            let endsSentence = text(w).last.map { ".?!".contains($0) } ?? false
            if next == nil || endsSentence || (gap ?? 0) > 0.7 || cur.count >= 30 {
                flush(gapAfter: gap.flatMap { $0 > 0.4 ? $0 : nil })
            }
        }
        return out
    }

    static func fmtFps(_ f: Double) -> String { f.rounded() == f ? String(Int(f)) : String(format: "%.3f", f) }
}

extension Toolbox {
    /// Issues an edit introduced, for the edit's response.
    func newIssues(_ p: Project, _ before: Project) -> String {
        guard let b = session.bundle else { return "" }
        let tr = b.transcripts(for: p)
        let fresh = Set(p.qualityIssues(transcripts: tr)).subtracting(before.qualityIssues(transcripts: b.transcripts(for: before)))
        guard !fresh.isEmpty else { return "" }
        return "\nCheck: " + fresh.sorted().prefix(5).joined(separator: "; ")
    }
}

extension Toolbox {
    /// Describes Audio Unit plug-ins named in the arguments or used by the project, so their
    /// parameters validate like built-in effects.
    func registerPlugins(_ args: Args) async throws {
        var ids = Set<String>()
        if let t = args.raw["type"]?.string, ProAudioCatalog.isPlugin(t) { ids.insert(t) }
        if let p = try? session.project() {
            for e in p.tracks.flatMap({ $0.effects + $0.clips.flatMap(\.effects) }) + p.master.effects + p.buses.flatMap(\.effects) where ProAudioCatalog.isPlugin(e.type) { ids.insert(e.type) }
        }
        for id in ids where PluginRegistry.type(id) == nil {
            try await Toolbox.registerPlugin(id)
        }
    }

    @discardableResult
    static func registerPlugin(_ id: String) async throws -> EffectType {
        if let t = PluginRegistry.type(id) { return t }
        guard let info = AudioUnitHost.installedEffects().first(where: { $0.id == id }) else {
            throw EditError("No installed Audio Unit \(id); catalog plugins:true lists them")
        }
        let params = try await AudioUnitHost.parameters(of: id).filter(\.writable)
        let presets = (try? await AudioUnitHost.presets(of: id)) ?? []
        var specs = params.map { p in
            ParamSpec(p.id, .number, .number(p.defaultValue), min: p.min, max: p.max, unit: p.unit, animatable: false, p.name + (p.values.map { " (" + $0.enumerated().map { "\($0.offset)=\($0.element)" }.joined(separator: ", ") + ")" } ?? ""))
        }
        if !presets.isEmpty { specs.append(ParamSpec(ProAudioCatalog.presetParam, .choice(presets), .string(presets[0]), "Factory preset, applied before the parameters")) }
        let t = EffectType(id: id, category: "audio", summary: "\(info.name) by \(info.manufacturer) (Audio Unit \(info.version))", params: specs)
        PluginRegistry.register(t)
        return t
    }
}
