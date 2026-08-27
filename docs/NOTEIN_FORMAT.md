# Notein (`.in`) File Format — Reverse-Engineering Summary

## What it is

`.in` is the note export/backup format used by **Notein** ("Notein: Handwriting Notes & PDF"), an Android stylus note-taking app by **ORION STUDIO PTE. LTD.** (package: `com.orion.notein.global`). Despite the custom extension, the file is a plain ZIP archive — no encryption or obfuscation on the container level.

## Container structure

Unzipping a `.in` file yields:

| File | Purpose |
|---|---|
| `note_database_note_<note-uuid>_db` | Main SQLite database — all note content lives here |
| `…_db-wal`, `…_db-shm` | SQLite Write-Ahead Log + shared-memory files. The WAL must be replayed on top of `…_db` to get the final state — the viewer does this at load time (see `wasm/src/wal.zig`) |
| `note_meta.json` | Note-level metadata: title, creation/modification timestamps, favorite flag, trash flag, thumbnail path, parent folder id, owning user id |
| `note_extra.json` | Small internal counter/flag object (obfuscated keys, low information value) |
| `note_in_flag.json` | Boolean feature flags (obfuscated keys — UI toggle states) |
| `note_label.json` | Labels/tags attached to the note (empty if none) |
| `notepdf_lost_info.json` | Placeholder for PDF-recovery metadata (present even when the note has no PDF) |
| `note_image_<uuid>.*` | Embedded images (PNG/JPEG/GIF), referenced by name from the DB |
| `note_audio_<uuid>.*` | Embedded audio recordings, referenced by name from the DB |

The note's UUID is embedded in the DB filename (`note_database_note_<uuid>_db`) — the sole `NoteContentEntity` row matching that UUID is the active note (exports may contain multiple notes' rows).

## The database

A standard SQLite 3 database (Room-generated). Key tables:

### `NoteContentEntity`
One row per note. Columns include `id` (UUID), `page_list` (JSON array of `PageEntity` ids, ordered), `unbounded_note` (bool), zoom/pan state, layer/outline lists, and `default_page_id`. The viewer resolves pages in `page_list` order.

### `PageEntity`
One row per page: `id`, `note_id`, `paper_spec` (JSON with `preciseWidth` / `preciseHeight` in points — e.g. `1920×1920` for an infinite-canvas page, often nominal), `page_orientation`, `paper_theme` (JSON — `baseTheme.color` holds the actual paper color as an Android ARGB `int`; `padding_color` is the margin outside the paper, not the paper itself), `unbounded` (bool), `creation_time`, `tn_path`, etc. A multi-page A4 document is multiple `PageEntity` rows; an infinite-canvas note is typically one logical page with an unbounded coordinate space.

> **Important nuance — declared size vs. real content:** `paper_spec` for unbounded pages is frequently a placeholder (`1920×1920`) or absent, not the actual ink extent. Real infinite-canvas content can extend arbitrarily far, including negative coordinates. The viewer therefore also computes a per-page `content_bounds` (union of every stroke/shape/text/image/link bounds on that page) and sizes unbounded pages to that union (see `model.zig:Page.content_bounds` and `layout.ts:layoutNote`). Without this, ink outside the guessed box is invisible.

### `StrokeEntity`
One row per pen stroke — the handwriting itself. Columns: `page_id`, `left`/`top`/`right`/`bottom` (bounds, page-local), `record_json` (JSON blob):

```json
{
  "color": -16777216,
  "width": 4.2,
  "creationTime": 1714000000000,
  "bounds": { "left": 0, "top": 0, "right": 100, "bottom": 50 },
  "layerId": "...",
  "points": [{ "x": 12.3, "y": 45.6, "p": 0.72, "action": 0 }, ...]
}
```

- `points[].p` — pressure in `0..1` (affects stroke width)
- `points[].action` — `0` start, `2` move, `1` end
- `color` — signed 32-bit ARGB `int` (reinterpret low 32 bits unsigned)
- There is **no stored text** — handwriting is pure vector ink.

### `ShapeEntity`
Ruler-guided strokes (rectangles, lines, etc.). Columns: `page_id`, `color`, `width`, `points` (JSON array of `{x,y}`), `type`, `creation_time`, `left`/`top`/`right`/`bottom`. Drawn as stroked outlines (quads per edge, see `tessellate.zig:quadForLine`), never filled — the format carries no fill flag.

### `TextBoxEntity`
Typed text boxes: `page_id`, `text`, `text_size`, `box_width`/`box_height`, `default_text_color` (ARGB), `left`/`top`/`right`/`bottom`, `creation_time`. Rendered natively by the frontend (Canvas `fillText`), not by WASM raster.

### `ImageEntity`
Inserted images: `uri` (path whose basename maps to `note_image_<basename>` in the ZIP), `page_id`, `left`/`top`/`right`/`bottom`, `creation_time`, `rotation`. ZIP entry name is derived from `uri` basename, not `id`.

### `HyperLinkEntity`
Links: `page_id`, `type`, `destination` (URL), `creation_time`, `left`/`top`/`right`/`bottom`. `type` distinguishes web vs. internal links; bounds are page-local.

### `AudioFileEntity`
Audio recordings: `file_path` (basename maps to `note_audio_<basename>`), `audio_name` (display name), `duration` (ms), `creation_time`. Same basename-to-ZIP derivation as images.

### Other tables
`PdfInfoEntity` (source PDF for annotations), `PageLayerEntity` (layer visibility/names per page), `OutlineEntity` / `DualLinkRefEntity` / `DualLinkSourceEntity` / `AudioSyncRecordEntity` / `QuoteEntity` / `CommentEntity` — present in the schema but often empty; same pattern of `page_id` + bounds + JSON payload.

## Bounded vs. infinite canvas

Both modes are stored identically except for a flag and a size:

- **Bounded (A4/Letter/etc.):** `PageEntity.unbounded = 0`, `paper_spec` gives the fixed page size, pages stack vertically via `page_list`.
- **Infinite canvas:** `PageEntity.unbounded = 1`, single large coordinate space. Strokes carry absolute page-local coordinates regardless of mode and may be negative or far outside `[0, width]×[0, height]`.

## Rendering notes (how the viewer replays this)

- **Pressure → width:** each point's `p` scales the stroke's base `width` (`radius = base_width * max(0.15, p) * 0.5`), tessellated into a filled ribbon polygon (`wasm/src/tessellate.zig:tessellateStroke`). Catmull-Rom smoothing subdivides sparse samples so curves stay smooth when zoomed in (`window.zig:smoothPoints`).
- **Scanline raster:** polygons are filled with a nonzero-winding, subpixel-AA scanline rasterizer (`wasm/src/raster.zig:fillPolygon`) — nonzero winding is required because variable-width ribbons self-overlap at sharp corners.
- **Chronological compositing:** strokes, shapes, images, and text are interleaved by `creationTime` so ink annotated on a pasted photo correctly appears on top of it. WASM exposes `render_viewport(..., time_min, time_max)` so the frontend can rasterize ink in slices between overlay items.

## Practical takeaway

To read a `.in` file programmatically: unzip → replay the WAL onto `…_db` if `…_db-wal` exists → open `…_db` with any SQLite library → read `StrokeEntity.record_json` (and `ShapeEntity`/`TextBoxEntity`/`ImageEntity`/`HyperLinkEntity` for overlays) per page → replay each stroke's point array through a pressure-aware tessellator to reconstruct handwriting. Everything needed to fully reconstruct a note is plain JSON inside standard SQLite rows — nothing is proprietary-binary or encrypted.
