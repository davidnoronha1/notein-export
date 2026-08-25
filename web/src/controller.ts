import { signal, type Signal } from "@preact/signals";
import { NoteinModule } from "./wasm/loader";
import { Viewport, MIN_ZOOM, MAX_ZOOM } from "./canvas/viewport";
import { Renderer } from "./canvas/renderer";
import { Minimap } from "./canvas/minimap";
import type { PageLayout } from "./canvas/layout";
import type { WorldRect } from "./canvas/export-render";
import { exportRegionPdf, exportRegionPng, exportRegionSvg, type ExportScale } from "./export";
import { formatStats } from "./stats";
import { nextPaint } from "./util";

const ZOOM_STEP_FACTOR = 1.25;
// Log-scale mapping so the slider gives fine control at low zoom and still
// reaches MAX_ZOOM, matching the feel of wheel/pinch zoom.
const ZOOM_LOG_RANGE = Math.log(MAX_ZOOM / MIN_ZOOM);
function sliderToZoom(value: number): number {
  return MIN_ZOOM * Math.exp((value / 100) * ZOOM_LOG_RANGE);
}
function zoomToSlider(zoom: number): number {
  return (100 * Math.log(zoom / MIN_ZOOM)) / ZOOM_LOG_RANGE;
}

export const DEFAULT_DROP_MESSAGE = "Drag & drop a Notein .in file here";

export interface ScreenRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

/**
 * Single reactive store + imperative bridge for the whole app: owns the
 * non-reactive canvas classes (Viewport/Renderer/Minimap, all wasm-backed
 * and too heavy to re-run as JSX) and exposes every UI-relevant bit of state
 * as a signal, so components stay pure `signal.value` reads instead of
 * poking the DOM directly the way the old main.ts did.
 */
export class AppController {
  wasm: NoteinModule | null = null;
  viewport: Viewport | null = null;
  renderer: Renderer | null = null;
  minimap: Minimap | null = null;
  canvasEl: HTMLCanvasElement | null = null;
  minimapEl: HTMLElement | null = null;
  private dragStartScreen: { x: number; y: number } | null = null;

  readonly status = signal("");
  readonly statsText = signal("");
  readonly progressVisible = signal(false);
  readonly noteLoaded = signal(false);
  /** Bumped on every load attempt (success or failure) so panels that cache
   * per-note data (media/links) know to reset -- see media-panel.tsx. */
  readonly noteVersion = signal(0);

  readonly zoom = signal(1);
  readonly pageExportEnabled = signal(false);
  /** Whether the loaded note has at least one bounded page -- an unbounded
   * (infinite-canvas) page has no real page boundary to export (see
   * layoutNote's "Known caveat" in CLAUDE.md), so if every page is
   * unbounded the page-export buttons are hidden entirely rather than
   * perpetually greyed out. A mixed note still shows them, toggling
   * pageExportEnabled live as the current page changes. */
  readonly notePageExportPossible = signal(false);
  /** Mirrors Minimap's own freeform-vs-paginated decision (any unbounded
   * page -> freeform) so App.tsx can style the minimap container to match
   * what Minimap actually renders inside it -- see index.html's #minimap.free. */
  readonly minimapFreeform = signal(false);

  readonly dropZoneVisible = signal(true);
  readonly dropZoneLoading = signal(false);
  readonly dropZoneDragOver = signal(false);
  readonly dropMessage = signal(DEFAULT_DROP_MESSAGE);

  readonly selectMode = signal(false);
  readonly dragRect = signal<ScreenRect | null>(null);
  readonly pendingRect = signal<WorldRect | null>(null);
  readonly exportPanelPos = signal<{ left: number; top: number } | null>(null);
  readonly regionExportBusy = signal(false);
  readonly pageExportBusy = signal(false);

