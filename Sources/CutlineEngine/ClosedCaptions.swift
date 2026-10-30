import AVFoundation
import CoreMedia
import CutlineCore
import Foundation

/// CEA-608 (line 21) closed captions: the byte-pair stream, Scenarist SCC files and QuickTime 'c608' tracks.
/// One byte pair per frame on field 1 (CC1 or CC2). Cue text may use `<i>` for italics and `\n` for line breaks.
public enum CEA608 {
    public enum Mode: String, CaseIterable, Sendable {
        /// Each caption is loaded off screen and flipped on at its start time.
        case popOn
        /// Lines appear as they arrive and scroll up in a two- or three-row window.
        case rollUp2, rollUp3
        /// Characters are drawn straight onto the screen as they arrive.
        case paintOn
    }

    /// Consecutive byte pairs, one per frame from `time`.
    public typealias Run = (time: Seconds, pairs: [UInt16])

    public static let columns = 32
    public static let maxRows = 4

    // MARK: Encoding

    /// The byte-pair stream for `cues`. Pop-on captions are loaded ahead and flipped on (EOC) at the cue start,
    /// erased (EDM) at the cue end; roll-up and paint-on text starts arriving at the cue start.
    /// A caption whose bytes do not fit before its start is shown late rather than dropped.
    public static func encode(_ cues: [TimedText], fps: Double, mode: Mode = .popOn, channel: Int = 1) -> [Run] {
        let clock = Clock(fps)
        let codes = Codes(channel: channel)
        let captions = layout(cues, mode: mode, clock: clock)
        var slots: [Int: UInt16] = [:]

        func free(_ range: ClosedRange<Int>) -> Bool { !range.contains { slots[$0] != nil } }
        func put(_ pairs: [UInt16], at start: Int) { for (i, p) in pairs.enumerated() { slots[start + i] = p } }
        /// Places units, each on consecutive free frames, as late as possible before `limit`, or else as early as
        /// possible from `lo`. Returns the frame after the last one.
        func load(_ units: [[UInt16]], before limit: Int, from lo: Int) -> Int {
            var starts: [Int] = []
            var cursor = limit
            for unit in units.reversed() {
                var start = cursor - unit.count
                while start >= lo, !free(start...start + unit.count - 1) { start -= 1 }
                guard start >= lo else { break }
                starts.append(start)
                cursor = start
            }
            if starts.count == units.count {
                for (unit, start) in zip(units.reversed(), starts) { put(unit, at: start) }
                return limit
            }
            cursor = lo
            for unit in units {
                while !free(cursor...cursor + unit.count - 1) { cursor += 1 }
                put(unit, at: cursor)
                cursor += unit.count
            }
            return cursor
        }

        var lo = 0
        var previousEnd: Int?
        for caption in captions {
            switch mode {
            case .popOn:
                if let e = previousEnd, caption.start >= e + 2 { put(codes.twice(Codes.edm), at: e) }
                var units = [codes.twice(Codes.rcl), codes.twice(Codes.enm)]
                for (i, line) in caption.lines.enumerated() {
                    units += codes.position(row: caption.rows[i], column: caption.columns[i]) + codes.text(line)
                }
                let eoc = max(caption.start, load(units, before: caption.start, from: lo))
                put(codes.twice(Codes.eoc), at: eoc)
                lo = eoc + 2
                previousEnd = max(caption.end, lo)
            case .paintOn, .rollUp2, .rollUp3:
                let rollUp = mode != .paintOn
                let modeCodes = rollUp ? codes.twice(mode == .rollUp2 ? Codes.ru2 : Codes.ru3) + codes.twice(Codes.cr) : codes.twice(Codes.rdc)
                let first = codes.position(row: caption.rows[0], column: caption.columns[0]).flatMap { $0 }
                var preamble = modeCodes + first
                if let e = previousEnd {
                    if caption.start - preamble.count >= e + 2 {
                        put(codes.twice(Codes.edm), at: e)
                        lo = max(lo, e + 2)
                    } else if !rollUp {
                        preamble += codes.twice(Codes.edm)
                    }
                }
                var body = codes.text(caption.lines[0]).flatMap { $0 }
                for i in caption.lines.indices.dropFirst() {
                    body += (codes.position(row: caption.rows[i], column: caption.columns[i]) + codes.text(caption.lines[i])).flatMap { $0 }
                }
                let start = max(caption.start - preamble.count, lo)
                put(preamble + body, at: start)
                lo = start + preamble.count + body.count
                previousEnd = max(caption.end, lo)
            }
        }
        if let e = previousEnd { put(codes.twice(Codes.edm), at: e) }
        return runs(slots, clock)
    }

