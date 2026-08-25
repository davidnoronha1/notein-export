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

/** Small floating drawer listing every image and audio recording in the
 * note, with click-to-jump (images), playback (audio), per-item download,
 * and a bulk "download all" zip. Data is fetched from wasm lazily, on
 * first open, and cached until `reset()` (called on note load/unload). */
export class MediaPanel {
  private images: AssetImage[] = [];
  private audio: AudioAsset[] = [];
  private loaded = false;
  private activeTab: "images" | "audio" = "images";

  constructor(
    private readonly wasm: NoteinModule,
    private readonly panelEl: HTMLElement,
    private readonly tabImagesEl: HTMLButtonElement,
    private readonly tabAudioEl: HTMLButtonElement,
    private readonly listEl: HTMLElement,
    private readonly downloadAllEl: HTMLButtonElement,
    private readonly getLayout: () => NoteLayout | null,
    private readonly viewport: Viewport,
    private readonly canvas: HTMLCanvasElement,
  ) {
    this.tabImagesEl.addEventListener("click", () => this.setTab("images"));
    this.tabAudioEl.addEventListener("click", () => this.setTab("audio"));
    this.downloadAllEl.addEventListener("click", () => downloadAllMedia(this.wasm, this.images, this.audio));
  }

  /** Clears cached data and hides the panel -- call on note load/unload. */
  reset(): void {
    this.images = [];
    this.audio = [];
    this.loaded = false;
    this.listEl.replaceChildren();
    this.downloadAllEl.disabled = true;
    this.panelEl.classList.add("hidden");
  }

  open(): void {
    if (!this.loaded) {
      this.images = this.wasm.getAllImages();
      this.audio = this.wasm.getAllAudio();
      this.loaded = true;
      this.downloadAllEl.disabled = this.images.length === 0 && this.audio.length === 0;
    }
    this.panelEl.classList.remove("hidden");
    this.render();
  }

  close(): void {
    this.panelEl.classList.add("hidden");
  }

  toggle(): void {
    if (this.panelEl.classList.contains("hidden")) this.open();
    else this.close();
  }

  private setTab(tab: "images" | "audio"): void {
    this.activeTab = tab;
    this.tabImagesEl.classList.toggle("active", tab === "images");
    this.tabAudioEl.classList.toggle("active", tab === "audio");
    this.render();
  }

  private render(): void {
    this.listEl.replaceChildren();
    if (this.activeTab === "images") this.renderImages();
    else this.renderAudio();
  }

  private renderImages(): void {
    this.listEl.classList.add("media-grid");
    this.listEl.classList.remove("media-list");
    if (this.images.length === 0) {
      this.listEl.appendChild(this.emptyMessage("No images in this note."));
      return;
    }
    for (const img of this.images) {
      const cell = document.createElement("div");
      cell.className = "media-thumb";

      const imgEl = document.createElement("img");
      imgEl.alt = img.name;
      cell.appendChild(imgEl);
      this.loadThumb(imgEl, img.name);

      cell.addEventListener("click", () => {
        const layout = this.getLayout();
        if (layout) frameToBounds(this.viewport, layout, img.pageIndex, img, this.canvas);
      });

      const dl = document.createElement("button");
      dl.type = "button";
      dl.className = "media-dl";
      dl.textContent = "⬇";
      dl.setAttribute("aria-label", `Download ${img.name}`);
      dl.addEventListener("click", (e) => {
        e.stopPropagation();
        const bytes = this.wasm.getBytes(img.name);
        triggerDownload(new Blob([bytes.buffer as ArrayBuffer], { type: sniffImageMime(bytes) }), img.name);
      });
      cell.appendChild(dl);

      this.listEl.appendChild(cell);
    }
  }

  private loadThumb(imgEl: HTMLImageElement, name: string): void {
    const bytes = this.wasm.getBytes(name);
    const blob = new Blob([bytes.buffer as ArrayBuffer], { type: sniffImageMime(bytes) });
    imgEl.src = URL.createObjectURL(blob);
    imgEl.addEventListener("load", () => URL.revokeObjectURL(imgEl.src), { once: true });
  }

  private renderAudio(): void {
    this.listEl.classList.add("media-list");
    this.listEl.classList.remove("media-grid");
    if (this.audio.length === 0) {
      this.listEl.appendChild(this.emptyMessage("No audio recordings in this note."));
      return;
    }
    for (const a of this.audio) {
      const row = document.createElement("div");
      row.className = "media-row";

      const label = document.createElement("span");
      label.className = "media-row-label";
      label.textContent = `${a.name} (${formatDuration(a.durationMs)})`;
      row.appendChild(label);

      const bytes = this.wasm.getBytes(a.entryName);
      const blob = new Blob([bytes.buffer as ArrayBuffer], { type: "audio/mp4" });
      const url = URL.createObjectURL(blob);

      const audioEl = document.createElement("audio");
      audioEl.controls = true;
      audioEl.src = url;
      row.appendChild(audioEl);

      const dl = document.createElement("button");
      dl.type = "button";
      dl.className = "media-dl";
      dl.textContent = "⬇ Download";
      dl.addEventListener("click", () => triggerDownload(blob, `${a.name}.${extOf(a.entryName)}`));
      row.appendChild(dl);

      this.listEl.appendChild(row);
    }
  }

  private emptyMessage(text: string): HTMLElement {
    const p = document.createElement("p");
    p.className = "media-empty";
    p.textContent = text;
    return p;
  }
}
