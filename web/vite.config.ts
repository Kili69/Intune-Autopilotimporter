import { readFileSync } from 'node:fs';
import { defineConfig } from 'vite';

const projectVersion = readFileSync(new URL('../VERSION', import.meta.url), 'utf8').trim();

export default defineConfig({
  base: '/api/ui/',
  define: {
    __APP_VERSION__: JSON.stringify(projectVersion),
  },
  build: {
    outDir: '../WebFrontend/wwwroot',
    emptyOutDir: true,
    sourcemap: false,
  },
  test: {
    environment: 'node',
  },
});
