import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const { execFileSync } = vi.hoisted(() => ({ execFileSync: vi.fn() }));
vi.mock('node:child_process', () => ({ execFileSync }));

describe('Frontend source branch metadata', () => {
  beforeEach(() => {
    vi.resetModules();
    execFileSync.mockReset().mockReturnValue('dev\n');
    vi.stubEnv('GITHUB_HEAD_REF', '');
    vi.stubEnv('GITHUB_REF_NAME', '');
    vi.stubEnv('BUILD_SOURCEBRANCHNAME', '');
  });

  afterEach(() => vi.unstubAllEnvs());

  it('uses the pull request source branch rather than its merge ref', async () => {
    vi.stubEnv('GITHUB_HEAD_REF', 'feature/tag-policy');
    vi.stubEnv('GITHUB_REF_NAME', '23/merge');
    const { default: config } = await import('../vite.config');
    expect(config.define?.__APP_BRANCH__).toBe('"feature/tag-policy"');
    expect(execFileSync).not.toHaveBeenCalled();
  });

  it.each(['main', 'dev'])('preserves the pushed branch %s on detached CI checkouts', async (branch) => {
    vi.stubEnv('GITHUB_REF_NAME', branch);
    const { default: config } = await import('../vite.config');
    expect(config.define?.__APP_BRANCH__).toBe(JSON.stringify(branch));
    expect(execFileSync).not.toHaveBeenCalled();
  });

  it('uses the Azure Pipelines branch when GitHub metadata is absent', async () => {
    vi.stubEnv('BUILD_SOURCEBRANCHNAME', 'dev');
    const { default: config } = await import('../vite.config');
    expect(config.define?.__APP_BRANCH__).toBe('"dev"');
    expect(execFileSync).not.toHaveBeenCalled();
  });

  it('uses the local Git checkout when no CI metadata is present', async () => {
    const { default: config } = await import('../vite.config');
    expect(config.define?.__APP_BRANCH__).toBe('"dev"');
    expect(execFileSync).toHaveBeenCalledWith(
      'git', ['branch', '--show-current'], expect.objectContaining({ encoding: 'utf8' }),
    );
  });

  it('rejects unknown detached checkouts rather than labelling them as main', async () => {
    execFileSync.mockReturnValue('');
    await expect(import('../vite.config')).rejects.toThrow('source branch could not be determined');
  });
});
