import AppKit
import CoreText
import SwiftUI

/// A screening room: graphite surfaces that step down from the stage to the desk, so the
/// picture is the brightest thing on screen. Two voices, two colors: wax for the human's
/// notes, periwinkle for everything Claude does.
enum Theme {
    static let room = Color(hex: 0x1B1C1F)
    static let desk = Color(hex: 0x141517)
    static let panel = Color(hex: 0x1E1F22)
    static let raised = Color(hex: 0x292A2E)
    static let field = Color(hex: 0x151619)
    static let rule = Color(hex: 0x2C2D32)
    static let ink = Color(hex: 0xEEEDE9)
    static let ink2 = Color(hex: 0xA6A6A1)
    static let ink3 = Color(hex: 0x8F9094)
    /// Text that has been dealt with: resolved notes and their replies.
    static let settled = Color(hex: 0x9D9D99)
    static let wax = Color(hex: 0xF0CF6E)
    static let claude = Color(hex: 0xA9B4F5)
    static let tally = Color(hex: 0xE5493A)

    enum NS {
        static let room = NSColor(hex: 0x1B1C1F)
        static let desk = NSColor(hex: 0x141517)
        static let lane = NSColor(hex: 0x1A1B1E)
        static let rule = NSColor(hex: 0x2C2D32)
        static let ink = NSColor(hex: 0xEEEDE9)
        static let ink2 = NSColor(hex: 0xA6A6A1)
        static let ink3 = NSColor(hex: 0x8F9094)
        static let numeral = NSColor(hex: 0x8E8F93)
        static let overlay = NSColor(hex: 0x7F8A99)
        static let wax = NSColor(hex: 0xF0CF6E)
        static let claude = NSColor(hex: 0xA9B4F5)
        static let video = NSColor(hex: 0x4D678A)
        static let audio = NSColor(hex: 0x4C8A7C)
        static let wave = NSColor(hex: 0x8FC6B8)
        static let title = NSColor(hex: 0x8C8478)
        static let caption = NSColor(hex: 0x7E77A0)
        static let solid = NSColor(hex: 0x6B6F78)
    }

    static func timecode(_ t: Double, fps: Double) -> String {
        let t = max(0, t)
        let total = Int(t)
        let frames = Int(((t - Double(total)) * fps).rounded(.down))
        return String(format: "%02d:%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60, frames)
    }

    /// Minutes, seconds and frames, e.g. "0:17:11", for notes and buttons.
    static func compact(_ t: Double, fps: Double) -> String {
        let t = max(0, t)
        let total = Int(t)
        let frames = Int(((t - Double(total)) * fps).rounded(.down))
        return String(format: "%d:%02d:%02d", total / 60, total % 60, frames)
    }

    static func short(_ t: Double) -> String {
        let m = Int(t) / 60
        return String(format: "%d:%04.1f", m, t - Double(m * 60))
    }
}

/// One grotesque for everything; hierarchy comes from size, weight and color.
enum Typeface {
    static let family = "Host Grotesk"

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(family, size: size).weight(weight)
    }

    /// Host Grotesk's hyphen is half an em long; hyphens are drawn from the system font so
    /// names like "b-roll" read naturally.
    static func text(_ s: String, _ size: CGFloat, _ weight: Font.Weight = .regular) -> Text {
        var a = AttributedString(s)
        a.font = font(size, weight)
        var i = a.startIndex
        while i < a.endIndex {
            let next = a.index(afterCharacter: i)
            if a.characters[i] == "-" { a[i..<next].font = .system(size: size, weight: weight) }
            i = next
        }
        return Text(a)
    }

    static func attributed(_ s: String, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let out = NSMutableAttributedString(string: s, attributes: attrs)
        guard let f = attrs[.font] as? NSFont else { return out }
        let weight = (f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        let system = NSFont.systemFont(ofSize: f.pointSize, weight: NSFont.Weight(weight))
        for (i, ch) in s.utf16.enumerated() where ch == 0x2D {
            out.addAttribute(.font, value: system, range: NSRange(location: i, length: 1))
        }
        return out
    }

    static func ns(_ size: CGFloat, _ weight: NSFont.Weight = .regular, tabular: Bool = false) -> NSFont {
        let d = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
        var f = NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size, weight: weight)
        if tabular {
            let t = f.fontDescriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]]])
            f = NSFont(descriptor: t, size: size) ?? f
        }
        return f
    }

    /// Registers the bundled fonts for this process. Looks in the app bundle first, then
    /// next to the executable for SwiftPM development builds.
    static func register() {
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            exeDir?.appendingPathComponent("Cutline_Cutline.bundle/Contents/Resources/Fonts"),
            exeDir?.appendingPathComponent("Cutline_Cutline.bundle/Fonts"),
        ]
        guard let dir = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }

    /// "lake-tahoe" reads as "Lake Tahoe".
    var humanized: String {
        replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// The note mark from the frame, small enough to use as an icon.
struct PencilMarkIcon: View {
    var color: Color
    var size: CGFloat = 13

    var body: some View {
        PencilCircle()
            .stroke(color, style: StrokeStyle(lineWidth: max(1.3, size / 9), lineCap: .round))
            .frame(width: size, height: size * 0.9)
    }
}

/// A 16 pt monogram that says who is speaking.
struct Monogram: View {
    let human: Bool

    var body: some View {
        Text(human ? "Y" : "C")
            .font(Typeface.font(9.5, .semibold))
            .foregroundStyle(Theme.desk)
            .frame(width: 16, height: 16)
            .background(Circle().fill(human ? Theme.wax : Theme.claude))
    }
}

/// Text buttons: quiet by default, a solid ink fill when prominent.
struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    var bordered = false

    func makeBody(configuration: Configuration) -> some View {
        QuietLabel(configuration: configuration, prominent: prominent, bordered: bordered)
    }

    private struct QuietLabel: View {
        let configuration: ButtonStyle.Configuration
        let prominent: Bool
        let bordered: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(Typeface.font(13, .medium))
                .foregroundStyle(prominent ? Theme.desk : Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(prominent
                            ? Theme.ink.opacity(configuration.isPressed ? 0.82 : 1)
                            : Theme.ink.opacity(configuration.isPressed ? 0.12 : hovering ? 0.07 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(bordered && !prominent ? 0.13 : 0), lineWidth: 1)
                )
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Reports the on-screen frame of the picture so the stage can light the room around it.
struct PictureFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
