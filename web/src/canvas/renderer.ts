import type { ImageDraw, NoteinModule, TextBoxDraw } from "../wasm/loader";
import { layoutNote, visiblePages, type NoteLayout, type PageLayout } from "./layout";
import type { Viewport } from "./viewport";
import { FrameStats } from "../stats";

type Overlay = ({ kind: "image"; item: ImageDraw } | { kind: "text"; item: TextBoxDraw }) & { creationTime: number };

const PREFETCH_MARGIN_PAGES = 1;
// While actively panning/zooming, rasterize ink at this fraction of native
// resolution (a quarter the pixel count at 0.5x linear) and stretch it up to
// full size -- rasterization cost here is pixel-count-dominated (measured:
// ~29ms/frame zoomed out on a ~3k-stroke note vs. ~0.5ms just to cull, so the
// per-pixel scanline work is what's actually slow), and a soft frame mid-
// gesture is a better tradeoff than dropping frames. `Viewport.isInteracting`
// flips back to false as soon as the gesture ends, at which point the very
// next frame renders at full quality again.
const INTERACTION_LOD_SCALE = 0.5;

function argbToCss(argb: number): string {
  const a = ((argb >>> 24) & 0xff) / 255;
  const r = (argb >>> 16) & 0xff;
  const g = (argb >>> 8) & 0xff;
  const b = argb & 0xff;
  return `rgba(${r}, ${g}, ${b}, ${a})`;
}

export class Renderer {
  readonly layout: NoteLayout;
  readonly stats = new FrameStats();
  private readonly ctx: CanvasRenderingContext2D;
  private readonly imageCache = new Map<string, ImageBitmap | "pending" | "failed">();
  private lastActivePageSet = "";
  private scratchCanvas: HTMLCanvasElement;
  private scratchCtx: CanvasRenderingContext2D;
  private rafScheduled = false;

  constructor(
    private readonly wasm: NoteinModule,
    private readonly canvas: HTMLCanvasElement,
    private readonly viewport: Viewport,
  ) {
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("2d context unavailable");
    this.ctx = ctx;

    this.scratchCanvas = document.createElement("canvas");
    const sctx = this.scratchCanvas.getContext("2d");
    if (!sctx) throw new Error("2d context unavailable");
    this.scratchCtx = sctx;

    this.layout = layoutNote(wasm.getPages());
  }

  /** Frames the camera on page 1, fitted and centered, and does an initial render. */
  showWholeNote(): void {
    const { width, height } = this.canvasSize();
    const first = this.layout.pages[0];
    if (!first) {
      this.viewport.frame(0, 0, this.layout.contentWidth, this.layout.contentHeight, width, height);
      return;
    }
    this.viewport.frame(first.x + first.boxLeft, first.y + first.boxTop, first.width, first.height, width, height);
  }

  /**
   * Forces the wasm active-decode-window to be recomputed and re-applied on
   * the next render, bypassing the diff-check cache in `updateActiveWindow`.
   * Needed after something else (the minimap's thumbnail generation) has
   * changed wasm's active window behind this renderer's back.
   */
  resyncActiveWindow(): void {
    this.lastActivePageSet = "";
    this.requestRender();
  }

  requestRender(): void {
    if (this.rafScheduled) return;
    this.rafScheduled = true;
    requestAnimationFrame(() => {
      this.rafScheduled = false;
      this.render();
    });
  }

  private canvasSize(): { width: number; height: number } {
    const rect = this.canvas.getBoundingClientRect();
    return { width: rect.width, height: rect.height };
  }

  private resizeCanvasIfNeeded(): { widthPx: number; heightPx: number } {
    const dpr = this.viewport.dpr;
    const { width, height } = this.canvasSize();
    const widthPx = Math.max(1, Math.round(width * dpr));
    const heightPx = Math.max(1, Math.round(height * dpr));
    if (this.canvas.width !== widthPx || this.canvas.height !== heightPx) {
      this.canvas.width = widthPx;
      this.canvas.height = heightPx;
    }
    return { widthPx, heightPx };
  }

