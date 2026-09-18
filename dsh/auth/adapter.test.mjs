import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { PassThrough } from 'node:stream';
import { once } from 'node:events';
import { createAdapter } from './adapter.mjs';
import { captureLaunchOutput } from './launch-output.mjs';

async function listen(server) { server.listen(0, '127.0.0.1'); await once(server, 'listening'); return server.address().port; }
async function fixture(t) {
  let token = 'test-process-token';
  let oauthDown = false;
  let exchanged = 0;
  let mutations = 0;
  let unsafeCookie = false;
  const sockets = new Set();
  const oauth = http.createServer((req, res) => {
    assert.equal(req.url, '/oauth2/auth');
    assert.equal(req.headers.host, 'dsh.example.test');
    const owner = req.headers.cookie?.includes('oauth=owner');
    res.writeHead(oauthDown ? 503 : owner || req.headers.cookie?.includes('oauth=other') ? 202 : 401,
      { 'x-auth-request-email': owner ? 'owner@example.test' : 'other@example.test' });
    res.end();
  });
  const dsh = http.createServer((req, res) => {
    assert.equal(req.headers.host, 'dsh.example.test');
    if (req.url === `/?token=${token}` && token) {
      exchanged++;
      res.writeHead(303, { location: '/', 'set-cookie': unsafeCookie ? 'native=valid; Path=/' : 'native=valid; Path=/; HttpOnly; SameSite=Strict' });
      return res.end();
    }
    if (!req.headers.cookie?.includes('native=valid')) { res.writeHead(401); return res.end('native authentication required'); }
    if (req.method === 'POST') mutations++;
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.write('first');
    setTimeout(() => res.end('second'), 15);
  });
  dsh.on('upgrade', (req, socket, head) => {
    if (!req.headers.cookie?.includes('native=valid')) return socket.end('HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n');
    socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n');
    if (head.length) socket.write(head);
    socket.pipe(socket);
  });
  const oauthPort = await listen(oauth);
  const dshPort = await listen(dsh);
  const adapter = createAdapter({ authority: 'dsh.example.test', owners: new Set(['owner@example.test']), getToken: () => token, oauthPort, dshPort });
  const port = await listen(adapter);
  for (const server of [oauth, dsh, adapter]) server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    for (const server of [adapter, oauth, dsh]) { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  });
  const request = (path = '/', headers = {}, method = 'GET') => new Promise((resolve, reject) => {
    const req = http.request({ hostname: '127.0.0.1', port, path, method, headers: { host: 'dsh.example.test', cookie: 'oauth=owner', ...headers } }, res => {
      let body = '';
      res.on('data', c => { body += c; });
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
    });
    req.on('error', reject); req.end();
  });
  return { port, request, setToken: v => { token = v; }, oauthDown: () => { oauthDown = true; }, unsafeCookie: () => { unsafeCookie = true; }, exchanged: () => exchanged, mutations: () => mutations };
}

test('owner bootstrap hides token, hardens native cookie, preserves existing sessions and streams', async t => {
  const f = await fixture(t);
  const fresh = await f.request();
  assert.equal(fresh.status, 303);
  assert.equal(fresh.headers.location, '/');
  assert.match(fresh.headers['set-cookie'][0], /HttpOnly; SameSite=Strict; Secure$/);
  assert.equal(fresh.headers['cache-control'], 'no-store');
  assert.ok(!JSON.stringify(fresh).includes('test-process-token'));
  assert.equal(f.exchanged(), 1);
  const existing = await f.request('/', { cookie: 'oauth=owner; native=valid' });
  assert.equal(existing.status, 200);
  assert.equal(existing.body, 'firstsecond');
  assert.equal(f.exchanged(), 1);
});

test('anonymous, wrong-owner and forged identity headers cannot bootstrap', async t => {
  const f = await fixture(t);
  for (const cookie of ['', 'oauth=other']) {
    const result = await f.request('/', { cookie, 'x-auth-request-email': 'owner@example.test', 'x-forwarded-email': 'owner@example.test' });
    assert.equal(result.status, 401);
    assert.equal(result.headers['set-cookie'], undefined);
  }
  assert.equal(f.exchanged(), 0);
});