    static func runs(_ slots: [Int: UInt16], _ clock: Clock) -> [Run] {
        var out: [(frame: Int, pairs: [UInt16])] = []
        for f in slots.keys.sorted() {
            if let last = out.last, last.frame + last.pairs.count == f {
                out[out.count - 1].pairs.append(slots[f]!)
            } else {
                out.append((f, [slots[f]!]))
            }
        }
        return out.map { (clock.seconds($0.frame), $0.pairs) }
    }

    struct Caption {
        var start: Int
        var end: Int
        var lines: [[Op]]
        var rows: [Int]
        var columns: [Int]
    }

    enum Op: Equatable {
        case char(Character)
        /// A mid-row style change; it occupies one column, shown as a space.
        case italics(Bool)
    }

    /// Wraps cues to 32 columns and splits them into captions: up to four rows at the bottom of the screen
    /// for pop-on and paint-on, one line at a time for roll-up. Split captions share the cue time by length.
    static func layout(_ cues: [TimedText], mode: Mode, clock: Clock) -> [Caption] {
        var out: [Caption] = []
        for cue in cues.sorted(by: { $0.start < $1.start }) where cue.end > cue.start {
            let lines = wrap(cells(cue.text))
            guard !lines.isEmpty else { continue }
            let rollUp = mode == .rollUp2 || mode == .rollUp3
            let groups = stride(from: 0, to: lines.count, by: rollUp ? 1 : maxRows).map { Array(lines[$0..<min($0 + (rollUp ? 1 : maxRows), lines.count)]) }
            let weights = groups.map { Double($0.reduce(0) { $0 + $1.count }) }
            let total = weights.reduce(0, +)
            var t = cue.start
            for (g, w) in zip(groups, weights) {
                let e = t + (cue.end - cue.start) * w / total
                let s = clock.frame(t), end = max(clock.frame(e), s + 1)
                let rows = (0..<g.count).map { 16 - g.count + $0 }
                let cols = g.map { rollUp ? 0 : (columns - $0.count) / 2 }
                out.append(Caption(start: s, end: end, lines: g, rows: rows, columns: cols))
                t = e
            }
        }
        return out
    }

    struct Cell {
        var char: Character
        var italic: Bool
    }

