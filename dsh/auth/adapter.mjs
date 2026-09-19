import http from 'node:http';

const secureCookies = values => (values || []).map(value => /;\s*secure(?:;|$)/i.test(value) ? value : `${value}; Secure`);

// node:http preserves the public Host for authority-bound cookies; Fetch implementations may overwrite it.
function internalGet(port, path, headers) {
  return new Promise((resolve, reject) => {
    const req = http.get({ hostname: '127.0.0.1', port, path, headers }, res => {
      res.on('error', reject);
      res.resume();
      resolve({ status: res.statusCode, headers: res.headers });
    });
    req.setTimeout(5000, () => req.destroy(new Error('Internal request timed out')));
    req.on('error', reject);
  });
}

function headersFor(req, upgrade = false) {
  const headers = { ...req.headers };
  const hop = String(headers.connection || '').split(',').map(x => x.trim().toLowerCase());
  for (const key of [...hop, 'connection', 'proxy-connection', 'keep-alive', 'transfer-encoding', 'te', 'trailer', 'upgrade', 'authorization']) delete headers[key];
  for (const key of Object.keys(headers)) if (key.startsWith('x-forwarded-') || key.startsWith('x-auth-request-')) delete headers[key];
  if (upgrade) {
    headers.connection = 'Upgrade';
    headers.upgrade = 'websocket';
  }
  return headers;
}

export function createAdapter({ authority, getOwners, getToken, dshPort = 3080, oauthPort = 4180 }) {
  const origin = `https://${authority}`;
  const fail = (res, status) => {
    if (res.destroyed) return;
    if (res.headersSent) return res.destroy();
    res.writeHead(status, { 'cache-control': 'no-store', 'content-type': 'text/plain' });
    res.end(`DSH gateway: ${status}\n`);
  };
  function trusted(req) {
    if (req.headers.host !== authority) return false;
    if (req.headers.origin && req.headers.origin !== origin) return false;
    if (req.headers['sec-fetch-site'] === 'cross-site') return false;
    if (!req.url.startsWith('/') || req.url.startsWith('//')) return false;
    return !new URL(req.url, origin).searchParams.has('token');
  }
  async function authorized(req) {
    // Validate the browser cookie independently; caller-supplied identity is never trusted.
    const response = await internalGet(oauthPort, '/oauth2/auth', { host: authority, cookie: req.headers.cookie || '', 'x-forwarded-proto': 'https' });
    if (response.status >= 500) throw new Error('OAuth unavailable');
    return response.status === 202 && (await getOwners()).has(response.headers['x-auth-request-email']?.toLowerCase());
  }
  async function bootstrap(req, res) {
    const token = getToken();
    if (!token) return fail(res, 503);
    const response = await internalGet(dshPort, `/?token=${encodeURIComponent(token)}`, { host: authority, ...(req.headers.origin ? { origin: req.headers.origin } : {}) });
    const cookies = response.headers['set-cookie'] || [];
    if (response.status !== 303 || response.headers.location !== '/' || !cookies.length) return fail(res, 502);
    if (!cookies.every(c => /;\s*HttpOnly(?:;|$)/i.test(c) && /;\s*SameSite=Strict(?:;|$)/i.test(c) && !/;\s*Domain=/i.test(c))) return fail(res, 502);
    res.writeHead(303, { location: '/', 'set-cookie': secureCookies(cookies), 'cache-control': 'no-store', 'referrer-policy': 'no-referrer' });
    res.end();
  }
  const server = http.createServer(async (req, res) => {
    try {
      if (req.url === '/_dsh_adapter/healthz' && req.headers.host === `127.0.0.1:${server.address().port}`) {
        if (!getToken()) return fail(res, 503);
        const response = await internalGet(dshPort, '/', { host: authority });
        res.writeHead([200, 401].includes(response.status) ? 204 : 503);
        return res.end();
      }
      if (!trusted(req)) return fail(res, 403);
      if (!await authorized(req)) return fail(res, 401);
      const upstream = http.request({ hostname: '127.0.0.1', port: dshPort, method: req.method, path: req.url, headers: headersFor(req) });
      const timer = setTimeout(() => upstream.destroy(), 30000);
      upstream.on('response', response => {
        clearTimeout(timer);
        if (response.statusCode === 401 && req.method === 'GET' && new URL(req.url, origin).pathname === '/') {
          response.resume();
          void bootstrap(req, res).catch(() => fail(res, 503));
          return;
        }
        const headers = { ...response.headers, 'cache-control': 'no-store' };
        if (headers['set-cookie']) headers['set-cookie'] = secureCookies(headers['set-cookie']);
        res.writeHead(response.statusCode, headers);
        response.on('error', () => res.destroy());
        response.pipe(res);
      });
      upstream.on('error', () => { clearTimeout(timer); fail(res, 502); });
      req.on('aborted', () => upstream.destroy());
      res.on('close', () => upstream.destroy());
      req.pipe(upstream);
    } catch { fail(res, 503); }
  });
  server.on('upgrade', async (req, socket, head) => {
    const reject = status => socket.end(`HTTP/1.1 ${status} Rejected\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
    socket.on('error', () => socket.destroy());
    try {
      if (!trusted(req) || req.headers.origin !== origin || req.headers.upgrade?.toLowerCase() !== 'websocket') return reject(403);
      if (!await authorized(req)) return reject(401);
      if (socket.destroyed) return;
      const upstream = http.request({ hostname: '127.0.0.1', port: dshPort, path: req.url, headers: headersFor(req, true) });
      const timer = setTimeout(() => upstream.destroy(), 10000);
      socket.on('close', () => upstream.destroy());
      upstream.on('error', () => { clearTimeout(timer); if (!socket.destroyed) reject(502); });
      upstream.on('response', response => { clearTimeout(timer); response.resume(); reject(response.statusCode); });
      upstream.on('upgrade', (response, peer, peerHead) => {
        clearTimeout(timer);
        const headers = { ...response.headers };
        if (headers['set-cookie']) headers['set-cookie'] = secureCookies(headers['set-cookie']);
        socket.write('HTTP/1.1 101 Switching Protocols\r\n' + Object.entries(headers).flatMap(([k, v]) => (Array.isArray(v) ? v : [v]).map(x => `${k}: ${x}\r\n`)).join('') + '\r\n');
        peer.on('error', () => socket.destroy());
        peer.on('close', () => socket.destroy());
        socket.on('close', () => peer.destroy());
        if (head.length) peer.write(head);
        if (peerHead.length) socket.write(peerHead);
        socket.pipe(peer).pipe(socket);
      });
      upstream.end();
    } catch { reject(503); }
  });
  return server;
}
