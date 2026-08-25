import type { NoteinModule, LinkAsset } from "./wasm/loader";
import type { NoteLayout } from "./canvas/layout";
import { frameToBounds } from "./canvas/layout";
import type { Viewport } from "./canvas/viewport";

function isHttpUrl(destination: string): boolean {
  return /^https?:\/\//i.test(destination);
}

/** Small floating drawer listing every hyperlink in the note, with a
 * jump-to-location button and an "open externally" link for http(s) URLs.
 * Links aren't files, so there's no download here. */
export class LinksPanel {
  private links: LinkAsset[] = [];
  private loaded = false;

  constructor(
    private readonly wasm: NoteinModule,
    private readonly panelEl: HTMLElement,
    private readonly listEl: HTMLElement,
    private readonly getLayout: () => NoteLayout | null,
    private readonly viewport: Viewport,
    private readonly canvas: HTMLCanvasElement,
  ) {}

  reset(): void {
    this.links = [];
    this.loaded = false;
    this.listEl.replaceChildren();
    this.panelEl.classList.add("hidden");
  }

  open(): void {
    if (!this.loaded) {
      this.links = this.wasm.getAllLinks();
      this.loaded = true;
    }
    this.panelEl.classList.remove("hidden");
    this.render();
  }

  close(): void {
    this.panelEl.classList.add("hidden");
  }

  toggle(): void {
    if (this.panelEl.classList.contains("hidden")) this.open();
    else this.close();
  }

  private render(): void {
    this.listEl.replaceChildren();
    if (this.links.length === 0) {
      const empty = document.createElement("p");
      empty.className = "media-empty";
      empty.textContent = "No links in this note.";
      this.listEl.appendChild(empty);
      return;
    }
    for (const link of this.links) {
      const row = document.createElement("div");
      row.className = "media-row";

      const label = document.createElement("span");
      label.className = "media-row-label";
      label.textContent = link.destination;
      label.title = link.destination;
      row.appendChild(label);

      const actions = document.createElement("div");
      actions.className = "media-row-actions";

      const jump = document.createElement("button");
      jump.type = "button";
      jump.textContent = "Jump";
      jump.addEventListener("click", () => {
        const layout = this.getLayout();
        if (layout) frameToBounds(this.viewport, layout, link.pageIndex, link, this.canvas);
      });
      actions.appendChild(jump);

      if (isHttpUrl(link.destination)) {
        const open = document.createElement("a");
        open.href = link.destination;
        open.target = "_blank";
        open.rel = "noopener";
        open.textContent = "Open ↗";
        actions.appendChild(open);
      }

      row.appendChild(actions);
      this.listEl.appendChild(row);
    }
  }
}
