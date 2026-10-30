import Foundation

/// A Microsoft Compound File Binary ([MS-CFB], "structured storage"): a tree of storages and streams in one file,
/// as AAF and legacy Office files use. Reads versions 3 (512-byte sectors) and 4 (4096); writes either.
public struct CompoundFile: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var isStorage: Bool
        /// 16 bytes as stored.
        public var clsid: [UInt8]
        public var data: Data
        public var children: [Entry]
        public var stateBits: UInt32 = 0

        public init(storage name: String, clsid: [UInt8] = CompoundFile.zeroID, children: [Entry] = []) {
            self.name = name
            isStorage = true
            self.clsid = clsid
            data = Data()
            self.children = children
        }

        public init(stream name: String, data: Data) {
            self.name = name
            isStorage = false
            clsid = CompoundFile.zeroID
            self.data = data
            children = []
        }

        public func child(_ name: String) -> Entry? { children.first { $0.name == name } }

        /// Storage paths ("a/b") and stream paths with their sizes, depth first.
        public func listing(_ prefix: String = "") -> [String] {
            children.flatMap { c -> [String] in
                let p = prefix.isEmpty ? c.name : prefix + "/" + c.name
                return c.isStorage ? [p + "/"] + c.listing(p) : ["\(p) \(c.data.count)"]
            }
        }
    }

    public static let zeroID = [UInt8](repeating: 0, count: 16)

    public var root: Entry
    /// The header's CLSID field, where AAF writes its file-kind signature.
    public var headerCLSID: [UInt8]
    public var majorVersion: UInt16

    public init(root: Entry, headerCLSID: [UInt8] = CompoundFile.zeroID, majorVersion: UInt16 = 4) {
        self.root = root
        self.headerCLSID = headerCLSID
        self.majorVersion = majorVersion
    }

    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let freeSect: UInt32 = 0xFFFF_FFFF
    static let fatSect: UInt32 = 0xFFFF_FFFD
    static let difSect: UInt32 = 0xFFFF_FFFC
    static let maxRegSect: UInt32 = 0xFFFF_FFFA
    static let noStream: UInt32 = 0xFFFF_FFFF
    static let miniCutoff = 4096
    static let miniSize = 64

    public static func isCompoundFile(_ data: Data) -> Bool { data.count >= 512 && [UInt8](data.prefix(8)) == signature }

    // MARK: Ordering

    /// The directory's red-black tree order: shorter names first, then by upper-cased UTF-16 code units.
    public static func nameLess(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf16), y = Array(b.utf16)
        if x.count != y.count { return x.count < y.count }
        for (p, q) in zip(x, y) {
            let u = upper(p), v = upper(q)
            if u != v { return u < v }
        }
        return false
    }

    static func upper(_ c: UInt16) -> UInt16 {
        guard c >= 0x61 else { return c }
        if c <= 0x7A { return c - 0x20 }
        guard c >= 0x80, let s = Unicode.Scalar(c) else { return c }
        let u = String(Character(s)).uppercased().utf16
        return u.count == 1 ? u.first! : c
    }
}

/// A directory entry as stored.
public struct CFBDirectoryEntry: Equatable, Sendable {
    public var name: String
    public var type: UInt8
    public var color: UInt8
    public var left: UInt32
    public var right: UInt32
    public var child: UInt32
    public var clsid: [UInt8]
    public var start: UInt32
    public var size: UInt64
}

/// Header fields, allocation tables and the raw directory of a compound file.
public struct CFBLayout: Sendable {
    public var majorVersion: UInt16
    public var minorVersion: UInt16
    public var sectorShift: UInt16
    public var miniSectorShift: UInt16
    public var directorySectorCount: UInt32
    public var fatSectorCount: UInt32
    public var miniStreamCutoff: UInt32
    public var difatSectorCount: UInt32
    public var difat: [UInt32]
    public var fat: [UInt32]
    public var directory: [CFBDirectoryEntry]
    public var fileSize: Int
    public var directoryStart: UInt32 = CompoundFile.endOfChain
    public var miniFATStart: UInt32 = CompoundFile.endOfChain
    public var miniFAT: [UInt32] = []

