import Foundation

/// How a frame-rate change re-times the edit.
public enum FrameRateConform: String, Codable, Sendable, CaseIterable {
    /// Every time moves to the nearest frame of the new rate; the edit keeps its length in seconds.
    case snap
    /// Every time keeps its frame count, as a sequence frame-rate change does: the edit runs longer or shorter.
    case keepFrames = "keep_frames"
}

/// What a frame-rate conform changed.
public struct FrameRateConformReport: Equatable, Sendable {
    public var from: Double
    public var to: Double
    public var mode: FrameRateConform
    /// Timeline times (cuts, sound edges, transitions, markers, keyframes, caption offsets) that moved.
    public var moved: Int
    /// The largest of those moves, in seconds.
    public var maxShift: Seconds
    public var oldDuration: Seconds
    public var newDuration: Seconds
    /// Clips shorter than a frame of the new rate, removed.
    public var removed: [String]
    /// Clips cut short to the end of their media.
    public var trimmed: [String]
    /// Transitions that no longer fit their clips, removed.
    public var droppedTransitions: [String]

    public var summary: String {
        var parts: [String] = []
        let rate = "\(fmtRate(from))→\(fmtRate(to)) fps"
        switch mode {
        case .snap:
            parts.append(moved == 0 ? "Conformed \(rate): every time was already on the new frame grid"
                         : "Conformed \(rate) by snapping to the new frame grid: \(moved) time\(moved == 1 ? "" : "s") moved, at most \(fmt3(maxShift))s (\(fmt2(maxShift * to)) frame)")
        case .keepFrames:
            parts.append("Conformed \(rate) keeping frame counts: the edit runs \(fmt2(oldDuration))s → \(fmt2(newDuration))s; \(moved) time\(moved == 1 ? "" : "s") moved, at most \(fmt3(maxShift))s")
        }
        parts.append("cuts that met still meet, so no gaps or overlaps")
        if !removed.isEmpty { parts.append("removed clips shorter than a frame: \(removed.joined(separator: ", "))") }
        if !trimmed.isEmpty { parts.append("cut short at the end of their media: \(trimmed.joined(separator: ", "))") }
        if !droppedTransitions.isEmpty { parts.append("removed transitions that no longer fit: \(droppedTransitions.joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }

    private func fmtRate(_ f: Double) -> String { abs(f - f.rounded()) < 1e-6 ? "\(Int(f.rounded()))" : String(format: "%.3f", f) }
    private func fmt3(_ v: Double) -> String { String(format: "%.3f", v) }
}

extension Project {
    /// Re-times the current timeline, made at `old` fps, to the canvas's frame rate: clip starts, ends and in points,
    /// sound edges (split edits), fades, keyframes, text unit times, track fader keys, transitions, markers and caption
    /// offsets, in the timeline and its nested sequences. `snap` moves each to the nearest new frame; `keepFrames`
    /// keeps its frame count. Cuts that met still meet, since both sides map from the same time; a clip keeps its
    /// picture in sync when its start moves. Clips left shorter than a frame are removed, clips running past their
    /// media are cut short, and transitions that no longer fit are removed.
    @discardableResult
    public mutating func conformFrameRate(from old: Double, mode: FrameRateConform = .snap) -> FrameRateConformReport {
        let oldGrid = FrameGrid(fps: old), newGrid = FrameGrid(fps: canvas.fps)
        var report = FrameRateConformReport(from: old, to: canvas.fps, mode: mode, moved: 0, maxShift: 0, oldDuration: duration, newDuration: duration,
                                            removed: [], trimmed: [], droppedTransitions: [])
        func frames(_ t: Seconds, _ g: FrameGrid) -> Int {
            // Times a hair apart (one side of a cut computed as start + duration) count as the same.
            let x = (t * g.rate * 1e6).rounded() / 1e6
            return Int(x.rounded())
        }
        func seconds(_ n: Int) -> Seconds { Double(n * newGrid.num) / Double(newGrid.den) }
        var moved = Set<Int64>()
        /// A timeline position on the new grid.
        func at(_ t: Seconds) -> Seconds {
            let mapped = seconds(mode == .snap ? frames(t, newGrid) : frames(t, oldGrid))
            if abs(mapped - t) > 1e-9 {
                moved.insert(Int64((t * 1e6).rounded()))
                report.maxShift = max(report.maxShift, abs(mapped - t))
            }
            return mapped
        }
        /// A length on the new grid; one that had any length keeps at least a frame.
        func length(_ d: Seconds) -> Seconds {
            guard abs(d) > 1e-9 else { return d }
            let n = mode == .snap ? frames(abs(d), newGrid) : frames(abs(d), oldGrid)
            return seconds(max(1, n)) * (d < 0 ? -1 : 1)
        }
        func curve(_ c: Curve, origin: Seconds, newOrigin: Seconds) -> Curve {
            var c = c
            for k in c.keys.indices { c.keys[k].t = at(origin + c.keys[k].t) - newOrigin }
            return c
        }

        func conform(_ tracks: inout [Track]) {
            for t in tracks.indices {
                if let v = tracks[t].volumeCurve { tracks[t].volumeCurve = curve(v, origin: 0, newOrigin: 0) }
                var kept: [Clip] = []
                for var c in tracks[t].clips {
                    let start = at(c.start), end = at(c.end)
                    guard end > start + 1e-9 else { report.removed.append(c.id); continue }
                    let soundStart = at(c.start - c.audioLead), soundEnd = at(c.end + c.audioLag)
                    let media = c.mediaId.flatMap(mediaAsset)
                    if mode == .snap {
                        // The picture stays in sync where the clip now starts (or, reversed, ends).
                        let shift = c.reverse ? -(end - c.end) * c.speed(atLocal: c.duration) : (start - c.start) * c.speed(atLocal: 0)
                        c.sourceIn = max(0, c.sourceIn + shift)
                        if c.kind == .sequence || media.map({ !$0.isImage }) == true { c.sourceIn = max(0, seconds(frames(c.sourceIn, newGrid))) }
                    }
                    for (key, value) in c.anim { c.anim[key] = curve(value, origin: c.start, newOrigin: start) }
                    if var text = c.text, let times = text.unitTimes {
                        text.unitTimes = times.map { at(c.start + $0) - start }
                        c.text = text
                    }
                    c.start = start
                    c.duration = end - start
                    c.audioLead = start - soundStart
                    c.audioLag = soundEnd - end
                    c.fadeIn = length(c.fadeIn)
                    c.fadeOut = length(c.fadeOut)
                    c.audioFadeIn = length(c.audioFadeIn)
                    c.audioFadeOut = length(c.audioFadeOut)
                    if let m = media, !m.isImage, c.kind == .media, m.duration > 0 {
                        let over = c.sourceOut - m.duration
                        if over > 1 / max(m.fps, 24), !c.reverse, !c.isRetimed {
                            let keep = frames((m.duration - c.sourceIn) / max(c.speed, 1e-6), newGrid)
                            guard keep > 0 else { report.removed.append(c.id); continue }
                            c.duration = seconds(keep)
                            c.audioLag = min(c.audioLag, 0)
                            report.trimmed.append(c.id)
                        }
                        let heard = c.audioSourceRange
                        if heard.start < 0 { c.audioLead += heard.start / max(c.speed, 1e-6) }
                        if heard.end > m.duration { c.audioLag -= (heard.end - m.duration) / max(c.speed, 1e-6) }
                    }
                    kept.append(c)
                }
                tracks[t].clips = kept
            }
        }
        func conform(_ transitions: inout [Transition]) {
            for i in transitions.indices {
                transitions[i].duration = length(transitions[i].duration)
                if let o = transitions[i].cutOffset { transitions[i].cutOffset = min(max(0, length(o)), transitions[i].duration) }
            }
        }

        var main = tracks
        conform(&main)
        tracks = main
        conform(&transitions)
        for s in sequences.indices {
            var inner = sequences[s].tracks
            conform(&inner)
            sequences[s].tracks = inner
            conform(&sequences[s].transitions)
        }
        for m in markers.indices {
            markers[m].time = at(markers[m].time)
            if let d = markers[m].duration { markers[m].duration = length(d) }
        }
        for e in captions.edits.indices {
            if let o = captions.edits[e].startOffset { captions.edits[e].startOffset = length(o) }
            if let o = captions.edits[e].endOffset { captions.edits[e].endOffset = length(o) }
        }

        // Transitions that no longer fit their handles try a frame shorter, then go.
        func fit(_ scope: inout Project) -> [String] {
            var dropped: [String] = []
            var kept: [Transition] = []
            for var tr in scope.transitions {
                var probe = scope
                probe.transitions = kept
                if (try? probe.checkTransition(tr)) == nil, tr.duration > seconds(1) * 1.5 {
                    tr.duration -= seconds(1)
                    if let o = tr.cutOffset { tr.cutOffset = min(o, tr.duration) }
                }
                if (try? probe.checkTransition(tr)) != nil { kept.append(tr) } else { dropped.append(tr.id) }
            }
            scope.transitions = kept
            return dropped
        }
        let before = Set(transitions.map(\.id))
        report.droppedTransitions = fit(&self).filter(before.contains)
        for s in sequences.indices {
            var inner = inside(sequences[s])
            report.droppedTransitions += fit(&inner).map { "\(sequences[s].id)/\($0)" }
            sequences[s].transitions = inner.transitions
        }
        report.moved = moved.count
        report.newDuration = duration
        return report
    }
}
