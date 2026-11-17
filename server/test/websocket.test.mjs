import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { WebSocket } from 'ws';
import { createTogetherServer } from '../dist/server.js';

async function connect(url) {
  const ws = new WebSocket(url);
  const messages = [];
  const pending = new Set();
  ws.on('message', raw => {
    const message = JSON.parse(raw);
    messages.push(message);
    for (const waiter of pending) if (waiter.filter(message)) {
      pending.delete(waiter); clearTimeout(waiter.timer); waiter.resolve(message);
    }
  });
  await once(ws, 'open');
  let serial = 0;
  const wait = filter => new Promise((resolve, reject) => {
    const waiter = { filter, resolve, timer: setTimeout(() => { pending.delete(waiter); reject(new Error('Response timed out')); }, 2000) };
    pending.add(waiter);
  });
  return {
    ws, messages, wait,
    send: message => ws.send(JSON.stringify(message)),
    async request(message) {
      const requestId = `test-${++serial}`;
      const response = wait(m => m.requestId === requestId && ['welcome', 'ack', 'error', 'left'].includes(m.type));
      ws.send(JSON.stringify({ ...message, requestId }));
      return response;
    },
  };
}

test('two real WebSocket clients create, join, synchronize, chat and resume', async t => {
  const app = createTogetherServer();
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening');
  const port = app.server.address().port;
  t.after(() => app.close());
  const health = await fetch(`http://127.0.0.1:${port}/healthz`).then(r => r.json());
  assert.equal(health.protocol, 1);
  const url = `ws://127.0.0.1:${port}/ws`;
  const a = await connect(url);
  const b = await connect(url);
  const stranger = await connect(url);
  const created = await a.request({ type: 'create', protocol: 1, name: 'A' });
  assert.equal(created.type, 'welcome');
  const joined = await b.request({ type: 'join', protocol: 1, roomCode: created.session.roomCode, name: 'B' });
  assert.equal(joined.state.members.length, 2);
  const refused = await stranger.request({ type: 'join', protocol: 1, roomCode: created.session.roomCode, name: 'C' });
  assert.equal(refused.code, 'room_full');
  const unauthorized = await stranger.request({ type: 'command', action: 'pause', mediaEpoch: 0, memberId: created.session.memberId });
  assert.equal(unauthorized.code, 'not_joined');
  const selected = await a.request({ type: 'command', action: 'select', mediaEpoch: 0,
    video: { kind: 'ugc', bvid: 'BV1xx411c7mD', cid: 1, title: '测试', durationMs: 120000 } });
  const epoch = selected.state.mediaEpoch;
  const playing = a.wait(m => m.type === 'state' && m.state.playing);
  a.send({ type: 'status', mediaEpoch: epoch, ready: true, durationMs: 120000 });
  b.send({ type: 'status', mediaEpoch: epoch, ready: true, durationMs: 120000 });
  await playing;
  const moved = await b.request({ type: 'command', action: 'seek', mediaEpoch: epoch, positionMs: 25000 });
  assert.equal(moved.state.positionMs, 25000);
  const paused = await a.request({ type: 'command', action: 'pause', mediaEpoch: epoch });
  assert.equal(paused.state.playing, false);
  const chatted = await b.request({ type: 'command', action: 'chat', mediaEpoch: epoch, text: '等我一下' });
  assert.equal(chatted.state.messages.at(-1).text, '等我一下');
  const replacement = await connect(url);
  const resumed = await replacement.request({ type: 'resume', protocol: 1, ...joined.session });
  assert.equal(resumed.type, 'welcome');
  await new Promise(resolve => setTimeout(resolve, 40));
  const state = app.rooms.get(created.session.roomCode).snapshot();
  assert.equal(state.members.find(m => m.id === joined.session.memberId).connected, true);
  assert.equal(state.desiredPlaying, false);
  assert.equal(JSON.stringify(state).includes(joined.session.resumeToken), false);
});

test('version mismatch and malformed packets return actionable errors', async t => {
  const app = createTogetherServer();
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening');
  t.after(() => app.close());
  const client = await connect(`ws://127.0.0.1:${app.server.address().port}/ws`);
  const result = await client.request({ type: 'create', protocol: 999, name: 'A' });
  assert.equal(result.code, 'version_mismatch');
  const error = client.wait(m => m.type === 'error');
  client.ws.send('not json');
  assert.equal((await error).code, 'invalid_message');
});
