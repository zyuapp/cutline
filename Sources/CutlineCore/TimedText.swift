import Foundation

/// XML subtitle documents built from the shared caption cues: plain TTML 2, the IMSC 1.1 Text profile (Netflix and
/// streaming delivery) and EBU-TT-D (European broadcast and HbbTV).
public enum TimedTextFormat: String, CaseIterable, Sendable {
    case ttml
    case imsc
    case ebuttd = "ebu-tt-d"

    /// Sidecar suffix after the export's base name.
    public var fileSuffix: String {
        switch self {
        case .ttml: "ttml"
        case .imsc: "imsc.ttml"
        case .ebuttd: "ebu-tt-d.xml"
        }
    }

    static let ttmlNS = "http://www.w3.org/ns/ttml"
    static let parameterNS = "http://www.w3.org/ns/ttml#parameter"
    static let stylingNS = "http://www.w3.org/ns/ttml#styling"
    static let metadataNS = "http://www.w3.org/ns/ttml#metadata"
    static let imscProfile = "http://www.w3.org/ns/ttml/profile/imsc1.1/text"
    static let ebuMetadataNS = "urn:ebu:tt:metadata"
    static let ebuStyleNS = "urn:ebu:tt:style"
    static let ebuDistribution = "urn:ebu:tt:distribution:2018-04"
}

public struct TimedTextOptions: Sendable {
    /// Where the lines sit: "bottom" (default) or "top" of the title-safe area.
    public var position = "bottom"
    /// Colors each speaker's lines differently (and names them as TTML agents outside EBU-TT-D).
    public var speakerColors = false
    public var language = "en"
    /// The translation the text comes from (`captions.translations`); nil is the spoken language.
    public var translation: String?
    /// Rows and columns of the cell grid font sizes are measured in.
    public var cellResolution = (columns: 32, rows: 15)

    public init() {}
}

extension Project {
    /// Line colors for speaker labels, in order of first appearance.
    static let speakerPalette = ["#FFFFFF", "#FFFF00", "#00FFFF", "#00FF00", "#FF00FF", "#FF8080"]

