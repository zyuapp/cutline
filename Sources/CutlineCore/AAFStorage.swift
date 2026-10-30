import Foundation

/// An AAF identifier as stored: a GUID with little-endian Data1–3. SMPTE labels appear with their halves swapped,
/// so 06.0e.2b.34.01.01.01.01.0d.01.01.01.01.01.01.00 is "0d010101-0101-0100-060e-2b3401010101".
public struct AUID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var bytes: [UInt8]

    public init(bytes: [UInt8]) { self.bytes = Array(bytes.prefix(16)) + [UInt8](repeating: 0, count: max(0, 16 - bytes.count)) }

    /// "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx".
    public init(_ s: String) {
        let hex = s.filter(\.isHexDigit)
        var v: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) {
            v.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        guard v.count == 16 else { self.init(bytes: v); return }
        self.init(bytes: [v[3], v[2], v[1], v[0], v[5], v[4], v[7], v[6]] + v[8...])
    }

    public static let zero = AUID(bytes: [])

    public var description: String {
        let b = bytes
        let h = { (r: [UInt8]) in r.map { String(format: "%02x", $0) }.joined() }
        return "\(h([b[3], b[2], b[1], b[0]]))-\(h([b[5], b[4]]))-\(h([b[7], b[6]]))-\(h(Array(b[8..<10])))-\(h(Array(b[10..<16])))"
    }

    public static func < (a: AUID, b: AUID) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }

    /// A new random identifier (version 4 UUID).
    public static func random() -> AUID {
        var u = UUID().uuid
        return withUnsafeBytes(of: &u) { AUID(bytes: Array($0)) }
    }
}

/// A weak reference: an index into the file's referenced-properties table and the target's key.
public struct AAFWeakRef: Equatable, Sendable {
    public var tag: UInt16
    public var keyPid: UInt16
    public var key: [UInt8]

    public init(tag: UInt16, keyPid: UInt16, key: [UInt8]) {
        self.tag = tag
        self.keyPid = keyPid
        self.key = key
    }
}

/// A property value in its stored form.
public indirect enum AAFValue: Equatable, Sendable {
    case data([UInt8])
    case strong(AAFObject)
    case vector([AAFObject])
    /// Elements keyed by the value of their `keyPid` property.
    case set([AAFObject], keyPid: UInt16)
    case weak(AAFWeakRef)
    case weakVector([AAFWeakRef])
    case weakSet([AAFWeakRef])
    case stream(Data)
    case other(form: UInt16, [UInt8])
}

/// An object of an AAF file: its class and properties by pid, in stored order.
public struct AAFObject: Equatable, Sendable {
    public var classID: AUID
    public var properties: [(pid: UInt16, value: AAFValue)]

    public init(_ classID: AUID, _ properties: [(pid: UInt16, value: AAFValue)] = []) {
        self.classID = classID
        self.properties = properties
    }

    public static func == (a: AAFObject, b: AAFObject) -> Bool {
        a.classID == b.classID && a.properties.count == b.properties.count && zip(a.properties, b.properties).allSatisfy { $0.pid == $1.pid && $0.value == $1.value }
    }

    public subscript(pid: UInt16) -> AAFValue? {
        get { properties.first { $0.pid == pid }?.value }
        set {
            if let i = properties.firstIndex(where: { $0.pid == pid }) {
                if let newValue { properties[i].value = newValue } else { properties.remove(at: i) }
            } else if let newValue {
                properties.append((pid, newValue))
            }
        }
    }

    public mutating func set(_ pid: UInt16, _ v: AAFValue) { self[pid] = v }