    /// Every sector belongs to at most one chain (the directory, the mini FAT, the mini stream, a stream), FAT and
    /// DIFAT sectors are marked as such, and every stream's chain is as long as its size; returns the problems found.
    public func sectorProblems() -> [String] {
        var problems: [String] = []
        let sector = 1 << Int(sectorShift)
        let sectors = (fileSize - sector) / sector
        var owner = [String?](repeating: nil, count: max(sectors, fat.count))
        func claim(_ start: UInt32, _ name: String, in table: [UInt32], owners: inout [String?]) -> Int {
            var s = start, n = 0
            while s <= CompoundFile.maxRegSect {
                guard Int(s) < table.count, Int(s) < owners.count else { problems.append("\(name): sector \(s) out of range"); break }
                if let o = owners[Int(s)] { problems.append("\(name): sector \(s) also in \(o)"); break }
                owners[Int(s)] = name
                n += 1
                s = table[Int(s)]
            }
            return n
        }
        _ = claim(directoryStart, "directory", in: fat, owners: &owner)
        _ = claim(miniFATStart, "mini FAT", in: fat, owners: &owner)
        var miniOwner = [String?](repeating: nil, count: miniFAT.count)
        for (i, e) in directory.enumerated() where e.type == 2 || e.type == 5 {
            guard e.size > 0 else { continue }
            if e.type == 5 || e.size >= UInt64(miniStreamCutoff) {
                let n = claim(e.start, e.type == 5 ? "mini stream" : "stream \(i) \(e.name)", in: fat, owners: &owner)
                if UInt64(n * sector) < e.size || UInt64((n - 1) * sector) >= e.size { problems.append("\(e.name): \(n) sectors for \(e.size) bytes") }
            } else {
                let n = claim(e.start, "mini stream \(i) \(e.name)", in: miniFAT, owners: &miniOwner)
                if UInt64(n * 64) < e.size || UInt64((n - 1) * 64) >= e.size { problems.append("\(e.name): \(n) mini sectors for \(e.size) bytes") }
            }
        }
        let fatSectors = Set(difat.filter { $0 <= CompoundFile.maxRegSect }.prefix(Int(fatSectorCount)))
        for (s, v) in fat.enumerated() where s < sectors {
            if fatSectors.contains(UInt32(s)) {
                if v != CompoundFile.fatSect { problems.append("FAT sector \(s) not marked FATSECT") }
            } else if v == CompoundFile.fatSect {
                problems.append("sector \(s) marked FATSECT but not listed in the DIFAT")
            } else if v == CompoundFile.freeSect, owner[s] != nil {
                problems.append("sector \(s) free but used by \(owner[s]!)")
            } else if v <= CompoundFile.endOfChain, v != CompoundFile.difSect, owner[s] == nil {
                problems.append("sector \(s) chained but in no stream")
            }
        }
        return problems
    }

    /// Every storage's children form a valid red-black tree in directory order; returns the problems found.
    public func treeProblems() -> [String] {
        var problems: [String] = []
        var seen = Set<UInt32>()
        func entry(_ i: UInt32) -> CFBDirectoryEntry? { i == CompoundFile.noStream || Int(i) >= directory.count ? nil : directory[Int(i)] }
        /// Black height of the subtree, checking order within (lo, hi).
        func check(_ i: UInt32, parentRed: Bool, lo: String?, hi: String?) -> Int {
            guard let e = entry(i) else { return 1 }
            guard seen.insert(i).inserted else { problems.append("entry \(i) reached twice"); return 1 }
            if e.color > 1 { problems.append("\(e.name): color \(e.color)") }
            let red = e.color == 0
            if red && parentRed { problems.append("\(e.name): red child of a red node") }
            if let lo, !CompoundFile.nameLess(lo, e.name) { problems.append("\(e.name) out of order after \(lo)") }
            if let hi, !CompoundFile.nameLess(e.name, hi) { problems.append("\(e.name) out of order before \(hi)") }
            let l = check(e.left, parentRed: red, lo: lo, hi: e.name)
            let r = check(e.right, parentRed: red, lo: e.name, hi: hi)
            if l != r { problems.append("\(e.name): black heights \(l) and \(r) differ") }
            if e.type == 1 || e.type == 5 { checkStorage(e) }
            return max(l, r) + (red ? 0 : 1)
        }
        func checkStorage(_ s: CFBDirectoryEntry) {
            guard let c = entry(s.child) else { return }
            if c.color != 1 { problems.append("\(s.name): tree root \(c.name) isn't black") }
            _ = check(s.child, parentRed: false, lo: nil, hi: nil)
        }
        if let root = directory.first {
            if root.type != 5 { problems.append("entry 0 isn't the root") }
            seen.insert(0)
            checkStorage(root)
        }
        return problems
    }
}

