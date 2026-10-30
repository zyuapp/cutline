import Foundation

extension Project {
    /// AAF for Pro Tools, Media Composer and Resolve: an Edit Protocol file in structured storage (4096-byte
    /// sectors) with linked media, nothing embedded. The timeline is a CompositionMob on canvas frames: a Timecode
    /// slot at the canvas's start timecode, a Picture slot per video track and, per track whose clips sound, one
    /// mono Sound slot per source channel (sound overlapping itself on a track gets another set). Clips are
    /// SourceClips of a MasterMob per media whose slots span the media used plus `handles` seconds each side (as
    /// far as the media goes); the MasterMob points at a file SourceMob whose descriptor (CDCI picture and PCM
    /// sound, a MultipleDescriptor for both) has a NetworkLocator to the camera original, and that at a tape
    /// SourceMob carrying the source timecode and reel. Dissolves are VideoDissolve and sound crossfades
    /// MonoAudioDissolve transitions (on the sound cut, so split edits keep their own); fades are those against
    /// filler. Levels are MonoAudioGain operation groups, Amplitude constant or keyframed (track faders and the
    /// master folded in). Speed, reverse, freezes and ramps are Motion Control (VideoSpeedControl) as Media Composer
    /// writes it: SpeedRatio plus its input offset map at output frames (every frame of a ramp). Crop, scale (fit,
    /// fill and stretch as scale of the media fit whole), rotation, position and opacity are the baseline Video Crop,
    /// Scale, Rotate, Position and Opacity effects around the clip, keyed when animated. Multicam clips are their
    /// active angles. Markers are DescriptiveMarkers on an event slot.
    /// Titles and solids are filler carrying the Cutline clip in a "Cutline clip" comment.
    public func aaf(handles: Seconds = 2, date: Date = Date()) -> Data { scopedToTimeline().aaf(InterchangeContext(), handles: handles, date: date) }

    func aaf(_ ctx: InterchangeContext, handles: Seconds, date: Date) -> Data {
        var w = AAFWriter(project: flattenedSequences(), ctx: ctx, handles: handles, date: date)
        return w.document().data(names: AAFMetaModel.shared.name)
    }

    /// The AAF object tree `aaf` writes.
    func aafDocument(handles: Seconds = 2, date: Date = Date(timeIntervalSince1970: 0)) -> AAFDocument {
        var w = AAFWriter(project: flattenedSequences(), ctx: InterchangeContext(), handles: handles, date: date)
        return w.document()
    }

    /// Source channels a media's sound is written as.
    func aafChannels(_ m: MediaAsset) -> Int {
        guard m.hasAudio, !m.isImage else { return 0 }
        let routed = (tracks + sequences.flatMap(\.tracks)).flatMap(\.clips).filter { $0.mediaId == m.id }.compactMap { $0.channels?.sourceChannels.max() }.max() ?? 0
        return min(max(m.audioChannels?.count ?? 2, routed, 1), 16)
    }
}

struct AAFWriter {
    let p: Project
    let ctx: InterchangeContext
    let grid: FrameGrid
    let handleFrames: Int
    let date: Date

    /// A stretch of a slot: a source clip or filler, placed in timeline frames.
    struct Piece {
        var start: Int
        var end: Int
        var media: String?
        /// Source frame (timeline rate) at `start`.
        var source: Int = 0
        var speed: Double = 1
        var clip: Clip?
        var track: Track?
        var comment: String?
        /// Where the clip sits beyond its sound, for Cutline to read back (`SoundHint`).
        var hint: String?
        /// Source channels (from 0) the sound slots of this piece read in order; nil reads every channel.
        var channels: [Int]?
        var length: Int { end - start }
    }

    /// A transition after piece `index` in a slot.
    struct Join {
        var length: Int
        var cut: Int
        var operation: AUID
        /// Sound overlapping the next clip's under their fades, written as a crossfade over the overlap.
        var overlap = false
    }

    struct Slot {
        var pieces: [Piece] = []
        var joins: [Int: Join] = [:]
    }

    var ranges: [String: (lo: Int, hi: Int)] = [:]
    var masters: [String: AAFMobID] = [:]
    var operations = Set<AUID>()

    init(project: Project, ctx: InterchangeContext, handles: Seconds, date: Date) {
        p = project
        self.ctx = ctx
        grid = FrameGrid(fps: project.canvas.fps)
        handleFrames = max(0, grid.frames(handles))
        self.date = date
    }

    func f(_ t: Seconds) -> Int { grid.frames(t) }

    var editRate: (Int, Int) {
        let g = max(1, FrameGrid.gcd(grid.den, grid.num))
        return (grid.den / g, grid.num / g)
    }

    // MARK: Slots

    func sounds(_ c: Clip, _ t: Track) -> Bool {
        guard c.kind == .media, let m = c.mediaId.flatMap(p.mediaAsset), m.hasAudio, !m.isImage else { return false }
        if t.kind == .audio && t.muted { return false }
        return c.volume > 0 || c.anim["audio.volume"] != nil
    }

    /// `items` in order with filler between and around them (of no length where they touch), so transitions have filler to fade against.
    func layout(_ items: [Piece]) -> Slot {
        var s = Slot()
        var pos = 0
        for it in items.sorted(by: { $0.start < $1.start }) where it.end > it.start {
            let gapStart = min(pos, it.start)
            s.pieces.append(Piece(start: gapStart, end: max(gapStart, it.start)))
            s.pieces.append(it)
            pos = max(pos, it.end)
        }
        s.pieces.append(Piece(start: pos, end: pos))
        return s
    }

    func index(_ s: Slot, clip id: String) -> Int? { s.pieces.firstIndex { $0.clip?.id == id } }

