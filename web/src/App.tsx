import { signal } from "@preact/signals";
import type { ExportScale } from "./export";
import { app } from "./controller";
import { CloseIcon, PlusIcon, MinusIcon } from "./icons";
import { MediaToggleButton, MediaPanel } from "./media-panel";
import { LinksToggleButton, LinksPanel } from "./links-panel";
import { HelpToggleButton } from "./help-panel";

const exportScale = signal<ExportScale>(4);

let fileInputEl: HTMLInputElement | null = null;

function onFileChosen(file: File | undefined): void {
  if (file) void app.openFile(file);
}

function DropZone() {
  return (
    <div
      id="drop-zone"
      class={[app.dropZoneVisible.value ? "" : "hidden", app.dropZoneLoading.value ? "loading" : "", app.dropZoneDragOver.value ? "drag-over" : ""].join(" ").trim()}
      onDragOver={(e) => {
        e.preventDefault();
        app.dropZoneDragOver.value = true;
      }}
      onDragLeave={() => (app.dropZoneDragOver.value = false)}
      onDrop={(e) => {
        e.preventDefault();
        app.dropZoneDragOver.value = false;
        onFileChosen(e.dataTransfer?.files?.[0]);
      }}
    >
      <p id="drop-message">
        {app.dropZoneLoading.value ? (
          app.dropMessage.value
        ) : (
          <>
            Drag &amp; drop a Notein <code>.in</code> file here
          </>
        )}
      </p>
      <button type="button" disabled={app.dropZoneLoading.value} onClick={() => fileInputEl?.click()}>
        Or choose a file…
      </button>
      <input
        ref={(el) => {
          fileInputEl = el;
        }}
        type="file"
        accept=".in"
        style={{ display: "none" }}
        onChange={(e) => {
          const input = e.currentTarget;
          const file = input.files?.[0];
          input.value = ""; // reset immediately so the same file can be re-selected after a failure
          onFileChosen(file);
        }}
      />
    </div>
  );
}

function ZoomControl() {
  if (!app.noteLoaded.value) return null;
  return (
    <div id="zoom-control">
      <button type="button" aria-label="Zoom out" onClick={() => app.zoomOut()}>
        <MinusIcon />
      </button>
      <input
        id="zoom-slider"
        type="range"
        min="0"
        max="100"
        step="0.5"
        value={app.sliderValue}
        onInput={(e) => app.setZoomFromSlider(Number(e.currentTarget.value))}
      />
      <button type="button" aria-label="Zoom in" onClick={() => app.zoomIn()}>
        <PlusIcon />
      </button>
      <span id="zoom-label">{Math.round(app.zoom.value * 100)}%</span>
    </div>
  );
}

function SelectionLayer() {
  const r = app.dragRect.value;
  return (
    <div id="selection-overlay" class={app.selectMode.value ? "active" : ""} onPointerDown={(e) => app.onSelectPointerDown(e)} onPointerMove={(e) => app.onSelectPointerMove(e)} onPointerUp={(e) => app.onSelectPointerUp(e)}>
      <div id="selection-rect" style={r ? { display: "block", left: `${r.left}px`, top: `${r.top}px`, width: `${r.width}px`, height: `${r.height}px` } : { display: "none" }} />
    </div>
  );
}

function ExportPanel() {
  const pos = app.exportPanelPos.value;
  if (!pos) return null;
  // Re-centers/clamps against the panel's actual measured size once mounted
  // (the position `pos` gives us is only a rough screen-anchor guess from the
  // selection drag -- see AppController.onSelectPointerUp).
  const onMount = (el: HTMLDivElement | null): void => {
    if (!el || !app.canvasEl) return;
    const rect = app.canvasEl.getBoundingClientRect();
    const panelRect = el.getBoundingClientRect();
    const left = Math.max(8, Math.min(rect.width - panelRect.width - 8, pos.left - panelRect.width / 2));
    const fitsBelow = pos.top + panelRect.height <= rect.height - 8;
    const top = fitsBelow ? pos.top : Math.max(8, pos.top - panelRect.height - 16);
    el.style.left = `${left}px`;
    el.style.top = `${top}px`;
  };
  const busy = app.regionExportBusy.value;
  return (
    <div id="export-panel" ref={onMount}>
      <div class="row">
        <button type="button" disabled={busy} onClick={() => app.exportRegion("png", exportScale.value)}>
          Export PNG
        </button>
        <button type="button" disabled={busy} onClick={() => app.exportRegion("pdf", exportScale.value)}>
          Export PDF
        </button>
        <button type="button" disabled={busy} onClick={() => app.exportRegion("svg", exportScale.value)}>
          Export SVG
        </button>
        <button type="button" aria-label="Cancel selection" onClick={() => app.cancelSelection()}>
          <CloseIcon />
        </button>
      </div>
    </div>
  );
}

function ExportControl() {
  if (!app.noteLoaded.value) return null;
  const busy = app.pageExportBusy.value;
  return (
    <div id="export-control">
      <select aria-label="Export resolution" value={exportScale.value} onChange={(e) => (exportScale.value = Number(e.currentTarget.value) as ExportScale)}>
        <option value="1">1x</option>
        <option value="2">2x</option>
        <option value="4">4x</option>
      </select>
      <button type="button" class={app.selectMode.value ? "active" : ""} onClick={() => app.toggleSelectMode()}>
        Select region…
      </button>
      {app.notePageExportPossible.value && (
        <>
          <div class="sep" />
          <button type="button" disabled={!app.pageExportEnabled.value || busy} onClick={() => app.exportPage("png", exportScale.value)}>
            Export page PNG
          </button>
          <button type="button" disabled={!app.pageExportEnabled.value || busy} onClick={() => app.exportPage("pdf", exportScale.value)}>
            Export page PDF
          </button>
          <button type="button" disabled={!app.pageExportEnabled.value || busy} onClick={() => app.exportPage("svg", exportScale.value)}>
            Export page SVG
          </button>
        </>
      )}
      <div class="sep" />
      <MediaToggleButton />
      <LinksToggleButton />
    </div>
  );
}

export function App() {
  return (
    <>
      <div id="viewer">
        <canvas
          id="canvas"
          ref={(el) => {
            if (el) app.attachCanvas(el);
          }}
        />
        <div id="status">{app.status.value}</div>
        <div id="stats">{app.statsText.value}</div>
        <div id="progress-bar" class={app.progressVisible.value ? "" : "hidden"}>
          <div id="progress-bar-fill" />
        </div>
        <ExportControl />
        <SelectionLayer />
        <ExportPanel />
        <MediaPanel />
        <LinksPanel />
        <ZoomControl />
        <HelpToggleButton />
      </div>
      <div
        id="minimap"
        class={[app.noteLoaded.value ? "" : "hidden", app.minimapFreeform.value ? "free" : ""].join(" ").trim()}
        ref={(el) => {
          if (el) app.attachMinimapContainer(el);
        }}
      />
      <DropZone />
    </>
  );
}
