import {
  aggregateMember,
  generateJoinCode,
  memberSeries,
  normalizeHandle,
  STREAK_THRESHOLD_USD,
  validateDays,
} from './logic.js';

const MAX_BODY_BYTES = 256 * 1024;
const JOIN_LIMIT = 10;
const JOIN_TTL_SECONDS = 60;

const JSON_HEADERS = { 'content-type': 'application/json' };
const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-allow-headers': 'content-type',
};

function json(data, status = 200, cors = false) {
  return new Response(JSON.stringify(data), {
    status,
    headers: cors ? { ...JSON_HEADERS, ...CORS_HEADERS } : JSON_HEADERS,
  });
}

function error(message, status = 400, cors = false) {
  return json({ error: message }, status, cors);
}

async function readJson(request, allowEmpty = false) {
  const length = Number(request.headers.get('content-length') || 0);
  if (length > MAX_BODY_BYTES) return { error: 'request body too large', status: 413 };
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) return { error: 'request body too large', status: 413 };
  if (!text.trim()) return allowEmpty ? { value: {} } : { error: 'JSON body required', status: 400 };
  try {
    return { value: JSON.parse(text) };
  } catch {
    return { error: 'malformed JSON body', status: 400 };
  }
}

async function sha256(value) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function listKeys(kv, prefix) {
  const names = [];
  let cursor;
  do {
    const page = await kv.list({ prefix, cursor });
    names.push(...page.keys.map((key) => key.name));
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return names;
}

async function pitExists(kv, code) {
  return kv.get(`pit:${code}`, 'json');
}

async function createPit(request, env, now) {
  const parsed = await readJson(request, true);
  if (parsed.error) return error(parsed.error, parsed.status);
  const name = parsed.value.name;
  if (name !== undefined && (typeof name !== 'string' || name.length > 80)) {
    return error('name must be a string up to 80 characters');
  }

  for (let attempt = 0; attempt < 20; attempt += 1) {
    const code = generateJoinCode();
    const key = `pit:${code}`;
    if (await env.BRRRN_KV.get(key)) continue;
    await env.BRRRN_KV.put(key, JSON.stringify({
      name: name?.trim() || null,
      created_at: now.toISOString(),
    }));
    return json({ code });
  }
  return error('could not allocate a join code', 503);
}

async function enforceJoinLimit(request, env) {
  const ip = request.headers.get('cf-connecting-ip') || 'unknown';
  const key = `ratelimit:join:${ip}`;
  const count = Number(await env.BRRRN_KV.get(key) || 0);
  if (count >= JOIN_LIMIT) return false;
  await env.BRRRN_KV.put(key, String(count + 1), { expirationTtl: JOIN_TTL_SECONDS });
  return true;
}

async function joinPit(request, env, code, now) {
  if (!(await pitExists(env.BRRRN_KV, code))) return error('pit not found', 404);
  if (!(await enforceJoinLimit(request, env))) return error('too many join attempts', 429);

  const parsed = await readJson(request);
  if (parsed.error) return error(parsed.error, parsed.status);
  const handle = normalizeHandle(parsed.value.handle);
  const secret = parsed.value.secret;
  if (!handle) return error('handle must be 1-24 lowercase letters, numbers, _ or -');
  if (typeof secret !== 'string' || secret.length < 1 || secret.length > 256) {
    return error('secret must be a non-empty string up to 256 characters');
  }

  const key = `member:${code}:${handle}`;
  if (await env.BRRRN_KV.get(key)) return error('handle already taken', 409);
  await env.BRRRN_KV.put(key, JSON.stringify({
    secret_hash: await sha256(secret),
    joined_at: now.toISOString(),
  }));
  return json({ ok: true });
}

function validMachineId(value) {
  return typeof value === 'string' && /^[a-zA-Z0-9_-]{1,64}$/.test(value);
}

async function authenticateMember(env, code, handleValue, secret) {
  const handle = normalizeHandle(handleValue);
  if (!handle) return { response: error('invalid handle') };
  if (!(await pitExists(env.BRRRN_KV, code))) {
    return { response: error('pit not found', 404) };
  }
  const member = await env.BRRRN_KV.get(`member:${code}:${handle}`, 'json');
  if (!member) return { response: error('member not found', 404) };
  if (typeof secret !== 'string' || await sha256(secret) !== member.secret_hash) {
    return { response: error('invalid secret', 401) };
  }
  return { handle, member };
}

async function submitDays(request, env, code) {
  const parsed = await readJson(request);
  if (parsed.error) return error(parsed.error, parsed.status);
  const body = parsed.value;
  const auth = await authenticateMember(env, code, body.handle, body.secret);
  if (auth.response) return auth.response;
  if (!validMachineId(body.machine_id)) {
    return error('machine_id must be 1-64 letters, numbers, _ or -');
  }
  const checked = validateDays(body.days);
  if (!checked.ok) return error(checked.error);

  await Promise.all(checked.days.map(({ date, rec }) => {
    const key = `day:${code}:${auth.handle}:${body.machine_id}:${date}`;
    return env.BRRRN_KV.put(key, JSON.stringify(rec));
  }));
  return json({ ok: true, days_stored: checked.days.length });
}

async function dailyRecords(env, prefix) {
  const keys = await listKeys(env.BRRRN_KV, prefix);
  const values = await Promise.all(keys.map((key) => env.BRRRN_KV.get(key, 'json')));
  return values.flatMap((rec, index) => {
    if (!rec) return [];
    const date = keys[index].slice(keys[index].lastIndexOf(':') + 1);
    return [{ [date]: rec }];
  });
}

async function getBoard(env, code, now) {
  const pit = await pitExists(env.BRRRN_KV, code);
  if (!pit) return error('pit not found', 404, true);
  const memberKeys = await listKeys(env.BRRRN_KV, `member:${code}:`);
  const members = await Promise.all(memberKeys.map(async (key) => {
    const handle = key.slice(`member:${code}:`.length);
    const records = await dailyRecords(env, `day:${code}:${handle}:`);
    return { handle, ...aggregateMember(records, now) };
  }));
  members.sort((a, b) => b.today_usd - a.today_usd || a.handle.localeCompare(b.handle));
  return json({ name: pit.name ?? null, code, streak_threshold_usd: STREAK_THRESHOLD_USD, members }, 200, true);
}

async function getMember(env, code, handleValue) {
  if (!(await pitExists(env.BRRRN_KV, code))) return error('pit not found', 404, true);
  const handle = normalizeHandle(handleValue);
  if (!handle || !(await env.BRRRN_KV.get(`member:${code}:${handle}`))) {
    return error('member not found', 404, true);
  }
  const records = await dailyRecords(env, `day:${code}:${handle}:`);
  return json({ handle, streak_threshold_usd: STREAK_THRESHOLD_USD, days: memberSeries(records) }, 200, true);
}

async function coordinatedRoute(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  const now = new Date(env.__TEST_NOW || Date.now());

  let match = path.match(/^\/pit\/([^/]+)\/join$/);
  if (request.method === 'POST' && match) return joinPit(request, env, match[1], now);

  match = path.match(/^\/pit\/([^/]+)\/submit$/);
  if (request.method === 'POST' && match) return submitDays(request, env, match[1]);

  return error('not found', 404);
}

export class Coordinator {
  constructor(_ctx, env) {
    this.env = env;
    this.tail = Promise.resolve();
  }

  async fetch(request) {
    let release;
    const previous = this.tail;
    this.tail = new Promise((resolve) => { release = resolve; });
    await previous;
    try {
      return await coordinatedRoute(request, this.env);
    } finally {
      release();
    }
  }
}

function coordinatedFetch(request, env) {
  if (!env.COORDINATOR) return coordinatedRoute(request, env);
  const id = env.COORDINATOR.idFromName('global');
  return env.COORDINATOR.get(id).fetch(request);
}

async function route(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  const now = new Date(env.__TEST_NOW || Date.now());

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (request.method === 'POST' && path === '/pit') {
    return createPit(request, env, now);
  }

  let match = path.match(/^\/pit\/([^/]+)\/(join|submit)$/);
  if (request.method === 'POST' && match) return coordinatedFetch(request, env);

  match = path.match(/^\/pit\/([^/]+)\/board$/);
  if (request.method === 'GET' && match) return getBoard(env, match[1], now);

  match = path.match(/^\/pit\/([^/]+)\/member\/([^/]+)$/);
  if (request.method === 'GET' && match) {
    return getMember(env, match[1], decodeURIComponent(match[2]));
  }

  return error('not found', 404, request.method === 'GET');
}

export { route as fetch };
export default { fetch: route };
