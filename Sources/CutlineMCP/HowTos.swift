import Foundation

extension Toolbox {
    /// Common editor tasks for catalog search, each with the calls that do it.
    static let howTos: [HowTo] = [
        HowTo(title: "Blur a face", keywords: "face blur, anonymize, censor or hide a person's face, privacy blur that follows the face", summary: "Blur inside an ellipse window bound to the analyzed face so it follows the person; use face:<media>:1 for the second face. Shots analysis finds the faces.", calls: [
            ("media_analyze", #"{"media_id":"<media>","features":["shots"]}"#),
            ("effect_add", #"{"target":"<clip>","type":"blur.gaussian","id":"faceblur","params":{"radius":0.05,"limit":"ellipse","limit_width":0.22,"limit_height":0.3,"limit_feather":0.03}}"#),
            ("param_set", #"{"target":"<clip>","bind":{"fx.faceblur.limit_x":{"source":"face:<media>.x"},"fx.faceblur.limit_y":{"source":"face:<media>.y"},"fx.faceblur.limit_height":{"source":"face:<media>.size","offset":0.08}}}"#),
        ]),
        HowTo(title: "Pixelate a face", keywords: "mosaic face, pixelate person, censor face with blocks", summary: "Pixelate inside a window bound to the face, like the face blur.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"stylize.pixelate","id":"facepix","params":{"size":0.03,"limit":"ellipse","limit_width":0.22,"limit_height":0.3}}"#),
            ("param_set", #"{"target":"<clip>","bind":{"fx.facepix.limit_x":{"source":"face:<media>.x"},"fx.facepix.limit_y":{"source":"face:<media>.y"},"fx.facepix.limit_height":{"source":"face:<media>.size","offset":0.08}}}"#),
        ]),
        HowTo(title: "Blur a license plate, screen or moving object", keywords: "blur plate, blur sign, blur object, censor object, hide text on screen, track and blur", summary: "Track the object with media_track, then bind a blur window to the track.", calls: [
            ("media_track", #"{"media_id":"<media>","at":12.0,"box":{"x":0.4,"y":0.6,"width":0.1,"height":0.05}}"#),
            ("effect_add", #"{"target":"<clip>","type":"blur.gaussian","id":"plateblur","params":{"radius":0.04,"limit":"rect","limit_width":0.12,"limit_height":0.07}}"#),
            ("param_set", #"{"target":"<clip>","bind":{"fx.plateblur.limit_x":{"source":"track:<track id>.x"},"fx.plateblur.limit_y":{"source":"track:<track id>.y"}}}"#),
        ]),
        HowTo(title: "Remove a logo or watermark", keywords: "logo removal, delete watermark, remove bug, erase brand, paint out", summary: "Paint the logo out with the background from other frames; fixed:true for a logo that never moves.", calls: [
            ("recipe", #"{"name":"remove_object","args":{"clip":"<clip>","box":{"x":0.85,"y":0.05,"width":0.1,"height":0.08},"fixed":true}}"#),
        ]),
        HowTo(title: "Remove an object or person from the shot", keywords: "erase object, remove boom mic, remove passerby, content-aware fill, object removal, clean plate", summary: "Track the object from a box and paint it out with the background other frames show.", calls: [
            ("recipe", #"{"name":"remove_object","args":{"clip":"<clip>","box":{"x":0.3,"y":0.4,"width":0.15,"height":0.3},"at":"<time>"}}"#),
        ]),
        HowTo(title: "Stabilize shaky footage", keywords: "stabilise, steady handheld, remove camera shake, smooth wobble", summary: "Analyzes camera motion once and smooths it, zooming just enough to hide edges.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"distort.stabilize","params":{"smoothing":1.5}}"#),
        ]),
        HowTo(title: "Match color between shots", keywords: "color match, shot matching, consistent color, continuity grade, match camera", summary: "Measures each shot's tones and color and matches them to a reference clip.", calls: [
            ("recipe", #"{"name":"match_color","args":{"clips":["<clip_a>","<clip_b>"],"reference":"<reference clip>"}}"#),
        ]),
        HowTo(title: "Color correct exposure and white balance", keywords: "brighten, darken, fix exposure, warm up, cool down, white balance, saturation, contrast, correct color", summary: "Primary correction with color.adjust; temperature warms (+) or cools (−).", calls: [
            ("effect_add", #"{"target":"<clip>","type":"color.adjust","params":{"exposure":0.3,"contrast":0.1,"temperature":10,"saturation":0.1}}"#),
        ]),
        HowTo(title: "Apply a cinematic look", keywords: "film look, teal and orange, movie grade, stylized grade, color look", summary: "A look on an adjustment layer over the range.", calls: [
            ("recipe", #"{"name":"look","args":{"look":"teal_orange","amount":0.8}}"#),
        ]),
        HowTo(title: "Apply a LUT", keywords: "cube file, lut, log to rec709, camera lut", summary: "3D LUT from a .cube file.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"color.lut","params":{"file":"/path/to/look.cube"}}"#),
        ]),
        HowTo(title: "Make it black and white", keywords: "monochrome, grayscale, desaturate, b&w", summary: "color.monochrome; a tint color makes sepia or duotone.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"color.monochrome","params":{"amount":1}}"#),
        ]),
        HowTo(title: "Brighten a face", keywords: "relight face, lift face exposure, face too dark, highlight person", summary: "Exposure inside an ellipse window bound to the face.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"color.adjust","id":"facelight","params":{"exposure":0.4,"limit":"ellipse","limit_width":0.3,"limit_height":0.4,"limit_feather":0.1}}"#),
            ("param_set", #"{"target":"<clip>","bind":{"fx.facelight.limit_x":{"source":"face:<media>.x"},"fx.facelight.limit_y":{"source":"face:<media>.y"}}}"#),
        ]),
        HowTo(title: "Smooth skin", keywords: "beauty retouch, soften skin, skin smoothing", summary: "A soft blur keyed to skin tones inside a window bound to the face.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"blur.gaussian","id":"skin","params":{"radius":0.006,"limit":"ellipse+qualifier","q_preset":"skin","limit_width":0.25,"limit_height":0.35}}"#),
            ("param_set", #"{"target":"<clip>","bind":{"fx.skin.limit_x":{"source":"face:<media>.x"},"fx.skin.limit_y":{"source":"face:<media>.y"}}}"#),
        ]),
        HowTo(title: "Add a vignette", keywords: "dark edges, vignette, focus center", summary: "Darkened edges.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"stylize.vignette","params":{"amount":0.6}}"#),
        ]),
        HowTo(title: "Add film grain", keywords: "grain, noise texture, film look", summary: "stylize.grain on a clip or an adjustment layer.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"stylize.grain"}"#),
        ]),
        HowTo(title: "Sharpen the picture", keywords: "sharpen, crisp, detail", summary: "blur.sharpen.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"blur.sharpen"}"#),
        ]),
        HowTo(title: "Reduce video noise", keywords: "denoise video, remove grain, noisy low light footage", summary: "Temporal noise reduction, rendered in the background.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"video.denoise"}"#),
        ]),
        HowTo(title: "Key out a green screen", keywords: "chroma key, green screen, blue screen, replace background", summary: "Key the top clip; put the new background on the track below.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"key.chroma","params":{"color":"auto"}}"#),
        ]),
        HowTo(title: "Remove or replace the background without a green screen", keywords: "cutout person, background removal, segment person, isolate subject, text behind person", summary: "mask.person keeps the people; invert to keep the background (text behind a person).", calls: [
            ("effect_add", #"{"target":"<clip>","type":"mask.person","params":{"quality":"balanced"}}"#),
        ]),
        HowTo(title: "Picture in picture", keywords: "pip, inset, webcam corner, face cam", summary: "Puts a clip in a corner.", calls: [
            ("recipe", #"{"name":"pip","args":{"clip":"<clip>","corner":"bottom_right","size":0.3}}"#),
        ]),
        HowTo(title: "Split screen", keywords: "side by side, two clips at once, compare", summary: "Shows clips side by side.", calls: [
            ("recipe", #"{"name":"split_screen","args":{"clips":["<clip_a>","<clip_b>"]}}"#),
        ]),
        HowTo(title: "Make a vertical version for TikTok, Reels or Shorts", keywords: "9:16, vertical video, portrait, reframe, crop to vertical, social", summary: "Changes the canvas aspect and follows faces or the subject.", calls: [
            ("recipe", #"{"name":"reframe","args":{"aspect":"9:16"}}"#),
            ("recipe", #"{"name":"safe_zone_fix","args":{"platform":"tiktok"}}"#),
        ]),
        HowTo(title: "Make text or a graphic follow a person or object", keywords: "tracking text, attach title to face, follow subject, motion tracking, stick graphic", summary: "recipe follow moves a clip with a face or a media_track track.", calls: [
            ("recipe", #"{"name":"follow","args":{"clip":"<title clip>","target":"face:<media>","offset_y":-0.2}}"#),
        ]),
        HowTo(title: "Add captions or subtitles", keywords: "burn in captions, subtitles, closed captions, srt, vtt, social captions", summary: "Captions come from the transcript; export writes SRT/VTT too.", calls: [
            ("captions_set", #"{"enabled":true}"#),
            ("captions_list", #"{}"#),
        ]),
        HowTo(title: "Translate subtitles", keywords: "translate captions, foreign language subtitles, french spanish subtitles", summary: "On-device translation of the caption cues; export them as subtitle files.", calls: [
            ("captions_translate", #"{"language":"fr"}"#),
        ]),
        HowTo(title: "Fix a misheard word", keywords: "correct transcript, wrong word, fix caption typo, spelling", summary: "transcript_edit fixes the transcript; captions_set replacements fixes a word everywhere in captions.", calls: [
            ("transcript_edit", #"{"media_id":"<media>","from":"w12","text":"Cutline"}"#),
        ]),
        HowTo(title: "Name speakers and fix who speaks", keywords: "label speakers, speaker names, diarization, who is talking, wrong speaker, identify voices", summary: "Rename S1… to names and pin a few turns; media_analyze speakers enroll:true re-labels the rest from those voices.", calls: [
            ("transcript_edit", #"{"media_id":"<media>","rename":{"S1":"Anna"}}"#),
            ("transcript_edit", #"{"media_id":"<media>","from":"w40","to":"w52","speaker":"Ben"}"#),
            ("media_analyze", #"{"media_id":"<media>","features":["speakers"],"enroll":true}"#),
        ]),
        HowTo(title: "Remove silences and pauses", keywords: "cut dead air, tighten pauses, jump cut silences, remove gaps", summary: "Cuts pauses longer than min_pause from a media's clips.", calls: [
            ("cut_silences", #"{"media_id":"<media>","min_pause":0.5}"#),
        ]),
        HowTo(title: "Remove filler words", keywords: "remove um and uh, cut fillers, hesitations", summary: "cut_silences with fillers removes um/uh along with pauses.", calls: [
            ("cut_silences", #"{"media_id":"<media>","fillers":true}"#),
        ]),
        HowTo(title: "Cut out words or a flubbed take", keywords: "remove sentence, cut mistake, delete words, retake", summary: "Remove source ranges by word anchors from media_transcript.", calls: [
            ("source_cut", #"{"media_id":"<media>","ranges":[["<media>.w88","<media>.w93.end"]]}"#),
        ]),
        HowTo(title: "Duck music under dialogue", keywords: "lower music when talking, ducking, sidechain, music too loud under voice", summary: "Dips music clips under speech.", calls: [
            ("recipe", #"{"name":"duck","args":{"amount_db":12}}"#),
        ]),
        HowTo(title: "Normalize loudness for YouTube or podcasts", keywords: "lufs, -14 lufs, loudness target, volume consistent, broadcast loudness", summary: "Sets master gain and a limiter and keeps the target for every export.", calls: [
            ("recipe", #"{"name":"loudness_normalize","args":{"target_lufs":-14}}"#),
        ]),
        HowTo(title: "Reduce background noise in speech", keywords: "denoise audio, remove hiss, clean up voice, noisy audio, voice isolation", summary: "audio.denoise lowers steady noise; audio.voice_isolation removes music and room too.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"audio.denoise","params":{"reduction":12}}"#),
            ("effect_add", #"{"target":"<clip>","type":"audio.voice_isolation"}"#),
        ]),
        HowTo(title: "Remove hum or buzz", keywords: "dehum, 50hz 60hz hum, electrical buzz", summary: "audio.dehum.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"audio.dehum"}"#),
        ]),
        HowTo(title: "Tame harsh s sounds", keywords: "de-ess, sibilance", summary: "audio.deess.", calls: [
            ("effect_add", #"{"target":"<clip>","type":"audio.deess"}"#),
        ]),
        HowTo(title: "Fade in or out", keywords: "fade from black, fade to black, fade picture, fade audio", summary: "Picture fades with fade.in/out, sound with audio.fade_in/out.", calls: [
            ("param_set", #"{"target":"<clip>","set":{"fade.in":0.5,"fade.out":1.0,"audio.fade_in":0.5,"audio.fade_out":1.0}}"#),
        ]),
        HowTo(title: "Add a transition between clips", keywords: "crossfade, dissolve, wipe, slide, transition at cut", summary: "transition_set at a cut; catalog lists the types.", calls: [
            ("transition_set", #"{"cut":"<clip_a>|<clip_b>","type":"dissolve","duration":0.5}"#),
        ]),
        HowTo(title: "Slow motion or a speed ramp", keywords: "slow mo, speed up, timelapse, ramp speed, change clip speed", summary: "recipe speed_ramp ramps in and out; clip_update speed sets a constant speed.", calls: [
            ("recipe", #"{"name":"speed_ramp","args":{"clip":"<clip>","at":"<time>","speed":0.4}}"#),
            ("clip_update", #"{"clip_id":"<clip>","speed":2}"#),
        ]),
        HowTo(title: "Freeze frame", keywords: "hold frame, still frame, pause the picture", summary: "Holds a frame; speech pauses with it.", calls: [
            ("recipe", #"{"name":"freeze_frame","args":{"at":"<time>","duration":2}}"#),
        ]),
        HowTo(title: "Zoom in slowly (Ken Burns)", keywords: "push in, slow zoom, animate scale, ken burns", summary: "Animate transform.scale over the clip.", calls: [
            ("param_set", #"{"target":"<clip>","animate":{"transform.scale":[["<clip>.start",1],["<clip>.end",1.15,"easeOut"]]}}"#),
        ]),
        HowTo(title: "Hide jump cuts with punch-ins", keywords: "punch in, alternate zoom, jump cut cover", summary: "Scales up alternate shots, centered on faces.", calls: [
            ("recipe", #"{"name":"punch_in","args":{"amount":1.15}}"#),
        ]),
        HowTo(title: "Cut to the beat of the music", keywords: "music video, beat sync edit, cut on beats, rhythm edit", summary: "Cuts footage to the timeline music's analyzed beats, best shots first.", calls: [
            ("recipe", #"{"name":"beat_cut","args":{"media":["<media>"],"every":2}}"#),
        ]),
        HowTo(title: "Fit music to the video length", keywords: "shorten song, extend music, music length, edit music to fit", summary: "Cuts or repeats whole bars so the song keeps its ending.", calls: [
            ("recipe", #"{"name":"music_fit","args":{"clip":"<music clip>","length":60}}"#),
        ]),
        HowTo(title: "Sync external audio to video", keywords: "dual system sound, sync recorder, align audio by waveform, clap sync", summary: "Lines up the recorder's sound by waveform and mutes the camera mic.", calls: [
            ("recipe", #"{"name":"sync_audio","args":{"audio":"<audio media>","clips":["<clip>"]}}"#),
        ]),
        HowTo(title: "J-cut or L-cut", keywords: "split edit, audio leads picture, audio lags", summary: "Sound starts early (+) or runs on (−) at a cut.", calls: [
            ("recipe", #"{"name":"split_edit","args":{"edit":"<clip_a>|<clip_b>","offset":0.5}}"#),
        ]),
        HowTo(title: "Fill gaps with room tone", keywords: "room tone, background ambience, silent gaps, audio drops out", summary: "Fills every gap on a dialogue track with looped room tone.", calls: [
            ("recipe", #"{"name":"fill_gaps","args":{"track":"<audio track>","media":"<media>","source_start":1.0,"source_end":3.5}}"#),
        ]),
        HowTo(title: "Add a title", keywords: "text on screen, headline, add words, caption card", summary: "text_add places styled text; catalog lists title presets.", calls: [
            ("text_add", #"{"text":"Day One","start":0,"duration":3}"#),
        ]),
        HowTo(title: "Add a lower third with a name", keywords: "name title, lower third, speaker name, chyron", summary: "A lower-third graphic generator.", calls: [
            ("clip_add", #"{"generator":"title.lower_third_modern","start":5,"duration":4}"#),
        ]),
        HowTo(title: "Animated words as they are spoken", keywords: "kinetic typography, word by word captions, animated text", summary: "Spoken words appear as they are said.", calls: [
            ("recipe", #"{"name":"kinetic_text","args":{"start":"<time>","end":"<time>"}}"#),
        ]),
        HowTo(title: "Multicam edit that cuts to whoever speaks", keywords: "multicam, podcast edit, switch angles by speaker, interview cameras", summary: "Build a multicam clip and switch angles per speaker turn.", calls: [
            ("multicam_create", #"{"angles":["<cam_a>","<cam_b>"],"sync":"audio"}"#),
            ("recipe", #"{"name":"multicam_switch","args":{"clip":"<multicam clip>"}}"#),
        ]),
        HowTo(title: "Glitch effect", keywords: "digital glitch, distortion hits, rgb split", summary: "Glitch hits on an adjustment track.", calls: [
            ("recipe", #"{"name":"glitch","args":{"at":["<time>"],"duration":0.3}}"#),
        ]),
        HowTo(title: "Whip pan transition", keywords: "swish pan, fast pan transition", summary: "Whip-pan at a cut.", calls: [
            ("recipe", #"{"name":"whip_pan","args":{"cut":"<clip_a>|<clip_b>"}}"#),
        ]),
        HowTo(title: "Crop or rotate the picture", keywords: "crop edges, rotate, flip, letterbox, straighten", summary: "transform.crop.* and transform.rotation.", calls: [
            ("param_set", #"{"target":"<clip>","set":{"transform.crop.top":0.1,"transform.crop.bottom":0.1,"transform.rotation":2}}"#),
        ]),
        HowTo(title: "Add chapter markers", keywords: "chapters, markers, youtube chapters, bookmarks", summary: "Markers become chapters on export.", calls: [
            ("markers", #"{"add":[{"time":0,"label":"Intro"},{"time":"<time>","label":"Part 2"}]}"#),
        ]),
        HowTo(title: "Export for a platform", keywords: "export youtube, render mp4, deliver, upload instagram, save video", summary: "export with platform picks size, codec and loudness checks; preset picks a codec.", calls: [
            ("export", #"{"path":"out.mp4","platform":"youtube"}"#),
        ]),
        HowTo(title: "Undo the last change", keywords: "undo, revert, go back, restore earlier version", summary: "history undo; restore jumps to any entry.", calls: [
            ("history", #"{"action":"undo"}"#),
        ]),
        HowTo(title: "Refer to what the last call created", keywords: "last clip id, previous result, $last, reuse id, chain calls", summary: "\"$last\", \"$last_clip\", \"$last_track\", \"$last_media\" and \"$last_effect\" work in any argument; inside batch, as:\"x\" names a result for \"$x\".", calls: [
            ("effect_add", #"{"target":"$last_clip","type":"stylize.vignette"}"#),
        ]),
    ]
}
