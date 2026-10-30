import Foundation

/// How an effect stack mixes, like the node tree of a grading suite.
///
/// Consecutive effects with the same `node` label form one node (applied in order inside it); an effect without a
/// label is a node on its own. Each node has a `node_mode`:
/// - serial (default): takes the output of the node before.
/// - parallel: every node in a run of parallel nodes takes the same input, and their changes are added, so two
///   corrections from one input neither compound nor dilute each other.
/// - layer: every node in a run of layer nodes takes the same input; each is composited over the result so far
///   (starting from that input) with `node_blend` and `node_opacity`, restricted to its key; later layers on top.
/// - outside: applies where the previous node's key is not (its limit window/qualifier, inverted).
/// The node's key is the limit of its first limited effect. `node_opacity` fades a node's result into its input.
public enum EffectNodes {
    public enum Mode: String, CaseIterable, Sendable {
        case serial, parallel, layer, outside
    }

    public struct Node: Equatable, Sendable {
        public var label: String
        public var mode: Mode
        public var blend: BlendMode
        /// Indices into the effect stack, in order.
        public var effects: [Int]
        /// The effect whose node_opacity the node uses.
        public var opacityFrom: Int
        /// The effect whose limit is the node's key, if any.
        public var key: Int?
    }

    /// Effects that take node parameters; the others are serial nodes of their own.
    public static func takesNodes(_ type: String) -> Bool {
        EffectCatalog.type(type)?.spec("node_mode") != nil
    }

    public static func nodes(_ effects: [Effect]) -> [Node] {
        var out: [Node] = []
        for (i, e) in effects.enumerated() {
            let nodal = takesNodes(e.type)
            let label = nodal ? (e.params["node"]?.string ?? "") : ""
            if !label.isEmpty, let last = out.last, last.label == label, effects[last.effects[0]].params["node"]?.string == label {
                out[out.count - 1].effects.append(i)
                continue
            }
            out.append(Node(label: label.isEmpty ? e.id : label, mode: .serial, blend: .normal, effects: [i], opacityFrom: i, key: nil))
        }
        for n in out.indices {
            let members = out[n].effects.map { effects[$0] }
            guard takesNodes(members[0].type) else { continue }
            if let m = members.lazy.compactMap({ $0.params["node_mode"]?.string.flatMap(Mode.init) }).first { out[n].mode = m }
            if let b = members.lazy.compactMap({ $0.params["node_blend"]?.string.flatMap(BlendMode.init) }).first { out[n].blend = b }
            if let k = out[n].effects.first(where: { effects[$0].params["node_opacity"] != nil }) { out[n].opacityFrom = k }
            out[n].key = out[n].effects.first { (effects[$0].params["limit"]?.string ?? "none") != "none" }
        }
        return out
    }

    /// True when every node is a plain serial effect, so the stack reads as a simple chain.
    public static func isChain(_ effects: [Effect]) -> Bool {
        nodes(effects).allSatisfy { $0.mode == .serial && $0.effects.count == 1 && $0.label == effects[$0.effects[0]].id }
    }

    /// The node structure for project_status, or nil for a plain chain.
    public static func describe(_ effects: [Effect]) -> String? {
        guard !isChain(effects) else { return nil }
        let nodes = nodes(effects)
        func members(_ n: Node) -> String {
            n.effects.map { i in
                let e = effects[i]
                var s = "\(e.id) \(e.type)"
                if let limit = e.params["limit"]?.string, limit != "none" { s += " [key: \(limit)\(e.params["q_preset"]?.string.map { " \($0)" } ?? "")]" }
                if !e.enabled { s += " (off)" }
                return s
            }.joined(separator: ", ")
        }
        func opacity(_ n: Node) -> String {
            let o = effects[n.opacityFrom].params["node_opacity"]?.number ?? 1
            return o < 0.999 ? " at \(Int((o * 100).rounded()))%" : ""
        }
        var lines = ["Node graph, input to output:"]
        var step = 1
        var i = 0
        while i < nodes.count {
            let n = nodes[i]
            switch n.mode {
            case .serial:
                lines.append("  \(step). \(n.label): \(members(n))\(opacity(n))")
                i += 1
            case .outside:
                var note = ""
                if i == 0 { note = " (no node before it: does nothing)" }
                else if let k = nodes[i - 1].key { note = " (outside \(nodes[i - 1].label)'s key from \(effects[k].id))" }
                else { note = " (\(nodes[i - 1].label) has no key, so this does nothing; give it a limit)" }
                lines.append("  \(step). \(n.label) outside\(note): \(members(n))\(opacity(n))")
                i += 1
            case .parallel, .layer:
                var j = i
                while j < nodes.count && nodes[j].mode == n.mode { j += 1 }
                lines.append(n.mode == .parallel
                    ? "  \(step). parallel mixer: each node from the same input, their changes added"
                    : "  \(step). layer mixer: each node from the same input, composited in order over it (later on top)")
                for m in nodes[i..<j] {
                    let how = n.mode == .layer ? " (\(m.blend.rawValue)\(opacity(m)), inside \(m.key == nil ? "the whole picture" : "its key"))" : opacity(m)
                    lines.append("       \(m.label)\(how): \(members(m))")
                }
                i = j
            }
            step += 1
        }
        return lines.joined(separator: "\n")
    }
}