    // Typed reads of data properties (little-endian).
    public func bytes(_ pid: UInt16) -> [UInt8]? { if case .data(let b)? = self[pid] { return b } else { return nil } }
    public func int(_ pid: UInt16) -> Int64? {
        guard let b = bytes(pid), [1, 2, 4, 8].contains(b.count) else { return nil }
        var v: UInt64 = 0
        for (k, x) in b.enumerated() { v |= UInt64(x) << (8 * UInt64(k)) }
        let bits = UInt64(b.count * 8)
        if bits < 64, v & (1 << (bits - 1)) != 0 { v |= ~0 << bits }
        return Int64(bitPattern: v)
    }
    public func uint(_ pid: UInt16) -> UInt64? {
        guard let b = bytes(pid), [1, 2, 4, 8].contains(b.count) else { return nil }
        var v: UInt64 = 0
        for (k, x) in b.enumerated() { v |= UInt64(x) << (8 * UInt64(k)) }
        return v
    }
    public func string(_ pid: UInt16) -> String? { bytes(pid).map(AAFCodec.string) }
    public func auid(_ pid: UInt16) -> AUID? { bytes(pid).flatMap { $0.count == 16 ? AUID(bytes: $0) : nil } }
    public func rational(_ pid: UInt16) -> (num: Int, den: Int)? { bytes(pid).flatMap(AAFCodec.rational) }
    public func strong(_ pid: UInt16) -> AAFObject? { if case .strong(let o)? = self[pid] { return o } else { return nil } }
    public func objects(_ pid: UInt16) -> [AAFObject] {
        switch self[pid] {
        case .vector(let v)?: return v
        case .set(let v, _)?: return v
        default: return []
        }
    }
    public func weak(_ pid: UInt16) -> AAFWeakRef? { if case .weak(let w)? = self[pid] { return w } else { return nil } }

    /// Every object under this one, depth first, with this one first.
    public func walk(_ visit: (AAFObject) -> Void) {
        visit(self)
        for p in properties {
            switch p.value {
            case .strong(let o): o.walk(visit)
            case .vector(let v), .set(let v, _): for o in v { o.walk(visit) }
            default: break
            }
        }
    }
}

/// Little-endian encodings of AAF data types.
public enum AAFCodec {
    public static func u8(_ v: UInt8) -> [UInt8] { [v] }
    public static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    public static func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(v >> (8 * UInt32($0)) & 0xFF) } }
    public static func i32(_ v: Int32) -> [UInt8] { u32(UInt32(bitPattern: v)) }
    public static func i64(_ v: Int64) -> [UInt8] { (0..<8).map { UInt8(UInt64(bitPattern: v) >> (8 * UInt64($0)) & 0xFF) } }
    public static func rational(_ n: Int, _ d: Int) -> [UInt8] { i32(Int32(truncatingIfNeeded: n)) + i32(Int32(truncatingIfNeeded: d)) }
    public static func bool(_ v: Bool) -> [UInt8] { [v ? 1 : 0] }
    /// UTF-16LE with a terminating null.
    public static func string(_ s: String) -> [UInt8] { s.utf16.flatMap { u16($0) } + [0, 0] }

    public static func string(_ b: [UInt8]) -> String {
        var units: [UInt16] = []
        var i = 0
        while i + 1 < b.count {
            let u = UInt16(b[i]) | UInt16(b[i + 1]) << 8
            if u == 0 { break }
            units.append(u)
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Null-separated UTF-16 strings, as in StringArray.
    public static func strings(_ b: [UInt8]) -> [String] {
        var out: [String] = []
        var units: [UInt16] = []
        var i = 0
        while i + 1 < b.count {
            let u = UInt16(b[i]) | UInt16(b[i + 1]) << 8
            if u == 0 { out.append(String(decoding: units, as: UTF16.self)); units = [] } else { units.append(u) }
            i += 2
        }
        if !units.isEmpty { out.append(String(decoding: units, as: UTF16.self)) }
        return out
    }

    public static func rational(_ b: [UInt8]) -> (num: Int, den: Int)? {
        guard b.count >= 8 else { return nil }
        return (Int(int32(b, 0)), Int(int32(b, 4)))
    }

    public static func int32(_ b: [UInt8], _ o: Int) -> Int32 {
        guard o + 4 <= b.count else { return 0 }
        return Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
    }

    public static func uint16(_ b: [UInt8], _ o: Int) -> UInt16 { o + 2 <= b.count ? UInt16(b[o]) | UInt16(b[o + 1]) << 8 : 0 }
    public static func uint32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(bitPattern: int32(b, o)) }

    /// Timestamp: year, month, day, hour, minute, second, 1/100 s.
    public static func timestamp(_ d: Date) -> [UInt8] {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
        return u16(UInt16(c.year ?? 2000)) + [UInt8(c.month ?? 1), UInt8(c.day ?? 1), UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0), 0]
    }
}

// MARK: Structured storage encoding

