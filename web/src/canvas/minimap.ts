import type { NoteinModule } from "../wasm/loader";
import type { NoteLayout, PageLayout } from "./layout";
import type { Viewport } from "./viewport";

const THUMB_WIDTH = 96;
// Below the thumbnail's tiny scale, most stroke widths round to a fraction of
// a device pixel and vanish; floor every stroke/shape to this many device
// pixels wide so the minimap still reads as legible ink instead of blank.
const THUMB_MIN_STROKE_PX = 1.25;
const MIN_INDICATOR_PX = 4;

function argbToCss(argb: number): string {
  const a = ((argb >>> 24) & 0xff) / 255;
  const r = (argb >>> 16) & 0xff;
  const g = (argb >>> 8) & 0xff;
  const b = argb & 0xff;
  return `rgba(${r}, ${g}, ${b}, ${a})`;
}

interface WorldRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

function pageWorldRect(p: PageLayout): WorldRect {
  return { left: p.x + p.boxLeft, top: p.y + p.boxTop, width: p.width, height: p.height };
}

/**
 * Two layouts, depending on the note:
 *
 * - **Paginated** (every page bounded, e.g. a scanned/typed document): a
 *   vertical strip of per-page thumbnails, one below the other, matching how
 *   the pages are actually laid out in world space (continuous-scroll). A
 *   click/drag jumps the main viewport to that page, vertically.
 * - **Freeform** (any page unbounded, i.e. infinite canvas): a page stack
 *   doesn't mean anything here -- there's one open-ended surface, and ink can
 *   be anywhere in any direction. Instead this renders a single 2D thumbnail
 *   of the whole content's bounding box, with a viewport-rect indicator free
 *   to move on both axes, like a minimap in a game rather than a scrollbar.
 *
 * Either way, a highlighted rect tracks the main viewport's current position
 * so the user can jump straight to a spot in the note instead of panning.
 */
export class Minimap {
  private readonly freeform: boolean;
  private readonly container: HTMLElement;
  private readonly track: HTMLElement;
  private readonly indicator: HTMLElement;
  private readonly scratchCanvas = document.createElement("canvas");
  private readonly scratchCtx: CanvasRenderingContext2D;
  private readonly imageCache = new Map<string, ImageBitmap | "pending" | "failed">();
  private pageTops: number[] = []; // paginated mode: px offset of each thumbnail within the track

  // Freeform mode only: the whole note's content bounding box in world space,
  // and world-units -> thumbnail-px scale (uniform on both axes).
  private worldBounds: WorldRect = { left: 0, top: 0, width: 1, height: 1 };
  private freeScale = 1;
  private freeCanvas: HTMLCanvasElement | null = null;

  constructor(
    private readonly wasm: NoteinModule,
    private readonly layout: NoteLayout,
    private readonly viewport: Viewport,
    /** Called after thumbnail generation changes wasm's active window, so the
     * main renderer can resync before its next frame. */
    private readonly onActiveWindowStolen: () => void,
    /** Called after a click/drag jump, to re-render the main view. */
    private readonly onJump: () => void,
  ) {
    this.freeform = layout.pages.some((p) => p.unbounded);

    const container = document.getElementById("minimap")!;
    container.innerHTML = "";
    container.classList.remove("hidden");
    this.container = container;

    this.track = document.createElement("div");
    this.track.id = "minimap-track";
    container.appendChild(this.track);

    this.indicator = document.createElement("div");
    this.indicator.id = "minimap-indicator";
    this.track.appendChild(this.indicator);

    const sctx = this.scratchCanvas.getContext("2d");
    if (!sctx) throw new Error("2d context unavailable");
    this.scratchCtx = sctx;

    if (this.freeform) {
      this.track.classList.add("free");
      this.indicator.classList.add("free");
      this.buildFreeCanvas();
      this.track.addEventListener("pointerdown", this.onPointerFree);
    } else {
      this.buildThumbnails();
      this.track.addEventListener("pointerdown", this.onPointerPaginated);
    }
  }

  // ------------------------------------------------------------------
  // Freeform (infinite-canvas) mode
  // ------------------------------------------------------------------

