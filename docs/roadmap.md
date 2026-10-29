# Cutline roadmap: from rough cuts to any edit

Synthesized from three research passes: a gap analysis against Premiere Pro, Final Cut Pro and DaVinci Resolve; an agent-native MCP design; and a feasibility study on Apple frameworks (macOS 26, Apple Silicon).

## Where Cutline stands

Strong today: transcript-driven cutting (source-time ranges that survive edits), filler and pause removal, layered video with transform keyframes, styled text, live captions, a shared Metal compositor for preview and export, undo history, and notes pinned to frames.

The gaps that block "any fancy edit" come from five model limits:

- Clips on a track can't overlap and the compositor only does source-over, so there are no transitions, blend modes, effects, masks or adjustment layers.
- Only scale, x, y, rotation and opacity can animate.
- Audio is locked to picture and only has constant volume plus linear fades. There's no automation, effects, loudness control or split edits.
- Speed is one constant per clip. There are no ramps, freezes or reverse.
- Export is a fixed preset. There are no sidecar subtitles, chapters, bitrate control or interchange formats.

## Design principles

1. **Capability grows through data, not tools.** New effects, transitions, generators and recipes are catalog entries. The tool list stays around 44 (38 today), which keeps schemas near 7k tokens and tool choice reliable.
2. **One addressing scheme.** Everything is `target` + `path` + value. A value is a constant, keyframes, or a binding to analysis data. For example: `fx.blur1.radius`, `audio.volume`, `transform.scale`, `text.size`.
3. **Edit-stable anchors.** Any time argument accepts a transcript word (`m1.w213`, `m1.w213.end`), a beat (`b20`), a shot (`m2.s4`), a marker (`mk3`) or an offset (`m1.w213+0.1`). They stay correct after later trims.
4. **Every edit is previewable and atomic.** All edit tools take `dry_run`, and `batch` gains variables, `verify` frames and `if_history` concurrency checks.
5. **Agents grade with numbers, not wheels.** Scopes, loudness, flicker, safe-area and contrast are measured and returned as numbers.
6. **Heavy perception never runs while rendering.** Vision, optical flow and audio effects run as background jobs into caches. Preview and export read the cached results.

## Data model v2 (sketch)

```jsonc
Project  { sequences: { main: Sequence, ... }, templates: [...] }
Sequence { canvas?, tracks: [Track], transitions: [Transition], markers }
Track    { ..., blend, effects: [Effect], audio: { volume, pan, effects } }
Clip     { kind: media|text|solid|generator|adjustment|sequence,
           transform, opacity, blend, effects: [Effect],           // masks are effects of category "mask"
           time:  { speed, remap?: Curve, frameBlend, reverse, freeze? },
           audio: { volume, pan, lead, lag, effects },             // lead/lag = J/L cuts
           anim:  { "<path>": Curve | Binding },                   // any numeric or color parameter
           origin?: { recipe, instance } }
Effect     { id: "blur1", type: "blur.gaussian", enabled, mix, params, mask? }
Transition { from: clipId, to: clipId, part: video|audio|both, type, duration, align, params }  // uses source handles
Curve      { keys: [[t, v, ease]] }    // linear|in|out|inOut|hold|back|elastic|bezier
Binding    { bind: "trk_5.top.x" | "audio:A1.env" | "beats", map?, offset?, smooth? }
Text      += animators: [{ unit: char|word|line, sync?: "speech", props, duration, stagger, ease }]
```

Clips still never overlap. Transitions borrow media from just past each clip's edge, and the engine checks that enough media exists.

## Tool surface (44)

| Group | Tools |
|---|---|
| Project and history (5) | project_create, project_open, project_status (param tree per target), canvas_set, **history** (list, undo, redo, restore, diff) |
| Media and perception (7) | media_import, media_remove, media_analyze (features: transcript, scenes, beats, shots, faces, persons, speakers, saliency, loudness, emphasis, sync), media_transcript (word IDs, emphasis), media_frames (overlays), **analysis_read**, **media_track** |
| Structure (13) | clip_add (generator, adjustment and sequence kinds), clip_update (absorbs move), clip_split, clip_delete, range_delete, source_cut, assemble, cut_silences, track_add, track_update, **trim** (ripple/roll/slip/slide, audio-only for J/L), **sequence_nest**, **markers** |
| Look and sound (5) | **param_set** (set, animate, bind), **effect_add** (video, mask and audio effects), **transition_set**, text_add (animators), captions_set |
| Discovery and extensibility (5) | **catalog** (types, param schemas, examples), **recipe**, **template_save**, batch (variables, dry_run, verify), **project_patch** (JSON Patch, last resort) |
| Verification (3) | timeline_frames (motion strips, before/after, overlays), timeline_transcript, **timeline_measure** (LUFS, true peak, scopes, flicker, flash frames, black, text contrast, safe area) |
| Human loop and output (6) | comments_list, comment_reply, comment_add, preview_state, preview_seek (absorbs open), export |

