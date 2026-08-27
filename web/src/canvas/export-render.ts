import type { ImageDraw, NoteinModule, TextBoxDraw, VectorPoly } from "../wasm/loader";
import { argbToCss, invertArgb } from "./color";
import { visiblePages, type NoteLayout, type PageLayout } from "./layout";
import { bytesToBase64, xmlEscape } from "../util";
import { darkMode } from "../theme";

export interface WorldRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

type Overlay = ({ kind: "image"; item: ImageDraw } | { kind: "text"; item: TextBoxDraw }) & { creationTime: number };

/**
 * Renders a note-space world rect (which may span multiple stacked pages,
 * per `layout.ts`) into a freshly-sized offscreen canvas at `pixelsPerUnit`
 * device pixels per world unit, compositing ink, images, and text in true
 * chronological order per page -- same approach as `Renderer.renderPage`,
 * but a one-shot pass that fully resolves (awaits every image) before
 * returning, since an exported file can't progressively "fill in" like the
 * live view does.
 *
 * Steals wasm's active decode window while it runs (like the minimap does);
 * call `resync` afterward to restore the live renderer's window.
 */
// Hard ceiling on the output canvas, independent of the requested scale --
// a selection made while zoomed far out covers many world units per screen
// pixel, so "4x" over a huge world-space rect can otherwise demand a canvas
// far past what browsers can allocate (Chrome caps around 268 megapixels;
// well below that, allocation just gets slow/crash-prone). Silently
// downscales rather than failing -- exporting *something* crisp beats
// erroring out.
const MAX_EXPORT_DIMENSION = 16384;
const MAX_EXPORT_PIXELS = 100_000_000;

/** Reduces `pixelsPerUnit` if needed so the output canvas stays within
 * MAX_EXPORT_DIMENSION per side and MAX_EXPORT_PIXELS total. */
/** Backdrop for an export: black document-viewer gutter for bounded notes, or
 * the page's own color for an infinite-canvas note (which has no gutter) so
 * dark ink stays visible. Mirrors the on-screen renderer's clear color,
 * including dark mode's background inversion (see theme.ts). */
function backdropColor(layout: NoteLayout): string {
  const allUnbounded = layout.pages.length > 0 && layout.pages.every((p) => p.unbounded);
  const first = layout.pages[0]!;
  return allUnbounded ? argbToCss(darkMode.value ? invertArgb(first.color) : first.color) : "#000000";
}

/** A page's background ARGB, flipped in dark mode (mirrors Renderer). */
function pageColor(page: PageLayout): number {
  return darkMode.value ? invertArgb(page.color) : page.color;
}

export function clampExportScale(rect: WorldRect, pixelsPerUnit: number): number {
  let scale = pixelsPerUnit;
  scale = Math.min(scale, MAX_EXPORT_DIMENSION / Math.max(1, rect.w));
  scale = Math.min(scale, MAX_EXPORT_DIMENSION / Math.max(1, rect.h));
  scale = Math.min(scale, Math.sqrt(MAX_EXPORT_PIXELS / Math.max(1, rect.w * rect.h)));
  return Math.max(0.01, scale);
}

export async function renderRegionToCanvas(
  wasm: NoteinModule,
  layout: NoteLayout,
  rect: WorldRect,
  pixelsPerUnit: number,
  resync: () => void,
): Promise<HTMLCanvasElement> {
  pixelsPerUnit = clampExportScale(rect, pixelsPerUnit);
  const outW = Math.max(1, Math.round(rect.w * pixelsPerUnit));
  const outH = Math.max(1, Math.round(rect.h * pixelsPerUnit));
  const out = document.createElement("canvas");
  out.width = outW;
  out.height = outH;
  const ctx = out.getContext("2d")!;
  // Infinite-canvas notes have no page gutter -- back them with the page color
  // (matches the on-screen renderer) so dark ink isn't lost on a black backdrop.
  ctx.fillStyle = backdropColor(layout);
  ctx.fillRect(0, 0, outW, outH);

  const imageCache = new Map<string, ImageBitmap | null>();
  const scratch = document.createElement("canvas");
  const scratchCtx = scratch.getContext("2d")!;

  try {
    const pages = visiblePages(layout, rect.x, rect.y, rect.w, rect.h);
    for (const page of pages) {
      wasm.setActiveWindow([page.index]);
      await renderPageInto(wasm, ctx, scratch, scratchCtx, page, rect, pixelsPerUnit, imageCache);
    }
  } finally {
    resync();
  }

  return out;
}