/// Stored forms of the AAF structured-storage encoding.
public enum AAFStoredForm {
    public static let data: UInt16 = 0x82
    public static let dataStream: UInt16 = 0x42
    public static let strongRef: UInt16 = 0x22
    public static let strongVector: UInt16 = 0x32
    public static let strongSet: UInt16 = 0x3A
    public static let weakRef: UInt16 = 0x02
    public static let weakVector: UInt16 = 0x12
    public static let weakSet: UInt16 = 0x1A
    public static let uniqueID: UInt16 = 0x86
}

/// An AAF file's object tree in structured storage: the root object (MetaDictionary pid 1, Header pid 2) and the
/// referenced-properties table weak references index.
public struct AAFDocument: Equatable, Sendable {
    public var root: AAFObject
    /// Pid paths from the root to the sets weak references point into.
    public var referencedPaths: [[UInt16]]

    public init(root: AAFObject, referencedPaths: [[UInt16]]) {
        self.root = root
        self.referencedPaths = referencedPaths
    }

    public var header: AAFObject? { root.strong(0x0002) }
    public var metaDictionary: AAFObject? { root.strong(0x0001) }

    /// AAF files: a compound file whose header CLSID is an AAF signature and whose root storage is an AAF Root.
    public static func isAAF(_ data: Data) -> Bool {
        guard CompoundFile.isCompoundFile(data) else { return false }
        let b = [UInt8](data.prefix(0x60))
        return b.count >= 24 && AAFDocument.signatures.contains(Array(b[8..<24]))
    }

    public static let rootClass = AUID("b3b398a5-1c90-11d4-8053-080036210804")
    /// Header CLSIDs of AAF files with 4096- and 512-byte sectors.
    public static let signature4K: [UInt8] = AUID("0d010201-0200-0000-060e-2b3403020101").bytes
    public static let signature512: [UInt8] = AUID("42464141-000d-4d4f-060e-2b34010101ff").bytes
    static let signatures = [signature4K, signature512]

    // MARK: Reading

    public init(data: Data) throws {
        try self.init(CompoundFile(data: data))
    }

    public init(_ cf: CompoundFile) throws {
        guard cf.root.child("properties") != nil else { throw EditError("Not an AAF file: the root storage has no properties") }
        root = try AAFDocument.readObject(cf.root, depth: 0)
        referencedPaths = []
        if let s = cf.root.child("referenced properties") {
            let b = [UInt8](s.data)
            var i = 7
            let paths = Int(AAFCodec.uint16(b, 1))
            var path: [UInt16] = []
            while i + 1 < b.count, referencedPaths.count < paths {
                let p = AAFCodec.uint16(b, i)
                i += 2
                if p == 0 { referencedPaths.append(path); path = [] } else { path.append(p) }
            }
        }
    }

