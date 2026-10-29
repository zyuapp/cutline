import AppKit
import CutlineCore
import SwiftUI

struct TimelineTrackView: NSViewRepresentable {
    let doc: ProjectDocument
    var selectedComment: String?
    var onSelectComment: (String) -> Void

    func makeNSView(context: Context) -> TimelineCanvas {
        let v = TimelineCanvas()
        v.onSeek = { [weak doc] t in
            doc?.player.pause()
            doc?.player.seek(t)
        }
        v.onSelectComment = onSelectComment
        return v
    }

    func updateNSView(_ v: TimelineCanvas, context: Context) {
        v.onSelectComment = onSelectComment
        v.update(project: doc.project, captions: doc.laneCaptions, transcripts: doc.transcripts, comments: doc.comments, audio: doc.audio, thumbnails: doc.thumbnails, revision: doc.thumbnails.revision, selected: selectedComment, changed: doc.changedClips, changedAt: doc.changedAt)
        v.setPlayhead(doc.player.time, playing: doc.player.isPlaying)
    }

    /// Height that fits every lane, matching `TimelineCanvas.lanes()`.
    static func idealHeight(_ p: Project, hasNotes: Bool) -> CGFloat {
        var h = TimelineCanvas.rulerHeight + TimelineCanvas.lanesTop + 14
        for lane in TimelineCanvas.laneKinds(p, hasNotes: hasNotes) { h += lane.height + TimelineCanvas.laneGap }
        return h
    }
}

/// Draws tracks, filmstrips, waveforms, captions and notes; scrubs on drag.
final class TimelineCanvas: NSView {
    var onSeek: ((Double) -> Void)?
    var onSelectComment: ((String) -> Void)?

    static let rulerHeight: CGFloat = 34
    static let lanesTop: CGFloat = 8
    static let laneGap: CGFloat = 4

    private var project = Project(name: "")
    private var captions: [CaptionSegment] = []
    private var transcripts: [String: Transcript] = [:]
    private var comments: [Comment] = []
    private var audio: [String: AudioAnalysis] = [:]
    private weak var thumbnails: Thumbnails?
    private var revision = -1
    private var selected: String?
    private var changed: Set<String> = []
    private var changedAt: Date?
    private var glowTimer: Timer?

    private var viewStart: Double = 0
    private var pxPerSec: Double = 40
    private var fitted = false
    private var lastDuration: Double = 0
    private var playhead: Double = 0
    private var scrubbing = false
    private var hoverX: CGFloat?
    private var hoverY: CGFloat = 0

    private let headerW: CGFloat = 132
    private var rulerH: CGFloat { Self.rulerHeight }
    private let glowDuration = 1.6
    private let playheadLayer = CALayer()
    private let playheadHead = CAShapeLayer()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.NS.desk.cgColor
        playheadLayer.backgroundColor = Theme.NS.ink.cgColor
        playheadLayer.zPosition = 10
        playheadHead.fillColor = Theme.NS.ink.cgColor
        playheadHead.shadowColor = NSColor.black.cgColor
        playheadHead.shadowOpacity = 0.6
        playheadHead.shadowRadius = 3
        playheadHead.shadowOffset = .zero
        playheadHead.zPosition = 11
        let p = CGMutablePath()
        p.addRoundedRect(in: CGRect(x: -5.5, y: -1, width: 11, height: 12), cornerWidth: 3, cornerHeight: 3)
        p.move(to: CGPoint(x: -5.5, y: 1))
        p.addLine(to: CGPoint(x: 5.5, y: 1))
        p.addLine(to: CGPoint(x: 0.6, y: -5))
        p.addLine(to: CGPoint(x: -0.6, y: -5))
        p.closeSubpath()
        playheadHead.path = p
        layer?.addSublayer(playheadLayer)
        layer?.addSublayer(playheadHead)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    func update(project: Project, captions: [CaptionSegment], transcripts: [String: Transcript], comments: [Comment], audio: [String: AudioAnalysis], thumbnails: Thumbnails, revision: Int, selected: String?, changed: Set<String>, changedAt: Date?) {
        let dirty = project != self.project || captions != self.captions || comments != self.comments || revision != self.revision || selected != self.selected || audio.count != self.audio.count || transcripts.count != self.transcripts.count
        self.project = project
        self.captions = captions
        self.transcripts = transcripts
        self.comments = comments
        self.audio = audio
        self.thumbnails = thumbnails
        self.revision = revision
        self.selected = selected
        if changedAt != self.changedAt {
            self.changed = changed
            self.changedAt = changedAt
            startGlow()
        }
        let d = project.duration
        if !fitted || (d > lastDuration * 1.05 && viewEnd < d) {
            fit()
        }
        lastDuration = d
        if dirty { needsDisplay = true }
    }

