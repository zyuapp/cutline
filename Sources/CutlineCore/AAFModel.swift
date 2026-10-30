import Foundation

/// Class identifiers of the AAF object model.
enum AAFClass {
    static func id(_ n: String) -> AUID { AUID("0d010101-0101-\(n)-060e-2b3402060101") }
    static let component = id("0200"), segment = id("0300"), essenceGroup = id("0500"), event = id("0600")
    static let commentMarker = id("0800"), filler = id("0900"), operationGroup = id("0a00"), nestedScope = id("0b00")
    static let pulldown = id("0c00"), scopeReference = id("0d00"), selector = id("0e00"), sequence = id("0f00")
    static let sourceClip = id("1100"), timecode = id("1400"), transition = id("1700"), contentStorage = id("1800")
    static let controlPoint = id("1900"), dataDefinition = id("1b00"), operationDefinition = id("1c00")
    static let parameterDefinition = id("1d00"), containerDefinition = id("2000"), interpolationDefinition = id("2100")
    static let dictionary = id("2200"), fileDescriptor = id("2500"), digitalImageDescriptor = id("2700"), cdciDescriptor = id("2800")
    static let rgbaDescriptor = id("2900"), waveDescriptor = id("2c00"), aifcDescriptor = id("2600"), tapeDescriptor = id("2e00")
    static let header = id("2f00"), identification = id("3000"), networkLocator = id("3200"), textLocator = id("3300")
    static let compositionMob = id("3500"), masterMob = id("3600"), sourceMob = id("3700"), eventMobSlot = id("3900")
    static let timelineMobSlot = id("3b00"), constantValue = id("3d00"), varyingValue = id("3e00"), taggedValue = id("3f00")
    static let descriptiveMarker = id("4100"), soundDescriptor = id("4200"), multipleDescriptor = id("4400")
    static let pcmDescriptor = id("4800"), importDescriptor = id("4a00"), filmDescriptor = id("2d00")
    static let metaDictionary = AUID("0d010101-0225-0000-060e-2b3402060101")
    static let classDefinition = AUID("0d010101-0201-0000-060e-2b3402060101")
    static let propertyDefinition = AUID("0d010101-0202-0000-060e-2b3402060101")
}

/// Data, operation, parameter, interpolation and container definitions Cutline writes and recognizes.
enum AAFDef {
    static let picture = AUID("01030202-0100-0000-060e-2b3404010101")
    static let sound = AUID("01030202-0200-0000-060e-2b3404010101")
    static let timecode = AUID("01030201-0100-0000-060e-2b3404010101")
    static let descriptiveMetadata = AUID("01030201-1000-0000-060e-2b3404010101")
    static let legacyPicture = AUID("6f3c8ce1-6cef-11d2-807d-006008143e6f")
    static let legacySound = AUID("78e1ebe1-6cef-11d2-807d-006008143e6f")
    static let legacyTimecode = AUID("7f275e81-77e5-11d2-807f-006008143e6f")
    static let pictureWithMatte = AUID("05cba732-1daa-11d3-80ad-006008143e6f")
    static let pictureKinds: Set<AUID> = [picture, legacyPicture, pictureWithMatte]
    static let soundKinds: Set<AUID> = [sound, legacySound]
    static let timecodeKinds: Set<AUID> = [timecode, legacyTimecode, AUID("01030201-0200-0000-060e-2b3404010101"), AUID("01030201-0300-0000-060e-2b3404010101")]

