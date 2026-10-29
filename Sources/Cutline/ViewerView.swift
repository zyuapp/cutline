import AVFoundation
import AppKit
import CutlineCore
import SwiftUI

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        v.layer = layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVPlayerLayer)?.player = player
    }
}

/// Light from the picture spilling into the room: a softened copy of the current frame,
/// scaled up behind the picture and faded out at the edges.
struct AmbientGlow: NSViewRepresentable {
    let image: CGImage?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let glow = CALayer()
        glow.contentsGravity = .resize
        glow.magnificationFilter = .linear
        glow.opacity = 0.34
        let mask = CAGradientLayer()
        mask.type = .radial
        mask.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.55).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        mask.locations = [0, 0.45, 1]
        mask.startPoint = CGPoint(x: 0.5, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 1)
        glow.mask = mask
        v.layer?.addSublayer(glow)
        context.coordinator.glow = glow
        context.coordinator.mask = mask
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let glow = context.coordinator.glow else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = v.bounds
        context.coordinator.mask?.frame = v.bounds
        CATransaction.commit()
        guard glow.contents as! CGImage? !== image else { return }
        CATransaction.begin()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.setDisableActions(reduceMotion)
        CATransaction.setAnimationDuration(0.6)
        glow.contents = image
        CATransaction.commit()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var glow: CALayer?
        var mask: CAGradientLayer?
    }
}

/// The picture, fitted to the canvas, with notes marked where they were pinned.
struct ViewerView: View {
    let doc: ProjectDocument
    @Binding var pinning: Bool
    @Binding var draft: DraftNote?
    var selected: String?

    var body: some View {
        GeometryReader { geo in
            let canvas = CGSize(width: doc.project.canvas.width, height: doc.project.canvas.height)
            let frame = fit(canvas, in: geo.size)
            ZStack(alignment: .topLeading) {
                PlayerLayerView(player: doc.player.player)
                    .frame(width: frame.width, height: frame.height)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(pinning ? Theme.wax.opacity(0.85) : Color.white.opacity(0.07), lineWidth: pinning ? 1.5 : 0.5)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 14)
                    .background(GeometryReader { p in
                        Color.clear.preference(key: PictureFrameKey.self, value: p.frame(in: .named("stage")))
                    })
                    .position(x: frame.midX, y: frame.midY)
                ForEach(visibleNotes) { c in
                    if let x = c.x, let y = c.y {
                        NoteMark(text: c.id == selected ? c.text : nil, meta: Theme.compact(c.time, fps: doc.project.canvas.fps), human: c.author == .human, emphasized: c.id == selected, flip: x > 0.62)
                            .position(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
                    }
                }
                if let d = draft, let x = d.x, let y = d.y {
                    NoteMark(text: nil, human: true, emphasized: true)
                        .position(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
                }
                if pinning {
                    Color.clear
                        .frame(width: frame.width, height: frame.height)
                        .contentShape(Rectangle())
                        .position(x: frame.midX, y: frame.midY)
                        .onTapGesture(coordinateSpace: .local) { p in
                            draft = DraftNote(time: doc.player.time, x: min(max((p.x - frame.minX) / frame.width, 0), 1), y: min(max((p.y - frame.minY) / frame.height, 0), 1))
                            pinning = false
                        }
                        .onContinuousHover { phase in
                            if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                        }
                    HStack(spacing: 10) {
                        Text("Click where the note applies")
                            .foregroundStyle(Theme.ink)
                        Text("Return for the whole frame")
                            .foregroundStyle(Theme.ink2)
                    }
                    .font(Typeface.font(13, .medium))
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .glassEffect(.regular, in: Capsule())
                    .position(x: frame.midX, y: frame.minY + 32)
                    .allowsHitTesting(false)
                }
                if let err = doc.buildError {
                    Text(err)
                        .font(Typeface.font(13))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .glassEffect(.regular.tint(Theme.tally.opacity(0.25)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .position(x: frame.midX, y: frame.maxY - 36)
                }
            }
        }
    }

    private var visibleNotes: [Comment] {
        doc.comments.filter { $0.status == .open && abs($0.time - doc.player.time) < 0.6 || $0.id == selected }
    }

    private func fit(_ size: CGSize, in box: CGSize) -> CGRect {
        let s = min(box.width / max(size.width, 1), box.height / max(size.height, 1))
        let w = (size.width * s).rounded(), h = (size.height * s).rounded()
        return CGRect(x: ((box.width - w) / 2).rounded(), y: ((box.height - h) / 2).rounded(), width: w, height: h)
    }
}

struct DraftNote: Equatable {
    var time: Double
    var x: Double?
    var y: Double?
}

/// A loose wax-pencil circle, like a mark on a print, with the note above it when selected.
struct NoteMark: View {
    var text: String?
    var meta = ""
    var human: Bool
    var emphasized: Bool
    /// Hang the note to the left of the mark, for marks near the right edge.
    var flip = false

    private func textWidth(_ s: String) -> CGFloat {
        let w = NSAttributedString(string: s, attributes: [.font: Typeface.ns(12.5)]).size().width
        return min(236, ceil(w) + 2)
    }

    var body: some View {
        let color = human ? Theme.wax : Theme.claude
        PencilCircle()
            .stroke(color, style: StrokeStyle(lineWidth: emphasized ? 2.6 : 2, lineCap: .round))
            .frame(width: 48, height: 43)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            .overlay(alignment: flip ? .bottomTrailing : .bottomLeading) {
                if let text {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(human ? "You" : "Claude").font(Typeface.font(11.5, .semibold))
                            Text(meta).font(Typeface.font(11.5).monospacedDigit()).opacity(0.75)
                        }
                        .foregroundStyle(color)
                        Typeface.text(text, 12.5)
                            .foregroundStyle(Theme.ink.opacity(0.94))
                            .lineSpacing(2.5)
                            .lineLimit(3)
                            .frame(width: textWidth(text), alignment: .leading)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(
                        BubbleShape(trailing: flip)
                            .fill(Color(hex: human ? 0x29261E : 0x22242E).opacity(0.96))
                            .overlay(BubbleShape(trailing: flip).stroke(color.opacity(0.38), lineWidth: 1))
                            .shadow(color: .black.opacity(0.4), radius: 12, y: 8)
                    )
                    .offset(x: flip ? -30 : 30, y: -46)
                }
            }
            .allowsHitTesting(false)
    }
}

/// A rounded box with a short tail at a lower corner, pointing at the mark.
struct BubbleShape: Shape {
    var trailing = false

    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: 11, style: .continuous)
        if trailing {
            p.move(to: CGPoint(x: rect.maxX - 12, y: rect.maxY - 1))
            p.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY + 8))
            p.addLine(to: CGPoint(x: rect.maxX - 24, y: rect.maxY - 1))
        } else {
            p.move(to: CGPoint(x: rect.minX + 12, y: rect.maxY - 1))
            p.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY + 8))
            p.addLine(to: CGPoint(x: rect.minX + 24, y: rect.maxY - 1))
        }
        p.closeSubpath()
        return p
    }
}

struct PencilCircle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let steps = 48
        for i in 0...steps + 6 {
            let a = Double(i) / Double(steps) * 2 * .pi - 0.6
            let wobble = 1 + 0.035 * sin(a * 3) + Double(i) / Double(steps) * 0.07
            let pt = CGPoint(x: c.x + cos(a) * rect.width / 2 * wobble, y: c.y + sin(a) * rect.height / 2 * wobble)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}
