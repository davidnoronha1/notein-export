import type { PageInfo } from "../wasm/loader";
import type { Viewport } from "./viewport";

export interface PageLayout {
  index: number;
  /** World-space position of this page's local-coordinate origin (0,0) --
   * NOT necessarily the box's top-left corner, see `boxLeft`/`boxTop`. Ink,
   * image, and text-box bounds all come back from wasm in this same
   * page-local space, so `x + someLocalCoord` always converts correctly. */
  x: number;
  y: number;
  /** Local-space offset of the displayed box's top-left corner from the
   * page's local origin. Zero for bounded pages (their box always starts at
   * local (0,0)); can be negative for an unbounded page, whose content may
   * extend arbitrarily far in any direction from wherever the user first
   * started drawing. The box's world-space rect is
   * `[x+boxLeft, x+boxLeft+width] x [y+boxTop, y+boxTop+height]`. */
  boxLeft: number;
  boxTop: number;
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
 * real paper_spec dimensions -- or actual content -- to lay it out with. */
const UNBOUNDED_FALLBACK_SIZE = 4000;
/** Margin (page-local units) added around an unbounded page's real content
 * bounds, so ink right at the edge isn't flush against the viewport border
 * and there's a little room to keep drawing outward from where it ends. */
const UNBOUNDED_CONTENT_PADDING = 400;

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
    let boxLeft = 0;
    let boxTop = 0;
    let width: number;
    let height: number;
    if (p.width > 0 && p.height > 0) {
      // Real declared paper size (bounded page, or an unbounded page whose
      // paper_spec still carries a usable size): trust it as-is.
      width = p.width;
      height = p.height;
    } else if (p.contentBounds) {
      // No declared size (typical for infinite-canvas pages) -- size the box
      // to where the ink actually is instead of guessing, since content can
      // sit arbitrarily far from local (0,0) in any direction.
      boxLeft = p.contentBounds.left - UNBOUNDED_CONTENT_PADDING;
      boxTop = p.contentBounds.top - UNBOUNDED_CONTENT_PADDING;
      width = p.contentBounds.right - p.contentBounds.left + UNBOUNDED_CONTENT_PADDING * 2;
      height = p.contentBounds.bottom - p.contentBounds.top + UNBOUNDED_CONTENT_PADDING * 2;
    } else {
      // Empty page, no size hint at all: an arbitrary fallback box is the
      // best we can do (nothing to fit it to).
      width = UNBOUNDED_FALLBACK_SIZE;
      height = UNBOUNDED_FALLBACK_SIZE;
    }
    laidOut.push({ index: i, x: 0, y, boxLeft, boxTop, width, height, unbounded: p.unbounded, color: p.color });
    y += height + PAGE_GAP;
    maxWidth = Math.max(maxWidth, width);
  }

  // Center each page horizontally within the shared column, since pages can
  // have differing widths (e.g. mixed orientations within one note).
  for (const p of laidOut) {
    p.x = (maxWidth - p.width) / 2 - p.boxLeft;
  }

  return { pages: laidOut, contentWidth: maxWidth, contentHeight: Math.max(0, y - PAGE_GAP) };
}

/** Pages whose page-local box intersects the world-space viewport rect. */
export function visiblePages(layout: NoteLayout, x: number, y: number, w: number, h: number): PageLayout[] {
  const right = x + w;
  const bottom = y + h;
  return layout.pages.filter((p) => {
    const left = p.x + p.boxLeft;
    const top = p.y + p.boxTop;
    return left <= right && left + p.width >= x && top <= bottom && top + p.height >= y;
  });
}

/** Pans/zooms the viewport to frame a page-local bounds rect (an image,
 * link, etc.), converting it to world space via the page's layout offset. */
export function frameToBounds(
  viewport: Viewport,
  layout: NoteLayout,
  pageIndex: number,
  bounds: { left: number; top: number; right: number; bottom: number },
  canvas: HTMLCanvasElement,
): void {
  const page = layout.pages[pageIndex];
  if (!page) return;
  const pad = 40;
  const rect = canvas.getBoundingClientRect();
  viewport.frame(
    page.x + bounds.left - pad,
    page.y + bounds.top - pad,
    bounds.right - bounds.left + pad * 2,
    bounds.bottom - bounds.top + pad * 2,
    rect.width,
    rect.height,
  );
}
