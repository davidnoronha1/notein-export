import { signal } from "@preact/signals";
import { useRef } from "preact/hooks";
import type { ExportScale } from "./export";
import { app } from "./controller";
import { CloseIcon, PlusIcon, MinusIcon, MoonIcon, SunIcon } from "./icons";
import { MediaToggleButton, MediaPanel } from "./media-panel";
import { LinksToggleButton, LinksPanel } from "./links-panel";
import { HelpToggleButton } from "./help-panel";
import { darkMode } from "./theme";

const exportScale = signal<ExportScale>(4);

function onFileChosen(file: File | undefined): void {
  if (file) void app.openFile(file);
}

function DropZone() {
  const fileInputRef = useRef<HTMLInputElement>(null);

  return (
    <div
      id="drop-zone"
      class={[
        app.dropZoneVisible.value ? "" : "hidden",
        app.dropZoneLoading.value ? "loading" : "",
        app.dropZoneDragOver.value ? "drag-over" : "",
      ]
        .filter(Boolean)
        .join(" ")}
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
      <img src="/favicon.svg" alt="Notein Viewer Logo" class="drop-zone-icon" width="256" height="256" />
      <p id="drop-message">
        {app.dropZoneLoading.value ? (
          app.dropMessage.value
        ) : (
          <>
            Drag &amp; drop a Notein <code>.in</code> or Nebo <code>.nebo</code> file here
          </>
        )}
      </p>
      <button type="button" disabled={app.dropZoneLoading.value} onClick={() => fileInputRef.current?.click()}>
        Or choose a file…
      </button>
      <input
        ref={fileInputRef}
        type="file"
        accept=".in,.nebo"
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
    <div
      id="selection-overlay"
      class={app.selectMode.value ? "active" : ""}
      onPointerDown={(e) => app.onSelectPointerDown(e)}
      onPointerMove={(e) => app.onSelectPointerMove(e)}
      onPointerUp={(e) => app.onSelectPointerUp(e)}
    >
      <div
        id="selection-rect"
        style={
          r
            ? {
                display: "block",
                left: `${r.left}px`,
                top: `${r.top}px`,
                width: `${r.width}px`,
                height: `${r.height}px`,
              }
            : { display: "none" }
        }
      />
    </div>
  );
}

function ExportPanel() {
  const pos = app.exportPanelPos.value;
  if (!pos) return null;
  const busy = app.regionExportBusy.value;
  return (
    <div
      id="export-panel"
      style={{
        left: `${pos.left}px`,
        top: `${pos.top}px`,
        transform: "translateX(-50%)",
      }}
    >
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

/** Dark-mode toggle (Nebo notes only -- see AppController.toggleDarkMode):
 * flips the canvas to an inverted backdrop with light ink. */
function ThemeToggleButton() {
  if (!app.isNebo.value) return null;
  return (
    <button
      type="button"
      aria-label={darkMode.value ? "Switch to light mode" : "Switch to dark mode"}
      class={darkMode.value ? "active" : ""}
      onClick={() => app.toggleDarkMode()}
    >
      {darkMode.value ? <SunIcon /> : <MoonIcon />}
    </button>
  );
}

function ExportControl() {
  if (!app.noteLoaded.value) return null;
  const busy = app.pageExportBusy.value;
  return (
    <div id="export-control">
      <select
        aria-label="Export resolution"
        value={exportScale.value}
        onChange={(e) => (exportScale.value = Number(e.currentTarget.value) as ExportScale)}
      >
        <option value="1">1x</option>
        <option value="2">2x</option>
        <option value="4">4x</option>
        <option value="8">8x</option>
      </select>
      <button type="button" class={app.selectMode.value ? "active" : ""} onClick={() => app.toggleSelectMode()}>
        Select region…
      </button>
      {app.notePageExportPossible.value && (
        <>
          <div class="sep" />
          <button
            type="button"
            disabled={!app.pageExportEnabled.value || busy}
            onClick={() => app.exportPage("png", exportScale.value)}
          >
            Export page PNG
          </button>
          <button
            type="button"
            disabled={!app.pageExportEnabled.value || busy}
            onClick={() => app.exportPage("pdf", exportScale.value)}
          >
            Export page PDF
          </button>
          <button
            type="button"
            disabled={!app.pageExportEnabled.value || busy}
            onClick={() => app.exportPage("svg", exportScale.value)}
          >
            Export page SVG
          </button>
        </>
      )}
      <div class="sep" />
      <MediaToggleButton />
      <LinksToggleButton />
      <ThemeToggleButton />
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
        {app.status.value ? <div id="status">{app.status.value}</div> : null}
        {app.statsText.value ? <div id="stats">{app.statsText.value}</div> : null}
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
        class={[app.noteLoaded.value ? "" : "hidden", app.minimapFreeform.value ? "free" : ""].filter(Boolean).join(" ")}
        ref={(el) => {
          if (el) app.attachMinimapContainer(el);
        }}
      />
      <DropZone />
    </>
  );
}
