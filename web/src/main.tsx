import { render } from "preact";
import { App } from "./App";
import { app } from "./controller";

app.loadWasm().catch((err) => {
  console.error(err);
  app.status.value = `Fatal error: ${(err as Error).message}`;
  app.progressVisible.value = false;
});

render(<App />, document.getElementById("app")!);
