// Thin client for the Plectron HTTP API. Auth rides on the session cookie.

export class AuthError extends Error {}

async function request(method, path, body) {
  const init = { method, credentials: 'same-origin', headers: {} };
  if (body !== undefined) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(body);
  }
  const res = await fetch(path, init);
  if (res.status === 401) throw new AuthError('Not authorised. Open the link printed by Start-Plectron.');
  if (res.status === 204) return null;
  const isJson = (res.headers.get('Content-Type') || '').includes('application/json');
  const data = isJson ? await res.json() : await res.text();
  if (!res.ok) throw new Error((data && data.error) || res.statusText);
  return data;
}

export const api = {
  info: () => request('GET', '/api/info'),
  tools: () => request('GET', '/api/tools'),
  tool: (id) => request('GET', `/api/tools/${encodeURIComponent(id)}`),
  runs: (limit = 100) => request('GET', `/api/runs?limit=${limit}`),
  run: (id) => request('GET', `/api/runs/${encodeURIComponent(id)}`),
  startRun: (toolId, parameters) => request('POST', '/api/runs', { toolId, parameters }),
  deleteRun: (id) => request('DELETE', `/api/runs/${encodeURIComponent(id)}`),
  events: (id) => new EventSource(`/api/runs/${encodeURIComponent(id)}/events`),
  pages: () => request('GET', '/api/pages'),
  createSession: (pageId) => request('POST', `/api/pages/${encodeURIComponent(pageId)}/sessions`, {}),
  sessionEvents: (sid) => new EventSource(`/api/sessions/${sid}/events`),
  invoke: (sid, body) => request('POST', `/api/sessions/${sid}/invoke`, body),
  refresh: (sid, body) => request('POST', `/api/sessions/${sid}/refresh`, body),
  cancel: (sid, id) => request('POST', `/api/sessions/${sid}/cancel`, id ? { id } : {}),
  closeSession: (sid) => fetch(`/api/sessions/${sid}`, { method: 'DELETE', credentials: 'same-origin', keepalive: true }).catch(() => {}),
  closeSessionOnUnload: (sid) => navigator.sendBeacon(`/api/sessions/${sid}/close`),
};
