# Media Panels, Links Panel, and Selection-Menu Positioning — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the region-export floating menu so it's attached to the
selection instead of floating on the right, and add two new openable
drawers — a Media panel (Images/Audio tabs, per-item and bulk-zip download,
click-to-jump) and a Links panel (list + jump + open-external) — to the
Notein viewer.

**Architecture:** New Zig parsing (`HyperLinkEntity`, `AudioFileEntity`) in
`wasm/src/model.zig`, three new unfiltered (whole-note) wasm exports in
`wasm/src/main.zig`, matching typed bindings in `web/src/wasm/loader.ts`, and
two small self-contained UI classes (`MediaPanel`, `LinksPanel`) wired into
`main.ts`. No new JS test framework is introduced — this project has none;
Zig gets real `zig build test` coverage (this project's existing pattern),
JS/TS changes are verified via `tsc`/`vite build` plus manual browser checks
against the local `fixtures/diary.in`, matching how `renderer.ts`/
`minimap.ts`/`viewport.ts` are already verified.

**Tech Stack:** Zig (wasm parser), TypeScript + Vite (web viewer), `fflate`
(new dependency, client-side zip creation), `bun` (package manager — see
`web/bun.lock`).

**Spec:** `docs/superpowers/specs/2026-08-25-media-panels-design.md`

## Global Constraints

- No bulk download for links (they're not files).
- "Download all" zips images (`images/`) and audio (`audio/`) together into
  one `notein-media.zip`, using `fflate`'s `zipSync` with `level: 0` (store
  only — assets are already-compressed PNG/JPEG/M4A).
- Audio has no page/bounds — no "jump to" for audio rows.
- Don't touch the existing per-page/per-region PNG/PDF/SVG export flows.
- `fixtures/diary.in` is gitignored (`fixtures/*.in`) — it must never be
  committed. It already exists locally (copied from the user's own export)
  and existing `zig build test` integration tests already depend on it,
  skipping gracefully when absent.

---

### Task 1: Fix selection-menu positioning

**Files:**
- Modify: `web/src/main.ts:212-237` (the `selectionOverlayEl` `pointerup` handler)

**Interfaces:**
- Consumes: existing `exportPanelEl`, `selectionOverlayEl`, `viewport` — no new types.
- Produces: nothing consumed by later tasks (fully independent).

- [ ] **Step 1: Replace the fixed right-of-selection placement with an attached floating-toolbar placement**

In `web/src/main.ts`, find the end of the `pointerup` handler:

```ts
    const p0 = viewport.screenToWorld(screenLeft, screenTop);
    const p1 = viewport.screenToWorld(screenRight, screenBottom);
    pendingRect = { x: p0.x, y: p0.y, w: p1.x - p0.x, h: p1.y - p0.y };

    exportPanelEl.style.left = `${Math.min(rect.width - 8, screenRight + 8)}px`;
    exportPanelEl.style.top = `${Math.max(8, screenTop)}px`;
    exportPanelEl.classList.remove("hidden");
  });
```

Replace it with:

```ts
    const p0 = viewport.screenToWorld(screenLeft, screenTop);
    const p1 = viewport.screenToWorld(screenRight, screenBottom);
    pendingRect = { x: p0.x, y: p0.y, w: p1.x - p0.x, h: p1.y - p0.y };

    // Show first so getBoundingClientRect() below reflects the panel's real
    // size -- centering/clamping needs the actual width, not a guess.
    exportPanelEl.classList.remove("hidden");
    const panelRect = exportPanelEl.getBoundingClientRect();
    const centerX = (screenLeft + screenRight) / 2;
    const left = Math.max(8, Math.min(rect.width - panelRect.width - 8, centerX - panelRect.width / 2));
    const fitsBelow = screenBottom + 8 + panelRect.height <= rect.height - 8;
    const top = fitsBelow ? screenBottom + 8 : Math.max(8, screenTop - panelRect.height - 8);
    exportPanelEl.style.left = `${left}px`;
    exportPanelEl.style.top = `${top}px`;
  });
```

This centers the panel under the selection's midpoint, clamps it to stay
within the viewer horizontally, anchors it 8px below the selection, and
flips above the selection if there isn't room below.

- [ ] **Step 2: Type-check**

Run: `cd web && npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Manual verification**

Run `cd web && npm run dev`, open the printed local URL, load
`~/Desktop/diary.in` (or any `.in` file), click "Select region…", drag a
selection near the right edge of the viewer, and confirm the PNG/PDF/SVG
menu appears centered below the selection (not pinned to the right), and
flips above when dragging a selection near the bottom edge.

- [ ] **Step 4: Commit**

```bash
git add web/src/main.ts
git commit -m "fix: attach region-export menu to selection instead of floating right"
```

---

### Task 2: Parse HyperLinkEntity and AudioFileEntity in the wasm model

**Files:**
- Modify: `wasm/src/model.zig`
- Modify: `wasm/src/model_integration_test.zig`
- Modify: `wasm/src/integration_test.zig`

**Interfaces:**
- Produces: `model.LinkAsset { page_index: u32, bounds: Bounds, destination: []const u8, link_type: i64, creation_time: i64 }`,
  `model.AudioAsset { name: []const u8, zip_entry_name: []const u8, duration_ms: i64, creation_time: i64 }`,
  and `Note.links: []LinkAsset`, `Note.audio: []AudioAsset` — consumed by Task 3.

- [ ] **Step 1: Write the failing test (extend the existing fixture-backed test)**

In `wasm/src/model_integration_test.zig`, after the existing
`try std.testing.expectEqual(@as(usize, 29), note.images.len);` line, add:

```zig
    try std.testing.expectEqual(@as(usize, 0), note.links.len);
    try std.testing.expectEqual(@as(usize, 1), note.audio.len);
```

And after the existing `for (note.images) |img| try std.testing.expect(img.page_index < note.pages.len);` line, add:

```zig
    for (note.links) |l| try std.testing.expect(l.page_index < note.pages.len);
    if (note.audio.len > 0) {
        try std.testing.expect(note.audio[0].duration_ms > 0);
        try std.testing.expect(note.audio[0].zip_entry_name.len > 0);
    }
```

In `wasm/src/integration_test.zig`, in the `expectations` array inside
`test "diary.in: row counts match known sample values"`, add two entries:

```zig
        .{ .table = "HyperLinkEntity", .count = 0 },
        .{ .table = "AudioFileEntity", .count = 1 },
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `cd wasm && zig build test 2>&1 | tail -30`
Expected: compile error — `note` (type `model.Note`) has no field `links` (and/or `audio`).

- [ ] **Step 3: Add the new asset types and scan functions to `model.zig`**

In `wasm/src/model.zig`, after the existing `ImageAsset` struct, add:

```zig
pub const LinkAsset = struct {
    page_index: u32,
    bounds: Bounds,
    destination: []const u8,
    link_type: i64,
    creation_time: i64,
};

pub const AudioAsset = struct {
    /// Display name (AudioFileEntity.audio_name), e.g. "Recording 1".
    name: []const u8,
    /// Zip entry name, resolved at load time like ImageAsset.zip_entry_name.
    zip_entry_name: []const u8,
    duration_ms: i64,
    creation_time: i64,
};
```

In the `Note` struct, add two fields after `images: []ImageAsset,`:

```zig
    links: []LinkAsset,
    audio: []AudioAsset,
```

In `model.open`, after the existing `const images = try scanImages(alloc, db, archive, pages);` line, add:

```zig
    const links = try scanLinks(alloc, db, pages);
    const audio = try scanAudio(alloc, db, archive);
```

And in the `Note` struct literal returned by `open`, add after `.images = images,`:

```zig
        .links = links,
        .audio = audio,
```

At the end of the file, after `scanImages`, add:

```zig
fn scanLinks(alloc: std.mem.Allocator, db: pager.Db, pages: []const Page) ![]LinkAsset {
    const root = (try schema.findTableRoot(db, "HyperLinkEntity")) orelse return Error.TableNotFound;

    const Ctx = struct {
        alloc: std.mem.Allocator,
        db: pager.Db,
        pages: []const Page,
        out: std.array_list.Managed(LinkAsset),
    };
    var ctx = Ctx{ .alloc = alloc, .db = db, .pages = pages, .out = std.array_list.Managed(LinkAsset).init(alloc) };

    const visit = struct {
        fn f(c: *Ctx, row: btree.Row) !void {
            const hdr = try row.header();
            // HyperLinkEntity: id, bounds(json, unused), page_id, type, destination,
            // extras(json, unused), creation_time, last_modification_time, left, top, right, bottom
            const page_id = try readColumn(c.alloc, c.db, row, hdr, 2);
            var page_index: u32 = std.math.maxInt(u32);
            for (c.pages, 0..) |p, i| {
                if (std.mem.eql(u8, p.id, page_id)) {
                    page_index = @intCast(i);
                    break;
                }
            }
            if (page_index == std.math.maxInt(u32)) return; // orphaned row

            const link_type = readColumnI64(c.db, row, hdr, 3);
            const destination = try readColumn(c.alloc, c.db, row, hdr, 4);
            const creation_time = readColumnI64(c.db, row, hdr, 6);
            const bounds = readBounds(c.db, row, hdr, 8);
            try c.out.append(.{ .page_index = page_index, .bounds = bounds, .destination = destination, .link_type = link_type, .creation_time = creation_time });
        }
    }.f;
    try btree.scanTable(db, root, *Ctx, &ctx, visit);
    return ctx.out.toOwnedSlice();
}

fn scanAudio(alloc: std.mem.Allocator, db: pager.Db, archive: zip.Archive) ![]AudioAsset {
    const root = (try schema.findTableRoot(db, "AudioFileEntity")) orelse return Error.TableNotFound;

    const Ctx = struct {
        alloc: std.mem.Allocator,
        db: pager.Db,
        archive: zip.Archive,
        out: std.array_list.Managed(AudioAsset),
    };
    var ctx = Ctx{ .alloc = alloc, .db = db, .archive = archive, .out = std.array_list.Managed(AudioAsset).init(alloc) };

    const visit = struct {
        fn f(c: *Ctx, row: btree.Row) !void {
            const hdr = try row.header();
            // AudioFileEntity: id, file_path, audio_name, duration, play_speed, creation_time, last_modification_time
            const file_path = try readColumn(c.alloc, c.db, row, hdr, 1);
            const audio_name = try readColumn(c.alloc, c.db, row, hdr, 2);
            const duration_ms = readColumnI64(c.db, row, hdr, 3);
            const creation_time = readColumnI64(c.db, row, hdr, 5);

            // Zip entry name is derived from file_path's basename, same
            // pattern as ImageEntity.uri.
            const basename = if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |i| file_path[i + 1 ..] else file_path;
            const entry_name = try std.fmt.allocPrint(c.alloc, "note_audio_{s}", .{basename});
            if (c.archive.find(entry_name) == null) return; // asset missing from export, skip gracefully

            try c.out.append(.{ .name = audio_name, .zip_entry_name = entry_name, .duration_ms = duration_ms, .creation_time = creation_time });
        }
    }.f;
    try btree.scanTable(db, root, *Ctx, &ctx, visit);
    return ctx.out.toOwnedSlice();
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd wasm && zig build test 2>&1 | tail -30`
Expected: all tests pass (no `error:` lines, no `FAIL`).

- [ ] **Step 5: Commit**

```bash
git add wasm/src/model.zig wasm/src/model_integration_test.zig wasm/src/integration_test.zig
git commit -m "feat(wasm): parse HyperLinkEntity and AudioFileEntity into Note.links/audio"
```

---

### Task 3: Expose all-images/links/audio as wasm exports

**Files:**
- Modify: `wasm/src/main.zig`

**Interfaces:**
- Consumes: `Note.links`, `Note.audio`, `Note.images` (Task 2).
- Produces: exports `get_all_images_count/ptr`, `get_all_links_count/ptr`,
  `get_all_audio_count/ptr` with extern struct layouts documented below —
  consumed by Task 4's `loader.ts` bindings via these exact byte offsets.

- [ ] **Step 1: Add the extern structs and export buffers**

In `wasm/src/main.zig`, after the existing `g_bytes_buf`/`g_vector_*_buf`
declarations, add:

```zig
var g_asset_image_buf: []AssetImageDraw = &.{};
var g_link_draw_buf: []LinkDraw = &.{};
var g_audio_draw_buf: []AudioDraw = &.{};
```

After the existing `VectorPoly` extern struct declaration, add (f64 fields
first, same convention as `VectorPoly`/`TextBoxDraw`, so the natural C
layout needs no interior padding):

```zig
// stride 40: f64 creation_time, 4x f32 bounds, u32 page_index, u32 name_ptr, u32 name_len
const AssetImageDraw = extern struct { creation_time: f64, left: f32, top: f32, right: f32, bottom: f32, page_index: u32, name_ptr: u32, name_len: u32 };
// stride 40: f64 creation_time, 4x f32 bounds, u32 page_index, i32 link_type, u32 dest_ptr, u32 dest_len
const LinkDraw = extern struct { creation_time: f64, left: f32, top: f32, right: f32, bottom: f32, page_index: u32, link_type: i32, dest_ptr: u32, dest_len: u32 };
// stride 32: f64 creation_time, f64 duration_ms, u32 name_ptr, u32 name_len, u32 entry_ptr, u32 entry_len
const AudioDraw = extern struct { creation_time: f64, duration_ms: f64, name_ptr: u32, name_len: u32, entry_ptr: u32, entry_len: u32 };
```

- [ ] **Step 2: Add the three export pairs**

At the end of `wasm/src/main.zig` (after `get_bytes_len`), add:

```zig
/// Returns ALL images in the note (not viewport-culled, unlike
/// get_visible_image_*) -- for the Media panel's Images tab.
export fn get_all_images_count() u32 {
    const s = &(g_state orelse return 0);
    gpa.free(g_asset_image_buf);
    g_asset_image_buf = gpa.alloc(AssetImageDraw, s.note.images.len) catch return 0;
    for (s.note.images, 0..) |img, i| {
        g_asset_image_buf[i] = .{
            .creation_time = @floatFromInt(img.creation_time),
            .left = img.bounds.left,
            .top = img.bounds.top,
            .right = img.bounds.right,
            .bottom = img.bounds.bottom,
            .page_index = img.page_index,
            .name_ptr = @intFromPtr(img.zip_entry_name.ptr),
            .name_len = @intCast(img.zip_entry_name.len),
        };
    }
    return @intCast(g_asset_image_buf.len);
}

export fn get_all_images_ptr() u32 {
    return @intFromPtr(g_asset_image_buf.ptr);
}

/// Returns ALL hyperlinks in the note -- for the Links panel.
export fn get_all_links_count() u32 {
    const s = &(g_state orelse return 0);
    gpa.free(g_link_draw_buf);
    g_link_draw_buf = gpa.alloc(LinkDraw, s.note.links.len) catch return 0;
    for (s.note.links, 0..) |link, i| {
        g_link_draw_buf[i] = .{
            .creation_time = @floatFromInt(link.creation_time),
            .left = link.bounds.left,
            .top = link.bounds.top,
            .right = link.bounds.right,
            .bottom = link.bounds.bottom,
            .page_index = link.page_index,
            .link_type = @truncate(link.link_type),
            .dest_ptr = @intFromPtr(link.destination.ptr),
            .dest_len = @intCast(link.destination.len),
        };
    }
    return @intCast(g_link_draw_buf.len);
}

export fn get_all_links_ptr() u32 {
    return @intFromPtr(g_link_draw_buf.ptr);
}

/// Returns ALL audio recordings in the note -- for the Media panel's Audio tab.
export fn get_all_audio_count() u32 {
    const s = &(g_state orelse return 0);
    gpa.free(g_audio_draw_buf);
    g_audio_draw_buf = gpa.alloc(AudioDraw, s.note.audio.len) catch return 0;
    for (s.note.audio, 0..) |a, i| {
        g_audio_draw_buf[i] = .{
            .creation_time = @floatFromInt(a.creation_time),
            .duration_ms = @floatFromInt(a.duration_ms),
            .name_ptr = @intFromPtr(a.name.ptr),
            .name_len = @intCast(a.name.len),
            .entry_ptr = @intFromPtr(a.zip_entry_name.ptr),
            .entry_len = @intCast(a.zip_entry_name.len),
        };
    }
    return @intCast(g_audio_draw_buf.len);
}

export fn get_all_audio_ptr() u32 {
    return @intFromPtr(g_audio_draw_buf.ptr);
}
```

- [ ] **Step 3: Build the wasm artifact to verify it compiles**

`main.zig` isn't included in `root.zig`'s native test module (it's
wasm-only, `export fn`s over `std.heap.wasm_allocator`), so this task's
verification is a successful build, matching how the existing
`get_visible_image_*` exports are verified.

Run: `cd wasm && zig build -Doptimize=ReleaseSmall 2>&1 | tail -30`
Expected: no errors; `web/src/wasm/notein.wasm` is written.

- [ ] **Step 4: Commit**

```bash
git add wasm/src/main.zig
git commit -m "feat(wasm): export get_all_images/links/audio for the Media/Links panels"
```

---

### Task 4: JS bindings for the new exports, plus two small reuse exports

**Files:**
- Modify: `web/src/wasm/loader.ts`
- Modify: `web/src/canvas/export-render.ts:199` (export `sniffImageMime`)
- Modify: `web/src/export.ts:19` (export `triggerDownload`)

**Interfaces:**
- Consumes: `get_all_images_count/ptr`, `get_all_links_count/ptr`,
  `get_all_audio_count/ptr` (Task 3), byte offsets as documented in Task 3's
  struct comments.
- Produces: `NoteinModule.getAllImages(): AssetImage[]`,
  `.getAllLinks(): LinkAsset[]`, `.getAllAudio(): AudioAsset[]`; exported
  `sniffImageMime(bytes: Uint8Array): string` from `export-render.ts`;
  exported `triggerDownload(blob: Blob, filename: string): void` from
  `export.ts` — all consumed by Tasks 6, 8, 9.

- [ ] **Step 1: Export the two existing helper functions**

In `web/src/canvas/export-render.ts`, change:

```ts
function sniffImageMime(bytes: Uint8Array): string {
```

to:

```ts
export function sniffImageMime(bytes: Uint8Array): string {
```

In `web/src/export.ts`, change:

```ts
function triggerDownload(blob: Blob, filename: string): void {
```

to:

```ts
export function triggerDownload(blob: Blob, filename: string): void {
```

- [ ] **Step 2: Add the new exports to the `NoteinExports` interface**

In `web/src/wasm/loader.ts`, in the `NoteinExports` interface, after
`get_bytes_len(): number;`, add:

```ts
  get_all_images_count(): number;
  get_all_images_ptr(): number;
  get_all_links_count(): number;
  get_all_links_ptr(): number;
  get_all_audio_count(): number;
  get_all_audio_ptr(): number;
```

- [ ] **Step 3: Add the result interfaces and stride constants**

After the existing `TextBoxDraw` interface, add:

```ts
export interface AssetImage {
  pageIndex: number;
  left: number;
  top: number;
  right: number;
  bottom: number;
  name: string;
  creationTime: number;
}

export interface LinkAsset {
  pageIndex: number;
  left: number;
  top: number;
  right: number;
  bottom: number;
  destination: string;
  linkType: number;
  creationTime: number;
}

export interface AudioAsset {
  name: string;
  entryName: string;
  durationMs: number;
  creationTime: number;
}
```

After the existing `const VECTOR_POLY_STRIDE = 24;` line, add:

```ts
const ASSET_IMAGE_STRIDE = 40; // f64 creation_time, 4x f32 bounds, u32 page_index, u32 name_ptr, u32 name_len
const LINK_DRAW_STRIDE = 40; // f64 creation_time, 4x f32 bounds, u32 page_index, i32 link_type, u32 dest_ptr, u32 dest_len
const AUDIO_DRAW_STRIDE = 32; // f64 creation_time, f64 duration_ms, u32 name_ptr, u32 name_len, u32 entry_ptr, u32 entry_len
```

- [ ] **Step 4: Add the three methods**

At the end of the `NoteinModule` class, after `getBytes`, add:

```ts
  /** All images in the note (not viewport-culled), for the Media panel. */
  getAllImages(): AssetImage[] {
    const count = this.exports.get_all_images_count();
    const ptr = this.exports.get_all_images_ptr();
    const view = new DataView(this.memory, ptr, count * ASSET_IMAGE_STRIDE);
    const out: AssetImage[] = [];
    for (let i = 0; i < count; i++) {
      const base = i * ASSET_IMAGE_STRIDE;
      const namePtr = view.getUint32(base + 28, true);
      const nameLen = view.getUint32(base + 32, true);
      out.push({
        creationTime: view.getFloat64(base + 0, true),
        left: view.getFloat32(base + 8, true),
        top: view.getFloat32(base + 12, true),
        right: view.getFloat32(base + 16, true),
        bottom: view.getFloat32(base + 20, true),
        pageIndex: view.getUint32(base + 24, true),
        name: this.readString(namePtr, nameLen),
      });
    }
    return out;
  }

  /** All hyperlinks in the note, for the Links panel. */
  getAllLinks(): LinkAsset[] {
    const count = this.exports.get_all_links_count();
    const ptr = this.exports.get_all_links_ptr();
    const view = new DataView(this.memory, ptr, count * LINK_DRAW_STRIDE);
    const out: LinkAsset[] = [];
    for (let i = 0; i < count; i++) {
      const base = i * LINK_DRAW_STRIDE;
      const destPtr = view.getUint32(base + 32, true);
      const destLen = view.getUint32(base + 36, true);
      out.push({
        creationTime: view.getFloat64(base + 0, true),
        left: view.getFloat32(base + 8, true),
        top: view.getFloat32(base + 12, true),
        right: view.getFloat32(base + 16, true),
        bottom: view.getFloat32(base + 20, true),
        pageIndex: view.getUint32(base + 24, true),
        linkType: view.getInt32(base + 28, true),
        destination: this.readString(destPtr, destLen),
      });
    }
    return out;
  }

  /** All audio recordings in the note, for the Media panel's Audio tab. */
  getAllAudio(): AudioAsset[] {
    const count = this.exports.get_all_audio_count();
    const ptr = this.exports.get_all_audio_ptr();
    const view = new DataView(this.memory, ptr, count * AUDIO_DRAW_STRIDE);
    const out: AudioAsset[] = [];
    for (let i = 0; i < count; i++) {
      const base = i * AUDIO_DRAW_STRIDE;
      const namePtr = view.getUint32(base + 16, true);
      const nameLen = view.getUint32(base + 20, true);
      const entryPtr = view.getUint32(base + 24, true);
      const entryLen = view.getUint32(base + 28, true);
      out.push({
        creationTime: view.getFloat64(base + 0, true),
        durationMs: view.getFloat64(base + 8, true),
        name: this.readString(namePtr, nameLen),
        entryName: this.readString(entryPtr, entryLen),
      });
    }
    return out;
  }
```

- [ ] **Step 5: Type-check**

Run: `cd web && npx tsc --noEmit`
Expected: no errors (the wasm build from Task 3 must already have produced
`web/src/wasm/notein.wasm` with the matching exports, but `tsc` only checks
types here, not the actual wasm binary).

- [ ] **Step 6: Commit**

```bash
git add web/src/wasm/loader.ts web/src/canvas/export-render.ts web/src/export.ts
git commit -m "feat(web): add loader.ts bindings for images/links/audio, export shared helpers"
```

---

### Task 5: `frameToBounds` viewport-jump helper

**Files:**
- Modify: `web/src/canvas/layout.ts`

**Interfaces:**
- Consumes: `Viewport.frame` (existing, `web/src/canvas/viewport.ts`), `NoteLayout` (existing).
- Produces: `frameToBounds(viewport, layout, pageIndex, bounds, canvas): void` — consumed by Tasks 8 and 9.

- [ ] **Step 1: Add the helper**

In `web/src/canvas/layout.ts`, add the import at the top:

```ts
import type { Viewport } from "./viewport";
```

At the end of the file, add:

```ts
/** Pans/zooms the viewport to frame a page-local bounds rect (an image,
 * link, etc.), converting it to world space via the page's layout offset. */
export function frameToBounds(
  viewport: Viewport,
  layout: NoteLayout,
  pageIndex: number,
  bounds: { left: number; top: number; right: number; bottom: number },
  canvas: HTMLCanvasElement,
): void {
  const page = layout.pages[pageIndex];
  if (!page) return;
  const pad = 40;
  const rect = canvas.getBoundingClientRect();
  viewport.frame(
    page.x + bounds.left - pad,
    page.y + bounds.top - pad,
    bounds.right - bounds.left + pad * 2,
    bounds.bottom - bounds.top + pad * 2,
    rect.width,
    rect.height,
  );
}
```

- [ ] **Step 2: Type-check**

Run: `cd web && npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add web/src/canvas/layout.ts
git commit -m "feat(web): add frameToBounds helper for jump-to-item navigation"
```

---

### Task 6: `fflate` dependency and the "download all" zip helper

**Files:**
- Modify: `web/package.json`
- Create: `web/src/media-zip.ts`

**Interfaces:**
- Consumes: `NoteinModule.getBytes` (existing), `AssetImage`, `AudioAsset` (Task 4), `triggerDownload` (Task 4).
- Produces: `downloadAllMedia(wasm, images, audio): void` — consumed by Task 8.

- [ ] **Step 1: Add the dependency**

Run: `cd web && bun add fflate`
Expected: `fflate` appears in `web/package.json` `dependencies` and `web/bun.lock` updates.

- [ ] **Step 2: Write `media-zip.ts`**

Create `web/src/media-zip.ts`:

```ts
import { zipSync } from "fflate";
import type { NoteinModule, AssetImage, AudioAsset } from "./wasm/loader";
import { triggerDownload } from "./export";

function extOf(entryName: string): string {
  const dot = entryName.lastIndexOf(".");
  return dot === -1 ? "bin" : entryName.slice(dot + 1);
}

function sanitizeName(name: string): string {
  return name.replace(/[^a-zA-Z0-9._-]+/g, "_");
}

/** Bundles every image and audio recording in the note into one zip
 * (images/ and audio/ folders), stored uncompressed since PNG/JPEG/M4A are
 * already-compressed formats, and triggers a browser download. */
export function downloadAllMedia(wasm: NoteinModule, images: AssetImage[], audio: AudioAsset[]): void {
  const files: Record<string, Uint8Array> = {};
  images.forEach((img, i) => {
    files[`images/image-${String(i + 1).padStart(3, "0")}.${extOf(img.name)}`] = wasm.getBytes(img.name);
  });
  audio.forEach((a, i) => {
    files[`audio/audio-${String(i + 1).padStart(3, "0")}-${sanitizeName(a.name)}.${extOf(a.entryName)}`] = wasm.getBytes(a.entryName);
  });
  const zipped = zipSync(files, { level: 0 });
  triggerDownload(new Blob([zipped.buffer as ArrayBuffer], { type: "application/zip" }), "notein-media.zip");
}
```

- [ ] **Step 3: Type-check**

Run: `cd web && npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add web/package.json web/bun.lock web/src/media-zip.ts
git commit -m "feat(web): add fflate dependency and downloadAllMedia zip helper"
```

---

### Task 7: Side-panel markup and styles

**Files:**
- Modify: `web/index.html`

**Interfaces:**
- Produces: DOM elements `#media-tool`, `#links-tool`, `#media-panel`,
  `#media-tab-images`, `#media-tab-audio`, `#media-panel-list`,
  `#media-download-all`, `#media-panel-close`, `#links-panel`,
  `#links-panel-list`, `#links-panel-close` — consumed by Task 10.

- [ ] **Step 1: Add the CSS**

In `web/index.html`, inside the existing `<style>` block, after the
`#export-panel button:hover { background: #2a2a2a; }` rule, add:

```css
      .side-panel {
        position: absolute;
        top: 56px;
        right: 12px;
        width: 300px;
        max-height: calc(100% - 80px);
        display: flex;
        flex-direction: column;
        background: rgba(20, 20, 20, 0.92);
        border: 1px solid #444;
        border-radius: 10px;
        z-index: 6;
        overflow: hidden;
      }
      .side-panel.hidden {
        display: none;
      }
      .side-panel-header {
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 8px 10px;
        border-bottom: 1px solid #333;
        flex: 0 0 auto;
      }
      .side-panel-tabs {
        display: flex;
        gap: 6px;
        flex: 1 1 auto;
      }
      .side-panel-title {
        flex: 1 1 auto;
        color: #ddd;
        font-size: 13px;
      }
      .side-panel button {
        font-size: 12px;
        padding: 5px 8px;
        border-radius: 8px;
        border: 1px solid #555;
        background: #1e1e1e;
        color: #eee;
        cursor: pointer;
        white-space: nowrap;
      }
      .side-panel button:hover {
        background: #2a2a2a;
      }
      .side-panel button.active {
        background: #4f8cff;
        border-color: #4f8cff;
      }
      .side-panel button:disabled {
        opacity: 0.4;
        cursor: default;
      }
      .side-panel-list {
        overflow-y: auto;
        padding: 10px;
      }
      .media-grid {
        display: grid;
        grid-template-columns: repeat(auto-fill, minmax(72px, 1fr));
        gap: 8px;
      }
      .media-thumb {
        position: relative;
        aspect-ratio: 1;
        border-radius: 6px;
        overflow: hidden;
        cursor: pointer;
        background: #111;
      }
      .media-thumb img {
        width: 100%;
        height: 100%;
        object-fit: cover;
        display: block;
      }
      .media-dl {
        position: absolute;
        top: 4px;
        right: 4px;
        padding: 2px 6px !important;
        font-size: 11px !important;
        background: rgba(0, 0, 0, 0.6) !important;
      }
      .media-list {
        display: flex;
        flex-direction: column;
        gap: 8px;
      }
      .media-row {
        display: flex;
        flex-direction: column;
        gap: 4px;
        padding: 6px;
        border-radius: 8px;
        background: rgba(255, 255, 255, 0.04);
      }
      .media-row audio {
        width: 100%;
        height: 28px;
      }
      .media-row-label {
        color: #ddd;
        font-size: 12px;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .media-row-actions {
        display: flex;
        gap: 6px;
      }
      .media-row a {
        font-size: 12px;
        padding: 5px 8px;
        border-radius: 8px;
        border: 1px solid #555;
        background: #1e1e1e;
        color: #8ab0ff;
        text-decoration: none;
      }
      .media-empty {
        color: #888;
        font-size: 12px;
        margin: 0;
      }
```

- [ ] **Step 2: Add the toggle buttons**

In `web/index.html`, inside `#export-control`, after the
`<button id="export-page-svg" type="button">Export page SVG</button>` line,
add:

```html
          <div class="sep"></div>
          <button id="media-tool" type="button">Media</button>
          <button id="links-tool" type="button">Links</button>
```

- [ ] **Step 3: Add the panel markup**

In `web/index.html`, after the existing `#export-panel` `</div>`, add:

```html
        <div id="media-panel" class="side-panel hidden">
          <div class="side-panel-header">
            <div class="side-panel-tabs">
              <button id="media-tab-images" type="button" class="active">Images</button>
              <button id="media-tab-audio" type="button">Audio</button>
            </div>
            <button id="media-download-all" type="button" disabled>Download all (zip)</button>
            <button id="media-panel-close" type="button" aria-label="Close">&times;</button>
          </div>
          <div id="media-panel-list" class="side-panel-list media-grid"></div>
        </div>
        <div id="links-panel" class="side-panel hidden">
          <div class="side-panel-header">
            <span class="side-panel-title">Links</span>
            <button id="links-panel-close" type="button" aria-label="Close">&times;</button>
          </div>
          <div id="links-panel-list" class="side-panel-list"></div>
        </div>
```

- [ ] **Step 4: Commit**

```bash
git add web/index.html
git commit -m "feat(web): add Media/Links panel markup and styles"
```

---

### Task 8: `MediaPanel` class

**Files:**
- Create: `web/src/media-panel.ts`

**Interfaces:**
- Consumes: `NoteinModule.getAllImages/getAllAudio/getBytes` (Task 4),
  `NoteLayout`, `frameToBounds` (Task 5), `Viewport` (existing),
  `sniffImageMime`, `triggerDownload` (Task 4), `downloadAllMedia` (Task 6),
  DOM ids from Task 7.
- Produces: `class MediaPanel { constructor(wasm, panelEl, tabImagesEl,
  tabAudioEl, listEl, downloadAllEl, getLayout, viewport, canvas); reset():
  void; open(): void; close(): void; toggle(): void }` — consumed by Task 10.

- [ ] **Step 1: Write `media-panel.ts`**

Create `web/src/media-panel.ts`:

```ts
import type { NoteinModule, AssetImage, AudioAsset } from "./wasm/loader";
import type { NoteLayout } from "./canvas/layout";
import { frameToBounds } from "./canvas/layout";
import type { Viewport } from "./canvas/viewport";
import { sniffImageMime } from "./canvas/export-render";
import { triggerDownload } from "./export";
import { downloadAllMedia } from "./media-zip";

function formatDuration(ms: number): string {
  const totalSeconds = Math.round(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

function extOf(entryName: string): string {
  const dot = entryName.lastIndexOf(".");
  return dot === -1 ? "bin" : entryName.slice(dot + 1);
}

/** Small floating drawer listing every image and audio recording in the
 * note, with click-to-jump (images), playback (audio), per-item download,
 * and a bulk "download all" zip. Data is fetched from wasm lazily, on
 * first open, and cached until `reset()` (called on note load/unload). */
export class MediaPanel {
  private images: AssetImage[] = [];
  private audio: AudioAsset[] = [];
  private loaded = false;
  private activeTab: "images" | "audio" = "images";

  constructor(
    private readonly wasm: NoteinModule,
    private readonly panelEl: HTMLElement,
    private readonly tabImagesEl: HTMLButtonElement,
    private readonly tabAudioEl: HTMLButtonElement,
    private readonly listEl: HTMLElement,
    private readonly downloadAllEl: HTMLButtonElement,
    private readonly getLayout: () => NoteLayout | null,
    private readonly viewport: Viewport,
    private readonly canvas: HTMLCanvasElement,
  ) {
    this.tabImagesEl.addEventListener("click", () => this.setTab("images"));
    this.tabAudioEl.addEventListener("click", () => this.setTab("audio"));
    this.downloadAllEl.addEventListener("click", () => downloadAllMedia(this.wasm, this.images, this.audio));
  }

  /** Clears cached data and hides the panel -- call on note load/unload. */
  reset(): void {
    this.images = [];
    this.audio = [];
    this.loaded = false;
    this.listEl.replaceChildren();
    this.downloadAllEl.disabled = true;
    this.panelEl.classList.add("hidden");
  }

  open(): void {
    if (!this.loaded) {
      this.images = this.wasm.getAllImages();
      this.audio = this.wasm.getAllAudio();
      this.loaded = true;
      this.downloadAllEl.disabled = this.images.length === 0 && this.audio.length === 0;
    }
    this.panelEl.classList.remove("hidden");
    this.render();
  }

  close(): void {
    this.panelEl.classList.add("hidden");
  }

  toggle(): void {
    if (this.panelEl.classList.contains("hidden")) this.open();
    else this.close();
  }

  private setTab(tab: "images" | "audio"): void {
    this.activeTab = tab;
    this.tabImagesEl.classList.toggle("active", tab === "images");
    this.tabAudioEl.classList.toggle("active", tab === "audio");
    this.render();
  }

  private render(): void {
    this.listEl.replaceChildren();
    if (this.activeTab === "images") this.renderImages();
    else this.renderAudio();
  }

  private renderImages(): void {
    this.listEl.classList.add("media-grid");
    this.listEl.classList.remove("media-list");
    if (this.images.length === 0) {
      this.listEl.appendChild(this.emptyMessage("No images in this note."));
      return;
    }
    for (const img of this.images) {
      const cell = document.createElement("div");
      cell.className = "media-thumb";

      const imgEl = document.createElement("img");
      imgEl.alt = img.name;
      cell.appendChild(imgEl);
      this.loadThumb(imgEl, img.name);

      cell.addEventListener("click", () => {
        const layout = this.getLayout();
        if (layout) frameToBounds(this.viewport, layout, img.pageIndex, img, this.canvas);
      });

      const dl = document.createElement("button");
      dl.type = "button";
      dl.className = "media-dl";
      dl.textContent = "⬇";
      dl.setAttribute("aria-label", `Download ${img.name}`);
      dl.addEventListener("click", (e) => {
        e.stopPropagation();
        const bytes = this.wasm.getBytes(img.name);
        triggerDownload(new Blob([bytes.buffer as ArrayBuffer], { type: sniffImageMime(bytes) }), img.name);
      });
      cell.appendChild(dl);

      this.listEl.appendChild(cell);
    }
  }

  private loadThumb(imgEl: HTMLImageElement, name: string): void {
    const bytes = this.wasm.getBytes(name);
    const blob = new Blob([bytes.buffer as ArrayBuffer], { type: sniffImageMime(bytes) });
    imgEl.src = URL.createObjectURL(blob);
    imgEl.addEventListener("load", () => URL.revokeObjectURL(imgEl.src), { once: true });
  }

  private renderAudio(): void {
    this.listEl.classList.add("media-list");
    this.listEl.classList.remove("media-grid");
    if (this.audio.length === 0) {
      this.listEl.appendChild(this.emptyMessage("No audio recordings in this note."));
      return;
    }
    for (const a of this.audio) {
      const row = document.createElement("div");
      row.className = "media-row";

      const label = document.createElement("span");
      label.className = "media-row-label";
      label.textContent = `${a.name} (${formatDuration(a.durationMs)})`;
      row.appendChild(label);

      const bytes = this.wasm.getBytes(a.entryName);
      const blob = new Blob([bytes.buffer as ArrayBuffer], { type: "audio/mp4" });
      const url = URL.createObjectURL(blob);

      const audioEl = document.createElement("audio");
      audioEl.controls = true;
      audioEl.src = url;
      row.appendChild(audioEl);

      const dl = document.createElement("button");
      dl.type = "button";
      dl.className = "media-dl";
      dl.textContent = "⬇ Download";
      dl.addEventListener("click", () => triggerDownload(blob, `${a.name}.${extOf(a.entryName)}`));
      row.appendChild(dl);

      this.listEl.appendChild(row);
    }
  }

  private emptyMessage(text: string): HTMLElement {
    const p = document.createElement("p");
    p.className = "media-empty";
    p.textContent = text;
    return p;
  }
}
```

- [ ] **Step 2: Type-check**

Run: `cd web && npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add web/src/media-panel.ts
git commit -m "feat(web): add MediaPanel (Images/Audio tabs, jump-to, download, zip-all)"
```

---

### Task 9: `LinksPanel` class

**Files:**
- Create: `web/src/links-panel.ts`

**Interfaces:**
- Consumes: `NoteinModule.getAllLinks` (Task 4), `NoteLayout`,
  `frameToBounds` (Task 5), `Viewport` (existing), DOM ids from Task 7.
- Produces: `class LinksPanel { constructor(wasm, panelEl, listEl,
  getLayout, viewport, canvas); reset(): void; open(): void; close(): void;
  toggle(): void }` — consumed by Task 10.

- [ ] **Step 1: Write `links-panel.ts`**

Create `web/src/links-panel.ts`:

```ts
import type { NoteinModule, LinkAsset } from "./wasm/loader";
import type { NoteLayout } from "./canvas/layout";
import { frameToBounds } from "./canvas/layout";
import type { Viewport } from "./canvas/viewport";

function isHttpUrl(destination: string): boolean {
  return /^https?:\/\//i.test(destination);
}

/** Small floating drawer listing every hyperlink in the note, with a
 * jump-to-location button and an "open externally" link for http(s) URLs.
 * Links aren't files, so there's no download here. */
export class LinksPanel {
  private links: LinkAsset[] = [];
  private loaded = false;

  constructor(
    private readonly wasm: NoteinModule,
    private readonly panelEl: HTMLElement,
    private readonly listEl: HTMLElement,
    private readonly getLayout: () => NoteLayout | null,
    private readonly viewport: Viewport,
    private readonly canvas: HTMLCanvasElement,
  ) {}

  reset(): void {
    this.links = [];
    this.loaded = false;
    this.listEl.replaceChildren();
    this.panelEl.classList.add("hidden");
  }

  open(): void {
    if (!this.loaded) {
      this.links = this.wasm.getAllLinks();
      this.loaded = true;
    }
    this.panelEl.classList.remove("hidden");
    this.render();
  }

  close(): void {
    this.panelEl.classList.add("hidden");
  }

  toggle(): void {
    if (this.panelEl.classList.contains("hidden")) this.open();
    else this.close();
  }

  private render(): void {
    this.listEl.replaceChildren();
    if (this.links.length === 0) {
      const empty = document.createElement("p");
      empty.className = "media-empty";
      empty.textContent = "No links in this note.";
      this.listEl.appendChild(empty);
      return;
    }
    for (const link of this.links) {
      const row = document.createElement("div");
      row.className = "media-row";

      const label = document.createElement("span");
      label.className = "media-row-label";
      label.textContent = link.destination;
      label.title = link.destination;
      row.appendChild(label);

      const actions = document.createElement("div");
      actions.className = "media-row-actions";

      const jump = document.createElement("button");
      jump.type = "button";
      jump.textContent = "Jump";
      jump.addEventListener("click", () => {
        const layout = this.getLayout();
        if (layout) frameToBounds(this.viewport, layout, link.pageIndex, link, this.canvas);
      });
      actions.appendChild(jump);

      if (isHttpUrl(link.destination)) {
        const open = document.createElement("a");
        open.href = link.destination;
        open.target = "_blank";
        open.rel = "noopener";
        open.textContent = "Open ↗";
        actions.appendChild(open);
      }

      row.appendChild(actions);
      this.listEl.appendChild(row);
    }
  }
}
```

- [ ] **Step 2: Type-check**

Run: `cd web && npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add web/src/links-panel.ts
git commit -m "feat(web): add LinksPanel (list, jump-to, open-external)"
```

---

### Task 10: Wire panels into `main.ts` and verify end-to-end

**Files:**
- Modify: `web/src/main.ts`

**Interfaces:**
- Consumes: `MediaPanel` (Task 8), `LinksPanel` (Task 9), all DOM ids from
  Task 7.

- [ ] **Step 1: Add imports and element references**

In `web/src/main.ts`, add to the imports at the top:

```ts
import { MediaPanel } from "./media-panel";
import { LinksPanel } from "./links-panel";
```

After the existing `const exportRegionCancelEl = document.getElementById("export-region-cancel")!;` line, add:

```ts
const mediaToolEl = document.getElementById("media-tool") as HTMLButtonElement;
const linksToolEl = document.getElementById("links-tool") as HTMLButtonElement;
const mediaPanelEl = document.getElementById("media-panel")!;
const mediaTabImagesEl = document.getElementById("media-tab-images") as HTMLButtonElement;
const mediaTabAudioEl = document.getElementById("media-tab-audio") as HTMLButtonElement;
const mediaPanelListEl = document.getElementById("media-panel-list")!;
const mediaDownloadAllEl = document.getElementById("media-download-all") as HTMLButtonElement;
const mediaPanelCloseEl = document.getElementById("media-panel-close")!;
const linksPanelEl = document.getElementById("links-panel")!;
const linksPanelListEl = document.getElementById("links-panel-list")!;
const linksPanelCloseEl = document.getElementById("links-panel-close")!;
```

- [ ] **Step 2: Instantiate the panels and wire the toggle/close buttons**

In `web/src/main.ts`, inside `main()`, right after the
`const viewport = new Viewport(canvas, () => { ... });` block (and its
`window.addEventListener("resize", ...)` line that follows it), add:

```ts
  const mediaPanel = new MediaPanel(
    wasm,
    mediaPanelEl,
    mediaTabImagesEl,
    mediaTabAudioEl,
    mediaPanelListEl,
    mediaDownloadAllEl,
    () => renderer?.layout ?? null,
    viewport,
    canvas,
  );
  const linksPanel = new LinksPanel(wasm, linksPanelEl, linksPanelListEl, () => renderer?.layout ?? null, viewport, canvas);

  mediaToolEl.addEventListener("click", () => mediaPanel.toggle());
  linksToolEl.addEventListener("click", () => linksPanel.toggle());
  mediaPanelCloseEl.addEventListener("click", () => mediaPanel.close());
  linksPanelCloseEl.addEventListener("click", () => linksPanel.close());
```

(`renderer` is declared with `let renderer: Renderer | null = null;` earlier
in `main()`, so this closure is safe to create before `renderer` is
assigned.)

- [ ] **Step 3: Reset the panels on note load and on load failure**

In `web/src/main.ts`, in `setupFileInput`'s success branch, after the
existing `syncPageExportUI();` line (just before
`setStatus(\`${file.name} — ${renderer.layout.pages.length} page(s)\`);`),
add:

```ts
      mediaPanel.reset();
      linksPanel.reset();
```

In the `catch` block, after the existing `hideExportPanel();` and
`setSelectMode(false);` lines, add:

```ts
      mediaPanel.reset();
      linksPanel.reset();
```

- [ ] **Step 4: Type-check**

Run: `cd web && npx tsc --noEmit`
Expected: no errors.

- [ ] **Step 5: Build**

Run: `cd web && npm run build`
Expected: build succeeds (this also rebuilds the wasm artifact via
`build:wasm`, so it re-verifies Tasks 2/3's Zig changes too).

- [ ] **Step 6: Manual end-to-end verification**

Run `cd web && npm run dev`, open the printed local URL, and load
`~/Desktop/diary.in` (the same file used for the fixture). Verify:
- The **Media** button opens a drawer with an Images tab showing a
  thumbnail grid (29 images); clicking a thumbnail pans/zooms to that
  image; the small download button on a thumbnail downloads that one
  image.
- Switching to the Audio tab shows 1 row ("Recording 1", ~6:08 duration),
  with a working `<audio controls>` player and a working per-item download.
- "Download all (zip)" downloads `notein-media.zip` containing an
  `images/` folder (29 files) and an `audio/` folder (1 file); confirm it
  unzips cleanly (e.g. `unzip -l ~/Downloads/notein-media.zip`).
- The **Links** button opens a drawer showing "No links in this note."
  (this specific export has zero `HyperLinkEntity` rows — that's the
  correct empty-state, not a bug).
- Both panels close via their `×` button and via re-clicking their toggle
  button; loading a different (or the same) file again resets both panels
  (closed, no stale thumbnails).

- [ ] **Step 7: Commit**

```bash
git add web/src/main.ts
git commit -m "feat(web): wire Media/Links panels into the viewer"
```
