import test from 'node:test';
import assert from 'node:assert/strict';
import worker, { Coordinator } from '../src/worker.js';

// Map-backed mock of the Workers KV binding, matching the return shapes of
// get / put / list({prefix}).
class MockKV {
  constructor() {
    this.store = new Map();
    this.bulkGetKeys = [];
    this.listPrefixes = [];
    this.getMisses = new Map();
    this.putFailures = new Map();
    this.deleteFailures = new Map();
    this.deleteKeys = [];
    this.putPrefixFailures = [];
    this.putPrefixDelays = [];
    this.getBlocks = new Map();
    this.beforeNextBulkGet = null;
    this.bulkGetBlock = null;
  }

  blockNextGet(key) {
    let release;
    const promise = new Promise((resolve) => { release = resolve; });
    this.getBlocks.set(key, { promise, release });
    return release;
  }

  runBeforeNextBulkGet(callback) {
    this.beforeNextBulkGet = callback;
  }

  blockNextBulkGets(count) {
    let release;
    const promise = new Promise((resolve) => { release = resolve; });
    this.bulkGetBlock = { remaining: count, promise };
    return release;
  }

  missNextGet(key) {
    this.getMisses.set(key, (this.getMisses.get(key) ?? 0) + 1);
  }

  failNextPut(key) {
    this.putFailures.set(key, (this.putFailures.get(key) ?? 0) + 1);
  }

  failPutWithPrefixOn(prefix, occurrence = 1) {
    this.putPrefixFailures.push({ prefix, remaining: occurrence });
  }

  delayPutWithPrefixOn(prefix, occurrence = 1, milliseconds = 20) {
    this.putPrefixDelays.push({ prefix, remaining: occurrence, milliseconds });
  }

  failNextDelete(key) {
    this.deleteFailures.set(key, (this.deleteFailures.get(key) ?? 0) + 1);
  }

  consumeFailure(failures, key) {
    const remaining = failures.get(key) ?? 0;
    if (!remaining) return false;
    if (remaining === 1) failures.delete(key);
    else failures.set(key, remaining - 1);
    return true;
  }

  async get(key, typeOrOptions) {
    const type = typeof typeOrOptions === 'string' ? typeOrOptions : typeOrOptions?.type;
    if (Array.isArray(key)) {
      const callback = this.beforeNextBulkGet;
      this.beforeNextBulkGet = null;
      if (callback) await callback();
      if (this.bulkGetBlock?.remaining > 0) {
        this.bulkGetBlock.remaining -= 1;
        await this.bulkGetBlock.promise;
      }
      this.bulkGetKeys.push(...key);
      return new Map(key.map((name) => {
        if (this.consumeFailure(this.getMisses, name)) return [name, null];
        const value = this.store.get(name);
        return [name, value === undefined ? null : type === 'json' ? JSON.parse(value) : value];
      }));
    }
    if (this.consumeFailure(this.getMisses, key)) return null;
    const block = this.getBlocks.get(key);
    if (block) {
      this.getBlocks.delete(key);
      await block.promise;
    }
    const value = this.store.get(key);
    if (value === undefined) return null;
    return type === 'json' ? JSON.parse(value) : value;
  }

  async put(key, value, _options) {
    const delayIndex = this.putPrefixDelays.findIndex((delay) => key.startsWith(delay.prefix));
    if (delayIndex >= 0) {
      const delay = this.putPrefixDelays[delayIndex];
      delay.remaining -= 1;
      if (delay.remaining === 0) {
        this.putPrefixDelays.splice(delayIndex, 1);
        await new Promise((resolve) => setTimeout(resolve, delay.milliseconds));
      }
    }
    const prefixIndex = this.putPrefixFailures.findIndex((failure) => key.startsWith(failure.prefix));
    if (prefixIndex >= 0) {
      const failure = this.putPrefixFailures[prefixIndex];
      failure.remaining -= 1;
      if (failure.remaining === 0) {
        this.putPrefixFailures.splice(prefixIndex, 1);
        throw new Error(`injected put failure: ${key}`);
      }
    }
    if (this.consumeFailure(this.putFailures, key)) throw new Error(`injected put failure: ${key}`);
    this.store.set(key, String(value));
  }

  async delete(key) {
    this.deleteKeys.push(key);
    if (this.consumeFailure(this.deleteFailures, key)) {
      throw new Error(`injected delete failure: ${key}`);
    }
    this.store.delete(key);
  }

  async list({ prefix = '' } = {}) {
    this.listPrefixes.push(prefix);
    const keys = [...this.store.keys()]
      .filter((k) => k.startsWith(prefix))
      .sort()
      .map((name) => ({ name }));
    return { keys, list_complete: true, cacheStatus: null };
  }
}

function cloneStored(value) {
  return value === undefined ? undefined : structuredClone(value);
}

// Durable Object storage stores structured values, returns a Map for list,
// and runs transactions one at a time. A failed transaction restores all keys.
class MockDurableObjectStorage {
  constructor() {
    this.store = new Map();
    this.transactionTail = Promise.resolve();
    this.getBlocks = new Map();
  }

  blockNextGet(key) {
    let release;
    const promise = new Promise((resolve) => { release = resolve; });
    this.getBlocks.set(key, { promise, release });
    return release;
  }

  async get(keyOrKeys) {
    if (Array.isArray(keyOrKeys)) {
      if (keyOrKeys.length > 128) throw new Error('too many Durable Object keys');
      const found = new Map();
      for (const key of keyOrKeys) {
        if (this.store.has(key)) found.set(key, cloneStored(this.store.get(key)));
      }
      return found;
    }
    const block = this.getBlocks.get(keyOrKeys);
    if (block) {
      this.getBlocks.delete(keyOrKeys);
      await block.promise;
    }
    return cloneStored(this.store.get(keyOrKeys));
  }

  async put(keyOrEntries, value) {
    if (typeof keyOrEntries === 'string') {
      this.store.set(keyOrEntries, cloneStored(value));
      return;
    }
    for (const [key, entryValue] of Object.entries(keyOrEntries)) {
      this.store.set(key, cloneStored(entryValue));
    }
  }

  async delete(keyOrKeys) {
    if (Array.isArray(keyOrKeys)) {
      if (keyOrKeys.length > 128) throw new Error('too many Durable Object keys');
      let deleted = 0;
      for (const key of keyOrKeys) deleted += Number(this.store.delete(key));
      return deleted;
    }
    return this.store.delete(keyOrKeys);
  }

  async list({ prefix = '', start, end, reverse = false, limit } = {}) {
    let keys = [...this.store.keys()]
      .filter((key) => key.startsWith(prefix))
      .filter((key) => start === undefined || key >= start)
      .filter((key) => end === undefined || key < end)
      .sort();
    if (reverse) keys.reverse();
    if (limit !== undefined) keys = keys.slice(0, limit);
    return new Map(keys.map((key) => [key, cloneStored(this.store.get(key))]));
  }

  async transaction(callback) {
    let release;
    const previous = this.transactionTail;
    this.transactionTail = new Promise((resolve) => { release = resolve; });
    await previous;

    const snapshot = new Map(
      [...this.store].map(([key, value]) => [key, cloneStored(value)]),
    );
    try {
      return await callback(this);
    } catch (err) {
      this.store = snapshot;
      throw err;
    } finally {
      release();
    }
  }
}

// Fixed "now": Wednesday 2026-01-07 UTC. ISO week starts Monday 2026-01-05.
const NOW = '2026-01-07T12:00:00Z';

