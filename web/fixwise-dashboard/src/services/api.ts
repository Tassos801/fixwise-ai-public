const BASE_URL = import.meta.env.VITE_API_BASE_URL?.trim() ?? '';
const TOKEN_KEY = 'fixwise_auth_token';
const REFRESH_KEY = 'fixwise_refresh_token';
const AUTH_CHANGED_EVENT = 'fixwise-auth-changed';

class APIError extends Error {
  status: number;
  detail: string;

  constructor(status: number, detail: string) {
    super(detail);
    this.name = 'APIError';
    this.status = status;
    this.detail = detail;
  }
}

function getAuthHeaders(): Record<string, string> {
  const token = localStorage.getItem(TOKEN_KEY);
  if (token) {
    return { Authorization: `Bearer ${token}` };
  }
  return {};
}

function clearStoredTokens() {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(REFRESH_KEY);
  window.dispatchEvent(new Event(AUTH_CHANGED_EVENT));
}

function storeTokens(accessToken: string, refreshToken: string) {
  localStorage.setItem(TOKEN_KEY, accessToken);
  localStorage.setItem(REFRESH_KEY, refreshToken);
  window.dispatchEvent(new Event(AUTH_CHANGED_EVENT));
}

function buildUrl(path: string): string {
  if (!BASE_URL) {
    return path;
  }

  if (path.startsWith('http://') || path.startsWith('https://')) {
    return path;
  }

  return `${BASE_URL}${path}`;
}

async function handleResponse(res: Response) {
  if (!res.ok) {
    let detail = `Request failed with status ${res.status}`;
    try {
      const data = await res.json();
      detail = data.detail || detail;
    } catch {
      // response may not be JSON
    }
    throw new APIError(res.status, detail);
  }

  const contentType = res.headers.get('content-type') || '';
  if (contentType.includes('application/json')) {
    return res.json();
  }
  return res;
}

function canRetryWithRefresh(path: string): boolean {
  return !path.startsWith('/api/auth/login') && !path.startsWith('/api/auth/register') && !path.startsWith('/api/auth/refresh');
}

async function refreshAccessToken(): Promise<boolean> {
  const refreshToken = localStorage.getItem(REFRESH_KEY);
  if (!refreshToken) {
    return false;
  }

  const res = await fetch(buildUrl('/api/auth/refresh'), {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ refresh_token: refreshToken }),
  });

  if (!res.ok) {
    clearStoredTokens();
    return false;
  }

  const data = await res.json();
  if (!data?.access_token || !data?.refresh_token) {
    clearStoredTokens();
    return false;
  }

  storeTokens(data.access_token, data.refresh_token);
  return true;
}

async function request(path: string, init: RequestInit, retryOnAuthFailure = true) {
  const run = () => {
    const headers = new Headers(init.headers);
    for (const [key, value] of Object.entries(getAuthHeaders())) {
      headers.set(key, value);
    }

    return fetch(buildUrl(path), {
      ...init,
      headers,
    });
  };

  let res = await run();

  if (res.status === 401 && retryOnAuthFailure && canRetryWithRefresh(path)) {
    const refreshed = await refreshAccessToken();
    if (refreshed) {
      res = await run();
    }
  }

  return handleResponse(res);
}

export const api = {
  async get(path: string) {
    return request(path, {});
  },

  async post(path: string, body?: unknown) {
    return request(path, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  },

  async put(path: string, body?: unknown) {
    return request(path, {
      method: 'PUT',
      headers: {
        'Content-Type': 'application/json',
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });
  },

  async del(path: string) {
    return request(path, { method: 'DELETE' });
  },

  async downloadReport(sessionId: string): Promise<Blob> {
    const result = await request(`/api/sessions/${sessionId}/report`, {});
    if (result instanceof Response) {
      return result.blob();
    }
    throw new Error('Expected a binary report response.');
  },
};

export { APIError, AUTH_CHANGED_EVENT, clearStoredTokens, storeTokens };
