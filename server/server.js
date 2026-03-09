'use strict';

const http = require('http');
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
// rooms: Map<roomId, { pin, donorWs, lastFrame, frameTime, torchOn, createdAt }>
const rooms = new Map();
const mjpegClients = new Map();    // roomId → Set<res>
const audioObservers = new Map();  // roomId → Set<ws>
const activeRecordings = new Map();// roomId → { path, filename, stream, startTime }

// ─── SIMPLE JWT ─────────────────────────────────────────────────────────────
function signToken(payload) {
  const h = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const b = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const s = crypto.createHmac('sha256', JWT_SECRET).update(`${h}.${b}`).digest('base64url');
  return `${h}.${b}.${s}`;
}
function verifyToken(token) {
  try {
    const [h, b, s] = (token || '').split('.');
    const expected = crypto.createHmac('sha256', JWT_SECRET).update(`${h}.${b}`).digest('base64url');
    if (s !== expected) return null;
    return JSON.parse(Buffer.from(b, 'base64url').toString());
  } catch { return null; }
}
function getToken(req) {
  const auth = req.headers['authorization'] || '';
  if (auth.startsWith('Bearer ')) return auth.slice(7);
  return new URL(req.url, 'http://x').searchParams.get('token');
}

// ─── RECORDING ──────────────────────────────────────────────────────────────
function startRecording(roomId) {
  if (activeRecordings.has(roomId)) return;
  const ts = new Date().toISOString().replace(/[:.]/g, '-');
  const filename = `clip_${roomId}_${ts}.mjpeg`;
  const filePath = path.join(CLIPS_DIR, filename);
  const stream = fs.createWriteStream(filePath);
  activeRecordings.set(roomId, { path: filePath, filename, stream, startTime: Date.now() });
  console.log(`[REC] ▶ ${filename}`);
}
function writeFrame(roomId, jpeg) {
  const rec = activeRecordings.get(roomId);
  if (!rec?.stream.writable) return;
  rec.stream.write(`--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.length}\r\n\r\n`);
  rec.stream.write(jpeg);
  rec.stream.write('\r\n');
}
function stopRecording(roomId) {
  const rec = activeRecordings.get(roomId);
  if (!rec) return;
  rec.stream.end();
  activeRecordings.delete(roomId);
  const dur = Math.round((Date.now() - rec.startTime) / 1000);
  console.log(`[REC] ■ ${rec.filename} (${dur}с)`);
}

// ─── MJPEG BROADCAST ────────────────────────────────────────────────────────
function broadcast(roomId, jpeg) {
  const clients = mjpegClients.get(roomId);
  if (!clients?.size) return;
  const header = `--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.length}\r\n\r\n`;
  for (const res of clients) {
    try { res.write(header); res.write(jpeg); res.write('\r\n'); }
    catch { clients.delete(res); }
  }
}