    static func readObject(_ s: CompoundFile.Entry, depth: Int) throws -> AAFObject {
        guard depth < 200 else { throw EditError("AAF: objects nested too deeply") }
        guard let ps = s.child("properties") else { throw EditError("AAF: storage \(s.name) has no properties stream") }
        let b = [UInt8](ps.data)
        guard b.count >= 4, b[0] == 0x4C else { throw EditError("AAF: \(s.name) properties aren't little-endian AAF properties") }
        let count = Int(AAFCodec.uint16(b, 2))
        var o = AAFObject(AUID(bytes: s.clsid))
        var at = 4 + count * 6
        guard at <= b.count else { throw EditError("AAF: \(s.name) properties are truncated") }
        func index(_ name: String) throws -> [UInt8] {
            guard let e = s.child(name + " index") else { throw EditError("AAF: \(s.name) is missing \(name) index") }
            return [UInt8](e.data)
        }
        func element(_ name: String, _ key: UInt32) throws -> AAFObject {
            let n = name + "{" + String(key, radix: 16) + "}"
            guard let c = s.child(n) else { throw EditError("AAF: \(s.name) is missing \(n)") }
            return try readObject(c, depth: depth + 1)
        }
        for k in 0..<count {
            let pid = AAFCodec.uint16(b, 4 + k * 6)
            let form = AAFCodec.uint16(b, 6 + k * 6)
            let len = Int(AAFCodec.uint16(b, 8 + k * 6))
            guard at + len <= b.count else { throw EditError("AAF: \(s.name) property \(String(pid, radix: 16)) is truncated") }
            let v = Array(b[at..<(at + len)])
            at += len
            let value: AAFValue
            switch form {
            case AAFStoredForm.data, AAFStoredForm.uniqueID: value = .data(v)
            case AAFStoredForm.strongRef:
                let name = AAFCodec.string(v)
                guard let c = s.child(name) else { throw EditError("AAF: \(s.name) is missing \(name)") }
                value = .strong(try readObject(c, depth: depth + 1))
            case AAFStoredForm.strongVector:
                let name = AAFCodec.string(v)
                let ix = try index(name)
                let n = Int(AAFCodec.uint32(ix, 0))
                guard ix.count >= 12 + n * 4 else { throw EditError("AAF: \(name) index is truncated") }
                value = .vector(try (0..<n).map { try element(name, AAFCodec.uint32(ix, 12 + $0 * 4)) })
            case AAFStoredForm.strongSet:
                let name = AAFCodec.string(v)
                let ix = try index(name)
                let n = Int(AAFCodec.uint32(ix, 0))
                let keyPid = AAFCodec.uint16(ix, 12)
                let size = ix.count > 14 ? Int(ix[14]) : 0
                guard ix.count >= 15 + n * (8 + size) else { throw EditError("AAF: \(name) index is truncated") }
                value = .set(try (0..<n).map { try element(name, AAFCodec.uint32(ix, 15 + $0 * (8 + size))) }, keyPid: keyPid)
            case AAFStoredForm.weakRef:
                guard v.count >= 5 else { throw EditError("AAF: \(s.name) weak reference is truncated") }
                value = .weak(AAFWeakRef(tag: AAFCodec.uint16(v, 0), keyPid: AAFCodec.uint16(v, 2), key: Array(v[5..<min(v.count, 5 + Int(v[4]))])))
            case AAFStoredForm.weakVector, AAFStoredForm.weakSet:
                let name = AAFCodec.string(v)
                let ix = try index(name)
                let n = Int(AAFCodec.uint32(ix, 0))
                let tag = AAFCodec.uint16(ix, 4), keyPid = AAFCodec.uint16(ix, 6)
                let size = ix.count > 8 ? Int(ix[8]) : 0
                guard ix.count >= 9 + n * size else { throw EditError("AAF: \(name) index is truncated") }
                let refs = (0..<n).map { AAFWeakRef(tag: tag, keyPid: keyPid, key: Array(ix[(9 + $0 * size)..<(9 + ($0 + 1) * size)])) }
                value = form == AAFStoredForm.weakVector ? .weakVector(refs) : .weakSet(refs)
            case AAFStoredForm.dataStream:
                let name = AAFCodec.string(Array(v.dropFirst()))
                value = .stream(s.child(name)?.data ?? Data())
            default: value = .other(form: form, v)
            }
            o.properties.append((pid, value))
        }
        return o
    }

    /// The object a weak reference names, looked up in the set its tag's path leads to.
    public func resolve(_ ref: AAFWeakRef) -> AAFObject? {
        guard Int(ref.tag) < referencedPaths.count else { return nil }
        var o = root
        let path = referencedPaths[Int(ref.tag)]
        for pid in path.dropLast() {
            guard let next = o.strong(pid) else { return nil }
            o = next
        }
        guard let last = path.last else { return nil }
        return o.objects(last).first { $0.bytes(ref.keyPid) == ref.key }
    }

    // MARK: Writing

    /// Storage and stream names: the property name, shortened to 16 characters (8, "-", the last 7), "-" and the pid in hex.
    public static func mangle(_ name: String, _ pid: UInt16) -> String {
        let n = name.count > 16 ? String(name.prefix(8)) + "-" + String(name.suffix(7)) : name
        return n + "-" + String(pid, radix: 16)
    }

    /// The compound file, with `names` giving each pid's property name for storage names.
    public func compoundFile(names: (UInt16) -> String, majorVersion: UInt16 = 4) -> CompoundFile {
        var root = AAFDocument.writeObject(self.root, name: "Root Entry", names: names)
        var rp: [UInt8] = [0x4C] + AAFCodec.u16(UInt16(referencedPaths.count)) + AAFCodec.u32(UInt32(referencedPaths.reduce(0) { $0 + $1.count + 1 }))
        for p in referencedPaths { for pid in p + [0] { rp += AAFCodec.u16(pid) } }
        root.children.append(CompoundFile.Entry(stream: "referenced properties", data: Data(rp)))
        return CompoundFile(root: root, headerCLSID: majorVersion >= 4 ? AAFDocument.signature4K : AAFDocument.signature512, majorVersion: majorVersion)
    }

