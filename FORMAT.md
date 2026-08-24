# Notein (`.in`) File Format — Reverse-Engineering Summary

## What it is
`.in` is the note export/backup format used by **Notein** ("Notein: Handwriting Notes & PDF"), an Android stylus note-taking app by **ORION STUDIO PTE. LTD.** (package: `com.orion.notein.global`). Despite the extension looking custom, the file is a plain ZIP archive — no encryption or obfuscation on the container level.

## Container structure
Unzipping a `.in` file yields:

| File | Purpose |
|---|---|
| `note_database_note_<note-uuid>_db` | Main SQLite database — all note content lives here |
| `..._db-wal`, `..._db-shm` | SQLite Write-Ahead Log + shared-memory files (standard SQLite journaling artifacts, safe to ignore for a static export) |
| `note_meta.json` | Note-level metadata: title, creation/modification timestamps, favorite flag, trash flag, thumbnail path, parent folder id, owning user id |
| `note_extra.json` | Small internal counter/flag object (obfuscated key names, low information value) |
| `note_in_flag.json` | Boolean feature flags (also obfuscated keys — likely UI toggle states) |
| `note_label.json` | Labels/tags attached to the note (empty if none applied) |
| `notepdf_lost_info.json` | Placeholder for PDF-recovery metadata (present even when the note has no attached PDF) |

## The database (the important part)
It's a normal SQLite 3 database (Room-generated, based on the schema conventions). Key tables:

- **`NoteContentEntity`** — one row per note. Points to its page list, layer list, zoom/pan state, and whether the note is `unbounded` (infinite canvas) or a fixed page size.
- **`PageEntity`** — one row per page. Contains `paper_spec` (JSON: width/height in points, e.g. 1920×1920 for infinite canvas), orientation, paper theme/background color, and an `unbounded` flag. A multi-page A4 document is just multiple `PageEntity` rows chained together; an infinite-canvas note has effectively one very large page.
- **`StrokeEntity`** — one row per pen stroke. This is where handwriting actually lives. Each row has a `record_json` blob containing:
  - `points`: an array of `{x, y, p, action}` samples — `p` is pen pressure (0–1), `action` marks stroke start/move/end (0/2/1).
  - `color`, `width`, `bounds` (bounding box), `layerId`, `creationTime`.
  - There is **no stored text** — handwriting is pure vector ink, reconstructed visually from the point path, not OCR'd or stored as characters.
- **`TextBoxEntity`** — typed (non-handwritten) text boxes, if any, with position, size, font size, color.
- **`ImageEntity`**, **`ShapeEntity`**, **`HyperLinkEntity`**, **`QuoteEntity`**, **`CommentEntity`** — inserted images, drawn shapes (rectangles/rulers/etc.), links, PDF quote/highlight annotations, and comments — same pattern: position + bounds + a JSON payload, one table per content type.
- **`PdfInfoEntity`** — if the note is annotations *on top of* an imported PDF, this stores the source PDF path/thumbnail.
- **`PageLayerEntity`** — layer visibility/name per page (Notein supports multiple ink layers per page, like Procreate).
- **`OutlineEntity`**, **`DualLinkRefEntity`/`DualLinkSourceEntity`**, **`AudioFileEntity`/`AudioSyncRecordEntity`** — outline/table-of-contents entries, bidirectional note-linking (backlinks), and audio recordings synced to strokes (for narrated notes) — all empty in this sample but part of the schema.

## Bounded vs. infinite canvas
Both are stored identically — the only difference is a flag and a size:
- **Bounded (A4/Letter/etc.)**: `PageEntity.unbounded = 0`, `paper_spec` gives fixed width/height, multiple pages chain via `NoteContentEntity.page_list`.
- **Infinite canvas**: `PageEntity.unbounded = 1`, a single very large coordinate space; the app just pans/zooms a viewport over it. Strokes carry absolute coordinates in this space regardless of mode.

## Practical takeaway
To read a `.in` file programmatically: unzip → open the `..._db` file with any SQLite library → read `StrokeEntity.record_json` per page → replay each stroke's point array (ideally through a pressure-aware renderer like *perfect-freehand*) to reconstruct the handwriting visually. Everything needed to fully reconstruct a note (ink, text, images, shapes, PDF background) is plain JSON inside standard SQLite rows — nothing is proprietary-binary or encrypted.