async function renderPageInto(
  wasm: NoteinModule,
  ctx: CanvasRenderingContext2D,
  scratch: HTMLCanvasElement,
  scratchCtx: CanvasRenderingContext2D,
  page: PageLayout,
  rect: WorldRect,
  pixelsPerUnit: number,
  imageCache: Map<string, ImageBitmap | null>,
): Promise<void> {
  const boxX = page.x + page.boxLeft;
  const boxY = page.y + page.boxTop;
  const vx0 = Math.max(boxX, rect.x);
  const vy0 = Math.max(boxY, rect.y);
  const vx1 = Math.min(boxX + page.width, rect.x + rect.w);
  const vy1 = Math.min(boxY + page.height, rect.y + rect.h);
  const vw = vx1 - vx0;
  const vh = vy1 - vy0;
  if (vw <= 0 || vh <= 0) return;

  const localX = vx0 - page.x;
  const localY = vy0 - page.y;
  const pixelW = Math.max(1, Math.round(vw * pixelsPerUnit));
  const pixelH = Math.max(1, Math.round(vh * pixelsPerUnit));
  const screenX = (vx0 - rect.x) * pixelsPerUnit;
  const screenY = (vy0 - rect.y) * pixelsPerUnit;

  if (!page.unbounded) {
    ctx.fillStyle = argbToCss(pageColor(page));
    ctx.fillRect(screenX, screenY, pixelW, pixelH);
  }

  const images = wasm.getVisibleImages(page.index, localX, localY, vw, vh);
  const textBoxes = wasm.getVisibleTextBoxes(page.index, localX, localY, vw, vh);
  const overlays: Overlay[] = [
    ...images.map((item): Overlay => ({ kind: "image", item, creationTime: item.creationTime })),
    ...textBoxes.map((item): Overlay => ({ kind: "text", item, creationTime: item.creationTime })),
  ].sort((a, b) => a.creationTime - b.creationTime);

  await preloadImages(wasm, images, imageCache);

  const drawInkRange = (timeMin: number, timeMax: number) => {
    const rgba = wasm.renderViewport(page.index, localX, localY, vw, vh, pixelW, pixelH, timeMin, timeMax, 0);
    scratch.width = pixelW;
    scratch.height = pixelH;
    scratchCtx.putImageData(new ImageData(new Uint8ClampedArray(rgba), pixelW, pixelH), 0, 0);
    ctx.drawImage(scratch, screenX, screenY);
  };

  let prevTime = -Infinity;
  for (const overlay of overlays) {
    drawInkRange(prevTime, overlay.creationTime);
    if (overlay.kind === "image") drawImageItem(ctx, overlay.item, page, rect, pixelsPerUnit, imageCache);
    else drawTextBoxItem(ctx, overlay.item, page, rect, pixelsPerUnit);
    prevTime = overlay.creationTime;
  }
  drawInkRange(prevTime, Infinity);
}

async function preloadImages(wasm: NoteinModule, images: ImageDraw[], cache: Map<string, ImageBitmap | null>): Promise<void> {
  for (const img of images) {
    if (cache.has(img.name)) continue;
    const bytes = wasm.getBytes(img.name);
    if (bytes.length === 0) {
      cache.set(img.name, null);
      continue;
    }
    try {
      // `bytes` is already a freshly-copied, tightly-sized owned buffer (see
      // NoteinModule.getBytes) -- no need to copy it again just to reach .buffer.
      const blob = new Blob([bytes.buffer as ArrayBuffer]);
      cache.set(img.name, await createImageBitmap(blob));
    } catch {
      cache.set(img.name, null);
    }
  }
}

function drawImageItem(
  ctx: CanvasRenderingContext2D,
  img: ImageDraw,
  page: PageLayout,
  rect: WorldRect,
  pixelsPerUnit: number,
  cache: Map<string, ImageBitmap | null>,
): void {
  const bitmap = cache.get(img.name);
  if (!bitmap) return;
  const sx = (page.x + img.left - rect.x) * pixelsPerUnit;
  const sy = (page.y + img.top - rect.y) * pixelsPerUnit;
  const sw = (img.right - img.left) * pixelsPerUnit;
  const sh = (img.bottom - img.top) * pixelsPerUnit;
  ctx.drawImage(bitmap, sx, sy, sw, sh);
}

function drawTextBoxItem(ctx: CanvasRenderingContext2D, box: TextBoxDraw, page: PageLayout, rect: WorldRect, pixelsPerUnit: number): void {
  const sx = (page.x + box.left - rect.x) * pixelsPerUnit;
  const sy = (page.y + box.top - rect.y) * pixelsPerUnit;
  const fontPx = Math.max(1, box.size * pixelsPerUnit);
  ctx.font = `${fontPx}px sans-serif`;
  ctx.fillStyle = argbToCss(box.color);
  ctx.textBaseline = "top";
  ctx.fillText(box.text, sx, sy);
}

type SvgOverlay =
  | { kind: "ink"; creationTime: number; poly: VectorPoly }
  | { kind: "image"; creationTime: number; item: ImageDraw }
  | { kind: "text"; creationTime: number; item: TextBoxDraw };

/** Sniffs an image asset's magic bytes for its MIME type -- the zip entries
 * are raw photo/image bytes with no type stored alongside them elsewhere. */
