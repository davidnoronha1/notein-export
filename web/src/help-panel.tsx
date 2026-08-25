import { signal } from "@preact/signals";
// Repo-root FORMAT.md, not under web/ -- vite.config.ts's server.fs.allow
// lets both dev and build resolve it via a raw string import.
import formatMd from "../../FORMAT.md?raw";
import { CloseIcon, HelpIcon } from "./icons";

const isOpen = signal(false);
const formatHtml = signal<string | null>(null);

/** Toggle button for the file-format documentation (FORMAT.md), always
 * available regardless of whether a note is loaded. */
export function HelpToggleButton() {
  return (
    <button
      type="button"
      id="help-button"
      aria-label="File format documentation"
      onClick={async () => {
        if (formatHtml.value === null) {
          // Lazy-loaded so the markdown renderer never enters the bundle
          // most sessions actually use (viewing a note, not the format docs).
          const { marked } = await import("marked");
          // FORMAT.md is a static bundled file, not user input, so rendering
          // its parsed HTML directly is safe -- nothing here for an
          // attacker to have injected.
          formatHtml.value = await marked.parse(formatMd);
        }
        isOpen.value = !isOpen.value;
      }}
    >
      <HelpIcon />
    </button>
  );
}

export function HelpPanel() {
  if (!isOpen.value || formatHtml.value === null) return null;
  return (
    <div class="side-panel help-panel">
      <div class="side-panel-header">
        <span class="side-panel-title">File Format Documentation</span>
        <button type="button" aria-label="Close" onClick={() => (isOpen.value = false)}>
          <CloseIcon />
        </button>
      </div>
      <div class="side-panel-list help-panel-body" dangerouslySetInnerHTML={{ __html: formatHtml.value }} />
    </div>
  );
}
