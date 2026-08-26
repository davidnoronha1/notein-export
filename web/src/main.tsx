import { render } from "preact";
import { App } from "./App";
import { app } from "./controller";

// Debugging handle: lets the browser console inspect live state
// (app.isNebo.value, !!app.wasm?.exports.set_invert_colors, ...).
(app as unknown as Record<string, unknown>).app = app;

app.loadWasm().catch((err) => {
  console.error(err);
  app.status.value = `Fatal error: ${(err as Error).message}`;
  app.progressVisible.value = false;
});

render(<App />, document.getElementById("app")!);
