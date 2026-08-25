# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A browser-based viewer/exporter for **Notein** (`.in`) handwriting-note exports. Everything runs
client-side: a Zig core compiled to WASM unzips the `.in` container, replays its SQLite database, and
rasterizes ink; a Preact/TS frontend drives pan/zoom/export/panels around it. No server-side processing —
files never leave the browser. Deployed as static assets on Cloudflare Workers.

## Commands

All web/wasm commands run from `web/` (the wasm build is invoked as a prestep via bun scripts):

```bash
cd web
bun install
bun run dev          # zig build (wasm) + vite dev server -> http://localhost:5173, rebuilds wasm on change
bun run build         # zig build -Doptimize=ReleaseSmall + vite build -> web/dist
bun run preview       # preview a production build
```

Zig tests run from `wasm/`:

```bash
cd wasm
zig build test                              # unit tests (root.zig)
zig build test -- --test-filter diary       # integration tests, need a local .in fixture
```

Integration tests (`integration_test.zig`, `model_integration_test.zig`, `window_integration_test.zig`)
read `.in` fixtures and skip gracefully if none are present. To enable them locally, drop any `.in` export
as `fixtures/diary.in` (or matching name) — `fixtures/*.in` is git-ignored, never commit note samples.

This repo requires a **nightly Zig** (`master` in CI via `mlugg/setup-zig@v2`) — it uses very recent std
APIs (`std.array_list.Managed`, `std.Io.Dir`, ...) not present in any stable release. If the build breaks
on a new nightly, pin CI to a known-good version from ziglang.org/download/index.json after verifying with
`zig build test` locally.

Deploy is automatic: pushing to `master` runs `.github/workflows/deploy.yml` (zig + bun build, then
`wrangler-action` deploy). `wrangler.toml` at the repo root points `[assets]` at `web/dist`.

## Architecture

### Two runtimes, one boundary

- `wasm/src/` — Zig, compiled freestanding to `web/src/wasm/notein.wasm` (`wasm/build.zig`). Owns: ZIP
  reading (`zip.zig`), SQLite paging/btree/record decoding (`sqlite/`), WAL replay (`wal.zig`), the note
  model (`model.zig`), lazy per-item JSON decode of stroke/shape/textbox records (`window.zig`), and
  scanline polygon rasterization (`raster.zig`). `main.zig` is the sole C-ABI surface (`export fn` — alloc,
  `open`, `render_viewport`, `get_visible_*`, `get_all_*`, `build_media_zip`, etc.) — this is the only file
  that should grow new exports.
- `web/src/wasm/loader.ts` — the one TS file that knows the wasm ABI: typed wrappers over the exported
  functions, reading packed structs directly out of wasm linear memory (zero-copy views) instead of
  serializing. Every other TS file talks to wasm only through `NoteinModule` from this file.

### Note model and the "active window"

A `.in` file can be tens of MB of stroke JSON. `main.zig`/`window.zig` avoid decoding all of it up front:
`model.zig` builds a cheap per-item index (bounds + a pointer back into the SQLite row) for every
stroke/shape/textbox at load time; `set_active_window(pageIndices)` tells wasm which pages are worth lazily
JSON-decoding into `window.zig`'s decoded-item cache. The frontend's `Renderer.updateActiveWindow()`
(`web/src/canvas/renderer.ts`) recomputes this window from the currently visible pages (+1 page prefetch
margin) every frame and only calls `set_active_window` when the page set actually changes. The minimap
(`web/src/canvas/minimap.ts`) also temporarily steals the active window to rasterize thumbnails, then calls
back (`onActiveWindowStolen`) so the renderer knows to resync (`resyncActiveWindow`) before its next frame.

### Coordinate spaces

Three layers, and most bugs in this codebase are about which one a value is in:

1. **Page-local** — what wasm speaks. Stroke/image/textbox bounds and `render_viewport(page_index, x, y,
   w, h, ...)` are all relative to a page's own origin.