  private render(): void {
    this.stats.tick();
    const { widthPx, heightPx } = this.resizeCanvasIfNeeded();
    const { camera } = this.viewport;
    // camera.zoom is CSS-pixel-calibrated (matches pointer/wheel input in
    // viewport.ts, which works in CSS client coordinates); the canvas backing
    // store is device-pixel-sized, so all pixel-buffer/screen-position math
    // below uses devicePxPerUnit instead, keeping rendering crisp (and
    // correctly scaled) on HiDPI displays.
    const devicePxPerUnit = camera.zoom * this.viewport.dpr;
    const worldW = widthPx / devicePxPerUnit;
    const worldH = heightPx / devicePxPerUnit;

    const visible = visiblePages(this.layout, camera.x, camera.y, worldW, worldH);
    this.updateActiveWindow(visible);

    this.ctx.setTransform(1, 0, 0, 1, 0, 0);
    this.ctx.fillStyle = "#000000";
    this.ctx.fillRect(0, 0, widthPx, heightPx);

    const inkPxPerUnit = this.viewport.isInteracting ? devicePxPerUnit * INTERACTION_LOD_SCALE : devicePxPerUnit;
    for (const page of visible) {
      this.renderPage(page, camera, devicePxPerUnit, inkPxPerUnit, widthPx, heightPx);
    }
  }

  private updateActiveWindow(visible: { index: number }[]): void {
    const withMargin = new Set<number>();
    for (const p of visible) {
      for (let d = -PREFETCH_MARGIN_PAGES; d <= PREFETCH_MARGIN_PAGES; d++) {
        const idx = p.index + d;
        if (idx >= 0 && idx < this.layout.pages.length) withMargin.add(idx);
      }
    }
    const indices = [...withMargin].sort((a, b) => a - b);
    const key = indices.join(",");
    if (key !== this.lastActivePageSet) {
      this.lastActivePageSet = key;
      this.wasm.setActiveWindow(indices);
    }
  }

  private renderPage(
    page: PageLayout,
    camera: { x: number; y: number; zoom: number },
    devicePxPerUnit: number,
    inkPxPerUnit: number,
    canvasWidthPx: number,
    canvasHeightPx: number,
  ): void {
    // Intersection of the page box and the viewport, in world space.
    const boxX = page.x + page.boxLeft;
    const boxY = page.y + page.boxTop;
    const vx0 = Math.max(boxX, camera.x);
    const vy0 = Math.max(boxY, camera.y);
    const vx1 = Math.min(boxX + page.width, camera.x + canvasWidthPx / devicePxPerUnit);
    const vy1 = Math.min(boxY + page.height, camera.y + canvasHeightPx / devicePxPerUnit);
    const vw = vx1 - vx0;
    const vh = vy1 - vy0;
    if (vw <= 0 || vh <= 0) return;

    // Page-local viewport rect (wasm indexes strokes in page-local coordinates).
    const localX = vx0 - page.x;
    const localY = vy0 - page.y;

    // Full-resolution destination size (screen pixels this region occupies)
    // vs. the (possibly reduced, see INTERACTION_LOD_SCALE) size wasm
    // actually rasterizes at -- drawInk stretches the latter to the former.
    const destW = Math.max(1, Math.round(vw * devicePxPerUnit));
    const destH = Math.max(1, Math.round(vh * devicePxPerUnit));
    const pixelW = Math.max(1, Math.round(vw * inkPxPerUnit));
    const pixelH = Math.max(1, Math.round(vh * inkPxPerUnit));

    // Screen position (device pixels) of this rasterized rect's top-left.
    const screenX = (vx0 - camera.x) * devicePxPerUnit;
    const screenY = (vy0 - camera.y) * devicePxPerUnit;

    // Page background (paper) first, using the note's real paper color.
    if (!page.unbounded) {
      this.ctx.fillStyle = argbToCss(page.color);
      this.ctx.fillRect(screenX, screenY, destW, destH);
    }

    // Ink (strokes+shapes), images, and text boxes are composited in true
    // chronological/stacking order -- not always "all ink, then all images,
    // then all text" -- since e.g. ink annotated on top of a pasted photo
    // must render on top of it, not underneath. Cheap in the common case
    // (no images/text on this page, or all after all ink): the loop below
    // just does one full-range ink draw, same cost as before.
    const images = this.wasm.getVisibleImages(page.index, localX, localY, vw, vh);
    const textBoxes = this.wasm.getVisibleTextBoxes(page.index, localX, localY, vw, vh);
    const overlays: Overlay[] = [
      ...images.map((item): Overlay => ({ kind: "image", item, creationTime: item.creationTime })),
      ...textBoxes.map((item): Overlay => ({ kind: "text", item, creationTime: item.creationTime })),
    ].sort((a, b) => a.creationTime - b.creationTime);

    let prevTime = -Infinity;
    for (const overlay of overlays) {
      this.drawInk(page, localX, localY, vw, vh, screenX, screenY, pixelW, pixelH, destW, destH, prevTime, overlay.creationTime);
      if (overlay.kind === "image") this.drawImageItem(overlay.item, page, camera, devicePxPerUnit);
      else this.drawTextBoxItem(overlay.item, page, camera, devicePxPerUnit);
      prevTime = overlay.creationTime;
    }
    this.drawInk(page, localX, localY, vw, vh, screenX, screenY, pixelW, pixelH, destW, destH, prevTime, Infinity);

    if (!page.unbounded) {
      this.ctx.strokeStyle = "rgba(0,0,0,0.15)";
      this.ctx.lineWidth = 1;
      this.ctx.strokeRect(
        (page.x - camera.x) * devicePxPerUnit,
        (page.y - camera.y) * devicePxPerUnit,
        page.width * devicePxPerUnit,
        page.height * devicePxPerUnit,
      );
    }
  }

