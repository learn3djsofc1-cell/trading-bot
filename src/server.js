'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { URL } = require('node:url');
const { loadConfig } = require('./config');
const { parseSnapshotText } = require('./protocol');

const config = loadConfig();
const stateFile = path.resolve(config.storage.stateFile);
const eventLogFile = path.resolve(config.storage.eventLogFile);
fs.mkdirSync(path.dirname(stateFile), { recursive: true });
fs.mkdirSync(path.dirname(eventLogFile), { recursive: true });

let state = loadState();
let staleAlertAt = 0;

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);
    if (url.pathname === '/health') return sendJson(res, 200, buildHealth());

    if (!isAuthorized(req)) return sendJson(res, 401, { ok: false, error: 'unauthorized' });

    if (req.method === 'POST' && url.pathname === '/api/snapshot') {
      const body = await readBody(req, 2_000_000);
      const snapshot = parseSnapshotText(body);
      validateSnapshot(snapshot);
      state.lastSnapshot = snapshot;
      state.lastSnapshotReceivedAt = Date.now();
      state.sequence += 1;
      state.lastSequence = state.sequence;
      persistState();
      appendLog({ type: 'snapshot', sequence: state.sequence, snapshot });
      notifyTelegram(`MT5 copier received snapshot ${snapshot.eventId}: ${snapshot.positions.length} positions, ${snapshot.orders.length} pending orders.`);
      return sendJson(res, 200, { ok: true, sequence: state.sequence, eventId: snapshot.eventId });
    }

    if (req.method === 'GET' && url.pathname === '/api/snapshot') {
      if (!state.lastSnapshot) return sendText(res, 204, '');
      maybeSendStaleAlert();
      res.setHeader('X-Copier-Sequence', String(state.sequence));
      res.setHeader('X-Copier-Event-Id', state.lastSnapshot.eventId);
      res.setHeader('X-Copier-Received-At', String(state.lastSnapshotReceivedAt));
      return sendText(res, 200, state.lastSnapshot.raw, 'text/plain; charset=utf-8');
    }

    if (req.method === 'POST' && url.pathname === '/api/follower-status') {
      const body = await readBody(req, 256_000);
      let payload;
      try { payload = JSON.parse(body); } catch { payload = { raw: body }; }
      state.lastFollowerStatus = { ...payload, receivedAt: Date.now() };
      persistState();
      appendLog({ type: 'follower-status', status: state.lastFollowerStatus });
      if (payload && payload.level === 'error') notifyTelegram(`MT5 copier follower error: ${payload.message || 'unknown error'}`);
      return sendJson(res, 200, { ok: true });
    }

    return sendJson(res, 404, { ok: false, error: 'not found' });
  } catch (error) {
    appendLog({ type: 'server-error', error: error.message, stack: error.stack });
    return sendJson(res, 500, { ok: false, error: error.message });
  }
});

server.listen(config.port, config.host, () => {
  console.log(`MT5 copier relay listening on http://${config.host}:${config.port}`);
  console.log(`Symbol locked to ${config.symbol}.`);
});

function loadState() {
  const initial = { sequence: 0, lastSequence: 0, lastSnapshot: null, lastSnapshotReceivedAt: 0, lastFollowerStatus: null };
  if (!fs.existsSync(stateFile)) return initial;
  try {
    return { ...initial, ...JSON.parse(fs.readFileSync(stateFile, 'utf8')) };
  } catch (error) {
    const backup = `${stateFile}.corrupt.${Date.now()}`;
    fs.renameSync(stateFile, backup);
    console.error(`State file was corrupt and has been moved to ${backup}: ${error.message}`);
    return initial;
  }
}

function persistState() {
  const tmp = `${stateFile}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, stateFile);
}

function appendLog(entry) {
  fs.appendFileSync(eventLogFile, `${JSON.stringify({ ...entry, at: new Date().toISOString() })}\n`);
}

function validateSnapshot(snapshot) {
  if (snapshot.account !== config.masterId) throw new Error(`snapshot account ${snapshot.account} does not match masterId ${config.masterId}`);
  if (snapshot.symbol !== config.symbol) throw new Error(`snapshot symbol ${snapshot.symbol} does not match configured symbol ${config.symbol}`);
  for (const position of snapshot.positions) {
    if (position.symbol !== config.symbol) throw new Error(`position ${position.ticket} uses unsupported symbol ${position.symbol}`);
  }
  for (const order of snapshot.orders) {
    if (order.symbol !== config.symbol) throw new Error(`order ${order.ticket} uses unsupported symbol ${order.symbol}`);
  }
}

function buildHealth() {
  const now = Date.now();
  return {
    ok: true,
    symbol: config.symbol,
    sequence: state.sequence,
    hasSnapshot: Boolean(state.lastSnapshot),
    lastSnapshotReceivedAt: state.lastSnapshotReceivedAt,
    lastSnapshotAgeMs: state.lastSnapshotReceivedAt ? now - state.lastSnapshotReceivedAt : null,
    maxSnapshotAgeMs: config.maxSnapshotAgeMs,
    stale: state.lastSnapshotReceivedAt ? now - state.lastSnapshotReceivedAt > config.maxSnapshotAgeMs : true,
    positions: state.lastSnapshot?.positions.length || 0,
    orders: state.lastSnapshot?.orders.length || 0,
    lastFollowerStatus: state.lastFollowerStatus
  };
}

function maybeSendStaleAlert() {
  const health = buildHealth();
  const now = Date.now();
  if (health.stale && now - staleAlertAt > config.staleAlertEveryMs) {
    staleAlertAt = now;
    notifyTelegram(`MT5 copier warning: master snapshot stale (${health.lastSnapshotAgeMs ?? 'none'} ms).`);
  }
}

function isAuthorized(req) {
  const header = req.headers.authorization || '';
  return header === `Bearer ${config.authToken}`;
}

function readBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    let body = '';
    let bytes = 0;
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      bytes += Buffer.byteLength(chunk);
      if (bytes > maxBytes) {
        reject(new Error('request body too large'));
        req.destroy();
        return;
      }
      body += chunk;
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

function sendJson(res, status, payload) {
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(JSON.stringify(payload));
}

function sendText(res, status, payload, contentType = 'text/plain; charset=utf-8') {
  res.writeHead(status, { 'Content-Type': contentType, 'Cache-Control': 'no-store' });
  res.end(payload);
}

function notifyTelegram(message) {
  if (!config.telegram?.enabled || !config.telegram.botToken || !config.telegram.chatId) return;
  const payload = JSON.stringify({ chat_id: config.telegram.chatId, text: message });
  const req = httpsRequest({
    hostname: 'api.telegram.org',
    path: `/bot${config.telegram.botToken}/sendMessage`,
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) }
  });
  req.on('error', (error) => appendLog({ type: 'telegram-error', error: error.message }));
  req.end(payload);
}

function httpsRequest(options) {
  return require('node:https').request(options, (res) => res.resume());
}