    /// Joins `a` and `b` (adjacent with filler of no length between) with a transition from `start` for `length`, cut at `cut`.
    mutating func crossfade(_ s: inout Slot, _ a: Int, _ b: Int, start: Int, cut: Int, length: Int, op: AUID) -> Bool {
        guard b == a + 2, s.pieces[a + 1].length == 0, s.pieces[a].end == cut, s.pieces[b].start == cut, s.joins[a] == nil, s.joins[a + 1] == nil,
              start <= cut, start + length >= cut, length > 0 else { return false }
        s.pieces[a].end = start + length
        let back = cut - start
        s.pieces[b].source -= Int((Double(back) * s.pieces[b].speed).rounded())
        s.pieces[b].start = start
        s.pieces[a + 1].media = "-"
        s.joins[a] = Join(length: length, cut: back, operation: op)
        operations.insert(op)
        return true
    }

    /// A fade from the filler before piece `i` over its first `length` frames.
    mutating func fadeIn(_ s: inout Slot, _ i: Int, length: Int, op: AUID) {
        guard i > 0, length > 0, s.pieces[i - 1].media == nil, s.pieces[i - 1].clip == nil, s.joins[i - 1] == nil, length <= s.pieces[i].length else { return }
        s.pieces[i - 1].end += length
        s.joins[i - 1] = Join(length: length, cut: 0, operation: op)
        operations.insert(op)
    }

    /// A fade into the filler after piece `i` over its last `length` frames.
    mutating func fadeOut(_ s: inout Slot, _ i: Int, length: Int, op: AUID) {
        guard i + 1 < s.pieces.count, length > 0, s.pieces[i + 1].media == nil, s.pieces[i + 1].clip == nil, s.joins[i] == nil, length <= s.pieces[i].length else { return }
        s.pieces[i + 1].start -= length
        s.joins[i] = Join(length: length, cut: length, operation: op)
        operations.insert(op)
    }

    /// A picture slot of a video track.
    mutating func pictureSlot(_ t: Track) -> Slot {
        var items: [Piece] = []
        for c in t.clips {
            var piece = Piece(start: f(c.start), end: f(c.end), clip: c, track: t)
            if c.kind == .media, let m = c.mediaId.flatMap(p.mediaAsset), m.hasVideo || m.isImage {
                piece.media = m.id
                piece.source = m.isImage ? 0 : f(c.sourceIn)
                piece.speed = c.isRetimed || m.isImage ? 1 : abs(c.speed)
            } else if let e = ctx.embedded(c) {
                piece.comment = Project.clipTag + Project.clipJSON(e)
            }
            items.append(piece)
        }
        var s = layout(items)
        for tr in p.transitions where tr.hasVideo || tr.from == nil || tr.to == nil {
            guard let w = try? p.window(tr), w.trackId == t.id else { continue }
            if tr.from != nil, tr.to != nil {
                guard tr.hasVideo, let a = index(s, clip: tr.from!), let b = index(s, clip: tr.to!), let tf = p.transitionFrames(tr, grid: grid, sound: false) else { continue }
                _ = crossfade(&s, a, b, start: tf.start, cut: tf.cut, length: tf.length, op: AAFDef.videoDissolve)
            } else if tr.hasVideo, let tf = p.transitionFrames(tr, grid: grid, sound: false) {
                if let id = tr.to, let i = index(s, clip: id) { fadeIn(&s, i, length: tf.length, op: AAFDef.videoDissolve) }
                if let id = tr.from, let i = index(s, clip: id) { fadeOut(&s, i, length: tf.length, op: AAFDef.videoDissolve) }
            }
        }
        return s
    }

    /// Sound slots of a track: lanes of sound that doesn't overlap, each with its channel count.
    mutating func soundSlots(_ t: Track) -> [(slot: Slot, channels: Int)] {
        var lanes: [[Piece]] = []
        // Sounds overlapping under a crossfade meet at the sound cut, where the crossfade is centered.
        var cutAt: [String: (end: Int?, start: Int?)] = [:]
        for tr in p.transitions where tr.hasAudio {
            guard let a = tr.from.flatMap(p.clip), let b = tr.to.flatMap(p.clip), t.clips.contains(where: { $0.id == a.id }),
                  a.audioRange.end > b.audioRange.start + 1e-6, let cut = p.soundCut(tr) else { continue }
            cutAt[a.id, default: (nil, nil)].end = f(cut)
            cutAt[b.id, default: (nil, nil)].start = f(cut)
        }
        for c in t.clips.sorted(by: { $0.start < $1.start }) where sounds(c, t) {
            let m = p.mediaAsset(c.mediaId!)!
            let r = c.audioRange
            var piece = Piece(start: f(r.start), end: f(r.end), media: m.id, source: f(c.audioSourceRange.start), clip: c, track: t)
            piece.speed = c.isRetimed ? 1 : abs(c.speed)
            if let routed = c.channels?.sourceChannels, !routed.isEmpty { piece.channels = routed.map { $0 - 1 } }
            if let e = cutAt[c.id]?.end { piece.end = min(piece.end, e) }
            if let s = cutAt[c.id]?.start, s > piece.start {
                piece.source += Int((Double(s - piece.start) * piece.speed).rounded())
                piece.start = s
            }
            guard piece.end > piece.start else { continue }
            if t.kind == .audio, c.audioLead != 0 || c.audioLag != 0, cutAt[c.id] == nil { piece.hint = SoundHint(c, grid: grid).text }
            /// Sound fading out over its overlap with this one, which fades in over it: a crossfade.
            func crossfades(_ last: Piece) -> Bool {
                guard let a = last.clip, last.hint != nil, piece.hint != nil else { return false }
                let overlap = last.end - piece.start
                return overlap > 0 && overlap < last.length && overlap < piece.length && f(a.audioFadeOut) >= overlap - 1 && f(c.audioFadeIn) >= overlap - 1
                    && !p.transitions.contains { $0.from == a.id || $0.to == c.id }
            }
            if let l = lanes.firstIndex(where: { ($0.last?.end ?? 0) <= piece.start }) ?? lanes.firstIndex(where: { $0.last.map(crossfades) ?? false }) {
                lanes[l].append(piece)
            } else {
                lanes.append([piece])
            }
        }
        return lanes.map { lane in
            var s = layout(lane)
            var crossed = Set<String>()
            for tr in p.transitions where tr.hasAudio && tr.from != nil && tr.to != nil {
                guard let a = index(s, clip: tr.from!), let b = index(s, clip: tr.to!), let tf = p.transitionFrames(tr, grid: grid, sound: true) else { continue }
                if crossfade(&s, a, b, start: tf.start, cut: tf.cut, length: tf.length, op: AAFDef.monoAudioDissolve) {
                    crossed.insert(tr.from! + ">")
                    crossed.insert("<" + tr.to!)
                }
            }
            for a in s.pieces.indices.dropLast(2) {
                let b = a + 2
                guard let ca = s.pieces[a].clip, let cb = s.pieces[b].clip, s.pieces[a].end > s.pieces[b].start, s.pieces[a + 1].length == 0, s.joins[a] == nil else { continue }
                let overlap = s.pieces[a].end - s.pieces[b].start
                s.pieces[a + 1].media = "-"
                s.joins[a] = Join(length: overlap, cut: overlap / 2, operation: AAFDef.monoAudioDissolve, overlap: true)
                operations.insert(AAFDef.monoAudioDissolve)
                crossed.insert(ca.id + ">")
                crossed.insert("<" + cb.id)
            }
            for i in s.pieces.indices {
                guard let c = s.pieces[i].clip else { continue }
                var fin = c.audioFadeIn, fout = c.audioFadeOut
                for tr in p.transitions where tr.hasAudio && (tr.from == nil || tr.to == nil) {
                    if tr.to == c.id, tr.from == nil { fin = max(fin, min(tr.duration, c.duration)) }
                    if tr.from == c.id, tr.to == nil { fout = max(fout, min(tr.duration, c.duration)) }
                }
                if fin > 0, !crossed.contains("<" + c.id) { fadeIn(&s, i, length: f(fin), op: AAFDef.monoAudioDissolve) }
                if fout > 0, !crossed.contains(c.id + ">") { fadeOut(&s, i, length: f(fout), op: AAFDef.monoAudioDissolve) }
            }
            let channels = lane.compactMap { piece in piece.channels?.count ?? piece.media.flatMap(p.mediaAsset).map(p.aafChannels) }.max() ?? 2
            return (s, max(channels, 1))
        }
    }

