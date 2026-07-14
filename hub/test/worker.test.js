import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { Coordinator } from '../src/worker.js';

// Map-backed mock of the Workers KV binding, matching the return shapes of
// get / put / list({prefix}).
class MockKV {
  constructor() {
    this.store = new Map();
  }

  async get(key, typeOrOptions) {
    const value = this.store.get(key);
    if (value === undefined) return null;
    const type = typeof typeOrOptions === 'string' ? typeOrOptions : typeOrOptions?.type;
    return type === 'json' ? JSON.parse(value) : value;
  }

  async put(key, value, _options) {
    this.store.set(key, String(value));
  }

  async delete(key) {
    this.store.delete(key);
  }

  async list({ prefix = '' } = {}) {
    const keys = [...this.store.keys()]
      .filter((k) => k.startsWith(prefix))
      .sort()
      .map((name) => ({ name }));
    return { keys, list_complete: true, cacheStatus: null };
  }
}

// Fixed "now": Wednesday 2026-01-07 UTC. ISO week starts Monday 2026-01-05.
const NOW = '2026-01-07T12:00:00Z';

function makeEnv() {
  const env = { BRRRN_KV: new MockKV(), __TEST_NOW: NOW };
  let coordinator;
  env.COORDINATOR = {
    idFromName: (name) => name,
    get: () => ({
      fetch: (request) => {
        coordinator ??= new Coordinator({}, env);
        return coordinator.fetch(request);
      },
    }),
  };
  return env;
}

async function call(env, method, path, body, headers = {}) {
  const init = { method, headers: { ...headers } };
  if (body !== undefined) {
    init.body = typeof body === 'string' ? body : JSON.stringify(body);
    init.headers['content-type'] = 'application/json';
  }
  const res = await worker.fetch(new Request(`https://brrrn-hub.test${path}`, init), env, {});
  const data = res.status === 204 ? null : await res.json();
  return { status: res.status, data, headers: res.headers };
}

async function createPit(env, name) {
  const res = await call(env, 'POST', '/pit', name === undefined ? {} : { name });
  assert.equal(res.status, 200);
  return res.data.code;
}

async function join(env, code, handle, secret) {
  return call(env, 'POST', `/pit/${code}/join`, { handle, secret });
}

test('end to end: create pit, join, submit, board, member series', async () => {
  const env = makeEnv();

  const code = await createPit(env, '台北燒錢俱樂部');
  assert.match(code, /^[a-z]+-[a-z]+-[a-z0-9]{4}$/);

  const joined = await join(env, code, 'Alice', 'hunter2');
  assert.equal(joined.status, 200);
  assert.deepEqual(joined.data, { ok: true });

  // Three days from the laptop: today, yesterday, and the prior Sunday
  // (2026-01-04 is out of the ISO week but inside the month).
  const submit = await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 'hunter2',
    machine_id: 'laptop',
    days: [
      {
        date: '2026-01-07', tokens: 1800, cost_usd: 10, claude_usd: 8, codex_usd: 2,
        models: {
          'claude-fable-5': { input_tokens: 1000, output_tokens: 200, cost_usd: 8 },
          'gpt-6-codex': { input_tokens: 500, output_tokens: 100, cost_usd: 2 },
        },
      },
      {
        date: '2026-01-06', tokens: 350, cost_usd: 6, claude_usd: 6, codex_usd: 0,
        models: { 'claude-fable-5': { input_tokens: 300, output_tokens: 50, cost_usd: 6 } },
      },
      {
        date: '2026-01-04', tokens: 900, cost_usd: 7, claude_usd: 0, codex_usd: 7,
        models: { 'gpt-6-codex': { input_tokens: 800, output_tokens: 100, cost_usd: 7 } },
      },
    ],
  });
  assert.equal(submit.status, 200);
  assert.deepEqual(submit.data, { ok: true, days_stored: 3 });

  const board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.status, 200);
  assert.equal(board.headers.get('access-control-allow-origin'), '*');
  assert.equal(board.headers.get('content-type'), 'application/json');
  assert.equal(board.data.name, '台北燒錢俱樂部');
  assert.equal(board.data.code, code);
  assert.equal(board.data.streak_threshold_usd, 5);
  assert.equal(board.data.members.length, 1);

  const alice = board.data.members[0];
  assert.equal(alice.handle, 'alice');
  assert.equal(alice.today_usd, 10);
  assert.equal(alice.week_usd, 16);
  assert.equal(alice.month_usd, 23);
  // Today 10 and yesterday 6 qualify; 2026-01-05 has no record.
  assert.equal(alice.streak_days, 2);
  assert.equal(alice.top_model, 'claude-fable-5');
  assert.deepEqual(alice.models_week, [
    { model: 'claude-fable-5', input_tokens: 1300, output_tokens: 250, cost_usd: 14 },
    { model: 'gpt-6-codex', input_tokens: 500, output_tokens: 100, cost_usd: 2 },
  ]);

  // A second machine adds up instead of clobbering.
  const desktop = await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 'hunter2',
    machine_id: 'desktop',
    days: [{ date: '2026-01-07', tokens: 100, cost_usd: 4, claude_usd: 4, codex_usd: 0 }],
  });
  assert.equal(desktop.status, 200);

  const board2 = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board2.data.members[0].today_usd, 14);
  assert.equal(board2.data.members[0].week_usd, 20);
  assert.equal(board2.data.members[0].month_usd, 27);

  // Re-submitting from the same machine overwrites that machine's date.
  await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 'hunter2',
    machine_id: 'desktop',
    days: [{ date: '2026-01-07', tokens: 25, cost_usd: 1, claude_usd: 1, codex_usd: 0 }],
  });
  const board3 = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board3.data.members[0].today_usd, 11);

  const member = await call(env, 'GET', `/pit/${code}/member/alice`);
  assert.equal(member.status, 200);
  assert.equal(member.headers.get('access-control-allow-origin'), '*');
  assert.deepEqual(member.data, {
    handle: 'alice',
    streak_threshold_usd: 5,
    days: [
      { date: '2026-01-04', tokens: 900, cost_usd: 7 },
      { date: '2026-01-06', tokens: 350, cost_usd: 6 },
      { date: '2026-01-07', tokens: 1825, cost_usd: 11 },
    ],
  });
});

