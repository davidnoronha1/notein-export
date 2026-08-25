import { clamp } from "../util";

export interface Camera {
  x: number; // world-space top-left of the viewport
  y: number;
  zoom: number; // world units -> device pixels
}

export const MIN_ZOOM = 0.05;
export const MAX_ZOOM = 8;

/**
 * Owns pan/zoom camera state and wires up pointer/wheel input on `canvas`.
 * Calls `onChange` whenever the camera moves, so the caller can re-render
 * (and re-evaluate the active page window) without polling every frame.
 */
// How long after the last wheel event to still count as "interacting" --
// covers the gaps between individual trackpad/mouse wheel ticks during one
// continuous gesture, which otherwise wouldn't overlap in time at all.
const WHEEL_SETTLE_MS = 150;

export class Viewport {
  camera: Camera = { x: 0, y: 0, zoom: 1 };
  private dragging = false;
  private lastPointer: { x: number; y: number } | null = null;
  private activePointers = new Map<number, { x: number; y: number }>();
  private pinchStartDist = 0;
  private pinchStartZoom = 1;
  private lastWheelTime = 0;
  private settleTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    private readonly canvas: HTMLCanvasElement,
    private readonly onChange: () => void,
  ) {
    canvas.addEventListener("pointerdown", this.onPointerDown);
    canvas.addEventListener("pointermove", this.onPointerMove);
    canvas.addEventListener("pointerup", this.onPointerUp);
    canvas.addEventListener("pointercancel", this.onPointerUp);
    canvas.addEventListener("wheel", this.onWheel, { passive: false });
  }

  /**
   * True while the camera is actively being dragged, pinched, or wheeled --
   * i.e. while another frame is imminent anyway, so it's not worth paying
   * full rasterization cost for a frame the user won't get to look at.
   * `Renderer` uses this to render at reduced resolution mid-gesture and
   * snap back to full quality once things settle (see `scheduleSettle`).
   */
  get isInteracting(): boolean {
    return this.dragging || this.activePointers.size >= 2 || performance.now() - this.lastWheelTime < WHEEL_SETTLE_MS;
  }

  /** Guarantees one more `onChange` fires after interaction stops, even if
   * no further input event would otherwise trigger it -- e.g. the wheel-quiet
   * window elapsing produces no event of its own, so without this the view
   * would stay at reduced quality until the next unrelated render. */
  private scheduleSettle(delayMs: number): void {
    if (this.settleTimer !== null) clearTimeout(this.settleTimer);
    this.settleTimer = setTimeout(() => {
      this.settleTimer = null;
      this.onChange();
    }, delayMs);
  }

  /** device pixels per CSS pixel, so canvas rendering stays crisp. */
  get dpr(): number {
    return window.devicePixelRatio || 1;
  }

  get canvasEl(): HTMLCanvasElement {
    return this.canvas;
  }

  screenToWorld(sx: number, sy: number): { x: number; y: number } {
    return { x: this.camera.x + sx / this.camera.zoom, y: this.camera.y + sy / this.camera.zoom };
  }

  /** Centers the camera on a world-space rect, e.g. a note's content bounds. */
  frame(x: number, y: number, w: number, h: number, viewportW: number, viewportH: number): void {
    const rawZoom = w > 0 && h > 0 ? Math.min(viewportW / w, viewportH / h, 1) : 1;
    const zoom = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, rawZoom));
    // camera.{x,y} is the viewport's world-space top-left, so to actually
    // center the rect (not just left/top-align it), offset by half the slack
    // between how much world-space the viewport shows and the rect's size.
    const worldW = viewportW / zoom;
    const worldH = viewportH / zoom;
    this.camera = { x: x - (worldW - w) / 2, y: y - (worldH - h) / 2, zoom };
    this.onChange();
  }

  private onPointerDown = (e: PointerEvent) => {
    this.canvas.setPointerCapture(e.pointerId);
    this.activePointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
    if (this.activePointers.size === 1) {
      this.dragging = true;
      this.lastPointer = { x: e.clientX, y: e.clientY };
      this.canvas.classList.add("panning");
    } else if (this.activePointers.size === 2) {
      this.dragging = false;
      this.pinchStartDist = this.pointerDistance();
      this.pinchStartZoom = this.camera.zoom;
    }
  };

  private onPointerMove = (e: PointerEvent) => {
    if (!this.activePointers.has(e.pointerId)) return;
    this.activePointers.set(e.pointerId, { x: e.clientX, y: e.clientY });

    if (this.activePointers.size === 2) {
      const dist = this.pointerDistance();
      if (this.pinchStartDist > 0) {
        const newZoom = clamp(this.pinchStartZoom * (dist / this.pinchStartDist), MIN_ZOOM, MAX_ZOOM);
        const center = this.pointerCenter();
        this.zoomAt(center.x, center.y, newZoom);
      }
      return;
    }

    if (!this.dragging || !this.lastPointer) return;
    const dx = e.clientX - this.lastPointer.x;
    const dy = e.clientY - this.lastPointer.y;
    this.lastPointer = { x: e.clientX, y: e.clientY };
    this.camera.x -= dx / this.camera.zoom;
    this.camera.y -= dy / this.camera.zoom;
    this.onChange();
  };

  private onPointerUp = (e: PointerEvent) => {
    this.activePointers.delete(e.pointerId);
    if (this.activePointers.size === 0) {
      this.dragging = false;
      this.lastPointer = null;
      this.canvas.classList.remove("panning");
      // The drag's last onChange (above, in onPointerMove) rendered at
      // reduced quality since isInteracting was still true at that instant;
      // it's now false, so this one snaps back to full quality.
      this.onChange();
    }
  };

  private onWheel = (e: WheelEvent) => {
    e.preventDefault();
    this.lastWheelTime = performance.now();
    if (e.ctrlKey || e.metaKey) {
      // Pinch-zoom gesture (trackpad) or ctrl+wheel: zoom around cursor.
      const factor = Math.exp(-e.deltaY * 0.01);
      const rect = this.canvas.getBoundingClientRect();
      this.zoomAt(e.clientX - rect.left, e.clientY - rect.top, clamp(this.camera.zoom * factor, MIN_ZOOM, MAX_ZOOM));
    } else {
      this.camera.x += e.deltaX / this.camera.zoom;
      this.camera.y += e.deltaY / this.camera.zoom;
      this.onChange();
    }
    this.scheduleSettle(WHEEL_SETTLE_MS + 20);
  };

  /** Sets zoom directly (e.g. from a slider), anchored on the viewport center. */
  setZoom(newZoom: number, viewportW: number, viewportH: number): void {
    this.zoomAt(viewportW / 2, viewportH / 2, clamp(newZoom, MIN_ZOOM, MAX_ZOOM));
  }

  private zoomAt(sx: number, sy: number, newZoom: number): void {
    const before = this.screenToWorld(sx, sy);
    this.camera.zoom = newZoom;
    const after = this.screenToWorld(sx, sy);
    this.camera.x += before.x - after.x;
    this.camera.y += before.y - after.y;
    this.onChange();
  }

  private pointerDistance(): number {
    const pts = [...this.activePointers.values()];
    if (pts.length < 2) return 0;
    const [a, b] = pts as [{ x: number; y: number }, { x: number; y: number }];
    return Math.hypot(a.x - b.x, a.y - b.y);
  }

  private pointerCenter(): { x: number; y: number } {
    const pts = [...this.activePointers.values()];
    const rect = this.canvas.getBoundingClientRect();
    const cx = pts.reduce((s, p) => s + p.x, 0) / pts.length;
    const cy = pts.reduce((s, p) => s + p.y, 0) / pts.length;
    return { x: cx - rect.left, y: cy - rect.top };
  }
}