Merged away: clip_move, undo, redo, history_restore, preview_open, marker_add and marker_remove.

**Starter recipes**: speed_ramp, punch_in, beat_cut, split_screen, pip, split_edit, multicam_switch, reframe, follow, duck, loudness_normalize, freeze_frame, whip_pan, kinetic_text, look, glitch. A recipe returns the low-level edits it made, as one undoable entry. Re-running the same recipe instance replaces its earlier edits.

## Engine architecture

- **Compile the project into segments.** Each time range with a constant set of active clips gets its own video composition instruction listing only its sources. Inside each segment is a small Core Image graph: Source → Retime → Transform → Effects → Mask → Blend or Transition → Adjustment → Text and captions. Nodes are pure functions with content hashes, which enables caching and a `frame_explain` debugging tool.
- **Alternating video lanes per track** so a transition sees both clips.
- **Picture pipeline.** Half-float working format, a canvas color space (709, P3, HLG or PQ), and parameters scaled by render resolution so preview matches export.
- **Audio as offline stems.** Each track is rendered (clip chains → time-stretch → fades → track chain) with AVAudioEngine's offline mode into cached files. The master bus normalizes loudness and limits. Preview and export play the same stems. Until a stem is ready, playback falls back to the current volume-ramp mix.
- **Export.** Move to AVAssetReader → AVAssetWriter for bitrate and profile control, color tags, embedded subtitles and chapters.
- **Caches inside the bundle**, keyed by content and analyzer version: analysis, masks, proxies (ProRes Proxy, including reversed copies), stems and rendered segments. A `jobs` tool plus a `jobs.json` file let the app show progress.
- **Render quality levels** (draft, preview, full): proxies and simpler effects keep preview real-time. Export always uses full quality from the original files.

## Status

All six phases are implemented.

- **Phase 0, done.** Format 2 with migration, effect stacks, 17 blend modes, animation of any parameter, anchors, `param_set`, `effect_add`, `catalog`, `dry_run`, `batch` with named results, `history` with diffs.
- **Phase 1, done.** Volume automation, ducking, J/L cuts, audio effects on clips, tracks and the master (rendered offline into cached stems), audio crossfades (transitions with `part` audio or both), BS.1770 loudness with true peak, `recipe loudness_normalize`, and export through AVAssetReader → AVAssetWriter.
- **Phase 2, done.** `transition_set` with 12 types using media handles and A/B picture lanes; color wheels, curves, HSL, creative looks and `.cube` LUTs; glitch, masks and adjustment layers; `timeline_measure` picture metrics (exposure, clipping, cast, shot mismatches, black, flash frames, photosensitive flashing) and text contrast and safe areas.
- **Phase 3, done.** Background analysis jobs (`jobs.json`, shown in the preview), beats and downbeats, shots with Vision labels, shot size, people, on-screen text, saliency, aesthetics and feature prints, face tracks, speakers and word emphasis, sound events, `analysis_read`, frame overlays, and beat, downbeat and shot anchors. Shot descriptions come from Vision labels; a Foundation Models paraphrase was left out because it can't see the frame.
- **Phase 4, done.** Speed ramps (`time.speed` curves), held frames, reverse, frame blending and optical-flow retiming, stabilization, `media_track` with parameter bindings, auto-reframe, per-word text animators, generators (shapes, arrows, highlights, callouts, lower thirds, counters, progress bars), recipes and `template_save`, and `trim`.
- **Phase 5, done.** Person and subject segmentation masks, chroma key, nested sequences (`sequence_nest`), and multicam sync by audio cross-correlation with `recipe multicam_switch` cutting to the speaker.
- **Phase 6, done.** SRT/VTT sidecars and embedded subtitles, chapters (embedded and a YouTube list), platform presets with safe-zone, length and loudness checks, project forks and export variants, OTIO and FCPXML, quality checks after every edit, and `project_patch`.

## Phases (about 1–2 weeks each)

