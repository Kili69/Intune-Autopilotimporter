import { defineConfig } from 'vite';

export default defineConfig({
  base: '/api/ui/',
  build: {
    outDir: '../WebFrontend/wwwroot',
    emptyOutDir: true,
    sourcemap: false,
  },
  test: {
    environment: 'node',
  },
});