// MARK: Reading

extension CompoundFile {
    public init(data: Data) throws {
        let (root, layout, clsid) = try CompoundFile.read(data)
        self.root = root
        headerCLSID = clsid
        majorVersion = layout.majorVersion
    }

    public static func layout(_ data: Data) throws -> CFBLayout { try read(data).1 }

    static func read(_ data: Data) throws -> (Entry, CFBLayout, [UInt8]) {
        let b = [UInt8](data)
        guard isCompoundFile(data) else { throw EditError("Not a compound file (structured storage): bad signature") }
        func u16(_ o: Int) -> UInt16 { o + 2 <= b.count ? UInt16(b[o]) | UInt16(b[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> UInt32 { o + 4 <= b.count ? UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 : 0 }
        func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
        let major = u16(26), shift = u16(30), miniShift = u16(32)
        guard u16(28) == 0xFFFE else { throw EditError("Compound file: bad byte order mark") }
        guard (major == 3 && shift == 9) || (major == 4 && shift == 12) else { throw EditError("Compound file: version \(major) with \(1 << Int(min(shift, 20)))-byte sectors isn't supported") }
        guard miniShift == 6 else { throw EditError("Compound file: mini sector shift \(miniShift)") }
        let sector = 1 << Int(shift)
        let perSector = sector / 4
        let sectorCount = max(0, (b.count - sector + sector - 1) / sector)
        func offset(_ s: UInt32) -> Int { (Int(s) + 1) * sector }

        var difat: [UInt32] = (0..<109).map { u32(76 + $0 * 4) }
        var next = u32(68)
        var difatCount = 0
        while next <= maxRegSect, difatCount < sectorCount {
            let o = offset(next)
            difat += (0..<(perSector - 1)).map { u32(o + $0 * 4) }
            next = u32(o + (perSector - 1) * 4)
            difatCount += 1
        }
        let fatSectors = Int(u32(44))
        let fatList = difat.filter { $0 <= maxRegSect }.prefix(fatSectors)
        var fat: [UInt32] = []
        fat.reserveCapacity(fatList.count * perSector)
        for s in fatList {
            let o = offset(s)
            guard o + sector <= b.count else { throw EditError("Compound file: FAT sector \(s) is past the end") }
            for i in 0..<perSector { fat.append(u32(o + i * 4)) }
        }
        func chain(_ start: UInt32, in table: [UInt32]) throws -> [UInt32] {
            var out: [UInt32] = []
            var s = start
            while s <= maxRegSect {
                guard Int(s) < table.count, out.count <= table.count else { throw EditError("Compound file: broken sector chain at \(s)") }
                out.append(s)
                s = table[Int(s)]
            }
            return out
        }
        func readChain(_ start: UInt32) throws -> [UInt8] {
            var out: [UInt8] = []
            for s in try chain(start, in: fat) {
                let o = offset(s)
                guard o < b.count else { throw EditError("Compound file: sector \(s) is past the end") }
                out += b[o..<min(o + sector, b.count)]
            }
            return out
        }

        let dirBytes = try readChain(u32(48))
        var dir: [CFBDirectoryEntry] = []
        for i in 0..<(dirBytes.count / 128) {
            let o = i * 128
            func d16(_ k: Int) -> UInt16 { UInt16(dirBytes[o + k]) | UInt16(dirBytes[o + k + 1]) << 8 }
            func d32(_ k: Int) -> UInt32 { UInt32(d16(k)) | UInt32(d16(k + 2)) << 16 }
            let len = Int(min(d16(64), 64))
            let units = stride(from: 0, to: max(0, len - 2), by: 2).map { d16($0) }
            var size = UInt64(d32(120)) | UInt64(d32(124)) << 32
            if major == 3 { size &= 0xFFFF_FFFF }
            dir.append(CFBDirectoryEntry(name: String(decoding: units, as: UTF16.self), type: dirBytes[o + 66], color: dirBytes[o + 67],
                                         left: d32(68), right: d32(72), child: d32(76), clsid: Array(dirBytes[(o + 80)..<(o + 96)]),
                                         start: d32(116), size: size))
        }
        guard let rootEntry = dir.first, rootEntry.type == 5 else { throw EditError("Compound file: no root entry") }

        let miniFAT: [UInt32] = try {
            guard u32(60) <= maxRegSect else { return [] }
            let bytes = try readChain(u32(60))
            return (0..<(bytes.count / 4)).map { i -> UInt32 in
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(bytes[i * 4 + k]) << (8 * UInt32(k)) }
                return v
            }
        }()
        let miniStream = rootEntry.start <= maxRegSect ? try readChain(rootEntry.start) : []
        let cutoff = Int(u32(56))

        func streamData(_ e: CFBDirectoryEntry) throws -> Data {
            let size = Int(e.size)
            guard size > 0 else { return Data() }
            if size < cutoff {
                var out: [UInt8] = []
                out.reserveCapacity(size)
                for s in try chain(e.start, in: miniFAT) {
                    let o = Int(s) * miniSize
                    guard o + miniSize <= miniStream.count else { throw EditError("Compound file: mini sector \(s) of \(e.name) is past the mini stream") }
                    out += miniStream[o..<(o + miniSize)]
                    if out.count >= size { break }
                }
                guard out.count >= size else { throw EditError("Compound file: stream \(e.name) is short") }
                return Data(out.prefix(size))
            }
            var out = try readChain(e.start)
            guard out.count >= size else { throw EditError("Compound file: stream \(e.name) is short (\(out.count) of \(size) bytes)") }
            out.removeLast(out.count - size)
            return Data(out)
        }

        var visited = Set<UInt32>()
        func siblings(_ i: UInt32) throws -> [UInt32] {
            guard i != noStream, Int(i) < dir.count else { return [] }
            guard visited.insert(i).inserted else { throw EditError("Compound file: directory loop at entry \(i)") }
            let e = dir[Int(i)]
            return try siblings(e.left) + [i] + siblings(e.right)
        }
        func build(_ i: UInt32) throws -> Entry {
            let e = dir[Int(i)]
            if e.type == 2 {
                var s = Entry(stream: e.name, data: try streamData(e))
                s.clsid = e.clsid
                return s
            }
            var s = Entry(storage: e.name, clsid: e.clsid)
            s.children = try siblings(e.child).filter { [1, 2].contains(dir[Int($0)].type) }.map(build)
            return s
        }
        visited.insert(0)
        let root = try build(0)
        var layout = CFBLayout(majorVersion: major, minorVersion: u16(24), sectorShift: shift, miniSectorShift: miniShift,
                               directorySectorCount: u32(40), fatSectorCount: u32(44), miniStreamCutoff: u32(56),
                               difatSectorCount: u32(72), difat: difat, fat: fat, directory: dir, fileSize: b.count)
        layout.directoryStart = u32(48)
        layout.miniFATStart = u32(60)
        layout.miniFAT = miniFAT
        return (root, layout, Array(b[8..<24]))
    }
}

// MARK: Writing

extension CompoundFile {
    public func data() -> Data {
        let v4 = majorVersion >= 4
        let sector = v4 ? 4096 : 512
        let perSector = sector / 4
        let noStream = CompoundFile.noStream, endOfChain = CompoundFile.endOfChain, freeSect = CompoundFile.freeSect
        let fatSect = CompoundFile.fatSect, difSect = CompoundFile.difSect

        // Directory in breadth-first order, root first.
        struct Flat { var entry: Entry; var left = CompoundFile.noStream; var right = CompoundFile.noStream; var child = CompoundFile.noStream; var color: UInt8 = 1; var start = CompoundFile.endOfChain; var size = 0 }
        var flat: [Flat] = [Flat(entry: root)]
        var queue = [0]
        while !queue.isEmpty {
            let p = queue.removeFirst()
            let kids = flat[p].entry.children.sorted { CompoundFile.nameLess($0.name, $1.name) }
            guard !kids.isEmpty else { continue }
            let base = flat.count
            for k in kids { flat.append(Flat(entry: k)) }
            // Balanced tree over the sorted children: the deepest level red, the rest black.
            func depth(_ lo: Int, _ hi: Int) -> Int { lo >= hi ? 0 : 1 + depth(lo, (lo + hi) / 2) }
            let maxDepth = depth(0, kids.count) - 1
            func link(_ lo: Int, _ hi: Int, _ d: Int) -> UInt32 {
                guard lo < hi else { return noStream }
                let mid = (lo + hi) / 2
                flat[base + mid].left = link(lo, mid, d + 1)
                flat[base + mid].right = link(mid + 1, hi, d + 1)
                flat[base + mid].color = d == maxDepth && d > 0 ? 0 : 1
                return UInt32(base + mid)
            }
            flat[p].child = link(0, kids.count, 0)
            for i in base..<flat.count where flat[i].entry.isStorage { queue.append(i) }
        }

        // Sectors: big streams, the mini stream, the mini FAT, the directory, then the FAT and DIFAT.
        var body: [UInt8] = []
        var fat: [UInt32] = []
        func place(_ bytes: [UInt8]) -> UInt32 {
            guard !bytes.isEmpty else { return endOfChain }
            let first = UInt32(fat.count)
            let n = (bytes.count + sector - 1) / sector
            for i in 0..<n { fat.append(i == n - 1 ? endOfChain : first + UInt32(i) + 1) }
            body += bytes
            body += [UInt8](repeating: 0, count: n * sector - bytes.count)
            return first
        }
        var mini: [UInt8] = []
        var miniFAT: [UInt32] = []
        for i in flat.indices.dropFirst() where !flat[i].entry.isStorage {
            let d = [UInt8](flat[i].entry.data)
            flat[i].size = d.count
            if d.isEmpty { flat[i].start = endOfChain; continue }
            if d.count < CompoundFile.miniCutoff {
                let first = UInt32(miniFAT.count)
                let n = (d.count + CompoundFile.miniSize - 1) / CompoundFile.miniSize
                for k in 0..<n { miniFAT.append(k == n - 1 ? endOfChain : first + UInt32(k) + 1) }
                mini += d
                mini += [UInt8](repeating: 0, count: n * CompoundFile.miniSize - d.count)
                flat[i].start = first
            } else {
                flat[i].start = place(d)
            }
        }
        for i in flat.indices where flat[i].entry.isStorage && i > 0 { flat[i].start = 0 }
        flat[0].start = place(mini)
        flat[0].size = mini.count
        if !miniFAT.isEmpty { while miniFAT.count % perSector != 0 { miniFAT.append(freeSect) } }
        var miniFATBytes: [UInt8] = []
        for v in miniFAT { miniFATBytes += le(v) }
        let miniFATStart = place(miniFATBytes)
        let miniFATSectors = (miniFATBytes.count + sector - 1) / sector

        var dirBytes: [UInt8] = []
        for f in flat {
            var e = [UInt8](repeating: 0, count: 128)
            let units = Array(f.entry.name.utf16.prefix(31))
            for (k, u) in units.enumerated() { e[k * 2] = UInt8(u & 0xFF); e[k * 2 + 1] = UInt8(u >> 8) }
            put16(&e, 64, UInt16((units.count + 1) * 2))
            e[66] = f.entry.isStorage ? (dirBytes.isEmpty ? 5 : 1) : 2
            e[67] = f.color
            put32(&e, 68, f.left)
            put32(&e, 72, f.right)
            put32(&e, 76, f.child)
            for k in 0..<16 { e[80 + k] = k < f.entry.clsid.count ? f.entry.clsid[k] : 0 }
            put32(&e, 96, f.entry.stateBits)
            put32(&e, 116, f.entry.isStorage && !dirBytes.isEmpty ? 0 : f.start)
            put32(&e, 120, UInt32(truncatingIfNeeded: f.size))
            if v4 { put32(&e, 124, UInt32(truncatingIfNeeded: UInt64(f.size) >> 32)) }
            dirBytes += e
        }
        while dirBytes.count % sector != 0 {
            var e = [UInt8](repeating: 0, count: 128)
            put32(&e, 68, noStream); put32(&e, 72, noStream); put32(&e, 76, noStream)
            dirBytes += e
        }
        let dirStart = place(dirBytes)
        let dirSectors = dirBytes.count / sector

        // FAT and DIFAT sectors cover themselves.
        let used = fat.count
        var fatSectors = 0, difatSectors = 0
        while true {
            let total = used + fatSectors + difatSectors
            let needFAT = (total + perSector - 1) / perSector
            let needDIFAT = needFAT > 109 ? (needFAT - 109 + perSector - 2) / (perSector - 1) : 0
            if needFAT == fatSectors && needDIFAT == difatSectors { break }
            fatSectors = needFAT
            difatSectors = needDIFAT
        }
        let fatStart = UInt32(used)
        for _ in 0..<fatSectors { fat.append(fatSect) }
        let difatStart = UInt32(fat.count)
        for _ in 0..<difatSectors { fat.append(difSect) }
        while fat.count % perSector != 0 { fat.append(freeSect) }
        let fatLocations = (0..<fatSectors).map { fatStart + UInt32($0) }
        var fatBytes: [UInt8] = []
        for v in fat { fatBytes += le(v) }
        body += fatBytes
        var difatBytes: [UInt8] = []
        if difatSectors > 0 {
            let rest = Array(fatLocations.dropFirst(109))
            for s in 0..<difatSectors {
                let chunk = rest.dropFirst(s * (perSector - 1)).prefix(perSector - 1)
                for v in chunk { difatBytes += le(v) }
                for _ in chunk.count..<(perSector - 1) { difatBytes += le(freeSect) }
                difatBytes += le(s == difatSectors - 1 ? endOfChain : difatStart + UInt32(s) + 1)
            }
        }
        body += difatBytes

        var h = [UInt8](repeating: 0, count: sector)
        for (k, v) in CompoundFile.signature.enumerated() { h[k] = v }
        for k in 0..<16 { h[8 + k] = k < headerCLSID.count ? headerCLSID[k] : 0 }
        put16(&h, 24, 0x003E)
        put16(&h, 26, v4 ? 4 : 3)
        put16(&h, 28, 0xFFFE)
        put16(&h, 30, v4 ? 12 : 9)
        put16(&h, 32, 6)
        put32(&h, 40, v4 ? UInt32(dirSectors) : 0)
        put32(&h, 44, UInt32(fatSectors))
        put32(&h, 48, dirStart)
        put32(&h, 56, UInt32(CompoundFile.miniCutoff))
        put32(&h, 60, miniFATSectors > 0 ? miniFATStart : endOfChain)
        put32(&h, 64, UInt32(miniFATSectors))
        put32(&h, 68, difatSectors > 0 ? difatStart : endOfChain)
        put32(&h, 72, UInt32(difatSectors))
        for k in 0..<109 { put32(&h, 76 + k * 4, k < fatLocations.count ? fatLocations[k] : freeSect) }
        return Data(h + body)
    }

    private func le(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
    private func put16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) { b[o] = UInt8(v & 0xFF); b[o + 1] = UInt8(v >> 8) }
    private func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) { for k in 0..<4 { b[o + k] = UInt8(v >> (8 * UInt32(k)) & 0xFF) } }
}
