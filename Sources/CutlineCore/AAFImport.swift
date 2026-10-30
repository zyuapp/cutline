import Foundation

extension Importer {
    /// AAF from Media Composer, Pro Tools, Resolve, Premiere or Cutline: the top-level CompositionMob (UsageCode
    /// TopLevel, or the one no other composition uses) becomes the timeline at its picture slots' edit rate, with
    /// its Timecode slot as the start timecode. Picture slots become video tracks; sound slots audio tracks, mono
    /// channel slots of the same clips (stereo pairs) joining one track, and sound in sync with a picture clip of the
    /// same master clip folds into it (as a split edit when its edges differ). Source clips resolve through master
    /// and source mobs to a file: the media is the first locator that exists (the original a file mob was imported
    /// from before Avid's own media), else the deepest one; its reel and source timecode come from the tape or import
    /// mob. Transitions become dissolves (dips stay dips), against filler fades; MonoAudioGain/Audio Gain Amplitude
    /// the clip's level or volume keyframes; Motion Control (Media Composer's offset maps, else SpeedRatio) and Video
    /// Repeat the clip's speed, reverse, freeze or ramp; Video Crop, Scale, Rotate, Position and Opacity, and Media
    /// Composer's 3D Warp scale and rotation, its picture (keyed when varying). Other effects pass their first
    /// input through with a note. Nested compositions are flattened. DescriptiveMarkers and CommentMarkers on event
    /// slots become markers. Media is never probed; files that don't exist stay offline.
    public static func aaf(_ data: Data, relativeTo base: URL?) throws -> ImportResult {
        let doc: AAFDocument
        do { doc = try AAFDocument(data: data) } catch { throw EditError("Not a readable AAF file: \(error.localizedDescription)") }
        return try AAFReader(doc, base: base).read()
    }
}

final class AAFReader {
    typealias Rate = (num: Int, den: Int)

    /// A stretch of a slot in its own edit units: a clip of media or nothing.
    struct Piece {
        var start: Int
        var length: Int
        var ref: Ref?
        /// A Cutline clip a filler carries in its comments.
        var embedded: Clip?
    }

    struct Ref {
        var media: String
        /// Seconds into the media at the piece's start.
        var source: Double
        var speed: Double = 1
        var gain: Double = 1
        /// Volume keys at slot positions (edit units, fractional).
        var keys: [(at: Double, gain: Double)] = []
        var name: String?
        var channel: Int?
        /// A muted clip (the alternate of a selector that plays nothing).
        var disabled = false
        /// Cutline's `SoundHint` for the clip around this sound.
        var hint: String?
        /// A grade note: CDL and LUT files.
        var grade: String?
        /// Motion Control: source frames from the input's first at output frames from the effect's start, as
        /// Cutline's time map (a reversed clip's first output frame at its source out).
        var warp: [(t: Double, v: Double)]?
        /// Picture effects' parameters by id.
        var picture: [AUID: ParamRead] = [:]
    }

    /// A parameter's constant, or its keys at slot positions (edit units).
    struct ParamRead {
        var constant: Double?
        var keys: [(at: Double, v: Double)] = []
    }

    /// A transition between the piece at `before` and the next one.
    struct Join {
        var before: Int
        var start: Int
        var length: Int
        var cut: Int
        var type: String
        /// Cutline's overlapping sounds, which their clips' sound hints restore.
        var overlap = false
    }

    struct SlotRead {
        var pieces: [Piece] = []
        var joins: [Join] = []
    }

    let doc: AAFDocument
    let base: URL?
    var warnings: [String] = []
    var missing: [String] = []
    var offline = Set<String>()
    var mobs: [[UInt8]: AAFObject] = [:]
    var parents: [AUID: AUID] = [:]
    var media: [MediaAsset] = []
    var mediaFor: [[UInt8]: String] = [:]
    var usedIds = Set<String>()
    var nestDepth = 0
    var opNames: [AUID: String] = [:]

    init(_ doc: AAFDocument, base: URL?) {
        self.doc = doc
        self.base = base
        for o in doc.header?.strong(0x3b03)?.objects(0x1901) ?? [] {
            if let id = o.bytes(0x4401) { mobs[id] = o }
        }
        for (id, def) in AAFMetaModel.shared.classes { parents[id] = def.parent }
        for c in doc.metaDictionary?.objects(0x0003) ?? [] {
            if let id = c.auid(0x0005), let parent = c.weak(0x0008) { parents[id] = AUID(bytes: parent.key) }
        }
        for op in doc.header?.strong(0x3b04)?.objects(0x2603) ?? [] {
            if let id = op.auid(0x1b01) { opNames[id] = op.string(0x1b02) ?? "" }
        }
    }

    func isA(_ o: AAFObject, _ cls: AUID) -> Bool {
        var c = o.classID
        for _ in 0..<32 {
            if c == cls { return true }
            guard let p = parents[c], p != c else { return false }
            c = p
        }
        return false
    }

    func dataKind(_ o: AAFObject) -> AUID? { o.weak(0x0201).map { AUID(bytes: $0.key) } }
    func rate(_ slot: AAFObject) -> Rate {
        let r = slot.rational(0x4b01) ?? slot.rational(0x4901) ?? (25, 1)
        return r.num > 0 && r.den > 0 ? (r.num, r.den) : (25, 1)
    }
    func seconds(_ units: Double, _ r: Rate) -> Double { units * Double(r.den) / Double(r.num) }
    func length(_ o: AAFObject) -> Int { Int(o.int(0x0202) ?? 0) }

    // MARK: Composition

