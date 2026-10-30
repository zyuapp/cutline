import CutlineCore
import Foundation

/// What tools/list shows for a tool: a short contract. The tool's own description and argument descriptions are
/// its full manual, shown by catalog tool=<name>.
struct ToolBrief {
    let text: String
    /// Short descriptions by argument path ("leader.bars" for nested ones); "" lists the argument without one.
    var args: [String: String] = [:]
    /// Accepted but not listed.
    var hide: Set<String> = []
}

extension Toolbox {
    /// Enums longer than this are left to catalog and error messages.
    static let listedEnumLimit = 16

    static let briefs: [String: ToolBrief] = [
        "project_create": ToolBrief(text: "Create a .cutline project, open it here and in the preview app.", args: [
            "path": "Where; .cutline is appended",
            "import": "Start from an .fcpxml(d), .otio or .edl timeline",
            "preset": "landscape 1920×1080, vertical 1080×1920, square, portrait 1080×1350, uhd",
            "color_space": "rec709 (default), p3, rec2020_hlg, rec2020_pq (HDR)",
            "drop_frame": "Drop-frame timecode in EDL/FCPXML/XML; default at 29.97/59.94",
            "timecode_start": "\"hh:mm:ss:ff\" of the first frame, default 01:00:00:00",
            "width": "", "height": "", "fps": "Default: first video's, else 30", "background": "Hex, default #000000", "name": "", "open_preview": "Default true",
            "edl_fps": "EDL frame rate, default 30",
        ]),
        "project_open": ToolBrief(text: "Open a .cutline project.", args: ["open_preview": "Default false", "path": ""]),
        "project_status": ToolBrief(text: "The project: canvas, media and analysis, tracks and clips with timeline and source times, effects, captions, open comments, warnings. target=<clip> lists its parameter paths and keys; detail=json the raw project.", args: [
            "target": "Clip id", "detail": "",
        ]),
        "canvas_set": ToolBrief(text: "Change canvas size, frame rate, color space, timecode or background; media refits, text scales.", args: [
            "preset": "landscape, vertical, square, portrait, uhd",
            "color_space": "rec709, p3, rec2020_hlg, rec2020_pq",
            "drop_frame": "Drop-frame timecode in interchange files",
            "timecode_start": "\"hh:mm:ss:ff\" of the first frame",
            "width": "", "height": "", "fps": "", "background": "Hex",
        ]),
        "history": ToolBrief(text: "Edit history: list, undo, redo, restore an entry, diff against a version, or fork into a separate copy.", args: [
            "id": "Entry for restore or diff", "path": "For fork: the new .cutline", "steps": "For undo/redo, default 1", "limit": "For list, default 20", "action": "",
        ]),
        "preview_seek": ToolBrief(text: "Move the human's preview playhead or play a range.", args: [
            "time": "Timeline time or anchor", "end": "Play until here", "play": "", "open": "Open the preview app",
        ]),
        "preview_state": ToolBrief(text: "The preview playhead and play state (\"here\", \"this part\")."),
        "media_import": ToolBrief(text: "Import (or relink) files and folders; analyzes transcripts, pauses and scene cuts. MXF/DNx/MPEG-2 get a ProRes mezzanine; interlaced media is deinterlaced. Returns the media ids.", args: [
            "paths": "Files or folders", "relink": "Find missing media inside paths instead", "analyze": "Default true", "language": "Default en-US",
        ]),
        "media_analyze": ToolBrief(text: "Run analysis: transcript, scenes, beats, speakers, shots (faces, saliency, shot size), sounds. Read it with analysis_read.", args: [
            "media_id": "Id, ids or \"all\"",
            "features": "Default all the media allows",
            "channel": "Channel(s) analysis listens to: \"ch3\", \"ch3+ch4\", \"mix:1,3\", auto",
            "background": "Return at once", "language": "Default en-US",
        ], hide: ["log", "signal_range"]),
        "media_remove": ToolBrief(text: "Remove unused media.", args: ["media_id": ""]),
        "media_transcript": ToolBrief(text: "What a media file says, in SOURCE time with word ids (for source_cut, assemble, source_in/out); fillers *um*, pauses ≥0.4 s.", args: [
            "media_id": "", "start": "Source time", "end": "Source time", "words": "Every word with its time",
        ]),
        "media_frames": ToolBrief(text: "Contact sheet of source frames from one media file.", args: [
            "media_id": "", "times": "Source times", "count": "Default 8, max 24", "start": "", "end": "",
            "overlay": "Draw faces, subject and shot size",
        ]),
        "timeline_frames": ToolBrief(text: "Render timeline frames exactly as export will, with the clip visible at each time.", args: [
            "times": "Timeline times", "count": "Default 6, max 24", "start": "", "end": "", "size": "large for detail",
            "view": "matte: white where clip's effect acts (keys, masks, qualifiers)", "clip": "For matte", "effect": "For matte",
        ]),
        "timeline_transcript": ToolBrief(text: "What the edit says in TIMELINE time, per clip, from the dialogue tracks; pauses ≥0.4 s and fillers marked.", args: [
            "start": "", "end": "", "all_tracks": "Include music, effects and ambience tracks",
        ]),
        "clip_add": ToolBrief(text: "Place media, a solid, a generator graphic or an adjustment layer. Default track V1 (A1 for audio); \"new\" adds a layer; without start it appends.", args: [
            "media_id": "", "track": "Track id or \"new\"",
            "start": "Timeline time or anchor", "duration": "Default 5 for stills, solids, layers", "end": "Instead of duration",
            "source_in": "Source time, word anchor or media@timecode", "source_out": "",
            "mode": "place (exact; default with start), append, overwrite, insert (ripples all tracks)", "speed": "Computed to fit with in, out and duration (fit to fill)",
            "channels": "Source channels (as audio.channels) or \"split\": each channel on its own linked track",
            "audio_tracks": "Tracks for split channels",
            "loop": "Repeat the source range to fill (sound beds)",
            "generator": "Graphic type (catalog lists them); params set it",
            "params": "Generator parameters", "set": "Initial parameters by path",
            "color": "Hex for a solid", "adjustment": "Adjustment layer", "name": "",
            "allow_stretch": "Allow audio below 0.25×",
        ]),
        "text_add": ToolBrief(text: "Add a title, lower third or label on a text layer (or import .srt/.vtt as titles).", args: [
            "text": "\\n breaks lines", "start": "", "end": "", "duration": "Default 3", "track": "",
            "size": "Fraction of the short side, e.g. 0.07", "text_x": "Center, fraction of width", "text_y": "Center, fraction of height",
            "font": "system, rounded, serif, mono or a family", "weight": "100–900", "color": "Hex", "background": "Hex box or none",
            "stroke": "Hex or none", "stroke_width": "Fraction of size", "shadow": "Default true", "letter_spacing": "Fraction of size",
            "max_width": "Fraction of width, default 0.85", "align": "",
            "animation_in": "", "animation_out": "",
            "animator": "Per word/char/line: {unit, preset, stagger, duration, ease, color, out}; null removes",
            "spans": "Style parts: [{match|from,to, color, font, weight, scale, italic, underline, highlight}]; [] clears",
            "spans[].color": "", "spans[].font": "", "spans[].from": "", "spans[].highlight": "", "spans[].italic": "", "spans[].match": "",
            "spans[].scale": "", "spans[].text": "", "spans[].to": "", "spans[].underline": "", "spans[].weight": "",
            "set": "Initial parameters by path", "subtitles": ".srt/.vtt to import as titles", "offset": "Seconds added to subtitle times",
        ]),
        "clip_update": ToolBrief(text: "Move, trim, retime, rename, relink, replace media or retitle a clip. Looks and levels go through param_set.", args: [
            "clip_id": "", "start": "", "track": "Move here (overwrites)", "duration": "Trims the tail", "end": "Trims the tail",
            "source_in": "Trims the head; start stays", "source_out": "", "speed": "Keeps the source range",
            "media_id": "Replace edit: other media, same place and length", "text": "New title words", "name": "",
            "ripple": "Shift later clips on the track", "link": "Clips that move together with it", "unlink": "",
            "allow_stretch": "Allow audio below 0.25×",
        ]),
        "clip_split": ToolBrief(text: "Split one clip, or every clip under a time, at a timeline time.", args: [
            "time": "", "clip_id": "", "track_ids": "",
        ]),
        "clip_delete": ToolBrief(text: "Delete clips; ripple closes the gap on their own tracks only (range_delete keeps sync).", args: ["clip_ids": "", "ripple": ""]),
        "range_delete": ToolBrief(text: "Cut a timeline range out of every track (or track_ids); ripple (default) keeps sync.", args: [
            "start": "", "end": "", "ripple": "Default true", "track_ids": "",
        ]),
        "source_cut": ToolBrief(text: "Cut SOURCE ranges of a media file wherever they play, rippling all tracks: flubs, retakes, words.", args: [
            "media_id": "", "ranges": "[[start, end]] in seconds or word anchors",
        ]),
        "assemble": ToolBrief(text: "Lay source segments end to end on one track, in order: a rough cut from media_transcript.", args: [
            "segments": "[{media_id, start, end}] in source time or word anchors", "segments[].media_id": "", "segments[].start": "", "segments[].end": "",
            "track": "Default V1", "at": "Default the track end", "replace": "Clear the track first", "fit": "",
        ]),
        "cut_silences": ToolBrief(text: "Remove pauses over min_pause (keeping `keep`) and filler words, rippling all tracks.", args: [
            "media_id": "Default every transcribed media", "min_pause": "Default 0.5", "keep": "Default 0.2", "fillers": "Default true",
        ]),
        "track_add": ToolBrief(text: "Add a track; later video tracks draw on top.", args: ["kind": "", "name": "", "position": "Index from the bottom"]),
        "track_update": ToolBrief(text: "Rename, mute, hide, set volume, role, bus output or sends of, or remove a track.", args: [
            "track_id": "", "name": "", "muted": "", "hidden": "", "remove": "", "volume": "0–2", "role": "dialogue, music, effects or custom (stems, captions)",
            "output": "Bus id, or master", "sends": "[{bus, level_db, pre_fader, remove}]; [] clears",
            "sends[].bus": "", "sends[].level_db": "", "sends[].pre_fader": "", "sends[].remove": "",
        ]),
        "audio_bus": ToolBrief(text: "Add, change or remove a submix bus (effects incl. Audio Units, fader, automation, mute/solo, output). Route tracks with track_update output/sends.", args: [
            "bus": "Bus id", "action": "", "name": "", "output": "master or a bus id", "tracks": "Tracks to route into it", "layout": "",
            "volume": "", "gain_db": "", "volume_keys": "[{t, v}] timeline seconds", "muted": "", "solo": "",
            "type": "Effect type, as effect_add", "params": "", "effect_id": "", "index": "", "mix": "", "enabled": "", "remove_effect": "",
        ]),
        "captions_set": ToolBrief(text: "Turn on and style live captions from the transcripts. Presets: karaoke, bold, clean, reveal, minimal.", args: [
            "preset": "", "enabled": "Default true", "animation": "", "font": "", "size": "Fraction of the short side", "weight": "",
            "color": "Hex", "highlight_color": "Hex, spoken word", "background": "Hex or none", "stroke": "Hex or none", "stroke_width": "",
            "uppercase": "", "y": "Center, default 0.82", "max_width": "", "max_words_per_line": "", "max_lines": "Lines at once; longer cues page",
            "replacements": "{\"cut line\": \"Cutline\"}; \"\" deletes", "hidden_words": "Never captioned", "track_ids": "Default the dialogue tracks",
        ]),
        "markers": ToolBrief(text: "Timeline markers (anchors \"marker:<label>\"), or with media_id keyword/rating tags on source ranges.", args: [
            "add": "[{time, end, label, kind, color, note, rating}]", "add[].color": "", "add[].end": "", "add[].kind": "", "add[].label": "",
            "add[].note": "", "add[].rating": "Media tags", "add[].time": "Source time with media_id",
            "update": "[{id, label, kind, note}]", "update[].id": "Id or label", "update[].kind": "", "update[].label": "", "update[].note": "",
            "remove": "Ids or labels", "remove_all": "", "media_id": "Tag this media's source ranges",
        ]),
        "param_set": ToolBrief(text: "Set or animate any parameter by path (transform.*, blend, fade.*, audio.volume/channels/pan_*, text.*, fx.<id>.<param>) or bind it to analysis. Keys [time, value, ease?] in timeline time or anchors; eases in catalog. project_status target=<clip> lists paths.", args: [
            "target": "Clip, track, \"V1/*\", \"group:<id>\", \"master\" or a list",
            "set": "{path: value}", "animate": "{path: [[time, value, ease?], …]}; replaces that path's keys",
            "unset": "Paths to reset", "relative": "Key times from each clip's start",
            "bind": "{path: {source, map, smooth, offset, decay, keep_centered}}; sources beats, downbeats, audio:<media>, face:<media>[:n].x|y|size, track:<id>.x|y|width|height. catalog tool=param_set explains",
        ], hide: ["subframe"]),
        "effect_add": ToolBrief(text: "Add, update (existing id), reorder or remove a picture or audio effect on clips, tracks, adjustment layers or the master. catalog lists types and parameters.", args: [
            "target": "Clip, track, \"V1/*\", \"group:<id>\", \"master\" or a list",
            "type": "Effect type (catalog)", "params": "", "id": "Default from type, e.g. vignette1", "index": "Stack position, 0 first",
            "mix": "0…1", "enabled": "", "remove": "Remove this id (or every effect of type)",
        ]),
        "catalog": ToolBrief(text: "Reference: no arguments lists effects, transitions, blends, eases, paths and anchors. type: one effect; search; paths; recipe: a recipe's arguments; tool: a tool's full manual; plugins: Audio Units.", args: [
            "type": "Effect or transition id", "search": "", "paths": "", "recipe": "Name or \"all\"", "plugins": "", "tool": "Tool name",
        ]),
        "transition_set": ToolBrief(text: "Add, change or remove transitions on cuts (borrowing handles), or in/out over what lies beneath. Types in catalog; part sound/both crossfades audio.", args: [
            "cut": "\"clip_a|clip_b\" or a list", "track": "Every cut on this track (skips misfits)", "from": "Alone: transition out", "to": "Alone: transition in",
            "type": "Default dissolve", "duration": "Default 0.5", "align": "Default center", "ease": "", "part": "Default both",
            "params": "e.g. {\"direction\": \"left\"}", "id": "Existing transition", "remove": "",
        ], hide: ["subframe"]),
        "trim": ToolBrief(text: "Trim an edit: plain, ripple, roll, slip or slide; part audio moves only the sound edge (J/L cut). Give to or by.", args: [
            "clip_id": "", "mode": "Default plain", "edge": "Default end", "to": "Timeline time or anchor for the edge",
            "by": "Seconds, + later (source seconds for slip)", "part": "", "all_tracks": "Ripple every track", "subframe": "Off the frame grid",
        ]),
        "project_patch": ToolBrief(text: "Last resort: RFC 6902 JSON Patch on project.json (project_status detail=json), validated, one undo step.", args: [
            "ops": "[{op, path, value?, from?}]",
        ]),
        "template_save": ToolBrief(text: "Save clips (effects, animation, transitions) as a template for recipe template; {{name}} text or fields become fields.", args: [
            "name": "", "clips": "", "fields": "{placeholder: clip id}", "summary": "",
        ]),
        "sequence_nest": ToolBrief(text: "Nest clips into one sequence clip (one transform, effects, transition for all), or unnest one.", args: [
            "clips": "", "name": "", "unnest": "Nested clip to expand",
        ]),
        "media_track": ToolBrief(text: "Track an object (box or face) or a flat surface (corners) through media, for bind track:<id> or recipe follow.", args: [
            "media_id": "", "at": "Source time of box", "box": "{x, y, width, height} frame fractions", "face": "Face track index instead of box",
            "corners": "[[x,y]×4] TL, TR, BR, BL of a flat surface", "end": "Source time; before at tracks backwards", "label": "", "list": "List tracks",
        ]),
        "analysis_read": ToolBrief(text: "Read analysis compactly: summary, beats, speakers, shots, sounds, faces, levels; without media_id the timeline's beats and jobs. Source seconds.", args: [
            "media_id": "Omit for the timeline", "what": "Default summary", "start": "", "end": "",
            "wait": "Seconds to wait for running analysis (≤600)", "start_missing": "Start analysis that never ran",
        ]),
        "export": ToolBrief(text: "Render the timeline (default HEVC .mp4 in <project>/exports). platform picks the codec and checks shape, length, loudness, true peak and UI-safe text; strict refuses on failures. Also subtitles, chapters, captions, interchange files, stems, stills, archive, variants. catalog tool=export explains every option.", args: [
            "path": "", "platform": "", "strict": "Refuse to export when the platform check fails", "check_only": "Only run the platform checks",
            "hdr": "PQ HEVC: {mastering, max_nits, min_nits, max_cll, max_fall}; MaxCLL/FALL measured when omitted",
            "hdr.mastering": "", "hdr.max_nits": "", "hdr.min_nits": "", "hdr.max_cll": "", "hdr.max_fall": "",
            "preset": "Default hevc; dnxhr_* and xdcam_hd422 need ffmpeg", "container": "mov carries timecode; mxf for DNxHR", "bitrate_mbps": "", "start": "", "end": "",
            "deliver": "Default video; stems is one file per audio role", "audio_format": "", "downmix": "", "image_format": "", "times": "For stills",
            "interlaced": "1080i master: tff or bff", "leader": "Bars, slate, 2-pop: true or {bars, slate, black, pop, version}",
            "leader.bars": "", "leader.black": "", "leader.pop": "", "leader.slate": "", "leader.version": "",
            "timecode_start": "\"hh:mm:ss:ff\" of the program", "subtitles": "Soft subtitles from the transcripts, default none", "subtitle_formats": "srt, vtt, ttml, imsc, ebu-tt-d",
            "subtitle_position": "", "subtitle_speakers": "Color speakers in TTML", "closed_captions": "CEA-608 plus .scc",
            "chapters": "From markers, default with 2+", "interchange": "otio, fcpxml, edl, xml", "trim": "For archive: used parts only",
            "reveal": "", "variants": "[{name, ops: [{tool, args}], …export args}] each applied, exported, then undone",
        ]),
        "timeline_measure": ToolBrief(text: "Measure the export: sound (LUFS, peaks), picture (exposure, clipping, cast per shot, flashes), text (contrast, title-safe), scopes, compare (shot color continuity).", args: [
            "what": "sound, picture, text, scopes, compare; default the first three", "start": "", "end": "", "at": "For scopes",
            "tracks": "Each track's sound too", "platform": "Text against its UI-free area", "reference": "For compare: clip id or time",
        ]),
        "recipe": ToolBrief(text: recipeDescription, args: ["name": "", "args": ""]),
        "batch": ToolBrief(text: "Run edit tools in order as ONE undo step; all or nothing. as:\"x\" names a result for \"$x\" later.", args: [
            "operations": "[{tool, args, as}]", "operations[].tool": "Edit tool", "operations[].args": "", "operations[].as": "",
            "label": "History label", "if_history": "Only if the current entry is this id", "verify": "Timeline times to render after",
        ]),
        "comments_list": ToolBrief(text: "The human's notes pinned to frames. Read at the start of every turn; resolve with comment_reply.", args: [
            "status": "Default open", "frames": "Attach frames, default true",
        ]),
        "comment_reply": ToolBrief(text: "Reply to a comment and resolve it.", args: ["comment_id": "", "text": "", "resolve": "Default true"]),
        "comment_add": ToolBrief(text: "Leave the human a note at a timeline time.", args: ["text": "", "time": ""]),
        "captions_list": ToolBrief(text: "Caption cues with times, text and source words (\"<media>.wN\" for caption_edit), captioned tracks and overlapping speech.", args: [
            "start": "", "end": "",
        ]),
        "caption_edit": ToolBrief(text: "Fix one caption cue (by at or from/to words): text, timing, hide, break_before, merge with the next, or clear edits.", args: [
            "at": "Time inside the cue", "from": "\"<media>.wN\"", "to": "Default from", "text": "", "start_offset": "", "end_offset": "",
            "hidden": "", "break_before": "New cue at the first word", "merge": "Join with the next cue", "clear": "Remove edits on those words",
        ]),
        "transcript_edit": ToolBrief(text: "Fix a transcript: replace words, insert missed words, set or rename speakers.", args: [
            "media_id": "", "from": "\"wN\"", "to": "Default from", "text": "Replacement", "insert": "{start, end, text}",
            "insert.end": "", "insert.start": "", "insert.text": "", "speaker": "", "rename": "{\"S1\": \"Anna\"}",
        ]),
        "media_organize": ToolBrief(text: "Bins, metadata columns, names, camera log encoding and scan of media.", args: [
            "media_ids": "", "bin": "\"A/B\"; \"\" removes", "metadata": "{column: value}; \"\" removes", "name": "One media only",
            "log": "Camera log encoding, or none", "signal_range": "Log code values: video (default) or full",
            "deinterlace": "", "field_order": "",
        ]),
        "media_list": ToolBrief(text: "List media with bins, metadata, tags, format, channels and use; filter and sort.", args: [
            "bin": "", "search": "Names, metadata, tags, transcripts", "keyword": "", "rating": "", "kind": "", "unused": "", "sort": "Any column",
        ]),
        "timeline_import": ToolBrief(text: "Import an .fcpxml, .otio, .edl or FCP7 .xml as a new current timeline, matching the project's media.", args: [
            "path": "", "name": "", "edl_fps": "Default the project's",
        ]),
        "timelines": ToolBrief(text: "Several timelines per project: list, new (duplicate copies the current), switch, rename, delete.", args: [
            "action": "", "name": "", "new_name": "For rename", "duplicate": "For new",
        ]),
    ]

