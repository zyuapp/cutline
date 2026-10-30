import CutlineCore
import Foundation

extension Toolbox {
    /// Per-target result lines ("<id>: <what changed>") with the same change on four or more clips folded into one
    /// line naming how many, where, and the first and last of them. Before-values (the "x" in "x→y") don't keep
    /// changes apart. At most `limit` lines are listed.
    static func compactTargets(_ lines: [String], _ p: Project, limit: Int = 20) -> String {
        guard lines.count > 3 else { return lines.joined(separator: "\n") }
        var groups: [(key: String, text: String, ids: [String])] = []
        var index: [String: Int] = [:]
        for line in lines {
            guard let r = line.range(of: ": "), p.clip(String(line[..<r.lowerBound])) != nil else {
                groups.append((line, line, []))
                continue
            }
            let id = String(line[..<r.lowerBound]), rest = String(line[r.upperBound...])
            let key = rest.replacingOccurrences(of: #"[^\s;,(]+→"#, with: "→", options: .regularExpression)
            if let i = index[key] {
                groups[i].ids.append(id)
                if groups[i].text != rest { groups[i].text = key }
            } else {
                index[key] = groups.count
                groups.append((key, rest, [id]))
            }
        }
        var out: [String] = []
        for g in groups {
            if g.ids.isEmpty { out.append(g.text); continue }
            if g.ids.count < 4 { out += g.ids.map { "\($0): \(g.text)" }; continue }
            let tracks = Set(g.ids.compactMap { p.locateClip($0).map { p.tracks[$0.track].id } }).sorted()
            let names = g.ids.prefix(2).joined(separator: ", ") + " … " + g.ids.last!
            out.append("\(g.ids.count) clips on \(tracks.joined(separator: ", ")) (\(names)): \(g.text)")
        }
        guard out.count > limit else { return out.joined(separator: "\n") }
        return (out.prefix(limit) + ["…and \(out.count - limit) more"]).joined(separator: "\n")
    }

    /// Transition lines for many cuts: the first few and the last, with a count of the rest.
    static func compactTransitions(_ lines: [String]) -> String {
        guard lines.count > 8 else { return lines.joined(separator: "\n") }
        return (lines.prefix(3) + ["…\(lines.count - 4) more like these…"] + [lines.last!]).joined(separator: "\n")
    }
}