    func topComposition() throws -> AAFObject {
        let compositions = mobs.values.filter { isA($0, AAFClass.compositionMob) }.sorted { ($0.string(0x4402) ?? "") < ($1.string(0x4402) ?? "") }
        guard !compositions.isEmpty else {
            let masters = mobs.values.filter { isA($0, AAFClass.masterMob) }.sorted { ($0.string(0x4402) ?? "") < ($1.string(0x4402) ?? "") }
            guard let m = masters.first else { throw EditError("This AAF has no sequence or master clip to import; it only describes media") }
            warnings.append("The AAF has no sequence; imported master clip \(m.string(0x4402) ?? "") as the timeline")
            return m
        }
        let top = compositions.filter { $0.auid(0x4408) == AAFDef.usageTopLevel }
        if top.count == 1 { return top[0] }
        var referenced = Set<[UInt8]>()
        for c in compositions {
            c.walk { o in if o.classID == AAFClass.sourceClip, let id = o.bytes(0x1101) { referenced.insert(id) } }
        }
        let candidates = (top.isEmpty ? compositions : top).filter { !referenced.contains($0.bytes(0x4401) ?? []) }
        let pool = candidates.isEmpty ? compositions : candidates
        if pool.count > 1 { warnings.append("The AAF has \(pool.count) top-level sequences; imported \(pool[0].string(0x4402) ?? "the first"), not \(pool.dropFirst().compactMap { $0.string(0x4402) }.joined(separator: ", "))") }
        return pool[0]
    }

