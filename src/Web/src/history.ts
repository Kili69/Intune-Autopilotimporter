export interface HistoryRecord {
  importId?: string;
  serialNumber?: string;
  status?: string;
  requestedBy?: string;
  requestedByDisplayName?: string;
  deviceHashSha256?: string;
}

export function buildHistoryRequestUrl(baseUrl: string, showAll: boolean): string {
  const baseOrigin = typeof window !== 'undefined' ? window.location.origin : 'https://example.test';
  const url = new URL(baseUrl, baseOrigin);
  url.searchParams.set('top', '25');
  if (showAll) {
    url.searchParams.set('showAll', 'true');
  }
  return url.toString();
}

export function formatHashReference(value: string | null | undefined): string {
  if (!value) return '—';
  const trimmed = value.trim();
  if (!trimmed) return '—';
  if (trimmed.length <= 12) return trimmed;
  return `${trimmed.slice(0, 6)}…${trimmed.slice(-6)}`;
}