  async loadWasm(): Promise<void> {
    this.status.value = "Loading wasm module…";
    this.progressVisible.value = true;
    await nextPaint();
    const wasmUrl = new URL("./wasm/notein.wasm", import.meta.url).href;
    this.wasm = await NoteinModule.load(wasmUrl);
    this.status.value = "";
    this.progressVisible.value = false;

    setInterval(() => {
      this.statsText.value = formatStats(this.renderer?.stats.fps() ?? null, this.wasm!.memoryBytes);
    }, 500);

    window.addEventListener("resize", () => this.renderer?.requestRender());
    window.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && (this.selectMode.value || this.pendingRect.value)) this.cancelSelection();
    });
  }

  attachCanvas(canvas: HTMLCanvasElement): void {
    if (this.canvasEl === canvas) return;
    this.canvasEl = canvas;
    this.viewport = new Viewport(canvas, () => this.onCameraChange());
  }

  attachMinimapContainer(el: HTMLElement): void {
    this.minimapEl = el;
  }

  private onCameraChange(): void {
    this.renderer?.requestRender();
    this.minimap?.updateIndicator();
    this.syncZoomUI();
    this.syncPageExportUI();
    // A selection (armed, mid-drag, or a finished region with the export
    // panel open) is anchored to screen position -- once the camera pans or
    // zooms underneath it, it no longer corresponds to the content it was
    // drawn over, so treat any camera movement as an implicit cancel. Panning
    // is normally unreachable mid-drag (the selection overlay captures the
    // pointer while select mode is active), but wheel/pinch-zoom listens on
    // the canvas itself and isn't blocked by the overlay, and a finished
    // selection's export panel stays open (with select mode already off)
    // while the canvas underneath is still freely pannable.
    if (this.selectMode.value || this.pendingRect.value) this.cancelSelection();
  }

  private syncZoomUI(): void {
    this.zoom.value = this.viewport!.camera.zoom;
  }

  /** The page whose box contains the viewport's current world-space center,
   * falling back to the closest page by vertical distance. */
  private currentPage(): PageLayout | null {
    const pages = this.renderer?.layout.pages ?? [];
    if (pages.length === 0 || !this.viewport || !this.canvasEl) return null;
    const rect = this.canvasEl.getBoundingClientRect();
    const center = this.viewport.screenToWorld(rect.width / 2, rect.height / 2);
    for (const p of pages) {
      const top = p.y + p.boxTop;
      if (center.y >= top && center.y <= top + p.height) return p;
    }
    let best = pages[0]!;
    let bestDist = Infinity;
    for (const p of pages) {
      const d = Math.abs(p.y + p.boxTop + p.height / 2 - center.y);
      if (d < bestDist) {
        bestDist = d;
        best = p;
      }
    }
    return best;
  }

  private syncPageExportUI(): void {
    const page = this.currentPage();
    this.pageExportEnabled.value = !!page && !page.unbounded;
  }

  // --- Zoom ---------------------------------------------------------------

  get sliderValue(): number {
    return zoomToSlider(this.zoom.value);
  }

  setZoomFromSlider(sliderValue: number): void {
    const rect = this.canvasEl!.getBoundingClientRect();
    this.viewport!.setZoom(sliderToZoom(sliderValue), rect.width, rect.height);
  }

  zoomIn(): void {
    const rect = this.canvasEl!.getBoundingClientRect();
    this.viewport!.setZoom(this.viewport!.camera.zoom * ZOOM_STEP_FACTOR, rect.width, rect.height);
  }

  zoomOut(): void {
    const rect = this.canvasEl!.getBoundingClientRect();
    this.viewport!.setZoom(this.viewport!.camera.zoom / ZOOM_STEP_FACTOR, rect.width, rect.height);
  }

  // --- Region select --------------------------------------------------------

  toggleSelectMode(): void {
    const turningOn = !this.selectMode.value;
    this.cancelSelection();
    if (turningOn) this.selectMode.value = true;
  }

  /** Cancels any in-progress or pending selection: an armed-but-not-yet-drawn
   * selection, a mid-drag rect, or a finished region still showing its export
   * panel. Called on Escape and on any camera movement (see onCameraChange)
   * -- both make the current rect meaningless. */
  cancelSelection(): void {
    this.exportPanelPos.value = null;
    this.pendingRect.value = null;
    this.dragRect.value = null;
    this.dragStartScreen = null;
    this.selectMode.value = false;
  }

  onSelectPointerDown(e: PointerEvent): void {
    if (!this.selectMode.value) return;
    this.exportPanelPos.value = null;
    this.pendingRect.value = null;
    const target = e.currentTarget as HTMLElement;
    const rect = target.getBoundingClientRect();
    this.dragStartScreen = { x: e.clientX - rect.left, y: e.clientY - rect.top };
    this.dragRect.value = { left: this.dragStartScreen.x, top: this.dragStartScreen.y, width: 0, height: 0 };
    target.setPointerCapture(e.pointerId);
  }

  onSelectPointerMove(e: PointerEvent): void {
    if (!this.dragStartScreen) return;
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const cx = e.clientX - rect.left;
    const cy = e.clientY - rect.top;
    this.dragRect.value = {
      left: Math.min(this.dragStartScreen.x, cx),
      top: Math.min(this.dragStartScreen.y, cy),
      width: Math.abs(cx - this.dragStartScreen.x),
      height: Math.abs(cy - this.dragStartScreen.y),
    };
  }

  onSelectPointerUp(e: PointerEvent): void {
    if (!this.dragStartScreen) return;
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const cx = e.clientX - rect.left;
    const cy = e.clientY - rect.top;
    const start = this.dragStartScreen;
    this.dragStartScreen = null;
    this.selectMode.value = false;

    const screenLeft = Math.min(start.x, cx);
    const screenTop = Math.min(start.y, cy);
    const screenRight = Math.max(start.x, cx);
    const screenBottom = Math.max(start.y, cy);
    if (screenRight - screenLeft < 4 || screenBottom - screenTop < 4) {
      this.dragRect.value = null;
      return; // too small to be a deliberate drag
    }

    const p0 = this.viewport!.screenToWorld(screenLeft, screenTop);
    const p1 = this.viewport!.screenToWorld(screenRight, screenBottom);
    this.pendingRect.value = { x: p0.x, y: p0.y, w: p1.x - p0.x, h: p1.y - p0.y };

    const centerX = (screenLeft + screenRight) / 2;
    // Rough placement now; ExportPanel re-centers/clamps itself against its
    // own real size once it has mounted and can measure it (see ExportPanel).
    this.exportPanelPos.value = { left: centerX, top: screenBottom + 8 };
  }

  // --- Export ---------------------------------------------------------------

  private async withBusy(busy: Signal<boolean>, fn: () => Promise<void>): Promise<void> {
    busy.value = true;
    this.progressVisible.value = true;
    await nextPaint(); // let the progress bar actually paint before the export's main-thread-blocking render work
    try {
      await fn();
    } catch (err) {
      console.error(err);
      this.status.value = `Export failed: ${(err as Error).message}`;
    } finally {
      busy.value = false;
      this.progressVisible.value = false;
    }
  }

  exportRegion(kind: "png" | "pdf" | "svg", scale: ExportScale): void {
    const rect = this.pendingRect.value;
    if (!rect || !this.renderer) return;
    const resync = () => this.renderer?.resyncActiveWindow();
    void this.withBusy(this.regionExportBusy, () => {
      if (kind === "png") return exportRegionPng(this.wasm!, this.renderer!.layout, rect, scale, resync, "notein-export");
      if (kind === "pdf") return exportRegionPdf(this.wasm!, this.renderer!.layout, rect, scale, resync, "notein-export");
      return exportRegionSvg(this.wasm!, this.renderer!.layout, rect, resync, "notein-export");
    });
  }

  exportPage(kind: "png" | "pdf" | "svg", scale: ExportScale): void {
    if (!this.renderer) return;
    const page = this.currentPage();
    if (!page || page.unbounded) return;
    const rect: WorldRect = { x: page.x, y: page.y, w: page.width, h: page.height };
    const resync = () => this.renderer?.resyncActiveWindow();
    const nameBase = `notein-page-${page.index + 1}`;
    void this.withBusy(this.pageExportBusy, () => {
      if (kind === "png") return exportRegionPng(this.wasm!, this.renderer!.layout, rect, scale, resync, nameBase);
      if (kind === "pdf") return exportRegionPdf(this.wasm!, this.renderer!.layout, rect, scale, resync, nameBase);
      return exportRegionSvg(this.wasm!, this.renderer!.layout, rect, resync, nameBase);
    });
  }

  // --- File load --------------------------------------------------------

  async openFile(file: File): Promise<void> {
    this.status.value = `Loading ${file.name}…`;
    this.dropMessage.value = `Loading ${file.name}…`;
    this.dropZoneLoading.value = true;
    this.progressVisible.value = true;
    await nextPaint(); // let progress bar + status actually paint before file I/O and wasm work
    try {
      const bytes = new Uint8Array(await file.arrayBuffer());
      await nextPaint(); // wasm.openFile blocks the main thread; let the progress bar actually render first
      this.wasm!.openFile(bytes);
      this.dropZoneVisible.value = false;

      this.renderer = new Renderer(this.wasm!, this.canvasEl!, this.viewport!);
      this.renderer.showWholeNote();
      this.minimap = new Minimap(
        this.minimapEl!,
        this.wasm!,
        this.renderer.layout,
        this.viewport!,
        () => this.renderer?.resyncActiveWindow(),
        () => {
          this.renderer?.requestRender();
          this.minimap?.updateIndicator();
        },
      );
      this.minimap.updateIndicator();
      this.noteLoaded.value = true;
      this.notePageExportPossible.value = this.renderer.layout.pages.some((p) => !p.unbounded);
      this.minimapFreeform.value = this.renderer.layout.pages.some((p) => p.unbounded);
      this.syncZoomUI();
      this.syncPageExportUI();
      this.noteVersion.value++;
      this.status.value = `${file.name} — ${this.renderer.layout.pages.length} page(s)`;
    } catch (err) {
      console.error(err);
      this.status.value = `Failed to load ${file.name}: ${(err as Error).message}`;
      // wasm's open() frees the previously loaded note before parsing the new
      // file, so on failure here the old note is already gone -- drop the
      // renderer/minimap referencing it rather than leaving them to call into
      // wasm against freed state on the next pan/zoom.
      this.renderer = null;
      this.minimap = null;
      this.noteLoaded.value = false;
      this.notePageExportPossible.value = false;
      this.minimapFreeform.value = false;
      this.dropZoneVisible.value = true;
      this.cancelSelection();
      this.noteVersion.value++;
    } finally {
      this.dropZoneLoading.value = false;
      this.dropMessage.value = DEFAULT_DROP_MESSAGE;
      this.progressVisible.value = false;
    }
  }
}

export const app = new AppController();
