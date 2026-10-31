import Foundation

/// A word from Premiere, Final Cut or Resolve and what does it here.
struct EditorTerm {
    let term: String
    /// Other names for it, in any of the apps.
    let aliases: String
    /// What it maps to, or why it isn't available and the nearest option.
    let summary: String
    let calls: [(String, String)]
}

extension Toolbox {
    /// Premiere, Final Cut Pro and Resolve vocabulary for catalog search.
    static let editorTerms: [EditorTerm] = [
        // Editing
        EditorTerm(term: "Compound clip", aliases: "compound clip, nested sequence, nest, precompose, pre-comp, group clips, fcp compound", summary: "Final Cut's compound clip / Premiere's nested sequence / After Effects precomp: sequence_nest groups clips into one clip with one transform, effect stack and transition; unnest expands it.", calls: [
            ("sequence_nest", #"{"clips":["<clip_a>","<clip_b>"],"name":"Montage"}"#),
        ]),
        EditorTerm(term: "Multicam", aliases: "multicam, multi-camera, multicamera clip, angle switching, live switch, angle viewer", summary: "multicam_create syncs angles (audio, timecode, markers or in points) into one clip; multicam_cut switches angles; recipe multicam_switch cuts to whoever speaks.", calls: [
            ("multicam_create", #"{"angles":["<cam_a>","<cam_b>"],"sync":"audio"}"#),
            ("multicam_cut", #"{"clip":"<multicam clip>","angle":2,"at":12.5}"#),
        ]),
        EditorTerm(term: "Proxy", aliases: "proxy, proxies, proxy media, optimized media, offline media, transcode for editing, render cache, playback resolution, lower playback resolution", summary: "Preview plays ProRes Proxy copies of heavy footage (over 2560 px, over 60 fps, 10-bit long GOP); export always reads originals. media_organize proxy auto/always/never per file, canvas_set playback auto/proxy/original and proxy_size half/quarter/1080/720 for the project, media_analyze proxy:true (re)makes them; media_list shows their state.", calls: [
            ("canvas_set", #"{"playback":"proxy","proxy_size":"quarter"}"#),
            ("media_organize", #"{"media_ids":["<media>"],"proxy":"always"}"#),
            ("media_analyze", #"{"media_id":"all","proxy":true}"#),
        ]),
        EditorTerm(term: "Three-point edit", aliases: "three point edit, 3-point edit, four point edit, in and out points, mark in mark out, source monitor, edit to timeline", summary: "Source in/out plus a timeline in point: clip_add with media_id, source_in, source_out and start; mode overwrite replaces what is there, insert ripples everything later (all tracks).", calls: [
            ("clip_add", #"{"media_id":"<media>","source_in":"<media>.w10","source_out":"<media>.w42.end","start":30,"mode":"overwrite"}"#),
        ]),
        EditorTerm(term: "Insert edit", aliases: "insert edit, insert, splice in, ripple insert, comma key", summary: "clip_add mode:\"insert\" places the clip at start and pushes everything after it later on every track, keeping sync.", calls: [
            ("clip_add", #"{"media_id":"<media>","start":12,"source_in":4,"source_out":9,"mode":"insert"}"#),
        ]),
        EditorTerm(term: "Overwrite edit", aliases: "overwrite edit, overwrite, period key, overlay edit, record over", summary: "clip_add mode:\"overwrite\" lays the clip over whatever is on the track for its length, without moving anything.", calls: [
            ("clip_add", #"{"media_id":"<media>","start":12,"source_in":4,"source_out":9,"mode":"overwrite"}"#),
        ]),
        EditorTerm(term: "Replace edit", aliases: "replace edit, swap clip, replace with clip, replace footage, swap shot, relink to other take", summary: "clip_update media_id swaps the media under a clip, keeping its place, length, effects and animation; source_in picks the frame that lines up.", calls: [
            ("clip_update", #"{"clip_id":"<clip>","media_id":"<other media>","source_in":3.2}"#),
        ]),
        EditorTerm(term: "Fit to fill", aliases: "fit to fill, retime to fit, stretch to gap, speed to fill", summary: "Give source_in, source_out and a timeline start and end: clip_add computes the speed that fills the span (allow_stretch for sound).", calls: [
            ("clip_add", #"{"media_id":"<media>","source_in":2,"source_out":8,"start":20,"end":24,"mode":"overwrite","allow_stretch":true}"#),
        ]),
        EditorTerm(term: "Append", aliases: "append, append at end, add to end of sequence, e key", summary: "clip_add without start (or mode append) adds the clip after the track's last clip.", calls: [
            ("clip_add", #"{"media_id":"<media>","mode":"append"}"#),
        ]),
        EditorTerm(term: "Ripple edit", aliases: "ripple, ripple trim, ripple delete, close gap, ripple tool", summary: "trim mode ripple moves an edge and shifts everything after it (all_tracks keeps sync); clip_delete ripple closes the gap; range_delete ripples by default.", calls: [
            ("trim", #"{"clip_id":"<clip>","edge":"end","mode":"ripple","by":-0.5,"all_tracks":true}"#),
            ("clip_delete", #"{"clip_ids":["<clip>"],"ripple":true}"#),
        ]),
        EditorTerm(term: "Roll edit", aliases: "roll, rolling edit, roll trim, move the cut", summary: "trim mode roll moves the cut between two touching clips: one gets longer, the other shorter, nothing else moves.", calls: [
            ("trim", #"{"clip_id":"<clip>","edge":"end","mode":"roll","by":0.4}"#),
        ]),
        EditorTerm(term: "Slip edit", aliases: "slip, slip tool, change source in place", summary: "trim mode slip changes which part of the source plays without moving or resizing the clip.", calls: [
            ("trim", #"{"clip_id":"<clip>","mode":"slip","by":1.0}"#),
        ]),
        EditorTerm(term: "Slide edit", aliases: "slide, slide tool, move clip between neighbours", summary: "trim mode slide moves a clip along the track, trimming its neighbours to keep the edit's length.", calls: [
            ("trim", #"{"clip_id":"<clip>","mode":"slide","by":-0.5}"#),
        ]),
        EditorTerm(term: "Lift", aliases: "lift, lift edit, remove leaving gap, semicolon key", summary: "range_delete ripple:false removes a range and leaves a gap (Premiere lift).", calls: [
            ("range_delete", #"{"start":10,"end":14,"ripple":false}"#),
        ]),
        EditorTerm(term: "Extract", aliases: "extract, extract edit, remove and close, ripple delete range, apostrophe key", summary: "range_delete (ripple default) removes a range from every track and closes it up, keeping sync.", calls: [
            ("range_delete", #"{"start":10,"end":14}"#),
        ]),
        EditorTerm(term: "Blade", aliases: "blade, razor, add edit, cut tool, split at playhead, cmd b, ctrl k", summary: "clip_split cuts one clip, or every clip under the time, at a timeline time.", calls: [
            ("clip_split", #"{"at":12.5}"#),
        ]),
        EditorTerm(term: "J-cut and L-cut", aliases: "j cut, l cut, j-cut, l-cut, split edit, audio leads, audio trails, prelap", summary: "recipe split_edit: + starts the next clip's sound early (J), − runs the first clip's sound on (L); trim part:\"audio\" moves only a sound edge.", calls: [
            ("recipe", #"{"name":"split_edit","args":{"edit":"<clip_a>|<clip_b>","offset":0.5}}"#),
            ("trim", #"{"clip_id":"<clip>","edge":"start","part":"audio","by":-0.5}"#),
        ]),
        EditorTerm(term: "Match frame", aliases: "match frame, reveal in source, find source frame, show in browser, f key", summary: "project_status target=<clip> lists its source in/out; media_frames shows that source frame; clip_add source_in from it lays the same frame again.", calls: [
            ("project_status", #"{"target":"<clip>"}"#),
            ("media_frames", #"{"media_id":"<media>","times":[12.4]}"#),
        ]),
        EditorTerm(term: "Storyline", aliases: "storyline, primary storyline, magnetic timeline, connected clip, secondary storyline, fcp spine", summary: "No magnetic timeline: tracks hold clips at times. V1 plays the main story; clip_add track \"new\" adds connected b-roll above; insert and ripple edits keep later clips in sync like the magnetic timeline.", calls: [
            ("clip_add", #"{"media_id":"<broll>","track":"new","start":"<media>.w20"}"#),
        ]),
        EditorTerm(term: "Gap", aliases: "gap, gap clip, filler, slug, black filler, spacer", summary: "Empty time on a track plays black (or what is below); a solid clip_add color fills it; range_delete closes gaps; project_status warns about them.", calls: [
            ("clip_add", ##"{"color":"#000000","start":10,"duration":2}"##),
        ]),
        EditorTerm(term: "Sequence", aliases: "sequence, timeline, edit, project timeline, new sequence, duplicate sequence, versions", summary: "timelines: several timelines in one project (new, duplicate, switch, rename) sharing media; every tool edits the current one.", calls: [
            ("timelines", #"{"action":"new","name":"Trailer","duplicate":true}"#),
        ]),
        EditorTerm(term: "Bins", aliases: "bin, bins, folder, keyword collection, smart collection, project panel, media pool, browser", summary: "media_organize bin and metadata columns; markers media_id adds keyword and rating ranges; media_list filters and sorts like a list view.", calls: [
            ("media_organize", #"{"media_ids":["<media>"],"bin":"Interviews/Day 1","metadata":{"scene":"12","take":"3"}}"#),
            ("media_list", #"{"bin":"Interviews"}"#),
        ]),
        EditorTerm(term: "Subclip", aliases: "subclip, favorite range, select range, keyword range, rating, reject", summary: "markers with media_id tags a source range (keyword, favorite or reject); clip_add source_in/source_out places just that range.", calls: [
            ("markers", #"{"media_id":"<media>","add":[{"time":12,"end":18,"label":"best take","rating":"favorite"}]}"#),
        ]),
        EditorTerm(term: "Markers", aliases: "marker, markers, chapter marker, to-do marker, comment marker, locator", summary: "markers adds timeline markers (anchors marker:<label>, chapters on export); comment_add leaves the human a note.", calls: [
            ("markers", #"{"add":[{"time":12,"label":"Act 2"}]}"#),
        ]),
        EditorTerm(term: "Through edit", aliases: "through edit, join through edit, heal edit, unnecessary cut", summary: "project_status warns about cuts with continuous source; clip_delete the second piece and trim the first to its end, or history undo the split.", calls: [
            ("trim", #"{"clip_id":"<clip>","edge":"end","to":"<next clip>.end"}"#),
        ]),
        EditorTerm(term: "Freeze frame", aliases: "freeze frame, hold frame, frame hold, still frame", summary: "recipe freeze_frame holds a frame for a duration, rippling the rest.", calls: [
            ("recipe", #"{"name":"freeze_frame","args":{"clip":"<clip>","at":12,"duration":1.5}}"#),
        ]),
        EditorTerm(term: "Speed ramp", aliases: "speed ramp, time remapping, retime, variable speed, slow mo, optical flow, frame blending, time warp", summary: "recipe speed_ramp, or param_set time.speed; time.interpolate blend or flow (optical flow) smooths slow motion; time.reverse plays backwards.", calls: [
            ("recipe", #"{"name":"speed_ramp","args":{"clip":"<clip>","speed":0.3}}"#),
            ("param_set", #"{"target":"<clip>","set":{"time.speed":0.5,"time.interpolate":"flow"}}"#),
        ]),
        EditorTerm(term: "Adjustment layer", aliases: "adjustment layer, adjustment clip, adjustment track, effect layer, fx layer", summary: "clip_add adjustment:true on a new track; effect_add on it acts on every layer below for its duration.", calls: [
            ("clip_add", #"{"adjustment":true,"track":"new","start":0,"duration":10}"#),
            ("effect_add", #"{"target":"<adjustment clip>","type":"color.look","params":{"look":"teal_orange"}}"#),
        ]),
        EditorTerm(term: "Track matte", aliases: "track matte, track matte key, alpha matte, luma matte, set matte, travel matte", summary: "mask.matte shows a clip only where another track's picture (alpha or luma) is; hide the matte track.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"mask.matte","params":{"track":"V3","mode":"luma"}}"#),
        ]),
        EditorTerm(term: "Luma key", aliases: "luma key, luminance key, key out black, key out white, screen blend fire smoke, lumakey", summary: "key.luma keeps a brightness range and keys the rest (fire or titles shot on black: low 0.1; on white: high 0.9) with matte cleanup; timeline_frames view:\"matte\" shows it.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"key.luma","params":{"low":0.1,"softness":0.1}}"#),
        ]),
        EditorTerm(term: "Difference key", aliases: "difference key, difference matte, clean plate key, background subtraction, locked off key", summary: "key.difference keeps what differs from a clean plate (an image, or plate_at a frame of the same media) for a locked-off shot without a green screen.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"key.difference","params":{"plate_at":0.5,"threshold":0.08}}"#),
        ]),
        EditorTerm(term: "Sky replacement", aliases: "sky replacement, replace sky, sky swap, new sky, sky mask, sky keyer", summary: "recipe sky_replace keys the sky with mask.sky (a heuristic: bright, smooth, sky-colored region touching the top), puts the new sky under it and relights the foreground. Check the matte; hair, branches, haze and night skies are hard.", calls: [
            ("recipe", #"{"name":"sky_replace","args":{"clip":"<clip>","image":"/path/to/sky.jpg","blend":0.5}}"#),
        ]),
        EditorTerm(term: "Roto", aliases: "rotoscope, roto, roto brush, magic mask, object mask, garbage matte, bezier mask", summary: "mask.shape draws a pen mask (recipe track_mask makes it follow; mode person or subject redraws it from the matte outline every frame; correct:[{at, points}] fixes a drifting frame); mask.object rotos a tracked object; mask.person and mask.subject segment people and subjects.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"mask.shape","params":{"points":"0.3,0.3 0.7,0.3 0.7,0.7 0.3,0.7","feather":0.01}}"#),
            ("recipe", #"{"name":"track_mask","args":{"clip":"<clip>","mode":"points","refine":"person"}}"#),
            ("recipe", #"{"name":"track_mask","args":{"clip":"<clip>","mode":"person"}}"#),
            ("recipe", #"{"name":"track_mask","args":{"clip":"<clip>","mode":"points","correct":[{"at":2.5,"points":"0.31,0.2 0.52,0.21 0.55,0.9 0.29,0.9"}]}}"#),
        ]),
        // Color
        EditorTerm(term: "Power window", aliases: "power window, window, vignette mask, shape mask, circle mask, secondary window, mask grade", summary: "Any color, blur or stylize effect takes limit rect or ellipse (limit_x, limit_y, limit_width, limit_height, limit_feather, limit_invert); bind it to a face or track to follow.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"color.wheels","params":{"gain":0.15,"limit":"ellipse","limit_width":0.4,"limit_height":0.5,"limit_feather":0.1}}"#),
        ]),
        EditorTerm(term: "Qualifier", aliases: "qualifier, hsl qualifier, secondary, key a color, eyedropper, color isolation, hsl secondary", summary: "limit qualifier keys an effect to a hue/saturation/luma range with matte cleanup; recipe qualify samples it from the picture.", calls: [
            ("recipe", #"{"name":"qualify","args":{"clip":"<clip>","x":0.5,"y":0.4,"type":"color.wheels"}}"#),
        ]),
        EditorTerm(term: "Node", aliases: "node, nodes, serial node, parallel node, layer mixer, node tree, node graph", summary: "Effect parameters node, node_mode (serial, parallel, layer, outside), node_blend and node_opacity group effects into Resolve-style grade nodes.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"color.wheels","params":{"node":"skin","node_mode":"parallel","gain":0.1}}"#),
        ]),
        EditorTerm(term: "LUT", aliases: "lut, 3d lut, cube, look up table, input lut, output lut, show lut", summary: "color.lut applies a .cube; export bake_luts writes each clip's grade as a .cube for a colorist.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"color.lut","params":{"file":"/path/to/look.cube"}}"#),
        ]),
        EditorTerm(term: "Color space transform", aliases: "cst, color space transform, idt, input transform, log to rec709, aces, color management, rcm, odt", summary: "Set a clip's camera log encoding (media_organize log) and it is converted into the canvas space with an ACES-style tone map (input.tone, input.exposure); canvas_set color_space picks rec709, p3 or HDR.", calls: [
            ("media_organize", #"{"media_ids":["<media>"],"log":"slog3_sgamut3"}"#),
            ("param_set", #"{"target":"<clip>","set":{"input.tone":"aces","input.exposure":0.3}}"#),
        ]),
        EditorTerm(term: "Color wheels", aliases: "color wheels, lift gamma gain, primaries, offset, lumetri, color board, three way color", summary: "color.wheels: lift, gamma, gain, offset per channel, temperature, tint, contrast, saturation; color.cdl for ASC CDL.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"color.wheels","params":{"lift":-0.02,"gain":0.08,"temperature":10}}"#),
        ]),
        EditorTerm(term: "Curves", aliases: "curves, rgb curves, hue vs hue, hue vs sat, hue curves, luma vs sat", summary: "color.curves for tone curves, color.hue_curves for hue-vs-hue/sat/luma.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"color.curves"}"#),
        ]),
        EditorTerm(term: "Scopes", aliases: "scopes, waveform, parade, rgb parade, vectorscope, histogram, video scopes, false color", summary: "timeline_measure what:[\"scopes\"] renders waveform, RGB parade, vectorscope and histogram with their numbers; what picture checks exposure, clipping and color cast per shot.", calls: [
            ("timeline_measure", #"{"what":["scopes"],"at":12}"#),
        ]),
        EditorTerm(term: "Shot match", aliases: "shot match, color match, match shots, compare shots, still store, gallery, reference still", summary: "recipe match_color matches clips to a reference; timeline_measure what compare reports shot-to-shot differences.", calls: [
            ("recipe", #"{"name":"match_color","args":{"clips":["<clip_a>","<clip_b>"],"reference":"<reference clip>"}}"#),
        ]),
        EditorTerm(term: "Grade groups", aliases: "group grade, color group, pre-clip post-clip, shared node, apply grade to all, copy grade, paste attributes", summary: "recipe grade_group gives clips one shared effect changed together through target group:<id>.", calls: [
            ("recipe", #"{"name":"grade_group","args":{"clips":["<clip_a>","<clip_b>"],"id":"scene12"}}"#),
        ]),
        EditorTerm(term: "HDR grading", aliases: "hdr, hdr10, hlg, pq, nits, hdr grade, hdr zones, tone mapping", summary: "canvas_set color_space rec2020_pq or rec2020_hlg; color.hdr_zones grades by zone; export writes HDR10 metadata (hdr) and sdr_from_hdr makes the SDR version.", calls: [
            ("canvas_set", #"{"color_space":"rec2020_pq"}"#),
        ]),
        EditorTerm(term: "Dolby Vision", aliases: "dolby vision, dovi, dolby vision metadata, trim pass, cmu", summary: "Not available: no Dolby Vision metadata or trim passes are written. Nearest: an HDR10 (PQ) master with static metadata, plus an SDR version made by tone mapping (export sdr_from_hdr).", calls: [
            ("export", #"{"path":"master_hdr10.mov","preset":"prores_hq","hdr":{}}"#),
        ]),
        // Audio
        EditorTerm(term: "Roles", aliases: "roles, audio roles, subroles, dialogue role, music role, effects role, track role", summary: "track_update role sets a track's role (dialogue, music, effects or any name); param_set audio.role \"dialogue.room tone\" gives a clip a subrole; stems and M&E follow roles.", calls: [
            ("track_update", #"{"track":"A2","role":"music"}"#),
            ("param_set", #"{"target":"<clip>","set":{"audio.role":"dialogue.boom"}}"#),
        ]),
        EditorTerm(term: "Stems", aliases: "stems, dme, dialogue music effects, m&e, music and effects, split tracks, audio stems", summary: "export deliver:\"stems\" writes one file per role; audio_tracks puts mix, M&E and stems on a master's tracks; recipe dme_buses builds DIA/MUS/FX buses.", calls: [
            ("export", #"{"deliver":"stems","path":"stems/"}"#),
            ("recipe", #"{"name":"dme_buses","args":{}}"#),
        ]),
        EditorTerm(term: "Surround 5.1 mix", aliases: "surround, 5.1, 7.1, surround mix, 5.1 mix, panner, lfe, center channel, multichannel mix, fairlight", summary: "param_set target master layout surround51 (or surround71) makes the mix surround; audio.pan_x, pan_y, center and lfe pan clips; export downmix and audio_tracks netflix_51_20 deliver it.", calls: [
            ("param_set", #"{"target":"master","set":{"layout":"surround51"}}"#),
            ("param_set", #"{"target":"<clip>","set":{"audio.pan_x":-0.5,"audio.pan_y":0.8}}"#),
        ]),
        EditorTerm(term: "Submix bus", aliases: "bus, submix, aux, send, return, audio bus, bus track, mixer", summary: "audio_bus adds a submix bus with effects; track_update output and sends route tracks to it.", calls: [
            ("audio_bus", #"{"bus":"DIA","tracks":["A1"],"type":"audio.compressor"}"#),
        ]),
        EditorTerm(term: "Audio keyframes", aliases: "rubber band, volume keyframes, audio automation, fader automation, clip gain, volume envelope", summary: "param_set animate audio.volume keys on a clip; param_set on a track animates its volume fader.", calls: [
            ("param_set", #"{"target":"<clip>","animate":{"audio.volume":[[0,1],[2,0.3,"easeInOut"]]}}"#),
        ]),
        EditorTerm(term: "Loudness", aliases: "loudness, lufs, loudness normalization, ebu r128, atsc a85, true peak, loudness meter", summary: "recipe loudness_normalize sets integrated loudness and a true-peak ceiling; timeline_measure what sound reports LUFS.", calls: [
            ("recipe", #"{"name":"loudness_normalize","args":{"target_lufs":-23,"ceiling_db":-1}}"#),
        ]),
        EditorTerm(term: "Dialogue cleanup", aliases: "voice isolation, dialogue isolation, enhance speech, noise reduction audio, de-noise, de-hum, de-ess, de-reverb, repair", summary: "audio.voice_isolation and the repair effects (noise, hum, sibilance, clicks, reverb) on clips or tracks; recipe spectral_repair for coughs, bumps and beeps.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"audio.voice_isolation","params":{"amount":0.8}}"#),
        ]),
        EditorTerm(term: "Dialogue leveler", aliases: "dialogue leveler, auto match, auto level, clip gain, gain rides, riding levels, rubber banding dialogue", summary: "Resolve's Dialogue Leveler / Premiere's Auto Match: recipe clip_gain_ride writes per-phrase audio.volume keys to a target (−23 LUFS for a DME mix); audio.leveler levels live.", calls: [
            ("recipe", #"{"name":"clip_gain_ride","args":{"clips":["<clip>"],"target_lufs":-23,"max_db":10}}"#),
        ]),
        EditorTerm(term: "Spectral repair", aliases: "izotope rx, spectral repair, spectral editing, de-click, de-plosive, de-cough, remove beep, resolve fairlight repair", summary: "recipe spectral_repair rebuilds a time range and band from the surrounding sound (or attenuates it) and lists detected clicks, thumps and tones; recipe match_eq is RX's EQ Match.", calls: [
            ("recipe", #"{"name":"spectral_repair","args":{"clip":"<clip>","at":5.2,"duration":0.25}}"#),
        ]),
        EditorTerm(term: "Sync clips", aliases: "synchronize clips, merge clips, sync sound, dual system sound, waveform sync, pluraleyes", summary: "recipe sync_audio lines up a separate recorder with the camera by waveform.", calls: [
            ("recipe", #"{"name":"sync_audio","args":{"audio":"<recorder media>"}}"#),
        ]),
        EditorTerm(term: "Voice-over", aliases: "voice over, voiceover, record voice, adr, narration, record audio", summary: "voiceover_record records takes in the preview app and places the best one in sync.", calls: [
            ("voiceover_record", #"{"start":10,"end":20,"script":"Narration text"}"#),
        ]),
        // Titles and graphics
        EditorTerm(term: "Burn-in timecode", aliases: "burn in timecode, timecode burn, tc burn in, burnt in timecode, window burn, bitc, burn-in, timecode overlay, review copy, watermark", summary: "clip_add generator timecode_burn on a new top track shows record and/or source timecode, clip name, frame count, reel and a watermark for review copies.", calls: [
            ("clip_add", #"{"generator":"timecode_burn","track":"new","start":0,"duration":60,"params":{"show":"record,source,clip","position":"bottom","watermark":"CONFIDENTIAL"}}"#),
        ]),
        EditorTerm(term: "Rolling credits", aliases: "credits, end credits, rolling credits, credit roll, crawl, scroll titles, end crawl", summary: "clip_add generator credits rolls (or crawls) \"# Title\", \"## Heading\" and \"Role | Name\" lines over the clip's duration; end_hold holds the last lines.", calls: [
            ("clip_add", ##"{"generator":"credits","track":"new","start":"end","duration":20,"params":{"text":"# THE END\n## Cast\nCaptain | Ada Lovelace","end_hold":3,"background":"#000000"}}"##),
        ]),
        EditorTerm(term: "Essential graphics", aliases: "essential graphics, mogrt, motion graphics template, title template, generator, fusion title", summary: "Generators (lower thirds, title.* presets, shapes, counters, credits) via clip_add generator; template_save turns clips into reusable templates.", calls: [
            ("clip_add", #"{"generator":"title.lower_third_modern","track":"new","start":5,"duration":4,"params":{"title":"Ada Lovelace"}}"#),
        ]),
        EditorTerm(term: "Shape layer", aliases: "shape layer, trim paths, stroke animation, vector shapes, path animation", summary: "clip_add generator shape; animate a shape's properties as fx.gen.<shape id>.<property> (e.g. fx.gen.ring.trim_end), other generators as fx.gen.<param>.", calls: [
            ("param_set", #"{"target":"<clip>","relative":true,"animate":{"fx.gen.ring.trim_end":[[0,0],[0.8,1,"easeOut"]]}}"#),
        ]),
        EditorTerm(term: "Keyframes", aliases: "keyframe, keyframes, animate, motion, position scale rotation, ease, bezier, graph editor", summary: "param_set animate takes [time, value, ease] keys on any path (transform.*, fx.<id>.<param>, text.*); catalog lists eases.", calls: [
            ("param_set", #"{"target":"<clip>","animate":{"transform.scale":[[0,1],[4,1.2,"easeInOut"]]}}"#),
        ]),
        EditorTerm(term: "Expressions", aliases: "expression, wiggle, loopout, time expression, pick whip, link parameters", summary: "param_set bind with source wiggle, time, loop or link:<clip>.<path> adds procedural motion.", calls: [
            ("param_set", #"{"target":"<clip>","bind":{"transform.x":{"source":"wiggle","freq":2,"amp":0.01}}}"#),
        ]),
        EditorTerm(term: "Tracking", aliases: "motion tracking, tracker, planar tracker, mocha, track point, attach to track, stick", summary: "media_track tracks a box, face or surface; recipe follow pins a clip to it; corner_pin with a surface track replaces a screen.", calls: [
            ("media_track", #"{"media_id":"<media>","at":5,"box":{"x":0.4,"y":0.4,"width":0.1,"height":0.1}}"#),
        ]),
        EditorTerm(term: "Picture in picture", aliases: "picture in picture, pip, inset, transform box, crop and position", summary: "recipe pip puts a clip in a corner; transform.* and crop do it by hand.", calls: [
            ("recipe", #"{"name":"pip","args":{"clip":"<clip>","corner":"top_right"}}"#),
        ]),
        EditorTerm(term: "Reframe", aliases: "auto reframe, smart conform, reframe, aspect ratio, 9:16, vertical crop, social crop", summary: "recipe reframe changes the aspect and keeps faces or subjects in frame.", calls: [
            ("recipe", #"{"name":"reframe","args":{"aspect":"9:16"}}"#),
        ]),
        // Finishing and delivery
        EditorTerm(term: "Render queue", aliases: "render queue, deliver page, export queue, batch export, media encoder, adobe media encoder, compressor, deliverables", summary: "export variants renders several versions in one call (each with its own ops, platform, path); deliver picks video, audio, stems, stills, image sequences or archives.", calls: [
            ("export", #"{"path":"master.mov","preset":"prores_hq","variants":[{"name":"vertical","platform":"tiktok","ops":[{"tool":"recipe","args":{"name":"reframe","args":{"aspect":"9:16"}}}]}]}"#),
        ]),
        EditorTerm(term: "Master file", aliases: "master, mezzanine, prores master, broadcast master, textless, deliverable spec, qc", summary: "export preset prores_hq (or dnxhr_hq, xdcam_hd422) with platform broadcast or netflix_master checks the spec; audio_tracks lays out mix, M&E and stems.", calls: [
            ("export", #"{"path":"master.mov","preset":"prores_hq","platform":"netflix_master","audio_tracks":"netflix_51_20_me"}"#),
        ]),
        EditorTerm(term: "IMF", aliases: "imf, interoperable master format, imp, cpl, smpte st 2067", summary: "Not available: IMF packages (CPL, OPL, MXF track files) aren't written. Nearest: a ProRes or DNxHR MXF master with its audio layout, IMSC subtitles and timecode, wrapped by an IMF tool afterwards.", calls: [
            ("export", #"{"path":"master.mxf","preset":"dnxhr_hqx","container":"mxf","subtitles":"imsc"}"#),
        ]),
        EditorTerm(term: "DCP", aliases: "dcp, digital cinema package, cinema delivery, jpeg2000, dci", summary: "Not available: no DCP (JPEG 2000 in MXF, XYZ, CPL). Nearest: a ProRes 4444 XQ or ProRes HQ master at 24 fps for a DCP tool such as DCP-o-matic.", calls: [
            ("export", #"{"path":"for_dcp.mov","preset":"prores4444xq"}"#),
        ]),
        EditorTerm(term: "XML and EDL interchange", aliases: "xml, fcpxml, edl, aaf, otio, omf, send to resolve, send to pro tools, round trip, conform, turnover", summary: "export interchange writes otio, fcpxml, edl, FCP7 xml and aaf (with handles); timeline_import reads them back; bake_luts sends the grade as .cube files.", calls: [
            ("export", #"{"path":"turnover.mov","interchange":["aaf","xml","edl"],"aaf_handles":2}"#),
            ("timeline_import", #"{"path":"/path/to/edit.fcpxml"}"#),
        ]),
        EditorTerm(term: "OMF", aliases: "omf, omfi, audio turnover legacy", summary: "Not available: OMF isn't written. Nearest: AAF with embedded-free linked media and handles, which Pro Tools and Resolve read.", calls: [
            ("export", #"{"path":"audio_turnover.mov","interchange":["aaf"],"aaf_handles":3}"#),
        ]),
        EditorTerm(term: "Media management", aliases: "media manager, consolidate, collect files, project archive, trim project, backup project", summary: "export deliver:\"archive\" copies the project and its media (trim:true keeps only used parts plus handles).", calls: [
            ("export", #"{"deliver":"archive","path":"/Volumes/Backup/Project","trim":true}"#),
        ]),
        EditorTerm(term: "Relink", aliases: "relink, reconnect media, offline media, missing media, locate media", summary: "media_relink finds offline files by name or reel and timecode; media_import relink:true searches folders.", calls: [
            ("media_relink", #"{"folder":"/Volumes/Media","match":"both"}"#),
        ]),
        EditorTerm(term: "Captions", aliases: "closed captions, cea-608, cea 608, scc, subtitles, open captions, srt, sdh", summary: "captions_set turns on live captions; export subtitles writes srt/vtt/ttml/imsc sidecars or embeds them, closed_captions writes CEA-608.", calls: [
            ("export", #"{"path":"out.mov","subtitles":"sidecar","closed_captions":true}"#),
        ]),
        EditorTerm(term: "Leader and slate", aliases: "bars and tone, slate, leader, countdown, head leader, 2-pop, academy leader", summary: "export leader adds bars and tone, slate and countdown before the program.", calls: [
            ("export", #"{"path":"master.mov","preset":"prores_hq","leader":{}}"#),
        ]),
        EditorTerm(term: "Timecode", aliases: "start timecode, sequence timecode, drop frame, non drop, source timecode, tc", summary: "canvas_set timecode_start and drop_frame set the timeline's timecode; \"<media>@01:00:12:10\" anchors a source timecode; timecode_burn shows it on the picture.", calls: [
            ("canvas_set", #"{"timecode_start":"10:00:00:00"}"#),
        ]),
        EditorTerm(term: "Render in to out", aliases: "render in to out, render selection, smart render, render preview, red bar, render cache", summary: "Nothing to render by hand: the preview plays effects live, temporal effects render in the background, and export renders from the originals; proxies make heavy footage play.", calls: [
            ("timeline_frames", #"{"start":10,"end":14,"count":4}"#),
        ]),
        EditorTerm(term: "Interlacing", aliases: "interlaced, fields, deinterlace, field order, 1080i, upper field first", summary: "media_organize field_order and deinterlace; export interlaced tff/bff weaves an interlaced master.", calls: [
            ("media_organize", #"{"media_ids":["<media>"],"deinterlace":"auto","field_order":"tff"}"#),
        ]),
        EditorTerm(term: "Frame rate conversion", aliases: "frame rate conversion, conform frame rate, 23.976 to 25, pulldown, change sequence frame rate", summary: "canvas_set fps conforms the timeline to the new frame grid (conform snap or keep_frames); time.interpolate flow smooths retimed clips.", calls: [
            ("canvas_set", #"{"fps":25,"conform":"snap"}"#),
        ]),
        EditorTerm(term: "Stabilization", aliases: "warp stabilizer, stabilize, smooth cam, image stabilization, rolling shutter", summary: "distort.stabilize smooths camera shake; video.rolling_shutter repairs skew.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"distort.stabilize","params":{"smoothing":1.5}}"#),
        ]),
        EditorTerm(term: "Noise reduction", aliases: "temporal nr, spatial nr, neat video, denoise, grain removal", summary: "video.denoise is Resolve-style temporal (plus spatial) noise reduction, rendered in the background.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"video.denoise","params":{"temporal_frames":2}}"#),
        ]),
        EditorTerm(term: "Object removal", aliases: "content aware fill, object removal, paint out, patch replacer, clean plate", summary: "recipe remove_object tracks and paints an object out from other frames or a clean plate.", calls: [
            ("recipe", #"{"name":"remove_object","args":{"clip":"<clip>","box":{"x":0.3,"y":0.4,"width":0.15,"height":0.3}}}"#),
        ]),
        EditorTerm(term: "Camera RAW", aliases: "raw, braw, r3d, arriraw, prores raw, cinemadng, dng, debayer, raw settings", summary: "CinemaDNG and DNG import develop on the fly; media_organize raw sets ISO, white balance and exposure; BRAW, R3D and ARRIRAW need a transcode first.", calls: [
            ("media_organize", #"{"media_ids":["<media>"],"raw":{"exposure":0.5,"temperature":5600}}"#),
        ]),
        EditorTerm(term: "Fusion and compositing nodes", aliases: "fusion, fusion page, after effects composition, compositing nodes, merge node", summary: "Not available as a node graph. Nearest: tracks stack layers with blend modes, effects form grade nodes, sequence_nest precomposes, mask.matte and keys cut layers.", calls: [
            ("param_set", #"{"target":"<clip>","set":{"blend":"screen"}}"#),
        ]),
        EditorTerm(term: "Blend modes", aliases: "blend mode, composite mode, screen, multiply, overlay, add, layer mode", summary: "param_set blend sets a clip's composite mode; catalog lists them.", calls: [
            ("param_set", #"{"target":"<clip>","set":{"blend":"multiply"}}"#),
        ]),
        EditorTerm(term: "Opacity and fades", aliases: "opacity, cross dissolve, dip to black, fade handles, fade in fade out, video transition", summary: "param_set fade.in/fade.out or transition_set dissolve/dip on a cut; transform.opacity animates.", calls: [
            ("transition_set", #"{"cut":"<clip_a>|<clip_b>","type":"dissolve","duration":0.5}"#),
        ]),
        EditorTerm(term: "Audio crossfade", aliases: "constant power, crossfade audio, audio transition, exponential fade", summary: "transition_set part:\"audio\" (or both) crossfades the sound at a cut; audio.fade_in and audio.fade_out fade a clip.", calls: [
            ("transition_set", #"{"cut":"<clip_a>|<clip_b>","type":"dissolve","part":"audio","duration":0.2}"#),
        ]),
        EditorTerm(term: "Text-based editing", aliases: "text based editing, transcript editing, paper edit, script sync, edit by transcript", summary: "media_transcript gives word ids; assemble builds a cut from them, source_cut removes words wherever they play, cut_silences tightens.", calls: [
            ("assemble", #"{"segments":[{"media_id":"<media>","start":"<media>.w10","end":"<media>.w40.end"}]}"#),
        ]),
        EditorTerm(term: "Scene detection", aliases: "scene cut detection, scene edit detection, detect cuts, split at cuts, shot detection", summary: "Import detects scene cuts; recipe split_at_shots cuts clips at them.", calls: [
            ("recipe", #"{"name":"split_at_shots","args":{"track":"V1"}}"#),
        ]),
        EditorTerm(term: "Beat markers", aliases: "beat detection, beat markers, cut to music, music sync, auto beat", summary: "media_analyze beats; recipe beat_cut cuts shots on the beat; anchors beat:12.", calls: [
            ("recipe", #"{"name":"beat_cut","args":{"media":["<media_a>","<media_b>"]}}"#),
        ]),
        EditorTerm(term: "Smart bins and search", aliases: "smart bin, search media, find clip, filter media, metadata search, keyword search", summary: "media_list search finds names, metadata, keywords and transcript words; analysis_read shots describes what each shot shows.", calls: [
            ("media_list", #"{"search":"interview"}"#),
        ]),
        EditorTerm(term: "Undo history", aliases: "history panel, undo history, snapshots, versions, project backup, auto save", summary: "history lists every edit; restore jumps to one, diff compares, fork copies the project for an alternative.", calls: [
            ("history", #"{"action":"list"}"#),
        ]),
        EditorTerm(term: "Review and approval", aliases: "frame io, review, notes, approval, client review, comments on frame", summary: "The human pins notes to frames in the preview app; comments_list reads them, comment_reply resolves; timecode_burn marks review copies.", calls: [
            ("comments_list", #"{}"#),
        ]),
        EditorTerm(term: "Safe areas", aliases: "title safe, action safe, safe margins, guides, overlays, platform ui safe zone", summary: "generator grid_overlay safe shows the guides; recipe safe_zone_fix moves text out of a platform's UI.", calls: [
            ("recipe", #"{"name":"safe_zone_fix","args":{"platform":"tiktok"}}"#),
        ]),
        EditorTerm(term: "3D camera", aliases: "3d camera, camera layer, z space, 3d layer, parallax, 2.5d", summary: "param_set transform.3d true and transform.z put layers in depth; clip_add generator camera orbits and dollies.", calls: [
            ("clip_add", #"{"generator":"camera","track":"new","start":0,"duration":6}"#),
        ]),
        EditorTerm(term: "Particles", aliases: "particle emitter, particular, snow, sparks, confetti, emitter", summary: "clip_add generator particles with a preset (sparks, confetti, snow, dust, embers…).", calls: [
            ("clip_add", #"{"generator":"particles","track":"new","duration":5,"params":{"preset":"snow"}}"#),
        ]),
        EditorTerm(term: "Audio plugins", aliases: "vst, audio unit, au plugin, third party audio plugin, fairlight fx, izotope rx", summary: "catalog plugins lists installed Audio Units; effect_add type with the AU id runs it (VST isn't supported).", calls: [
            ("catalog", #"{"plugins":true}"#),
        ]),
        EditorTerm(term: "OpenFX plugins", aliases: "ofx, openfx, sapphire, boris fx, red giant, third party video plugin, fxplug", summary: "Not available: no OFX or FxPlug hosting. Nearest: built-in effects (catalog), stacked into nodes, and LUTs.", calls: [
            ("catalog", #"{"search":"glow"}"#),
        ]),
        EditorTerm(term: "Speed and duration", aliases: "clip speed duration, ctrl r, change duration, constant speed", summary: "clip_update speed (or duration with allow_stretch) retimes a clip.", calls: [
            ("clip_update", #"{"clip_id":"<clip>","speed":2}"#),
        ]),
        EditorTerm(term: "Link and unlink", aliases: "link audio, unlink audio, detach audio, separate audio, linked selection", summary: "clip_update link/unlink ties or separates a clip's picture and sound; clip_add channels split puts channels on their own tracks.", calls: [
            ("clip_update", #"{"clip_id":"<clip>","unlink":true}"#),
        ]),
        EditorTerm(term: "Source patching", aliases: "source patching, track targeting, track select, destination track, v1 a1 patch", summary: "clip_add track names the destination track (\"new\" adds one); audio_tracks routes split channels.", calls: [
            ("clip_add", #"{"media_id":"<media>","track":"V2","start":10}"#),
        ]),
        EditorTerm(term: "Track lock and visibility", aliases: "lock track, toggle track output, solo track, mute track, hide track, eye icon", summary: "track_update hidden and muted (no lock: tools only change what you name).", calls: [
            ("track_update", #"{"track":"V2","hidden":true}"#),
        ]),
        EditorTerm(term: "Snapshots of frames", aliases: "export frame, still, grab still, frame grab, thumbnail", summary: "export deliver:\"stills\" with times writes frames; timeline_frames shows them here.", calls: [
            ("export", #"{"deliver":"stills","times":[12.5],"path":"stills/"}"#),
        ]),
        EditorTerm(term: "GIF", aliases: "animated gif, gif export, loop", summary: "export deliver:\"gif\" renders an animated GIF of a range.", calls: [
            ("export", #"{"deliver":"gif","start":10,"end":13,"path":"clip.gif"}"#),
        ]),
    ]
}