    /// The displayable characters of each hard line: `<i>` sets italics, other tags are dropped,
    /// characters outside the 608 set are replaced or dropped.
    static func cells(_ text: String) -> [[Cell]] {
        var lines: [[Cell]] = [[]]
        var italic = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "<", let close = chars[i...].firstIndex(of: ">") {
                let tag = String(chars[(i + 1)..<close]).lowercased()
                let name = tag.hasPrefix("/") ? String(tag.dropFirst()) : tag
                if let head = name.first, head.isLetter, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "=" || $0 == "\"" || $0 == "#" || $0 == "'" }) {
                    if name == "i" { italic = !tag.hasPrefix("/") }
                    i = close + 1
                    continue
                }
            }
            if c == "\n" || c == "\r\n" {
                lines.append([])
            } else if c != "\r" {
                for r in replacement(c) { lines[lines.count - 1].append(Cell(char: r, italic: italic)) }
            }
            i += 1
        }
        return lines
    }

    /// Lines of at most 32 columns, counting the columns mid-row italics codes take.
    static func wrap(_ hardLines: [[Cell]]) -> [[Op]] {
        var out: [[Op]] = []
        for hard in hardLines {
            let words = hard.split(whereSeparator: { $0.char == " " }).map(Array.init)
            var line: [Cell] = []
            for word in words {
                var word = word
                if !line.isEmpty {
                    let joined = line + [Cell(char: " ", italic: word[0].italic)] + word
                    if ops(joined).count <= columns { line = joined; continue }
                    out.append(ops(line))
                    line = []
                }
                while ops(word).count > columns {
                    var n = columns
                    while ops(Array(word.prefix(n))).count > columns { n -= 1 }
                    out.append(ops(Array(word.prefix(n))))
                    word.removeFirst(n)
                }
                line = word
            }
            if !line.isEmpty { out.append(ops(line)) }
        }
        return out
    }

    static func ops(_ cells: [Cell]) -> [Op] {
        var out: [Op] = []
        var italic = false
        for cell in cells {
            if cell.italic != italic {
                out.append(.italics(cell.italic))
                italic = cell.italic
                if cell.char == " " { continue }
            }
            out.append(.char(cell.char))
        }
        return out
    }

    // MARK: Character set

    /// 0x11 0x30–0x3F; 0x39 is the transparent space.
    static let special: [Character] = ["®", "°", "½", "¿", "™", "¢", "£", "♪", "à", " ", "è", "â", "ê", "î", "ô", "û"]
    /// 0x12 0x20–0x3F: Spanish, French and miscellaneous.
    static let extended12: [Character] = ["Á", "É", "Ó", "Ú", "Ü", "ü", "‘", "¡", "*", "'", "—", "©", "℠", "•", "“", "”", "À", "Â", "Ç", "È", "Ê", "Ë", "ë", "Î", "Ï", "ï", "Ô", "Ù", "ù", "Û", "«", "»"]
    /// 0x13 0x20–0x3F: Portuguese, German and Danish.
    static let extended13: [Character] = ["Ã", "ã", "Í", "Ì", "ì", "Ò", "ò", "Õ", "õ", "{", "}", "\\", "^", "_", "|", "~", "Ä", "ä", "Ö", "ö", "ß", "¥", "¤", "│", "Å", "å", "Ø", "ø", "┌", "┐", "└", "┘"]
    /// Standard-set bytes that are not ASCII.
    static let standardOverrides: [UInt8: Character] = [0x2A: "á", 0x5C: "é", 0x5E: "í", 0x5F: "ó", 0x60: "ú", 0x7B: "ç", 0x7C: "÷", 0x7D: "Ñ", 0x7E: "ñ", 0x7F: "█"]

    static func standardChar(_ b: UInt8) -> Character { standardOverrides[b] ?? Character(UnicodeScalar(b)) }

    enum Glyph {
        case standard(UInt8)
        case special(UInt8)
        /// Sent after a standard fallback, which decoders that know the extended set back over.
        case extended(set: UInt8, code: UInt8, fallback: UInt8)
    }

    static let glyphs: [Character: Glyph] = {
        var map: [Character: Glyph] = [:]
        for b in UInt8(0x20)...0x7F { map[standardChar(b)] = .standard(b) }
        for (i, c) in special.enumerated() where map[c] == nil { map[c] = .special(0x30 + UInt8(i)) }
        let fallbacks: [Character: Character] = [
            "‘": "'", "“": "\"", "”": "\"", "«": "\"", "»": "\"", "—": "-", "©": "c", "℠": " ", "•": ".", "*": ".",
            "{": "(", "}": ")", "\\": "/", "^": " ", "_": "-", "|": ":", "~": "-", "¥": "Y", "¤": "$", "│": ":",
            "┌": "+", "┐": "+", "└": "+", "┘": "+", "ß": "s", "Ø": "O", "ø": "o", "¡": "!",
        ]
        for (set, table) in [(UInt8(0x12), extended12), (0x13, extended13)] {
            for (i, c) in table.enumerated() where map[c] == nil {
                let folded = String(c).folding(options: .diacriticInsensitive, locale: nil)
                let base = fallbacks[c] ?? (folded.count == 1 ? folded.first! : " ")
                guard case .standard(let fb)? = map[base] else { continue }
                map[c] = .extended(set: set, code: 0x20 + UInt8(i), fallback: fb)
            }
        }
        return map
    }()

    static let substitutes: [Character: String] = [
        "’": "'", "‚": "'", "′": "'", "`": "'", "„": "\"", "″": "\"", "–": "-", "‐": "-", "‑": "-", "−": "-",
        "…": "...", "\u{00A0}": " ", "\t": " ", "×": "x", "æ": "ae", "Æ": "AE", "œ": "oe", "Œ": "OE",
    ]

    /// Characters that stand for `c` in the 608 set: itself, a typographic substitute, the letter without
    /// its accent, or nothing.
    static func replacement(_ c: Character) -> [Character] {
        if glyphs[c] != nil { return [c] }
        if let s = substitutes[c] { return Array(s) }
        let folded = String(c).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        if folded != String(c) { return folded.filter { glyphs[$0] != nil }.map { $0 } }
        return []
    }

    // MARK: Codes

    static func parity(_ b: UInt8) -> UInt8 {
        let v = b & 0x7F
        return v.nonzeroBitCount % 2 == 0 ? v | 0x80 : v
    }

    /// Both bytes carry odd parity in bit 7.
    public static func hasOddParity(_ pair: UInt16) -> Bool {
        UInt8(pair >> 8).nonzeroBitCount % 2 == 1 && UInt8(pair & 0xFF).nonzeroBitCount % 2 == 1
    }

    static func pair(_ a: UInt8, _ b: UInt8) -> UInt16 { UInt16(parity(a)) << 8 | UInt16(parity(b)) }

    /// First byte and second-byte base of the preamble address code for rows 1–15 on CC1.
    static let pacRows: [(UInt8, UInt8)] = [
        (0x11, 0x40), (0x11, 0x60), (0x12, 0x40), (0x12, 0x60), (0x15, 0x40), (0x15, 0x60), (0x16, 0x40), (0x16, 0x60),
        (0x17, 0x40), (0x17, 0x60), (0x10, 0x40), (0x13, 0x40), (0x13, 0x60), (0x14, 0x40), (0x14, 0x60),
    ]

    struct Codes {
        static let rcl: UInt8 = 0x20, bs: UInt8 = 0x21, der: UInt8 = 0x24, ru2: UInt8 = 0x25, ru3: UInt8 = 0x26, ru4: UInt8 = 0x27
        static let rdc: UInt8 = 0x29, edm: UInt8 = 0x2C, cr: UInt8 = 0x2D, enm: UInt8 = 0x2E, eoc: UInt8 = 0x2F

        /// CC2 sets bit 3 of the first byte.
        let ch: UInt8

        init(channel: Int) { ch = channel == 2 ? 0x08 : 0 }

        /// Control codes are sent twice; decoders drop the repeat.
        func twice(_ misc: UInt8) -> [UInt16] { twice(0x14, misc) }
        func twice(_ a: UInt8, _ b: UInt8) -> [UInt16] { let p = pair(a | ch, b); return [p, p] }

        /// PAC to the nearest indent at or left of `column`, then a tab offset for the remainder.
        func position(row: Int, column: Int) -> [[UInt16]] {
            let (b1, base) = pacRows[max(1, min(15, row)) - 1]
            var out = [twice(b1, base + 0x10 + UInt8(column / 4) * 2)]
            if column % 4 > 0 { out.append(twice(0x17, 0x20 + UInt8(column % 4))) }
            return out
        }

        /// Byte pairs for a line, grouped so a doubled code is never split.
        func text(_ ops: [Op]) -> [[UInt16]] {
            var out: [[UInt16]] = []
            var pending: UInt8?
            func standard(_ b: UInt8) {
                if let p = pending { out.append([pair(p, b)]); pending = nil } else { pending = b }
            }
            func flush() {
                if let p = pending { out.append([pair(p, 0)]); pending = nil }
            }
            for op in ops {
                switch op {
                case .italics(let on):
                    flush()
                    out.append(twice(0x11, on ? 0x2E : 0x20))
                case .char(let c):
                    switch glyphs[c] {
                    case .standard(let b)?: standard(b)
                    case .special(let code)?:
                        flush()
                        out.append(twice(0x11, code))
                    case .extended(let set, let code, let fallback)?:
                        standard(fallback)
                        flush()
                        out.append(twice(set, code))
                    case nil: break
                    }
                }
            }
            flush()
            return out
        }
    }

    // MARK: Timing

    /// Frame numbers at an exact rate: 29.97 is 30000/1001.
    struct Clock {
        let num: Int64
        let den: Int64

        init(_ fps: Double) {
            let nominal = (fps * 1.001).rounded()
            if abs(fps - nominal / 1.001) < 0.005, abs(fps - fps.rounded()) > 0.01 {
                (num, den) = (Int64(nominal) * 1000, 1001)
            } else if abs(fps - fps.rounded()) < 0.001 {
                (num, den) = (Int64(max(1, fps.rounded())), 1)
            } else {
                (num, den) = (Int64((fps * 1000).rounded()), 1000)
            }
        }

        var frameDuration: Seconds { Double(den) / Double(num) }
        func frame(_ t: Seconds) -> Int { Int((t * Double(num) / Double(den)).rounded()) }
        func seconds(_ f: Int) -> Seconds { Double(f) * Double(den) / Double(num) }
        func time(_ f: Int) -> CMTime { CMTime(value: Int64(f) * den, timescale: CMTimeScale(num)) }
    }

    /// SMPTE timecode for a frame: drop-frame (`;`) at 29.97 and 59.94, non-drop (`:`) otherwise.
    static func timecode(_ frame: Int, fps: Double) -> String {
        let clock = Clock(fps)
        let nominal = Int((Double(clock.num) / Double(clock.den)).rounded())
        let drop = clock.den == 1001 && nominal % 30 == 0 ? nominal / 15 : 0
        var f = frame
        if drop > 0 {
            let perMinute = nominal * 60 - drop, perTen = perMinute * 10 + drop
            let tens = f / perTen, rest = f % perTen
            f += drop * 9 * tens + (rest > drop ? drop * ((rest - drop) / perMinute) : 0)
        }
        let ff = f % nominal, ss = f / nominal % 60, mm = f / (nominal * 60) % 60, hh = f / (nominal * 3600)
        return String(format: "%02d:%02d:%02d%@%02d", hh, mm, ss, drop > 0 ? ";" : ":", ff)
    }

    // MARK: SCC

    /// A Scenarist SCC file: one line per run of consecutive frames, timecode then hex byte pairs.
    public static func scc(_ cues: [TimedText], fps: Double = 30000.0 / 1001, mode: Mode = .popOn, channel: Int = 1) -> String {
        scc(runs: encode(cues, fps: fps, mode: mode, channel: channel), fps: fps)
    }

    public static func scc(runs: [Run], fps: Double) -> String {
        let clock = Clock(fps)
        var out = "Scenarist_SCC V1.0\n"
        for run in runs {
            out += "\n" + timecode(clock.frame(run.time), fps: fps) + "\t" + run.pairs.map { String(format: "%04x", $0) }.joined(separator: " ") + "\n"
        }
        return out
    }

    // MARK: QuickTime track

    public static func formatDescription() throws -> CMFormatDescription {
        var fd: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_ClosedCaption, mediaSubType: kCMClosedCaptionFormatType_CEA608, extensions: nil, formatDescriptionOut: &fd)
        guard status == noErr, let fd else { throw EditError("Cannot describe the closed caption track (\(status))") }
        return fd
    }

    /// 'c608' samples covering `0..<duration`: one frame-long sample per byte pair, each a 'cdat' atom
    /// holding field 1's pair, and one null-pair sample spanning each gap.
    public static func captionSampleBuffers(_ runs: [Run], fps: Double, duration: Seconds) throws -> [CMSampleBuffer] {
        let clock = Clock(fps)
        let fd = try formatDescription()
        var slots: [Int: UInt16] = [:]
        for run in runs {
            let f = clock.frame(run.time)
            for (i, p) in run.pairs.enumerated() { slots[f + i] = p }
        }
        let total = max(clock.frame(duration), (slots.keys.max() ?? -1) + 1)
        var out: [CMSampleBuffer] = []
        var f = 0
        while f < total {
            if let p = slots[f] {
                out.append(try sample([p], from: f, frames: 1, clock, fd))
                f += 1
            } else {
                var next = f + 1
                while next < total, slots[next] == nil { next += 1 }
                out.append(try sample([0x8080], from: f, frames: next - f, clock, fd))
                f = next
            }
        }
        return out
    }

    static func sample(_ pairs: [UInt16], from frame: Int, frames: Int, _ clock: Clock, _ fd: CMFormatDescription) throws -> CMSampleBuffer {
        let size = 8 + pairs.count * 2
        var bytes: [UInt8] = [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)] + Array("cdat".utf8)
        for p in pairs { bytes += [UInt8(p >> 8), UInt8(p & 0xFF)] }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { throw EditError("Cannot allocate a caption sample") }
        CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        var timing = CMSampleTimingInfo(duration: clock.time(frames), presentationTimeStamp: clock.time(frame), decodeTimeStamp: .invalid)
        var sampleSize = bytes.count
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fd, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard let sample else { throw EditError("Cannot create a caption sample") }
        return sample
    }

    /// Writes `cues` to a `.closedCaption` input made with `formatDescription()` as the source format hint.
    public static func write(_ cues: [TimedText], to input: AVAssetWriterInput, fps: Double, duration: Seconds, mode: Mode = .popOn, channel: Int = 1) async throws {
        let samples = try captionSampleBuffers(encode(cues, fps: fps, mode: mode, channel: channel), fps: fps, duration: duration)
        try await TextTrack.append(samples, to: input)
    }

    /// The field 1 byte pairs of an asset's first 'c608' track, null padding removed.
    public static func read(_ asset: AVAsset) async throws -> [Run] {
        guard let track = try await asset.loadTracks(withMediaType: .closedCaption).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EditError("Cannot read the closed captions") }
        var runs: [Run] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
            let pairs = fieldOnePairs(bytes)
            guard pairs.contains(where: { $0 & 0x7F7F != 0 }) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let step = CMSampleBufferGetDuration(sample).seconds / Double(pairs.count)
            if let last = runs.last, abs(last.time + Double(last.pairs.count) * step - t) < step / 2 {
                runs[runs.count - 1].pairs += pairs
            } else {
                runs.append((t, pairs))
            }
        }
        if reader.status == .failed { throw reader.error ?? EditError("Reading the closed captions failed") }
        return runs
    }

    static func fieldOnePairs(_ bytes: [UInt8]) -> [UInt16] {
        var out: [UInt16] = []
        var i = 0
        while i + 8 <= bytes.count {
            let size = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard size >= 8, i + size <= bytes.count else { break }
            if bytes[(i + 4)..<(i + 8)].elementsEqual("cdat".utf8) {
                var j = i + 8
                while j + 1 < i + size { out.append(UInt16(bytes[j]) << 8 | UInt16(bytes[j + 1])); j += 2 }
            }
            i += size
        }
        return out
    }

    // MARK: Decoding

    /// The captions a viewer would see: pop-on captions from flip to erase, paint-on text from its first
    /// character to erase, and each roll-up line from its first character until the next line starts or the
    /// screen is erased. Rows join with `\n`; italics come back as `<i>`.
    public static func decode(_ runs: [Run], fps: Double = 30000.0 / 1001, channel: Int = 1) -> [TimedText] {
        let step = Clock(fps).frameDuration
        var d = Decoder(channel: channel)
        for run in runs.sorted(by: { $0.time < $1.time }) {
            var previous: UInt16?
            for (i, raw) in run.pairs.enumerated() {
                let t = run.time + Double(i) * step
                d.time = t
                let b1 = UInt8(raw >> 8) & 0x7F, b2 = UInt8(raw & 0xFF) & 0x7F
                if (0x10...0x1F).contains(b1) {
                    let code = raw & 0x7F7F
                    if previous == code { previous = nil; continue }
                    previous = code
                    d.control(b1, b2)
                } else {
                    previous = nil
                    d.characters(b1, b2)
                }
            }
        }
        d.close()
        return d.cues
    }

    struct Decoder {
        enum State: Equatable { case popOn, paintOn, rollUp(Int) }
        typealias Grid = [[Cell?]]

        static let blank: Grid = Array(repeating: Array(repeating: nil, count: CEA608.columns), count: 16)

        let channel: Int
        var state = State.popOn
        var displayed = blank, hidden = blank
        var row = 15, col = 0, italic = false
        var active = 1
        var time: Seconds = 0
        var open: (start: Seconds, text: String)?
        var rolled = false
        var cues: [TimedText] = []

        init(channel: Int) { self.channel = channel }

        static let pacLookup: [UInt16: Int] = {
            var map: [UInt16: Int] = [:]
            for (i, (b1, base)) in pacRows.enumerated() { map[UInt16(b1) << 8 | UInt16(base)] = i + 1 }
            return map
        }()

        mutating func control(_ b1: UInt8, _ b2: UInt8) {
            active = b1 & 0x08 != 0 ? 2 : 1
            guard active == channel else { return }
            let c1 = b1 & 0x77
            switch (c1, b2) {
            case (0x14...0x15, 0x20...0x2F): misc(b2)
            case (0x17, 0x21...0x23): col = min(col + Int(b2 - 0x20), CEA608.columns - 1)
            case (0x11, 0x20...0x2F):
                italic = b2 & 0x0E == 0x0E
                put(" ")
            case (0x11, 0x30...0x3F): put(special[Int(b2 - 0x30)])
            case (0x12...0x13, 0x20...0x3F):
                col = max(col - 1, 0)
                put((c1 == 0x12 ? extended12 : extended13)[Int(b2 - 0x20)])
            case (0x10...0x17, 0x40...0x7F):
                guard let r = Self.pacLookup[UInt16(c1) << 8 | UInt16(b2 & 0x60)] else { return }
                row = r
                let low = b2 & 0x1F
                if low & 0x10 != 0 {
                    col = Int((low & 0x0E) >> 1) * 4
                    italic = false
                } else {
                    col = 0
                    italic = low & 0x0E == 0x0E
                }
            default: break
            }
        }

        mutating func characters(_ b1: UInt8, _ b2: UInt8) {
            guard active == channel else { return }
            for b in [b1, b2] where b >= 0x20 { put(standardChar(b)) }
        }

        mutating func misc(_ code: UInt8) {
            switch code {
            case Codes.rcl: state = .popOn
            case Codes.rdc: state = .paintOn
            case Codes.ru2, Codes.ru3, Codes.ru4:
                if case .rollUp = state {} else {
                    close()
                    displayed = Self.blank
                    hidden = Self.blank
                    row = 15
                    col = 0
                }
                state = .rollUp(Int(code - Codes.ru2) + 2)
            case Codes.bs:
                col = max(col - 1, 0)
                edit(col..<col + 1, nil)
            case Codes.der:
                edit(col..<CEA608.columns, nil)
            case Codes.edm:
                displayed = Self.blank
                close()
            case Codes.enm: hidden = Self.blank
            case Codes.eoc:
                swap(&displayed, &hidden)
                state = .popOn
                close()
                let text = render(displayed, rows: 1...15)
                if !text.isEmpty { open = (time, text) }
            case Codes.cr:
                guard case .rollUp(let depth) = state else { return }
                let top = max(1, row - depth + 1)
                if top < row { for r in top..<row { displayed[r] = displayed[r + 1] } }
                if top > 1 { displayed[top - 1] = Array(repeating: nil, count: CEA608.columns) }
                displayed[row] = Array(repeating: nil, count: CEA608.columns)
                col = 0
                if open != nil { rolled = true }
            default: break
            }
        }

        mutating func put(_ c: Character) {
            edit(col..<col + 1, Cell(char: c, italic: italic))
            col = min(col + 1, CEA608.columns - 1)
        }

        /// Sets columns of the cursor row in the memory being written; on-screen changes extend or start the open caption.
        mutating func edit(_ columns: Range<Int>, _ cell: Cell?) {
            if state == .popOn {
                for c in columns { hidden[row][c] = cell }
                return
            }
            for c in columns { displayed[row][c] = cell }
            if rolled { close() }
            let text = state == .paintOn ? render(displayed, rows: 1...15) : render(displayed, rows: row...row)
            if open != nil { open?.text = text } else { open = (time, text) }
        }

        mutating func close() {
            if let o = open, !o.text.isEmpty { cues.append(TimedText(start: o.start, end: time, text: o.text)) }
            open = nil
            rolled = false
        }

        func render(_ grid: Grid, rows: ClosedRange<Int>) -> String {
            rows.map { line(grid[$0]) }.filter { !$0.isEmpty }.joined(separator: "\n")
        }

        func line(_ cells: [Cell?]) -> String {
            let shown = { (c: Cell?) in c.map { $0.char != " " } ?? false }
            guard let first = cells.firstIndex(where: shown), let last = cells.lastIndex(where: shown) else { return "" }
            var out = "", spaces = "", inItalics = false
            for cell in cells[first...last] {
                guard let cell, cell.char != " " else { spaces += " "; continue }
                if cell.italic != inItalics {
                    out += inItalics ? "</i>" + spaces : spaces + "<i>"
                    inItalics = cell.italic
                } else {
                    out += spaces
                }
                spaces = ""
                out.append(cell.char)
            }
            return inItalics ? out + "</i>" : out
        }
    }
}
