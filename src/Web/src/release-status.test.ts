import { afterEach, describe, expect, it, vi } from 'vitest';
import { getReleaseNotice, loadReleaseNotice } from './release-status';

const now = Date.parse('2026-11-12T12:00:00Z');
const release = {
  status: 'available',
  checkedAtUtc: '2026-11-12T00:00:00Z',
  version: '1.4.20261112.10',
  releaseUrl: 'https://github.com/Kili69/Intune-Autopilotimporter/releases/tag/v1.4.20261112.10',
};

describe('Daily published release notice', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('compares version parts numerically instead of alphabetically', () => {
    expect(getReleaseNotice(release, '1.4.20261112.9', now)).toEqual({
      kind: 'update', version: release.version, url: release.releaseUrl,
    });
  });

  it.each(['1.4.20261112.10', '1.4.20261112.11', '1.5.20261101.1', '2.0.20261101.1'])(
    'does not offer an update to an equal or newer installed version %s',
    (installed) => expect(getReleaseNotice(release, installed, now)).toEqual({ kind: 'current' }),
  );

  it('compares major/minor before dates and counters', () => {
    expect(getReleaseNotice(release, '1.3.20261201.99', now).kind).toBe('update');
  });

  it('accepts a daily check through 26 hours and rejects it immediately afterward', () => {
    const expiresAt = Date.parse(release.checkedAtUtc) + 26 * 60 * 60 * 1000;
    expect(getReleaseNotice(release, '1.4.20261111.1', expiresAt).kind).toBe('update');
    expect(getReleaseNotice(release, '1.4.20261111.1', expiresAt + 1).kind).toBe('unavailable');
  });

  it.each([
    null,
    { ...release, status: 'unavailable' },
    { ...release, checkedAtUtc: 'invalid' },
    { ...release, checkedAtUtc: '2026-11-11T00:00:00Z' },
    { ...release, checkedAtUtc: '2026-11-13T00:00:00Z' },
    { ...release, version: 'v1.4.20261112.10' },
    { ...release, releaseUrl: 'https://example.com/fake-release' },
  ])('does not present failed, stale or invalid results as an update (%j)', (data) => {
    expect(getReleaseNotice(data, '1.4.20261111.1', now)).toEqual({ kind: 'unavailable' });
  });

  it('shows pending until the first central check and accepts no-release results', () => {
    expect(getReleaseNotice({ status: 'pending' }, '1.4.20261111.1', now)).toEqual({ kind: 'pending' });
    expect(getReleaseNotice({ ...release, status: 'noRelease' }, '1.4.20261111.1', now))
      .toEqual({ kind: 'current' });
    expect(getReleaseNotice(release, 'unknown', now)).toEqual({ kind: 'unavailable' });
  });

  it('reads only the local cached-status endpoint, not GitHub', async () => {
    const fetch = vi.fn().mockResolvedValue(new Response(JSON.stringify({ status: 'pending' })));
    vi.stubGlobal('fetch', fetch);
    expect(await loadReleaseNotice('1.4.20261111.1')).toEqual({ kind: 'pending' });
    expect(fetch).toHaveBeenCalledOnce();
    expect(fetch).toHaveBeenCalledWith('./release-status', expect.objectContaining({ cache: 'no-store' }));
  });

  it('reports an endpoint failure without breaking application initialization', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('', { status: 503 })));
    const warning = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    try {
      expect(await loadReleaseNotice('1.4.20261111.1')).toEqual({ kind: 'unavailable' });
      expect(warning).toHaveBeenCalledOnce();
    } finally {
      warning.mockRestore();
    }
  });
});