function makeEnv() {
  const storage = new MockDurableObjectStorage();
  const env = { BRRRN_KV: new MockKV(), __TEST_DO_STORAGE: storage, __TEST_NOW: NOW };
  let coordinator;
  env.COORDINATOR = {
    idFromName: (name) => name,
    get: () => ({
      fetch: (request) => {
        coordinator ??= new Coordinator({ storage }, env);
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

function stalledJsonPost(path, headers = {}) {
  let controller;
  let cancelled = false;
  const body = new ReadableStream({
    start(streamController) {
      controller = streamController;
    },
    cancel() {
      cancelled = true;
    },
  });
  const request = new Request(`https://brrrn-hub.test${path}`, {
    method: 'POST',
    headers: { ...headers, 'content-type': 'application/json' },
    body,
    duplex: 'half',
  });
  return {
    request,
    release(value) {
      controller.enqueue(new TextEncoder().encode(JSON.stringify(value)));
      controller.close();
    },
    wasCancelled() {
      return cancelled;
    },
  };
}

async function callRequest(env, request) {
  const res = await worker.fetch(request, env, {});
  return { status: res.status, data: await res.json(), headers: res.headers };
}

async function createPit(env, name) {
  const res = await call(env, 'POST', '/pit', name === undefined ? {} : { name });
  assert.equal(res.status, 200);
  return res.data.code;
}

async function join(env, code, handle, secret) {
  return call(env, 'POST', `/pit/${code}/join`, { handle, secret });
}

const REL_DIRECT = `rel_${'a'.repeat(32)}`;
const REL_GROUP = `rel_${'b'.repeat(32)}`;
const INVITE_ONE = `inv_${'1'.repeat(64)}`;
const INVITE_TWO = `inv_${'2'.repeat(64)}`;
const INVITE_THREE = `inv_${'3'.repeat(64)}`;

function invitationToken(index) {
  return `inv_${index.toString(16).padStart(64, '0')}`;
}

function relationshipId(index) {
  return `rel_${index.toString(16).padStart(32, '0')}`;
}

function identity(handle, secret) {
  return {
    authorization: `Bearer ${secret}`,
    'x-brrrn-handle': handle,
  };
}

async function createRelationship(env, {
  relationshipId = REL_DIRECT,
  type = 'direct',
  name,
  handle = 'alice',
  secret = 'alice-secret',
} = {}) {
  const body = { relationship_id: relationshipId, type };
  if (name !== undefined) body.name = name;
  return call(env, 'POST', '/v2/relationships', body, identity(handle, secret));
}

async function createInvitation(env, relationshipId, invitationToken, handle = 'alice', secret = 'alice-secret') {
  return call(
    env,
    'POST',
    `/v2/relationships/${relationshipId}/invitations`,
    { invitation_token: invitationToken },
    identity(handle, secret),
  );
}

async function acceptInvitation(env, invitationToken, handle, secret) {
  return call(
    env,
    'POST',
    '/v2/invitations/accept',
    { invitation_token: invitationToken },
    identity(handle, secret),
  );
}

function sampleDay(overrides = {}) {
  return {
    date: '2026-01-07',
    tokens: 100,
    cost_usd: 6,
    claude_usd: 6,
    codex_usd: 0,
    models: { 'claude-fable-5': { input_tokens: 80, output_tokens: 20, cost_usd: 6 } },
    ...overrides,
  };
}

function datedDays(count, offset = 0) {
  return Array.from({ length: count }, (_, index) => {
    const date = new Date(Date.UTC(2024, 0, 1) + (offset + index) * 86400000)
      .toISOString()
      .slice(0, 10);
    return sampleDay({ date });
  });
}

function daysEndingOn(count, endDate = '2026-01-07') {
  const end = Date.parse(`${endDate}T00:00:00Z`);
  return Array.from({ length: count }, (_, index) => {
    const daysBeforeEnd = count - index - 1;
    const date = new Date(end - daysBeforeEnd * 86400000).toISOString().slice(0, 10);
    return sampleDay({ date });
  });
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

test('Durable Object storage mock serializes transactions and rolls back failed writes', async () => {
  const storage = new MockDurableObjectStorage();
  await storage.put('counter', 0);

  await Promise.all([1, 2].map(() => storage.transaction(async (txn) => {
    const value = await txn.get('counter');
    await Promise.resolve();
    await txn.put('counter', value + 1);
  })));
  assert.equal(await storage.get('counter'), 2);

  await assert.rejects(storage.transaction(async (txn) => {
    await txn.put('counter', 99);
    await txn.put('temporary', true);
    throw new Error('abort');
  }), /abort/);
  assert.equal(await storage.get('counter'), 2);
  assert.equal(await storage.get('temporary'), undefined);

  await storage.put({ 'prefix:a': 1, 'prefix:b': 2, other: 3 });
  assert.deepEqual([...await storage.list({ prefix: 'prefix:' })], [
    ['prefix:a', 1],
    ['prefix:b', 2],
  ]);
  assert.equal(await storage.delete('other'), true);
  assert.equal(await storage.get('other'), undefined);
});

test('v2 creates direct and trimmed Unicode group relationships with the creator as a member', async () => {
  const env = makeEnv();

  const direct = await createRelationship(env);
  assert.equal(direct.status, 200);
  assert.equal(direct.data.relationship_id, REL_DIRECT);

  const directBoard = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(directBoard.status, 200);
  assert.equal(directBoard.data.relationship_id, REL_DIRECT);
  assert.equal(directBoard.data.type, 'direct');
  assert.equal(directBoard.data.name, null);
  assert.deepEqual(directBoard.data.members.map((member) => member.handle), ['alice']);

  const group = await createRelationship(env, {
    relationshipId: REL_GROUP,
    type: 'group',
    name: '　台北 🔥 開発者の会　',
  });
  assert.equal(group.status, 200);
  assert.equal(group.data.relationship_id, REL_GROUP);

  const groupBoard = await call(
    env,
    'GET',
    `/v2/relationships/${REL_GROUP}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(groupBoard.status, 200);
  assert.equal(groupBoard.data.type, 'group');
  assert.equal(groupBoard.data.name, '台北 🔥 開発者の会');
  assert.deepEqual(groupBoard.data.members.map((member) => member.handle), ['alice']);
});

test('v2 relationship creation is idempotent but rejects conflicting ID reuse', async () => {
  const env = makeEnv();
  const first = await createRelationship(env);
  assert.equal(first.status, 200);

  const retry = await createRelationship(env);
  assert.equal(retry.status, 200);
  assert.deepEqual(retry.data, first.data);

  const changedDefinition = await createRelationship(env, {
    relationshipId: REL_DIRECT,
    type: 'group',
    name: 'conflict',
  });
  assert.equal(changedDefinition.status, 409);

  const changedCreator = await createRelationship(env, {
    relationshipId: REL_DIRECT,
    handle: 'mallory',
    secret: 'mallory-secret',
  });
  assert.equal(changedCreator.status, 409);
});

test('v2 creation requires a valid creator identity and later authenticates its secret', async () => {
  const env = makeEnv();
  const missingIdentity = await call(env, 'POST', '/v2/relationships', {
    relationship_id: REL_DIRECT,
    type: 'direct',
  });
  assert.equal(missingIdentity.status, 401);

  const missingHandle = await call(
    env,
    'POST',
    '/v2/relationships',
    { relationship_id: REL_DIRECT, type: 'direct' },
    { authorization: 'Bearer alice-secret' },
  );
  assert.equal(missingHandle.status, 401);

  assert.equal((await createRelationship(env)).status, 200);
  const wrongSecret = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'wrong-secret'),
  );
  assert.equal(wrongSecret.status, 401);
});

test('v2 stores invitations by token hash without retaining plaintext', async () => {
  const env = makeEnv();
  assert.equal((await createRelationship(env)).status, 200);
  const invited = await createInvitation(env, REL_DIRECT, INVITE_ONE);
  assert.equal(invited.status, 200);

  const hash = await sha256Hex(INVITE_ONE);
  const stored = await env.__TEST_DO_STORAGE.get(`v2:invite:${hash}`);
  assert.ok(stored);
  assert.equal(JSON.stringify([...env.__TEST_DO_STORAGE.store]).includes(INVITE_ONE), false);
});

test('v2 invitation preview returns safe metadata and expires after seven days', async () => {
  const env = makeEnv();
  await createRelationship(env, {
    relationshipId: REL_GROUP,
    type: 'group',
    name: '  火の会 🔥  ',
  });
  await createInvitation(env, REL_GROUP, INVITE_ONE);

  const preview = await call(env, 'POST', '/v2/invitations/preview', {
    invitation_token: INVITE_ONE,
  });
  assert.equal(preview.status, 200);
  assert.equal(preview.data.type, 'group');
  assert.equal(preview.data.name, '火の会 🔥');
  assert.equal('members' in preview.data, false);
  assert.equal(JSON.stringify(preview.data).includes(INVITE_ONE), false);
  assert.equal(JSON.stringify(preview.data).includes('alice-secret'), false);

  env.__TEST_NOW = '2026-01-14T11:59:59Z';
  assert.equal((await call(env, 'POST', '/v2/invitations/preview', {
    invitation_token: INVITE_ONE,
  })).status, 200);

  env.__TEST_NOW = '2026-01-14T12:00:00Z';
  assert.equal((await call(env, 'POST', '/v2/invitations/preview', {
    invitation_token: INVITE_ONE,
  })).status, 410);

  env.__TEST_NOW = '2026-01-14T12:00:01Z';
  assert.equal((await call(env, 'POST', '/v2/invitations/preview', {
    invitation_token: INVITE_ONE,
  })).status, 410);
});

test('v2 invitation acceptance rejects the exact expiration instant', async () => {
  const env = makeEnv();
  await createRelationship(env);
  await createInvitation(env, REL_DIRECT, INVITE_ONE);
  env.__TEST_NOW = '2026-01-14T12:00:00Z';
  const expired = await acceptInvitation(env, INVITE_ONE, 'bob', 'bob-secret');
  assert.equal(expired.status, 410);
});

test('v2 invitation acceptance is single use and retries for the same identity are idempotent', async () => {
  const env = makeEnv();
  await createRelationship(env);
  await createInvitation(env, REL_DIRECT, INVITE_ONE);

  const accepted = await acceptInvitation(env, INVITE_ONE, 'bob', 'bob-secret');
  assert.equal(accepted.status, 200);
  assert.equal(accepted.data.relationship_id, REL_DIRECT);

  const retry = await acceptInvitation(env, INVITE_ONE, 'BOB', 'bob-secret');
  assert.equal(retry.status, 200);
  assert.deepEqual(retry.data, accepted.data);

  const reused = await acceptInvitation(env, INVITE_ONE, 'carol', 'carol-secret');
  assert.equal(reused.status, 410);
  const recreated = await createInvitation(env, REL_DIRECT, INVITE_ONE);
  assert.equal(recreated.status, 410);

  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('bob', 'bob-secret'),
  );
  assert.equal(board.status, 200);
  assert.deepEqual(board.data.members.map((member) => member.handle).sort(), ['alice', 'bob']);
});

test('v2 concurrent direct invitation accepts enforce two-member capacity', async () => {
  const env = makeEnv();
  await createRelationship(env);
  await createInvitation(env, REL_DIRECT, INVITE_ONE);
  await createInvitation(env, REL_DIRECT, INVITE_TWO);

  const results = await Promise.all([
    acceptInvitation(env, INVITE_ONE, 'bob', 'bob-secret'),
    acceptInvitation(env, INVITE_TWO, 'carol', 'carol-secret'),
  ]);
  assert.deepEqual(results.map((result) => result.status).sort(), [200, 409]);

  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(board.data.members.length, 2);
  assert.equal(board.data.members.some((member) => member.handle === 'alice'), true);
});

test('v2 invitation creation requires membership and respects relationship capacity', async () => {
  const directEnv = makeEnv();
  await createRelationship(directEnv);

  const outsider = await createInvitation(
    directEnv,
    REL_DIRECT,
    INVITE_ONE,
    'mallory',
    'mallory-secret',
  );
  assert.equal(outsider.status, 401);

  await createInvitation(directEnv, REL_DIRECT, INVITE_ONE);
  await acceptInvitation(directEnv, INVITE_ONE, 'bob', 'bob-secret');
  const full = await createInvitation(directEnv, REL_DIRECT, INVITE_TWO);
  assert.equal(full.status, 409);

  const groupEnv = makeEnv();
  await createRelationship(groupEnv, {
    relationshipId: REL_GROUP,
    type: 'group',
    name: 'builders',
  });
  await createInvitation(groupEnv, REL_GROUP, INVITE_ONE);
  await acceptInvitation(groupEnv, INVITE_ONE, 'bob', 'bob-secret');
  const memberInvite = await createInvitation(
    groupEnv,
    REL_GROUP,
    INVITE_THREE,
    'bob',
    'bob-secret',
  );
  assert.equal(memberInvite.status, 200);
});

test('v2 invitation creation retry remains idempotent after a direct relationship fills', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const original = await createInvitation(env, REL_DIRECT, INVITE_ONE);
  assert.equal(original.status, 200);
  await createInvitation(env, REL_DIRECT, INVITE_TWO);
  await acceptInvitation(env, INVITE_TWO, 'bob', 'bob-secret');

  const retry = await createInvitation(env, REL_DIRECT, INVITE_ONE);
  assert.equal(retry.status, 200);
  assert.deepEqual(retry.data, original.data);
});

test('v2 caps active invitations and reclaims expired capabilities', async () => {
  const env = makeEnv();
  await createRelationship(env, {
    relationshipId: REL_GROUP,
    type: 'group',
    name: 'bounded invites',
  });

  for (let index = 1; index <= 20; index += 1) {
    const result = await createInvitation(env, REL_GROUP, invitationToken(index));
    assert.equal(result.status, 200, `invitation ${index}`);
  }
  assert.equal(
    (await createInvitation(env, REL_GROUP, invitationToken(21))).status,
    429,
  );

  env.__TEST_NOW = '2026-01-14T12:00:00Z';
  assert.equal(
    (await createInvitation(env, REL_GROUP, invitationToken(22))).status,
    200,
  );
  const active = await env.__TEST_DO_STORAGE.list({
    prefix: `v2:relationship-invite:${REL_GROUP}:`,
  });
  assert.equal(active.size, 1);
  const expiredHash = await sha256Hex(invitationToken(1));
  assert.ok(await env.__TEST_DO_STORAGE.get(`v2:invite:${expiredHash}`));
  assert.equal(
    (await createInvitation(env, REL_GROUP, invitationToken(1))).status,
    410,
  );
});

test('v2 authentication does not reveal relationship membership', async () => {
  const env = makeEnv();
  await createRelationship(env);

  const wrongSecret = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'wrong-secret'),
  );
  const unknownHandle = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('mallory', 'wrong-secret'),
  );
  assert.equal(wrongSecret.status, 401);
  assert.equal(unknownHandle.status, 401);
  assert.deepEqual(wrongSecret.data, unknownHandle.data);

  await createInvitation(env, REL_DIRECT, INVITE_ONE);
  await acceptInvitation(env, INVITE_ONE, 'bob', 'bob-secret');
  const wrongConsumerSecret = await acceptInvitation(env, INVITE_ONE, 'bob', 'wrong-secret');
  const otherConsumer = await acceptInvitation(env, INVITE_ONE, 'carol', 'carol-secret');
  assert.equal(wrongConsumerSecret.status, 410);
  assert.equal(otherConsumer.status, 410);
  assert.deepEqual(wrongConsumerSecret.data, otherConsumer.data);
});

test('v2 accepts at most 16 machine identifiers per member', async () => {
  const env = makeEnv();
  await createRelationship(env);
  for (let index = 1; index <= 16; index += 1) {
    const result = await call(
      env,
      'POST',
      `/v2/relationships/${REL_DIRECT}/submit`,
      { machine_id: `machine-${index}`, days: [] },
      identity('alice', 'alice-secret'),
    );
    assert.equal(result.status, 200, `machine ${index}`);
  }
  const overflow = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'machine-17', days: [] },
    identity('alice', 'alice-secret'),
  );
  assert.equal(overflow.status, 409);
});

test('v2 derives legacy machine identifiers from committed record keys', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const memberKey = `v2:member:${REL_DIRECT}:alice`;
  const member = await env.__TEST_DO_STORAGE.get(memberKey);
  member.record_keys = [];
  for (let index = 1; index <= 16; index += 1) {
    const recordKey = `machine-${index}:2026-01-07`;
    member.record_keys.push(recordKey);
    await env.BRRRN_KV.put(
      `v2:day:${REL_DIRECT}:alice:${recordKey}`,
      JSON.stringify({ t: 1, c: 1, cc: 1, cx: 0, models: {} }),
    );
  }
  delete member.machine_ids;
  await env.__TEST_DO_STORAGE.put(memberKey, member);

  const existingMachine = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'machine-1', days: [sampleDay({ cost_usd: 2, claude_usd: 2 })] },
    identity('alice', 'alice-secret'),
  );
  assert.equal(existingMachine.status, 200);

  const overflow = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'machine-17', days: [] },
    identity('alice', 'alice-secret'),
  );
  assert.equal(overflow.status, 409);
});

test('v2 summary migration preserves current-week models from legacy records', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const memberKey = `v2:member:${REL_DIRECT}:alice`;
  const historyKey = `v2:cost-history:${REL_DIRECT}:alice`;
  const recordKey = 'laptop:2026-01-07';
  const member = await env.__TEST_DO_STORAGE.get(memberKey);
  member.machine_ids = ['laptop'];
  member.record_keys = [recordKey];
  await env.__TEST_DO_STORAGE.put(memberKey, member);
  await env.__TEST_DO_STORAGE.delete(historyKey);
  await env.BRRRN_KV.put(
    `v2:day:${REL_DIRECT}:alice:${recordKey}`,
    JSON.stringify({
      t: 100,
      c: 6,
      cc: 6,
      cx: 0,
      models: {
        'claude-fable-5': { i: 80, o: 20, c: 6 },
      },
    }),
  );

  const before = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(before.status, 200);
  assert.equal(before.data.members[0].top_model, 'claude-fable-5');

  const migrated = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: [] },
    identity('alice', 'alice-secret'),
  );
  assert.equal(migrated.status, 200);

  const after = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(after.status, 200);
  assert.deepEqual(after.data.members[0], before.data.members[0]);
});

test('v2 rolls the machine-day cap forward while allowing overwrites', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const first = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: datedDays(400) },
    identity('alice', 'alice-secret'),
  );
  assert.equal(first.status, 200);
  const second = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'desktop', days: datedDays(400) },
    identity('alice', 'alice-secret'),
  );
  assert.equal(second.status, 200);

  const overwrite = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: datedDays(1) },
    identity('alice', 'alice-secret'),
  );
  assert.equal(overwrite.status, 200);

  const rollover = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: datedDays(1, 400) },
    identity('alice', 'alice-secret'),
  );
  assert.equal(rollover.status, 200);
  const member = await env.__TEST_DO_STORAGE.get(`v2:member:${REL_DIRECT}:alice`);
  assert.equal(member.record_keys.length, 800);
  assert.equal(
    member.record_keys.some((key) => key.startsWith('desktop:2024-01-01:')),
    false,
  );
  const rolloverKey = member.record_keys.find(
    (key) => key.startsWith(`laptop:${datedDays(1, 400)[0].date}:`),
  );
  assert.ok(rolloverKey);
  assert.ok(await env.BRRRN_KV.get(`v2:day:${REL_DIRECT}:alice:${rolloverKey}`));
});

test('v2 leaves partial KV writes invisible and reconciles them on retry', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const dayPrefix = `v2:day:${REL_DIRECT}:alice:laptop:`;
  env.BRRRN_KV.failPutWithPrefixOn(dayPrefix, 2);

  const failed = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    {
      machine_id: 'laptop',
      days: [
        sampleDay({ date: '2026-01-06' }),
        sampleDay({ date: '2026-01-07' }),
      ],
    },
    identity('alice', 'alice-secret'),
  );
  assert.equal(failed.status, 503);

  const afterFailure = await env.__TEST_DO_STORAGE.get(`v2:member:${REL_DIRECT}:alice`);
  assert.deepEqual(afterFailure.record_keys, []);
  assert.equal(
    [...env.BRRRN_KV.store.keys()].filter((key) => key.startsWith(dayPrefix)).length,
    0,
  );
  const hiddenBoard = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(hiddenBoard.data.members[0].today_usd, 0);

  const retry = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    {
      machine_id: 'laptop',
      days: [
        sampleDay({ date: '2026-01-06' }),
        sampleDay({ date: '2026-01-07' }),
      ],
    },
    identity('alice', 'alice-secret'),
  );
  assert.equal(retry.status, 200);
  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(board.data.members[0].today_usd, 6);
  assert.equal(board.data.members[0].streak_days, 2);
});

test('v2 bounds orphan cleanup work and retains markers for later retries', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const dayPrefix = `v2:day:${REL_DIRECT}:alice:laptop:`;
  const cleanupPrefix = `v2:cleanup:${REL_DIRECT}:alice:`;
  env.BRRRN_KV.failPutWithPrefixOn(dayPrefix, 200);

  const failed = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: datedDays(400) },
    identity('alice', 'alice-secret'),
  );

  assert.equal(failed.status, 503);
  assert.equal(env.BRRRN_KV.deleteKeys.length, 200);
  assert.equal((await env.__TEST_DO_STORAGE.list({ prefix: cleanupPrefix })).size, 200);

  env.BRRRN_KV.deleteKeys = [];
  const firstRetry = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: [] },
    identity('alice', 'alice-secret'),
  );
  assert.equal(firstRetry.status, 200);
  assert.equal(env.BRRRN_KV.deleteKeys.length, 200);
  assert.equal((await env.__TEST_DO_STORAGE.list({ prefix: cleanupPrefix })).size, 0);
});

test('v2 cleanup keeps pace with repeated maximum-size overwrites', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const cleanupPrefix = `v2:cleanup:${REL_DIRECT}:alice:`;
  const days = datedDays(400);

  assert.equal((await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days },
    identity('alice', 'alice-secret'),
  )).status, 200);

  for (let overwrite = 1; overwrite <= 2; overwrite += 1) {
    env.BRRRN_KV.deleteKeys = [];
    assert.equal((await call(
      env,
      'POST',
      `/v2/relationships/${REL_DIRECT}/submit`,
      {
        machine_id: 'laptop',
        days: days.map((entry) => ({ ...entry, cost_usd: entry.cost_usd + overwrite })),
      },
      identity('alice', 'alice-secret'),
    )).status, 200);
    assert.ok(env.BRRRN_KV.deleteKeys.length <= 400);
    assert.equal((await env.__TEST_DO_STORAGE.list({ prefix: cleanupPrefix })).size, 200);
  }
});

test('v2 waits for late KV writes before draining a failed submission', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const dayPrefix = `v2:day:${REL_DIRECT}:alice:laptop:`;
  env.BRRRN_KV.failPutWithPrefixOn(dayPrefix, 1);
  env.BRRRN_KV.delayPutWithPrefixOn(dayPrefix, 2);

  const failed = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    {
      machine_id: 'laptop',
      days: [
        sampleDay({ date: '2026-01-06' }),
        sampleDay({ date: '2026-01-07' }),
      ],
    },
    identity('alice', 'alice-secret'),
  );
  assert.equal(failed.status, 503);
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(
    [...env.BRRRN_KV.store.keys()].filter((key) => key.startsWith(dayPrefix)).length,
    0,
  );
});

test('v2 refuses to finalize or serve when a committed KV record is unavailable', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const initial = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: [sampleDay({ cost_usd: 6 })] },
    identity('alice', 'alice-secret'),
  );
  assert.equal(initial.status, 200);
  const member = await env.__TEST_DO_STORAGE.get(`v2:member:${REL_DIRECT}:alice`);
  const fullKey = `v2:day:${REL_DIRECT}:alice:${member.record_keys[0]}`;

  env.BRRRN_KV.missNextGet(fullKey);
  const overwrite = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: [sampleDay({ cost_usd: 1, claude_usd: 1 })] },
    identity('alice', 'alice-secret'),
  );
  assert.equal(overwrite.status, 503);
  assert.deepEqual(
    await env.__TEST_DO_STORAGE.get(`v2:cost-history:${REL_DIRECT}:alice`),
    { '2026-01-07': 6 },
  );

  env.BRRRN_KV.missNextGet(fullKey);
  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(board.status, 200);
  assert.equal(board.data.members[0].today_usd, 6);
});

test('v2 member reads retry when a committed record version changes', async () => {
  const env = makeEnv();
  await createRelationship(env);
  await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: [sampleDay()] },
    identity('alice', 'alice-secret'),
  );
  const memberKey = `v2:member:${REL_DIRECT}:alice`;
  const member = await env.__TEST_DO_STORAGE.get(memberKey);
  const oldRecordKey = member.record_keys[0];
  const newRecordKey = 'laptop:2026-01-07:new-version';
  const newRecord = { t: 25, c: 1, cc: 1, cx: 0, models: {} };

  env.BRRRN_KV.runBeforeNextBulkGet(async () => {
    await env.BRRRN_KV.put(
      `v2:day:${REL_DIRECT}:alice:${newRecordKey}`,
      JSON.stringify(newRecord),
    );
    member.record_keys = [newRecordKey];
    await env.__TEST_DO_STORAGE.put(memberKey, member);
    await env.BRRRN_KV.delete(`v2:day:${REL_DIRECT}:alice:${oldRecordKey}`);
  });

  const result = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/member/alice`,
    undefined,
    identity('alice', 'alice-secret'),
  );

  assert.equal(result.status, 200);
  assert.deepEqual(result.data.days, [
    { date: '2026-01-07', tokens: 25, cost_usd: 1 },
  ]);
});

test('v2 ignores failed cleanup without exposing obsolete records', async () => {
  const env = makeEnv();
  await createRelationship(env);
  for (const machine_id of ['laptop', 'desktop']) {
    const submitted = await call(
      env,
      'POST',
      `/v2/relationships/${REL_DIRECT}/submit`,
      { machine_id, days: datedDays(400) },
      identity('alice', 'alice-secret'),
    );
    assert.equal(submitted.status, 200);
  }

  const before = await env.__TEST_DO_STORAGE.get(`v2:member:${REL_DIRECT}:alice`);
  const obsoleteKey = `v2:day:${REL_DIRECT}:alice:${before.record_keys[0]}`;
  env.BRRRN_KV.failNextDelete(obsoleteKey);
  const rollover = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: datedDays(1, 400) },
    identity('alice', 'alice-secret'),
  );
  assert.equal(rollover.status, 200);
  assert.ok(await env.BRRRN_KV.get(obsoleteKey));

  const member = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/member/alice`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(member.status, 200);
  assert.equal(
    member.data.days.find(({ date }) => date === '2024-01-01').cost_usd,
    6,
  );

  const cleanupRetry = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: [] },
    identity('alice', 'alice-secret'),
  );
  assert.equal(cleanupRetry.status, 200);
  assert.equal(await env.BRRRN_KV.get(obsoleteKey), null);
});

test('v2 preserves a multi-machine streak beyond raw record retention', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const days = daysEndingOn(801);
  for (const [machine_id, submittedDays] of [
    ['laptop', days.slice(0, 400)],
    ['desktop', days.slice(400, 800)],
    ['laptop', days.slice(800)],
  ]) {
    const submitted = await call(
      env,
      'POST',
      `/v2/relationships/${REL_DIRECT}/submit`,
      { machine_id, days: submittedDays },
      identity('alice', 'alice-secret'),
    );
    assert.equal(submitted.status, 200);
  }

  const member = await env.__TEST_DO_STORAGE.get(`v2:member:${REL_DIRECT}:alice`);
  assert.equal(member.record_keys.length, 800);
  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(board.data.members[0].streak_days, 801);
});

test('v2 submit deterministically keeps the last duplicate date', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const submitted = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    {
      machine_id: 'laptop',
      days: [
        sampleDay({ tokens: 10, cost_usd: 1, claude_usd: 1 }),
        sampleDay({ tokens: 90, cost_usd: 9, claude_usd: 9 }),
      ],
    },
    identity('alice', 'alice-secret'),
  );
  assert.equal(submitted.status, 200);
  assert.equal(submitted.data.days_stored, 1);

  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(board.data.members[0].today_usd, 9);
});

test('v2 submit rejects dates outside the supported history window', async () => {
  const env = makeEnv();
  await createRelationship(env);
  for (const date of ['2019-12-31', '2026-01-08', '2026-01-09']) {
    const result = await call(
      env,
      'POST',
      `/v2/relationships/${REL_DIRECT}/submit`,
      { machine_id: 'laptop', days: [sampleDay({ date })] },
      identity('alice', 'alice-secret'),
    );
    assert.equal(result.status, 400, date);
  }
});

test('v2 board uses committed summaries without reading raw KV records', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const submitted = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    {
      machine_id: 'laptop',
      days: [
        sampleDay({ date: '2024-01-01' }),
        sampleDay({ date: '2026-01-07' }),
      ],
    },
    identity('alice', 'alice-secret'),
  );
  assert.equal(submitted.status, 200);
  env.BRRRN_KV.bulkGetKeys = [];

  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(board.status, 200);
  assert.equal(board.data.members[0].month_usd, 6);
  assert.deepEqual(env.BRRRN_KV.bulkGetKeys, []);
});

test('v2 board includes prior-month days from the current ISO week', async () => {
  const env = makeEnv();
  env.__TEST_NOW = '2026-01-01T12:00:00Z';
  await createRelationship(env);
  const submitted = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    {
      machine_id: 'laptop',
      days: [
        sampleDay({ date: '2025-12-31', cost_usd: 6, claude_usd: 6 }),
        sampleDay({ date: '2026-01-01', cost_usd: 7, claude_usd: 7 }),
      ],
    },
    identity('alice', 'alice-secret'),
  );
  assert.equal(submitted.status, 200);
  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(board.data.members[0].today_usd, 7);
  assert.equal(board.data.members[0].week_usd, 13);
  assert.equal(board.data.members[0].month_usd, 7);
});

test('v2 submit, board, and member routes require membership and aggregate multiple machines', async () => {
  const env = makeEnv();
  await createRelationship(env, {
    relationshipId: REL_GROUP,
    type: 'group',
    name: 'multi machine',
  });
  await createInvitation(env, REL_GROUP, INVITE_ONE);
  await acceptInvitation(env, INVITE_ONE, 'bob', 'bob-secret');

  const unauthenticated = await call(env, 'GET', `/v2/relationships/${REL_GROUP}/board`);
  assert.equal(unauthenticated.status, 401);

  const nonmember = await call(
    env,
    'GET',
    `/v2/relationships/${REL_GROUP}/board`,
    undefined,
    identity('mallory', 'mallory-secret'),
  );
  assert.equal(nonmember.status, 401);

  for (const [machineId, tokens, cost] of [
    ['laptop', 100, 6],
    ['desktop', 50, 4],
  ]) {
    const submitted = await call(
      env,
      'POST',
      `/v2/relationships/${REL_GROUP}/submit`,
      { machine_id: machineId, days: [sampleDay({ tokens, cost_usd: cost, claude_usd: cost })] },
      identity('alice', 'alice-secret'),
    );
    assert.equal(submitted.status, 200);
  }

  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_GROUP}/board`,
    undefined,
    identity('bob', 'bob-secret'),
  );
  assert.equal(board.status, 200);
  const alice = board.data.members.find((member) => member.handle === 'alice');
  assert.equal(alice.today_usd, 10);
  assert.equal(alice.week_usd, 10);
  assert.equal(alice.month_usd, 10);
  assert.equal(alice.streak_days, 1);
  assert.equal(alice.top_model, 'claude-fable-5');
  assert.deepEqual(alice.models_week, [
    { model: 'claude-fable-5', input_tokens: 160, output_tokens: 40, cost_usd: 12 },
  ]);

  const member = await call(
    env,
    'GET',
    `/v2/relationships/${REL_GROUP}/member/alice`,
    undefined,
    identity('bob', 'bob-secret'),
  );
  assert.equal(member.status, 200);
  assert.deepEqual(member.data.days, [
    { date: '2026-01-07', tokens: 150, cost_usd: 10 },
  ]);
});

test('v2 cost history stays idempotent at the streak threshold', async () => {
  const env = makeEnv();
  await createRelationship(env);
  for (const [machine_id, cost_usd] of [['laptop', 3.04], ['desktop', 1.96]]) {
    const submitted = await call(
      env,
      'POST',
      `/v2/relationships/${REL_DIRECT}/submit`,
      { machine_id, days: [sampleDay({ cost_usd, claude_usd: cost_usd })] },
      identity('alice', 'alice-secret'),
    );
    assert.equal(submitted.status, 200);
  }
  const retry = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: [sampleDay({ cost_usd: 3.04, claude_usd: 3.04 })] },
    identity('alice', 'alice-secret'),
  );
  assert.equal(retry.status, 200);
  assert.deepEqual(
    await env.__TEST_DO_STORAGE.get(`v2:cost-history:${REL_DIRECT}:alice`),
    { '2026-01-07': 5 },
  );
  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(board.data.members[0].streak_days, 1);
});

test('v2 canonicalizes costs before board and member aggregation', async () => {
  const env = makeEnv();
  await createRelationship(env);
  for (const machine_id of ['laptop', 'desktop']) {
    const submitted = await call(
      env,
      'POST',
      `/v2/relationships/${REL_DIRECT}/submit`,
      {
        machine_id,
        days: [sampleDay({
          cost_usd: 2.4999996,
          claude_usd: 2.4999996,
        })],
      },
      identity('alice', 'alice-secret'),
    );
    assert.equal(submitted.status, 200);
  }

  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(board.status, 200);
  assert.equal(board.data.members[0].today_usd, 5);
  assert.equal(board.data.members[0].streak_days, 1);

  const member = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/member/alice`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(member.status, 200);
  assert.deepEqual(member.data.days, [
    { date: '2026-01-07', tokens: 200, cost_usd: 5 },
  ]);
});

test('v2 responses are private, no-store, and expose required CORS headers', async () => {
  const env = makeEnv();
  const created = await createRelationship(env);
  assert.equal(created.status, 200);
  assert.equal(created.headers.get('access-control-allow-origin'), '*');
  assert.equal(created.headers.get('cache-control'), 'private, no-store');

  const board = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/board`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(board.status, 200);
  assert.equal(board.headers.get('access-control-allow-origin'), '*');
  assert.equal(board.headers.get('cache-control'), 'private, no-store');

  const preflight = await call(env, 'OPTIONS', `/v2/relationships/${REL_DIRECT}/submit`);
  assert.equal(preflight.status, 204);
  const allowedHeaders = preflight.headers.get('access-control-allow-headers').toLowerCase();
  for (const header of ['content-type', 'authorization', 'x-brrrn-handle']) {
    assert.ok(allowedHeaders.includes(header), `missing ${header}`);
  }
});

test('v2 body routes reject valid JSON values that are not objects', async () => {
  const env = makeEnv();
  await createRelationship(env);
  await createInvitation(env, REL_DIRECT, INVITE_ONE);
  const routes = [
    ['/v2/relationships', identity('alice', 'alice-secret')],
    [`/v2/relationships/${REL_DIRECT}/invitations`, identity('alice', 'alice-secret')],
    ['/v2/invitations/preview', {}],
    ['/v2/invitations/accept', identity('bob', 'bob-secret')],
    [`/v2/relationships/${REL_DIRECT}/submit`, identity('alice', 'alice-secret')],
  ];
  for (const [path, headers] of routes) {
    for (const body of ['null', '[]', '"text"', '42']) {
      const result = await call(env, 'POST', path, body, headers);
      assert.equal(result.status, 400, `${path} ${body}`);
      assert.equal(result.data.error, 'JSON body must be an object');
    }
  }
});

test('v2 malformed member path encoding returns a private JSON error', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const result = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/member/%`,
    undefined,
    identity('alice', 'alice-secret'),
  );
  assert.equal(result.status, 400);
  assert.equal(result.data.error, 'invalid path encoding');
  assert.equal(result.headers.get('cache-control'), 'private, no-store');
});

test('v2 relationship creation is rate limited per client address', async () => {
  const env = makeEnv();
  const headers = {
    ...identity('alice', 'alice-secret'),
    'cf-connecting-ip': '203.0.113.45',
  };
  for (let index = 1; index <= 20; index += 1) {
    const result = await call(
      env,
      'POST',
      '/v2/relationships',
      { relationship_id: relationshipId(index), type: 'direct' },
      headers,
    );
    assert.equal(result.status, 200, `relationship ${index}`);
  }
  const blocked = await call(
    env,
    'POST',
    '/v2/relationships',
    { relationship_id: relationshipId(21), type: 'direct' },
    headers,
  );
  assert.equal(blocked.status, 429);
});

test('v2 rate counters use strongly consistent Durable Object storage', async () => {
  const env = makeEnv();
  const ip = '203.0.113.46';
  const headers = {
    ...identity('alice', 'alice-secret'),
    'cf-connecting-ip': ip,
  };
  const created = await call(
    env,
    'POST',
    '/v2/relationships',
    { relationship_id: relationshipId(1), type: 'direct' },
    headers,
  );
  assert.equal(created.status, 200);
  const key = `v2:ratelimit:create:${ip}`;
  assert.equal(env.BRRRN_KV.store.has(key), false);
  assert.deepEqual(await env.__TEST_DO_STORAGE.get(key), {
    count: 1,
    reset_at: Date.parse(NOW) + 3600 * 1000,
  });
});

test('v2 rate windows reset at the original boundary', async () => {
  const env = makeEnv();
  const headers = {
    ...identity('alice', 'alice-secret'),
    'cf-connecting-ip': '203.0.113.48',
  };
  assert.equal((await call(
    env,
    'POST',
    '/v2/relationships',
    { relationship_id: relationshipId(1), type: 'direct' },
    headers,
  )).status, 200);

  env.__TEST_NOW = '2026-01-07T12:59:59Z';
  for (let index = 2; index <= 20; index += 1) {
    assert.equal((await call(
      env,
      'POST',
      '/v2/relationships',
      { relationship_id: relationshipId(index), type: 'direct' },
      headers,
    )).status, 200);
  }

  env.__TEST_NOW = '2026-01-07T13:00:00Z';
  assert.equal((await call(
    env,
    'POST',
    '/v2/relationships',
    { relationship_id: relationshipId(21), type: 'direct' },
    headers,
  )).status, 200);
});

test('v2 member read rate limiting is atomic under concurrency', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const headers = {
    ...identity('alice', 'alice-secret'),
    'cf-connecting-ip': '203.0.113.47',
  };
  const results = [];
  for (let batch = 0; batch < 30; batch += 1) {
    results.push(...await Promise.all(Array.from({ length: 2 }, () => call(
      env,
      'GET',
      `/v2/relationships/${REL_DIRECT}/member/alice`,
      undefined,
      headers,
    ))));
  }
  results.push(await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/member/alice`,
    undefined,
    headers,
  ));
  assert.equal(results.filter(({ status }) => status === 200).length, 60);
  assert.equal(results.filter(({ status }) => status === 429).length, 1);
});