    func read() throws -> ImportResult {
        let comp = try topComposition()
        let slots = comp.objects(0x4403)
        let timeline = slots.filter { isA($0, AAFClass.timelineMobSlot) }
        let picture = timeline.filter { s in s.strong(0x4803).flatMap(dataKind).map(AAFDef.pictureKinds.contains) ?? false }
        let sound = timeline.filter { s in s.strong(0x4803).flatMap(dataKind).map(AAFDef.soundKinds.contains) ?? false }
        let r = rate(picture.first ?? sound.first ?? timeline.first ?? AAFObject(AAFClass.timelineMobSlot))
        let fps = Importer.niceFps(Double(r.num) / Double(r.den))
        var canvas = Canvas(fps: fps)
        let frame = 1 / max(fps, 1)
        let grid = FrameGrid(fps: fps)

        if let tc = timeline.lazy.compactMap({ s -> AAFObject? in
            guard let seg = s.strong(0x4803) else { return nil }
            if seg.classID == AAFClass.timecode { return seg }
            return seg.classID == AAFClass.sequence ? seg.objects(0x1001).first { $0.classID == AAFClass.timecode } : nil
        }).first {
            if grid.num == 1001 { canvas.dropFrame = (tc.int(0x1503) ?? 0) != 0 }
            canvas.timecodeStart = canvas.timecodeStart(frames: Int(tc.int(0x1501) ?? 0))
        }

        var clipCount = 0, transitionCount = 0
        var transitions: [Transition] = []
        func nextClip() -> String { clipCount += 1; return "c\(clipCount)" }
        func nextTransition() -> String { transitionCount += 1; return "t\(transitionCount)" }

        /// Clips of one slot's segment, joined by Cutline transitions (picture) or fades and crossfades (sound), and its muted clips.
        func clips(_ seg: AAFObject, rate sr: Rate, kind: TrackKind) -> (clips: [Clip], disabled: [Clip]) {
            var read = SlotRead()
            var pos = 0
            self.read(seg, rate: sr, at: &pos, into: &read, wrap: Ref(media: "", source: 0))
            func sec(_ u: Int) -> Double { seconds(Double(u), sr) }
            var out: [(piece: Piece, clip: Clip)] = []
            var disabled: [Clip] = []
            var at: [Int: Int] = [:]
            for (i, piece) in read.pieces.enumerated() where piece.length > 0 {
                if var c = piece.embedded {
                    c.id = nextClip()
                    c.start = sec(piece.start)
                    c.duration = sec(piece.length)
                    at[i] = out.count
                    out.append((piece, c))
                    continue
                }
                guard let ref = piece.ref else { continue }
                var c = Clip(id: nextClip(), kind: .media, name: ref.name, mediaId: ref.media, start: sec(piece.start), duration: sec(piece.length), sourceIn: ref.source, speed: ref.speed)
                if let w = ref.warp, let warning = Importer.retime(&c, map: w.map { (seconds($0.t, sr), ref.source + seconds($0.v, sr)) }, tolerance: 0.1 * frame) {
                    warnings.append(warning)
                }
                if kind == .video { applyPicture(ref.picture, &c, rate: sr) }
                if kind == .audio || abs(ref.gain - 1) > 1e-9 { c.volume = ref.gain }
                if !ref.keys.isEmpty {
                    c.anim["audio.volume"] = Curve(keys: ref.keys.map { CurveKey(t: seconds($0.at, sr) - c.start, v: .number($0.gain * ref.gain), ease: .linear) })
                }
                if let ch = ref.channel { channelOf[c.id] = ch }
                if let g = ref.grade { c.effects = Importer.noteColor(g) }
                if ref.disabled { disabled.append(c); continue }
                at[i] = out.count
                out.append((piece, c))
            }
            for j in read.joins where !j.overlap {
                let a = at[j.before], b = at[j.before + 1]
                switch (a, b) {
                case let (a?, b?):
                    let cut = sec(j.start + j.cut)
                    out[a].clip = Project.trimmedRight(out[a].clip, to: cut)
                    out[b].clip = Project.trimmedLeft(out[b].clip, to: cut)
                    // A centered transition of odd length has its extra frame after the cut.
                    let al = j.length > 1 && j.cut == j.length / 2 ? (align: TransitionAlign.center, duration: sec(j.length), cutOffset: Seconds?.none)
                        : Importer.alignment(before: sec(j.cut), after: sec(j.length - j.cut), frame: frame)
                    var tr = Transition(id: nextTransition(), from: out[a].clip.id, to: out[b].clip.id, type: j.type, duration: al.duration, align: al.align, part: kind == .video ? .video : .audio)
                    tr.cutOffset = al.cutOffset
                    transitions.append(tr)
                case let (nil, b?):
                    if kind == .audio { out[b].clip.audioFadeIn = sec(j.length) } else {
                        transitions.append(Transition(id: nextTransition(), from: nil, to: out[b].clip.id, type: j.type, duration: sec(j.length), align: .start, part: .video))
                    }
                case let (a?, nil):
                    if kind == .audio { out[a].clip.audioFadeOut = sec(j.length) } else {
                        transitions.append(Transition(id: nextTransition(), from: out[a].clip.id, to: nil, type: j.type, duration: sec(j.length), align: .end, part: .video))
                    }
                default: break
                }
            }
            for i in out.indices {
                guard let text = out[i].piece.ref?.hint, let hint = SoundHint(text: text) else { continue }
                hint.apply(&out[i].clip, soundStart: grid.frames(sec(out[i].piece.start)), grid: grid)
            }
            return (out.map(\.clip).sorted { $0.start < $1.start }, disabled)
        }

        /// A slot's layers: the slots of a nested scope (Avid's collapsed tracks), bottom first, or the segment itself.
        func lanes(_ seg: AAFObject) -> [AAFObject] {
            if seg.classID == AAFClass.nestedScope { return seg.objects(0x0c01).flatMap(lanes) }
            if seg.classID == AAFClass.sequence, seg.objects(0x1001).count == 1, let only = seg.objects(0x1001).first, only.classID == AAFClass.nestedScope { return lanes(only) }
            return [seg]
        }

        var tracks: [Track] = []
        var hidden: [Track] = []
        for s in picture {
            for seg in lanes(s.strong(0x4803)!) {
                let n = tracks.count
                let name = s.string(0x4802).flatMap { $0.isEmpty ? nil : $0 } ?? (n == 0 ? "Main" : "Video \(n + 1)")
                let read = clips(seg, rate: rate(s), kind: .video)
                if read.clips.isEmpty, !tracks.isEmpty, read.disabled.isEmpty { continue }
                tracks.append(Track(id: "V\(n + 1)", kind: .video, name: name, clips: read.clips))
                if !read.disabled.isEmpty { hidden.append(Track(id: "VX", kind: .video, name: name + " (disabled)", hidden: true, clips: read.disabled)) }
            }
        }
        tracks += hidden
        // Channel slots of the same clips (stereo pairs, multichannel files) make one track.
        var groups: [(name: String?, clips: [Clip], channels: [[Int]])] = []
        var mutedSound: [Track] = []
        func signature(_ c: Clip) -> String { "\(c.mediaId ?? "")@\(Int((c.start / frame).rounded()))+\(Int((c.duration / frame).rounded()))<\(Int((c.sourceIn / frame).rounded()))" }
        for (s, seg) in sound.flatMap({ s in lanes(s.strong(0x4803)!).map { (s, $0) } }) {
            let read = clips(seg, rate: rate(s), kind: .audio)
            let cs = read.clips
            let name = s.string(0x4802).flatMap { $0.isEmpty ? nil : $0 }
            if !read.disabled.isEmpty { mutedSound.append(Track(id: "AX", kind: .audio, name: (name ?? "Audio") + " (disabled)", muted: true, clips: read.disabled)) }
            if cs.isEmpty { continue }
            if var g = groups.last, g.name == name, !cs.isEmpty {
                let have = Dictionary(g.clips.enumerated().map { (signature($0.element), $0.offset) }, uniquingKeysWith: { a, _ in a })
                if cs.allSatisfy({ have[signature($0)] != nil }) {
                    for c in cs { if let i = have[signature(c)], let ch = channelOf[c.id] { g.channels[i].append(ch) } }
                    groups[groups.count - 1] = g
                    continue
                }
            }
            groups.append((name, cs, cs.map { channelOf[$0.id].map { [$0] } ?? [] }))
        }
        for (n, g) in groups.enumerated() {
            var cs = g.clips
            for i in cs.indices {
                let chans = g.channels[i]
                guard let m = cs[i].mediaId.flatMap(mediaAsset), let all = channelCount[m.id], !chans.isEmpty, Set(chans).count < all else { continue }
                cs[i].channels = chans.count == 1 ? ChannelRouting(rawValue: "ch\(chans[0])") : ChannelRouting(rawValue: "ch\(chans[0])+ch\(chans[1])")
            }
            tracks.append(Track(id: "A\(n + 1)", kind: .audio, name: g.name ?? "Audio \(n + 1)", clips: cs))
        }
        tracks += mutedSound
        // Drop transitions on sound clips that folded away with their channel slots.
        let kept = Set(tracks.flatMap(\.clips).map(\.id))
        transitions = transitions.filter { tr in [tr.from, tr.to].compactMap { $0 }.allSatisfy(kept.contains) }

        let (folded, soundOf, heard) = fold(tracks, frame: frame)
        tracks = folded
        transitions = Importer.foldTransitions(transitions, soundOf: soundOf, separate: heard, frame: frame)
        var v = 0, a = 0
        for t in tracks.indices {
            if tracks[t].kind == .video { v += 1; tracks[t].id = "V\(v)" } else { a += 1; tracks[t].id = "A\(a)" }
        }

        var markers: [Marker] = []
        for s in slots where isA(s, AAFClass.eventMobSlot) || isA(s, AAFClass.timelineMobSlot) {
            guard let seg = s.strong(0x4803) else { continue }
            let events = seg.classID == AAFClass.sequence ? seg.objects(0x1001) : [seg]
            for e in events where isA(e, AAFClass.event) {
                let at = seconds(Double(e.int(0x0601) ?? 0), rate(s))
                var label = e.string(0x0602) ?? ""
                if label.isEmpty { label = "Marker \(markers.count + 1)" }
                markers.append(Marker(id: "m\(markers.count + 1)", time: at, label: label))
            }
        }

        if let first = tracks.lazy.filter({ $0.kind == .video }).flatMap(\.clips).compactMap({ $0.mediaId.flatMap(self.mediaAsset) }).first(where: { $0.width > 0 && $0.height > 0 }) {
            canvas.width = first.width
            canvas.height = first.height
        }
        if let size = comment(comp, "Cutline canvas", pid: 0x4406)?.split(separator: "x").compactMap({ Int($0) }), size.count == 2, size[0] > 0, size[1] > 0 {
            canvas.width = size[0]
            canvas.height = size[1]
        }
        var p = Project(name: comp.string(0x4402).flatMap { $0.isEmpty ? nil : $0 } ?? "AAF", canvas: canvas)
        p.canvasSet = true
        p.media = media
        p.tracks = tracks.filter { $0.kind == .video || !$0.clips.isEmpty }
        resolveConform(&p)
        if !p.tracks.contains(where: { $0.kind == .video }) { p.tracks.insert(Track(id: "V1", kind: .video, name: "Main"), at: 0) }
        p.transitions = transitions
        p.markers = markers.sorted { $0.time < $1.time }
        Importer.finish(&p, &warnings, offline: offline)
        return ImportResult(project: p, warnings: Importer.condense(warnings), missingMedia: missing)
    }

