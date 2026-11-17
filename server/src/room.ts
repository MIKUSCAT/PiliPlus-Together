import { createHash, randomBytes, randomInt, timingSafeEqual } from 'node:crypto';

export const PROTOCOL_VERSION = 1;
export const ROOM_CAPACITY = 2;
export const ROOM_TTL_MS = 30 * 60_000;

export class ProtocolError extends Error {
  constructor(public readonly code: string, message: string) { super(message); }
}

export interface Video {
  kind: 'ugc' | 'pgc';
  bvid: string;
  cid: number;
  epId?: number;
  seasonId?: number;
  pgcType?: number;
  title: string;
  cover: string;
  durationMs: number;
}

export interface Member {
  id: string;
  name: string;
  connected: boolean;
  ready: boolean;
  buffering: boolean;
  suspended: boolean;
  error: string | null;
  durationMs: number;
  tokenHash: Buffer;
  commands: Set<string>;
}

export interface ChatMessage {
  id: string;
  memberId: string;
  name: string;
  text: string;
  sentAtMs: number;
}

export function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new ProtocolError('invalid_message', '消息格式不正确');
  }
  return value as Record<string, unknown>;
}

export function text(value: unknown, max: number, label = '内容'): string {
  if (typeof value !== 'string' || !value.trim() || value.trim().length > max) {
    throw new ProtocolError('invalid_message', `${label}不能为空，且不能超过 ${max} 个字符`);
  }
  return value.trim();
}

function number(value: unknown, min: number, max: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max) {
    throw new ProtocolError('invalid_message', '播放参数超出有效范围');
  }
  return value;
}

function positiveId(value: unknown): number {
  const result = number(value, 1, Number.MAX_SAFE_INTEGER);
  if (!Number.isInteger(result)) throw new ProtocolError('invalid_message', '视频编号无效');
  return result;
}

export function parseVideo(value: unknown): Video {
  const item = object(value);
  const bvid = text(item.bvid, 12, 'BV 号');
  if (!/^BV[a-zA-Z0-9]{10}$/.test(bvid) || !['ugc', 'pgc'].includes(String(item.kind))) {
    throw new ProtocolError('unsupported_video', '请使用普通视频或番剧的一起看入口');
  }
  return {
    kind: item.kind as Video['kind'],
    bvid,
    cid: positiveId(item.cid),
    ...(item.kind === 'pgc' ? { epId: positiveId(item.epId) } : {}),
    ...(item.seasonId == null ? {} : { seasonId: positiveId(item.seasonId) }),
    ...(item.pgcType == null ? {} : { pgcType: positiveId(item.pgcType) }),
    title: text(item.title, 200, '视频标题'),
    cover: typeof item.cover === 'string' && /^https:\/\//.test(item.cover)
      ? item.cover.slice(0, 2048) : '',
    durationMs: number(item.durationMs ?? 0, 0, 7 * 24 * 3600_000),
  };
}

const tokenHash = (token: string): Buffer => createHash('sha256').update(token).digest();

export function newCode(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return Array.from({ length: 8 }, () => alphabet[randomInt(alphabet.length)]).join('');
}

export class Room {
  readonly members = new Map<string, Member>();
  readonly messages: ChatMessage[] = [];
  video: Video | null = null;
  mediaEpoch = 0;
  revision = 0;
  hostId = '';
  desiredPlaying = false;
  playing = false;
  positionMs = 0;
  rate = 1;
  updatedAtMs: number;
  updatedBy: string | null = null;
  lastActivityMs: number;
  lastAction = 'created';

  constructor(readonly code: string, private readonly now: () => number = Date.now) {
    this.updatedAtMs = this.lastActivityMs = now();
  }

  position(at = this.now()): number {
    const current = this.positionMs + (this.playing ? Math.max(0, at - this.updatedAtMs) * this.rate : 0);
    return Math.round(Math.max(0, this.video?.durationMs ? Math.min(current, this.video.durationMs) : current));
  }

  private freeze(): void {
    this.positionMs = this.position();
    this.updatedAtMs = this.now();
  }

  private commit(action: string, actor: string | null = null): void {
    this.playing = !!this.video && this.desiredPlaying && this.members.size === ROOM_CAPACITY &&
      [...this.members.values()].every(m => m.connected && m.ready && !m.buffering && !m.suspended && !m.error);
    this.lastAction = action;
    this.updatedBy = actor;
    this.lastActivityMs = this.now();
    this.revision++;
  }

  addMember(name: unknown): { member: Member; resumeToken: string } {
    if (this.members.size >= ROOM_CAPACITY) throw new ProtocolError('room_full', '房间已经有两个人了');
    const memberName = text(name, 24, '昵称');
    const resumeToken = randomBytes(32).toString('base64url');
    const member: Member = {
      id: randomBytes(12).toString('hex'), name: memberName, connected: true,
      ready: false, buffering: false, suspended: false, error: null, durationMs: 0,
      tokenHash: tokenHash(resumeToken), commands: new Set(),
    };
    this.freeze();
    this.members.set(member.id, member);
    if (!this.hostId) this.hostId = member.id;
    this.commit('joined', member.id);
    return { member, resumeToken };
  }