test('coordinator bounds the rate-admission backlog per client', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const ip = '203.0.113.49';
  const release = env.__TEST_DO_STORAGE.blockNextGet(`v2:ratelimit:read:${ip}`);
  const requests = Array.from({ length: 10 }, () => call(
    env,
    'GET',
    '/v2/not-found',
    undefined,
    { 'cf-connecting-ip': ip },
  ));
  await new Promise((resolve) => setImmediate(resolve));
  release();
  const results = await Promise.all(requests);

  assert.equal(results.filter(({ status }) => status === 404).length, 8);
  assert.equal(results.filter(({ status }) => status === 503).length, 2);
  assert.ok(results.filter(({ status }) => status === 503).every(
    ({ headers }) => headers.get('retry-after') === '1',
  ));
});

test('coordinator reads stalled v2 bodies before entering the mutation queue', async () => {
  const env = makeEnv();
  const slow = stalledJsonPost('/v2/relationships', {
    ...identity('alice', 'alice-secret'),
    'cf-connecting-ip': '203.0.113.50',
  });
  const slowPromise = callRequest(env, slow.request);
  await new Promise((resolve) => setImmediate(resolve));

  const fastPromise = call(
    env,
    'POST',
    '/v2/relationships',
    { relationship_id: relationshipId(301), type: 'direct' },
    {
      ...identity('alice', 'alice-secret'),
      'cf-connecting-ip': '203.0.113.51',
    },
  );
  const quickResult = await Promise.race([
    fastPromise,
    new Promise((resolve) => setTimeout(() => resolve(null), 50)),
  ]);

  slow.release({ relationship_id: relationshipId(300), type: 'direct' });
  const [slowResult, fastResult] = await Promise.all([slowPromise, fastPromise]);
  assert.equal(slowResult.status, 200);
  assert.equal(fastResult.status, 200);
  assert.equal(quickResult?.status, 200);
});

