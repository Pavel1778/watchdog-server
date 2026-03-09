'use strict';

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { WebSocketServer, WebSocket } = require('ws');
const crypto = require('crypto');

// ─── CONFIG ────────────────────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || '1379';
const JWT_SECRET = process.env.JWT_SECRET || crypto.randomBytes(32).toString('hex');
const CLIPS_DIR = path.join(__dirname, 'clips');
const PUBLIC_DIR = path.join(__dirname, 'public');

if (!fs.existsSync(CLIPS_DIR)) fs.mkdirSync(CLIPS_DIR, { recursive: true });

// ─── STATE ─────────────────────────────────────────────────────────────────
// donors: Map<donorId, { ws, lastFrame, frameTime, torchOn, recording, audioClients }>
const donors = new Map();
// observers: Map<observerToken, { role, watchingDonor }>
const observers = new Map();
// mjpeg streams: Map<donorId, Set<res>>
const mjpegClients = new Map();
// audio WS clients: Map<donorId, Set<ws>>
const audioObservers = new Map();
// active recordings per donor: Map<donorId, { path, stream, startTime }>
const activeRecordings = new Map();

// ─── SIMPLE JWT ─────────────────────────────────────────────────────────────
function signToken(payload) {
  const header = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const sig = crypto.createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest('base64url');
  return `${header}.${body}.${sig}`;
}

function verifyToken(token) {
  try {
    const [header, body, sig] = token.split('.');
    const expected = crypto.createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest('base64url');
    if (sig !== expected) return null;
    return JSON.parse(Buffer.from(body, 'base64url').toString());
  } catch { return null; }
}

function getTokenFromReq(req) {
  const auth = req.headers['authorization'] || '';
  if (auth.startsWith('Bearer ')) return auth.slice(7);
  const url = new URL(req.url, `http://localhost`);
  return url.searchParams.get('token');
}

// ─── RECORDING ──────────────────────────────────────────────────────────────
function startRecording(donorId) {
  if (activeRecordings.has(donorId)) return;
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const filename = `clip_${donorId}_${ts}.mjpeg`;
  const filePath = path.join(CLIPS_DIR, filename);
  const stream = fs.createWriteStream(filePath);
  activeRecordings.set(donorId, { path: filePath, filename, stream, startTime: Date.now() });
  console.log(`[REC] Started recording donor ${donorId} → ${filename}`);
}

function writeFrameToRecording(donorId, jpegBuffer) {
  const rec = activeRecordings.get(donorId);
  if (!rec || !rec.stream.writable) return;
  // Write MJPEG boundary
  const boundary = '--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ' + jpegBuffer.length + '\r\n\r\n';
  rec.stream.write(boundary);
  rec.stream.write(jpegBuffer);
  rec.stream.write('\r\n');
}

function stopRecording(donorId) {
  const rec = activeRecordings.get(donorId);
  if (!rec) return null;
  rec.stream.end();
  activeRecordings.delete(donorId);
  const duration = Math.round((Date.now() - rec.startTime) / 1000);
  console.log(`[REC] Stopped recording donor ${donorId}, duration ${duration}s → ${rec.filename}`);
  return rec.filename;
}