    /// A TTML-family subtitle document for the words heard on the timeline, cue for cue the same as the .srt and .vtt
    /// (`subtitleCues`). With `range`, only cues inside it, timed from its start. `speaker` names the speaker of a
    /// transcript word anchor ("<media>.w<index>"); each cue takes its words' most common speaker.
    public func timedText(_ format: TimedTextFormat, transcripts: [String: Transcript], range: TimeRange? = nil, options o: TimedTextOptions = TimedTextOptions(), speaker: ((String) -> String?)? = nil) -> String {
        let cues = subtitleCues(transcripts: transcripts, range: range, language: o.translation)
        let ebu = format == .ebuttd
        let cueSpeakers: [String?] = cues.map { c in
            guard o.speakerColors, let speaker else { return nil }
            var votes: [String: Int] = [:]
            for a in c.anchors { if let s = speaker(a) { votes[s, default: 0] += 1 } }
            return votes.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
        }
        var speakers: [String] = []
        for s in cueSpeakers.compactMap({ $0 }) where !speakers.contains(s) { speakers.append(s) }
        func styleId(_ s: String) -> String { "speaker\(speakers.firstIndex(of: s)! + 1)" }

        var root: [(String, String)] = [("xmlns", TimedTextFormat.ttmlNS), ("xmlns:ttp", TimedTextFormat.parameterNS), ("xmlns:tts", TimedTextFormat.stylingNS), ("xmlns:ttm", TimedTextFormat.metadataNS)]
        if ebu { root += [("xmlns:ebuttm", TimedTextFormat.ebuMetadataNS), ("xmlns:ebutts", TimedTextFormat.ebuStyleNS)] }
        root.append(("xml:lang", o.language))
        root.append(("ttp:timeBase", "media"))
        if !ebu {
            // Frame rate is informative here (times are in seconds) but delivery specs ask for it.
            let nominal = Int(canvas.fps.rounded())
            root.append(("ttp:frameRate", String(nominal)))
            if abs(Double(nominal) - canvas.fps) > 0.001 { root.append(("ttp:frameRateMultiplier", "1000 1001")) }
        }
        root.append(("ttp:cellResolution", "\(o.cellResolution.columns) \(o.cellResolution.rows)"))
        if format == .imsc { root.append(("ttp:contentProfiles", TimedTextFormat.imscProfile)) }

        var head: [XMLElem] = []
        var metadata: [XMLElem] = []
        if ebu {
            metadata.append(XMLElem("ebuttm:documentMetadata", children: [XMLElem("ebuttm:conformsToStandard", text: TimedTextFormat.ebuDistribution)]))
        } else {
            metadata.append(XMLElem("ttm:title", text: name))
            for s in speakers { metadata.append(XMLElem("ttm:agent", [("xml:id", "agent_" + styleId(s)), ("type", "person")], children: [XMLElem("ttm:name", [("type", "alias")], text: s)])) }
        }
        head.append(XMLElem("metadata", children: metadata))
        // One row of the cell grid is 1/15 of the frame; text 80% of a row tall reads at broadcast sizes.
        var paragraph: [(String, String)] = [("xml:id", "paragraph"), ("tts:textAlign", "center"), ("tts:fontFamily", "proportionalSansSerif"), ("tts:fontSize", "80%"), ("tts:lineHeight", "125%")]
        if ebu { paragraph.append(("ebutts:linePadding", "0.5c")) }
        var styles = [
            XMLElem("style", paragraph),
            XMLElem("style", [("xml:id", "text"), ("tts:color", "#FFFFFF"), ("tts:backgroundColor", "#000000C2")]),
        ]
        for s in speakers {
            let i = speakers.firstIndex(of: s)!
            styles.append(XMLElem("style", [("xml:id", styleId(s)), ("tts:color", Project.speakerPalette[i % Project.speakerPalette.count]), ("tts:backgroundColor", "#000000C2")]))
        }
        head.append(XMLElem("styling", children: styles))
        let top = o.position == "top"
        head.append(XMLElem("layout", children: [
            XMLElem("region", [("xml:id", top ? "top" : "bottom"), ("tts:origin", "10% 10%"), ("tts:extent", "80% 80%"), ("tts:displayAlign", top ? "before" : "after"), ("tts:writingMode", "lrtb")]),
        ]))

        let paragraphs: [XMLElem] = cues.enumerated().map { i, c in
            var attrs = [("xml:id", "sub\(i + 1)"), ("begin", Self.ttmlTime(c.startMs)), ("end", Self.ttmlTime(c.endMs)), ("style", "paragraph")]
            if !ebu, let s = cueSpeakers[i] { attrs.append(("ttm:agent", "agent_" + styleId(s))) }
            let style = cueSpeakers[i].map(styleId) ?? "text"
            var kids: [XMLElem] = []
            for (k, line) in c.lines.enumerated() {
                if k > 0 { kids.append(XMLElem("br")) }
                kids.append(XMLElem("span", [("style", style)], text: line))
            }
            return XMLElem("p", attrs, children: kids, inline: true)
        }
        let body = XMLElem("body", [("region", top ? "top" : "bottom")], children: [XMLElem("div", children: paragraphs)])
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        XMLElem("tt", root, children: [XMLElem("head", children: head), body]).write(&out, depth: 0)
        return out
    }

    /// "hh:mm:ss.mmm", the clock time every profile accepts.
    static func ttmlTime(_ ms: Int) -> String { subtitleTime(ms, ".") }