test('coordinator bounds concurrent v2 body readers per client', async () => {
  const env = makeEnv();
  const ip = '203.0.113.52';
  const streams = Array.from({ length: 5 }, (_, index) => stalledJsonPost(
    '/v2/relationships',
    {
      ...identity('alice', 'alice-secret'),
      'cf-connecting-ip': ip,
    },
  ));
  const active = streams.slice(0, 4).map((stream) => callRequest(env, stream.request));
  await new Promise((resolve) => setImmediate(resolve));

  const overflowPromise = callRequest(env, streams[4].request);
  const overflow = await Promise.race([
    overflowPromise,
    new Promise((resolve) => setTimeout(() => resolve(null), 50)),
  ]);

  streams.forEach((stream, index) => stream.release({
    relationship_id: relationshipId(310 + index),
    type: 'direct',
  }));
  await Promise.all([...active, overflowPromise]);
  assert.equal(overflow?.status, 503);
  assert.equal(overflow?.headers.get('retry-after'), '1');
});

test('coordinator bounds total concurrent v2 body readers', async () => {
  const env = makeEnv();
  const streams = Array.from({ length: 17 }, (_, index) => stalledJsonPost(
    '/v2/relationships',
    {
      ...identity('alice', 'alice-secret'),
      'cf-connecting-ip': `203.0.115.${Math.floor(index / 4) + 1}`,
    },
  ));
  const active = streams.slice(0, 16).map((stream) => callRequest(env, stream.request));
  await new Promise((resolve) => setImmediate(resolve));

  const overflowPromise = callRequest(env, streams[16].request);
  const overflow = await Promise.race([
    overflowPromise,
    new Promise((resolve) => setTimeout(() => resolve(null), 50)),
  ]);

  streams.forEach((stream, index) => stream.release({
    relationship_id: relationshipId(320 + index),
    type: 'direct',
  }));
  await Promise.all([...active, overflowPromise]);
  assert.equal(overflow?.status, 503);
  assert.equal(overflow?.headers.get('retry-after'), '1');
});