  private buildFreeCanvas(): void {
    let left = Infinity;
    let top = Infinity;
    let right = -Infinity;
    let bottom = -Infinity;
    for (const p of this.layout.pages) {
      const r = pageWorldRect(p);
      left = Math.min(left, r.left);
      top = Math.min(top, r.top);
      right = Math.max(right, r.left + r.width);
      bottom = Math.max(bottom, r.top + r.height);
    }
    if (!Number.isFinite(left)) {
      left = 0;
      top = 0;
      right = 1;
      bottom = 1;
    }
    this.worldBounds = { left, top, width: Math.max(1, right - left), height: Math.max(1, bottom - top) };
    this.freeScale = THUMB_WIDTH / this.worldBounds.width;
    const thumbHeight = Math.max(1, Math.round(this.worldBounds.height * this.freeScale));

    const canvas = document.createElement("canvas");
    canvas.className = "minimap-free-canvas";
    canvas.width = THUMB_WIDTH;
    canvas.height = thumbHeight;
    canvas.style.height = `${thumbHeight}px`;
    this.track.insertBefore(canvas, this.indicator);
    this.freeCanvas = canvas;

    for (const page of this.layout.pages) {
      this.scheduleGenerateFree(page.index);
    }
  }

  private scheduleGenerateFree(pageIndex: number): void {
    requestAnimationFrame(() => this.generateFreeThumbnail(pageIndex));
  }

  private generateFreeThumbnail(pageIndex: number): void {
    const canvas = this.freeCanvas;
    const page = this.layout.pages[pageIndex];
    if (!canvas || !page) return;

    const r = pageWorldRect(page);
    const pw = Math.max(1, Math.round(r.width * this.freeScale));
    const ph = Math.max(1, Math.round(r.height * this.freeScale));
    const px = Math.round((r.left - this.worldBounds.left) * this.freeScale);
    const py = Math.round((r.top - this.worldBounds.top) * this.freeScale);

    this.wasm.setActiveWindow([page.index]);
    const rgba = this.wasm.renderViewport(page.index, page.boxLeft, page.boxTop, page.width, page.height, pw, ph, -Infinity, Infinity, THUMB_MIN_STROKE_PX);

    this.scratchCanvas.width = pw;
    this.scratchCanvas.height = ph;
    this.scratchCtx.putImageData(new ImageData(new Uint8ClampedArray(rgba), pw, ph), 0, 0);

    const ctx = canvas.getContext("2d")!;
    ctx.fillStyle = argbToCss(page.color);
    ctx.fillRect(px, py, pw, ph);

    const scale = pw / page.width;
    const images = this.wasm.getVisibleImages(page.index, page.boxLeft, page.boxTop, page.width, page.height);
    for (const img of images) {
      const bitmap = this.imageCache.get(img.name);
      if (bitmap === undefined) {
        this.imageCache.set(img.name, "pending");
        const dw = Math.max(1, Math.round((img.right - img.left) * scale));
        const dh = Math.max(1, Math.round((img.bottom - img.top) * scale));
        this.loadImage(img.name, dw, dh, () => this.generateFreeThumbnail(pageIndex));
        continue;
      }
      if (bitmap === "pending" || bitmap === "failed") continue;
      const ix = px + (img.left - page.boxLeft) * scale;
      const iy = py + (img.top - page.boxTop) * scale;
      ctx.drawImage(bitmap, ix, iy, (img.right - img.left) * scale, (img.bottom - img.top) * scale);
    }

    ctx.drawImage(this.scratchCanvas, px, py);
    this.onActiveWindowStolen();
  }

  private onPointerFree = (e: PointerEvent) => {
    this.jumpToFreePoint(e);
    const onMove = (ev: PointerEvent) => this.jumpToFreePoint(ev);
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  };

  /** Maps a click/drag point on the free-canvas thumbnail to world-space and
   * centers the main viewport there (zoom unchanged), on both axes. */
  private jumpToFreePoint(e: PointerEvent): void {
    const canvas = this.freeCanvas;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const scaleX = rect.width > 0 ? canvas.width / rect.width : 1;
    const scaleY = rect.height > 0 ? canvas.height / rect.height : 1;
    const px = (e.clientX - rect.left) * scaleX;
    const py = (e.clientY - rect.top) * scaleY;
    const worldX = this.worldBounds.left + px / this.freeScale;
    const worldY = this.worldBounds.top + py / this.freeScale;

    const viewportCanvas = this.viewport.canvasEl;
    const viewRect = viewportCanvas.getBoundingClientRect();
    const worldW = viewRect.width / this.viewport.camera.zoom;
    const worldH = viewRect.height / this.viewport.camera.zoom;

    this.viewport.camera.x = worldX - worldW / 2;
    this.viewport.camera.y = worldY - worldH / 2;
    this.onJump();
  }

