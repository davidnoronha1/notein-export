import { NoteinModule } from "./wasm/loader";
import { Viewport, MIN_ZOOM, MAX_ZOOM } from "./canvas/viewport";
import { Renderer } from "./canvas/renderer";
import { Minimap } from "./canvas/minimap";
import type { PageLayout } from "./canvas/layout";
import type { WorldRect } from "./canvas/export-render";
import { exportRegionPdf, exportRegionPng, exportRegionSvg, type ExportScale } from "./export";
import { setupFileInput, hideDropZone, showDropZone } from "./file-input";
import { formatStats } from "./stats";
import { mountMediaPanel } from "./media-panel";
import { mountLinksPanel } from "./links-panel";

const statusEl = document.getElementById("status")!;
const statsEl = document.getElementById("stats")!;
const canvas = document.getElementById("canvas") as HTMLCanvasElement;
const progressBarEl = document.getElementById("progress-bar")!;
const zoomControlEl = document.getElementById("zoom-control")!;
const zoomSliderEl = document.getElementById("zoom-slider") as HTMLInputElement;
const zoomInEl = document.getElementById("zoom-in")!;
const zoomOutEl = document.getElementById("zoom-out")!;
const zoomLabelEl = document.getElementById("zoom-label")!;
const ZOOM_STEP_FACTOR = 1.25;
const minimapEl = document.getElementById("minimap")!;

const dropZoneEl = document.getElementById("drop-zone")!;
const dropMessageEl = document.getElementById("drop-message")!;
const openButtonEl = document.getElementById("open-button") as HTMLButtonElement;
const dropMessageDefault = dropMessageEl.innerHTML;

const exportControlEl = document.getElementById("export-control")!;
const exportScaleEl = document.getElementById("export-scale") as HTMLSelectElement;
const selectToolEl = document.getElementById("select-tool")!;
const exportPagePngEl = document.getElementById("export-page-png") as HTMLButtonElement;
const exportPagePdfEl = document.getElementById("export-page-pdf") as HTMLButtonElement;
const exportPageSvgEl = document.getElementById("export-page-svg") as HTMLButtonElement;
const selectionOverlayEl = document.getElementById("selection-overlay")!;
const selectionRectEl = document.getElementById("selection-rect")!;
const exportPanelEl = document.getElementById("export-panel")!;
const exportRegionPngEl = document.getElementById("export-region-png") as HTMLButtonElement;
const exportRegionPdfEl = document.getElementById("export-region-pdf") as HTMLButtonElement;
const exportRegionSvgEl = document.getElementById("export-region-svg") as HTMLButtonElement;
const exportRegionCancelEl = document.getElementById("export-region-cancel")!;
const mediaToolRootEl = document.getElementById("media-tool-root")!;
const mediaPanelRootEl = document.getElementById("media-panel-root")!;
const linksToolRootEl = document.getElementById("links-tool-root")!;
const linksPanelRootEl = document.getElementById("links-panel-root")!;

function setStatus(text: string): void {
  statusEl.textContent = text;
}

function showProgress(): void {
  progressBarEl.classList.remove("hidden");
}

function hideProgress(): void {
  progressBarEl.classList.add("hidden");
}

/** Yields to the event loop so a DOM state change (e.g. showing the progress
 * bar) gets painted before a synchronous, main-thread-blocking operation
 * runs. Uses setTimeout rather than requestAnimationFrame: rAF callbacks are
 * paused for backgrounded/non-visible tabs, which would hang this forever,
 * whereas a timeout task always fires (and still lets the browser paint). */