    /// Rules of `format` a document breaks, checked as far as they can be without the schemas: well-formed XML, the
    /// TTML namespaces, xml:lang, media time base, frame rate (TTML and IMSC), cell resolution, the profile
    /// designator (IMSC) or EBU-TT-D metadata, clock times with each cue ending after it begins and no earlier than the
    /// one before, style and region references that resolve, and text only inside spans (EBU-TT-D).
    public static func timedTextProblems(_ xml: String, format: TimedTextFormat) -> [String] {
        let doc: XMLDocument
        do { doc = try XMLDocument(xmlString: xml, options: []) } catch { return ["not well-formed XML: \(error.localizedDescription)"] }
        guard let tt = doc.rootElement(), tt.localName == "tt", tt.uri == TimedTextFormat.ttmlNS else { return ["root is not tt in \(TimedTextFormat.ttmlNS)"] }
        var out: [String] = []
        func attr(_ e: XMLElement, _ local: String, _ ns: String?) -> String? {
            if let ns { return e.attribute(forLocalName: local, uri: ns)?.stringValue }
            return e.attribute(forName: local)?.stringValue
        }
        let xmlNS = "http://www.w3.org/XML/1998/namespace"
        if (attr(tt, "lang", xmlNS) ?? "").isEmpty { out.append("tt has no xml:lang") }
        if attr(tt, "timeBase", TimedTextFormat.parameterNS) != "media" { out.append("ttp:timeBase is not media") }
        if let cells = attr(tt, "cellResolution", TimedTextFormat.parameterNS) {
            let parts = cells.split(separator: " ").compactMap { Int($0) }
            if parts.count != 2 || parts.contains(where: { $0 <= 0 }) { out.append("ttp:cellResolution \(cells) is not two positive integers") }
        } else {
            out.append("no ttp:cellResolution")
        }
        switch format {
        case .ttml, .imsc:
            guard let rate = attr(tt, "frameRate", TimedTextFormat.parameterNS), let n = Int(rate), n > 0 else { out.append("no positive integer ttp:frameRate"); break }
            if let m = attr(tt, "frameRateMultiplier", TimedTextFormat.parameterNS), m.split(separator: " ").compactMap({ Int($0) }).count != 2 { out.append("ttp:frameRateMultiplier \(m) is not two integers") }
            if format == .imsc, attr(tt, "contentProfiles", TimedTextFormat.parameterNS) != TimedTextFormat.imscProfile { out.append("no IMSC 1.1 text ttp:contentProfiles") }
        case .ebuttd:
            if tt.attribute(forLocalName: "frameRate", uri: TimedTextFormat.parameterNS) != nil { out.append("EBU-TT-D has no ttp:frameRate") }
            let standards = (try? doc.nodes(forXPath: "//*[local-name()='conformsToStandard']").compactMap(\.stringValue)) ?? []
            if !standards.contains(where: { $0.hasPrefix("urn:ebu:tt:distribution") }) { out.append("no ebuttm:conformsToStandard for EBU-TT-D") }
        }
        func all(_ name: String) -> [XMLElement] {
            ((try? doc.nodes(forXPath: "//*[local-name()='\(name)']")) ?? []).compactMap { $0 as? XMLElement }.filter { $0.uri == TimedTextFormat.ttmlNS }
        }
        let styleIds = Set(all("style").compactMap { attr($0, "id", xmlNS) })
        let regionIds = Set(all("region").compactMap { attr($0, "id", xmlNS) })
        for e in all("p") + all("span") + all("body") + all("div") {
            for s in (attr(e, "style", nil) ?? "").split(separator: " ") where !styleIds.contains(String(s)) { out.append("\(e.localName ?? "") refers to missing style \(s)") }
            if let r = attr(e, "region", nil), !regionIds.contains(r) { out.append("\(e.localName ?? "") refers to missing region \(r)") }
        }
        for r in all("region") {
            for key in ["origin", "extent"] {
                guard let v = attr(r, key, TimedTextFormat.stylingNS) else { continue }
                let parts = v.split(separator: " ")
                if parts.count != 2 || !parts.allSatisfy({ $0.hasSuffix("%") && Double($0.dropLast()).map { (0...100).contains($0) } == true }) { out.append("region tts:\(key) \(v) is not two percentages") }
            }
        }
        func seconds(_ s: String) -> Double? {
            let parts = s.split(separator: ":")
            guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]), parts[0].count >= 2, parts[1].count == 2 else { return nil }
            return h * 3600 + m * 60 + sec
        }
        var last = -Double.infinity
        for p in all("p") {
            guard let b = attr(p, "begin", nil).flatMap(seconds), let e = attr(p, "end", nil).flatMap(seconds) else { out.append("p \(attr(p, "id", xmlNS) ?? "") lacks clock-time begin and end"); continue }
            if e <= b { out.append("p \(attr(p, "id", xmlNS) ?? "") ends before it begins") }
            if b < last { out.append("p \(attr(p, "id", xmlNS) ?? "") begins before the one before it") }
            last = b
            if format == .ebuttd, (p.children ?? []).contains(where: { $0.kind == .text && !($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                out.append("EBU-TT-D p \(attr(p, "id", xmlNS) ?? "") has text outside a span")
            }
        }
        return out
    }
}