  /** Rasterizes and composites ink (strokes+shapes) whose creation_time
   * falls in [timeMin, timeMax) -- see the chronological-interleave comment
   * in renderPage. No-op range produces an all-transparent draw, cheaply. */
  private drawInk(
    page: PageLayout,
    localX: number,
    localY: number,
    vw: number,
    vh: number,
    screenX: number,
    screenY: number,
    pixelW: number,
    pixelH: number,
    destW: number,
    destH: number,
    timeMin: number,
    timeMax: number,
  ): void {
    const rgba = this.wasm.renderViewport(page.index, localX, localY, vw, vh, pixelW, pixelH, timeMin, timeMax);
    this.scratchCanvas.width = pixelW;
    this.scratchCanvas.height = pixelH;
    const imgData = new ImageData(new Uint8ClampedArray(rgba), pixelW, pixelH);
    this.scratchCtx.putImageData(imgData, 0, 0);
    // destW/destH stretch up to full resolution when pixelW/pixelH were
    // rasterized smaller (INTERACTION_LOD_SCALE) -- identical draw call and
    // cost as before when they match (the common, settled case).
    this.ctx.drawImage(this.scratchCanvas, 0, 0, pixelW, pixelH, screenX, screenY, destW, destH);
  }

  private drawImageItem(img: ImageDraw, page: PageLayout, camera: { x: number; y: number }, devicePxPerUnit: number): void {
    const bitmap = this.imageCache.get(img.name);
    if (bitmap === undefined) {
      this.imageCache.set(img.name, "pending");
      this.loadImage(img.name);
      return;
    }
    if (bitmap === "pending" || bitmap === "failed") return;

    const sx = (page_x(page, img.left) - camera.x) * devicePxPerUnit;
    const sy = (page_y(page, img.top) - camera.y) * devicePxPerUnit;
    const sw = (img.right - img.left) * devicePxPerUnit;
    const sh = (img.bottom - img.top) * devicePxPerUnit;
    this.ctx.drawImage(bitmap, sx, sy, sw, sh);
  }

  private drawTextBoxItem(box: TextBoxDraw, page: PageLayout, camera: { x: number; y: number }, devicePxPerUnit: number): void {
    const sx = (page_x(page, box.left) - camera.x) * devicePxPerUnit;
    const sy = (page_y(page, box.top) - camera.y) * devicePxPerUnit;
    const fontPx = Math.max(1, box.size * devicePxPerUnit);
    this.ctx.font = `${fontPx}px sans-serif`;
    this.ctx.fillStyle = argbToCss(box.color);
    this.ctx.textBaseline = "top";
    this.ctx.fillText(box.text, sx, sy);
  }

  private loadImage(name: string): void {
    const bytes = this.wasm.getBytes(name);
    if (bytes.length === 0) {
      this.imageCache.set(name, "failed");
      return;
    }
    // `bytes` is already a freshly-copied, tightly-sized owned buffer (see
    // NoteinModule.getBytes) -- no need to copy it again just to reach .buffer.
    const blob = new Blob([bytes.buffer as ArrayBuffer]);
    createImageBitmap(blob)
      .then((bitmap) => {
        this.imageCache.set(name, bitmap);
        this.requestRender();
      })
      .catch(() => this.imageCache.set(name, "failed"));
  }
}

// Helpers to convert a page-local coordinate back to note-space, since the
// image/textbox draw commands are returned in page-local coordinates.
function page_x(page: PageLayout, localX: number): number {
  return page.x + localX;
}
function page_y(page: PageLayout, localY: number): number {
  return page.y + localY;
}
