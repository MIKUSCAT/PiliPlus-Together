import { createServer } from 'node:http';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { WebSocket, WebSocketServer } from 'ws';
import { newCode, object, PROTOCOL_VERSION, ProtocolError, Room, ROOM_TTL_MS, text } from './room.js';

interface Binding { room: Room; memberId: string }
interface Peer { binding?: Binding; lastSeen: number; tokens: number; refillAt: number; authenticatedAt?: number }

export function createTogetherServer(options: { maxRooms?: number; now?: () => number } = {}) {
  const now = options.now ?? Date.now;
  const rooms = new Map<string, Room>();
  const peers = new Map<WebSocket, Peer>();
  const connections = new Map<string, WebSocket>();
  const maxRooms = options.maxRooms ?? 100;
  if (!Number.isInteger(maxRooms) || maxRooms < 1 || maxRooms > 10000) {
    throw new Error('MAX_ROOMS must be an integer between 1 and 10000');
  }
  const server = createServer((req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    if (req.url === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ status: 'ok', protocol: PROTOCOL_VERSION }));
    } else { res.writeHead(404); res.end('Not found'); }
  });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 16 * 1024, perMessageDeflate: false });
  server.on('upgrade', (request, socket, head) => {
    if (request.url !== '/ws' || peers.size >= maxRooms * 3) { socket.destroy(); return; }
    wss.handleUpgrade(request, socket, head, ws => wss.emit('connection', ws, request));
  });
  const send = (ws: WebSocket, payload: object) => {
    if (ws.readyState !== WebSocket.OPEN) return;
    if (ws.bufferedAmount > 256 * 1024) { ws.terminate(); return; }
    ws.send(JSON.stringify(payload));
  };
  const broadcast = (room: Room) => {
    const payload = { type: 'state', state: room.snapshot() };
    for (const id of room.members.keys()) {
      const ws = connections.get(id);
      if (ws) send(ws, payload);
    }
  };
  const detach = (ws: WebSocket) => {
    const peer = peers.get(ws);
    peers.delete(ws);
    if (peer?.binding && connections.get(peer.binding.memberId) === ws) {
      const { room, memberId } = peer.binding;
      connections.delete(memberId);
      room.disconnect(memberId);
      broadcast(room);
    }
  };

  wss.on('connection', ws => {
    const peer: Peer = { lastSeen: now(), tokens: 40, refillAt: now() };
    peers.set(ws, peer);
    ws.on('error', () => ws.terminate());
    ws.on('close', () => detach(ws));
    ws.on('pong', () => { peer.lastSeen = now(); });
    ws.on('message', (raw, isBinary) => {
      let requestId: unknown;
      try {
        peer.lastSeen = now();
        peer.tokens = Math.min(40, peer.tokens + (now() - peer.refillAt) / 1000 * 8);
        peer.refillAt = now();
        if (--peer.tokens < 0) throw new ProtocolError('rate_limited', '操作太快了，请稍后再试');
        if (isBinary) throw new ProtocolError('invalid_message', '消息格式不正确');
        const input = object(JSON.parse(raw.toString()));
        requestId = input.requestId;
        if (requestId != null) text(requestId, 100, '消息编号');
        if (input.type === 'ping') {
          send(ws, { type: 'pong', clientTimeMs: input.clientTimeMs, serverTimeMs: now() });
          return;
        }
        if (['create', 'join', 'resume'].includes(String(input.type))) {
          if (peer.binding) throw new ProtocolError('already_joined', '已经加入房间');
          if (input.protocol !== PROTOCOL_VERSION) throw new ProtocolError('version_mismatch', '客户端和房间服务版本不同，请更新后重试');
          let room: Room;
          let memberId: string;
          let resumeToken: string | undefined;
          if (input.type === 'create') {
            if (rooms.size >= maxRooms) throw new ProtocolError('server_full', '房间已满，请稍后再试');
            let code = newCode();
            while (rooms.has(code)) code = newCode();
            room = new Room(code, now);
            const added = room.addMember(input.name);
            memberId = added.member.id; resumeToken = added.resumeToken;
            rooms.set(code, room);
          } else {
            const code = text(input.roomCode, 12, '房间码').replace(/-/g, '').toUpperCase();
            const found = rooms.get(code);
            if (!found) throw new ProtocolError('room_not_found', '房间已结束或房间码不正确');
            room = found;
            if (input.type === 'resume') {
              memberId = room.resume(input.memberId, input.resumeToken).id;
              resumeToken = input.resumeToken as string;
              const previous = connections.get(memberId);
              // Replace first. The old close handler must not disconnect this session.
              connections.set(memberId, ws);
              if (previous && previous !== ws) previous.close(4001, 'Session resumed');
            } else {
              const added = room.addMember(input.name);
              memberId = added.member.id; resumeToken = added.resumeToken;
            }
          }
          peer.binding = { room, memberId };
          peer.authenticatedAt = now();
          connections.set(memberId, ws);
          send(ws, { type: 'welcome', requestId, session: { roomCode: room.code, memberId, resumeToken }, state: room.snapshot() });
          broadcast(room);
          return;
        }
        if (!peer.binding) throw new ProtocolError('not_joined', '请先加入房间');
        const { room, memberId } = peer.binding;
        if (connections.get(memberId) !== ws) throw new ProtocolError('invalid_session', '房间已在另一连接恢复');
        switch (input.type) {
          case 'command':
            if (room.command(memberId, input)) broadcast(room);
            send(ws, { type: 'ack', requestId, state: room.snapshot() });
            break;
          case 'status': if (room.status(memberId, input)) broadcast(room); break;
          case 'sync': send(ws, { type: 'state', state: room.snapshot() }); break;
          case 'leave':
            connections.delete(memberId);
            peer.binding = undefined;
            room.leave(memberId);
            send(ws, { type: 'left', requestId });
            broadcast(room);
            if (!room.members.size) rooms.delete(room.code);
            ws.close(1000, 'Left room');
            break;
          default: throw new ProtocolError('invalid_message', '无法识别这条消息');
        }
      } catch (error) {
        const failure = error instanceof ProtocolError ? error : new ProtocolError('invalid_message', '消息格式不正确');
        send(ws, { type: 'error', ...(requestId == null ? {} : { requestId }), code: failure.code, message: failure.message,
          ...(peer.binding ? { state: peer.binding.room.snapshot() } : {}) });
      }
    });
  });

  const timer = setInterval(() => {
    for (const [ws, peer] of peers) {
      if (now() - peer.lastSeen > 20_000 || (!peer.binding && now() - peer.refillAt > 10_000)) {
        ws.terminate(); detach(ws);
      } else if (ws.readyState === WebSocket.OPEN) { ws.ping(); }
    }
    for (const [code, room] of rooms) {
      if (![...room.members.values()].some(m => m.connected) && now() - room.lastActivityMs > ROOM_TTL_MS) rooms.delete(code);
    }
  }, 5000);
  timer.unref();
  return {
    server, rooms,
    async close(): Promise<void> {
      clearInterval(timer);
      for (const ws of peers.keys()) ws.terminate();
      await new Promise<void>(resolve => wss.close(() => resolve()));
      await new Promise<void>(resolve => server.close(() => resolve()));
    },
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const app = createTogetherServer({ maxRooms: Number(process.env.MAX_ROOMS ?? 100) });
  const port = Number(process.env.PORT ?? 3000);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('PORT must be an integer between 1 and 65535');
  }
  app.server.listen(port, '0.0.0.0', () => console.log(`PiliPlus Together listening on :${port}`));
  const shutdown = () => { void app.close().then(() => process.exit(0)); };
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
}
