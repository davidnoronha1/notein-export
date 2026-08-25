import { signal, effect } from "@preact/signals";
import type { LinkAsset } from "./wasm/loader";
import { frameToBounds } from "./canvas/layout";
import { CloseIcon, ExternalLinkIcon, JumpIcon } from "./icons";
import { isHttpUrl } from "./util";
import { app } from "./controller";

const isOpen = signal(false);
const links = signal<LinkAsset[]>([]);
const loaded = signal(false);

// A newly (or failed-to-be) loaded note invalidates any cached listing.
effect(() => {
  app.noteVersion.value;
  links.value = [];
  loaded.value = false;
  isOpen.value = false;
});

function toggle(): void {
  if (!isOpen.value && !loaded.value) {
    links.value = app.wasm!.getAllLinks();
    loaded.value = true;
  }
  isOpen.value = !isOpen.value;
}

/** Toggle button, placed in the export control bar. */
export function LinksToggleButton() {
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
            const layout = app.renderer?.layout;
            if (layout) frameToBounds(app.viewport!, layout, link.pageIndex, link, app.canvasEl!);
          }}
        >
          <JumpIcon /> Jump
        </button>
        {isHttpUrl(link.destination) && (
          <a href={link.destination} target="_blank" rel="noopener">
            <ExternalLinkIcon /> Open
          </a>
        )}
      </div>
    </div>
  );
}

/** Floating drawer (list, jump-to, open-external). Links aren't files, so
 * there's no download here. Independently positioned in the layout from
 * `LinksToggleButton` -- both read/write the same module-level signals
 * above, so they stay in sync without any parent owning shared state. */
export function LinksPanel() {
  if (!isOpen.value) return null;
  return (
    <div class="side-panel">
      <div class="side-panel-header">
        <span class="side-panel-title">Links</span>
        <button type="button" aria-label="Close" onClick={() => (isOpen.value = false)}>
          <CloseIcon />
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