    public func data(names: (UInt16) -> String, majorVersion: UInt16 = 4) -> Data { compoundFile(names: names, majorVersion: majorVersion).data() }

    static func writeObject(_ o: AAFObject, name: String, names: (UInt16) -> String) -> CompoundFile.Entry {
        var storage = CompoundFile.Entry(storage: name, clsid: o.classID.bytes)
        var head: [UInt8] = [0x4C, 0x20] + AAFCodec.u16(UInt16(o.properties.count))
        var body: [UInt8] = []
        func ref(_ pid: UInt16, _ form: UInt16, _ v: [UInt8]) {
            head += AAFCodec.u16(pid) + AAFCodec.u16(form) + AAFCodec.u16(UInt16(v.count))
            body += v
        }
        func weakIndex(_ refs: [AAFWeakRef]) -> [UInt8] {
            let first = refs.first
            var ix = AAFCodec.u32(UInt32(refs.count)) + AAFCodec.u16(first?.tag ?? 0) + AAFCodec.u16(first?.keyPid ?? 0) + [UInt8(first?.key.count ?? 0)]
            for r in refs { ix += r.key }
            return ix
        }
        for p in o.properties {
            let n = mangle(names(p.pid), p.pid)
            switch p.value {
            case .data(let v): ref(p.pid, AAFStoredForm.data, v)
            case .other(let form, let v): ref(p.pid, form, v)
            case .strong(let c):
                ref(p.pid, AAFStoredForm.strongRef, AAFCodec.string(n))
                storage.children.append(writeObject(c, name: n, names: names))
            case .vector(let v):
                ref(p.pid, AAFStoredForm.strongVector, AAFCodec.string(n))
                var ix = AAFCodec.u32(UInt32(v.count)) + AAFCodec.u32(UInt32(v.count)) + AAFCodec.u32(0xFFFF_FFFF)
                for (k, c) in v.enumerated() {
                    ix += AAFCodec.u32(UInt32(k))
                    storage.children.append(writeObject(c, name: n + "{" + String(k, radix: 16) + "}", names: names))
                }
                storage.children.append(CompoundFile.Entry(stream: n + " index", data: Data(ix)))
            case .set(let v, let keyPid):
                ref(p.pid, AAFStoredForm.strongSet, AAFCodec.string(n))
                let size = v.first?.bytes(keyPid)?.count ?? 0
                var ix = AAFCodec.u32(UInt32(v.count)) + AAFCodec.u32(UInt32(v.count)) + AAFCodec.u32(0xFFFF_FFFF) + AAFCodec.u16(keyPid) + [UInt8(size)]
                for (k, c) in v.enumerated() {
                    ix += AAFCodec.u32(UInt32(k)) + AAFCodec.u32(1) + (c.bytes(keyPid) ?? [UInt8](repeating: 0, count: size))
                    storage.children.append(writeObject(c, name: n + "{" + String(k, radix: 16) + "}", names: names))
                }
                storage.children.append(CompoundFile.Entry(stream: n + " index", data: Data(ix)))
            case .weak(let w):
                ref(p.pid, AAFStoredForm.weakRef, AAFCodec.u16(w.tag) + AAFCodec.u16(w.keyPid) + [UInt8(w.key.count)] + w.key)
            case .weakVector(let refs):
                ref(p.pid, AAFStoredForm.weakVector, AAFCodec.string(n))
                storage.children.append(CompoundFile.Entry(stream: n + " index", data: Data(weakIndex(refs))))
            case .weakSet(let refs):
                ref(p.pid, AAFStoredForm.weakSet, AAFCodec.string(n))
                storage.children.append(CompoundFile.Entry(stream: n + " index", data: Data(weakIndex(refs))))
            case .stream(let d):
                ref(p.pid, AAFStoredForm.dataStream, [0x4C] + AAFCodec.string(n))
                storage.children.append(CompoundFile.Entry(stream: n, data: d))
            }
        }
        storage.children.insert(CompoundFile.Entry(stream: "properties", data: Data(head + body)), at: 0)
        return storage
    }
}