// ─── MJPEG BROADCAST ────────────────────────────────────────────────────────
function broadcastFrame(donorId, jpegBuffer) {
  const clients = mjpegClients.get(donorId);
  if (!clients || clients.size === 0) return;
  const boundary = '--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ' + jpegBuffer.length + '\r\n\r\n';
  for (const res of clients) {
    try {
      res.write(boundary);
      res.write(jpegBuffer);
      res.write('\r\n');
    } catch (e) {
      clients.delete(res);
    }
  }
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────
function parseBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function json(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
  res.end(body);
}

function getDonorList() {
  return [...donors.entries()].map(([id, d]) => ({
    id,
    connected: d.ws && d.ws.readyState === WebSocket.OPEN,
    torchOn: d.torchOn || false,
    recording: activeRecordings.has(id),
    hasFrame: !!d.lastFrame,
    lastFrameAge: d.frameTime ? Date.now() - d.frameTime : null,
    observers: (mjpegClients.get(id) || new Set()).size,
  }));
}

function serveFile(res, filePath, contentType) {
  try {
    const data = fs.readFileSync(filePath);
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(data);
  } catch {
    res.writeHead(404); res.end('Not found');
  }
}

// ─── HTTP SERVER ─────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET,POST,DELETE,OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, Authorization',
    });
    return res.end();
  }

  const url = new URL(req.url, `http://localhost`);
  const pathname = url.pathname;

  // ── AUTH: Login ────────────────────────────────────────────────────────────
  if (pathname === '/auth/login' && req.method === 'POST') {
    const body = await parseBody(req);
    let data;
    try { data = JSON.parse(body.toString()); } catch { return json(res, 400, { error: 'invalid json' }); }
    const { password, role = 'viewer' } = data;
    if (password === ADMIN_PASSWORD) {
      const token = signToken({ role: 'admin', iat: Date.now() });
      return json(res, 200, { token, role: 'admin' });
    }
    // viewer password (same as admin for simplicity, or you can add separate)
    if (password === (process.env.VIEWER_PASSWORD || 'watch')) {
      const token = signToken({ role: 'viewer', iat: Date.now() });
      return json(res, 200, { token, role: 'viewer' });
    }
    return json(res, 401, { error: 'invalid password' });
  }

  // ── STATUS (public) ────────────────────────────────────────────────────────
  if (pathname === '/status' && req.method === 'GET') {
    return json(res, 200, {
      ok: true,
      donors: getDonorList(),
      clips: fs.readdirSync(CLIPS_DIR).filter(f => f.endsWith('.mjpeg') || f.endsWith('.mp4')).length,
    });
  }

  // ── DONOR: upload frame ────────────────────────────────────────────────────
  if (pathname.startsWith('/stream/frame') && req.method === 'POST') {
    const donorId = url.searchParams.get('donorId') || 'default';
    const jpeg = await parseBody(req);
    if (!donors.has(donorId)) donors.set(donorId, {});
    const donor = donors.get(donorId);
    donor.lastFrame = jpeg;
    donor.frameTime = Date.now();
    // Auto-start recording on first frame
    if (!activeRecordings.has(donorId)) startRecording(donorId);
    writeFrameToRecording(donorId, jpeg);
    broadcastFrame(donorId, jpeg);
    return json(res, 200, { ok: true });
  }

  // ── DONOR: upload mp4 clip ─────────────────────────────────────────────────
  if (pathname === '/clips/upload' && req.method === 'POST') {
    const donorId = url.searchParams.get('donorId') || 'default';
    const data = await parseBody(req);
    const ts = new Date().toISOString().replace(/[:.]/g, '-');
    const filename = `clip_${donorId}_${ts}.mp4`;
    fs.writeFileSync(path.join(CLIPS_DIR, filename), data);
    return json(res, 200, { ok: true, filename });
  }

  // ── AUTH REQUIRED below ────────────────────────────────────────────────────
  const token = getTokenFromReq(req);
  const payload = token ? verifyToken(token) : null;

  // ── OBSERVER: MJPEG stream ─────────────────────────────────────────────────
  if (pathname.startsWith('/stream') && req.method === 'GET') {
    const donorId = url.searchParams.get('donorId') || 'default';
    if (!donors.has(donorId)) donors.set(donorId, {});
    if (!mjpegClients.has(donorId)) mjpegClients.set(donorId, new Set());

    res.writeHead(200, {
      'Content-Type': 'multipart/x-mixed-replace; boundary=frame',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive',
      'Access-Control-Allow-Origin': '*',
    });

    mjpegClients.get(donorId).add(res);
    console.log(`[STREAM] Observer connected to donor ${donorId}, total: ${mjpegClients.get(donorId).size}`);

    // Send last frame immediately if available
    const donor = donors.get(donorId);
    if (donor && donor.lastFrame) {
      const jpeg = donor.lastFrame;
      res.write(`--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.length}\r\n\r\n`);
      res.write(jpeg);
      res.write('\r\n');
    }

    req.on('close', () => {
      mjpegClients.get(donorId)?.delete(res);
      console.log(`[STREAM] Observer disconnected from donor ${donorId}`);
    });
    return;
  }

  // ── TORCH CONTROL ─────────────────────────────────────────────────────────
  if (pathname.startsWith('/torch/') && req.method === 'POST') {
    const donorId = url.searchParams.get('donorId') || 'default';
    const state = pathname.includes('/on') ? 'on' : 'off';
    const donor = donors.get(donorId);
    if (donor && donor.ws && donor.ws.readyState === WebSocket.OPEN) {
      donor.ws.send(JSON.stringify({ cmd: 'torch', state }));
      donor.torchOn = state === 'on';
    }
    return json(res, 200, { ok: true, torch: state, donorId });
  }

  // ── STREAM STOP (observer command) ────────────────────────────────────────
  if (pathname === '/stream/stop' && req.method === 'POST') {
    const donorId = url.searchParams.get('donorId') || 'default';
    const donor = donors.get(donorId);
    if (donor && donor.ws && donor.ws.readyState === WebSocket.OPEN) {
      donor.ws.send(JSON.stringify({ cmd: 'stopStream' }));
    }
    // Stop recording too
    stopRecording(donorId);
    return json(res, 200, { ok: true, action: 'stopStream', donorId });
  }

  // ── STREAM START (observer command) ───────────────────────────────────────
  if (pathname === '/stream/start' && req.method === 'POST') {
    const donorId = url.searchParams.get('donorId') || 'default';
    const donor = donors.get(donorId);
    if (donor && donor.ws && donor.ws.readyState === WebSocket.OPEN) {
      donor.ws.send(JSON.stringify({ cmd: 'startStream' }));
    }
    return json(res, 200, { ok: true, action: 'startStream', donorId });
  }

  // ── CLIPS: list ───────────────────────────────────────────────────────────
  if (pathname === '/clips' && req.method === 'GET') {
    const files = fs.readdirSync(CLIPS_DIR)
      .filter(f => f.endsWith('.mjpeg') || f.endsWith('.mp4'))
      .map(f => {
        const stat = fs.statSync(path.join(CLIPS_DIR, f));
        return { filename: f, size: stat.size, created: stat.birthtime };
      })
      .sort((a, b) => new Date(b.created) - new Date(a.created));
    return json(res, 200, files);
  }

  // ── CLIPS: download ───────────────────────────────────────────────────────
  if (pathname.startsWith('/clips/') && req.method === 'GET') {
    const filename = decodeURIComponent(pathname.replace('/clips/', ''));
    const filePath = path.join(CLIPS_DIR, filename);
    if (!fs.existsSync(filePath)) return json(res, 404, { error: 'not found' });
    const stat = fs.statSync(filePath);
    const ext = path.extname(filename);
    const ct = ext === '.mp4' ? 'video/mp4' : 'video/x-msvideo';
    res.writeHead(200, {
      'Content-Type': ct,
      'Content-Length': stat.size,
      'Content-Disposition': `attachment; filename="${filename}"`,
      'Access-Control-Allow-Origin': '*',
    });
    fs.createReadStream(filePath).pipe(res);
    return;
  }

  // ── CLIPS: delete ─────────────────────────────────────────────────────────
  if (pathname.startsWith('/clips/') && req.method === 'DELETE') {
    if (!payload || payload.role !== 'admin') return json(res, 403, { error: 'admin required' });
    const filename = decodeURIComponent(pathname.replace('/clips/', ''));
    const filePath = path.join(CLIPS_DIR, filename);
    if (fs.existsSync(filePath)) fs.unlinkSync(filePath);
    return json(res, 200, { ok: true });
  }

  // ── DONORS LIST ───────────────────────────────────────────────────────────
  if (pathname === '/donors' && req.method === 'GET') {
    return json(res, 200, getDonorList());
  }

  // ── STATIC FILES ──────────────────────────────────────────────────────────
  if (pathname === '/' || pathname === '/index.html') {
    return serveFile(res, path.join(PUBLIC_DIR, 'index.html'), 'text/html');
  }
  if (pathname.endsWith('.js')) {
    return serveFile(res, path.join(PUBLIC_DIR, pathname), 'application/javascript');
  }
  if (pathname.endsWith('.css')) {
    return serveFile(res, path.join(PUBLIC_DIR, pathname), 'text/css');
  }

  res.writeHead(404); res.end('Not found');
});

