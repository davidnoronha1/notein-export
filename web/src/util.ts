export function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}

export function xmlEscape(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

export function isHttpUrl(destination: string): boolean {
  return /^https?:\/\//i.test(destination);
}

export function extOf(entryName: string): string {
  const dot = entryName.lastIndexOf(".");
  return dot === -1 ? "bin" : entryName.slice(dot + 1);
}

export function formatDuration(ms: number): string {
  const totalSeconds = Math.round(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

/** Yields to the event loop so a DOM state change (e.g. showing the progress
 * bar) gets painted before a synchronous, main-thread-blocking operation
 * runs. Uses setTimeout rather than requestAnimationFrame: rAF callbacks are
 * paused for backgrounded/non-visible tabs, which would hang this forever,
 * whereas a timeout task always fires (and still lets the browser paint). */
export function nextPaint(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}