function nextPaint(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

// Log-scale mapping so the slider gives fine control at low zoom and still
// reaches MAX_ZOOM, matching the feel of wheel/pinch zoom.
const ZOOM_LOG_RANGE = Math.log(MAX_ZOOM / MIN_ZOOM);
function sliderToZoom(value: number): number {
  return MIN_ZOOM * Math.exp((value / 100) * ZOOM_LOG_RANGE);
}
function zoomToSlider(zoom: number): number {
  return (100 * Math.log(zoom / MIN_ZOOM)) / ZOOM_LOG_RANGE;
}

function currentExportScale(): ExportScale {
  const v = Number(exportScaleEl.value);
  return v === 1 || v === 2 || v === 4 ? v : 4;
}

/** The page whose box contains the viewport's current world-space center,
 * falling back to the closest page by vertical distance. */
function currentPage(pages: PageLayout[], viewport: Viewport): PageLayout | null {
  if (pages.length === 0) return null;
  const rect = canvas.getBoundingClientRect();
  const center = viewport.screenToWorld(rect.width / 2, rect.height / 2);
  for (const p of pages) {
    if (center.y >= p.y && center.y <= p.y + p.height) return p;
  }
  let best = pages[0]!;
  let bestDist = Infinity;
  for (const p of pages) {
    const d = Math.abs(p.y + p.height / 2 - center.y);
    if (d < bestDist) {
      bestDist = d;
      best = p;
    }
  }
  return best;
}

async function withDisabled(buttons: HTMLButtonElement[], fn: () => Promise<void>): Promise<void> {
  for (const b of buttons) b.disabled = true;
  showProgress();
  await nextPaint(); // let the progress bar actually paint before the export's main-thread-blocking render work
  try {
    await fn();
  } catch (err) {
    console.error(err);
    setStatus(`Export failed: ${(err as Error).message}`);
  } finally {
    for (const b of buttons) b.disabled = false;
    hideProgress();
  }
}

async function main(): Promise<void> {
  setStatus("Loading wasm module…");
  showProgress();
  await nextPaint();
  const wasmUrl = new URL("./wasm/notein.wasm", import.meta.url).href;
  const wasm = await NoteinModule.load(wasmUrl);
  setStatus("");
  hideProgress();

  setInterval(() => {
    statsEl.textContent = formatStats(renderer?.stats.fps() ?? null, wasm.memoryBytes);
  }, 500);

  let renderer: Renderer | null = null;
  let minimap: Minimap | null = null;
  function syncZoomUI(): void {
    zoomSliderEl.value = String(zoomToSlider(viewport.camera.zoom));
    zoomLabelEl.textContent = `${Math.round(viewport.camera.zoom * 100)}%`;
  }
  function syncPageExportUI(): void {
    const page = renderer ? currentPage(renderer.layout.pages, viewport) : null;
    const enabled = !!page && !page.unbounded;
    exportPagePngEl.disabled = !enabled;
    exportPagePdfEl.disabled = !enabled;
    exportPageSvgEl.disabled = !enabled;
  }
  const viewport = new Viewport(canvas, () => {
    renderer?.requestRender();
    minimap?.updateIndicator();
    syncZoomUI();
    syncPageExportUI();
  });

  window.addEventListener("resize", () => renderer?.requestRender());

  const mediaPanel = mountMediaPanel(mediaToolRootEl, mediaPanelRootEl, wasm, () => renderer?.layout ?? null, viewport, canvas);
  const linksPanel = mountLinksPanel(linksToolRootEl, linksPanelRootEl, wasm, () => renderer?.layout ?? null, viewport, canvas);

  zoomSliderEl.addEventListener("input", () => {
    const rect = canvas.getBoundingClientRect();
    viewport.setZoom(sliderToZoom(Number(zoomSliderEl.value)), rect.width, rect.height);
  });
  zoomInEl.addEventListener("click", () => {
    const rect = canvas.getBoundingClientRect();
    viewport.setZoom(viewport.camera.zoom * ZOOM_STEP_FACTOR, rect.width, rect.height);
  });
  zoomOutEl.addEventListener("click", () => {
    const rect = canvas.getBoundingClientRect();
    viewport.setZoom(viewport.camera.zoom / ZOOM_STEP_FACTOR, rect.width, rect.height);
  });

  // --- Region select ---------------------------------------------------
  let selectMode = false;
  let pendingRect: WorldRect | null = null;
  let dragStart: { x: number; y: number } | null = null;

  function setSelectMode(on: boolean): void {
    selectMode = on;
    selectToolEl.classList.toggle("active", on);
    selectionOverlayEl.classList.toggle("active", on);
    if (!on) dragStart = null;
  }

  function hideExportPanel(): void {
    exportPanelEl.classList.add("hidden");
    pendingRect = null;
  }

  selectToolEl.addEventListener("click", () => {
    hideExportPanel();
    selectionRectEl.style.display = "none";
    setSelectMode(!selectMode);
  });

  selectionOverlayEl.addEventListener("pointerdown", (e) => {
    if (!selectMode) return;
    hideExportPanel();
    const rect = selectionOverlayEl.getBoundingClientRect();
    dragStart = { x: e.clientX - rect.left, y: e.clientY - rect.top };
    selectionRectEl.style.left = `${dragStart.x}px`;
    selectionRectEl.style.top = `${dragStart.y}px`;
    selectionRectEl.style.width = "0px";
    selectionRectEl.style.height = "0px";
    selectionRectEl.style.display = "block";
    selectionOverlayEl.setPointerCapture(e.pointerId);
  });

  selectionOverlayEl.addEventListener("pointermove", (e) => {
    if (!dragStart) return;
    const rect = selectionOverlayEl.getBoundingClientRect();
    const cx = e.clientX - rect.left;
    const cy = e.clientY - rect.top;
    const left = Math.min(dragStart.x, cx);
    const top = Math.min(dragStart.y, cy);
    const w = Math.abs(cx - dragStart.x);
    const h = Math.abs(cy - dragStart.y);
    selectionRectEl.style.left = `${left}px`;
    selectionRectEl.style.top = `${top}px`;
    selectionRectEl.style.width = `${w}px`;
    selectionRectEl.style.height = `${h}px`;
  });

  selectionOverlayEl.addEventListener("pointerup", (e) => {
    if (!dragStart) return;
    const rect = selectionOverlayEl.getBoundingClientRect();
    const cx = e.clientX - rect.left;
    const cy = e.clientY - rect.top;
    const start = dragStart;
    dragStart = null;
    setSelectMode(false);

    const screenLeft = Math.min(start.x, cx);
    const screenTop = Math.min(start.y, cy);
    const screenRight = Math.max(start.x, cx);
    const screenBottom = Math.max(start.y, cy);
    if (screenRight - screenLeft < 4 || screenBottom - screenTop < 4) {
      selectionRectEl.style.display = "none";
      return; // too small to be a deliberate drag
    }

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

  exportRegionCancelEl.addEventListener("click", () => {
    hideExportPanel();
    selectionRectEl.style.display = "none";
  });

  const regionExportButtons = [exportRegionPngEl, exportRegionPdfEl, exportRegionSvgEl];

  exportRegionPngEl.addEventListener("click", () => {
    if (!pendingRect || !renderer) return;
    const rect = pendingRect;
    void withDisabled(regionExportButtons, () =>
      exportRegionPng(wasm, renderer!.layout, rect, currentExportScale(), () => renderer?.resyncActiveWindow(), "notein-export"),
    );
  });

  exportRegionPdfEl.addEventListener("click", () => {
    if (!pendingRect || !renderer) return;
    const rect = pendingRect;
    void withDisabled(regionExportButtons, () =>
      exportRegionPdf(wasm, renderer!.layout, rect, currentExportScale(), () => renderer?.resyncActiveWindow(), "notein-export"),
    );
  });

  exportRegionSvgEl.addEventListener("click", () => {
    if (!pendingRect || !renderer) return;
    const rect = pendingRect;
    void withDisabled(regionExportButtons, () => exportRegionSvg(wasm, renderer!.layout, rect, () => renderer?.resyncActiveWindow(), "notein-export"));
  });

  // --- Per-page export ---------------------------------------------------
  const pageExportButtons = [exportPagePngEl, exportPagePdfEl, exportPageSvgEl];

  exportPagePngEl.addEventListener("click", () => {
    if (!renderer) return;
    const page = currentPage(renderer.layout.pages, viewport);
    if (!page || page.unbounded) return;
    const rect: WorldRect = { x: page.x, y: page.y, w: page.width, h: page.height };
    void withDisabled(pageExportButtons, () =>
      exportRegionPng(wasm, renderer!.layout, rect, currentExportScale(), () => renderer?.resyncActiveWindow(), `notein-page-${page.index + 1}`),
    );
  });

  exportPagePdfEl.addEventListener("click", () => {
    if (!renderer) return;
    const page = currentPage(renderer.layout.pages, viewport);
    if (!page || page.unbounded) return;
    const rect: WorldRect = { x: page.x, y: page.y, w: page.width, h: page.height };
    void withDisabled(pageExportButtons, () =>
      exportRegionPdf(wasm, renderer!.layout, rect, currentExportScale(), () => renderer?.resyncActiveWindow(), `notein-page-${page.index + 1}`),
    );
  });

  exportPageSvgEl.addEventListener("click", () => {
    if (!renderer) return;
    const page = currentPage(renderer.layout.pages, viewport);
    if (!page || page.unbounded) return;
    const rect: WorldRect = { x: page.x, y: page.y, w: page.width, h: page.height };
    void withDisabled(pageExportButtons, () =>
      exportRegionSvg(wasm, renderer!.layout, rect, () => renderer?.resyncActiveWindow(), `notein-page-${page.index + 1}`),
    );
  });

  setupFileInput(async (file) => {
    setStatus(`Loading ${file.name}…`);
    dropMessageEl.textContent = `Loading ${file.name}…`;
    dropZoneEl.classList.add("loading");
    openButtonEl.disabled = true;
    showProgress();
    await nextPaint(); // let progress bar + status actually paint before file I/O and wasm work
    try {
      const bytes = new Uint8Array(await file.arrayBuffer());
      await nextPaint(); // wasm.openFile blocks the main thread; let the progress bar actually render first
      wasm.openFile(bytes);
      hideDropZone();

      renderer = new Renderer(wasm, canvas, viewport);
      renderer.showWholeNote();
      minimap = new Minimap(
        wasm,
        renderer.layout,
        viewport,
        () => renderer?.resyncActiveWindow(),
        () => {
          renderer?.requestRender();
          minimap?.updateIndicator();
        },
      );
      minimap.updateIndicator();
      zoomControlEl.classList.remove("hidden");
      exportControlEl.classList.remove("hidden");
      syncZoomUI();
      syncPageExportUI();
      mediaPanel.reset();
      linksPanel.reset();
      setStatus(`${file.name} — ${renderer.layout.pages.length} page(s)`);
    } catch (err) {
      console.error(err);
      setStatus(`Failed to load ${file.name}: ${(err as Error).message}`);
      showDropZone();
      minimapEl.classList.add("hidden");
      zoomControlEl.classList.add("hidden");
      exportControlEl.classList.add("hidden");
      hideExportPanel();
      setSelectMode(false);
      selectionRectEl.style.display = "none";
      mediaPanel.reset();
      linksPanel.reset();
    } finally {
      dropZoneEl.classList.remove("loading");
      dropMessageEl.innerHTML = dropMessageDefault;
      openButtonEl.disabled = false;
      hideProgress();
    }
  });
}

main().catch((err) => {
  console.error(err);
  setStatus(`Fatal error: ${(err as Error).message}`);
  hideProgress();
});