// ─── HELPERS ─────────────────────────────────────────────────────────────────
function readBody(req) {
  return new Promise((res, rej) => {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => res(Buffer.concat(chunks)));
    req.on('error', rej);
  });
}
function json(res, status, data) {
  res.writeHead(status, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
  res.end(JSON.stringify(data));
}
function roomInfo(id, r) {
  return {
    id,
    donorConnected: r.donorWs?.readyState === WebSocket.OPEN,
    torchOn: r.torchOn || false,
    recording: activeRecordings.has(id),
    hasFrame: !!r.lastFrame,
    lastFrameAge: r.frameTime ? Date.now() - r.frameTime : null,
    observers: (mjpegClients.get(id) || new Set()).size,
    createdAt: r.createdAt,
  };
}
function serveFile(res, filePath, ct) {
  try { res.writeHead(200, { 'Content-Type': ct }); res.end(fs.readFileSync(filePath)); }
  catch { res.writeHead(404); res.end('Not found'); }
}

// ─── HTTP ─────────────────────────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET,POST,DELETE,OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type,Authorization',
    });
    return res.end();
  }

  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  const roomId = url.searchParams.get('roomId') || '';

  // ── Админ логин ──────────────────────────────────────────────────────────
  if (p === '/auth/admin' && req.method === 'POST') {
    const { password } = JSON.parse((await readBody(req)).toString() || '{}');
    if (password === ADMIN_PASSWORD)
      return json(res, 200, { token: signToken({ role: 'admin' }), role: 'admin' });
    return json(res, 401, { error: 'Неверный пароль' });
  }

  // ── Донор: создать комнату ────────────────────────────────────────────────
  if (p === '/room/create' && req.method === 'POST') {
    const body = JSON.parse((await readBody(req)).toString() || '{}');
    const id = body.roomId?.trim();
    const pin = body.pin?.trim();
    if (!id || !pin) return json(res, 400, { error: 'roomId и pin обязательны' });
    if (id.length < 2 || id.length > 20) return json(res, 400, { error: 'roomId: 2-20 символов' });
    if (pin.length < 4 || pin.length > 12) return json(res, 400, { error: 'pin: 4-12 символов' });
    if (!/^[a-zA-Z0-9_-]+$/.test(id)) return json(res, 400, { error: 'roomId: только буквы, цифры, - _' });

    // Если комната уже есть и донор онлайн — отказ
    if (rooms.has(id)) {
      const r = rooms.get(id);
      if (r.donorWs?.readyState === WebSocket.OPEN)
        return json(res, 409, { error: 'Комната занята другим донором' });
      // Донор оффлайн — обновляем пин и пересоздаём
      r.pin = pin;
      r.createdAt = Date.now();
    } else {
      rooms.set(id, { pin, donorWs: null, lastFrame: null, frameTime: null, torchOn: false, createdAt: Date.now() });
    }
    const token = signToken({ role: 'donor', roomId: id });
    console.log(`[ROOM] Создана: ${id}`);
    return json(res, 200, { ok: true, token, roomId: id });
  }

  // ── Наблюдатель: войти в комнату ─────────────────────────────────────────
  if (p === '/room/join' && req.method === 'POST') {
    const { roomId: id, pin } = JSON.parse((await readBody(req)).toString() || '{}');
    if (!id || !pin) return json(res, 400, { error: 'roomId и pin обязательны' });
    const room = rooms.get(id);
    if (!room) return json(res, 404, { error: 'Комната не найдена' });
    if (room.pin !== pin) return json(res, 403, { error: 'Неверный пинкод' });
    const token = signToken({ role: 'viewer', roomId: id });
    return json(res, 200, { ok: true, token, roomId: id });
  }

  // ── Донор: отправить кадр ─────────────────────────────────────────────────
  if (p === '/stream/frame' && req.method === 'POST') {
    if (!roomId || !rooms.has(roomId)) return json(res, 404, { error: 'room not found' });
    const jpeg = await readBody(req);
    const r = rooms.get(roomId);
    r.lastFrame = jpeg;
    r.frameTime = Date.now();
    if (!activeRecordings.has(roomId)) startRecording(roomId);
    writeFrame(roomId, jpeg);
    broadcast(roomId, jpeg);
    return json(res, 200, { ok: true });
  }

  // ── Наблюдатель: MJPEG стрим ──────────────────────────────────────────────
  if (p === '/stream' && req.method === 'GET') {
    const tok = verifyToken(getToken(req));
    if (!tok || !['viewer', 'donor', 'admin'].includes(tok.role)) {
      res.writeHead(403); return res.end('Forbidden');
    }
    const rid = tok.roomId || roomId;
    if (!rooms.has(rid)) { res.writeHead(404); return res.end('Room not found'); }

    if (!mjpegClients.has(rid)) mjpegClients.set(rid, new Set());
    res.writeHead(200, {
      'Content-Type': 'multipart/x-mixed-replace; boundary=frame',
      'Cache-Control': 'no-cache', 'Connection': 'keep-alive',
      'Access-Control-Allow-Origin': '*',
    });
    mjpegClients.get(rid).add(res);
    const last = rooms.get(rid)?.lastFrame;
    if (last) {
      res.write(`--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${last.length}\r\n\r\n`);
      res.write(last); res.write('\r\n');
    }
    req.on('close', () => mjpegClients.get(rid)?.delete(res));
    return;
  }

  // ── Фонарик ──────────────────────────────────────────────────────────────
  if (p.startsWith('/torch/') && req.method === 'POST') {
    const tok = verifyToken(getToken(req));
    if (!tok) return json(res, 401, { error: 'unauthorized' });
    const rid = tok.roomId || roomId;
    const state = p.includes('/on') ? 'on' : 'off';
    const r = rooms.get(rid);
    if (r?.donorWs?.readyState === WebSocket.OPEN) {
      r.donorWs.send(JSON.stringify({ cmd: 'torch', state }));
      r.torchOn = state === 'on';
    }
    return json(res, 200, { ok: true, torch: state });
  }

  // ── Стоп/старт стрима ─────────────────────────────────────────────────────
  if (p === '/stream/stop' && req.method === 'POST') {
    const tok = verifyToken(getToken(req));
    if (!tok) return json(res, 401, { error: 'unauthorized' });
    const rid = tok.roomId || roomId;
    rooms.get(rid)?.donorWs?.send(JSON.stringify({ cmd: 'stopStream' }));
    stopRecording(rid);
    return json(res, 200, { ok: true });
  }
  if (p === '/stream/start' && req.method === 'POST') {
    const tok = verifyToken(getToken(req));
    if (!tok) return json(res, 401, { error: 'unauthorized' });
    const rid = tok.roomId || roomId;
    rooms.get(rid)?.donorWs?.send(JSON.stringify({ cmd: 'startStream' }));
    return json(res, 200, { ok: true });
  }

  // ── Инфо о комнате ────────────────────────────────────────────────────────
  if (p === '/room/info' && req.method === 'GET') {
    const tok = verifyToken(getToken(req));
    if (!tok) return json(res, 401, { error: 'unauthorized' });
    const rid = tok.roomId || roomId;
    const r = rooms.get(rid);
    if (!r) return json(res, 404, { error: 'not found' });
    return json(res, 200, roomInfo(rid, r));
  }

  // ── Клипы ─────────────────────────────────────────────────────────────────
  if (p === '/clips' && req.method === 'GET') {
    const tok = verifyToken(getToken(req));
    if (!tok) return json(res, 401, { error: 'unauthorized' });
    const rid = tok.role === 'admin' ? null : tok.roomId;
    const files = fs.readdirSync(CLIPS_DIR)
      .filter(f => rid ? f.includes(`_${rid}_`) : true)
      .map(f => { const s = fs.statSync(path.join(CLIPS_DIR, f)); return { filename: f, size: s.size, created: s.birthtime }; })
      .sort((a, b) => new Date(b.created) - new Date(a.created));
    return json(res, 200, files);
  }
  if (p.startsWith('/clips/') && req.method === 'GET') {
    const tok = verifyToken(getToken(req));
    if (!tok) return json(res, 401, { error: 'unauthorized' });
    const file = path.join(CLIPS_DIR, decodeURIComponent(p.replace('/clips/', '')));
    if (!fs.existsSync(file)) return json(res, 404, { error: 'not found' });
    const stat = fs.statSync(file);
    res.writeHead(200, {
      'Content-Type': 'video/x-msvideo',
      'Content-Length': stat.size,
      'Content-Disposition': `attachment; filename="${path.basename(file)}"`,
      'Access-Control-Allow-Origin': '*',
    });
    return fs.createReadStream(file).pipe(res);
  }
  if (p.startsWith('/clips/') && req.method === 'DELETE') {
    const tok = verifyToken(getToken(req));
    if (tok?.role !== 'admin') return json(res, 403, { error: 'admin only' });
    const file = path.join(CLIPS_DIR, decodeURIComponent(p.replace('/clips/', '')));
    if (fs.existsSync(file)) fs.unlinkSync(file);
    return json(res, 200, { ok: true });
  }

  // ── Статус (admin) ────────────────────────────────────────────────────────
  if (p === '/status' && req.method === 'GET') {
    const tok = verifyToken(getToken(req));
    if (tok?.role !== 'admin') return json(res, 403, { error: 'admin only' });
    return json(res, 200, {
      ok: true,
      rooms: [...rooms.entries()].map(([id, r]) => roomInfo(id, r)),
      clips: fs.readdirSync(CLIPS_DIR).length,
      uptime: process.uptime(),
    });
  }

  // ── Статические файлы ─────────────────────────────────────────────────────
  if (p === '/' || p === '/index.html') return serveFile(res, path.join(PUBLIC_DIR, 'index.html'), 'text/html');
  if (p === '/admin' || p === '/admin.html') return serveFile(res, path.join(PUBLIC_DIR, 'admin.html'), 'text/html');

  res.writeHead(404); res.end('Not found');
});