    static let videoDissolve = AUID("0c3bea40-fc05-11d2-8a29-0050040ef7d2")
    static let monoAudioDissolve = AUID("0c3bea41-fc05-11d2-8a29-0050040ef7d2")
    static let monoAudioGain = AUID("9d2ea894-0968-11d3-8a38-0050040ef7d2")
    static let videoSpeedControl = AUID("9d2ea890-0968-11d3-8a38-0050040ef7d2")
    static let level = AUID("e4962320-2267-11d3-8a4c-0050040ef7d2")
    static let amplitude = AUID("e4962321-2267-11d3-8a4c-0050040ef7d2")
    static let speedRatio = AUID("72559a80-24d7-11d3-8a50-0050040ef7d2")
    static let linearInterpolation = AUID("5b6c85a4-0ede-11d3-80a9-006008143e6f")
    static let constantInterpolation = AUID("5b6c85a5-0ede-11d3-80a9-006008143e6f")
    static let externalContainer = AUID("4313b572-d8ba-11d2-809b-006008143e6f")

    static let rationalType = AUID("03010100-0000-0000-060e-2b3401040101")
    static let stringType = AUID("01100200-0000-0000-060e-2b3401040101")
    static let int32Type = AUID("01010700-0000-0000-060e-2b3401040101")

    static let editProtocol = AUID("0d011201-0100-0000-060e-2b3404010105")
    static let usageTopLevel = AUID(bytes: [0x02, 0x01, 0x01, 0x0d, 0x01, 0x01, 0x00, 0x07, 0x06, 0x0e, 0x2b, 0x34, 0x04, 0x01, 0x01, 0x01])
    static let usageLowerLevel = AUID(bytes: [0x02, 0x01, 0x01, 0x0d, 0x01, 0x01, 0x00, 0x08, 0x06, 0x0e, 0x2b, 0x34, 0x04, 0x01, 0x01, 0x01])
}

/// Indices into the referenced-properties table Cutline writes: where each kind of weak reference points.
enum AAFTag {
    static let classes: UInt16 = 0, types: UInt16 = 1, dataDefs: UInt16 = 2, operationDefs: UInt16 = 3
    static let parameterDefs: UInt16 = 4, containerDefs: UInt16 = 5, interpolationDefs: UInt16 = 6
    static let paths: [[UInt16]] = [[0x0001, 0x0003], [0x0001, 0x0004], [0x0002, 0x3b04, 0x2605], [0x0002, 0x3b04, 0x2603],
                                    [0x0002, 0x3b04, 0x2604], [0x0002, 0x3b04, 0x2608], [0x0002, 0x3b04, 0x2609]]
}

/// The baseline model from `AAFMetaTable`: class and type definitions as MetaDictionary objects, property names
/// for storage names, and each class's required properties.
struct AAFMetaModel {
    struct ClassDef {
        var id: AUID
        var name: String
        var parent: AUID
        var concrete: Bool
        var properties: [(pid: UInt16, id: AUID, name: String, type: AUID, optional: Bool, unique: Bool)]
    }

    var classes: [AUID: ClassDef] = [:]
    var classOrder: [AUID] = []
    var types: [AUID: AAFObject] = [:]
    var typeOrder: [AUID] = []
    var names: [UInt16: String] = [0x0001: "MetaDictionary", 0x0002: "Header"]

    static let shared = AAFMetaModel(AAFMetaTable.text)