    // MARK: Objects

    func weakDef(_ tag: UInt16, _ id: AUID) -> AAFValue { .weak(AAFWeakRef(tag: tag, keyPid: 0x1b01, key: id.bytes)) }
    func dataDef(_ id: AUID) -> AAFValue { weakDef(AAFTag.dataDefs, id) }
    func i64(_ v: Int) -> AAFValue { .data(AAFCodec.i64(Int64(v))) }
    func u32(_ v: Int) -> AAFValue { .data(AAFCodec.u32(UInt32(max(0, v)))) }
    func str(_ s: String) -> AAFValue { .data(AAFCodec.string(s)) }
    func rational(_ r: (Int, Int)) -> AAFValue { .data(AAFCodec.rational(r.0, r.1)) }

    func sourceClip(_ kind: AUID, length: Int, mob: AAFMobID, slot: Int, start: Int) -> AAFObject {
        AAFObject(AAFClass.sourceClip, [(0x0201, dataDef(kind)), (0x0202, i64(length)), (0x1201, i64(start)),
                                        (0x1101, .data(mob.bytes)), (0x1102, u32(slot))])
    }

    func filler(_ kind: AUID, length: Int) -> AAFObject {
        AAFObject(AAFClass.filler, [(0x0201, dataDef(kind)), (0x0202, i64(length))])
    }

    func comments(_ pairs: [(String, String)]) -> AAFValue {
        .vector(pairs.map { AAFObject(AAFClass.taggedValue, [(0x5001, str($0.0)), (0x5003, .data(AAFCodec.indirectString($0.1)))]) })
    }

    func timelineSlot(_ id: Int, name: String?, track number: Int, segment: AAFObject, rate: (Int, Int)? = nil) -> AAFObject {
        var o = AAFObject(AAFClass.timelineMobSlot, [(0x4801, u32(id)), (0x4803, .strong(segment)), (0x4804, u32(number)),
                                                     (0x4b01, rational(rate ?? editRate)), (0x4b02, i64(0))])
        if let name { o.set(0x4802, str(name)) }
        return o
    }

    func mob(_ cls: AUID, id: AAFMobID, name: String, slots: [AAFObject]) -> AAFObject {
        let now = AAFValue.data(AAFCodec.timestamp(date))
        return AAFObject(cls, [(0x4401, .data(id.bytes)), (0x4402, str(name)), (0x4403, .vector(slots)), (0x4404, now), (0x4405, now)])
    }