    var channelOf: [String: Int] = [:]
    var channelCount: [String: Int] = [:]

    func mediaAsset(_ id: String) -> MediaAsset? { media.first { $0.id == id } }

    /// Sound clips repeating a picture clip's media in sync fold into it; returns the tracks, folded sound to picture, and pictures heard.
    func fold(_ input: [Track], frame: Double) -> ([Track], [String: String], Set<String>) {
        var tracks = input
        let half = frame / 2
        var heard = Set<String>(), folded = Set<String>()
        var soundOf: [String: String] = [:]
        func hear(_ a: Clip, in v: inout Clip) {
            v.volume = a.volume
            v.audioFadeIn = a.audioFadeIn
            v.audioFadeOut = a.audioFadeOut
            v.channels = a.channels
            if let c = a.anim["audio.volume"] { v.anim["audio.volume"] = c.shifted(by: a.start - v.start) }
            v.audioLead = v.start - a.start
            v.audioLag = a.end - v.end
            if abs(v.audioLead) < half { v.audioLead = 0 }
            if abs(v.audioLag) < half { v.audioLag = 0 }
        }
        for exact in [true, false] {
            for t in tracks.indices where tracks[t].kind == .audio {
                for a in tracks[t].clips where !folded.contains(a.id) {
                    for vt in tracks.indices where tracks[vt].kind == .video && !folded.contains(a.id) {
                        guard let i = tracks[vt].clips.firstIndex(where: { c in
                            !heard.contains(c.id) && c.mediaId == a.mediaId && abs(c.speed - a.speed) < 1e-6
                                && (exact ? abs(c.start - a.start) < half && abs(c.duration - a.duration) < half && abs(c.sourceIn - a.sourceIn) < half
                                    : a.start < c.end + half && c.start < a.end + half && abs((a.sourceIn - a.start * a.speed) - (c.sourceIn - c.start * c.speed)) < half * max(a.speed, 1)
                                        && abs(c.start - a.start) <= Importer.maxSplit + half && abs(a.end - c.end) <= Importer.maxSplit + half)
                        }) else { continue }
                        hear(a, in: &tracks[vt].clips[i])
                        heard.insert(tracks[vt].clips[i].id)
                        folded.insert(a.id)
                        soundOf[a.id] = tracks[vt].clips[i].id
                    }
                }
            }
        }
        for t in tracks.indices where tracks[t].kind == .audio { tracks[t].clips.removeAll { folded.contains($0.id) } }
        tracks.removeAll { $0.kind == .audio && $0.clips.isEmpty }
        Importer.linkSeparateSound(&tracks, half: half)
        for t in tracks.indices where tracks[t].kind == .video {
            for c in tracks[t].clips.indices where !heard.contains(tracks[t].clips[c].id) {
                if tracks[t].clips[c].mediaId.flatMap(mediaAsset)?.hasAudio == true { tracks[t].clips[c].volume = 0 }
            }
        }
        return (tracks, soundOf, heard)
    }

    // MARK: Segments

    func comment(_ o: AAFObject, _ name: String, pid: UInt16 = 0x0204) -> String? {
        for tv in o.objects(pid) where tv.string(0x5001) == name {
            if let s = tv.bytes(0x5003).flatMap(AAFCodec.indirectString) { return s }
        }
        return nil
    }

    func transitionType(_ op: AUID?) -> String {
        let name = (op.flatMap { opNames[$0] } ?? "").lowercased()
        if name.contains("dip") { return "dip" }
        if name.contains("wipe") { return "wipe" }
        return "dissolve"
    }

    /// A segment that only shows the slots below it (a background input), or nothing.
    func scopeOnly(_ seg: AAFObject) -> Bool {
        if seg.classID == AAFClass.scopeReference || seg.classID == AAFClass.filler { return true }
        if seg.classID == AAFClass.sequence { return seg.objects(0x1001).allSatisfy(scopeOnly) }
        return false
    }

    func parameter(_ group: AAFObject, _ id: AUID) -> AAFObject? { group.objects(0x0b03).first { $0.auid(0x4c01) == id } }

