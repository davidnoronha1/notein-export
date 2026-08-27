import { PDFDocument } from "pdf-lib";
import type { NoteinModule } from "./wasm/loader";
import type { NoteLayout } from "./canvas/layout";
import { renderRegionToCanvas, renderRegionToSvg, type WorldRect } from "./canvas/export-render";

/** Output pixels per world unit. World units are the note's own paper-spec
 * units (dp-like); 4x/8x are ultra/print-quality, 1x/2x are lighter/faster. */
export type ExportScale = 1 | 2 | 4 | 8;

function canvasToPngBlob(canvas: HTMLCanvasElement): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (blob) resolve(blob);
      else reject(new Error("canvas.toBlob returned null"));
    }, "image/png");
  });
}

export function triggerDownload(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

async function canvasToPdfBytes(canvas: HTMLCanvasElement, worldW: number, worldH: number): Promise<Uint8Array> {
  const pngBlob = await canvasToPngBlob(canvas);
  const pngBytes = new Uint8Array(await pngBlob.arrayBuffer());

  const pdf = await PDFDocument.create();
  const png = await pdf.embedPng(pngBytes);
  const page = pdf.addPage([worldW, worldH]);
  page.drawImage(png, { x: 0, y: 0, width: worldW, height: worldH });
  return pdf.save();
}

async function renderExport(
  wasm: NoteinModule,
  layout: NoteLayout,
  rect: WorldRect,
  scale: ExportScale,
  resync: () => void,
): Promise<HTMLCanvasElement> {
  return renderRegionToCanvas(wasm, layout, rect, scale, resync);
}

export async function exportRegionPng(
  wasm: NoteinModule,
  layout: NoteLayout,
  rect: WorldRect,
  scale: ExportScale,
  resync: () => void,
  filenameBase: string,
): Promise<void> {
  const canvas = await renderExport(wasm, layout, rect, scale, resync);
  triggerDownload(await canvasToPngBlob(canvas), `${filenameBase}.png`);
}

/** SVG export is inherently resolution-independent (true vector paths), so
 * unlike PNG/PDF it takes no scale parameter. */
export async function exportRegionSvg(wasm: NoteinModule, layout: NoteLayout, rect: WorldRect, resync: () => void, filenameBase: string): Promise<void> {
  const svg = await renderRegionToSvg(wasm, layout, rect, resync);
  triggerDownload(new Blob([svg], { type: "image/svg+xml" }), `${filenameBase}.svg`);
}

export async function exportRegionPdf(
  wasm: NoteinModule,
  layout: NoteLayout,
  rect: WorldRect,
  scale: ExportScale,
  resync: () => void,
  filenameBase: string,
): Promise<void> {
  const canvas = await renderExport(wasm, layout, rect, scale, resync);
  const bytes = await canvasToPdfBytes(canvas, rect.w, rect.h);
  triggerDownload(new Blob([bytes.buffer as ArrayBuffer], { type: "application/pdf" }), `${filenameBase}.pdf`);
}