    /// The tool as tools/list shows it.
    static func listing(_ t: Tool) -> JSON {
        let brief = briefs[t.name]
        var schema = t.schema
        if case .object(var o) = schema, case .object(var props)? = o["properties"] {
            for k in brief?.hide ?? [] { props[k] = nil }
            o["properties"] = .object(props.reduce(into: [:]) { out, kv in out[kv.key] = compact(kv.value, path: kv.key, brief: brief) })
            schema = .object(o)
        }
        return ["name": .string(t.name), "description": .string(brief?.text ?? t.description), "inputSchema": schema]
    }

    private static func compact(_ s: JSON, path: String, brief: ToolBrief?) -> JSON {
        guard case .object(var o) = s else { return s }
        if path == "dry_run" { o["description"] = nil }
        if let short = brief?.args[path] { o["description"] = short.isEmpty ? nil : .string(short) }
        if let e = o["enum"]?.array, e.count > listedEnumLimit { o["enum"] = nil }
        if case .object(let props)? = o["properties"] {
            o["properties"] = .object(props.reduce(into: [:]) { out, kv in out[kv.key] = compact(kv.value, path: path + "." + kv.key, brief: brief) })
        }
        if let items = o["items"] { o["items"] = compact(items, path: path + "[]", brief: brief) }
        return .object(o)
    }

