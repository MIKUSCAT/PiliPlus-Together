import test from 'node:test';
import assert from 'node:assert/strict';
import { Room, ProtocolError } from '../dist/room.js';

const video = { kind: 'ugc', bvid: 'BV1xx411c7mD', cid: 12345, title: '一起看测试视频', cover: '', durationMs: 120_000 };

function fixture({ solo = false } = {}) {
  let time = 100_000;
  let serial = 0;
  const room = new Room('ABCDEFGH', () => time);
  const a = room.addMember('小明');
  const b = solo ? null : room.addMember('小雨');
  const command = (who, action, values = {}) => room.command(who.member.id, {
    requestId: `request-${++serial}`, action, mediaEpoch: room.mediaEpoch, ...values,
  });
  const status = (who, values = {}) => room.status(who.member.id, {
    mediaEpoch: room.mediaEpoch, ready: true, durationMs: video.durationMs, ...values,
  });
  const start = () => { command(a, 'select', { video }); status(a); if (b) status(b); };
  return { room, a, b, command, status, start, advance: ms => { time += ms; } };
}

test('private room reserves exactly two identities and never broadcasts credentials', () => {
  const { room } = fixture();
  assert.throws(() => room.addMember('第三个人'), e => e.code === 'room_full');
  const snapshot = JSON.stringify(room.snapshot());
  assert.equal(snapshot.includes('tokenHash'), false);
  assert.equal(snapshot.includes('resumeToken'), false);
  assert.equal(snapshot.includes('commands'), false);
});

test('both participants load before the room timeline advances', () => {
  const { room, a, b, command, status, advance } = fixture();
  command(a, 'select', { video, positionMs: 30_000 });
  status(a);
  advance(5000);
  assert.equal(room.position(), 30_000);
  assert.equal(room.playing, false);
  status(b);
  advance(2000);
  assert.equal(room.position(), 32_000);
  assert.equal(room.playing, true);
});

test('a lone member can play, pause, seek and resume before anyone joins', () => {
  const { room, a, command, status, advance } = fixture({ solo: true });
  command(a, 'select', { video, positionMs: 30_000 });
  advance(5000);
  assert.equal(room.position(), 30_000);
  assert.equal(room.playing, false);
  status(a);
  advance(2000);
  assert.equal(room.position(), 32_000);
  assert.equal(room.playing, true);
  command(a, 'pause');
  advance(3000);
  assert.equal(room.position(), 32_000);
  command(a, 'seek', { positionMs: 60_000 });
  advance(1000);
  assert.equal(room.position(), 60_000);
  assert.equal(room.playing, false);
  command(a, 'play');
  advance(1000);
  assert.equal(room.position(), 61_000);
});

test('a joining member loads at the solo position before both continue', () => {
  const { room, status, start, advance } = fixture({ solo: true });
  start(); advance(8000);
  const b = room.addMember('小雨');
  advance(5000);
  assert.equal(room.position(), 8000);
  assert.equal(room.playing, false);
  assert.equal(room.desiredPlaying, true);
  status(b); advance(2000);
  assert.equal(room.position(), 10_000);
  assert.equal(room.playing, true);
});

test('a manual pause during buffering is preserved after buffering ends', () => {
  const { room, a, b, command, status, start, advance } = fixture();
  start(); advance(10_000);
  status(b, { buffering: true });
  advance(8000);
  assert.equal(room.position(), 10_000);
  command(a, 'pause');
  status(b, { buffering: false });
  advance(3000);
  assert.equal(room.playing, false);
  assert.equal(room.position(), 10_000);
  command(b, 'play'); advance(1000);
  assert.equal(room.position(), 11_000);
});

test('either member can seek or change rate, with a single ordered timeline', () => {
  const { room, a, b, command, start, advance } = fixture();
  start(); advance(2000);
  command(b, 'rate', { rate: 2 }); advance(3000);
  assert.equal(room.position(), 8000);
  command(a, 'seek', { positionMs: 60_000 });
  command(b, 'seek', { positionMs: 20_000 }); advance(1000);
  assert.equal(room.position(), 22_000);
});

test('late messages from an old video cannot seek the new one', () => {
  const { room, a, b, command, start } = fixture();
  start();
  const oldEpoch = room.mediaEpoch;
  command(a, 'select', { video: { ...video, cid: 98765 } });
  const revision = room.revision;
  assert.throws(() => command(b, 'seek', { mediaEpoch: oldEpoch, positionMs: 99_000 }), e => e.code === 'stale_media');
  assert.equal(room.position(), 0);
  assert.equal(room.revision, revision);
});