    /// The segment of a piece on a slot of `kind`, for source channel `channel` (sound slot) or the picture.
    mutating func segment(_ piece: Piece, kind: AUID, channel: Int?) -> AAFObject {
        let source = channel.flatMap { k in piece.channels.map { k < $0.count ? $0[k] : -1 } ?? k }
        guard let id = piece.media, id != "-", let master = masters[id], let m = p.mediaAsset(id),
              source.map({ $0 >= 0 && $0 < p.aafChannels(m) }) ?? (m.hasVideo || m.isImage) else {
            var o = filler(kind, length: piece.length)
            if let note = piece.comment { o.set(0x0204, comments([("Cutline clip", note)])) }
            return o
        }
        let lo = ranges[id]?.lo ?? 0
        let slotID = source.map { $0 + 2 } ?? 1
        var seg: AAFObject
        if let w = warp(piece) {
            seg = motionControl(sourceClip(kind, length: w.length, mob: master, slot: slotID, start: w.start - lo), w, kind: kind, length: piece.length)
        } else {
            seg = sourceClip(kind, length: piece.length, mob: master, slot: slotID, start: piece.source - lo)
        }
        if channel == nil, let c = piece.clip { seg = pictureOperations(seg, piece: piece, clip: c) }
        if channel != nil, let c = piece.clip, let t = piece.track {
            let level = p.bakedLevel(c, track: t, grid: grid)
            let param: AAFObject?
            if !level.keys.isEmpty {
                let points = level.keys.map { k -> AAFObject in
                    let at = min(max(f(c.start + k.t) - piece.start, 0), piece.length)
                    return AAFObject(AAFClass.controlPoint, [(0x1a02, .data(AAFCodec.indirectRational(k.gain))), (0x1a03, rational((at, max(piece.length, 1))))])
                }
                param = AAFObject(AAFClass.varyingValue, [(0x4c01, .data(AAFDef.amplitude.bytes)), (0x4e01, weakDef(AAFTag.interpolationDefs, AAFDef.linearInterpolation)),
                                                          (0x4e02, .vector(points))])
            } else if abs(level.gain - 1) > 1e-6 {
                param = AAFObject(AAFClass.constantValue, [(0x4c01, .data(AAFDef.amplitude.bytes)), (0x4d01, .data(AAFCodec.indirectRational(level.gain)))])
            } else {
                param = nil
            }
            if let param {
                operations.insert(AAFDef.monoAudioGain)
                seg = AAFObject(AAFClass.operationGroup, [(0x0201, dataDef(kind)), (0x0202, i64(piece.length)), (0x0b01, weakDef(AAFTag.operationDefs, AAFDef.monoAudioGain)),
                                                          (0x0b02, .vector([seg])), (0x0b03, .vector([param]))])
            }
        }
        var notes: [(String, String)] = []
        if let name = piece.clip?.name, name != m.name { notes.append(("Name", name)) }
        if channel == nil, let c = piece.clip {
            let grade = (c.cdl.map { [$0.text] } ?? []) + c.lutFiles.map { "LUT \($0)" } + (ctx.luts[c.id].map { ["\(Project.gradeLUTTag) \($0)"] } ?? [])
            if !grade.isEmpty { notes.append(("Comment", grade.joined(separator: "; "))) }
        }
        if channel != nil, let hint = piece.hint { notes.append(("Cutline sound", hint)) }
        if !notes.isEmpty { seg.set(0x0204, comments(notes)) }
        return seg
    }

    // MARK: Motion and picture

    /// A warped piece as Media Composer's Motion Control reads it: the input's first frame and length (the frames the
    /// output shows), the input frame offset at output frames (a reversed clip's first output frame shows the frame
    /// before its source out), the speed, and SpeedRatio, output over input length, negative reversed.
    struct Warp {
        var start: Int
        var length: Int
        var offsets: [(frame: Int, value: Double)]
        var speeds: [(frame: Int, value: Double)]
        var ratio: (Int, Int)
    }

    func warp(_ piece: Piece) -> Warp? {
        guard let c = piece.clip, c.kind == .media, c.isWarped, let m = c.mediaId.flatMap(p.mediaAsset), !m.isImage, piece.length > 0 else { return nil }
        let at = piece.start - f(c.start), n = piece.length
        let shift = c.reverse ? 1.0 : 0.0
        let pts = c.timeMap(frames: at, at + n, grid: grid, step: 1).map { (frame: $0.frame - at, value: $0.source * grid.rate - shift) }
        func value(_ k: Double) -> Double {
            guard let i = pts.lastIndex(where: { Double($0.frame) <= k }), i + 1 < pts.count else { return pts.last!.value }
            let a = pts[i], b = pts[i + 1]
            return a.value + (b.value - a.value) * (k - Double(a.frame)) / Double(b.frame - a.frame)
        }
        let shown = [value(0), value(Double(n - 1))] + pts.filter { $0.frame < n }.map(\.value)
        let first = Int((shown.min()! + 1e-6).rounded(.down)), last = Int((shown.max()! + 1e-6).rounded(.down))
        let length = last - first + 1
        let sign = c.reverse ? -1.0 : 1.0
        var speeds: [(frame: Int, value: Double)] = []
        for q in pts where q.frame < n || speeds.isEmpty {
            let v = sign * c.speed(atLocal: Double((q.frame + at) * grid.num) / Double(grid.den))
            if speeds.last.map({ abs($0.value - v) > 1e-9 }) ?? true { speeds.append((q.frame, v)) }
        }
        return Warp(start: first, length: length, offsets: pts.map { ($0.frame, $0.value - Double(first)) }, speeds: speeds, ratio: (c.reverse ? -n : n, length))
    }

    func controlPoints(_ pts: [(time: (Int, Int), value: Double)]) -> AAFValue {
        .vector(pts.map { AAFObject(AAFClass.controlPoint, [(0x1a02, .data(AAFCodec.indirectRational($0.value))), (0x1a03, rational($0.time))]) })
    }

    func constant(_ id: AUID, _ v: Double) -> AAFObject {
        AAFObject(AAFClass.constantValue, [(0x4c01, .data(id.bytes)), (0x4d01, .data(AAFCodec.indirectRational(v)))])
    }

    func varying(_ id: AUID, _ pts: [(time: (Int, Int), value: Double)]) -> AAFObject {
        AAFObject(AAFClass.varyingValue, [(0x4c01, .data(id.bytes)), (0x4e01, weakDef(AAFTag.interpolationDefs, AAFDef.linearInterpolation)), (0x4e02, controlPoints(pts))])
    }

    mutating func operation(_ op: AUID, kind: AUID, length: Int, input: AAFObject, _ params: [AAFObject]) -> AAFObject {
        operations.insert(op)
        return AAFObject(AAFClass.operationGroup, [(0x0201, dataDef(kind)), (0x0202, i64(length)), (0x0b01, weakDef(AAFTag.operationDefs, op)),
                                                   (0x0b02, .vector([input])), (0x0b03, .vector(params))])
    }

