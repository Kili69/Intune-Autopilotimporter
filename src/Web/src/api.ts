export function buildApiRequestOptions(init?: RequestInit): RequestInit {
  const headers = new Headers(init?.headers ?? {});
  const method = (init?.method ?? 'GET').toUpperCase();

  if (method !== 'GET' && !headers.has('Content-Type')) {
    headers.set('Content-Type', 'application/json');
  }

  return {
    ...init,
    cache: 'no-store',
    headers,
  };
}