    init(_ text: String) {
        var current: AUID?
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            guard let kind = f.first else { continue }
            switch kind {
            case "C" where f.count >= 5:
                let id = AUID(f[1])
                classes[id] = ClassDef(id: id, name: f[2], parent: AUID(f[3]), concrete: f[4] == "1", properties: [])
                classOrder.append(id)
                current = id
            case "P" where f.count >= 6:
                guard let c = current, let pid = UInt16(f[1], radix: 16) else { continue }
                classes[c]?.properties.append((pid, AUID(f[2]), f[3], AUID(f[4]), f[5] == "1", f.count > 6 && f[6] == "u"))
                names[pid] = f[3]
            case "T" where f.count >= 4:
                let id = AUID(f[2])
                var o = AAFObject(AUID(f[1]), [(0x0005, .data(id.bytes)), (0x0006, .data(AAFCodec.string(f[3])))])
                for token in f.dropFirst(4) {
                    let kv = token.split(separator: "=", maxSplits: 1).map(String.init)
                    guard kv.count == 2, let pid = UInt16(kv[0], radix: 16) else { continue }
                    let parts = kv[1].split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    switch parts[0] {
                    case "x": o.properties.append((pid, .data(AAFMetaModel.hex(parts[1]))))
                    case "c": o.properties.append((pid, .weak(AAFWeakRef(tag: AAFTag.classes, keyPid: 0x0005, key: AUID(parts[1]).bytes))))
                    case "t": o.properties.append((pid, .weak(AAFWeakRef(tag: AAFTag.types, keyPid: 0x0005, key: AUID(parts[1]).bytes))))
                    case "Vt": o.properties.append((pid, .weakVector(parts[1].split(separator: ",").map { AAFWeakRef(tag: AAFTag.types, keyPid: 0x0005, key: AUID(String($0)).bytes) })))
                    default: break
                    }
                }
                types[id] = o
                typeOrder.append(id)
            default: break
            }
        }
    }

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = s.startIndex
        while let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex), i < s.endIndex {
            out.append(UInt8(s[i..<j], radix: 16) ?? 0)
            i = j
        }
        return out
    }

    func name(_ pid: UInt16) -> String { names[pid] ?? "Property" }

    /// The class and its ancestors, the class first.
    func lineage(_ id: AUID) -> [ClassDef] {
        var out: [ClassDef] = []
        var c = classes[id]
        while let def = c, !out.contains(where: { $0.id == def.id }) {
            out.append(def)
            c = classes[def.parent]
        }
        return out
    }

    /// Required properties of an object of class `id` that `o` doesn't have, by name. ObjClass is the storage's CLSID.
    func missingRequired(_ o: AAFObject) -> [String] {
        lineage(o.classID).flatMap(\.properties).filter { !$0.optional && $0.pid != 0x0101 && o[$0.pid] == nil }.map(\.name)
    }

    /// The MetaDictionary declaring `used` classes, their parents, and every type and class their properties reach.
    func metaDictionary(for used: Set<AUID>) -> AAFObject {
        var classSet = Set<AUID>(), typeSet = Set<AUID>()
        var pending = Array(used)
        func refs(_ o: AAFObject) -> [AAFWeakRef] {
            o.properties.flatMap { p -> [AAFWeakRef] in
                switch p.value {
                case .weak(let w): return [w]
                case .weakVector(let v), .weakSet(let v): return v
                default: return []
                }
            }
        }
        var typePending: [AUID] = []
        while !pending.isEmpty || !typePending.isEmpty {
            if let c = pending.popLast() {
                guard classSet.insert(c).inserted, let def = classes[c] else { continue }
                pending.append(def.parent)
                typePending += def.properties.map(\.type)
            } else if let t = typePending.popLast() {
                guard typeSet.insert(t).inserted, let o = types[t] else { continue }
                for r in refs(o) {
                    if r.tag == AAFTag.classes { pending.append(AUID(bytes: r.key)) } else { typePending.append(AUID(bytes: r.key)) }
                }
            }
        }
        let classObjects = classOrder.filter(classSet.contains).compactMap { id -> AAFObject? in
            guard let def = classes[id] else { return nil }
            let props = def.properties.map { p -> AAFObject in
                var o = AAFObject(AAFClass.propertyDefinition, [
                    (0x0005, .data(p.id.bytes)), (0x0006, .data(AAFCodec.string(p.name))), (0x000b, .data(p.type.bytes)),
                    (0x000c, .data(AAFCodec.bool(p.optional))), (0x000d, .data(AAFCodec.u16(p.pid))),
                ])
                if p.unique { o.set(0x000e, .data(AAFCodec.bool(true))) }
                return o
            }
            var o = AAFObject(AAFClass.classDefinition, [
                (0x0005, .data(id.bytes)), (0x0006, .data(AAFCodec.string(def.name))),
                (0x0008, .weak(AAFWeakRef(tag: AAFTag.classes, keyPid: 0x0005, key: def.parent.bytes))),
                (0x000a, .data(AAFCodec.bool(def.concrete))),
            ])
            if !props.isEmpty { o.set(0x0009, .set(props, keyPid: 0x0005)) }
            return o
        }
        let typeObjects = typeOrder.filter(typeSet.contains).compactMap { types[$0] }
        return AAFObject(AAFClass.metaDictionary, [(0x0003, .set(classObjects, keyPid: 0x0005)), (0x0004, .set(typeObjects, keyPid: 0x0005))])
    }
}