    private func startGlow() {
        glowTimer?.invalidate()
        guard changedAt != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        glowTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.needsDisplay = true
            if Date().timeIntervalSince(self.changedAt ?? .distantPast) > self.glowDuration { t.invalidate() }
        }
    }

    override func layout() {
        super.layout()
        if !fitted || viewEnd - viewStart > max(project.duration, 1) * 1.02 { fit() }
        positionPlayhead()
    }

    private func fit() {
        let d = max(project.duration, 5)
        let w = bounds.width - originX - 24
        guard w > 50 else { return }
        pxPerSec = w / d
        viewStart = 0
        fitted = true
        needsDisplay = true
    }

    private var viewEnd: Double { viewStart + Double(bounds.width - originX) / pxPerSec }

    func setPlayhead(_ t: Double, playing: Bool) {
        playhead = t
        if !scrubbing {
            let x = xFor(t)
            let span = Double(bounds.width - originX) / pxPerSec
            if x > bounds.width - 40 || x < headerW {
                viewStart = clampedStart(playing ? t - span * 0.1 : t - span / 2)
                needsDisplay = true
            }
        }
        positionPlayhead()
    }

    private func clampedStart(_ start: Double) -> Double {
        let span = Double(bounds.width - originX) / pxPerSec
        return min(max(0, start), max(0, project.duration - span * 0.9))
    }

    private func positionPlayhead() {
        let x = xFor(playhead).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let visible = x >= headerW - 1 && x <= bounds.width
        playheadLayer.isHidden = !visible
        playheadHead.isHidden = !visible
        let flipped = layer?.isGeometryFlipped ?? false
        playheadLayer.frame = CGRect(x: x - 0.5, y: flipped ? rulerH - 10 : 0, width: 1, height: bounds.height - rulerH + 10)
        playheadHead.position = CGPoint(x: x, y: flipped ? 12 : bounds.height - 12)
        playheadHead.transform = flipped ? CATransform3DMakeScale(1, -1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }

    /// Where time zero sits when scrolled to the start; leaves room for the lane's rounded edge.
    private var originX: CGFloat { headerW + 14 }
    private func xFor(_ t: Double) -> CGFloat { originX + CGFloat((t - viewStart) * pxPerSec) }
    private func timeFor(_ x: CGFloat) -> Double { viewStart + Double(x - originX) / pxPerSec }

    // MARK: Lanes

    enum LaneKind {
        case notes
        case titles(Track)
        case overlay(Track)
        case main(Track)
        case captions
        case audio(Track)

        var height: CGFloat {
            switch self {
            case .notes: 22
            case .titles: 30
            case .overlay: 40
            case .main: 54
            case .captions: 26
            case .audio: 40
            }
        }
    }

    private struct Lane {
        var kind: LaneKind
        var rect: CGRect
    }

    /// Top to bottom: notes, video layers (top layer first), captions, audio.
    static func laneKinds(_ p: Project, hasNotes: Bool) -> [LaneKind] {
        var out: [LaneKind] = hasNotes ? [.notes] : []
        let mainId = p.tracks.first { $0.kind == .video && $0.clips.contains { $0.kind == .media } }?.id
        for t in p.tracks.reversed() where t.kind == .video {
            let titlesOnly = !t.clips.isEmpty && t.clips.allSatisfy { $0.kind != .media }
            out.append(t.id == mainId ? .main(t) : titlesOnly ? .titles(t) : .overlay(t))
        }
        if p.captions.enabled { out.append(.captions) }
        for t in p.tracks where t.kind == .audio { out.append(.audio(t)) }
        return out
    }

    private func lanes() -> [Lane] {
        let kinds = Self.laneKinds(project, hasNotes: !comments.isEmpty)
        let total = kinds.map(\.height).reduce(0, +) + CGFloat(kinds.count) * Self.laneGap
        let available = bounds.height - rulerH - Self.lanesTop - 8
        let scale = total > available ? max(0.5, available / total) : 1
        var y = rulerH + Self.lanesTop
        return kinds.map { k in
            let h = (k.height * scale).rounded()
            defer { y += h + Self.laneGap }
            return Lane(kind: k, rect: CGRect(x: 0, y: y, width: bounds.width, height: h))
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Theme.NS.desk.setFill()
        bounds.fill()
        let all = lanes()
        let glow = glowAlpha()
        ctx.saveGState()
        ctx.clip(to: CGRect(x: headerW, y: 0, width: bounds.width - headerW, height: bounds.height))
        let laneStart = xFor(0) - 6
        let laneEnd = min(bounds.width - 6, xFor(project.duration) + 6)
        for lane in all where laneEnd > laneStart {
            Theme.NS.lane.setFill()
            NSBezierPath(roundedRect: CGRect(x: laneStart, y: lane.rect.minY, width: laneEnd - laneStart, height: lane.rect.height), xRadius: 7, yRadius: 7).fill()
        }
        let firstClipLane = all.first { if case .notes = $0.kind { return false }; return true }?.rect.minY ?? rulerH
        let bottom = all.last?.rect.maxY ?? rulerH
        drawNoteLines(top: firstClipLane, bottom: bottom)
        for lane in all {
            switch lane.kind {
            case .notes: drawNotePins(lane.rect)
            case .captions: drawCaptions(lane.rect)
            case .titles(let t), .overlay(let t), .main(let t), .audio(let t): drawClips(t, kind: lane.kind, in: lane.rect, ctx: ctx, glow: glow)
            }
        }
        drawHover(top: rulerH - 10, bottom: bottom)
        ctx.restoreGState()
        drawRuler()
        drawHeaders(all)
        drawNoteBubble()
    }

    private func glowAlpha() -> CGFloat {
        guard let at = changedAt else { return 0 }
        let age = Date().timeIntervalSince(at)
        guard age < glowDuration else { return 0 }
        return CGFloat(1 - Easing.easeIn.apply(age / glowDuration))
    }

    /// Three bands: time labels, a strip for markers, and ticks.
    private func drawRuler() {
        Theme.NS.desk.setFill()
        CGRect(x: headerW, y: 0, width: bounds.width - headerW, height: rulerH).fill()
        let tickTop: CGFloat = rulerH - 7
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let step = steps.first { $0 * pxPerSec >= 84 } ?? 600
        let minor = step / (step == 15 ? 3 : step >= 10 ? 5 : 4)
        let labelFont = Typeface.ns(11, .regular, tabular: true)
        let end = project.duration
        var t = max(0, (viewStart / minor).rounded(.down) * minor)
        while t <= min(viewEnd + minor, end + minor / 10) {
            let x = xFor(t).rounded()
            if x >= headerW {
                let major = abs((t / step).rounded() * step - t) < minor / 10
                (major ? Theme.NS.numeral.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.16)).setFill()
                CGRect(x: x - 0.25, y: major ? tickTop : rulerH - 3, width: 0.5, height: major ? 7 : 3).fill()
                if major, x < xFor(end) - 20 || abs(t - end) < minor / 10 {
                    let label = step < 1 ? String(format: "%.1f", t) : Theme.short(t).replacingOccurrences(of: ".0", with: "")
                    NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: Theme.NS.numeral]).draw(at: CGPoint(x: x + 4, y: 2))
                }
            }
            t += minor
        }
        let endX = xFor(end).rounded()
        if endX > headerW, endX < bounds.width {
            Theme.NS.ink3.setFill()
            CGRect(x: endX - 0.5, y: tickTop - 4, width: 1, height: rulerH - tickTop + 4).fill()
        }
        for m in project.markers {
            let x = xFor(m.time).rounded()
            guard x >= headerW, x <= bounds.width else { continue }
            let s = Typeface.attributed(m.label, [.font: Typeface.ns(10.5, .medium), .foregroundColor: Theme.NS.ink])
            let size = s.size()
            let flag = CGRect(x: x, y: 15, width: size.width + 11, height: 13)
            Theme.NS.ink3.withAlphaComponent(0.32).setFill()
            NSBezierPath(roundedRect: flag, xRadius: 3, yRadius: 3).fill()
            Theme.NS.ink2.setFill()
            CGRect(x: x, y: 15, width: 1.5, height: rulerH - 15).fill()
            s.draw(at: CGPoint(x: x + 5.5, y: flag.midY - size.height / 2))
        }
        if let hx = hoverX, !scrubbing, hx >= headerW {
            let label = Theme.timecode(timeFor(hx), fps: project.canvas.fps)
            let s = NSAttributedString(string: label, attributes: [.font: Typeface.ns(11, .medium, tabular: true), .foregroundColor: Theme.NS.desk])
            let size = s.size()
            let pill = CGRect(x: min(max(hx - size.width / 2 - 7, headerW + 2), bounds.width - size.width - 16), y: 0, width: size.width + 14, height: 16)
            Theme.NS.ink2.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
            s.draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 1))
        }
    }

    private func noteColor(_ c: Comment) -> NSColor {
        if c.status == .resolved { return Theme.NS.ink3 }
        return c.author == .human ? Theme.NS.wax : Theme.NS.claude
    }

    private func drawHeaders(_ all: [Lane]) {
        Theme.NS.desk.setFill()
        CGRect(x: 0, y: 0, width: headerW, height: bounds.height).fill()
        let nameAttr: [NSAttributedString.Key: Any] = [.font: Typeface.ns(12.5, .medium), .foregroundColor: Theme.NS.ink2]
        let detailAttr: [NSAttributedString.Key: Any] = [.font: Typeface.ns(11, .regular), .foregroundColor: Theme.NS.ink3]
        for lane in all {
            var name: String
            var detail = ""
            var symbol: String
            switch lane.kind {
            case .notes:
                name = "Notes"
                symbol = "pencil.tip"
            case .captions:
                name = "Captions"
                symbol = "captions.bubble"
            case .audio(let t):
                name = t.name
                detail = t.muted ? "Muted" : t.id
                symbol = t.muted ? "speaker.slash" : "waveform"
            case .titles(let t), .overlay(let t), .main(let t):
                name = t.name
                detail = t.hidden ? "Hidden" : t.id
                if case .titles = lane.kind {
                    symbol = t.clips.allSatisfy { $0.kind == .adjustment } ? "slider.horizontal.3" : "textformat"
                } else { symbol = "film" }
                if t.hidden { symbol = "eye.slash" }
            }
            let iconX: CGFloat = 20
            if case .notes = lane.kind {
                let mark = NSBezierPath(ovalIn: CGRect(x: iconX + 1.5, y: lane.rect.midY - 5, width: 11, height: 10))
                Theme.NS.ink3.setStroke()
                mark.lineWidth = 1.3
                mark.stroke()
            } else if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10.5, weight: .medium)) {
                let tinted = img.tinted(Theme.NS.ink3)
                let s = tinted.size
                tinted.draw(in: CGRect(x: iconX + (14 - s.width) / 2, y: (lane.rect.midY - s.height / 2).rounded(), width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let line = NSMutableAttributedString(attributedString: Typeface.attributed(name, nameAttr))
            if !detail.isEmpty { line.append(NSAttributedString(string: "  " + detail, attributes: detailAttr)) }
            let size = line.size()
            var maxW = headerW - iconX - 22 - 8
            if case .audio(let t) = lane.kind, !t.muted, t.volume != 1 {
                let vol = NSAttributedString(string: String(format: "%.0f%%", t.volume * 100), attributes: [.font: Typeface.ns(11, .regular, tabular: true), .foregroundColor: Theme.NS.ink3])
                let vs = vol.size()
                vol.draw(at: CGPoint(x: headerW - 10 - vs.width, y: (lane.rect.midY - vs.height / 2).rounded()))
                maxW -= vs.width + 6
            }
            line.draw(with: CGRect(x: iconX + 22, y: (lane.rect.midY - size.height / 2).rounded(), width: maxW, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawClips(_ track: Track, kind: LaneKind, in lane: CGRect, ctx: CGContext, glow: CGFloat) {
        let isMain: Bool
        if case .main = kind { isMain = true } else { isMain = false }
        for clip in track.clips {
            let x0 = xFor(clip.start).rounded(), x1 = xFor(clip.end).rounded()
            guard x1 >= headerW, x0 <= bounds.width else { continue }
            let rect = CGRect(x: x0 + 1, y: lane.minY + 2, width: max(2, x1 - x0 - 2), height: lane.height - 4)
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            let media = clip.mediaId.flatMap(project.mediaAsset)
            let isPicture = clip.kind == .media && track.kind == .video && (media?.hasVideo ?? false)
            let base: NSColor = switch clip.kind {
            case .media: isPicture ? (isMain ? Theme.NS.video : Theme.NS.overlay) : Theme.NS.audio
            case .text: Theme.NS.title
            case .solid: clip.color.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) } ?? Theme.NS.solid
            case .adjustment: Theme.NS.adjustment
            case .sequence: Theme.NS.overlay
            }
            let dim: CGFloat = track.hidden || (track.muted && track.kind == .audio) ? 0.35 : 1
            ctx.saveGState()
            ctx.setAlpha(dim)
            path.addClip()
            switch clip.kind {
            case .media:
                if isPicture, let media {
                    if isMain {
                        base.withAlphaComponent(0.3).setFill()
                        rect.fill()
                        drawFilmstrip(clip, media: media, rect: rect, ctx: ctx, alpha: 1)
                        if media.hasAudio, let a = audio[media.id] {
                            drawScrim(rect, ctx: ctx)
                            drawWaveform(clip, analysis: a, rect: CGRect(x: rect.minX, y: rect.maxY - 11, width: rect.width, height: 8), color: NSColor.white.withAlphaComponent(0.42), gain: (track.muted ? 0 : track.volume) * clip.volume)
                        }
                    } else {
                        // Layers above the main picture: a tinted lane with faint frames, so the edit reads at a glance.
                        base.withAlphaComponent(0.2).setFill()
                        rect.fill()
                        drawFilmstrip(clip, media: media, rect: rect, ctx: ctx, alpha: 0.38)
                        base.setFill()
                        CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
                    }
                } else if let media {
                    base.withAlphaComponent(0.16).setFill()
                    rect.fill()
                    if let a = audio[media.id] {
                        let top: CGFloat = rect.height >= 30 ? 17 : 3
                        drawWaveform(clip, analysis: a, rect: CGRect(x: rect.minX, y: rect.minY + top, width: rect.width, height: rect.height - top - 3), color: Theme.NS.wave.withAlphaComponent(0.72), gain: (track.muted ? 0 : track.volume) * clip.volume)
                    }
                }
            case .text:
                base.withAlphaComponent(0.2).setFill()
                rect.fill()
                base.setFill()
                CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
            case .solid:
                base.withAlphaComponent(0.8).setFill()
                rect.fill()
            case .sequence:
                // Nested sequences read as a stack: tinted fill with thin layered bands.
                base.withAlphaComponent(0.22).setFill()
                rect.fill()
                base.withAlphaComponent(0.35).setFill()
                for i in 0..<3 {
                    CGRect(x: rect.minX + 4, y: rect.maxY - 6 - CGFloat(i) * 4, width: rect.width - 8, height: 1.5).fill()
                }
            case .adjustment:
                base.withAlphaComponent(0.14).setFill()
                rect.fill()
                // Diagonal hatching: this layer changes what is below it rather than adding a picture.
                base.withAlphaComponent(0.22).setStroke()
                let hatch = NSBezierPath()
                var hx = rect.minX - rect.height
                while hx < rect.maxX {
                    hatch.move(to: CGPoint(x: hx, y: rect.maxY))
                    hatch.line(to: CGPoint(x: hx + rect.height, y: rect.minY))
                    hx += 7
                }
                hatch.lineWidth = 1
                hatch.stroke()
            }
            drawFades(clip, rect: rect, ctx: ctx)
            if glow > 0, changed.contains(clip.id) {
                Theme.NS.claude.withAlphaComponent(0.2 * glow).setFill()
                rect.fill()
            }
            ctx.restoreGState()

            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 4.75, yRadius: 4.75)
            NSColor.white.withAlphaComponent(clip.kind == .text ? 0.06 : 0.1).setStroke()
            edge.lineWidth = 0.5
            edge.stroke()
            if glow > 0, changed.contains(clip.id) {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 10, color: Theme.NS.claude.withAlphaComponent(glow * 0.8).cgColor)
                Theme.NS.claude.withAlphaComponent(glow).setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                ring.lineWidth = 2
                ring.stroke()
                ctx.restoreGState()
            }
            drawLabel(clip, media: media, rect: rect, onPicture: isPicture && isMain, audioOnly: clip.kind == .media && !isPicture, dim: dim)
        }
        drawTransitions(track, in: lane, ctx: ctx, glow: glow)
    }

    /// Transitions sit over the cut as a crossed tab spanning their window.
    private func drawTransitions(_ track: Track, in lane: CGRect, ctx: CGContext, glow: CGFloat) {
        for w in project.transitionWindows where w.trackId == track.id {
            let x0 = xFor(w.start), x1 = xFor(w.end)
            guard x1 >= headerW, x0 <= bounds.width else { continue }
            let h = min(lane.height - 8, 22)
            let rect = CGRect(x: x0, y: lane.midY - h / 2, width: max(8, x1 - x0), height: h)
            let tab = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            Theme.NS.desk.withAlphaComponent(0.82).setFill()
            tab.fill()
            let lit = glow > 0 && ([w.transition.from, w.transition.to].contains { $0.map(changed.contains) ?? false })
            let ink = lit ? Theme.NS.claude : Theme.NS.ink2
            ink.withAlphaComponent(0.9).setStroke()
            tab.lineWidth = 1
            tab.stroke()
            let cross = NSBezierPath()
            let inset = rect.insetBy(dx: 3, dy: 4)
            if w.transition.from != nil {
                cross.move(to: CGPoint(x: inset.minX, y: inset.maxY))
                cross.line(to: CGPoint(x: inset.maxX, y: inset.minY))
            }
            if w.transition.to != nil {
                cross.move(to: CGPoint(x: inset.minX, y: inset.minY))
                cross.line(to: CGPoint(x: inset.maxX, y: inset.maxY))
            }
            ink.withAlphaComponent(0.55).setStroke()
            cross.lineWidth = 1
            cross.stroke()
            if rect.width > 64 {
                let label = Typeface.attributed(w.transition.type, [.font: Typeface.ns(10.5, .medium), .foregroundColor: Theme.NS.ink])
                let size = label.size()
                let pill = CGRect(x: rect.midX - size.width / 2 - 4, y: rect.midY - size.height / 2 - 1, width: size.width + 8, height: size.height + 2)
                Theme.NS.desk.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
                label.draw(at: CGPoint(x: pill.minX + 4, y: pill.minY + 1))
            }
        }
    }

    private func drawScrim(_ rect: CGRect, ctx: CGContext) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.maxY - 16), options: [])
    }

    /// The words a clip opens with, for speech-only clips.
    private func firstWords(_ clip: Clip, _ media: MediaAsset) -> String? {
        guard let t = transcripts[media.id] else { return nil }
        let words = t.words.filter { ($0.start + $0.end) / 2 >= clip.sourceIn && ($0.start + $0.end) / 2 < clip.sourceOut && !$0.isFiller }
        guard !words.isEmpty else { return nil }
        return "“" + words.prefix(6).map(\.text).joined(separator: " ") + (words.count > 6 ? "…”" : "”")
    }

    /// Clip names sit on a small dark pill over pictures, and directly on quiet fills elsewhere.
    private func drawLabel(_ clip: Clip, media: MediaAsset?, rect: CGRect, onPicture: Bool, audioOnly: Bool, dim: CGFloat) {
        guard rect.width >= 80 else { return }
        var label: String
        switch clip.kind {
        case .media:
            if audioOnly, let media, let words = firstWords(clip, media) {
                label = words
            } else {
                label = clip.name ?? media?.name.humanized ?? "Clip"
            }
        case .text: label = clip.text?.text.replacingOccurrences(of: "\n", with: " ") ?? "Title"
        case .solid: label = clip.name ?? "Color"
        case .adjustment: label = clip.name ?? "Adjustment"
        case .sequence: label = clip.name ?? clip.mediaId.flatMap { project.sequence($0)?.name } ?? "Nested"
        }
        if !clip.effects.isEmpty {
            let names = clip.effects.filter(\.enabled).map { EffectCatalog.shortName($0.type) }
            if !names.isEmpty { label += "  ·  " + names.joined(separator: ", ") }
        }
        if clip.speed != 1 { label += String(format: "  %g×", (clip.speed * 100).rounded() / 100) }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let s = Typeface.attributed(label, [
            .font: Typeface.ns(11.5, .medium),
            .foregroundColor: (onPicture ? NSColor.white : Theme.NS.ink).withAlphaComponent(0.95 * dim),
            .paragraphStyle: para,
        ])
        let size = s.size()
        let fadeIn = CGFloat(max(clip.fadeIn, clip.audioFadeIn) * pxPerSec)
        let afterFade = fadeIn > 3 && fadeIn < rect.width / 2 ? rect.minX + min(fadeIn + 8, 40) : rect.minX
        let left = max(afterFade, headerW) + (onPicture ? 5 : 10)
        let avail = rect.maxX - left - (onPicture ? 5 : 8)
        guard avail > 24 else { return }
        if onPicture {
            let w = min(size.width + 12, avail)
            let pill = CGRect(x: left, y: rect.minY + 5, width: w, height: 18)
            NSColor.black.withAlphaComponent(0.6 * dim).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
            s.draw(with: CGRect(x: pill.minX + 6, y: pill.midY - size.height / 2, width: w - 12, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            let y = audioOnly && rect.height >= 30 ? rect.minY + 2 : rect.midY - size.height / 2
            s.draw(with: CGRect(x: left, y: y, width: avail, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// Fades darken toward the clip edge as a soft wedge.
    private func drawFades(_ clip: Clip, rect: CGRect, ctx: CGContext) {
        let fi = CGFloat(max(clip.fadeIn, clip.audioFadeIn) * pxPerSec)
        let fo = CGFloat(max(clip.fadeOut, clip.audioFadeOut) * pxPerSec)
        for (w, leading) in [(fi, true), (fo, false)] where w > 3 {
            let edge = leading ? rect.minX : rect.maxX
            let inner = leading ? rect.minX + w : rect.maxX - w
            let wedge = CGMutablePath()
            wedge.move(to: CGPoint(x: edge, y: rect.minY))
            wedge.addLine(to: CGPoint(x: inner, y: rect.minY))
            wedge.addLine(to: CGPoint(x: edge, y: rect.maxY))
            wedge.closeSubpath()
            ctx.saveGState()
            ctx.addPath(wedge)
            ctx.clip()
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [NSColor.black.withAlphaComponent(0.38).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: edge, y: rect.maxY), end: CGPoint(x: (edge + inner) / 2, y: rect.minY), options: [])
            }
            ctx.restoreGState()
        }
    }

    /// Frames tile across the clip at their source times; each tile blends into the one
    /// before it so neighboring frames meet without a hard seam.
    private func drawFilmstrip(_ clip: Clip, media: MediaAsset, rect: CGRect, ctx: CGContext, alpha: CGFloat) {
        guard let thumbs = thumbnails else { return }
        let aspect = media.height > 0 ? CGFloat(media.width) / CGFloat(media.height) : 16 / 9
        let tileW = max(24, (rect.height * aspect).rounded())
        let blend: CGFloat = 10
        let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.cgColor] as CFArray, locations: [0, 1])
        ctx.interpolationQuality = .medium
        var x = rect.minX
        if x < headerW - tileW { x += ((headerW - tileW - x) / tileW).rounded(.down) * tileW }
        var first = true
        while x < min(rect.maxX, bounds.width) {
            let t = timeFor(x + tileW / 2)
            let src = media.isImage ? 0 : clip.sourceTime(atTimeline: min(max(t, clip.start), clip.end))
            if let img = thumbs.image(mediaPath: media.path, at: src) {
                let left = x.rounded(.down) - (first ? 0 : blend)
                ctx.saveGState()
                ctx.setAlpha(alpha)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.saveGState()
                ctx.translateBy(x: left, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: tileW + (first ? 1 : blend + 1), height: rect.height))
                ctx.restoreGState()
                if !first, let fade {
                    ctx.setBlendMode(.destinationIn)
                    ctx.drawLinearGradient(fade, start: CGPoint(x: left, y: 0), end: CGPoint(x: left + blend, y: 0), options: [.drawsAfterEndLocation])
                }
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
            first = false
            x += tileW
        }
    }

    /// A mirrored, smoothed envelope of the clip's audio peaks.
    private func drawWaveform(_ clip: Clip, analysis a: AudioAnalysis, rect: CGRect, color: NSColor, gain: Double) {
        guard !a.levels.isEmpty, rect.width > 2 else { return }
        let minX = max(rect.minX, headerW), maxX = min(rect.maxX, bounds.width)
        guard maxX > minX else { return }
        let animated = clip.anim["audio.volume"] != nil
        let staticGain = gain
        let step: CGFloat = 2
        var heights: [CGFloat] = []
        var x = minX
        while x <= maxX {
            // Follow volume automation such as ducking, so the human can see it.
            let gainHere = animated ? staticGain / max(clip.volume, 1e-6) * clip.number("audio.volume", at: timeFor(x) - clip.start, default: clip.volume) : staticGain
            let g = gainHere <= 0 ? 0 : 1 + 20 * log10(max(gainHere, 0.01)) / 60
            let t0 = clip.sourceTime(atTimeline: timeFor(x)), t1 = clip.sourceTime(atTimeline: timeFor(x + step))
            let i0 = max(0, Int(t0 * a.levelRate)), i1 = min(a.levels.count, max(i0 + 1, Int(t1 * a.levelRate)))
            var peak: Float = -80
            if i0 < i1 { for i in i0..<i1 { peak = max(peak, a.levels[i]) } }
            let norm = CGFloat(max(0, (Double(peak) + 60) / 60) * max(0, g))
            heights.append(min(1, norm) * rect.height / 2)
            x += step
        }
        guard heights.count > 1 else { return }
        var smooth = heights
        for i in 1..<(heights.count - 1) { smooth[i] = (heights[i - 1] + 2 * heights[i] + heights[i + 1]) / 4 }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: minX, y: rect.midY))
        for (i, h) in smooth.enumerated() { path.line(to: CGPoint(x: minX + CGFloat(i) * step, y: rect.midY - max(0.5, h))) }
        for (i, h) in smooth.enumerated().reversed() { path.line(to: CGPoint(x: minX + CGFloat(i) * step, y: rect.midY + max(0.5, h))) }
        path.close()
        color.setFill()
        path.fill()
    }

    /// Caption blocks merge into chips at least 64 pt wide so their words stay readable at any zoom.
    private func drawCaptions(_ lane: CGRect) {
        var chips: [(start: Double, end: Double, text: String)] = []
        for seg in captions {
            let text = seg.text.replacingOccurrences(of: "\n", with: " ")
            if var last = chips.last, xFor(last.end) - xFor(last.start) < 64, seg.start - last.end < 0.8 {
                last.end = seg.end
                last.text += " " + text
                chips[chips.count - 1] = last
            } else {
                chips.append((seg.start, seg.end, text))
            }
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: Typeface.ns(11, .regular), .foregroundColor: NSColor.white.withAlphaComponent(0.68), .paragraphStyle: para]
        for chip in chips {
            let x0 = xFor(chip.start).rounded(), x1 = xFor(chip.end).rounded()
            guard x1 >= headerW, x0 <= bounds.width else { continue }
            let r = CGRect(x: x0 + 1, y: lane.minY + 3, width: max(2, x1 - x0 - 2), height: lane.height - 6)
            NSColor.white.withAlphaComponent(0.065).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            guard r.width >= 44 else { continue }
            let s = Typeface.attributed(chip.text, attrs)
            let h = s.size().height
            s.draw(with: CGRect(x: r.minX + 7, y: r.midY - h / 2, width: r.width - 14, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func drawNotePins(_ lane: CGRect) {
        for c in comments.sorted(by: { a, _ in a.id != selected }) {
            let x = xFor(c.time)
            guard x >= headerW - 6, x <= bounds.width + 6 else { continue }
            let r: CGFloat = c.id == selected ? 5 : 4
            let dot = NSBezierPath(ovalIn: CGRect(x: x - r, y: lane.midY - r, width: 2 * r, height: 2 * r))
            if c.status == .resolved {
                Theme.NS.ink3.setStroke()
                dot.lineWidth = 1.25
                dot.stroke()
            } else {
                noteColor(c).setFill()
                dot.fill()
            }
            if c.id == selected {
                let ring = NSBezierPath(ovalIn: CGRect(x: x - r - 3, y: lane.midY - r - 3, width: 2 * r + 6, height: 2 * r + 6))
                noteColor(c).withAlphaComponent(0.55).setStroke()
                ring.lineWidth = 1
                ring.stroke()
            }
        }
    }

    private func hoveredNote() -> (Comment, CGRect)? {
        guard let hx = hoverX, let notes = lanes().first(where: { if case .notes = $0.kind { return true }; return false }),
              hoverY >= notes.rect.minY - 4, hoverY <= notes.rect.maxY + 4,
              let hit = comments.min(by: { abs(xFor($0.time) - hx) < abs(xFor($1.time) - hx) }),
              abs(xFor(hit.time) - hx) < 9
        else { return nil }
        return (hit, notes.rect)
    }

    /// A preview of the note under the pointer, hanging from its pin.
    private func drawNoteBubble() {
        guard let (c, lane) = hoveredNote() else { return }
        let x = xFor(c.time)
        let human = c.author == .human
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        let who = NSAttributedString(string: (human ? "You" : "Claude") + "   " + Theme.compact(c.time, fps: project.canvas.fps) + "\n", attributes: [.font: Typeface.ns(11, .semibold, tabular: true), .foregroundColor: human ? Theme.NS.wax : Theme.NS.claude, .paragraphStyle: para])
        let body = Typeface.attributed(c.text, [.font: Typeface.ns(12.5, .regular), .foregroundColor: Theme.NS.ink.withAlphaComponent(0.92), .paragraphStyle: para])
        let text = NSMutableAttributedString(attributedString: who)
        text.append(body)
        let maxW: CGFloat = 240
        let bound = text.boundingRect(with: CGSize(width: maxW, height: 80), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let w = ceil(bound.width) + 24, h = min(ceil(bound.height), 80) + 18
        let bx = min(max(x - 22, headerW + 6), bounds.width - w - 8)
        let box = CGRect(x: bx, y: lane.maxY + 8, width: w, height: h)
        let shape = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
        let tail = NSBezierPath()
        tail.move(to: CGPoint(x: x - 6, y: box.minY + 0.5))
        tail.line(to: CGPoint(x: x, y: box.minY - 6))
        tail.line(to: CGPoint(x: x + 6, y: box.minY + 0.5))
        tail.close()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -5)
        shadow.set()
        (human ? NSColor(hex: 0x29261E) : NSColor(hex: 0x22242E)).setFill()
        shape.fill()
        tail.fill()
        NSGraphicsContext.restoreGraphicsState()
        (human ? Theme.NS.wax : Theme.NS.claude).withAlphaComponent(0.35).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        text.draw(with: CGRect(x: box.minX + 12, y: box.minY + 9, width: maxW, height: h - 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawNoteLines(top: CGFloat, bottom: CGFloat) {
        for c in comments where c.status == .open || c.id == selected {
            let x = xFor(c.time).rounded()
            guard x >= headerW, x <= bounds.width else { continue }
            noteColor(c).withAlphaComponent(c.id == selected ? 0.55 : 0.16).setFill()
            CGRect(x: x - 0.5, y: top, width: 1, height: bottom - top).fill()
        }
    }

    private func drawHover(top: CGFloat, bottom: CGFloat) {
        guard let hx = hoverX, !scrubbing, hx >= headerW else { return }
        Theme.NS.ink.withAlphaComponent(0.25).setFill()
        CGRect(x: hx.rounded() - 0.5, y: top, width: 1, height: bottom - top).fill()
    }

    // MARK: Interaction

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoverX = p.x >= headerW && timeFor(p.x) <= project.duration + 0.2 && timeFor(p.x) >= -0.2 ? p.x : nil
        hoverY = p.y
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let notes = lanes().first(where: { if case .notes = $0.kind { return true }; return false }),
           p.y >= notes.rect.minY - 2, p.y <= notes.rect.maxY + 2,
           let hit = comments.min(by: { abs(xFor($0.time) - p.x) < abs(xFor($1.time) - p.x) }), abs(xFor(hit.time) - p.x) < 9 {
            onSelectComment?(hit.id)
            onSeek?(hit.time)
            return
        }
        scrubbing = true
        needsDisplay = true
        scrub(p.x)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.x > bounds.width - 12 { viewStart = clampedStart(viewStart + 30 / pxPerSec); needsDisplay = true }
        if p.x < headerW + 12 { viewStart = clampedStart(viewStart - 30 / pxPerSec); needsDisplay = true }
        scrub(p.x)
    }

    override func mouseUp(with event: NSEvent) {
        scrubbing = false
        needsDisplay = true
    }

    private func scrub(_ x: CGFloat) {
        let t = min(max(0, timeFor(max(headerW, x))), project.duration)
        onSeek?(t)
        playhead = t
        positionPlayhead()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            zoom(by: 1 - event.scrollingDeltaY * 0.01, at: convert(event.locationInWindow, from: nil).x)
            return
        }
        let dx = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let delta = event.hasPreciseScrollingDeltas ? dx : dx * 12
        viewStart = clampedStart(viewStart - Double(delta) / pxPerSec)
        needsDisplay = true
        positionPlayhead()
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil).x)
    }

    private func zoom(by factor: Double, at x: CGFloat) {
        let anchor = timeFor(x)
        let minPx = Double(bounds.width - originX - 24) / max(project.duration, 1)
        pxPerSec = min(max(pxPerSec * factor, min(minPx, 4)), 2400)
        viewStart = clampedStart(anchor - Double(x - originX) / pxPerSec)
        needsDisplay = true
        positionPlayhead()
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
