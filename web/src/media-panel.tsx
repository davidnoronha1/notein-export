import { signal, effect } from "@preact/signals";
import { useEffect, useState } from "preact/hooks";
import type { AssetImage, AudioAsset } from "./wasm/loader";
import { frameToBounds } from "./canvas/layout";
import { sniffImageMime } from "./canvas/export-render";
import { triggerDownload } from "./export";
import { CloseIcon, DownloadIcon } from "./icons";
import { extOf, formatDuration } from "./util";
import { app } from "./controller";

const isOpen = signal(false);
const images = signal<AssetImage[]>([]);
const audio = signal<AudioAsset[]>([]);
const loaded = signal(false);
const activeTab = signal<"images" | "audio">("images");
const zipping = signal(false);

// A newly (or failed-to-be) loaded note invalidates any cached listing.
effect(() => {
  app.noteVersion.value;
  images.value = [];
  audio.value = [];
  loaded.value = false;
  activeTab.value = "images";
  isOpen.value = false;
});

async function downloadAll(): Promise<void> {
  zipping.value = true;
  await new Promise((resolve) => setTimeout(resolve, 0)); // let the "Zipping…" label paint before the blocking build
  try {
    triggerDownload(new Blob([app.wasm!.getMediaZip().buffer as ArrayBuffer], { type: "application/zip" }), "notein-media.zip");
  } finally {
    zipping.value = false;
  }
}

function toggle(): void {
  if (!isOpen.value && !loaded.value) {
    images.value = app.wasm!.getAllImages();
    audio.value = app.wasm!.getAllAudio();
    loaded.value = true;
  }
  isOpen.value = !isOpen.value;
}

/** Toggle button, placed in the export control bar. */
export function MediaToggleButton() {
  return (
    <button type="button" onClick={toggle}>
      Media
    </button>
  );
}

function ImageThumb({ img }: { img: AssetImage }) {
  const [src, setSrc] = useState<string | null>(null);
  useEffect(() => {
    const bytes = app.wasm!.getBytes(img.name);
    const blob = new Blob([bytes.buffer as ArrayBuffer], { type: sniffImageMime(bytes) });
    const url = URL.createObjectURL(blob);
    setSrc(url);
    return () => URL.revokeObjectURL(url);
  }, [img.name]);

  return (
    <div
      class="media-thumb"
      onClick={() => {
        const layout = app.renderer?.layout;
        if (layout) frameToBounds(app.viewport!, layout, img.pageIndex, img, app.canvasEl!);
      }}
    >
      {src && <img src={src} alt={img.name} />}
      <button
        type="button"
        class="media-dl"
        aria-label={`Download ${img.name}`}
        onClick={(e: MouseEvent) => {
          e.stopPropagation();
          const bytes = app.wasm!.getBytes(img.name);
          triggerDownload(new Blob([bytes.buffer as ArrayBuffer], { type: sniffImageMime(bytes) }), img.name);
        }}
      >
        <DownloadIcon />
      </button>
    </div>
  );
}

function AudioRow({ a }: { a: AudioAsset }) {
  const [url, setUrl] = useState<string | null>(null);
  useEffect(() => {
    const bytes = app.wasm!.getBytes(a.entryName);
    const blob = new Blob([bytes.buffer as ArrayBuffer], { type: "audio/mp4" });
    const objUrl = URL.createObjectURL(blob);
    setUrl(objUrl);
    return () => URL.revokeObjectURL(objUrl);
  }, [a.entryName]);

  return (
    <div class="media-row">
      <span class="media-row-label">
        {a.name} ({formatDuration(a.durationMs)})
      </span>
      {url && <audio controls src={url} />}
      <button type="button" onClick={() => triggerDownload(new Blob([app.wasm!.getBytes(a.entryName).buffer as ArrayBuffer], { type: "audio/mp4" }), `${a.name}.${extOf(a.entryName)}`)}>
        <DownloadIcon /> Download
      </button>
    </div>
  );
}

/** Floating drawer (Images/Audio tabs, click-to-jump, per-item download,
 * bulk zip). Independently positioned in the layout from `MediaToggleButton`
 * -- both read/write the same module-level signals above, so they stay in
 * sync without any parent needing to own or pass down media panel state. */
export function MediaPanel() {
  if (!isOpen.value) return null;
  const tab = activeTab.value;
  const hasMedia = images.value.length > 0 || audio.value.length > 0;
  return (
    <div class="side-panel">
      <div class="side-panel-header">
        <div class="side-panel-tabs">
          <button type="button" class={tab === "images" ? "active" : ""} onClick={() => (activeTab.value = "images")}>
            Images
          </button>
          {audio.value.length > 0 && (
            <button type="button" class={tab === "audio" ? "active" : ""} onClick={() => (activeTab.value = "audio")}>
              Audio
            </button>
          )}
        </div>
        <button type="button" disabled={!hasMedia || zipping.value} onClick={downloadAll}>
          <DownloadIcon /> {zipping.value ? "Zipping…" : "Download all"}
        </button>
        <button type="button" aria-label="Close" onClick={() => (isOpen.value = false)}>
          <CloseIcon />
        </button>
      </div>
      <div class={`side-panel-list ${tab === "images" ? "media-grid" : "media-list"}`}>
        {tab === "images"
          ? images.value.length === 0
            ? <p class="media-empty">No images in this note.</p>
            : images.value.map((img) => <ImageThumb key={img.name} img={img} />)
          : audio.value.length === 0
            ? <p class="media-empty">No audio recordings in this note.</p>
            : audio.value.map((a) => <AudioRow key={a.entryName} a={a} />)}
      </div>
    </div>
  );
}