// MARK: Values

/// A source package identifier: SMPTE UMID label, length, instance number and material number.
struct AAFMobID: Hashable {
    var bytes: [UInt8]

    static let zero = AAFMobID(bytes: [UInt8](repeating: 0, count: 32))

    /// A UMID whose material number is a hash of `seed`, so exports of the same project name the same mobs.
    init(seed: String) {
        var h1: UInt64 = 0xcbf2_9ce4_8422_2325, h2: UInt64 = 0x8422_2325_cbf2_9ce4
        for b in seed.utf8 {
            h1 = (h1 ^ UInt64(b)) &* 0x100_0000_01b3
            h2 = (h2 ^ UInt64(b)) &* 0x100_0000_01b3 &+ 0x9e37_79b9
        }
        var material: [UInt8] = (0..<8).map { UInt8(h1 >> (8 * UInt64($0)) & 0xFF) } + (0..<8).map { UInt8(h2 >> (8 * UInt64($0)) & 0xFF) }
        material[7] = material[7] & 0x0F | 0x40
        material[8] = material[8] & 0x3F | 0x80
        bytes = [0x06, 0x0a, 0x2b, 0x34, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x0f, 0x00, 0x13, 0x00, 0x00, 0x00] + material
    }

    init(bytes: [UInt8]) { self.bytes = Array(bytes.prefix(32)) + [UInt8](repeating: 0, count: max(0, 32 - bytes.count)) }

    var isZero: Bool { bytes.allSatisfy { $0 == 0 } }
}

extension AAFCodec {
    /// An Indirect value: byte order, the type's identifier, then the value.
    static func indirect(_ type: AUID, _ value: [UInt8]) -> [UInt8] { [0x4C] + type.bytes + value }

    /// `x` as a Rational: exact for decimals of up to six places, else in 2⁻²⁴ steps.
    static func indirectRational(_ x: Double) -> [UInt8] {
        let den = [1, 10, 100, 1000, 10000, 100_000, 1_000_000].first { d in
            let n = x * Double(d)
            return abs(n - n.rounded()) < 1e-9 * Double(d) && abs(n) < Double(Int32.max)
        } ?? (abs(x) < 127 ? 1 << 24 : 1 << 16)
        return indirect(AAFDef.rationalType, rational(Int((x * Double(den)).rounded()), den))
    }

    static func indirectString(_ s: String) -> [UInt8] { indirect(AAFDef.stringType, string(s)) }

    /// The number an Indirect holds: a Rational or an integer; nil for other types.
    static func indirectNumber(_ b: [UInt8]) -> Double? {
        guard b.count >= 17 else { return nil }
        let type = AUID(bytes: Array(b[1..<17]))
        let v = Array(b[17...])
        if type == AAFDef.rationalType, let r = rational(v), r.den != 0 { return Double(r.num) / Double(r.den) }
        if type == AAFDef.int32Type, v.count >= 4 { return Double(int32(v, 0)) }
        return nil
    }

    static func indirectString(_ b: [UInt8]) -> String? {
        guard b.count >= 17, AUID(bytes: Array(b[1..<17])) == AAFDef.stringType else { return nil }
        return string(Array(b[17...]))
    }
}