    func read(_ seg: AAFObject, rate r: Rate, at pos: inout Int, into out: inout SlotRead, wrap: Ref) {
        let len = length(seg)
        switch seg.classID {
        case AAFClass.sequence:
            for c in seg.objects(0x1001) {
                if isA(c, AAFClass.transition) {
                    let l = length(c)
                    pos -= l
                    let op = c.strong(0x1801).flatMap { $0.weak(0x0b01) }.map { AUID(bytes: $0.key) }
                    out.joins.append(Join(before: out.pieces.count - 1, start: pos, length: l, cut: Int(c.int(0x1802) ?? 0), type: transitionType(op), overlap: comment(c, "Cutline") == "overlap"))
                } else {
                    read(c, rate: r, at: &pos, into: &out, wrap: wrap)
                }
            }
            return
        case AAFClass.sourceClip:
            let id = seg.bytes(0x1101) ?? AAFMobID.zero.bytes
            if let target = mobs[id], isA(target, AAFClass.compositionMob) {
                nested(target, slot: Int(seg.uint(0x1102) ?? 0), start: Int(seg.int(0x1201) ?? 0), length: len, rate: r, at: pos, into: &out, wrap: wrap)
            } else if var ref = resolve(id, slot: Int(seg.uint(0x1102) ?? 0), start: Double(seg.int(0x1201) ?? 0), rate: r) {
                ref.speed = wrap.speed
                ref.gain = wrap.gain
                ref.keys = wrap.keys
                ref.disabled = wrap.disabled
                ref.name = comment(seg, "Name") ?? wrap.name ?? ref.name
                ref.hint = comment(seg, "Cutline sound") ?? wrap.hint
                ref.grade = comment(seg, "Comment") ?? wrap.grade
                ref.warp = wrap.warp
                ref.picture = wrap.picture
                out.pieces.append(Piece(start: pos, length: len, ref: ref))
            } else {
                out.pieces.append(Piece(start: pos, length: len, ref: nil))
            }
        case AAFClass.filler:
            let json = comment(seg, "Cutline clip")
            out.pieces.append(Piece(start: pos, length: len, ref: nil, embedded: json.flatMap { Project.restoredClip(json: $0, placed: Clip(id: "", kind: .solid, start: 0, duration: 0)) }))
        case _ where isA(seg, AAFClass.operationGroup):
            let op = seg.weak(0x0b01).map { AUID(bytes: $0.key) }
            let inputs = seg.objects(0x0b02)
            var inner = wrap
            inner.name = comment(seg, "Name") ?? wrap.name
            inner.hint = comment(seg, "Cutline sound") ?? wrap.hint
            inner.grade = comment(seg, "Comment") ?? wrap.grade
            let start = pos
            let opName = (op.flatMap { opNames[$0] } ?? "").lowercased()
            /// A parameter's constant or keys at slot positions.
            func number(_ id: AUID) -> ParamRead? {
                guard let p = parameter(seg, id) else { return nil }
                if p.classID == AAFClass.constantValue { return p.bytes(0x4d01).flatMap(AAFCodec.indirectNumber).map { ParamRead(constant: $0) } }
                let keys = p.objects(0x4e02).compactMap { cp -> (at: Double, v: Double)? in
                    guard let t = cp.rational(0x1a03), t.den != 0, let v = cp.bytes(0x1a02).flatMap(AAFCodec.indirectNumber) else { return nil }
                    return (Double(start) + Double(t.num) / Double(t.den) * Double(len), v)
                }
                return keys.isEmpty ? nil : ParamRead(keys: keys)
            }
            let pictureParams: [AUID: [AUID]] = [
                AAFDef.videoCrop: [AAFDef.cropLeft, AAFDef.cropRight, AAFDef.cropTop, AAFDef.cropBottom], AAFDef.videoScale: [AAFDef.scaleX, AAFDef.scaleY],
                AAFDef.videoRotate: [AAFDef.rotation], AAFDef.videoPosition: [AAFDef.positionOffsetX, AAFDef.positionOffsetY], AAFDef.videoOpacity: [AAFDef.opacityLevel],
            ]
            if let op, let ids = pictureParams[op] {
                for id in ids { if let v = number(id) { inner.picture[id] = v } }
            } else if op == AAFDef.avidSBlend {
                // Media Composer's 3D Warp: its scale (percent) and Z rotation; the rest isn't read.
                if let v = number(AAFDef.avidDVEScaleX) { inner.picture[AAFDef.scaleX] = scaled(v, 0.01) }
                if let v = number(AAFDef.avidDVEScaleY) { inner.picture[AAFDef.scaleY] = scaled(v, 0.01) }
                if let v = number(AAFDef.avidDVERotZ) { inner.picture[AAFDef.rotation] = scaled(v, -1.0 / 360) }
                warnings.append("3D Warp: scale and rotation kept; position, 3D rotation, perspective and borders not kept")
            } else if op == AAFDef.videoRepeat {
                inner.warp = [(0, 0), (Double(len), 0)]
            } else if op == AAFDef.monoAudioGain || opName.contains("audio gain") {
                if let p = parameter(seg, AAFDef.amplitude) {
                    if p.classID == AAFClass.constantValue, let g = p.bytes(0x4d01).flatMap(AAFCodec.indirectNumber) {
                        inner.gain *= g
                    } else if p.classID == AAFClass.varyingValue {
                        let keys = p.objects(0x4e02).compactMap { cp -> (at: Double, gain: Double)? in
                            guard let t = cp.rational(0x1a03), t.den != 0, let g = cp.bytes(0x1a02).flatMap(AAFCodec.indirectNumber) else { return nil }
                            return (Double(start) + Double(t.num) / Double(t.den) * Double(len), g)
                        }
                        if !keys.isEmpty { inner.keys = keys }
                    }
                }
            } else if op == AAFDef.videoSpeedControl || opName.contains("motion control") {
                if let w = timeWarp(seg, length: len, input: inputs.first.map(length) ?? len) {
                    inner.warp = w
                    if w.count >= 2 { inner.speed = abs(w[w.count - 1].v - w[0].v) / max(w[w.count - 1].t - w[0].t, 1e-9) }
                }
            } else if !opName.contains("audio pan") {
                let name = op.flatMap { opNames[$0] }.flatMap { $0.isEmpty ? nil : $0 } ?? op?.description ?? "unknown"
                warnings.append(inputs.isEmpty ? "Effect \(name) (a generator) imported as a gap" : "Effect \(name) not kept; its first input plays")
            }
            if let input = inputs.first(where: { !scopeOnly($0) }) {
                var p0 = pos
                let before = out.pieces.count
                read(input, rate: r, at: &p0, into: &out, wrap: inner)
                if out.pieces.count == before + 1 { out.pieces[before].length = len }
            } else {
                out.pieces.append(Piece(start: pos, length: len, ref: nil))
            }
            pos = start + len
            return
        case AAFClass.selector:
            if let s = seg.strong(0x0f01), !scopeOnly(s) {
                var p0 = pos
                read(s, rate: r, at: &p0, into: &out, wrap: wrap)
            } else if let alt = seg.objects(0x0f02).first {
                var p0 = pos
                var muted = wrap
                muted.disabled = true
                read(alt, rate: r, at: &p0, into: &out, wrap: muted)
            }
            pos += len
            return
        case AAFClass.essenceGroup:
            if let s = seg.objects(0x0501).first { var p0 = pos; read(s, rate: r, at: &p0, into: &out, wrap: wrap) }
            pos += len
            return
        case AAFClass.nestedScope:
            if let s = seg.objects(0x0c01).last { var p0 = pos; read(s, rate: r, at: &p0, into: &out, wrap: wrap) }
            pos += len
            return
        default:
            if !isA(seg, AAFClass.filler), !isA(seg, AAFClass.event) { out.pieces.append(Piece(start: pos, length: len, ref: nil)) }
        }
        pos += len
    }

