import { signal } from "@preact/signals";

/**
 * Dark mode: wasm inverts ink/textbox colors (see set_invert_colors), while
 * every JS-side background fill (canvas clear, page rects, minimap thumbs,
 * export backdrops) draws `invertArgb(page.color)` instead. A standalone
 * module (not a field on AppController) so the non-reactive canvas classes
 * can read it without a controller<->renderer import cycle.
 */
export const darkMode = signal(false);