test('retrying an acknowledged request is idempotent, including a video switch', () => {
  const { room, a, start, advance } = fixture();
  start();
  const message = { requestId: 'same-id', action: 'select', mediaEpoch: room.mediaEpoch, video: { ...video, cid: 55 } };
  assert.equal(room.command(a.member.id, message), true);
  const epoch = room.mediaEpoch;
  advance(1000);
  assert.equal(room.command(a.member.id, message), false);
  assert.equal(room.mediaEpoch, epoch);
});

test('reconnection requires the session token, preserves position and waits for readiness', () => {
  const { room, a, b, status, start, advance } = fixture();
  start(); advance(4000);
  room.disconnect(b.member.id); advance(12_000);
  assert.equal(room.playing, false);
  assert.equal(room.position(), 4000);
  assert.throws(() => room.resume(b.member.id, a.resumeToken), e => e.code === 'invalid_session');
  room.resume(b.member.id, b.resumeToken);
  assert.equal(room.playing, false);
  status(b); advance(1000);
  assert.equal(room.position(), 5000);
});

test('suspension holds playback without changing explicit play intent', () => {
  const { room, b, status, start, advance } = fixture();
  start(); advance(1000);
  status(b, { suspended: true }); advance(10_000);
  assert.equal(room.position(), 1000);
  assert.equal(room.desiredPlaying, true);
  status(b, { suspended: false }); advance(1000);
  assert.equal(room.position(), 2000);
});

test('a trial-length or different cut cannot silently join full-length playback', () => {
  const { room, b, status, start } = fixture();
  start(); status(b, { durationMs: 10_000 });
  assert.equal(room.playing, false);
  assert.match(room.members.get(b.member.id).error, /时长不同/);
});

test('invalid numeric values are rejected without changing the timeline', () => {
  const { room, a, command, start } = fixture();
  start(); const revision = room.revision;
  for (const rate of [NaN, Infinity, -1, 100, '2']) {
    assert.throws(() => command(a, 'rate', { rate }), ProtocolError);
  }
  assert.throws(() => command(a, 'seek', { positionMs: 130_000 }), ProtocolError);
  assert.equal(room.revision, revision);
});

test('a video selected before loading learns duration from the first ready player', () => {
  const { room, a, b, command, status } = fixture();
  command(a, 'select', { video: { kind: 'ugc', bvid: 'BV1xx411c7mD', cid: 1, title: '测试', durationMs: 0 } });
  status(a, { durationMs: 120000 });
  assert.equal(room.video.durationMs, 120000);
  status(b, { durationMs: 10000 });
  assert.equal(room.playing, false);
  assert.match(room.members.get(b.member.id).error, /时长不同/);
});

test('host departure transfers automatic advancement and keeps the remaining member playing', () => {
  const { room, a, b, start, advance } = fixture();
  start(); advance(3000);
  room.leave(a.member.id); advance(2000);
  assert.equal(room.hostId, b.member.id);
  assert.equal(room.playing, true);
  assert.equal(room.position(), 5000);
  assert.equal(room.members.size, 1);
  room.leave(b.member.id);
  assert.equal(room.playing, false);
});

test('a member leaving during buffering preserves the remaining member manual pause', () => {
  const { room, a, b, command, status, start, advance } = fixture();
  start(); advance(3000);
  status(b, { buffering: true });
  command(a, 'pause');
  room.leave(b.member.id); advance(5000);
  assert.equal(room.playing, false);
  assert.equal(room.desiredPlaying, false);
  assert.equal(room.position(), 3000);
  command(a, 'play'); advance(1000);
  assert.equal(room.position(), 4000);
});

test('host disconnect transfers automatic advancement without resuming playback', () => {
  const { room, a, b, start } = fixture();
  start(); room.disconnect(a.member.id);
  assert.equal(room.hostId, b.member.id);
  assert.equal(room.playing, false);
  room.resume(a.member.id, a.resumeToken);
  assert.equal(room.hostId, b.member.id);
  assert.equal(room.playing, false);
});

test('chat is bounded and remains usable before selecting a video', () => {
  const { room, a, command } = fixture();
  for (let i = 0; i < 55; i++) command(a, 'chat', { text: `消息 ${i}` });
  assert.equal(room.messages.length, 50);
  assert.equal(room.messages[0].text, '消息 5');
  assert.throws(() => command(a, 'chat', { text: 'x'.repeat(501) }), ProtocolError);
});
