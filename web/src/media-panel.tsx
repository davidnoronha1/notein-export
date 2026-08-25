import { signal } from "@preact/signals";
import { render } from "preact";
import { useEffect, useState } from "preact/hooks";
import type { NoteinModule, AssetImage, AudioAsset } from "./wasm/loader";
import type { NoteLayout } from "./canvas/layout";
import { frameToBounds } from "./canvas/layout";
import type { Viewport } from "./canvas/viewport";
import { sniffImageMime } from "./canvas/export-render";
import { triggerDownload } from "./export";
import { downloadAllMedia } from "./media-zip";

function formatDuration(ms: number): string {
  const totalSeconds = Math.round(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

function extOf(entryName: string): string {
  const dot = entryName.lastIndexOf(".");
  return dot === -1 ? "bin" : entryName.slice(dot + 1);
}

export interface MediaPanelHandle {
  reset(): void;
}

/** Mounts the Media toggle button and its floating drawer (Images/Audio
 * tabs, click-to-jump, per-item download, bulk zip) into the given roots.
 * State lives in signals, so both mounted trees stay in sync without any
 * imperative glue beyond `reset()`, which the caller invokes on note
 * load/unload. */
export function mountMediaPanel(
  toolRoot: HTMLElement,
  panelRoot: HTMLElement,
  wasm: NoteinModule,
  getLayout: () => NoteLayout | null,
  viewport: Viewport,
  canvas: HTMLCanvasElement,
): MediaPanelHandle {
  const isOpen = signal(false);
  const images = signal<AssetImage[]>([]);
  const audio = signal<AudioAsset[]>([]);
  const loaded = signal(false);
  const activeTab = signal<"images" | "audio">("images");

  function toggle(): void {
    if (!isOpen.value && !loaded.value) {
      images.value = wasm.getAllImages();
      audio.value = wasm.getAllAudio();
      loaded.value = true;
    }
    isOpen.value = !isOpen.value;
  }

  function ToggleButton() {
    return (
      <button type="button" onClick={toggle}>
        Media
      </button>
    );
  }

  function ImageThumb({ img }: { img: AssetImage }) {
    const [src, setSrc] = useState<string | null>(null);
    useEffect(() => {
      const bytes = wasm.getBytes(img.name);
      const blob = new Blob([bytes.buffer as ArrayBuffer], { type: sniffImageMime(bytes) });
      const url = URL.createObjectURL(blob);
      setSrc(url);
      return () => URL.revokeObjectURL(url);
    }, [img.name]);

    return (
      <div
        class="media-thumb"
        onClick={() => {
          const layout = getLayout();
          if (layout) frameToBounds(viewport, layout, img.pageIndex, img, canvas);
        }}
      >
        {src && <img src={src} alt={img.name} />}
        <button
          type="button"
          class="media-dl"
          aria-label={`Download ${img.name}`}
          onClick={(e: MouseEvent) => {
            e.stopPropagation();
            const bytes = wasm.getBytes(img.name);
            triggerDownload(new Blob([bytes.buffer as ArrayBuffer], { type: sniffImageMime(bytes) }), img.name);
          }}
        >
          ⬇
        </button>
      </div>
    );
  }

  function AudioRow({ a }: { a: AudioAsset }) {
    const [url, setUrl] = useState<string | null>(null);
    useEffect(() => {
      const bytes = wasm.getBytes(a.entryName);
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
        <button type="button" onClick={() => triggerDownload(new Blob([wasm.getBytes(a.entryName).buffer as ArrayBuffer], { type: "audio/mp4" }), `${a.name}.${extOf(a.entryName)}`)}>
          ⬇ Download
        </button>
      </div>
    );
  }

  function Panel() {
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
            <button type="button" class={tab === "audio" ? "active" : ""} onClick={() => (activeTab.value = "audio")}>
              Audio
            </button>
          </div>
          <button type="button" disabled={!hasMedia} onClick={() => downloadAllMedia(wasm, images.value, audio.value)}>
            Download all (zip)
          </button>
          <button type="button" aria-label="Close" onClick={() => (isOpen.value = false)}>
            &times;
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

  render(<ToggleButton />, toolRoot);
  render(<Panel />, panelRoot);

  return {
    reset(): void {
      images.value = [];
      audio.value = [];
      loaded.value = false;
      activeTab.value = "images";
      isOpen.value = false;
    },
  };
}