  private updateIndicatorFree(): void {
    const { camera } = this.viewport;
    const canvas = this.viewport.canvasEl;
    const rect = canvas.getBoundingClientRect();
    const worldW = camera.zoom > 0 ? rect.width / camera.zoom : 0;
    const worldH = camera.zoom > 0 ? rect.height / camera.zoom : 0;

    const left = (camera.x - this.worldBounds.left) * this.freeScale;
    const top = (camera.y - this.worldBounds.top) * this.freeScale;
    const width = Math.max(MIN_INDICATOR_PX, worldW * this.freeScale);
    const height = Math.max(MIN_INDICATOR_PX, worldH * this.freeScale);

    this.indicator.style.left = `${left}px`;
    this.indicator.style.top = `${top}px`;
    this.indicator.style.width = `${width}px`;
    this.indicator.style.height = `${height}px`;
  }

  // ------------------------------------------------------------------
  // Paginated mode (unchanged behavior, vertical page stack)
  // ------------------------------------------------------------------

  private buildThumbnails(): void {
    let top = 0;
    for (const page of this.layout.pages) {
      const aspect = page.height / page.width;
      const thumbHeight = Math.max(1, Math.round(THUMB_WIDTH * aspect));

      const wrap = document.createElement("div");
      wrap.className = "minimap-page";
      wrap.style.height = `${thumbHeight}px`;

      const canvas = document.createElement("canvas");
      canvas.width = THUMB_WIDTH;
      canvas.height = thumbHeight;
      canvas.style.backgroundColor = argbToCss(page.color);
      wrap.appendChild(canvas);
      this.track.appendChild(wrap);

      this.pageTops.push(top);
      top += thumbHeight + 4; // small gap between thumbnails, mirrors PAGE_GAP visually

      this.scheduleGenerate(page.index, canvas, thumbHeight);
    }
  }

  /** Generates thumbnails one page per animation frame so a many-page note
   * doesn't block the initial load. */
  private scheduleGenerate(pageIndex: number, canvas: HTMLCanvasElement, thumbHeight: number): void {
    requestAnimationFrame(() => this.generateThumbnail(pageIndex, canvas, thumbHeight));
  }

  private generateThumbnail(pageIndex: number, canvas: HTMLCanvasElement, thumbHeight: number): void {
    const page = this.layout.pages[pageIndex];
    if (!page) return;

    // Steals wasm's active decode window momentarily to rasterize this page
    // at thumbnail resolution; the caller resyncs the real window afterward.
    this.wasm.setActiveWindow([page.index]);
    const rgba = this.wasm.renderViewport(
      page.index,
      page.boxLeft,
      page.boxTop,
      page.width,
      page.height,
      THUMB_WIDTH,
      thumbHeight,
      -Infinity,
      Infinity,
      THUMB_MIN_STROKE_PX,
    );

    this.scratchCanvas.width = THUMB_WIDTH;
    this.scratchCanvas.height = thumbHeight;
    const imgData = new ImageData(new Uint8ClampedArray(rgba), THUMB_WIDTH, thumbHeight);
    this.scratchCtx.putImageData(imgData, 0, 0);

    const ctx = canvas.getContext("2d")!;
    ctx.fillStyle = argbToCss(page.color);
    ctx.fillRect(0, 0, THUMB_WIDTH, thumbHeight);

    // Images first (they're typically full-bleed backgrounds/photos), then
    // ink on top -- matches the main renderer's default stacking for the
    // common case; thumbnails are a quick-glance preview, not the precise
    // chronological interleave the main view does.
    const scale = THUMB_WIDTH / page.width;
    const images = this.wasm.getVisibleImages(page.index, page.boxLeft, page.boxTop, page.width, page.height);
    for (const img of images) {
      const bitmap = this.imageCache.get(img.name);
      if (bitmap === undefined) {
        this.imageCache.set(img.name, "pending");
        // Decode pre-downscaled to its thumbnail display size -- these can
        // be full-resolution photos (tens of MB decoded as RGBA); there's no
        // reason to ever materialize that at full size just to draw it at
        // ~96px wide.
        const dw = Math.max(1, Math.round((img.right - img.left) * scale));
        const dh = Math.max(1, Math.round((img.bottom - img.top) * scale));
        this.loadImage(img.name, dw, dh, () => this.generateThumbnail(pageIndex, canvas, thumbHeight));
        continue;
      }
      if (bitmap === "pending" || bitmap === "failed") continue;
      const ix = (img.left - page.boxLeft) * scale;
      const iy = (img.top - page.boxTop) * scale;
      ctx.drawImage(bitmap, ix, iy, (img.right - img.left) * scale, (img.bottom - img.top) * scale);
    }

    ctx.drawImage(this.scratchCanvas, 0, 0);

    this.onActiveWindowStolen();
  }