| # | Phase | What the agent can do afterwards | Key native APIs |
|---|---|---|---|
| 0 | **Foundation**: model v2 and migration, segment compiler and video lanes, effect registry, `param_set`, `effect_add`, `catalog`, anchors, `dry_run`, history consolidation | Animate any parameter; foundation for everything below | Core Image, AVVideoCompositionInstruction |
| 1 | **Audio finishing**: volume automation, `duck`, loudness measurement and normalization, EQ, compressor, limiter, de-esser, voice isolation, offline stems, `trim` with audio-only J/L cuts, audio crossfades, writer-based export | Broadcast-quality talking heads, music under voice | AVAudioEngine manual rendering, AUNBandEQ, AUDynamicsProcessor, AUPeakLimiter, AUSoundIsolation, vDSP |
| 2 | **Transitions, effects and color**: dissolve, dip, wipe, slide, push, zoom, whip; blur, glow, vignette, grain, sharpen, pixelate; LUTs, color grading, curves; blend modes; shape masks; adjustment layers; `timeline_measure` | Polished cuts, looks, censoring, callouts | CIDissolveTransition and others, CIColorCubeWithColorSpace, CIColorCurves, CIBlendWithMask, custom Metal kernels |
| 3 | **Perception index**: jobs system; beats; shots with descriptions; faces and people; saliency; speakers; emphasis; sound events; `analysis_read`; overlays on frames | The agent knows the footage without spending tokens on frames | Vision (classification, feature prints, aesthetics, faces, bodies, OCR), SNClassifySoundRequest, Foundation Models, vDSP beat tracker |
| 4 | **Motion and time**: speed ramps, freeze, reverse, frame blending and optical-flow slow motion; `media_track` with bindings; auto-reframe; stabilization; per-word text animators; generators (shapes, arrows, lower thirds); recipes and templates | Velocity edits, follow-labels, vertical repurposing, kinetic type | VTFrameProcessor, VNTrackObjectRequest, saliency, VNHomographicImageRegistrationRequest |
| 5 | **Advanced compositing and multicam**: person and subject segmentation masks, chroma key, nested sequences, multicam sync and `multicam_switch` by speaker | Text behind subject, background swaps, podcast auto-switching | VNGeneratePersonSegmentationRequest, VNGenerateForegroundInstanceMaskRequest, GCC-PHAT cross-correlation |
| 6 | **Delivery and scale**: SRT/VTT and embedded captions, chapters, platform presets with safe-zone checks, project forks and batch variants, OTIO and FCPXML export, quality checks run on every edit | Ship anywhere; 20 variants from one edit; hand off to a human finisher | AVAssetWriter subtitle and chapter tracks, XMLDocument |

**Spikes before committing:**
- VTFrameProcessor availability, for phase 4 slow motion.
- AUSoundIsolation quality on offline renders (phase 1).
- Precompiled Metal CI kernels under SwiftPM (phase 2).
- A speaker-diarization approach that needs no Apple API (phase 3).

## Where an agent-driven editor can win

- **Semantic story editing:** "cut every pricing tangent", "build 3 minutes from 6 hours of interviews".
- **Constraint-solved edits:** exactly 45.00 s, complete sentences, every cut on a beat, ending on the final downbeat.
- **Formulaic craft at scale:** a punch-in on every jump cut, b-roll on every named noun, captions colored per speaker.
- **Exhaustive variants:** different hooks, aspect ratios, lengths and languages, each one rendered and self-reviewed.
- **Continuous quality checks** on every edit: flash frames, cuts mid-word, text over faces or platform UI, loudness out of spec.
- **Metadata as a by-product:** chapters, titles, descriptions, SRT files and thumbnails come from the same transcript.

## Top risks

1. **Real-time preview** with several 4K sources and stacked effects. Mitigations: proxies, quality levels, render cache.
2. **Confusing timeline, source and keyframe time** once speed remapping exists. Responses must echo the resolved timeline times.
3. **Audio stems getting stale, and effect latency or tails** shifting audio against picture.
4. **Masks flicker and trackers drift.** Smooth over time and report coverage and lost spans to the agent.
5. **Things with no Apple API** (loudness, beat tracking, noise reduction, diarization) must be built in-house or with permissively licensed models. No GPL or AGPL code.
6. **The v2 migration breaks project.json readers.** Bump `formatVersion`, migrate on open, and update the preview app in the same change.
7. **Tool-count creep.** New capability goes into the catalog, recipes or templates, never new tools.