    /// Motion Control as Media Composer writes it: SpeedRatio, the input offset map in output frames and the speed map.
    mutating func motionControl(_ input: AAFObject, _ w: Warp, kind: AUID, length: Int) -> AAFObject {
        let ratio = AAFObject(AAFClass.constantValue, [(0x4c01, .data(AAFDef.speedRatio.bytes)), (0x4d01, .data(AAFCodec.indirect(AAFDef.rationalType, AAFCodec.rational(w.ratio.0, w.ratio.1))))])
        return operation(AAFDef.videoSpeedControl, kind: kind, length: length, input: input, [
            ratio, varying(AAFDef.avidSpeedOffsetMap, w.offsets.map { (($0.frame, 1), $0.value) }), varying(AAFDef.avidSpeedMap, w.speeds.map { (($0.frame, 1), $0.value) }),
        ])
    }

    /// The clip's crop, scale (its fit as scale of the media fit whole), rotation, position and opacity as the
    /// baseline Video Crop, Scale, Rotate, Position and Opacity effects, innermost first; animated ones keyed.
    mutating func pictureOperations(_ input: AAFObject, piece: Piece, clip c: Clip) -> AAFObject {
        guard c.kind == .media, piece.length > 0 else { return input }
        let t = c.transform
        let local0 = Double(piece.start * grid.num) / Double(grid.den) - c.start
        let span = Double(piece.length * grid.num) / Double(grid.den)
        let k = p.conformScale(c)
        /// Times to key an animated parameter: the piece's ends, its keys and every 0.1 s of eased segments.
        func times(_ paths: [String]) -> [Seconds]? {
            let curves = paths.compactMap { c.anim[$0] }
            guard !curves.isEmpty else { return nil }
            var at = [local0, local0 + span]
            for curve in curves {
                at += curve.keys.map(\.t)
                if curve.expression != nil { at += stride(from: local0, to: local0 + span, by: 0.1).map { $0 } }
                for (a, b) in zip(curve.keys, curve.keys.dropFirst()) where b.ease != .linear || b.bezier != nil {
                    at += stride(from: a.t + 0.1, to: b.t, by: 0.1).map { $0 }
                }
            }
            var out: [Seconds] = []
            for x in at.filter({ $0 >= local0 - 1e-9 && $0 <= local0 + span + 1e-9 }).sorted() where out.last.map({ x - $0 > 1e-6 }) ?? true { out.append(x) }
            return out
        }
        /// The parameter, or nil when it stays `neutral` (unless `always`).
        func param(_ id: AUID, _ paths: [String], neutral: Double, always: Bool = false, _ value: @escaping (Transform) -> Double) -> AAFObject? {
            if let at = times(paths) {
                let pts = at.map { x -> (time: (Int, Int), value: Double) in
                    ((Int(((x - local0) / span * Double(piece.length) * 1000).rounded()), piece.length * 1000), value(c.resolvedTransform(at: x)))
                }
                return always || pts.contains(where: { abs($0.value - neutral) > 1e-9 }) ? varying(id, pts) : nil
            }
            let v = value(t)
            return always || abs(v - neutral) > 1e-9 ? constant(id, v) : nil
        }
        var seg = input
        let crop = [param(AAFDef.cropLeft, [], neutral: -1) { -1 + 2 * $0.crop.left }, param(AAFDef.cropRight, [], neutral: 1) { 1 - 2 * $0.crop.right },
                    param(AAFDef.cropTop, [], neutral: -1) { -1 + 2 * $0.crop.top }, param(AAFDef.cropBottom, [], neutral: 1) { 1 - 2 * $0.crop.bottom }].compactMap { $0 }
        if !crop.isEmpty { seg = operation(AAFDef.videoCrop, kind: AAFDef.picture, length: piece.length, input: seg, crop) }
        let scale = [param(AAFDef.scaleX, ["transform.scale"], neutral: 1) { k.x * $0.scale }, param(AAFDef.scaleY, ["transform.scale"], neutral: 1) { k.y * $0.scale }].compactMap { $0 }
        if !scale.isEmpty {
            // Both axes, so a reader sees the picture's aspect even when one is neutral.
            let both = [param(AAFDef.scaleX, ["transform.scale"], neutral: 1, always: true) { k.x * $0.scale }, param(AAFDef.scaleY, ["transform.scale"], neutral: 1, always: true) { k.y * $0.scale }].compactMap { $0 }
            seg = operation(AAFDef.videoScale, kind: AAFDef.picture, length: piece.length, input: seg, both)
        }
        if let r = param(AAFDef.rotation, ["transform.rotation"], neutral: 0, { $0.rotation / 360 }) {
            seg = operation(AAFDef.videoRotate, kind: AAFDef.picture, length: piece.length, input: seg, [r])
        }
        let position = [param(AAFDef.positionOffsetX, ["transform.x"], neutral: 0) { 2 * $0.x }, param(AAFDef.positionOffsetY, ["transform.y"], neutral: 0) { 2 * $0.y }].compactMap { $0 }
        if !position.isEmpty { seg = operation(AAFDef.videoPosition, kind: AAFDef.picture, length: piece.length, input: seg, position) }
        if let o = param(AAFDef.opacityLevel, ["transform.opacity"], neutral: 1, { $0.opacity }) {
            seg = operation(AAFDef.videoOpacity, kind: AAFDef.picture, length: piece.length, input: seg, [o])
        }
        return seg
    }