    /// catalog tool=<name>: the full description and every argument with its type, values and full description.
    func toolManual(_ name: String) throws -> String {
        guard let t = tools[name] else {
            let close = order.map { ($0, editDistance($0, name)) }.filter { $0.1 <= max(2, name.count / 3) }.sorted { $0.1 < $1.1 }.prefix(3).map(\.0)
            throw EditError("No tool \(name)" + (close.isEmpty ? ". Tools: \(order.joined(separator: ", "))" : "; did you mean \(close.joined(separator: " or "))?"))
        }
        var lines = ["\(name): \(t.description)"]
        func walk(_ s: JSON, _ indent: String) {
            let required = Set(s["required"]?.array?.compactMap(\.string) ?? [])
            for (k, v) in (s["properties"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                var kind = v["type"].map { $0.string ?? ($0.array ?? []).compactMap(\.string).joined(separator: "|") } ?? "value"
                if let values = v["enum"]?.array?.compactMap(\.string) { kind += ": " + values.joined(separator: ", ") }
                lines.append("\(indent)\(k) (\(kind)\(required.contains(k) ? ", required" : ""))" + (v["description"]?.string.map { ": " + $0 } ?? ""))
                walk(v, indent + "  ")
                if let items = v["items"] { walk(items, indent + "  ") }
            }
        }
        walk(t.schema, "  ")
        return lines.joined(separator: "\n")
    }
}
