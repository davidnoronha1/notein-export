import type { NoteinModule } from "../wasm/loader";
import type { NoteLayout } from "./layout";
import type { Viewport } from "./viewport";

const THUMB_WIDTH = 96;

function argbToCss(argb: number): string {
  const a = ((argb >>> 24) & 0xff) / 255;
  const r = (argb >>> 16) & 0xff;
  const g = (argb >>> 8) & 0xff;
  const b = argb & 0xff;
  return `rgba(${r}, ${g}, ${b}, ${a})`;
}

/**
 * Vertical strip of per-page thumbnails, plus a highlighted rect tracking the
 * main viewport's current position, so the user can jump straight to a page
 * in a long note instead of scrolling through it.
 */
export class Minimap {
  private readonly container: HTMLElement;
  private readonly track: HTMLElement;
  private readonly indicator: HTMLElement;
  private readonly scratchCanvas = document.createElement("canvas");
  private readonly scratchCtx: CanvasRenderingContext2D;
  private readonly imageCache = new Map<string, ImageBitmap | "pending" | "failed">();
  private pageTops: number[] = []; // px offset of each thumbnail within the track

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

    this.buildThumbnails();
    this.track.addEventListener("pointerdown", this.onPointer);
  }

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
    const rgba = this.wasm.renderViewport(page.index, 0, 0, page.width, page.height, THUMB_WIDTH, thumbHeight);

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
    const images = this.wasm.getVisibleImages(page.index, 0, 0, page.width, page.height);
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
        this.loadImage(img.name, pageIndex, canvas, thumbHeight, dw, dh);
        continue;
      }
      if (bitmap === "pending" || bitmap === "failed") continue;
      ctx.drawImage(bitmap, img.left * scale, img.top * scale, (img.right - img.left) * scale, (img.bottom - img.top) * scale);
    }

    ctx.drawImage(this.scratchCanvas, 0, 0);

    this.onActiveWindowStolen();
  }

  private loadImage(name: string, pageIndex: number, canvas: HTMLCanvasElement, thumbHeight: number, dw: number, dh: number): void {
    const bytes = this.wasm.getBytes(name);
    if (bytes.length === 0) {
      this.imageCache.set(name, "failed");
      return;
    }
    const blob = new Blob([bytes.slice().buffer as ArrayBuffer]);
    createImageBitmap(blob, { resizeWidth: dw, resizeHeight: dh, resizeQuality: "low" })
      .then((bitmap) => {
        this.imageCache.set(name, bitmap);
        this.generateThumbnail(pageIndex, canvas, thumbHeight);
      })
      .catch(() => this.imageCache.set(name, "failed"));
  }

  private onPointer = (e: PointerEvent) => {
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

    this.viewport.camera.x = Math.max(0, this.layout.contentWidth / 2 - worldW / 2);
    this.viewport.camera.y = Math.max(0, worldY - worldH / 2);
    this.onJump();
  }

  /** Repositions the indicator rect to match the main viewport's current
   * world-space window. Call from the viewport's onChange callback. */
  updateIndicator(): void {
    const { camera } = this.viewport;
    const canvas = this.viewport.canvasEl;
    const rect = canvas.getBoundingClientRect();
    const worldH = rect.width > 0 ? rect.height / camera.zoom : 0;

    const trackHeight = this.track.scrollHeight || 1;
    const scale = trackHeight / Math.max(1, this.layout.contentHeight);

    const top = camera.y * scale;
    const height = Math.max(4, worldH * scale);
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
}