test('board sorts members by today_usd desc', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'race');
  for (const [handle, cost] of [['low', 1], ['high', 9], ['mid', 5]]) {
    await join(env, code, handle, 's');
    await call(env, 'POST', `/pit/${code}/submit`, {
      handle, secret: 's', machine_id: 'm1',
      days: [{ date: '2026-01-07', tokens: 10, cost_usd: cost, claude_usd: cost, codex_usd: 0 }],
    });
  }
  const board = await call(env, 'GET', `/pit/${code}/board`);
  assert.deepEqual(board.data.members.map((m) => m.handle), ['high', 'mid', 'low']);
});

test('pit can be created with no name and no body', async () => {
  const env = makeEnv();
  const res = await call(env, 'POST', '/pit');
  assert.equal(res.status, 200);
  const board = await call(env, 'GET', `/pit/${res.data.code}/board`);
  assert.equal(board.data.name, null);
  assert.deepEqual(board.data.members, []);
});

test('join: unknown pit is 404, duplicate handle is 409, bad handle is 400', async () => {
  const env = makeEnv();
  const missing = await join(env, 'no-such-pit1', 'alice', 's');
  assert.equal(missing.status, 404);

  const code = await createPit(env);
  assert.equal((await join(env, code, 'alice', 's1')).status, 200);
  const dup = await join(env, code, 'ALICE', 's2');
  assert.equal(dup.status, 409);
  assert.ok(dup.data.error);

  assert.equal((await join(env, code, 'bad handle!', 's')).status, 400);
  assert.equal((await join(env, code, 'x'.repeat(25), 's')).status, 400);
});

test('coordinator serializes concurrent claims for the same handle', async () => {
  const env = makeEnv();
  const code = await createPit(env);
  const results = await Promise.all([
    join(env, code, 'alice', 'secret-a'),
    join(env, code, 'alice', 'secret-b'),
  ]);
  assert.deepEqual(results.map((r) => r.status).sort(), [200, 409]);
});

test('concurrent submissions for different dates do not overwrite each other', async () => {
  const env = makeEnv();
  const code = await createPit(env);
  await join(env, code, 'alice', 's');
  const base = { handle: 'alice', secret: 's', machine_id: 'm1' };
  const results = await Promise.all([
    call(env, 'POST', `/pit/${code}/submit`, {
      ...base,
      days: [{ date: '2026-01-06', tokens: 10, cost_usd: 6 }],
    }),
    call(env, 'POST', `/pit/${code}/submit`, {
      ...base,
      days: [{ date: '2026-01-07', tokens: 20, cost_usd: 7 }],
    }),
  ]);
  assert.ok(results.every((r) => r.status === 200));
  const member = await call(env, 'GET', `/pit/${code}/member/alice`);
  assert.deepEqual(member.data.days, [
    { date: '2026-01-06', tokens: 10, cost_usd: 6 },
    { date: '2026-01-07', tokens: 20, cost_usd: 7 },
  ]);
});