    mutating func sequence(_ s: Slot, kind: AUID, channel: Int?) -> AAFObject {
        var components: [AAFObject] = []
        var total = 0
        for (i, piece) in s.pieces.enumerated() {
            let joined = s.joins[i] != nil || (i > 0 && s.joins[i - 1] != nil)
            if piece.length == 0 && !joined { continue }
            if piece.media == "-" { continue }
            components.append(segment(piece, kind: kind, channel: channel))
            total += piece.length
            if let j = s.joins[i] {
                let level = j.operation == AAFDef.monoAudioDissolve ? nil : AAFObject(AAFClass.varyingValue, [
                    (0x4c01, .data(AAFDef.level.bytes)), (0x4e01, weakDef(AAFTag.interpolationDefs, AAFDef.linearInterpolation)),
                    (0x4e02, .vector([AAFObject(AAFClass.controlPoint, [(0x1a02, .data(AAFCodec.indirectRational(0))), (0x1a03, rational((0, 1)))]),
                                      AAFObject(AAFClass.controlPoint, [(0x1a02, .data(AAFCodec.indirectRational(1))), (0x1a03, rational((1, 1)))])])),
                ])
                var op = AAFObject(AAFClass.operationGroup, [(0x0201, dataDef(kind)), (0x0202, i64(j.length)), (0x0b01, weakDef(AAFTag.operationDefs, j.operation))])
                if let level { op.set(0x0b03, .vector([level])) }
                var tr = AAFObject(AAFClass.transition, [(0x0201, dataDef(kind)), (0x0202, i64(j.length)), (0x1801, .strong(op)), (0x1802, i64(j.cut))])
                if j.overlap { tr.set(0x0204, comments([("Cutline", "overlap")])) }
                components.append(tr)
                total -= j.length
            }
        }
        if components.isEmpty { components = [filler(kind, length: 0)] }
        return AAFObject(AAFClass.sequence, [(0x0201, dataDef(kind)), (0x0202, i64(total)), (0x1001, .vector(components))])
    }

    // MARK: Media

    func collect(_ s: Slot, kind: AUID) -> [(media: String, lo: Int, hi: Int)] {
        s.pieces.compactMap { piece in
            guard let id = piece.media, id != "-" else { return nil }
            if let w = warp(piece) { return (id, w.start, w.start + w.length) }
            return (id, piece.source, piece.source + piece.length)
        }
    }

    /// MasterMob, file SourceMob and, with timecode or a reel, tape SourceMob of a media.
    func mediaMobs(_ m: MediaAsset, range: (lo: Int, hi: Int), master: AAFMobID) -> [AAFObject] {
        let seed = p.name + "\u{1}" + m.id + "\u{1}" + m.conformPath
        let fileID = AAFMobID(seed: seed + "\u{1}file"), tapeID = AAFMobID(seed: seed + "\u{1}tape")
        let total = max(m.isImage ? range.hi : f(m.duration), range.hi)
        let channels = p.aafChannels(m)
        let picture = m.hasVideo || m.isImage
        let tc = m.timecodeStart != nil
        let tape = tc || m.reel != nil
        var ids: [(slot: Int, kind: AUID, track: Int)] = picture ? [(1, AAFDef.picture, 1)] : []
        ids += (0..<channels).map { ($0 + 2, AAFDef.sound, $0 + 1) }

        let masterSlots = ids.map { s in
            timelineSlot(s.slot, name: nil, track: s.track, segment: sourceClip(s.kind, length: range.hi - range.lo, mob: fileID, slot: s.slot, start: range.lo))
        }
        let fileSlots = ids.map { s in
            timelineSlot(s.slot, name: nil, track: s.track, segment: sourceClip(s.kind, length: total, mob: tape ? tapeID : .zero, slot: tape ? s.slot : 0, start: 0))
        }
        let url = URL(fileURLWithPath: m.conformPath).absoluteString
        let locator = AAFObject(AAFClass.networkLocator, [(0x4001, str(url))])
        let container = weakDef(AAFTag.containerDefs, AAFDef.externalContainer)
        func image() -> AAFObject {
            let fps = FrameGrid(fps: m.fps > 0 ? m.fps : p.canvas.fps)
            let g = max(1, FrameGrid.gcd(fps.den, fps.num))
            let w = max(m.width, 1), h = max(m.height, 1), a = max(1, FrameGrid.gcd(w, h))
            return AAFObject(AAFClass.cdciDescriptor, [
                (0x3001, rational((fps.den / g, fps.num / g))), (0x3002, i64(m.isImage ? 1 : max(1, Int((m.duration * fps.rate).rounded())))),
                (0x3004, container), (0x3202, u32(h)), (0x3203, u32(w)), (0x320c, .data([0])),
                (0x320d, .data(AAFCodec.i32(42) + AAFCodec.i32(0))), (0x320e, rational((w / a, h / a))),
                (0x3301, u32(8)), (0x3302, u32(2)),
            ])
        }
        func sound() -> AAFObject {
            let rate = Int((m.sampleRate ?? 48000).rounded())
            return AAFObject(AAFClass.pcmDescriptor, [
                (0x3001, rational((rate, 1))), (0x3002, i64(Int((m.duration * Double(rate)).rounded()))), (0x3004, container),
                (0x3d01, u32(24)), (0x3d03, rational((rate, 1))), (0x3d07, u32(channels)),
                (0x3d09, u32(rate * 3 * channels)), (0x3d0a, .data(AAFCodec.u16(UInt16(3 * channels)))),
            ])
        }
        var descriptor: AAFObject
        if picture && channels > 0 {
            let fps = editRate
            descriptor = AAFObject(AAFClass.multipleDescriptor, [(0x3001, rational(fps)), (0x3002, i64(total)), (0x3004, container), (0x3f01, .vector([image(), sound()]))])
        } else {
            descriptor = picture ? image() : sound()
        }
        descriptor.set(0x2f01, .vector([locator]))
        let fileName = (m.conformPath as NSString).lastPathComponent
        var out = [
            mob(AAFClass.masterMob, id: master, name: m.name, slots: masterSlots),
            {
                var o = mob(AAFClass.sourceMob, id: fileID, name: fileName.isEmpty ? m.name : fileName, slots: fileSlots)
                o.set(0x4701, .strong(descriptor))
                return o
            }(),
        ]
        if tape {
            let format = m.timecodeFormat(fallback: p.canvas.fps)
            let tcFrames = m.timecodeFrames(fallback: p.canvas.fps) ?? 0
            let tcRate: (Int, Int) = {
                let g = max(1, FrameGrid.gcd(format.frameDen, format.frameNum))
                return (format.frameDen / g, format.frameNum / g)
            }()
            var slots = ids.map { s in timelineSlot(s.slot, name: nil, track: s.track, segment: sourceClip(s.kind, length: total, mob: .zero, slot: 0, start: 0)) }
            if tc {
                let tcLength = max(1, format.frameCount(m.duration))
                let code = AAFObject(AAFClass.timecode, [(0x0201, dataDef(AAFDef.timecode)), (0x0202, i64(tcLength)), (0x1501, i64(tcFrames)),
                                                         (0x1502, .data(AAFCodec.u16(UInt16(format.nominal)))), (0x1503, .data(AAFCodec.bool(format.dropFrame)))])
                slots.append(timelineSlot((ids.map(\.slot).max() ?? 0) + 1, name: nil, track: 1, segment: code, rate: tcRate))
            }
            var o = mob(AAFClass.sourceMob, id: tapeID, name: m.reel ?? m.name, slots: slots)
            o.set(0x4701, .strong(AAFObject(AAFClass.tapeDescriptor, [])))
            out.append(o)
        }
        return out
    }

