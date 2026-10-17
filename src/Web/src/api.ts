export class ApiRequestError extends Error {
  constructor(message: string, public readonly status: number) {
    super(message);
    this.name = 'ApiRequestError';
  }
}

export async function canManageTagPolicies(request: () => Promise<unknown>): Promise<boolean> {
  try {
    await request();
    return true;
  } catch (error) {
    if (error instanceof ApiRequestError && error.status === 403) return false;
    throw error;
  }
}

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