export function sniffImageMime(bytes: Uint8Array): string {
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return "image/png";
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) return "image/gif";
  return "image/png";
}

/**
 * Renders a note-space world rect (possibly spanning multiple pages) as a
 * self-contained SVG document string: ink is emitted as true vector `<path>`
 * fills (via `wasm.getVectorContent`, the same tessellated ribbon polygons
 * `render_viewport` rasterizes, just left as vectors), images are embedded
 * as base64 data URIs, and text boxes as `<text>` elements -- so, unlike the
 * PNG/PDF export, this stays crisp at any zoom the viewer opens it at.
 */
export async function renderRegionToSvg(wasm: NoteinModule, layout: NoteLayout, rect: WorldRect, resync: () => void): Promise<string> {
  const parts: string[] = [];
  const imageDataUris = new Map<string, string | null>();

  try {
    const pages = visiblePages(layout, rect.x, rect.y, rect.w, rect.h);
    for (const page of pages) {
      wasm.setActiveWindow([page.index]);
      await appendPageSvg(wasm, parts, page, rect, imageDataUris);
    }
  } finally {
    resync();
  }

  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${rect.w}" height="${rect.h}" viewBox="0 0 ${rect.w} ${rect.h}">`,
    `<rect x="0" y="0" width="${rect.w}" height="${rect.h}" fill="${backdropColor(layout)}" />`,
    ...parts,
    `</svg>`,
  ].join("\n");
}

async function appendPageSvg(
  wasm: NoteinModule,
  parts: string[],
  page: PageLayout,
  rect: WorldRect,
  imageDataUris: Map<string, string | null>,
): Promise<void> {
  const boxX = page.x + page.boxLeft;
  const boxY = page.y + page.boxTop;
  const vx0 = Math.max(boxX, rect.x);
  const vy0 = Math.max(boxY, rect.y);
  const vx1 = Math.min(boxX + page.width, rect.x + rect.w);
  const vy1 = Math.min(boxY + page.height, rect.y + rect.h);
  const vw = vx1 - vx0;
  const vh = vy1 - vy0;
  if (vw <= 0 || vh <= 0) return;

  const localX = vx0 - page.x;
  const localY = vy0 - page.y;
  const offsetX = page.x - rect.x;
  const offsetY = page.y - rect.y;

  if (!page.unbounded) {
    const screenX = vx0 - rect.x;
    const screenY = vy0 - rect.y;
    parts.push(`<rect x="${screenX}" y="${screenY}" width="${vw}" height="${vh}" fill="${argbToCss(pageColor(page))}" />`);
  }

  const ink = wasm.getVectorContent(page.index, localX, localY, vw, vh);
  const images = wasm.getVisibleImages(page.index, localX, localY, vw, vh);
  const textBoxes = wasm.getVisibleTextBoxes(page.index, localX, localY, vw, vh);

  await preloadDataUris(wasm, images, imageDataUris);

  const overlays: SvgOverlay[] = [
    ...ink.map((poly): SvgOverlay => ({ kind: "ink", creationTime: poly.creationTime, poly })),
    ...images.map((item): SvgOverlay => ({ kind: "image", creationTime: item.creationTime, item })),
    ...textBoxes.map((item): SvgOverlay => ({ kind: "text", creationTime: item.creationTime, item })),
  ].sort((a, b) => a.creationTime - b.creationTime);

  parts.push(`<g transform="translate(${offsetX}, ${offsetY})">`);
  for (const overlay of overlays) {
    if (overlay.kind === "ink") {
      const pts = overlay.poly.points;
      let d = `M ${pts[0]} ${pts[1]}`;
      for (let i = 2; i < pts.length; i += 2) d += ` L ${pts[i]} ${pts[i + 1]}`;
      d += " Z";
      parts.push(`<path d="${d}" fill="${argbToCss(overlay.poly.color)}" fill-rule="nonzero" />`);
    } else if (overlay.kind === "image") {
      const href = imageDataUris.get(overlay.item.name);
      if (!href) continue;
      const { left, top, right, bottom } = overlay.item;
      parts.push(`<image x="${left}" y="${top}" width="${right - left}" height="${bottom - top}" href="${href}" preserveAspectRatio="none" />`);
    } else {
      const { left, top, size, color, text } = overlay.item;
      parts.push(`<text x="${left}" y="${top + size * 0.85}" font-size="${size}" font-family="sans-serif" fill="${argbToCss(color)}">${xmlEscape(text)}</text>`);
    }
  }
  parts.push(`</g>`);
}

async function preloadDataUris(wasm: NoteinModule, images: ImageDraw[], cache: Map<string, string | null>): Promise<void> {
  for (const img of images) {
    if (cache.has(img.name)) continue;
    const bytes = wasm.getBytes(img.name);
    if (bytes.length === 0) {
      cache.set(img.name, null);
      continue;
    }
    cache.set(img.name, `data:${sniffImageMime(bytes)};base64,${bytesToBase64(bytes)}`);
  }
}