    // MARK: Document

    mutating func document() -> AAFDocument {
        var picture: [(Track, Int, Slot)] = []
        var sound: [(Track, Int, Slot, Int)] = []
        var v = 0, a = 0
        for t in p.tracks where t.kind == .video {
            v += 1
            picture.append((t, v, pictureSlot(t)))
        }
        for t in p.tracks.filter({ $0.kind == .video }) + p.tracks.filter({ $0.kind == .audio }) {
            for lane in soundSlots(t) {
                sound.append((t, a + 1, lane.slot, lane.channels))
                a += lane.channels
            }
        }
        for (_, _, s) in picture { for r in collect(s, kind: AAFDef.picture) { widen(r) } }
        for (_, _, s, _) in sound { for r in collect(s, kind: AAFDef.sound) { widen(r) } }
        var mobs: [AAFObject] = []
        for m in p.media where ranges[m.id] != nil {
            let r = ranges[m.id]!
            let total = m.isImage ? r.hi : max(f(m.duration), r.hi)
            let range = (lo: max(0, r.lo - handleFrames), hi: min(total, r.hi + handleFrames))
            ranges[m.id] = range
            let id = AAFMobID(seed: p.name + "\u{1}" + m.id + "\u{1}" + m.conformPath + "\u{1}master")
            masters[m.id] = id
            mobs += mediaMobs(m, range: range, master: id)
        }

        let end = p.tracks.flatMap(\.clips).map { f($0.end) }.max() ?? 0
        let tcFormat = p.canvas.timecodeFormat
        var slots: [AAFObject] = [timelineSlot(1, name: "TC1", track: 1, segment: AAFObject(AAFClass.timecode, [
            (0x0201, dataDef(AAFDef.timecode)), (0x0202, i64(end)), (0x1501, i64(p.startFrame)),
            (0x1502, .data(AAFCodec.u16(UInt16(tcFormat.nominal)))), (0x1503, .data(AAFCodec.bool(tcFormat.dropFrame)))]))]
        var nextID = 2
        for (t, n, s) in picture {
            slots.append(timelineSlot(nextID, name: t.name, track: n, segment: sequence(s, kind: AAFDef.picture, channel: nil)))
            nextID += 1
        }
        for (t, first, s, channels) in sound {
            for k in 0..<channels {
                slots.append(timelineSlot(nextID, name: t.name, track: first + k, segment: sequence(s, kind: AAFDef.sound, channel: k)))
                nextID += 1
            }
        }
        let markers = p.markers.filter { $0.time >= 0 }.sorted { $0.time < $1.time }
        if !markers.isEmpty {
            let events = markers.map { mk -> AAFObject in
                let text = [mk.label, mk.note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
                return AAFObject(AAFClass.descriptiveMarker, [(0x0201, dataDef(AAFDef.descriptiveMetadata)), (0x0601, i64(f(mk.time))), (0x0602, str(text))])
            }
            let seq = AAFObject(AAFClass.sequence, [(0x0201, dataDef(AAFDef.descriptiveMetadata)), (0x1001, .vector(events))])
            slots.append(AAFObject(AAFClass.eventMobSlot, [(0x4801, u32(1000)), (0x4803, .strong(seq)), (0x4804, u32(1)), (0x4901, rational(editRate))]))
        }
        var composition = mob(AAFClass.compositionMob, id: AAFMobID(seed: p.name + "\u{1}composition"), name: p.name, slots: slots)
        composition.set(0x4408, .data(AAFDef.usageTopLevel.bytes))
        // AAF has no sequence raster; Cutline sizes the timeline from it on import.
        composition.set(0x4406, comments([("Cutline canvas", "\(p.canvas.width)x\(p.canvas.height)")]))
        mobs.insert(composition, at: 0)
        return assemble(mobs)
    }

    mutating func widen(_ r: (media: String, lo: Int, hi: Int)) {
        let old = ranges[r.media]
        ranges[r.media] = (min(old?.lo ?? r.lo, r.lo), max(old?.hi ?? r.hi, r.hi))
    }

    func definition(_ cls: AUID, _ id: AUID, _ name: String, _ extra: [(pid: UInt16, value: AAFValue)] = []) -> AAFObject {
        AAFObject(cls, [(0x1b01, .data(id.bytes)), (0x1b02, str(name))] + extra)
    }

    func assemble(_ mobs: [AAFObject]) -> AAFDocument {
        var params: [AAFObject] = []
        var ops: [AAFObject] = []
        func param(_ list: [(AUID, String)]) -> AAFValue {
            for (id, name) in list where !params.contains(where: { $0.auid(0x1b01) == id }) {
                params.append(definition(AAFClass.parameterDefinition, id, name, [(0x1f01, .weak(AAFWeakRef(tag: AAFTag.types, keyPid: 0x0005, key: AAFDef.rationalType.bytes)))]))
            }
            return .weakSet(list.map { AAFWeakRef(tag: AAFTag.parameterDefs, keyPid: 0x1b01, key: $0.0.bytes) })
        }
        func picture(_ op: AUID, _ name: String, _ list: [(AUID, String)], timeWarp: Bool = false) -> AAFObject {
            definition(AAFClass.operationDefinition, op, name, [(0x1e01, dataDef(AAFDef.picture)), (0x1e02, .data(AAFCodec.bool(timeWarp))), (0x1e07, .data(AAFCodec.i32(1))), (0x1e09, param(list))])
        }
        let order = [AAFDef.videoDissolve, AAFDef.monoAudioDissolve, AAFDef.monoAudioGain, AAFDef.videoSpeedControl, AAFDef.videoCrop, AAFDef.videoScale,
                     AAFDef.videoRotate, AAFDef.videoPosition, AAFDef.videoOpacity]
        for op in order where operations.contains(op) {
            switch op {
            case AAFDef.videoDissolve:
                ops.append(definition(AAFClass.operationDefinition, op, "VideoDissolve", [(0x1e01, dataDef(AAFDef.picture)), (0x1e07, .data(AAFCodec.i32(2))), (0x1e09, param([(AAFDef.level, "Level")]))]))
            case AAFDef.monoAudioDissolve:
                ops.append(definition(AAFClass.operationDefinition, op, "MonoAudioDissolve", [(0x1e01, dataDef(AAFDef.sound)), (0x1e07, .data(AAFCodec.i32(2)))]))
            case AAFDef.monoAudioGain:
                ops.append(definition(AAFClass.operationDefinition, op, "MonoAudioGain", [(0x1e01, dataDef(AAFDef.sound)), (0x1e07, .data(AAFCodec.i32(1))), (0x1e09, param([(AAFDef.amplitude, "Amplitude")]))]))
            case AAFDef.videoSpeedControl:
                ops.append(picture(op, "Motion Control", [(AAFDef.speedRatio, "SpeedRatio"), (AAFDef.avidSpeedOffsetMap, "PARAM_SPEED_OFFSET_MAP_U"), (AAFDef.avidSpeedMap, "PARAM_SPEED_MAP_U")], timeWarp: true))
            case AAFDef.videoCrop:
                ops.append(picture(op, "Video Crop", [(AAFDef.cropLeft, "CropLeft"), (AAFDef.cropRight, "CropRight"), (AAFDef.cropTop, "CropTop"), (AAFDef.cropBottom, "CropBottom")]))
            case AAFDef.videoScale:
                ops.append(picture(op, "Video Scale", [(AAFDef.scaleX, "ScaleX"), (AAFDef.scaleY, "ScaleY")]))
            case AAFDef.videoRotate:
                ops.append(picture(op, "Video Rotate", [(AAFDef.rotation, "Rotation")]))
            case AAFDef.videoPosition:
                ops.append(picture(op, "Video Position", [(AAFDef.positionOffsetX, "PositionOffsetX"), (AAFDef.positionOffsetY, "PositionOffsetY")]))
            default:
                ops.append(picture(op, "Video Opacity", [(AAFDef.opacityLevel, "OpacityLevel")]))
            }
        }
        let dataDefs = [(AAFDef.picture, "Picture"), (AAFDef.sound, "Sound"), (AAFDef.timecode, "Timecode"), (AAFDef.descriptiveMetadata, "DescriptiveMetadata")]
            .map { definition(AAFClass.dataDefinition, $0.0, $0.1) }
        var dictionary = AAFObject(AAFClass.dictionary, [
            (0x2605, .set(dataDefs, keyPid: 0x1b01)),
            (0x2608, .set([definition(AAFClass.containerDefinition, AAFDef.externalContainer, "External")], keyPid: 0x1b01)),
            (0x2609, .set([definition(AAFClass.interpolationDefinition, AAFDef.linearInterpolation, "LinearInterp")], keyPid: 0x1b01)),
        ])
        if !ops.isEmpty { dictionary.set(0x2603, .set(ops, keyPid: 0x1b01)) }
        if !params.isEmpty { dictionary.set(0x2604, .set(params, keyPid: 0x1b01)) }
        let stamp = AAFValue.data(AAFCodec.timestamp(date))
        let identification = AAFObject(AAFClass.identification, [
            (0x3c01, str("Cutline")), (0x3c02, str("Cutline")),
            (0x3c03, .data(AAFCodec.u16(1) + AAFCodec.u16(0) + AAFCodec.u16(0) + AAFCodec.u16(0) + [1])),
            (0x3c04, str("1.1")), (0x3c05, .data(AUID("6c8f3a52-1b7e-4d0e-9a35-c07d1e2f6a41").bytes)), (0x3c06, stamp),
            (0x3c08, str("macOS")), (0x3c09, .data(AAFMobID(seed: p.name + "\u{1}generation").bytes.suffix(16).map { $0 })),
        ])
        let header = AAFObject(AAFClass.header, [
            (0x3b01, .data(AAFCodec.u16(0x4949))), (0x3b02, stamp),
            (0x3b03, .strong(AAFObject(AAFClass.contentStorage, [(0x1901, .set(mobs, keyPid: 0x4401))]))),
            (0x3b04, .strong(dictionary)), (0x3b05, .data([1, 1])),
            (0x3b06, .vector([identification])), (0x3b07, .data(AAFCodec.u32(1))), (0x3b09, .data(AAFDef.editProtocol.bytes)),
        ])
        var used = Set<AUID>()
        header.walk { used.insert($0.classID) }
        used.formUnion([AAFClass.metaDictionary, AAFClass.classDefinition, AAFClass.propertyDefinition])
        let model = AAFMetaModel.shared
        var meta = model.metaDictionary(for: used)
        let typeClasses = Set(meta.objects(0x0004).map(\.classID))
        if !typeClasses.isSubset(of: used) { meta = model.metaDictionary(for: used.union(typeClasses)) }
        return AAFDocument(root: AAFObject(AAFDocument.rootClass, [(0x0001, .strong(meta)), (0x0002, .strong(header))]), referencedPaths: AAFTag.paths)
    }
}