test('coordinator cancels v2 body reads that exceed the deadline', async () => {
  const env = makeEnv();
  env.__TEST_BODY_READ_TIMEOUT_MS = 20;
  const slow = stalledJsonPost('/v2/relationships', {
    ...identity('alice', 'alice-secret'),
    'cf-connecting-ip': '203.0.113.53',
  });
  const responsePromise = callRequest(env, slow.request);
  const response = await Promise.race([
    responsePromise,
    new Promise((resolve) => setTimeout(() => resolve(null), 100)),
  ]);

  if (!response) {
    slow.release({ relationship_id: relationshipId(340), type: 'direct' });
    await responsePromise;
  }
  assert.equal(response?.status, 408);
  assert.equal(response?.data.error, 'request body timed out');
  assert.equal(slow.wasCancelled(), true);
});

test('coordinator cancels oversized declared v2 bodies', async () => {
  const env = makeEnv();
  const slow = stalledJsonPost('/v2/relationships', {
    ...identity('alice', 'alice-secret'),
    'content-length': String(256 * 1024 + 1),
  });
  const response = await callRequest(env, slow.request);
  assert.equal(response.status, 413);
  assert.equal(response.data.error, 'request body too large');
  assert.equal(slow.wasCancelled(), true);
});

test('coordinator rejects non-byte request stream chunks cleanly', async () => {
  const env = makeEnv();
  const request = new Request('https://brrrn-hub.test/v2/relationships', {
    method: 'POST',
    headers: identity('alice', 'alice-secret'),
    body: new ReadableStream({
      start(controller) {
        controller.enqueue('not bytes');
        controller.close();
      },
    }),
    duplex: 'half',
  });
  const response = await callRequest(env, request);
  assert.equal(response.status, 400);
  assert.equal(response.data.error, 'request body unavailable');
});

