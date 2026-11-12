export type ReleaseNotice =
  | { kind: 'update'; version: string; url: string }
  | { kind: 'pending' | 'unavailable' | 'current' };

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

const versionPattern = /^\d+\.\d+\.\d{8}\.\d+$/;

export function getReleaseNotice(
  data: unknown,
  installedVersion: string,
  now = Date.now(),
): ReleaseNotice {
  if (!isRecord(data)) return { kind: 'unavailable' };
  if (data.status === 'pending') return { kind: 'pending' };
  if (typeof data.checkedAtUtc !== 'string') return { kind: 'unavailable' };
  const age = now - Date.parse(data.checkedAtUtc);
  // Allow the daily timer a short execution/availability window.
  if (!Number.isFinite(age) || age < 0 || age > 26 * 60 * 60 * 1000) {
    return { kind: 'unavailable' };
  }
  if (data.status === 'noRelease') return { kind: 'current' };
  if (data.status !== 'available' || typeof data.version !== 'string' ||
      !versionPattern.test(data.version) || !versionPattern.test(installedVersion)) {
    return { kind: 'unavailable' };
  }
  const url = `https://github.com/Kili69/Intune-Autopilotimporter/releases/tag/v${data.version}`;
  if (data.releaseUrl !== url) return { kind: 'unavailable' };
  const installed = installedVersion.split('.').map(Number);
  const latest = data.version.split('.').map(Number);
  for (let index = 0; index < latest.length; index += 1) {
    const remotePart = latest[index];
    const localPart = installed[index];
    if (remotePart === undefined || localPart === undefined ||
        !Number.isSafeInteger(remotePart) || !Number.isSafeInteger(localPart)) {
      return { kind: 'unavailable' };
    }
    if (remotePart > localPart) return { kind: 'update', version: data.version, url };
    if (remotePart < localPart) return { kind: 'current' };
  }
  return { kind: 'current' };
}

export async function loadReleaseNotice(installedVersion: string): Promise<ReleaseNotice> {
  try {
    const response = await fetch('./release-status', {
      cache: 'no-store',
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) throw new Error(`Release status returned HTTP ${response.status}.`);
    return getReleaseNotice(await response.json(), installedVersion);
  } catch (error) {
    console.warn('Release status could not be loaded.', error);
    return { kind: 'unavailable' };
  }
}
