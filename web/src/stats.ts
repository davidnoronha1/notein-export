/** Tracks a rolling average of time between `tick()` calls (call once per
 * actual render), so the FPS readout reflects real render cadence rather
 * than the display's refresh rate -- this app only redraws on camera/content
 * changes, not a continuous animation loop. */
export class FrameStats {
  private lastTime: number | null = null;
  private emaFrameMs = 0;

  tick(): void {
    const now = performance.now();
    if (this.lastTime !== null) {
      const dt = now - this.lastTime;
      // Exponential moving average smooths out noisy single-frame spikes.
      this.emaFrameMs = this.emaFrameMs === 0 ? dt : this.emaFrameMs * 0.9 + dt * 0.1;
    }
    this.lastTime = now;
  }

  /** FPS implied by the current average frame time, or null before any renders. */
  fps(): number | null {
    if (this.emaFrameMs <= 0) return null;
    return 1000 / this.emaFrameMs;
  }
}

function formatMB(bytes: number): string {
  return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
}

/** Renders the "FPS: xx  WASM: xx MB  JS: xx MB" overlay text. */
export function formatStats(fps: number | null, wasmBytes: number): string {
  const fpsStr = fps === null ? "--" : fps.toFixed(0);
  const parts = [`${fpsStr} fps`, `wasm ${formatMB(wasmBytes)}`];
  // performance.memory is a non-standard Chrome-only API; guard for other browsers.
  const perfMemory = (performance as Performance & { memory?: { usedJSHeapSize: number } }).memory;
  if (perfMemory) parts.push(`js ${formatMB(perfMemory.usedJSHeapSize)}`);
  return parts.join("  ");
}