    func scaled(_ r: ParamRead, _ k: Double) -> ParamRead {
        ParamRead(constant: r.constant.map { $0 * k }, keys: r.keys.map { ($0.at, $0.v * k) })
    }

    /// A Motion Control's time map: Media Composer's input offset map (output frames, or normalized time for curved
    /// warps), else its SpeedRatio (output over input length; Cutline 1.0 wrote input over output).
    func timeWarp(_ seg: AAFObject, length len: Int, input: Int) -> [(t: Double, v: Double)]? {
        guard len > 0 else { return nil }
        func points(_ id: AUID) -> [(t: Double, v: Double)]? {
            guard let p = parameter(seg, id), p.classID == AAFClass.varyingValue else { return nil }
            let pts = p.objects(0x4e02).compactMap { cp -> (t: Double, v: Double)? in
                guard let t = cp.rational(0x1a03), t.den != 0, let v = cp.bytes(0x1a02).flatMap(AAFCodec.indirectNumber) else { return nil }
                return (Double(t.num) / Double(t.den), v)
            }.sorted { $0.t < $1.t }
            return pts.isEmpty ? nil : pts
        }
        let ratio = parameter(seg, AAFDef.speedRatio).flatMap { $0.classID == AAFClass.constantValue ? $0.bytes(0x4d01).flatMap(AAFCodec.indirectNumber) : nil }
        /// Avid's offsets name the frame shown; a reversed clip's map runs from one past it.
        func shifted(_ pts: [(t: Double, v: Double)]) -> [(t: Double, v: Double)] {
            guard let a = pts.first, let b = pts.last, b.v < a.v else { return pts }
            return pts.map { ($0.t, $0.v + 1) }
        }
        if var pts = points(AAFDef.avidSpeedOffsetMap) {
            if pts.count == 1 { pts.append((Double(len), pts[0].v)) }
            return shifted(pts)
        }
        if let pts = points(AAFDef.avidOffsetMap) {
            // Normalized time over the output's first to last frame, offsets of the input frames shown.
            if pts.count == 2, let r = ratio, r != 0 {
                let v0 = pts[0].v
                return shifted([(0, v0), (Double(len), v0 + Double(len) / r)])
            }
            var out = pts.map { (t: $0.t * Double(max(len - 1, 1)), v: $0.v) }
            if out.count >= 2 {
                let a = out[out.count - 2], b = out[out.count - 1]
                if b.t < Double(len), b.t > a.t { out.append((Double(len), b.v + (b.v - a.v) / (b.t - a.t) * (Double(len) - b.t))) }
            }
            if pts.count > 2 { warnings.append("A curved Media Composer timewarp was imported with straight segments between its keys") }
            return shifted(out)
        }
        if var r = ratio, r != 0 {
            if legacySpeedRatio { r = 1 / r }
            if input <= 1 { return [(0, 0), (Double(len), 0)] }
            let speed = 1 / r
            return speed < 0 ? [(0, Double(input)), (Double(len), Double(input) + Double(len) * speed)] : [(0, 0), (Double(len), Double(len) * speed)]
        }
        if parameter(seg, AAFDef.speedRatio)?.classID == AAFClass.varyingValue { warnings.append("A speed ramp was imported at its average speed") }
        return input > 0 ? [(0, 0), (Double(len), Double(input))] : nil
    }

    /// Cutline 1.0 wrote SpeedRatio as input over output length, with no offset map.
    lazy var legacySpeedRatio: Bool = {
        (doc.header?.objects(0x3b06) ?? []).contains { $0.string(0x3c02) == "Cutline" && $0.string(0x3c04) == "1.0" }
    }()

    /// Clips whose scale is still the picture's size over its media fit whole, until the canvas is known.
    var conformPending: [String: (x: Double, y: Double)] = [:]

    /// Sets `c`'s crop, rotation, position and opacity (keyed when the effects are) from picture effects; scale waits in
    /// `conformPending` for the canvas.
    func applyPicture(_ pic: [AUID: ParamRead], _ c: inout Clip, rate sr: Rate) {
        guard !pic.isEmpty else { return }
        func apply(_ id: AUID, _ path: String, _ f: (Double) -> Double, set: (inout Clip, Double) -> Void) {
            guard let r = pic[id] else { return }
            if let k = r.constant { set(&c, f(k)); return }
            let keys = r.keys.map { CurveKey(t: seconds($0.at, sr) - c.start, v: .number(f($0.v)), ease: .linear) }
            guard let first = keys.first, case .number(let v0) = first.v else { return }
            set(&c, v0)
            if keys.contains(where: { $0.v != first.v }) { c.anim[path] = Curve(keys: keys) }
        }
        func constant(_ id: AUID) -> Double? { pic[id]?.constant ?? pic[id]?.keys.first?.v }
        if let l = constant(AAFDef.cropLeft) { c.transform.crop.left = max(0, (l + 1) / 2) }
        if let r = constant(AAFDef.cropRight) { c.transform.crop.right = max(0, (1 - r) / 2) }
        if let t = constant(AAFDef.cropTop) { c.transform.crop.top = max(0, (t + 1) / 2) }
        if let b = constant(AAFDef.cropBottom) { c.transform.crop.bottom = max(0, (1 - b) / 2) }
        apply(AAFDef.rotation, "transform.rotation", { $0 * 360 }) { $0.transform.rotation = $1 }
        apply(AAFDef.positionOffsetX, "transform.x", { $0 / 2 }) { $0.transform.x = $1 }
        apply(AAFDef.positionOffsetY, "transform.y", { $0 / 2 }) { $0.transform.y = $1 }
        apply(AAFDef.opacityLevel, "transform.opacity", { min(max($0, 0), 1) }) { $0.transform.opacity = $1 }
        let x = pic[AAFDef.scaleX] ?? pic[AAFDef.scaleY], y = pic[AAFDef.scaleY] ?? pic[AAFDef.scaleX]
        if let x, let y {
            apply(pic[AAFDef.scaleX] != nil ? AAFDef.scaleX : AAFDef.scaleY, "transform.scale", { $0 }) { $0.transform.scale = $1 }
            conformPending[c.id] = (x.constant ?? x.keys.first?.v ?? 1, y.constant ?? y.keys.first?.v ?? 1)
        }
    }

