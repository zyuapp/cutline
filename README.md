# Cutline

A macOS video editor that Claude drives through MCP. You don't edit: you watch the preview, scrub, and pin notes on frames. Claude reads the notes and changes the edit.

- **Agent-native editing**: 38 MCP tools for timelines, transcripts, frames, captions, history and export.
- **The agent can see and hear**: on-device word-level transcripts, pause and filler detection, scene cuts, and rendered frames sent back as images.
- **Same pixels everywhere**: the preview and the export both use one Metal compositor built on AVFoundation.
- **Notes on frames**: press C in the preview, click the spot, and type. Claude replies in the same thread.
- **Every edit is undoable**: each tool call is a history entry, and `batch` groups several.

![Cutline showing a note pinned on a frame, Claude's reply, and the timeline](docs/screenshots/editor.png)

Requires macOS 26 on Apple Silicon.

## Install

Download `Cutline.dmg`, drag Cutline to Applications, then connect it to Claude Code:

```sh
claude mcp add cutline -- /Applications/Cutline.app/Contents/MacOS/cutline-mcp
```

Then ask Claude for a video:

> Make a 45-second vertical cut of ~/Movies/interview.mov with bold captions, no pauses, and the logo in the corner.

Claude creates a `.cutline` project and opens it in the preview window.

## What Claude can do

| Area | Tools |
| --- | --- |
| Project | `project_create`, `project_open`, `project_status`, `canvas_set` |
| Media | `media_import`, `media_analyze`, `media_transcript`, `media_frames`, `media_remove` |
| Cutting | `assemble`, `cut_silences`, `source_cut`, `range_delete`, `clip_split`, `clip_delete` |
| Layers | `clip_add`, `clip_update`, `clip_move`, `text_add`, `track_add`, `track_update` |
| Look and sound | transforms, keyframes, fades, speed, volume, `captions_set` presets (karaoke, bold, clean, reveal, minimal) |
| Review | `timeline_frames`, `timeline_transcript`, `comments_list`, `comment_reply`, `comment_add`, `preview_seek`, `preview_state` |
| History | `history`, `undo`, `redo`, `history_restore`, `batch` |
| Output | `export` (HEVC, H.264, ProRes) |

## Project format

A project is a `.cutline` folder of plain JSON:

```
project.json    canvas, media, tracks, clips, captions, markers
history.json    edit history; snapshots in history/
comments.json   notes from the preview and replies from Claude
analysis/       transcripts, audio levels and pauses, scene cuts per media file
exports/        rendered videos
```

Media is referenced in place, not copied.

## Preview controls

| Key | Action |
| --- | --- |
| Space | Play or pause |
| ← → | Step one frame (with Shift, one second) |
| J K L | Shuttle back, stop, forward |
| C | Pin a note to the current frame |
| Home, End | Go to start or end |
| ⌘-scroll, pinch | Zoom the timeline |

## Develop

```sh
swift build -c release --arch arm64   # app and MCP server
swift test                            # core editing tests
scripts/make-fixtures.sh              # sample media (needs ffmpeg)
scripts/build-app.sh                  # dist/Cutline.app
scripts/create-dmg.sh                 # dist/Cutline.dmg
```

The repo's `.mcp.json` points Claude Code at the development build, so opening Claude Code in this folder gives you the tools right away. `scripts/mcp-session.py` drives the server from a JSON list of tool calls and saves returned images.

| Target | Role |
| --- | --- |
| `CutlineCore` | Model, edits, captions, history, bundle IO |
| `CutlineEngine` | AVFoundation composition, Metal compositor, text, analysis, export |
| `CutlineMCP`, `cutline-mcp` | MCP server over stdio |
| `Cutline` | SwiftUI preview app |

## Design

Wax yellow marks your notes and periwinkle marks everything Claude does: note pins, replies, the live status dot and the outline on a clip Claude just changed. The interface is set in [Host Grotesk](https://github.com/HostGrotesk/Host-Grotesk) (SIL Open Font License, bundled in `Sources/Cutline/Fonts`).

## License

MIT
