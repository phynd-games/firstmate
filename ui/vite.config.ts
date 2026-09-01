import path from "node:path"
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

// The dashboard server serves the built client from assets/dashboard by EXACT
// basename: one flat file per asset, from a small extension allowlist, with no
// subdirectory. So the build emits stable flat names rather than hashed paths
// under an assets/ folder, and `base` matches the server's /assets/ route.
export default defineConfig({
  base: "/assets/",
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": path.resolve(__dirname, "./src") } },
  build: {
    outDir: path.resolve(__dirname, "../assets/dashboard"),
    emptyOutDir: true,
    sourcemap: false,
    rollupOptions: {
      output: {
        entryFileNames: "app.js",
        chunkFileNames: "app-[name].js",
        assetFileNames: (info) => {
          const name = info.names?.[0] ?? ""
          if (name.endsWith(".css")) return "app.css"
          return "app-[name][extname]"
        },
      },
    },
  },
})