    /// Fit and scale of clips whose picture effects gave their size over the media fit whole.
    func resolveConform(_ p: inout Project) {
        for t in p.tracks.indices {
            for i in p.tracks[t].clips.indices {
                let c = p.tracks[t].clips[i]
                guard let raw = conformPending[c.id], raw.x > 0 else { continue }
                var made = c
                if let w = p.canvas.setConform(&made, media: c.mediaId.flatMap(p.mediaAsset), x: raw.x, y: raw.y) { warnings.append(w) }
                let k = made.transform.scale / raw.x
                made.transform.scale = c.transform.scale * k
                if let curve = c.anim["transform.scale"] {
                    made.anim["transform.scale"] = Curve(keys: curve.keys.map { key in
                        var key = key
                        if case .number(let v) = key.v { key.v = .number(v * k) }
                        return key
                    })
                }
                p.tracks[t].clips[i] = made
            }
        }
    }

    /// A composition used as a clip, its slot flattened into the one reading it.
    func nested(_ mob: AAFObject, slot: Int, start: Int, length: Int, rate r: Rate, at pos: Int, into out: inout SlotRead, wrap: Ref) {
        guard nestDepth < 8, let s = mob.objects(0x4403).first(where: { Int($0.uint(0x4801) ?? 0) == slot }), let seg = s.strong(0x4803) else {
            out.pieces.append(Piece(start: pos, length: length, ref: nil))
            return
        }
        warnings.append("Nested sequence \(mob.string(0x4402) ?? "") flattened")
        nestDepth += 1
        defer { nestDepth -= 1 }
        var inner = SlotRead()
        var p0 = 0
        read(seg, rate: rate(s), at: &p0, into: &inner, wrap: wrap)
        let lo = start, hi = start + length
        var moved: [Int: Int] = [:]
        for (i, var piece) in inner.pieces.enumerated() where piece.start + piece.length > lo && piece.start < hi {
            let s0 = max(piece.start, lo), e0 = min(piece.start + piece.length, hi)
            let cutFront = s0 - piece.start
            piece.start = s0
            piece.length = e0 - s0
            if var ref = piece.ref {
                ref.source += seconds(Double(cutFront), rate(s)) * ref.speed
                ref.keys = ref.keys.map { ($0.at - Double(lo) + Double(pos), $0.gain) }
                piece.ref = ref
            }
            piece.start += pos - lo
            guard piece.length > 0 else { continue }
            moved[i] = out.pieces.count
            out.pieces.append(piece)
        }
        for var j in inner.joins where j.start >= lo && j.start + j.length <= hi {
            guard let before = moved[j.before], moved[j.before + 1] == before + 1 else { continue }
            j.before = before
            j.start += pos - lo
            out.joins.append(j)
        }
    }

    // MARK: Media

    struct Visit {
        var mob: AAFObject
        var slot: AAFObject
        /// Seconds from the slot's origin.
        var at: Double
    }

    /// The media a source clip plays and where, following master and source mobs down to the original.
    func resolve(_ id: [UInt8], slot slotID: Int, start: Double, rate r: Rate) -> Ref? {
        guard !AAFMobID(bytes: id).isZero else { return nil }
        guard let first = mobs[id] else {
            let key = id
            if let known = mediaFor[key] { return Ref(media: known, source: seconds(start, r)) }
            let mid = Importer.unique("offline-\(media.count + 1)", &usedIds)
            media.append(MediaAsset(id: mid, path: "", name: mid, duration: 0, width: 0, height: 0, fps: Double(r.num) / Double(r.den), hasVideo: true, hasAudio: true))
            offline.insert(mid)
            missing.append(mid)
            warnings.append("A clip refers to a source the AAF doesn't describe; kept offline as \(mid)")
            mediaFor[key] = mid
            return Ref(media: mid, source: seconds(start, r))
        }
        var visits: [Visit] = []
        var mob = first, sid = slotID, t = seconds(start, r)
        for _ in 0..<12 {
            guard let slot = mob.objects(0x4403).first(where: { Int($0.uint(0x4801) ?? 0) == sid }) else { break }
            let sr = rate(slot)
            let origin = seconds(Double(slot.int(0x4b02) ?? 0), sr)
            visits.append(Visit(mob: mob, slot: slot, at: t))
            guard var seg = slot.strong(0x4803) else { break }
            var segStart = 0.0
            if seg.classID == AAFClass.sequence {
                var p = 0.0
                var found: (AAFObject, Double)?, fallback: (AAFObject, Double)?
                for c in seg.objects(0x1001) {
                    let l = seconds(Double(length(c)), sr)
                    if isA(c, AAFClass.transition) { p -= l; continue }
                    if fallback == nil, c.classID == AAFClass.sourceClip { fallback = (c, p) }
                    if t + origin >= p - 1e-9, t + origin < p + l - 1e-9 { found = (c, p); break }
                    p += l
                }
                guard let f = found ?? fallback else { break }
                seg = f.0
                segStart = f.1
            }
            while isA(seg, AAFClass.operationGroup), let input = seg.objects(0x0b02).first { seg = input }
            if seg.classID == AAFClass.essenceGroup, let c = seg.objects(0x0501).first { seg = c }
            guard seg.classID == AAFClass.sourceClip, let next = seg.bytes(0x1101), !AAFMobID(bytes: next).isZero, let nextMob = mobs[next] else { break }
            t = t + origin - segStart + seconds(Double(seg.int(0x1201) ?? 0), sr)
            mob = nextMob
            sid = Int(seg.uint(0x1102) ?? 0)
        }
        guard let top = visits.first else { return nil }
        let master = visits.first { isA($0.mob, AAFClass.masterMob) } ?? top
        let key = master.mob.bytes(0x4401) ?? id
        let channel = soundChannel(master)
        if let known = mediaFor[key] {
            return Ref(media: known, source: placement(visits, media: known), name: master.mob.string(0x4402), channel: channel)
        }
        let made = makeMedia(visits, master: master)
        mediaFor[key] = made.id
        return Ref(media: made.id, source: made.source, name: master.mob.string(0x4402), channel: channel)
    }