// ─── WEBSOCKET SERVER ────────────────────────────────────────────────────────
const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://localhost');
  const pathname = url.pathname;
  const donorId = url.searchParams.get('donorId') || 'default';

  // ── DONOR command channel ──────────────────────────────────────────────────
  if (pathname === '/donor') {
    if (!donors.has(donorId)) donors.set(donorId, {});
    const donor = donors.get(donorId);
    donor.ws = ws;
    donor.torchOn = false;
    console.log(`[WS] Donor connected: ${donorId}`);

    ws.on('message', (data) => {
      // Donor can send audio chunks: { type: 'audio', data: base64 }
      try {
        const msg = JSON.parse(data);
        if (msg.type === 'audio') {
          // Relay audio to all observers watching this donor
          const obs = audioObservers.get(donorId);
          if (obs) {
            const payload = JSON.stringify({ type: 'audio', donorId, data: msg.data });
            for (const ows of obs) {
              if (ows.readyState === WebSocket.OPEN) ows.send(payload);
            }
          }
        }
      } catch {}
    });

    ws.on('close', () => {
      console.log(`[WS] Donor disconnected: ${donorId}`);
      stopRecording(donorId);
      const d = donors.get(donorId);
      if (d) d.ws = null;
    });
    return;
  }

  // ── OBSERVER audio channel ─────────────────────────────────────────────────
  if (pathname === '/observer/audio') {
    if (!audioObservers.has(donorId)) audioObservers.set(donorId, new Set());
    audioObservers.get(donorId).add(ws);
    console.log(`[WS] Observer audio connected to donor ${donorId}`);

    ws.on('message', (data) => {
      // Observer speaks → relay to donor
      const donor = donors.get(donorId);
      if (donor && donor.ws && donor.ws.readyState === WebSocket.OPEN) {
        try {
          const msg = JSON.parse(data);
          if (msg.type === 'audio') {
            donor.ws.send(JSON.stringify({ type: 'audio_from_observer', data: msg.data }));
          }
        } catch {}
      }
    });

    ws.on('close', () => {
      audioObservers.get(donorId)?.delete(ws);
      console.log(`[WS] Observer audio disconnected from donor ${donorId}`);
    });
    return;
  }

  ws.close(1008, 'Unknown path');
});

// ─── START ───────────────────────────────────────────────────────────────────
server.listen(PORT, () => {
  console.log(`\n🐕 Watchdog Server running on port ${PORT}`);
  console.log(`   Admin password: ${ADMIN_PASSWORD}`);
  console.log(`   Viewer password: ${process.env.VIEWER_PASSWORD || 'watch'}`);
  console.log(`   Web UI: http://localhost:${PORT}\n`);
});
