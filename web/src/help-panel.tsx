import { HelpIcon } from "./icons";

const FORMAT_DOCS_URL = "https://github.com/davidnoronha1/notein-export/blob/master/FORMAT.md";

/** Links out to FORMAT.md (the file-format reverse-engineering docs) on
 * GitHub rather than bundling a markdown renderer to show it in-app --
 * plain rendered markdown that GitHub already serves for free. */
export function HelpToggleButton() {
  return (
    <a id="help-button" href={FORMAT_DOCS_URL} target="_blank" rel="noopener" aria-label="File format documentation">
      <HelpIcon />
    </a>
  );
}
