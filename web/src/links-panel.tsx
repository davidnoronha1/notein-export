import { signal } from "@preact/signals";
import { render } from "preact";
import type { NoteinModule, LinkAsset } from "./wasm/loader";
import type { NoteLayout } from "./canvas/layout";
import { frameToBounds } from "./canvas/layout";
import type { Viewport } from "./canvas/viewport";

function isHttpUrl(destination: string): boolean {
  return /^https?:\/\//i.test(destination);
}

export interface LinksPanelHandle {
  reset(): void;
}

/** Mounts the Links toggle button and its floating drawer (list, jump-to,
 * open-external) into the given roots. Links aren't files, so there's no
 * download here. */
export function mountLinksPanel(
  toolRoot: HTMLElement,
  panelRoot: HTMLElement,
  wasm: NoteinModule,
  getLayout: () => NoteLayout | null,
  viewport: Viewport,
  canvas: HTMLCanvasElement,
): LinksPanelHandle {
  const isOpen = signal(false);
  const links = signal<LinkAsset[]>([]);
  const loaded = signal(false);

  function toggle(): void {
    if (!isOpen.value && !loaded.value) {
      links.value = wasm.getAllLinks();
      loaded.value = true;
    }
    isOpen.value = !isOpen.value;
  }

  function ToggleButton() {
    return (
      <button type="button" onClick={toggle}>
        Links
      </button>
    );
  }

  function LinkRow({ link }: { link: LinkAsset }) {
    return (
      <div class="media-row">
        <span class="media-row-label" title={link.destination}>
          {link.destination}
        </span>
        <div class="media-row-actions">
          <button
            type="button"
            onClick={() => {
              const layout = getLayout();
              if (layout) frameToBounds(viewport, layout, link.pageIndex, link, canvas);
            }}
          >
            Jump
          </button>
          {isHttpUrl(link.destination) && (
            <a href={link.destination} target="_blank" rel="noopener">
              Open ↗
            </a>
          )}
        </div>
      </div>
    );
  }

  function Panel() {
    if (!isOpen.value) return null;
    return (
      <div class="side-panel">
        <div class="side-panel-header">
          <span class="side-panel-title">Links</span>
          <button type="button" aria-label="Close" onClick={() => (isOpen.value = false)}>
            &times;
          </button>
        </div>
        <div class="side-panel-list">
          {links.value.length === 0 ? (
            <p class="media-empty">No links in this note.</p>
          ) : (
            links.value.map((link) => <LinkRow key={`${link.pageIndex}-${link.destination}`} link={link} />)
          )}
        </div>
      </div>
    );
  }

  render(<ToggleButton />, toolRoot);
  render(<Panel />, panelRoot);

  return {
    reset(): void {
      links.value = [];
      loaded.value = false;
      isOpen.value = false;
    },
  };
}
