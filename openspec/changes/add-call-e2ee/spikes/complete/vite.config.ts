import { defineConfig } from "vite";
import { worklet } from "../../common/vite-plugin-worklet.ts";
import { libav } from "../../common/vite-plugin-libav.ts";
export default defineConfig({ plugins: [worklet(), libav()], build: { outDir: "dist", emptyOutDir: true } });