// ─── WEBSOCKET ────────────────────────────────────────────────────────────────
const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://x');
  const tok = verifyToken(url.searchParams.get('token'));

  // Донор канал команд
  if (url.pathname === '/donor') {
    if (!tok || tok.role !== 'donor') { ws.close(1008, 'unauthorized'); return; }
    const roomId = tok.roomId;
    if (!rooms.has(roomId)) { ws.close(1008, 'room not found'); return; }
    rooms.get(roomId).donorWs = ws;
    rooms.get(roomId).torchOn = false;
    console.log(`[WS] Донор подключён: ${roomId}`);

    ws.on('message', data => {
      try {
        const msg = JSON.parse(data);
        if (msg.type === 'audio') {
          const payload = JSON.stringify({ type: 'audio', data: msg.data });
          audioObservers.get(roomId)?.forEach(ows => {
            if (ows.readyState === WebSocket.OPEN) ows.send(payload);
          });
        }
      } catch {}
    });
    ws.on('close', () => {
      console.log(`[WS] Донор отключён: ${roomId}`);
      stopRecording(roomId);
      if (rooms.get(roomId)) rooms.get(roomId).donorWs = null;
    });
    return;
  }

  // Наблюдатель аудиоканал
  if (url.pathname === '/observer/audio') {
    if (!tok || !['viewer', 'admin', 'donor'].includes(tok.role)) { ws.close(1008, 'unauthorized'); return; }
    const roomId = tok.roomId;
    if (!rooms.has(roomId)) { ws.close(1008, 'room not found'); return; }
    if (!audioObservers.has(roomId)) audioObservers.set(roomId, new Set());
    audioObservers.get(roomId).add(ws);

    ws.on('message', data => {
      try {
        const msg = JSON.parse(data);
        if (msg.type === 'audio') {
          rooms.get(roomId)?.donorWs?.send(JSON.stringify({ type: 'audio_from_observer', data: msg.data }));
        }
      } catch {}
    });
    ws.on('close', () => audioObservers.get(roomId)?.delete(ws));
    return;
  }

  // Донор: бинарный WebSocket стрим кадров (низкая задержка)
  if (url.pathname === '/stream/frames') {
    if (!tok || tok.role !== 'donor') { ws.close(1008, 'unauthorized'); return; }
    const roomId = tok.roomId;
    if (!rooms.has(roomId)) { ws.close(1008, 'room not found'); return; }
    console.log(`[WS] Бинарный стрим: ${roomId}`);

    ws.on('message', (data, isBinary) => {
      if (!isBinary) return;
      const jpeg = Buffer.isBuffer(data) ? data : Buffer.from(data);
      if (!jpeg.length) return;
      const r = rooms.get(roomId);
      if (!r) return;
      r.lastFrame = jpeg;
      r.frameTime = Date.now();
      if (!activeRecordings.has(roomId)) startRecording(roomId);
      writeFrame(roomId, jpeg);
      broadcast(roomId, jpeg);
    });

    ws.on('close', () => {
      console.log(`[WS] Бинарный стрим закрыт: ${roomId}`);
      stopRecording(roomId);
    });
    ws.on('error', () => stopRecording(roomId));
    return;
  }

  ws.close(1008, 'unknown path');
});

server.listen(PORT, () => {
  console.log(`\n🐕  Watchdog Server v2.1`);
  console.log(`    http://localhost:${PORT}`);
  console.log(`    Admin: ${ADMIN_PASSWORD}\n`);
});
