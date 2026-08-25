# notein-export

Browser-based viewer and exporter for **Notein** (`.in`) handwriting notes. Drop a `.in` file in and view, pan, and export — everything runs locally in your browser.

Unpacks the `.in` format (ZIP + SQLite) with a small Zig/WASM core, renders pressure-aware vector ink on `<canvas>`, and exports any region or page to **PNG / PDF / SVG** at 1× / 2× / 4×.

![Screenshot](assets/screenshot.png)

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

See [`FORMAT.md`](FORMAT.md) for the full reverse-engineering notes. To read programmatically: unzip → replay WAL → open `…_db` with any SQLite library → read `StrokeEntity.record_json` → replay points.

## Getting started

### Use the viewer

1. Open the viewer and drop a `.in` file onto the drop zone (or use the file picker)
2. Pan, zoom, and use the minimap to navigate
3. Drag to select a region or export the current page; use **Media** and **Links** to browse embedded assets

Files never leave your machine — parsing happens in WASM memory in the browser.

<details>
<summary><strong>Run locally</strong></summary>

**Prerequisites:** [Bun](https://bun.sh) 1.3+ and [Zig](https://ziglang.org) 0.17+ (nightly — uses `std.array_list.Managed`, `std.Io.Dir`, etc.).

```bash
git clone https://github.com/davidnoronha1/notein-export.git
cd notein-export

cd web
bun install
bun run build        # builds WASM (zig build) + web (vite) -> web/dist

bun run dev          # dev server with auto WASM rebuild -> http://localhost:5173
bun run preview      # preview a production build
```

</details>

### Tests

The Zig core has unit and integration tests. Integration tests need a local `.in` fixture (git-ignored) and skip gracefully if none is present:

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
├── assets/screenshot.png  # viewer screenshot
├── wasm/                  # Zig → WASM core (zip, SQLite btree/pager, raster)
│   ├── src/main.zig       # WASM C-ABI (alloc/open/render/get_visible_*/build_media_zip)
│   ├── src/model.zig      # note model (pages/strokes/images/text/links/audio, content_bounds)
│   ├── src/tessellate.zig # pressure → polygon ribbon, quad for shape edges
│   ├── src/window.zig     # lazy JSON decode + smoothing + spatial grid (active window)
│   ├── src/raster.zig     # scanline polygon fill (nonzero winding, AA)
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

## How it works

```
drop .in → read bytes → unzip + WAL replay → SQLite → layout → active window → tessellate → raster → canvas
```

1. **Read file** — the `.in` is read as raw bytes in JS and copied into WASM memory via `alloc_big` / `open` (`wasm/src/main.zig:114`).
2. **Unzip + WAL replay** — `zip.zig` opens the archive, `wal.zig` replays `…_db-wal` onto `…_db` to get the final SQLite image.
3. **Parse SQLite** — `sqlite/btree.zig` + `model.zig:open` scan `NoteContentEntity` / `PageEntity` / `StrokeEntity` etc. into a lightweight index (bounds + page + row pointer). `record_json` stays undecoded.
4. **Layout** — `web/src/canvas/layout.ts:46` builds one world space: bounded pages stack vertically and center horizontally; unbounded pages are sized to their real `content_bounds` (union of all item bounds from `model.zig:338`), not the nominal `paper_spec`.
5. **Active window** — `window.zig:Window.setActive` decodes only the visible pages (+1 prefetch). Each stroke is smoothed (Catmull-Rom), tessellated once into a pressure-aware ribbon polygon (`tessellate.zig:9`), and indexed in a spatial grid for fast culling.
6. **Render** — for each visible page, `renderer.ts:144` intersects the world viewport with the page box, converts to page-local, culls via the grid, rasterizes polygons with `raster.zig:71` (scanline, nonzero winding, AA), and composites ink / images / text in `creationTime` order onto the HiDPI canvas. Export reuses the same path offscreen.

## Privacy

- `.in` files never leave your device. No backend, no upload, no telemetry.
- The viewer is read-only — it does not modify `.in` files.

## License

MIT — see [LICENSE](LICENSE).

