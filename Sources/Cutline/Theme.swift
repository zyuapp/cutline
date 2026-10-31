import AppKit
import SwiftUI

/// A dark room lit by the picture. Controls float above it on Liquid Glass, so the
/// current frame tints every panel. Two voices, two colors: wax for the human's notes,
/// periwinkle for everything Claude does.
enum Theme {
    static let room = Color(nsColor: .windowBackgroundColor)
    static let desk = Color(nsColor: NS.desk)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let raised = Color(nsColor: .quaternaryLabelColor)
    static let field = Color(nsColor: .quaternarySystemFill)
    static let rule = Color(nsColor: .separatorColor)
    static let ink = Color(nsColor: .labelColor)
    static let ink2 = Color(nsColor: .secondaryLabelColor)
    static let ink3 = Color(nsColor: NS.ink3)
    /// Text that has been dealt with: resolved notes and their replies.
    static let settled = Color(nsColor: .secondaryLabelColor)
    static let wax = Color(nsColor: NS.wax)
    static let claude = Color(nsColor: NS.claude)
    /// Fill for prominent buttons that act through Claude, dark enough for a white label.
    static let claudeFill = Color(hex: 0x4D58B0)
    static let tally = Color(nsColor: .systemRed)
    /// The selected segment of a segmented control: neutral, dark enough for its white label.
    static let segment = Color(nsColor: .adaptive(dark: 0x48484D, light: 0x6E6E73, darkContrast: 0x2C2C2E, lightContrast: 0x3A3A3C))

    /// Space between the window edge and inset content.
    static let paneInset: CGFloat = 8

    enum NS {
        /// Labels on ink and wax fills, such as the play button and the note button.
        static let desk = NSColor.adaptive(dark: 0x111215, light: 0xFFFFFF, darkContrast: 0x000000, lightContrast: 0xFFFFFF)
        static let lane = NSColor(name: nil) { a in
            switch a.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]) {
            case .darkAqua: NSColor.white.withAlphaComponent(0.05)
            case .accessibilityHighContrastDarkAqua: NSColor.white.withAlphaComponent(0.1)
            case .accessibilityHighContrastAqua: NSColor.black.withAlphaComponent(0.08)
            default: NSColor.black.withAlphaComponent(0.04)
            }
        }
        static let rule = NSColor.separatorColor
        static let ink = NSColor.labelColor
        static let ink2 = NSColor.secondaryLabelColor
        static let ink3 = NSColor(name: nil) { a in
            let contrast = a.name.rawValue.contains("HighContrast")
            return NSColor.labelColor.withAlphaComponent(contrast ? 0.62 : 0.44)
        }
        static let numeral = ink3
        static let wax = NSColor.adaptive(dark: 0xF7CE5B, light: 0xA87800, darkContrast: 0xFFDF80, lightContrast: 0x7A5600)
        static let claude = NSColor.adaptive(dark: 0xAEB6E6, light: 0x4D58B0, darkContrast: 0xCAD0F2, lightContrast: 0x313B88)
        static let overlay = NSColor.adaptive(dark: 0x6F7F9C, light: 0x5A6A88, darkContrast: 0x8496B6, lightContrast: 0x46557A)
        static let video = NSColor.adaptive(dark: 0x3F6EB5, light: 0x3366B0, darkContrast: 0x5A8AD6, lightContrast: 0x22508F)
        static let audio = NSColor.adaptive(dark: 0x2F8F7A, light: 0x2A8370, darkContrast: 0x45AE96, lightContrast: 0x1C6656)
        static let wave = NSColor.adaptive(dark: 0x8FE0CB, light: 0x2E8C76, darkContrast: 0xB0F0DF, lightContrast: 0x1F6B59)
        static let title = NSColor.adaptive(dark: 0x9A7D57, light: 0x8A6C45, darkContrast: 0xB8976B, lightContrast: 0x6B522F)
        static let caption = NSColor.adaptive(dark: 0x7E77C0, light: 0x6A62B0, darkContrast: 0x9C95DC, lightContrast: 0x4E4796)
        static let solid = NSColor.adaptive(dark: 0x6B6F78, light: 0x6B6F78, darkContrast: 0x8A8E97, lightContrast: 0x4E525A)
        static let adjustment = NSColor.adaptive(dark: 0x8E9AB8, light: 0x6E7A98, darkContrast: 0xABB6D2, lightContrast: 0x525D7A)
        /// Fills behind a note's text on the frame and the timeline.
        static let humanBubble = NSColor.adaptive(dark: 0x29261E, light: 0xFFF6DD, darkContrast: 0x1C1A14, lightContrast: 0xFFFFFF)
        static let claudeBubble = NSColor.adaptive(dark: 0x22242E, light: 0xEEF0FF, darkContrast: 0x16171E, lightContrast: 0xFFFFFF)
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

/// San Francisco throughout; hierarchy comes from size, weight and color.
enum Typeface {
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func text(_ s: String, _ size: CGFloat, _ weight: Font.Weight = .regular) -> Text {
        Text(s).font(font(size, weight))
    }

    static func attributed(_ s: String, _ attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        NSAttributedString(string: s, attributes: attrs)
    }

    static func ns(_ size: CGFloat, _ weight: NSFont.Weight = .regular, tabular: Bool = false) -> NSFont {
        tabular ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
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

    /// A color with light and dark variants, each with an Increase Contrast variant.
    static func adaptive(dark: UInt32, light: UInt32, darkContrast: UInt32? = nil, lightContrast: UInt32? = nil) -> NSColor {
        NSColor(name: nil) { a in
            switch a.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]) {
            case .accessibilityHighContrastDarkAqua: NSColor(hex: darkContrast ?? dark)
            case .accessibilityHighContrastAqua: NSColor(hex: lightContrast ?? light)
            case .darkAqua: NSColor(hex: dark)
            default: NSColor(hex: light)
            }
        }
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

/// Text buttons: borderless by default, system glass when bordered, prominent glass in ink.
/// Inside glass panels use `.bordered` styles instead, so glass never sits on glass.
struct QuietButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    var bordered = false

    func makeBody(configuration: Configuration) -> some View {
        let button = Button(role: configuration.role, action: configuration.trigger) { configuration.label }
            .buttonBorderShape(.capsule)
        if prominent {
            button.buttonStyle(.glassProminent).tint(Theme.ink).foregroundStyle(Theme.desk)
        } else if bordered {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.borderless)
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
