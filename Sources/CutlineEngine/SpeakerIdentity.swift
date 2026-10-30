import CutlineCore
import Foundation

/// Speaker identity across scenes. A voice is reliable within a scene (one room, one microphone) but not across
/// scenes, so units are grouped into scenes: a pinned turn names its voice within its scene, and a name crosses into
/// another scene only on evidence measured against that scene's other voices.
extension Diarizer {
    /// Hand-set speakers to keep and spread: `pinned` per word (transcript_edit speaker), `named` per word from the
    /// previous analysis (speakers renamed from S1, S2…).
    public struct Enrollment: Equatable, Sendable {
        public var pinned: [String?]
        public var named: [String?]

        public init(pinned: [String?], named: [String?] = []) {
            self.pinned = pinned
            self.named = named
        }

        /// The pins and names of `previous`, when it describes the same `wordCount` words.
        public init?(_ previous: SpeakerAnalysis?, wordCount: Int) {
            guard let previous, previous.wordSpeakers.count == wordCount else { return nil }
            pinned = previous.pinnedWords(count: wordCount)
            named = previous.wordSpeakers.map { $0.flatMap { SpeakerAnalysis.isAutomatic($0) ? nil : $0 } }
            if pinned.allSatisfy({ $0 == nil }) && named.allSatisfy({ $0 == nil }) { return nil }
        }
    }

    /// Units closer than this belong to one scene.
    static let identitySceneGap = 8.0
    /// Scene identity at which a pinned name carries to the same voice cluster in a scene without pins.
    static let carryIdentity = 0.75
    /// The most a scene's speaker scores when no other speaker in that scene can cancel out its room and microphone.
    static let uncontrastedIdentity = 0.5

    /// Scene number per unit: runs of units with gaps under `identitySceneGap`.
    static func scenes(_ units: [Segment]) -> [Int] {
        var out: [Int] = []
        var n = 0
        for (u, unit) in units.enumerated() {
            if u > 0, unit.start - units[u - 1].end >= identitySceneGap { n += 1 }
            out.append(n)
        }
        return out
    }

    /// One identity per unit: a name from `enrollment`, or a number from voice clustering.
    struct UnitIdentity {
        var name: String?
        var via: String?
    }