    var anchor: [String: (mob: [UInt8], offset: Double)] = [:]

    /// Seconds into the media's file for this clip: its position at the mob the media's path came from.
    func placement(_ visits: [Visit], media id: String) -> Double {
        guard let a = anchor[id], let v = visits.first(where: { $0.mob.bytes(0x4401) == a.mob }) else { return visits.first?.at ?? 0 }
        return v.at - a.offset
    }

    /// The source channel (from 1) a master mob's sound slot reads, when it has several sound slots.
    func soundChannel(_ v: Visit) -> Int? {
        guard v.slot.strong(0x4803).flatMap(dataKind).map(AAFDef.soundKinds.contains) == true else { return nil }
        let sounds = v.mob.objects(0x4403).filter { $0.strong(0x4803).flatMap(dataKind).map(AAFDef.soundKinds.contains) == true }
        guard let i = sounds.firstIndex(where: { $0.uint(0x4801) == v.slot.uint(0x4801) }) else { return nil }
        return i + 1
    }

    func descriptors(_ mob: AAFObject) -> [AAFObject] {
        guard let d = mob.strong(0x4701) else { return [] }
        return [d] + d.objects(0x3f01)
    }

    func makeMedia(_ visits: [Visit], master: Visit) -> (id: String, source: Double) {
        var candidates: [(path: String, visit: Visit, physical: Bool)] = []
        var warn: [String] = []
        for v in visits.reversed() {
            for d in descriptors(v.mob) {
                for loc in d.objects(0x2f01) {
                    guard let url = loc.string(0x4001) ?? loc.string(0x4101), !url.isEmpty else { continue }
                    candidates.append((Importer.resolvePath(url, base: base, warnings: &warn), v, isA(d, AAFClass.importDescriptor) || !isA(d, AAFClass.fileDescriptor)))
                }
            }
        }
        let chosen = candidates.first { Importer.exists($0.path) } ?? candidates.first { $0.physical } ?? candidates.first
        let files = visits.filter { $0.mob.strong(0x4701).map { isA($0, AAFClass.fileDescriptor) } ?? false }
        let at = chosen?.visit ?? files.first ?? master
        let name = master.mob.string(0x4402).flatMap { $0.isEmpty ? nil : $0 } ?? chosen.map { Importer.fileName($0.path) } ?? "media"
        let id = Importer.unique(Importer.slug(name), &usedIds)
        let path = chosen?.path ?? ""
        var m = MediaAsset(id: id, path: path, name: name, duration: 0, width: 0, height: 0, fps: 0, hasVideo: false, hasAudio: false)
        let slots = master.mob.objects(0x4403)
        let kinds = slots.compactMap { $0.strong(0x4803).flatMap(dataKind) }
        m.hasVideo = kinds.contains(where: AAFDef.pictureKinds.contains)
        m.hasAudio = kinds.contains(where: AAFDef.soundKinds.contains)
        let soundSlots = slots.filter { $0.strong(0x4803).flatMap(dataKind).map(AAFDef.soundKinds.contains) == true }.count
        if soundSlots > 0 { channelCount[id] = soundSlots }
        if let s = slots.first, let seg = s.strong(0x4803) {
            m.duration = seconds(Double(length(seg)), rate(s))
        }
        // The master clip spans only what the edit uses (plus handles); the file's source mob spans the whole file.
        if let file = files.first, let seg = file.slot.strong(0x4803) {
            m.duration = max(m.duration, seconds(Double(length(seg)), rate(file.slot)))
        }
        for v in visits {
            for d in descriptors(v.mob) {
                if isA(d, AAFClass.digitalImageDescriptor) {
                    let w = Int(d.uint(0x3209) ?? d.uint(0x3203) ?? 0), h = Int(d.uint(0x3208) ?? d.uint(0x3202) ?? 0)
                    if m.width == 0, w > 0, h > 0 { m.width = w; m.height = h }
                    if m.fps == 0, let r = d.rational(0x3001), r.num > 0, r.den > 0 { m.fps = Importer.niceFps(Double(r.num) / Double(r.den)) }
                } else if isA(d, AAFClass.soundDescriptor) || d.classID == AAFClass.waveDescriptor || d.classID == AAFClass.aifcDescriptor {
                    if m.sampleRate == nil, let r = d.rational(0x3d03) ?? d.rational(0x3001), r.num > 0, r.den > 0 { m.sampleRate = Double(r.num) / Double(r.den) }
                }
            }
        }
        if m.fps == 0 { m.fps = Importer.niceFps(Double(rate(at.slot).num) / Double(rate(at.slot).den)) }
        m.isImage = Importer.stillExtensions.contains((path as NSString).pathExtension.lowercased())
        let origin = at.at
        anchor[id] = (at.mob.bytes(0x4401) ?? [], 0)
        // Source timecode and reel from the deepest mob with a timecode slot.
        for v in visits.reversed() {
            if m.reel == nil, let d = v.mob.strong(0x4701), d.classID == AAFClass.tapeDescriptor || d.classID == AAFClass.filmDescriptor,
               let n = v.mob.string(0x4402), !n.isEmpty { m.reel = n }
            guard m.timecodeStart == nil, let tcSlot = v.mob.objects(0x4403).first(where: { s in s.strong(0x4803).map { $0.classID == AAFClass.timecode } ?? false }),
                  let tc = tcSlot.strong(0x4803) else { continue }
            let tr = rate(tcSlot)
            let format = TimecodeFormat(fps: Double(tr.num) / Double(tr.den), dropFrame: (tc.int(0x1503) ?? 0) != 0)
            let tapeAt = v.at + seconds(Double(tcSlot.int(0x4b02) ?? 0), tr)
            let frames = Int(tc.int(0x1501) ?? 0) + format.frameCount(tapeAt - origin)
            m.setTimecode(frames: frames, format: format)
        }
        if path.isEmpty || !Importer.exists(path) {
            offline.insert(id)
            let label = path.isEmpty ? name : path
            if !missing.contains(label) { missing.append(label) }
        }
        media.append(m)
        return (id, origin)
    }
}
