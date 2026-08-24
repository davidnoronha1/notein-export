import { NoteinModule } from "./wasm/loader";
import { Viewport, MIN_ZOOM, MAX_ZOOM } from "./canvas/viewport";
import { Renderer } from "./canvas/renderer";
import { Minimap } from "./canvas/minimap";
import { setupFileInput, hideDropZone, showDropZone } from "./file-input";
import { formatStats } from "./stats";

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
  const viewport = new Viewport(canvas, () => {
    renderer?.requestRender();
    minimap?.updateIndicator();
    syncZoomUI();
  });

  window.addEventListener("resize", () => renderer?.requestRender());

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

  setupFileInput(async (file) => {
    setStatus(`Loading ${file.name}…`);
    showProgress();
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
      syncZoomUI();
      setStatus(`${file.name} — ${renderer.layout.pages.length} page(s)`);
    } catch (err) {
      console.error(err);
      setStatus(`Failed to load ${file.name}: ${(err as Error).message}`);
      showDropZone();
      minimapEl.classList.add("hidden");
      zoomControlEl.classList.add("hidden");
    } finally {
      hideProgress();
    }
  });
}

main().catch((err) => {
  console.error(err);
  setStatus(`Fatal error: ${(err as Error).message}`);
  hideProgress();
});
