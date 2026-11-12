import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';

const projectVersion = readFileSync(new URL('../../VERSION', import.meta.url), 'utf8').trim();
const projectBranch = [
  process.env.GITHUB_HEAD_REF,
  process.env.GITHUB_REF_NAME,
  process.env.BUILD_SOURCEBRANCHNAME,
].map(branch => branch?.trim()).find(Boolean) ?? execFileSync(
  'git', ['branch', '--show-current'],
  { cwd: fileURLToPath(new URL('../..', import.meta.url)), encoding: 'utf8' },
).trim();

if (!projectBranch) {
  throw new Error('The frontend source branch could not be determined. Set GITHUB_REF_NAME for detached builds.');
}

export default defineConfig({
  base: '/api/ui/',
  define: {
    __APP_VERSION__: JSON.stringify(projectVersion),
    __APP_BRANCH__: JSON.stringify(projectBranch),
  },
  build: {
    outDir: '../FunctionApp/WebFrontend/wwwroot',
    emptyOutDir: true,
    sourcemap: false,
  },
  test: {
    environment: 'node',
  },
});