test('coordinator applies body deadlines to legacy posts', async () => {
  const env = makeEnv();
  env.__TEST_BODY_READ_TIMEOUT_MS = 20;
  const slow = stalledJsonPost('/pit');
  const responsePromise = callRequest(env, slow.request);
  const response = await Promise.race([
    responsePromise,
    new Promise((resolve) => setTimeout(() => resolve(null), 100)),
  ]);
  if (!response) {
    slow.release({});
    await responsePromise;
  }
  assert.equal(response?.status, 408);
  assert.equal(response?.data.error, 'request body timed out');
  assert.equal(slow.wasCancelled(), true);
});

test('coordinator applies per-client body reader caps to legacy posts', async () => {
  const env = makeEnv();
  const streams = Array.from({ length: 5 }, () => stalledJsonPost('/pit', {
    'cf-connecting-ip': '203.0.113.56',
  }));
  const active = streams.slice(0, 4).map((stream) => callRequest(env, stream.request));
  await new Promise((resolve) => setImmediate(resolve));

  const overflowPromise = callRequest(env, streams[4].request);
  const overflow = await Promise.race([
    overflowPromise,
    new Promise((resolve) => setTimeout(() => resolve(null), 50)),
  ]);
  streams.forEach((stream, index) => stream.release({ name: `pit ${index}` }));
  await Promise.all([...active, overflowPromise]);
  assert.equal(overflow?.status, 503);
});