  private onPointerPaginated = (e: PointerEvent) => {
    this.jumpToTrackY(e.clientY - this.track.getBoundingClientRect().top);
    const onMove = (ev: PointerEvent) => this.jumpToTrackY(ev.clientY - this.track.getBoundingClientRect().top);
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  };

  /** Maps a Y offset within the minimap track to world-space and pans the
   * main viewport there (zoom unchanged), like clicking a scrollbar. */
  private jumpToTrackY(trackY: number): void {
    const trackHeight = this.track.scrollHeight || 1;
    const t = Math.max(0, Math.min(1, trackY / trackHeight));
    const worldY = t * this.layout.contentHeight;

    const canvas = this.viewport.canvasEl;
    const rect = canvas.getBoundingClientRect();
    const worldW = rect.width / this.viewport.camera.zoom;
    const worldH = rect.height / this.viewport.camera.zoom;

    const page = this.pageAtWorldY(worldY);
    const targetCenterX = page ? page.x + page.boxLeft + page.width / 2 : this.layout.contentWidth / 2;

    this.viewport.camera.x = targetCenterX - worldW / 2;
    this.viewport.camera.y = worldY - worldH / 2;
    this.onJump();
  }

  private pageAtWorldY(worldY: number): PageLayout | null {
    for (const p of this.layout.pages) {
      if (worldY >= p.y && worldY <= p.y + p.height) return p;
    }
    return this.layout.pages[0] ?? null;
  }

  private updateIndicatorPaginated(): void {
    const { camera } = this.viewport;
    const canvas = this.viewport.canvasEl;
    const rect = canvas.getBoundingClientRect();
    const worldH = rect.width > 0 ? rect.height / camera.zoom : 0;

    const trackHeight = this.track.scrollHeight || 1;
    const scale = trackHeight / Math.max(1, this.layout.contentHeight);

    const top = camera.y * scale;
    const height = Math.max(MIN_INDICATOR_PX, worldH * scale);
    this.indicator.style.top = `${top}px`;
    this.indicator.style.height = `${height}px`;

    // Auto-scroll the (independently scrollable) minimap panel so the
    // indicator stays in view as the user pans/zooms far down a long note --
    // otherwise the indicator moves outside the panel's visible scroll
    // window and panning looks like it does nothing to the minimap.
    const viewTop = this.container.scrollTop;
    const viewBottom = viewTop + this.container.clientHeight;
    if (top < viewTop || top + height > viewBottom) {
      this.container.scrollTop = top + height / 2 - this.container.clientHeight / 2;
    }
  }

  // ------------------------------------------------------------------

  private loadImage(name: string, dw: number, dh: number, onLoaded: () => void): void {
    const bytes = this.wasm.getBytes(name);
    if (bytes.length === 0) {
      this.imageCache.set(name, "failed");
      return;
    }
    // `bytes` is already a freshly-copied, tightly-sized owned buffer (see
    // NoteinModule.getBytes) -- no need to copy it again just to reach .buffer.
    const blob = new Blob([bytes.buffer as ArrayBuffer]);
    createImageBitmap(blob, { resizeWidth: dw, resizeHeight: dh, resizeQuality: "low" })
      .then((bitmap) => {
        this.imageCache.set(name, bitmap);
        onLoaded();
      })
      .catch(() => this.imageCache.set(name, "failed"));
  }

  /** Repositions the indicator rect to match the main viewport's current
   * world-space window. Call from the viewport's onChange callback. */
  updateIndicator(): void {
    if (this.freeform) this.updateIndicatorFree();
    else this.updateIndicatorPaginated();
  }
}
