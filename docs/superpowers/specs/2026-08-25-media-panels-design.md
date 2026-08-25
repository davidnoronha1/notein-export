# Media panels, links panel, and selection-menu positioning fix

## Problem

1. The region-export floating menu (`#export-panel`) is positioned at a fixed
   offset from the selection's right edge (`main.ts:234-235`), which reads as
   randomly placed rather than attached to the selection.
2. There's no way to see or download the images, audio recordings, or
   hyperlinks embedded in a note without exporting whole pages/regions.

## Schema findings (from a real `.in` export)

`HyperLinkEntity` and `AudioFileEntity` were previously undocumented (empty in
the format's original reverse-engineering sample). Confirmed via a real
export's SQLite schema:

```
HyperLinkEntity: id, bounds(json, unused), page_id, type, destination, extras(json, unused),
                  creation_time, last_modification_time, left, top, right, bottom
AudioFileEntity: id, file_path, audio_name, duration, play_speed, creation_time, last_modification_time
```

`AudioFileEntity` has no `page_id`/bounds — audio isn't anchored to a page or
canvas position (association to strokes lives in `AudioSyncRecordEntity`,
which we don't need for browsing/downloading). Its zip entry name is derived
the same way images derive theirs: `note_audio_<basename of file_path>`.

`AudioSyncRecordEntity`, `DualLinkRefEntity`/`DualLinkSourceEntity` are out of
scope — not needed to list or download media.

## 1. Selection menu positioning fix

In `selectionOverlayEl`'s `pointerup` handler (`main.ts`), replace the
right-of-selection placement with a floating-toolbar placement:
- Show the panel first (so `getBoundingClientRect()` reflects its real size).
- Horizontally center it under the selection's midpoint, clamped so it never
  leaves the viewport (`[8, viewportWidth - panelWidth - 8]`).
- Anchor below the selection's bottom edge with an 8px gap; flip to above the
  selection's top edge if there isn't enough room below.

## 2. Zig parser additions (`wasm/src/model.zig`)

```zig
pub const LinkAsset = struct {
    page_index: u32,
    bounds: Bounds,
    destination: []const u8,
    link_type: i64,
    creation_time: i64,
};

pub const AudioAsset = struct {
    name: []const u8,           // audio_name, for display
    zip_entry_name: []const u8, // resolved at load time, like ImageAsset
    duration_ms: i64,
    creation_time: i64,
};
```

`Note` gains `links: []LinkAsset` and `audio: []AudioAsset`, populated by
`scanLinks` (mirrors `scanImages`'s page-matching, no zip lookup needed) and
`scanAudio` (whole-table scan, no page filter; skips rows whose derived zip
entry is missing from the archive, same graceful-skip as images).

## 3. Wasm exports (`wasm/src/main.zig`)

New extern structs, `creation_time`/other f64 fields listed first so the
natural C layout needs no interior padding (same convention as
`VectorPoly`/`TextBoxDraw`):

```zig
const AssetImageDraw = extern struct { creation_time: f64, left: f32, top: f32, right: f32, bottom: f32, page_index: u32, name_ptr: u32, name_len: u32 }; // stride 40
const LinkDraw = extern struct { creation_time: f64, left: f32, top: f32, right: f32, bottom: f32, page_index: u32, link_type: i32, dest_ptr: u32, dest_len: u32 }; // stride 40
const AudioDraw = extern struct { creation_time: f64, duration_ms: f64, name_ptr: u32, name_len: u32, entry_ptr: u32, entry_len: u32 }; // stride 32
```

New exports: `get_all_images_count/ptr`, `get_all_links_count/ptr`,
`get_all_audio_count/ptr` — unfiltered (whole-note, not viewport-culled;
counts are small enough not to need windowing). Existing
`get_visible_image_*` is untouched (still used for rendering).

## 4. JS bindings (`web/src/wasm/loader.ts`)

`getAllImages(): AssetImage[]`, `getAllLinks(): LinkLoaderAsset[]`,
`getAllAudio(): AudioLoaderAsset[]` — same DataView-stride-read pattern as
`getVisibleImages`/`getVectorContent`. Byte fetching for thumbnails/downloads
reuses the existing `getBytes(name)`.

## 5. UI

Two new toggle buttons in `#export-control` (same style as `#select-tool`):
**Media** and **Links**, each opening a small floating drawer docked
top-right of `#viewer` (dark, rounded, matching `#export-panel`/`#minimap`
styling), independent of the export-panel/selection flow.

**Media panel**: tab bar (Images | Audio) plus a "Download all (zip)"
button in the header that zips *everything* regardless of active tab
(`images/` and `audio/` folders in one zip), using `fflate`'s `zipSync` with
`level: 0` (store only — PNG/JPEG/M4A are already compressed, so
recompressing wastes CPU for no size benefit). Byte fetches for the zip and
the two tabs reuse `wasm.getBytes`.
- *Images tab*: thumbnail grid (loaded via `getBytes` + `createImageBitmap`).
  Click a thumbnail → `viewport.frame()` to the image's world rect (its
  page's layout offset + its bounds). A small download icon per thumbnail
  downloads that one image (reusing `triggerDownload`, exported from
  `export.ts`).
- *Audio tab*: list rows (name, `mm:ss` duration, native `<audio controls>`
  sourced from a blob URL created from `getBytes`, download button). No
  jump-to (audio has no page/bounds).

**Links panel**: list rows showing `destination` (truncated, full text in
`title`). A "Jump" button when the row has valid bounds (same
`viewport.frame()` mechanism). If `destination` starts with `http://` or
`https://`, also show an "Open ↗" link (`target=_blank rel=noopener`). No
download/zip here — links aren't files.

## Out of scope

- `AudioSyncRecordEntity`-based "jump to audio position" — audio browsing
  only needs listing/playback/download.
- Bulk download for links (not files).
- Any change to existing per-page/per-region PNG/PDF/SVG export flows.

## New dependency

`fflate` (small, dependency-free, MIT) added to `web/package.json` for
client-side zip creation.
