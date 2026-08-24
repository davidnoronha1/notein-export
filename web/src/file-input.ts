/** Wires drag-and-drop and a plain <input type="file"> onto the drop zone,
 * both converging on the same callback with the chosen File. */
export function setupFileInput(onFile: (file: File) => void | Promise<void>): void {
  const dropZone = document.getElementById("drop-zone")!;
  const openButton = document.getElementById("open-button")!;
  const fileInput = document.getElementById("file-input") as HTMLInputElement;

  openButton.addEventListener("click", () => fileInput.click());

  fileInput.addEventListener("change", () => {
    const file = fileInput.files?.[0];
    // Reset immediately so the same file can be re-selected after a failure.
    fileInput.value = "";
    if (file) void onFile(file);
  });

  dropZone.addEventListener("dragover", (e) => {
    e.preventDefault();
    dropZone.classList.add("drag-over");
  });
  dropZone.addEventListener("dragleave", () => {
    dropZone.classList.remove("drag-over");
  });
  dropZone.addEventListener("drop", (e) => {
    e.preventDefault();
    dropZone.classList.remove("drag-over");
    const file = e.dataTransfer?.files?.[0];
    if (file) void onFile(file);
  });
}

export function hideDropZone(): void {
  document.getElementById("drop-zone")!.classList.add("hidden");
}

export function showDropZone(): void {
  document.getElementById("drop-zone")!.classList.remove("hidden");
}