2. **World/note space** — one shared coordinate space per note, built once by `layoutNote()`
   (`web/src/canvas/layout.ts`): bounded pages are stacked vertically with a gap and centered
   horizontally (mixed page widths/orientations in one note); an *unbounded* (infinite-canvas) page just
   gets its own box at a nominal size (`UNBOUNDED_FALLBACK_SIZE` when `paper_spec` doesn't give a usable
   size — see caveat below). `PageLayout.x/y` is the offset from page-local into world space.
3. **Screen/device pixels** — `Viewport.camera` (`web/src/canvas/viewport.ts`) is `{x, y, zoom}` in
   *CSS-pixel-calibrated* world units (matches pointer/wheel input); `Renderer` converts to device pixels
   via `camera.zoom * viewport.dpr` for the HiDPI canvas backing store.

`renderPage()` in `renderer.ts` intersects the page's world-space box with the camera viewport, converts
back to page-local (`localX = vx0 - page.x`, etc.), and only then calls into wasm — so wasm never sees
world-space coordinates. `frameToBounds()` (`layout.ts`) does the inverse for jump-to-item (media/links
panels): page-local bounds -> world space -> `viewport.frame()`.

**Known caveat**: an unbounded page's box in `layoutNote()` is a guess (`paper_spec` sizes from the Notein
app are frequently a nominal `1920x1920` or absent entirely, *not* the actual ink extent — real infinite-
canvas content can have negative/far-out coordinates well outside that box). Since `renderPage()` clips to
the intersection of the *box*, not the actual content, ink outside the guessed box is currently invisible
no matter how far the camera pans — this is the root cause behind reports of "content left of/above the
first page never loads." A real fix needs an aggregate content-bounds pass (over strokes/shapes/images/text
per page) surfaced from `model.zig`, not just a bigger guessed box.

### Rendering pipeline (`Renderer.render()` in `renderer.ts`)

1. `visiblePages(layout, camera...)` — which page boxes intersect the viewport.
2. `updateActiveWindow(visible)` — see above.
3. Per visible page: intersect viewport with the page box, convert to page-local rect, call
   `wasm.getVisibleImages` / `getVisibleTextBoxes` for that rect, merge with ink into one list sorted by
   `creationTime`, and draw in **chronological order** (not "all ink then all images") so e.g. annotations
   on top of a pasted photo composite correctly. Ink itself renders via `wasm.renderViewport(...)`, which
   returns packed RGBA pixels directly into wasm memory (`drawInk`) — `time_min`/`time_max` let the same
   call rasterize just the ink strokes that fall between two overlay items' creation times.
4. `export-render.ts` reuses this exact `render_viewport` path on an offscreen canvas/SVG at 1x/2x/4x for
   PNG/PDF/SVG export — keep the two in sync when changing rendering logic.

### Media/Links panels

`get_all_images` / `get_all_links` / `get_all_audio` are called once, lazily, on first panel open (not at
load time) — `web/src/media-panel.tsx`, `web/src/links-panel.tsx`. Per-item bytes come from
`get_bytes(name)`, resolved from the ZIP by name. "Download all media" builds a real ZIP (STORE, local +
central headers, CRC32) inside Zig (`wasm/src/zip_writer.zig`) rather than pulling in a JS zip library.

## File format reference

See `FORMAT.md` for the full reverse-engineered `.in`/SQLite schema (this is the authoritative spec used to
write `model.zig`'s table scans — update both together if the format understanding changes). Quick summary:
`.in` is an unencrypted ZIP containing a Room/SQLite DB (`note_database_note_<uuid>_db` + `-wal`/`-shm`) plus
loose JSON metadata files and `note_image_*`/`note_audio_*` blobs referenced by name from the DB. Key
tables: `NoteContentEntity`, `PageEntity` (`paper_spec`, `unbounded`), `StrokeEntity` (`record_json` →
`points: {x,y,p,action}[]`), `TextBoxEntity`, `ImageEntity`, `ShapeEntity`, `HyperLinkEntity`,
`AudioFileEntity`.
