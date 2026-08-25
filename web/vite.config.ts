import { defineConfig } from "vite";

export default defineConfig({
  assetsInclude: ["**/*.wasm"],
  esbuild: {
    jsx: "automatic",
    jsxImportSource: "preact",
  },
  server: {
    fs: { allow: [".."] },
  },
});
