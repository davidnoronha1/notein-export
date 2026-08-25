import { zipSync } from "fflate";
import type { NoteinModule, AssetImage, AudioAsset } from "./wasm/loader";
import { triggerDownload } from "./export";

function extOf(entryName: string): string {
  const dot = entryName.lastIndexOf(".");
  return dot === -1 ? "bin" : entryName.slice(dot + 1);
}

function sanitizeName(name: string): string {
  return name.replace(/[^a-zA-Z0-9._-]+/g, "_");
}

/** Bundles every image and audio recording in the note into one zip
 * (images/ and audio/ folders), stored uncompressed since PNG/JPEG/M4A are
 * already-compressed formats, and triggers a browser download. */
export function downloadAllMedia(wasm: NoteinModule, images: AssetImage[], audio: AudioAsset[]): void {
  const files: Record<string, Uint8Array> = {};
  images.forEach((img, i) => {
    files[`images/image-${String(i + 1).padStart(3, "0")}.${extOf(img.name)}`] = wasm.getBytes(img.name);
  });
  audio.forEach((a, i) => {
    files[`audio/audio-${String(i + 1).padStart(3, "0")}-${sanitizeName(a.name)}.${extOf(a.entryName)}`] = wasm.getBytes(a.entryName);
  });
  const zipped = zipSync(files, { level: 0 });
  triggerDownload(new Blob([zipped.buffer as ArrayBuffer], { type: "application/zip" }), "notein-media.zip");
}
