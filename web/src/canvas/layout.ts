import type { PageInfo } from "../wasm/loader";

export interface PageLayout {
  index: number;
  x: number;
  y: number;
  width: number;
  height: number;
  unbounded: boolean;
  color: number; // packed ARGB
}

export interface NoteLayout {
  pages: PageLayout[];
  contentWidth: number;
  contentHeight: number;
}

const PAGE_GAP = 40;
/** Nominal box for an unbounded (infinite-canvas) page when we don't have
 * real paper_spec dimensions to lay it out with. */
const UNBOUNDED_FALLBACK_SIZE = 4000;

/**
 * One shared coordinate space per note: bounded pages are stacked vertically
 * (a continuous-scroll document view); an unbounded note's single page just
 * occupies its own box with no stacking/guides drawn over it.
 */
export function layoutNote(pages: PageInfo[]): NoteLayout {
  let y = 0;
  let maxWidth = 0;
  const laidOut: PageLayout[] = [];

  for (let i = 0; i < pages.length; i++) {
    const p = pages[i]!;
    const width = p.width > 0 ? p.width : UNBOUNDED_FALLBACK_SIZE;
    const height = p.height > 0 ? p.height : UNBOUNDED_FALLBACK_SIZE;
    laidOut.push({ index: i, x: 0, y, width, height, unbounded: p.unbounded, color: p.color });
    y += height + PAGE_GAP;
    maxWidth = Math.max(maxWidth, width);
  }

  // Center each page horizontally within the shared column, since pages can
  // have differing widths (e.g. mixed orientations within one note).
  for (const p of laidOut) {
    p.x = (maxWidth - p.width) / 2;
  }

  return { pages: laidOut, contentWidth: maxWidth, contentHeight: Math.max(0, y - PAGE_GAP) };
}

/** Pages whose page-local box intersects the world-space viewport rect. */
export function visiblePages(layout: NoteLayout, x: number, y: number, w: number, h: number): PageLayout[] {
  const right = x + w;
  const bottom = y + h;
  return layout.pages.filter((p) => p.x <= right && p.x + p.width >= x && p.y <= bottom && p.y + p.height >= y);
}