test('submit: wrong secret is 401, unknown pit and member are 404', async () => {
  const env = makeEnv();
  const code = await createPit(env);
  await join(env, code, 'alice', 'right');

  const base = { machine_id: 'm1', days: [] };
  const wrong = await call(env, 'POST', `/pit/${code}/submit`, { ...base, handle: 'alice', secret: 'wrong' });
  assert.equal(wrong.status, 401);

  const noPit = await call(env, 'POST', '/pit/nope-nope-2345/submit', { ...base, handle: 'alice', secret: 'right' });
  assert.equal(noPit.status, 404);

  const noMember = await call(env, 'POST', `/pit/${code}/submit`, { ...base, handle: 'bob', secret: 'right' });
  assert.equal(noMember.status, 404);
});

test('submit: invalid day records are 400', async () => {
  const env = makeEnv();
  const code = await createPit(env);
  await join(env, code, 'alice', 's');
  const base = { handle: 'alice', secret: 's', machine_id: 'm1' };

  for (const days of [
    'not-an-array',
    [{ date: '2026/01/07', tokens: 1, cost_usd: 1 }],
    [{ date: '2026-01-07', tokens: -1, cost_usd: 1 }],
    [{ date: '2026-01-07', tokens: 1, cost_usd: Infinity }],
  ]) {
    const res = await call(env, 'POST', `/pit/${code}/submit`, { ...base, days });
    assert.equal(res.status, 400, JSON.stringify(days).slice(0, 60));
    assert.ok(res.data.error);
  }

  const noMachine = await call(env, 'POST', `/pit/${code}/submit`, { handle: 'alice', secret: 's', days: [] });
  assert.equal(noMachine.status, 400);
});

test('submit: body over 256KB is 413', async () => {
  const env = makeEnv();
  const code = await createPit(env);
  await join(env, code, 'alice', 's');
  const body = JSON.stringify({
    handle: 'alice', secret: 's', machine_id: 'm1', days: [], padding: 'x'.repeat(280 * 1024),
  });
  const res = await call(env, 'POST', `/pit/${code}/submit`, body);
  assert.equal(res.status, 413);
});

test('join is rate limited to 10 per IP per minute', async () => {
  const env = makeEnv();
  const code = await createPit(env);
  const ip = { 'cf-connecting-ip': '203.0.113.7' };
  for (let i = 0; i < 10; i++) {
    const res = await call(env, 'POST', `/pit/${code}/join`, { handle: `user${i}`, secret: 's' }, ip);
    assert.equal(res.status, 200, `join ${i}`);
  }
  const blocked = await call(env, 'POST', `/pit/${code}/join`, { handle: 'user10', secret: 's' }, ip);
  assert.equal(blocked.status, 429);

  // A different IP is not affected.
  const other = await call(env, 'POST', `/pit/${code}/join`, { handle: 'user10', secret: 's' }, { 'cf-connecting-ip': '203.0.113.8' });
  assert.equal(other.status, 200);
});

test('coordinator enforces join limit under concurrency', async () => {
  const env = makeEnv();
  const code = await createPit(env);
  const ip = { 'cf-connecting-ip': '203.0.113.90' };
  const results = await Promise.all(Array.from({ length: 11 }, (_, i) =>
    call(env, 'POST', `/pit/${code}/join`, { handle: `burst${i}`, secret: 's' }, ip)
  ));
  assert.equal(results.filter((r) => r.status === 200).length, 10);
  assert.equal(results.filter((r) => r.status === 429).length, 1);
});

test('member endpoint 404s for unknown pit or handle', async () => {
  const env = makeEnv();
  assert.equal((await call(env, 'GET', '/pit/none-none-2345/member/alice')).status, 404);
  const code = await createPit(env);
  assert.equal((await call(env, 'GET', `/pit/${code}/member/ghost`)).status, 404);
});

test('unknown routes and methods are 404 with a JSON error', async () => {
  const env = makeEnv();
  for (const [method, path] of [
    ['GET', '/'],
    ['GET', '/pit'],
    ['POST', '/pit/abc-def-2345/board'],
    ['GET', '/nope'],
    ['DELETE', '/pit/abc-def-2345/join'],
  ]) {
    const res = await call(env, method, path);
    assert.equal(res.status, 404, `${method} ${path}`);
    assert.ok(res.data.error);
    assert.equal(res.headers.get('content-type'), 'application/json');
  }
});

test('OPTIONS preflight returns permissive CORS headers', async () => {
  const env = makeEnv();
  const res = await call(env, 'OPTIONS', '/pit/abc-def-2345/board');
  assert.equal(res.status, 204);
  assert.equal(res.headers.get('access-control-allow-origin'), '*');
  assert.ok(res.headers.get('access-control-allow-methods').includes('POST'));
  assert.ok(res.headers.get('access-control-allow-headers').toLowerCase().includes('content-type'));
});

test('malformed JSON body is 400', async () => {
  const env = makeEnv();
  const res = await call(env, 'POST', '/pit', '{not json');
  assert.equal(res.status, 400);
});
