export function argbToCss(argb: number): string {
  const a = ((argb >>> 24) & 0xff) / 255;
  const r = (argb >>> 16) & 0xff;
  const g = (argb >>> 8) & 0xff;
  const b = argb & 0xff;
  return `rgba(${r}, ${g}, ${b}, ${a})`;
}

/** Dark-mode color transform -- the exact mirror of wasm raster.outputColor,
 * matching how the Nebo app renders dark mode. Flips HSL lightness while
 * keeping hue and saturation: white paper -> black, black ink -> white, and a
 * colored pen keeps its hue but lightens (deep maroon -> soft pink, etc.) so it
 * stays vivid on the dark backdrop. Involutive. Keep both sides identical. */
export function invertArgb(argb: number): number {
  const r = ((argb >> 16) & 0xff) / 255;
  const g = ((argb >> 8) & 0xff) / 255;
  const b = (argb & 0xff) / 255;

  const { h, s, l } = rgbToHsl(r, g, b);
  const [r2, g2, b2] = hslToRgb(h, s, 1 - l);
  const ri = Math.round(Math.min(1, Math.max(0, r2)) * 255);
  const gi = Math.round(Math.min(1, Math.max(0, g2)) * 255);
  const bi = Math.round(Math.min(1, Math.max(0, b2)) * 255);
  return ((argb & 0xff000000) | (ri << 16) | (gi << 8) | bi) >>> 0;
}

function rgbToHsl(r: number, g: number, b: number): { h: number; s: number; l: number } {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  if (max === min) return { h: 0, s: 0, l };
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h: number;
  if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
  else if (max === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  return { h: h / 6, s, l };
}

function hueToRgb(p: number, q: number, t: number): number {
  if (t < 0) t += 1;
  if (t > 1) t -= 1;
  if (t < 1 / 6) return p + (q - p) * 6 * t;
  if (t < 0.5) return q;
  if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
  return p;
}

function hslToRgb(h: number, s: number, l: number): [number, number, number] {
  if (s === 0) return [l, l, l];
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  return [hueToRgb(p, q, h + 1 / 3), hueToRgb(p, q, h), hueToRgb(p, q, h - 1 / 3)];
}