    /// Names units from pins: a pinned unit keeps its name; another unit of a local speaker holding pins takes the
    /// pinned name whose voice in that scene explains it best; a voice cluster whose pinned and enrolled units agree on
    /// one name carries it to scenes without pins. Units named in the previous analysis name the clusters they mostly
    /// fall in.
    static func enroll(_ enrollment: Enrollment, labels: [Int], units: [Segment], scene: [Int], unitFrames: [[Int]], v: VoiceFrames) -> [UnitIdentity] {
        func majority(_ names: [String?], _ unit: Segment) -> String? {
            var votes: [String: Int] = [:]
            for w in unit.words where names.indices.contains(w) { if let n = names[w] { votes[n, default: 0] += 1 } }
            guard let best = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }), best.value * 2 > unit.words.count else { return nil }
            return best.key
        }
        let pinned = units.map { majority(enrollment.pinned, $0) }
        var out = units.indices.map { UnitIdentity(name: pinned[$0], via: pinned[$0] == nil ? nil : "pinned") }
        for s in Set(scene) {
            let us = scene.indices.filter { scene[$0] == s }
            var profiles: [String: GaussStats] = [:]
            for u in us { if let n = pinned[u] { profiles[n] = (profiles[n] ?? GaussStats(dims: v.dims)) + v.stats(unitFrames[u]) } }
            guard !profiles.isEmpty else { continue }
            let names = profiles.keys.sorted()
            let models = names.map { GaussModel(profiles[$0]!, floor: covarianceFloor) }
            for u in us where pinned[u] == nil {
                let local = Set(us.filter { labels[$0] == labels[u] }.compactMap { pinned[$0] })
                guard !local.isEmpty else { continue }
                if local.count == 1 { out[u] = UnitIdentity(name: local.first, via: "enrolled"); continue }
                guard !unitFrames[u].isEmpty else { continue }
                let ll = v.logLikelihoods(unitFrames[u], models)
                let best = names.indices.filter { local.contains(names[$0]) }.max { ll[$0] < ll[$1] }!
                out[u] = UnitIdentity(name: names[best], via: "enrolled")
            }
        }
        // A cluster carries a name into scenes without pins when its named units agree, no other cluster also holds
        // that name, and the scene has other voices against which its voice there is surely the same person: across
        // rooms and microphones a voice alone says little about who it is.
        let links = sceneIdentity(labels, scene: scene, unitFrames: unitFrames, v: v)
        let pinnedScenes = Set(units.indices.filter { pinned[$0] != nil }.map { scene[$0] })
        let fixed = out
        var carriers: [String: [Int]] = [:]
        for l in Set(labels).sorted() {
            var votes: [String: Int] = [:]
            for u in labels.indices where labels[u] == l { if let n = fixed[u].name { votes[n, default: 0] += unitFrames[u].count } }
            let named = votes.values.reduce(0, +)
            guard let top = votes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { continue }
            if Double(top.value) >= 0.9 * Double(named), top.value >= minSeedFrames { carriers[top.key, default: []].append(l) } else {
                for n in votes.keys { carriers[n, default: []].append(l) }
            }
        }
        for (name, held) in carriers where held.count == 1 {
            let l = held[0]
            for u in labels.indices where labels[u] == l && fixed[u].name == nil && !pinnedScenes.contains(scene[u]) {
                let alone = !scene.indices.contains { scene[$0] == scene[u] && labels[$0] != l }
                guard !alone, (links[scene[u]]?[l] ?? 0) >= carryIdentity else { continue }
                out[u] = UnitIdentity(name: name, via: "named")
            }
        }
        // Names from the previous analysis label the clusters most of their words fall in.
        if enrollment.named.contains(where: { $0 != nil }) {
            let prior = units.map { majority(enrollment.named, $0) }
            for l in Set(labels) {
                let members = labels.indices.filter { labels[$0] == l && out[$0].name == nil }
                guard !members.isEmpty else { continue }
                var votes: [String: Int] = [:]
                for u in members { votes[prior[u] ?? "", default: 0] += unitFrames[u].count }
                guard let top = votes.max(by: { $0.value < $1.value }), !top.key.isEmpty, top.value * 2 > votes.values.reduce(0, +) else { continue }
                for u in members { out[u] = UnitIdentity(name: top.key, via: "named") }
            }
        }
        return out
    }

    /// 0…1 per scene and speaker: whether the speaker's voice here is the person its cluster holds in other scenes.
    /// Within one scene, speakers share a room and microphone, so the test is relative: the speaker must lean towards
    /// its cluster's voice from elsewhere more than each other speaker of the scene does. A speaker alone in its scene
    /// scores at most `uncontrastedIdentity`. Absent for speakers heard in one scene only.
    static func sceneIdentity(_ labels: [Int], scene: [Int], unitFrames: [[Int]], v: VoiceFrames) -> [Int: [Int: Double]] {
        var out: [Int: [Int: Double]] = [:]
        for s in Set(scene) {
            var here: [Int: [Int]] = [:]
            var elsewhere: [Int: GaussStats] = [:]
            for u in labels.indices {
                if scene[u] == s { here[labels[u], default: []] += unitFrames[u] } else { elsewhere[labels[u]] = (elsewhere[labels[u]] ?? GaussStats(dims: v.dims)) + v.stats(unitFrames[u]) }
            }
            let keys = elsewhere.keys.filter { elsewhere[$0]!.n >= Double(minSpeakerFrames) }.sorted()
            guard !keys.isEmpty else { continue }
            let models = keys.map { GaussModel(elsewhere[$0]!, floor: covarianceFloor) }
            let present = here.filter { !$0.value.isEmpty }
            var perFrame: [Int: [Double]] = [:]
            for (l, frames) in present { perFrame[l] = v.logLikelihoods(frames, models).map { $0 / Double(frames.count) } }
            func sure(_ margin: Double) -> Double { 1 / (1 + exp(-margin / 1.5)) }
            for l in present.keys {
                guard let own = keys.firstIndex(of: l) else { continue }
                let rivals = present.keys.filter { $0 != l && keys.contains($0) && present[$0]!.count >= minSeedFrames }
                if rivals.isEmpty {
                    let ll = perFrame[l]!
                    let other = ll.indices.filter { $0 != own }.map { ll[$0] }.max()
                    out[s, default: [:]][l] = other.map { min(uncontrastedIdentity, sure(ll[own] - $0)) } ?? uncontrastedIdentity
                    continue
                }
                out[s, default: [:]][l] = rivals.map { m -> Double in
                    let theirs = keys.firstIndex(of: m)!
                    let mine = perFrame[l]![own] - perFrame[l]![theirs], their = perFrame[m]![own] - perFrame[m]![theirs]
                    return sure(mine - their)
                }.min()!
            }
        }
        return out
    }
}
