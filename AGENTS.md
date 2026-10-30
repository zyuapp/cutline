# Agent Instructions

- `CutlineCore` is pure Swift: the project model, edits, captions, history and the `.cutline` bundle. Put editing rules here and cover them in `Tests/CutlineCoreTests`.
- `CutlineEngine` turns a project into AVFoundation objects: composition, Metal compositor, text rendering, analysis, frames and export. The preview app and the MCP server must render through it so preview and export match.
- `CutlineMCP` is the agent surface. Tools stay thin: parse arguments, call Core/Engine, describe the result. Edit tools go through `addEdit` so they are undoable and usable inside `batch`.
- `Cutline` (the app) only reads the bundle and writes comments, `preview.json` and, for `voiceover_record`, recorded takes under `media/recordings/`. It never edits the timeline; the agent imports and places takes.
- Build with `swift build -c release --arch arm64`; test with `swift test`; drive the server with `scripts/mcp-session.py`.
