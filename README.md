# notein-export

Browser-based viewer and exporter for **Notein** (`.in`) handwriting notes — no app, no cloud, everything runs locally in the browser.

Live demo: **https://noteinexport.neswk.workers.dev**

`notein-export` unpacks the `.in` format (plain ZIP + SQLite) with a tiny Zig/WASM core, renders pressure-aware vector ink on `<canvas>`, and lets you export any region or page to **PNG / PDF / SVG** at 1×/2×/4×.

## Features

- **Drag-and-drop** `.in` file → instant local render (WASM, zero network upload)
- Infinite-canvas + bounded (A4/Letter) notes — pan, zoom, minimap with viewport indicator
- Pressure-aware strokes (replayed as variable-width polygons, not bitmaps)
- Images, typed text boxes, and shapes composited in chronological order
- **Export**: region-select or whole-page export to PNG / PDF (via `pdf-lib`) / SVG (true vector)
- Offline/static deploy — served as Cloudflare Workers assets

## File format

`.in` is a ZIP archive containing:

| File | Purpose |
|---|---|
| `note_database_note_<uuid>_db` | SQLite DB — all note content |
| `…_db-wal`, `…_db-shm` | WAL/journal (applied on load) |
| `note_meta.json` | Title, timestamps, folder, flags |
| `note_extra.json`, `note_in_flag.json`, `note_label.json`, `notepdf_lost_info.json` | Metadata / flags / labels |

Key SQLite tables: `NoteContentEntity`, `PageEntity`, `StrokeEntity` (`record_json` → `points: {x,y,p,action}[]`), `TextBoxEntity`, `ImageEntity`, `ShapeEntity`, plus layers, outlines, audio. See [`FORMAT.md`](FORMAT.md) for full reverse-engineering notes.

To read programmatically: unzip → open `…_db` with any SQLite library → read `StrokeEntity.record_json` → replay points.

## Quick start

### Use the hosted viewer

1. Open https://noteinexport.neswk.workers.dev
2. Drag a `.in` file onto the drop zone (or choose via file picker)
3. Pan/zoom, use the minimap to jump pages, select a region or export the current page

Nothing is uploaded — parsing stays in your browser (WASM memory).

### Run locally

**Prerequisites:** [Bun](https://bun.sh) 1.3+, [Zig](https://ziglang.org) 0.17+, Cloudflare `wrangler` for deploy.

```bash
git clone https://github.com/davidnoronha1/notein-export.git
cd notein-export

# build WASM + web
cd web
bun install
bun run build        # -> zig build + vite build (outputs to web/dist)

# dev server (auto rebuilds WASM)
bun run dev          # http://localhost:5173
```

### Tests (Zig core)

The `wasm/` tests previously used a 96 MB `fixtures/diary.in` sample. That fixture was **purged from git history** (and is ignored by `.gitignore`) — the integration tests now skip gracefully when no `.in` fixture is present:

```bash
cd wasm
zig build test                # unit tests
zig build test -- --test-filter diary  # integration (skips if fixtures/*.in missing)
```

To run integration tests locally, drop any `.in` export as `fixtures/diary.in` (ignored by git) and rerun.

## Project structure

```
notein-export/
├── FORMAT.md          # reverse-engineered .in spec
├── wasm/              # Zig → WASM core (zip, SQLite btree/pager, raster, window)
│   ├── src/main.zig   # WASM C-ABI (alloc/open/render/get_visible_*)
│   ├── src/model.zig  # note model (pages/strokes/images/text)
│   └── build.zig      # -> web/src/wasm/notein.wasm
├── web/               # Vite + TypeScript viewer
│   ├── index.html     # shell (canvas, minimap, export controls)
│   ├── src/main.ts    # app glue (file input, viewport, export wiring)
│   ├── src/wasm/loader.ts # typed WASM wrapper (zero-copy views)
│   ├── src/canvas/    # renderer, viewport, minimap, export-render
│   └── src/export.ts  # PNG/PDF/SVG export helpers
├── fixtures/          # (git-ignored) local .in samples only
└── wrangler.toml      # Cloudflare Workers assets deploy
```

## How rendering works

1. `wasm.openFile(bytes)` — unzip, WAL-replay, parse SQLite btree, build in-memory model
2. `set_active_window` + `render_viewport(page, x,y,w,h, pixelW, pixelH, ...)` — returns packed polygon vertices over WASM memory
3. JS `Renderer` draws polygons via Canvas2D, compositing images/text by `creationTime`
4. `export-render.ts` reuses same `render_viewport` path but to an offscreen canvas/SVG at chosen `scale` (1×/2×/4×)

## Deployment

Static site is deployed as Cloudflare Workers assets (`noteinexport.neswk.workers.dev`):

```bash
# build first
cd web && bun run build

# deploy (wrangler logged in via OAuth, account nes)
bunx wrangler deploy --config ../wrangler.toml
# or: bunx wrangler deploy --cwd web  (uses web/wrangler.toml if placed there)
```

`wrangler.toml` at repo root:

```toml
name = "noteinexport"
compatibility_date = "2025-08-24"
assets = { directory = "./web/dist", not_found_handling = "single-page-application" }
```

## Privacy & notes

- `.in` files never leave your machine — the viewer has no backend, no upload, no telemetry.
- `*.in` and `fixtures/*.in` are git-ignored and **not** tracked with Git LFS. Do not commit diary samples; use local `fixtures/` only.
- The viewer is read-only; it does not write back to `.in`.

## License

MIT — use, fork, PRs welcome.