  resume(memberId: unknown, token: unknown): Member {
    const member = typeof memberId === 'string' ? this.members.get(memberId) : undefined;
    if (!member || typeof token !== 'string' || token.length > 128 ||
      !timingSafeEqual(member.tokenHash, tokenHash(token))) {
      throw new ProtocolError('invalid_session', '房间身份已失效，请重新加入');
    }
    this.freeze();
    member.connected = true;
    member.ready = false;
    member.buffering = false;
    member.suspended = false;
    member.error = null;
    this.commit('reconnected', member.id);
    return member;
  }

  disconnect(memberId: string): void {
    const member = this.members.get(memberId);
    if (!member?.connected) return;
    this.freeze();
    member.connected = false;
    member.ready = false;
    if (this.hostId === memberId) {
      this.hostId = [...this.members.values()].find(m => m.connected)?.id ?? memberId;
    }
    this.commit('disconnected', memberId);
  }

  leave(memberId: string): void {
    this.freeze();
    this.members.delete(memberId);
    if (this.hostId === memberId) this.hostId = this.members.keys().next().value ?? '';
    this.commit('left', memberId);
  }

  command(memberId: string, input: Record<string, unknown>): boolean {
    const member = this.members.get(memberId);
    if (!member?.connected) throw new ProtocolError('not_joined', '请先加入房间');
    const requestId = text(input.requestId, 100, '消息编号');
    if (member.commands.has(requestId)) return false;
    const action = text(input.action, 24);
    if (action !== 'chat' && input.mediaEpoch !== this.mediaEpoch) {
      throw new ProtocolError('stale_media', '视频已经切换，正在更新房间进度');
    }
    if (!this.video && !['select', 'chat'].includes(action)) {
      throw new ProtocolError('no_video', '先选一个视频一起看吧');
    }
    // Validate before changing the timeline, so rejected input has no side effects.
    let nextVideo: Video | undefined;
    let value = 0;
    let message = '';
    switch (action) {
      case 'select': nextVideo = parseVideo(input.video); break;
      case 'seek': value = number(input.positionMs, 0, this.video?.durationMs || 7 * 24 * 3600_000); break;
      case 'rate': value = number(input.rate, 0.1, 16); break;
      case 'chat': message = text(input.text, 500, '消息'); break;
      case 'play': case 'pause': case 'restart': break;
      default: throw new ProtocolError('invalid_message', '无法识别这个播放操作');
    }
    const initialPosition = nextVideo
      ? number(input.positionMs ?? 0, 0, nextVideo.durationMs || 7 * 24 * 3600_000) : 0;
    this.freeze();
    switch (action) {
      case 'select':
        this.video = nextVideo!;
        this.mediaEpoch++;
        this.positionMs = initialPosition;
        this.desiredPlaying = input.playing !== false;
        for (const m of this.members.values()) {
          m.ready = false; m.buffering = false; m.error = null; m.durationMs = 0;
        }
        break;
      case 'seek': this.positionMs = value; break;
      case 'rate': this.rate = value; break;
      case 'play': this.desiredPlaying = true; break;
      case 'pause': this.desiredPlaying = false; break;
      case 'restart': this.positionMs = 0; this.desiredPlaying = true; break;
      case 'chat':
        this.messages.push({ id: requestId, memberId, name: member.name, text: message, sentAtMs: this.now() });
        if (this.messages.length > 50) this.messages.shift();
        break;
    }
    member.commands.add(requestId);
    if (member.commands.size > 256) member.commands.delete(member.commands.values().next().value!);
    this.commit(action, memberId);
    return true;
  }

  status(memberId: string, input: Record<string, unknown>): boolean {
    const member = this.members.get(memberId);
    if (!member || input.mediaEpoch !== this.mediaEpoch) return false;
    const ready = input.ready === true;
    const buffering = input.buffering === true;
    const suspended = input.suspended === true;
    let error = typeof input.error === 'string' ? input.error.slice(0, 160) : null;
    const durationMs = number(input.durationMs ?? 0, 0, 7 * 24 * 3600_000);
    if (ready && durationMs > 0 && this.video?.durationMs &&
      Math.abs(durationMs - this.video.durationMs) > 3000) {
      error = '视频时长不同，请确认双方账号都能完整观看';
    }
    if (member.ready === (ready && !error) && member.buffering === buffering &&
      member.suspended === suspended && member.error === error && member.durationMs === durationMs) return false;
    this.freeze();
    Object.assign(member, { ready: ready && !error, buffering, suspended, error, durationMs });
    this.commit('status', memberId);
    return true;
  }

  snapshot(): Record<string, unknown> {
    return {
      roomCode: this.code, revision: this.revision, mediaEpoch: this.mediaEpoch,
      video: this.video, positionMs: this.positionMs, updatedAtMs: this.updatedAtMs,
      serverTimeMs: this.now(), rate: this.rate, playing: this.playing,
      desiredPlaying: this.desiredPlaying, hostId: this.hostId,
      updatedBy: this.updatedBy, lastAction: this.lastAction,
      members: [...this.members.values()].map(({ tokenHash: _token, commands: _commands, ...member }) => member),
      messages: this.messages,
    };
  }
}