test('rejects untrusted Host, Origin, cross-site requests and public token URLs', async t => {
  const f = await fixture(t);
  for (const headers of [{ host: 'evil.test' }, { origin: 'https://evil.test' }, { 'sec-fetch-site': 'cross-site' }]) assert.equal((await f.request('/', headers)).status, 403);
  assert.equal((await f.request('/?token=do-not-accept')).status, 403);
  assert.equal(f.exchanged(), 0);
});

test('missing launch token and OAuth outage fail closed; new process token can bootstrap', async t => {
  const f = await fixture(t);
  f.setToken(undefined);
  assert.equal((await f.request()).status, 503);
  f.setToken('new-process-token');
  assert.equal((await f.request()).status, 303);
  f.oauthDown();
  assert.equal((await f.request('/', { cookie: 'oauth=owner; native=valid' })).status, 503);
});

test('does not retry mutations or mint cookies for native API 401 responses', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('/api/task', {}, 'POST')).status, 401);
  assert.equal(f.exchanged(), 0);
  assert.equal(f.mutations(), 0);
  assert.equal((await f.request('/api/task', { cookie: 'oauth=owner; native=valid' }, 'POST')).status, 200);
  assert.equal(f.mutations(), 1);
});

test('rejects unexpected native cookie attributes and keeps health endpoint internal', async t => {
  const f = await fixture(t);
  const health = '/_dsh_adapter/healthz';
  assert.equal((await f.request(health, { host: `127.0.0.1:${f.port}`, cookie: '' })).status, 204);
  assert.equal((await f.request(health, { cookie: '' })).status, 401);
  f.unsafeCookie();
  const result = await f.request();
  assert.equal(result.status, 502);
  assert.equal(result.headers['set-cookie'], undefined);
  f.setToken(undefined);
  assert.equal((await f.request(health, { host: `127.0.0.1:${f.port}`, cookie: '' })).status, 503);
});

test('WebSocket preserves bidirectional traffic and rejects missing native or OAuth sessions', async t => {
  const f = await fixture(t);
  async function upgrade(cookie, expected) {
    const socket = net.connect(f.port, '127.0.0.1');
    socket.setTimeout(3000, () => socket.destroy(new Error('test timeout')));
    await once(socket, 'connect');
    const result = new Promise((resolve, reject) => {
      let data = '';
      socket.on('error', reject);
      socket.on('data', chunk => {
        data += chunk;
        if (!data.includes('\r\n\r\n')) return;
        if (expected === 101 && !data.includes('echo-payload')) { socket.write('echo-payload'); return; }
        socket.destroy(); resolve(data);
      });
    });
    socket.write(`GET /api/remote.mux HTTP/1.1\r\nHost: dsh.example.test\r\nOrigin: https://dsh.example.test\r\nCookie: ${cookie}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n`);
    const data = await result;
    assert.ok(data.startsWith(`HTTP/1.1 ${expected}`));
  }
  await upgrade('oauth=owner; native=valid', 101);
  await upgrade('oauth=owner', 401);
  await upgrade('native=valid', 401);
  assert.equal(f.exchanged(), 0);
});

test('startup token capture handles split chunks without logging credentials', async () => {
  const stream = new PassThrough();
  let token;
  let output = '';
  captureLaunchOutput(stream, value => { token = value; }, value => { output += value; });
  stream.write('dsh web: http://127.0.0.1:3080/?tok');
  stream.write('en=secret_test\n');
  stream.end('another URL ?token=hidden\nnormal log\n');
  await once(stream, 'end');
  assert.equal(token, 'secret_test');
  assert.ok(!output.includes('secret_test'));
  assert.ok(!output.includes('hidden'));
  assert.match(output, /normal log/);
});
