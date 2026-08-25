# notein-export

Browser-based viewer and exporter for **Notein** (`.in`) handwriting notes. Drop a `.in` file in and view, pan, and export — everything runs locally in your browser.

Unpacks the `.in` format (ZIP + SQLite) with a small Zig/WASM core, renders pressure-aware vector ink on `<canvas>`, and exports any region or page to **PNG / PDF / SVG** at 1× / 2× / 4×.

## Features

- **Drag & drop** `.in` file → instant local render, no upload
- **Infinite canvas + bounded pages** (A4 / Letter) — pan, zoom, and minimap with viewport indicator
- **Pressure-aware strokes** replayed as variable-width polygons, not bitmaps
- **Images, typed text, and shapes** composited in chronological order
- **Export** — select a region or export the whole page to PNG, PDF (`pdf-lib`), or true vector SVG. Selection menu follows your selection with a progress indicator for large exports
- **Media panel** — browse all embedded images and audio, jump to an image's location, play/download audio, or download everything as a single ZIP (ZIP assembly is done in Zig with real local/central headers and CRC32, no JS zip library)
- **Links panel** — browse all hyperlinks, jump to their position, or open externally

## File format

`.in` is a ZIP archive:

| File | Purpose |
|---|---|
| `note_database_note_<uuid>_db` | SQLite DB — all note content |
| `…_db-wal`, `…_db-shm` | WAL/journal (applied on load) |
| `note_meta.json` | Title, timestamps, folder, flags |
| `note_extra.json`, `note_in_flag.json`, `note_label.json`, `notepdf_lost_info.json` | Metadata / flags / labels |
| `note_image_<uuid>.*`, `note_audio_<uuid>.*` | Embedded images/audio, referenced by name from the DB |

Key tables: `NoteContentEntity`, `PageEntity`, `StrokeEntity` (`record_json` → `points: {x,y,p,action}[]`), `TextBoxEntity`, `ImageEntity`, `ShapeEntity`, `HyperLinkEntity`, `AudioFileEntity`, plus layers and outlines.

See [`FORMAT.md`](FORMAT.md) for the full reverse-engineering notes. To read programmatically: unzip → open `…_db` with any SQLite library → read `StrokeEntity.record_json` → replay points.

## Getting started

### Use the viewer

1. Open the viewer and drop a `.in` file onto the drop zone (or use the file picker)
2. Pan, zoom, and use the minimap to navigate
3. Drag to select a region or export the current page; use **Media** and **Links** to browse embedded assets

Files never leave your machine — parsing happens in WASM memory in the browser.

### Run locally

**Prerequisites:** [Bun](https://bun.sh) 1.3+ and [Zig](https://ziglang.org) 0.17+.

```bash
git clone https://github.com/davidnoronha1/notein-export.git
cd notein-export

cd web
bun install
bun run build        # builds WASM (zig build) + web (vite) -> web/dist

bun run dev          # dev server with auto WASM rebuild -> http://localhost:5173
```

### Tests

The Zig core has unit and integration tests. Integration tests need a local `.in` fixture (git-ignored), and skip gracefully if none is present:

```bash
cd wasm
zig build test                              # unit tests
zig build test -- --test-filter diary       # integration (requires fixtures/*.in)

# to enable integration tests locally:
# drop any .in export as fixtures/diary.in and rerun
```

`fixtures/*.in` and `*.in` are git-ignored — don't commit note samples.

## Project structure

```
notein-export/
├── FORMAT.md              # reverse-engineered .in spec
├── wasm/                  # Zig → WASM core (zip, SQLite btree/pager, raster)
│   ├── src/main.zig       # WASM C-ABI (alloc/open/render/get_visible_*/build_media_zip)
│   ├── src/model.zig      # note model (pages/strokes/images/text/links/audio)
│   ├── src/zip.zig        # ZIP reader for the .in container
│   ├── src/zip_writer.zig # ZIP writer (STORE) for media download-all
│   └── build.zig          # -> web/src/wasm/notein.wasm
├── web/                   # Vite + TypeScript + Preact viewer
│   ├── index.html
│   ├── src/main.ts        # app glue (file input, viewport, export wiring)
│   ├── src/wasm/loader.ts # typed WASM wrapper (zero-copy views)
│   ├── src/canvas/        # renderer, viewport, minimap, export-render, layout
│   ├── src/media-panel.tsx, src/links-panel.tsx, src/icons.tsx
│   └── src/export.ts      # PNG / PDF / SVG helpers
└── fixtures/              # local .in samples only (git-ignored)
```

## How rendering works

1. `wasm.openFile(bytes)` — unzip, WAL-replay, parse SQLite btree, build in-memory model
2. `set_active_window` + `render_viewport(page, x, y, w, h, pixelW, pixelH)` — returns packed polygon vertices over WASM memory
3. JS `Renderer` draws polygons via Canvas2D, compositing images and text by `creationTime`
4. `export-render.ts` reuses the same `render_viewport` path on an offscreen canvas/SVG at the chosen scale (1×/2×/4×)
5. Media/Links panels call `get_all_images` / `get_all_links` / `get_all_audio` once (lazily on first open); per-item bytes come from `get_bytes(name)`
6. **Download all** calls `build_media_zip()` — reads every image/audio asset from the already-open `.in` archive and assembles a ZIP inside WASM; JS just downloads the resulting bytes

## Privacy

- `.in` files never leave your device. There is no backend, no upload, and no telemetry.
- The viewer is read-only — it does not modify `.in` files.

## License

MIT — use, fork, and PRs welcome.