test('coordinator bounds concurrent v2 member history reads', async () => {
  const env = makeEnv();
  await createRelationship(env);
  assert.equal((await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: [sampleDay()] },
    identity('alice', 'alice-secret'),
  )).status, 200);

  const release = env.BRRRN_KV.blockNextBulkGets(2);
  const headers = identity('alice', 'alice-secret');
  const active = Array.from({ length: 2 }, () => call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/member/alice`,
    undefined,
    headers,
  ));
  await new Promise((resolve) => setImmediate(resolve));

  const overflow = await call(
    env,
    'GET',
    `/v2/relationships/${REL_DIRECT}/member/alice`,
    undefined,
    headers,
  );
  release();
  assert.equal(overflow.status, 503);
  assert.equal(overflow.headers.get('retry-after'), '1');
  assert.ok((await Promise.all(active)).every(({ status }) => status === 200));
});

test('legacy submissions do not occupy the v2 mutation queue', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'legacy isolation');
  await join(env, code, 'alice', 'legacy-secret');
  env.BRRRN_KV.delayPutWithPrefixOn(`day:${code}:alice:laptop:`, 1, 100);

  const legacyPromise = call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 'legacy-secret',
    machine_id: 'laptop',
    days: [sampleDay()],
  });
  await new Promise((resolve) => setImmediate(resolve));

  const v2Promise = call(
    env,
    'POST',
    '/v2/relationships',
    { relationship_id: relationshipId(350), type: 'direct' },
    identity('alice', 'alice-secret'),
  );
  const quickResult = await Promise.race([
    v2Promise,
    new Promise((resolve) => setTimeout(() => resolve(null), 30)),
  ]);

  assert.equal((await legacyPromise).status, 200);
  assert.equal((await v2Promise).status, 200);
  assert.equal(quickResult?.status, 200);
});

test('legacy submit attempts are rate limited before parsing', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'legacy attempts');
  const headers = { 'cf-connecting-ip': '203.0.113.54' };
  for (let index = 0; index < 120; index += 1) {
    assert.equal((await call(
      env,
      'POST',
      `/pit/${code}/submit`,
      '{malformed',
      headers,
    )).status, 400);
  }
  assert.equal((await call(
    env,
    'POST',
    `/pit/${code}/submit`,
    '{malformed',
    headers,
  )).status, 429);
});

test('legacy submitted record units are rate limited', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'legacy records');
  await join(env, code, 'alice', 'legacy-secret');
  const headers = { 'cf-connecting-ip': '203.0.113.55' };
  for (let index = 0; index < 3; index += 1) {
    assert.equal((await call(env, 'POST', `/pit/${code}/submit`, {
      handle: 'alice',
      secret: 'legacy-secret',
      machine_id: `machine-${index}`,
      days: datedDays(400),
    }, headers)).status, 200);
  }
  assert.equal((await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 'legacy-secret',
    machine_id: 'machine-overflow',
    days: [sampleDay()],
  }, headers)).status, 429);
});

test('coordinator bounds the pending mutation backlog', async () => {
  const env = makeEnv();
  await createRelationship(env);
  const dayPrefix = `v2:day:${REL_DIRECT}:alice:laptop:`;
  env.BRRRN_KV.delayPutWithPrefixOn(dayPrefix, 1, 200);

  const results = await Promise.all(Array.from({ length: 40 }, (_, index) => call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    { machine_id: 'laptop', days: [sampleDay()] },
    {
      ...identity('alice', 'alice-secret'),
      'cf-connecting-ip': `203.0.114.${index + 1}`,
    },
  )));

  assert.equal(results.filter(({ status }) => status === 200).length, 32);
  assert.equal(results.filter(({ status }) => status === 503).length, 8);
});

test('v2 submit attempts are limited before authentication and parsing', async () => {
  const env = makeEnv();
  const headers = {
    ...identity('mallory', 'wrong-secret'),
    'cf-connecting-ip': '203.0.113.46',
  };
  for (let index = 0; index < 120; index += 1) {
    const result = await call(
      env,
      'POST',
      `/v2/relationships/${REL_DIRECT}/submit`,
      '{malformed',
      headers,
    );
    assert.equal(result.status, 401, `attempt ${index}`);
  }
  const blocked = await call(
    env,
    'POST',
    `/v2/relationships/${REL_DIRECT}/submit`,
    '{malformed',
    headers,
  );
  assert.equal(blocked.status, 429);
});

test('legacy pit routes remain unauthenticated and keep their existing response contract', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'legacy');
  assert.equal((await join(env, code, 'alice', 'legacy-secret')).status, 200);
  assert.equal((await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 'legacy-secret',
    machine_id: 'laptop',
    days: [sampleDay()],
  })).status, 200);

  const board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.status, 200);
  assert.equal(board.data.code, code);
  assert.equal(board.data.name, 'legacy');
  assert.equal(board.data.members[0].handle, 'alice');
  assert.equal(board.headers.get('cache-control'), null);

  const member = await call(env, 'GET', `/pit/${code}/member/alice`);
  assert.equal(member.status, 200);
  assert.deepEqual(member.data.days, [
    { date: '2026-01-07', tokens: 100, cost_usd: 6 },
  ]);
});

test('legacy boards do not truncate weekly model rows', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'legacy models');
  await join(env, code, 'alice', 'secret');
  const days = ['2026-01-06', '2026-01-07'].map((date, dayIndex) => ({
    date,
    tokens: 25,
    cost_usd: 25,
    models: Object.fromEntries(Array.from({ length: 25 }, (_, modelIndex) => [
      `model-${dayIndex}-${modelIndex}`,
      { input_tokens: 1, output_tokens: 0, cost_usd: 1 },
    ])),
  }));
  const submitted = await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 'secret',
    machine_id: 'laptop',
    days,
  });
  assert.equal(submitted.status, 200);
  const board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.data.members[0].models_week.length, 50);
});

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

test('legacy board serves migrated members from summaries without scanning day history', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'summary reads');
  for (const handle of ['alice', 'bob', 'carol']) {
    await join(env, code, handle, 's');
    await call(env, 'POST', `/pit/${code}/submit`, {
      handle,
      secret: 's',
      machine_id: 'laptop',
      days: [sampleDay()],
    });
  }

  env.BRRRN_KV.listPrefixes = [];
  env.BRRRN_KV.bulkGetKeys = [];
  const board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.status, 200);
  assert.equal(board.data.members.length, 3);
  assert.deepEqual(board.data.members.map((m) => m.today_usd), [6, 6, 6]);

  // The whole point of the summary: a board read touches member metadata and
  // the Durable Object summaries, never a member's day-record history in KV.
  assert.equal(
    env.BRRRN_KV.listPrefixes.some((prefix) => prefix.startsWith(`day:${code}:`)),
    false,
  );
  assert.equal(
    env.BRRRN_KV.bulkGetKeys.some((key) => key.startsWith(`day:${code}:`)),
    false,
  );
  // Summaries and the migrated markers live in Durable Object storage, not KV.
  const summaryKeys = [...env.__TEST_DO_STORAGE.store.keys()];
  assert.ok(summaryKeys.includes(`bsum:migrated:${code}:alice`));
  assert.ok(summaryKeys.includes(`bsum:machine:${code}:alice:laptop`));
});

function seedDayRecord(env, code, handle, machine, date, rec) {
  env.BRRRN_KV.store.set(
    `day:${code}:${handle}:${machine}:${date}`,
    JSON.stringify({ t: 0, cc: 0, cx: 0, models: {}, ...rec }),
  );
}

test('legacy board falls back to a full scan for members without a summary yet', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'pre-summary data');
  await join(env, code, 'alice', 's');
  // Simulate history written before summaries shipped: day records exist but
  // no summary. The board must still be correct via the one-off scan.
  seedDayRecord(env, code, 'alice', 'laptop', '2026-01-06', { c: 6 });
  seedDayRecord(env, code, 'alice', 'laptop', '2026-01-07', { c: 10 });

  const board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.status, 200);
  assert.equal(board.data.members[0].today_usd, 10);
  assert.equal(board.data.members[0].week_usd, 16);
  // No summary yet, so the fallback scan does read day history.
  assert.equal(
    env.BRRRN_KV.listPrefixes.some((prefix) => prefix.startsWith(`day:${code}:`)),
    true,
  );
});

test('first submit migrates the whole member, capturing machines that never re-submit', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'multi-machine migration');
  await join(env, code, 'alice', 's');
  // Two machines' worth of pre-summary history.
  seedDayRecord(env, code, 'alice', 'laptop', '2026-01-06', { c: 6 });
  seedDayRecord(env, code, 'alice', 'laptop', '2026-01-07', {
    c: 10,
    models: { 'claude-fable-5': { i: 80, o: 20, c: 10 } },
  });
  seedDayRecord(env, code, 'alice', 'desktop', '2026-01-07', { c: 4 });

  // Only the laptop re-submits (re-stating a value it already had). The whole
  // member is migrated, so the desktop's untouched history is preserved.
  const submitted = await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 's',
    machine_id: 'laptop',
    days: [{ date: '2026-01-07', tokens: 80, cost_usd: 10, claude_usd: 10, codex_usd: 0,
      models: { 'claude-fable-5': { input_tokens: 80, output_tokens: 20, cost_usd: 10 } } }],
  });
  assert.equal(submitted.status, 200);

  env.BRRRN_KV.listPrefixes = [];
  env.BRRRN_KV.bulkGetKeys = [];
  const board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.data.members[0].today_usd, 14);
  assert.equal(board.data.members[0].week_usd, 20);
  // Now migrated: no day-record reads on the board.
  assert.equal(
    env.BRRRN_KV.listPrefixes.some((prefix) => prefix.startsWith(`day:${code}:`)),
    false,
  );
  assert.equal(
    env.BRRRN_KV.bulkGetKeys.some((key) => key.startsWith(`day:${code}:`)),
    false,
  );
});

test('summary retains full cost history for long streaks without scanning', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'deep streak');
  await join(env, code, 'alice', 's');
  // 40 consecutive UTC days ending today, each above the streak threshold.
  const submitted = await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 's',
    machine_id: 'laptop',
    days: daysEndingOn(40, '2026-01-07'),
  });
  assert.equal(submitted.status, 200);

  env.BRRRN_KV.listPrefixes = [];
  const board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.data.members[0].streak_days, 40);
  assert.equal(
    env.BRRRN_KV.listPrefixes.some((prefix) => prefix.startsWith(`day:${code}:`)),
    false,
  );
});

test('week rollover drops stale model rows but keeps cost history for the month', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'rollover');
  await join(env, code, 'alice', 's');
  await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 's',
    machine_id: 'laptop',
    days: [{ date: '2026-01-07', tokens: 100, cost_usd: 10, claude_usd: 10, codex_usd: 0,
      models: { 'old-week-model': { input_tokens: 10, output_tokens: 1, cost_usd: 10 } } }],
  });

  // Jump to the next ISO week (Mon 2026-01-12 .. Sun 2026-01-18); now is Wed.
  env.__TEST_NOW = '2026-01-14T12:00:00Z';
  await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 's',
    machine_id: 'laptop',
    days: [{ date: '2026-01-14', tokens: 50, cost_usd: 5, claude_usd: 5, codex_usd: 0,
      models: { 'new-week-model': { input_tokens: 5, output_tokens: 1, cost_usd: 5 } } }],
  });

  const board = await call(env, 'GET', `/pit/${code}/board`);
  const alice = board.data.members[0];
  assert.equal(alice.today_usd, 5);
  assert.equal(alice.week_usd, 5);
  assert.equal(alice.month_usd, 15);
  assert.equal(alice.top_model, 'new-week-model');
  assert.deepEqual(alice.models_week.map((m) => m.model), ['new-week-model']);
});

test('re-submitting a date overwrites its own contribution instead of double-counting', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'idempotent');
  await join(env, code, 'alice', 's');
  const body = {
    handle: 'alice',
    secret: 's',
    machine_id: 'laptop',
    days: [sampleDay()],
  };
  await call(env, 'POST', `/pit/${code}/submit`, body);
  // The same payload twice must not double the day's cost.
  await call(env, 'POST', `/pit/${code}/submit`, body);
  let board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.data.members[0].today_usd, 6);

  // A changed value replaces the previous one.
  await call(env, 'POST', `/pit/${code}/submit`, {
    ...body,
    days: [sampleDay({ cost_usd: 9, claude_usd: 9 })],
  });
  board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.data.members[0].today_usd, 9);
});

test('legacy submit rejects future-dated records', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'no future');
  await join(env, code, 'alice', 's');
  const future = await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 's',
    machine_id: 'laptop',
    days: [sampleDay({ date: '2026-01-08' })],
  });
  assert.equal(future.status, 400);
  // Today is still accepted.
  const ok = await call(env, 'POST', `/pit/${code}/submit`, {
    handle: 'alice',
    secret: 's',
    machine_id: 'laptop',
    days: [sampleDay()],
  });
  assert.equal(ok.status, 200);
});

test('any member can retitle a pit; outsiders and impostors cannot', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'old name');
  assert.equal((await join(env, code, 'alice', 'sa')).status, 200);
  assert.equal((await join(env, code, 'bob', 'sb')).status, 200);

  const renamed = await call(env, 'POST', `/pit/${code}/rename`, {
    handle: 'bob', secret: 'sb', name: '  night shift  ',
  });
  assert.equal(renamed.status, 200);
  const board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.data.name, 'night shift');

  assert.equal((await call(env, 'POST', `/pit/${code}/rename`, {
    handle: 'alice', secret: 'wrong', name: 'hijack',
  })).status, 401);
  assert.equal((await call(env, 'POST', `/pit/${code}/rename`, {
    handle: 'ghost', secret: 'x', name: 'hijack',
  })).status, 404);
  assert.equal((await call(env, 'POST', `/pit/${code}/rename`, {
    handle: 'alice', secret: 'sa', name: '',
  })).status, 400);
  assert.equal((await call(env, 'POST', `/pit/${code}/rename`, {
    handle: 'alice', secret: 'sa', name: 'x'.repeat(81),
  })).status, 400);
});

test('display names are cosmetic, editable, and never identity', async () => {
  const env = makeEnv();
  const code = await createPit(env, 'names');

  const joined = await call(env, 'POST', `/pit/${code}/join`, {
    handle: 'kevin', secret: 's1', display_name: '  Kevin the Flame  ',
  });
  assert.equal(joined.status, 200);

  let board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.data.members[0].display_name, 'Kevin the Flame');

  // Re-join with the same secret renames; a different secret still conflicts.
  const renamed = await call(env, 'POST', `/pit/${code}/join`, {
    handle: 'kevin', secret: 's1', display_name: 'K-dawg',
  });
  assert.equal(renamed.status, 200);
  const impostor = await call(env, 'POST', `/pit/${code}/join`, {
    handle: 'kevin', secret: 'other', display_name: 'Impostor',
  });
  assert.equal(impostor.status, 409);

  // Re-join without a display name keeps the existing one.
  const keep = await call(env, 'POST', `/pit/${code}/join`, { handle: 'kevin', secret: 's1' });
  assert.equal(keep.status, 200);
  board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.data.members[0].display_name, 'K-dawg');

  // Members without one report null; invalid names are rejected.
  assert.equal((await join(env, code, 'plain', 's2')).status, 200);
  board = await call(env, 'GET', `/pit/${code}/board`);
  const plain = board.data.members.find((m) => m.handle === 'plain');
  assert.equal(plain.display_name, null);
  const bad = await call(env, 'POST', `/pit/${code}/join`, {
    handle: 'toolong', secret: 's3', display_name: 'x'.repeat(33),
  });
  assert.equal(bad.status, 400);
});

test('PIT_CREATE_TOKEN gates creation but never joining', async () => {
  const env = makeEnv();
  env.PIT_CREATE_TOKEN = 'crew-only';

  const missing = await call(env, 'POST', '/pit', { name: 'open' });
  assert.equal(missing.status, 403);
  const wrong = await call(env, 'POST', '/pit', { name: 'open', create_token: 'guess' });
  assert.equal(wrong.status, 403);

  const ok = await call(env, 'POST', '/pit', { name: 'open', create_token: 'crew-only' });
  assert.equal(ok.status, 200);
  const joined = await join(env, ok.data.code, 'alice', 's3cret');
  assert.equal(joined.status, 200);
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
  // The board summary is a read-modify-write on one KV object; the Coordinator
  // serializes legacy mutations, so neither concurrent date is lost from it.
  const board = await call(env, 'GET', `/pit/${code}/board`);
  assert.equal(board.data.members[0].today_usd, 7);
  assert.equal(board.data.members[0].week_usd, 13);
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

test('submit enforces the 256KB limit by UTF-8 bytes without content-length', async () => {
  const env = makeEnv();
  const code = await createPit(env);
  await join(env, code, 'alice', 's');
  const body = JSON.stringify({
    handle: 'alice', secret: 's', machine_id: 'm1', days: [], padding: '火'.repeat(90 * 1024),
  });
  assert.ok(body.length < 256 * 1024);
  const request = new Request(`https://brrrn-hub.test/pit/${code}/submit`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body,
  });
  assert.equal(request.headers.get('content-length'), null);
  const response = await worker.fetch(request, env, {});
  assert.equal(response.status, 413);
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

test('legacy join rate window does not slide on late allowed requests', async () => {
  const env = makeEnv();
  const code = await createPit(env);
  const ip = { 'cf-connecting-ip': '203.0.113.91' };
  assert.equal((await call(
    env,
    'POST',
    `/pit/${code}/join`,
    { handle: 'window0', secret: 's' },
    ip,
  )).status, 200);

  env.__TEST_NOW = '2026-01-07T12:00:59Z';
  for (let index = 1; index < 10; index += 1) {
    const result = await call(
      env,
      'POST',
      `/pit/${code}/join`,
      { handle: `window${index}`, secret: 's' },
      ip,
    );
    assert.equal(result.status, 200);
  }

  env.__TEST_NOW = '2026-01-07T12:01:00Z';
  assert.equal((await call(
    env,
    'POST',
    `/pit/${code}/join`,
    { handle: 'window10', secret: 's' },
    ip,
  )).status, 200);
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
