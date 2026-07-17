import {
  aggregateMember,
  computeStreak,
  generateJoinCode,
  isoWeekStart,
  MAX_MODELS_PER_MEMBER_RESPONSE,
  memberSeries,
  monthStart,
  normalizeHandle,
  stableCost,
  STREAK_THRESHOLD_USD,
  utcDay,
  validateDays,
  validateRelationshipDefinition,
  validInvitationToken,
  validRelationshipId,
} from './logic.js';

const MAX_BODY_BYTES = 256 * 1024;
const JOIN_LIMIT = 10;
const JOIN_TTL_SECONDS = 60;
const LEGACY_SUBMIT_ATTEMPT_LIMIT = 120;
const LEGACY_SUBMIT_RECORD_LIMIT = 1200;
const SUBMIT_TTL_SECONDS = 60;
const INVITATION_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_ACTIVE_INVITATIONS = 20;
const MAX_MACHINES_PER_MEMBER = 16;
const MAX_RECORDS_PER_MEMBER = 800;
const MIN_SUBMIT_DATE = '2020-01-01';
const DURABLE_OBJECT_BULK_LIMIT = 128;
const MAX_CLEANUP_ENTRIES_PER_DRAIN = 256;
const MAX_CLEANUP_KV_DELETES_PER_DRAIN = 200;
const MAX_PENDING_ADMISSIONS = 32;
const MAX_PENDING_ADMISSIONS_PER_IP = 8;
const MAX_PENDING_MUTATIONS = 32;
const MAX_PENDING_LEGACY_MUTATIONS = 32;
const MAX_CONCURRENT_BODY_READS = 16;
const MAX_CONCURRENT_BODY_READS_PER_IP = 4;
const REQUEST_BODY_TIMEOUT_MS = 10_000;
const MAX_CONCURRENT_BOARD_READS = 4;
const MAX_CONCURRENT_MEMBER_READS = 2;

const JSON_HEADERS = { 'content-type': 'application/json' };
const CORS_HEADERS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
  'access-control-allow-headers': 'content-type, authorization, x-brrrn-handle',
};
const PRIVATE_HEADERS = { 'cache-control': 'private, no-store' };

function json(data, status = 200, cors = false) {
  return new Response(JSON.stringify(data), {
    status,
    headers: cors ? { ...JSON_HEADERS, ...CORS_HEADERS } : JSON_HEADERS,
  });
}

function error(message, status = 400, cors = false) {
  return json({ error: message }, status, cors);
}

function v2Json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...JSON_HEADERS, ...CORS_HEADERS, ...PRIVATE_HEADERS },
  });
}

function v2Error(message, status = 400) {
  return v2Json({ error: message }, status);
}

function v2RetryableError(message) {
  const response = v2Error(message, 503);
  response.headers.set('retry-after', '1');
  return response;
}

async function readTextBounded(request, timeoutMs) {
  const length = Number(request.headers.get('content-length') || 0);
  if (length > MAX_BODY_BYTES) {
    if (request.body) void request.body.cancel().catch(() => {});
    return { error: 'request body too large', status: 413 };
  }
  if (!request.body) return { text: '' };

  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  let timeout;
  let timeoutID;
  if (timeoutMs !== undefined) {
    timeout = new Promise((resolve) => {
      timeoutID = setTimeout(() => resolve({ timedOut: true }), timeoutMs);
    });
  }

  try {
    for (;;) {
      const next = timeout
        ? await Promise.race([reader.read(), timeout])
        : await reader.read();
      if (next.timedOut) {
        void reader.cancel().catch(() => {});
        return { error: 'request body timed out', status: 408 };
      }
      const { done, value } = next;
      if (done) break;
      if (!(value instanceof Uint8Array)) {
        void reader.cancel().catch(() => {});
        return { error: 'request body unavailable', status: 400 };
      }
      total += value.byteLength;
      if (total > MAX_BODY_BYTES) {
        void reader.cancel().catch(() => {});
        return { error: 'request body too large', status: 413 };
      }
      chunks.push(value);
    }
  } catch {
    return { error: 'request body unavailable', status: 400 };
  } finally {
    if (timeoutID !== undefined) clearTimeout(timeoutID);
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { text: new TextDecoder().decode(bytes) };
}

async function readJson(request, allowEmpty = false) {
  const body = await readTextBounded(request);
  if (body.error) return body;
  if (!body.text.trim()) {
    return allowEmpty ? { value: {} } : { error: 'JSON body required', status: 400 };
  }
  try {
    return { value: JSON.parse(body.text) };
  } catch {
    return { error: 'malformed JSON body', status: 400 };
  }
}

async function readObject(request, allowEmpty = false) {
  const parsed = await readJson(request, allowEmpty);
  if (parsed.error) return parsed;
  if (typeof parsed.value !== 'object' || parsed.value === null || Array.isArray(parsed.value)) {
    return { error: 'JSON body must be an object', status: 400 };
  }
  return parsed;
}

async function sha256(value) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function relationshipKey(id) {
  return `v2:relationship:${id}`;
}

function relationshipMemberKey(id, handle) {
  return `v2:member:${id}:${handle}`;
}

function invitationKey(hash) {
  return `v2:invite:${hash}`;
}

function relationshipInvitationKey(id, hash) {
  return `v2:relationship-invite:${id}:${hash}`;
}

function weekModelKey(id, handle, machineID) {
  return `v2:week-model:${id}:${handle}:${machineID}`;
}

function costHistoryKey(id, handle) {
  return `v2:cost-history:${id}:${handle}`;
}

function cleanupPrefix(id, handle) {
  return `v2:cleanup:${id}:${handle}:`;
}

function cleanupKey(id, handle, recordKey) {
  return `${cleanupPrefix(id, handle)}${recordKey}`;
}

function identityFromRequest(request) {
  const authorization = request.headers.get('authorization');
  const handle = normalizeHandle(request.headers.get('x-brrrn-handle'));
  if (!authorization?.startsWith('Bearer ') || !handle) {
    return { error: 'member identity required', status: 401 };
  }
  const secret = authorization.slice('Bearer '.length);
  if (!secret || secret.length > 256) {
    return { error: 'member identity required', status: 401 };
  }
  return { handle, secret };
}

async function authenticateRelationship(storage, id, identity) {
  const [relationship, member, candidateHash] = await Promise.all([
    storage.get(relationshipKey(id)),
    storage.get(relationshipMemberKey(id, identity.handle)),
    sha256(identity.secret),
  ]);
  if (!relationship || !member || candidateHash !== member.secret_hash) {
    return { error: 'invalid member credentials', status: 401 };
  }
  return { relationship, member };
}

function relationshipMetadata(relationship) {
  return {
    relationship_id: relationship.id,
    type: relationship.type,
    name: relationship.name,
    member_count: relationship.member_count,
    member_limit: relationship.member_limit,
  };
}

function decodePathSegment(value) {
  try {
    return { value: decodeURIComponent(value) };
  } catch {
    return { error: 'invalid path encoding' };
  }
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
  const parsed = await readObject(request, true);
  if (parsed.error) return error(parsed.error, parsed.status);
  // Optional gate for shared hubs: when the operator sets PIT_CREATE_TOKEN,
  // only people they gave the token to can open new pits. Joining and
  // submitting stay token-free (the pit code is that key).
  if (env.PIT_CREATE_TOKEN) {
    if (parsed.value.create_token !== env.PIT_CREATE_TOKEN) {
      return error('a create token is required on this hub', 403);
    }
  }
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

function rateLimitTime(env) {
  return new Date(env.__TEST_NOW || Date.now()).getTime();
}

function requestBodyTimeout(env) {
  const value = env.__TEST_BODY_READ_TIMEOUT_MS;
  return Number.isFinite(value) && value >= 0 ? value : REQUEST_BODY_TIMEOUT_MS;
}

async function enforceWindowLimit(storage, key, limit, ttlSeconds, units, now) {
  return storage.transaction(async (txn) => {
    let state = await txn.get(key);
    if (
      !state
      || typeof state !== 'object'
      || !Number.isFinite(state.count)
      || !Number.isFinite(state.reset_at)
      || now >= state.reset_at
    ) {
      state = {
        count: 0,
        reset_at: now + ttlSeconds * 1000,
      };
    }
    if (state.count + units > limit) return false;
    state.count += units;
    await txn.put(key, state);
    return true;
  });
}

async function enforceJoinLimit(request, storage, env) {
  const ip = request.headers.get('cf-connecting-ip') || 'unknown';
  return enforceWindowLimit(
    storage,
    `ratelimit:join:${ip}`,
    JOIN_LIMIT,
    JOIN_TTL_SECONDS,
    1,
    rateLimitTime(env),
  );
}

async function enforceLegacySubmitLimit(request, storage, env, action, limit, units = 1) {
  const ip = request.headers.get('cf-connecting-ip') || 'unknown';
  return enforceWindowLimit(
    storage,
    `ratelimit:${action}:${ip}`,
    limit,
    SUBMIT_TTL_SECONDS,
    units,
    rateLimitTime(env),
  );
}

async function enforceV2Limit(request, storage, env, action, limit, ttlSeconds, units = 1) {
  const ip = request.headers.get('cf-connecting-ip') || 'unknown';
  return enforceWindowLimit(
    storage,
    `v2:ratelimit:${action}:${ip}`,
    limit,
    ttlSeconds,
    units,
    rateLimitTime(env),
  );
}

function validateDisplayName(value) {
  if (value === undefined || value === null) return { ok: true, name: null };
  if (typeof value !== 'string') return { ok: false };
  const name = value.trim();
  const length = [...name].length;
  if (length < 1 || length > 32 || /\p{Cc}/u.test(name)) return { ok: false };
  return { ok: true, name };
}

async function joinPit(request, env, storage, code, now) {
  if (!(await pitExists(env.BRRRN_KV, code))) return error('pit not found', 404);
  if (!(await enforceJoinLimit(request, storage, env))) return error('too many join attempts', 429);

  const parsed = await readObject(request);
  if (parsed.error) return error(parsed.error, parsed.status);
  const handle = normalizeHandle(parsed.value.handle);
  const secret = parsed.value.secret;
  if (!handle) return error('handle must be 1-24 lowercase letters, numbers, _ or -');
  if (typeof secret !== 'string' || secret.length < 1 || secret.length > 256) {
    return error('secret must be a non-empty string up to 256 characters');
  }
  const display = validateDisplayName(parsed.value.display_name);
  if (!display.ok) return error('display name must be 1-32 characters');

  // The handle is permanent identity (day records key on it); the display
  // name is cosmetic and editable. Re-joining with the same secret updates
  // the display name instead of conflicting, which is also what makes the
  // client's join retry idempotent.
  const key = `member:${code}:${handle}`;
  const existingRaw = await env.BRRRN_KV.get(key);
  if (existingRaw) {
    const existing = JSON.parse(existingRaw);
    if (existing.secret_hash !== await sha256(secret)) {
      return error('handle already taken', 409);
    }
    await env.BRRRN_KV.put(key, JSON.stringify({
      ...existing,
      display_name: display.name ?? existing.display_name ?? null,
    }));
    return json({ ok: true });
  }
  await env.BRRRN_KV.put(key, JSON.stringify({
    secret_hash: await sha256(secret),
    display_name: display.name,
    joined_at: now.toISOString(),
  }));
  return json({ ok: true });
}

// Any authenticated member can retitle the pit: the trust model is "your
// friends", and pits deliberately have no admin tier.
async function renamePit(request, env, storage, code) {
  if (!(await pitExists(env.BRRRN_KV, code))) return error('pit not found', 404);
  if (!(await enforceJoinLimit(request, storage, env))) return error('too many attempts', 429);

  const parsed = await readObject(request);
  if (parsed.error) return error(parsed.error, parsed.status);
  const handle = normalizeHandle(parsed.value.handle);
  const secret = parsed.value.secret;
  if (!handle || typeof secret !== 'string' || !secret) {
    return error('member credentials required', 401);
  }
  const member = await env.BRRRN_KV.get(`member:${code}:${handle}`, 'json');
  if (!member) return error('member not found', 404);
  if (await sha256(secret) !== member.secret_hash) return error('invalid secret', 401);

  const name = typeof parsed.value.name === 'string' ? parsed.value.name.trim() : '';
  const length = [...name].length;
  if (length < 1 || length > 80 || /\p{Cc}/u.test(name)) {
    return error('name must be 1-80 characters');
  }
  const pit = await env.BRRRN_KV.get(`pit:${code}`, 'json');
  await env.BRRRN_KV.put(`pit:${code}`, JSON.stringify({ ...pit, name }));
  return json({ ok: true });
}

function validMachineId(value) {
  return typeof value === 'string' && /^[a-zA-Z0-9_-]{1,64}$/.test(value);
}

function uniqueDays(validatedDays) {
  const byDate = new Map();
  for (const day of validatedDays) byDate.set(day.date, day);
  return [...byDate.values()];
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

async function submitDays(request, env, storage, code, now) {
  const parsed = await readObject(request);
  if (parsed.error) return error(parsed.error, parsed.status);
  const body = parsed.value;
  const auth = await authenticateMember(env, code, body.handle, body.secret);
  if (auth.response) return auth.response;
  if (!validMachineId(body.machine_id)) {
    return error('machine_id must be 1-64 letters, numbers, _ or -');
  }
  const checked = validateDays(body.days);
  if (!checked.ok) return error(checked.error);

  const days = uniqueDays(checked.days);
  const maxDate = utcDay(now);
  if (days.some(({ date }) => date > maxDate)) {
    return error(`dates cannot be in the future (after ${maxDate})`);
  }
  if (!(await enforceLegacySubmitLimit(
    request,
    storage,
    env,
    'submit-records',
    LEGACY_SUBMIT_RECORD_LIMIT,
    Math.max(days.length, 1),
  ))) {
    return error('too many submitted records', 429);
  }
  await Promise.all(days.map(({ date, rec }) => {
    const key = `day:${code}:${auth.handle}:${body.machine_id}:${date}`;
    return env.BRRRN_KV.put(key, JSON.stringify(rec));
  }));
  // Keep the board summary in step with the day records so the board never has
  // to scan a member's full history. The summary lives in strongly consistent
  // Durable Object storage and legacy mutations are serialized, so this
  // read-modify-write is race-free and cannot be dropped by KV write limits.
  await maintainBoardSummary(env, storage, code, auth.handle, body.machine_id, days, now);
  return json({ ok: true, days_stored: days.length });
}

async function kvJsonValues(kv, keys) {
  const batches = [];
  for (let index = 0; index < keys.length; index += 100) {
    batches.push(keys.slice(index, index + 100));
  }
  const pages = await Promise.all(batches.map((batch) => kv.get(batch, 'json')));
  return new Map(pages.flatMap((page) => [...page]));
}

async function durableObjectValues(storage, keys) {
  const values = new Map();
  for (let index = 0; index < keys.length; index += DURABLE_OBJECT_BULK_LIMIT) {
    const batch = keys.slice(index, index + DURABLE_OBJECT_BULK_LIMIT);
    const page = await storage.get(batch);
    for (const entry of page) values.set(...entry);
  }
  return values;
}

async function dailyRecords(env, prefix) {
  const keys = await listKeys(env.BRRRN_KV, prefix);
  const values = await kvJsonValues(env.BRRRN_KV, keys);
  return keys.flatMap((key) => {
    const rec = values.get(key);
    if (!rec) return [];
    const date = key.slice(key.lastIndexOf(':') + 1);
    return [{ [date]: rec }];
  });
}

// ---- maintained board summary ----
//
// Scanning every stored machine-day on every board read is what makes KV
// usage explode. Instead, submit keeps a compact per-member, per-machine
// summary in the Coordinator's Durable Object storage, and the board reads
// those summaries. DO storage is strongly consistent, transactional, and has
// no per-key write-rate limit, so unlike KV it is safe to use as authoritative
// read-modify-write state. Legacy mutations are serialized by the Coordinator,
// so each summary update is race-free. Machine ids are DO key suffixes (not
// object keys), so an id like `__proto__` cannot corrupt anything.
//
// Each machine summary holds cost per UTC day (for today/week/month windows
// and streaks) and, for the current ISO week only, the model breakdown. Cost
// is set (never added) per machine/date, so a re-submit overwrites its own
// contribution without ever reading a day record back. A per-member marker
// records that the one-time migration from day records has run.

const BOARD_MIGRATED_PREFIX = 'bsum:migrated:';
const BOARD_MACHINE_PREFIX = 'bsum:machine:';

function boardMigratedKey(code, handle) {
  return `${BOARD_MIGRATED_PREFIX}${code}:${handle}`;
}

function boardMachineKey(code, handle, machineID) {
  return `${BOARD_MACHINE_PREFIX}${code}:${handle}:${machineID}`;
}

function emptyMachineSummary(weekStart) {
  return { cost: {}, week_start: weekStart, models: {} };
}

// Set this submission's costs and current-week models on one machine summary,
// in place. Cost is idempotent (set, not added); on a week rollover the
// machine's stale model rows are dropped before the newly submitted
// current-week days are recorded.
function applyDaysToMachineSummary(machine, days, now) {
  const weekStart = isoWeekStart(now);
  const today = utcDay(now);
  if (machine.week_start !== weekStart) {
    machine.week_start = weekStart;
    machine.models = {};
  }
  for (const { date, rec } of days) {
    machine.cost[date] = rec.c ?? 0;
    if (date >= weekStart && date <= today) machine.models[date] = rec.models ?? {};
  }
  return machine;
}

// Fold one machine's stored day records into a machine summary. Used to
// rebuild a machine the whole-member migration could not see yet (see below).
async function buildMachineSummaryFromRecords(env, code, handle, machineID, now) {
  const weekStart = isoWeekStart(now);
  const today = utcDay(now);
  const prefix = `day:${code}:${handle}:${machineID}:`;
  const keys = await listKeys(env.BRRRN_KV, prefix);
  const values = await kvJsonValues(env.BRRRN_KV, keys);
  const machine = emptyMachineSummary(weekStart);
  for (const key of keys) {
    const rec = values.get(key);
    if (!rec) continue;
    const date = key.slice(prefix.length);
    machine.cost[date] = rec.c ?? 0;
    if (date >= weekStart && date <= today) machine.models[date] = rec.models ?? {};
  }
  return machine;
}

// Rebuild every machine summary for a member from their stored day records.
// Runs once, on the first submit after summaries shipped, so the board never
// undercounts a machine that will not submit again. `day:${code}:${handle}:`
// keys are `...:<machine>:<date>` and neither segment contains ':'. Uses a Map
// so an untrusted machine id can never collide with Object prototype members.
async function buildMachineSummariesFromRecords(env, code, handle, now) {
  const weekStart = isoWeekStart(now);
  const today = utcDay(now);
  const prefix = `day:${code}:${handle}:`;
  const keys = await listKeys(env.BRRRN_KV, prefix);
  const values = await kvJsonValues(env.BRRRN_KV, keys);
  const machines = new Map();
  for (const key of keys) {
    const rec = values.get(key);
    if (!rec) continue;
    const rest = key.slice(prefix.length);
    const split = rest.lastIndexOf(':');
    if (split < 0) continue;
    const machineID = rest.slice(0, split);
    const date = rest.slice(split + 1);
    let machine = machines.get(machineID);
    if (!machine) {
      machine = emptyMachineSummary(weekStart);
      machines.set(machineID, machine);
    }
    machine.cost[date] = rec.c ?? 0;
    if (date >= weekStart && date <= today) machine.models[date] = rec.models ?? {};
  }
  return machines;
}

async function maintainBoardSummary(env, storage, code, handle, machineID, days, now) {
  const migratedKey = boardMigratedKey(code, handle);
  if (await storage.get(migratedKey)) {
    const key = boardMachineKey(code, handle, machineID);
    // A missing summary under a set marker means either a brand-new machine or
    // one whose records the whole-member migration could not see yet (KV list
    // lag). Rebuild it from its own, by-now converged, day records so its
    // history self-heals on this submit instead of being lost permanently.
    const machine = applyDaysToMachineSummary(
      (await storage.get(key)) ?? await buildMachineSummaryFromRecords(env, code, handle, machineID, now),
      days,
      now,
    );
    await storage.put(key, machine);
    return;
  }
  // First submit for this member since summaries shipped: rebuild every machine
  // from day records, apply this submission, then commit atomically so a
  // partial migration can never set the "migrated" marker.
  const machines = await buildMachineSummariesFromRecords(env, code, handle, now);
  let current = machines.get(machineID);
  if (!current) {
    current = emptyMachineSummary(isoWeekStart(now));
    machines.set(machineID, current);
  }
  applyDaysToMachineSummary(current, days, now);
  await storage.transaction(async (txn) => {
    for (const [id, machine] of machines) {
      await txn.put(boardMachineKey(code, handle, id), machine);
    }
    await txn.put(migratedKey, 1);
  });
}

// Turn one machine summary into the day-record map aggregateMember expects:
// cost per date plus the current week's model breakdown. Feeding these to the
// same aggregator reproduces exactly what a full day-record scan produced.
function machineSummaryToRecords(machine, now) {
  const weekStart = isoWeekStart(now);
  const today = utcDay(now);
  const byDate = {};
  for (const [date, cost] of Object.entries(machine.cost ?? {})) {
    byDate[date] = { c: cost, models: {} };
  }
  if (machine.week_start === weekStart) {
    for (const [date, models] of Object.entries(machine.models ?? {})) {
      if (date >= weekStart && date <= today) {
        (byDate[date] ??= { c: 0, models: {} }).models = models;
      }
    }
  }
  return byDate;
}

function logicalRecordKey(recordKey) {
  return recordKey.split(':').slice(0, 2).join(':');
}

function recordDate(recordKey) {
  return recordKey.split(':')[1];
}

function relationshipDayKey(id, handle, recordKey) {
  return `v2:day:${id}:${handle}:${recordKey}`;
}

async function exactRelationshipValues(env, id, handle, recordKeys) {
  const fullKeys = recordKeys.map((recordKey) => relationshipDayKey(id, handle, recordKey));
  const values = await kvJsonValues(env.BRRRN_KV, fullKeys);
  const missing = fullKeys.filter((key) => !values.get(key));
  if (missing.length) throw new Error('committed relationship record unavailable');
  return new Map(recordKeys.map((recordKey, index) => [recordKey, values.get(fullKeys[index])]));
}

async function exactRelationshipRecords(env, id, handle, recordKeys) {
  const values = await exactRelationshipValues(env, id, handle, recordKeys);
  return recordKeys.flatMap((recordKey) => {
    const rec = values.get(recordKey);
    return rec ? [{ [recordDate(recordKey)]: rec }] : [];
  });
}

async function createRelationshipV2(request, storage, now) {
  const identity = identityFromRequest(request);
  if (identity.error) return v2Error(identity.error, identity.status);
  const parsed = await readObject(request);
  if (parsed.error) return v2Error(parsed.error, parsed.status);
  const id = parsed.value.relationship_id;
  if (!validRelationshipId(id)) return v2Error('invalid relationship_id');
  const definition = validateRelationshipDefinition(parsed.value);
  if (!definition.ok) return v2Error(definition.error);
  const secretHash = await sha256(identity.secret);

  const result = await storage.transaction(async (txn) => {
    const key = relationshipKey(id);
    const existing = await txn.get(key);
    if (existing) {
      const creator = await txn.get(relationshipMemberKey(id, identity.handle));
      const sameDefinition = existing.type === definition.type && existing.name === definition.name;
      if (
        sameDefinition
        && existing.created_by === identity.handle
        && creator?.secret_hash === secretHash
      ) {
        return { data: relationshipMetadata(existing) };
      }
      return { error: 'relationship_id already exists', status: 409 };
    }

    const createdAt = now.toISOString();
    const relationship = {
      id,
      type: definition.type,
      name: definition.name,
      member_limit: definition.memberLimit,
      member_count: 1,
      created_by: identity.handle,
      created_at: createdAt,
    };
    await txn.put(key, relationship);
    await txn.put(relationshipMemberKey(id, identity.handle), {
      secret_hash: secretHash,
      joined_at: createdAt,
      machine_ids: [],
      record_keys: [],
    });
    await txn.put(costHistoryKey(id, identity.handle), {});
    return { data: relationshipMetadata(relationship) };
  });
  return result.error ? v2Error(result.error, result.status) : v2Json(result.data);
}

async function createInvitationV2(request, storage, id, now) {
  if (!validRelationshipId(id)) return v2Error('invalid relationship_id');
  const identity = identityFromRequest(request);
  if (identity.error) return v2Error(identity.error, identity.status);
  const parsed = await readObject(request);
  if (parsed.error) return v2Error(parsed.error, parsed.status);
  const token = parsed.value.invitation_token;
  if (!validInvitationToken(token)) return v2Error('invalid invitation_token');
  const [secretHash, tokenHash] = await Promise.all([
    sha256(identity.secret),
    sha256(token),
  ]);

  const result = await storage.transaction(async (txn) => {
    const relationship = await txn.get(relationshipKey(id));
    const member = await txn.get(relationshipMemberKey(id, identity.handle));
    if (!relationship || !member || member.secret_hash !== secretHash) {
      return { error: 'invalid member credentials', status: 401 };
    }

    const key = invitationKey(tokenHash);
    const existing = await txn.get(key);
    if (existing) {
      if (existing.relationship_id === id && existing.created_by === identity.handle) {
        if (existing.consumed_at) {
          return { error: 'invitation unavailable', status: 410 };
        }
        if (now.getTime() >= new Date(existing.expires_at).getTime()) {
          return { error: 'invitation expired', status: 410 };
        }
        return {
          data: {
            relationship_id: id,
            expires_at: existing.expires_at,
          },
        };
      }
      return { error: 'invitation token already exists', status: 409 };
    }
    if (relationship.member_count >= relationship.member_limit) {
      return { error: 'relationship is full', status: 409 };
    }

    const indexPrefix = `v2:relationship-invite:${id}:`;
    const activeInvitations = await txn.list({ prefix: indexPrefix });
    let activeCount = 0;
    for (const [indexKey, indexed] of activeInvitations) {
      if (now.getTime() >= new Date(indexed.expires_at).getTime()) {
        await txn.delete(indexKey);
      } else {
        activeCount += 1;
      }
    }
    if (activeCount >= MAX_ACTIVE_INVITATIONS) {
      return { error: 'too many active invitations', status: 429 };
    }

    const createdAt = now.toISOString();
    const expiresAt = new Date(now.getTime() + INVITATION_TTL_MS).toISOString();
    await txn.put(key, {
      relationship_id: id,
      created_by: identity.handle,
      created_at: createdAt,
      expires_at: expiresAt,
      consumed_at: null,
      consumed_by: null,
    });
    await txn.put(relationshipInvitationKey(id, tokenHash), {
      token_hash: tokenHash,
      expires_at: expiresAt,
    });
    return { data: { relationship_id: id, expires_at: expiresAt } };
  });
  return result.error ? v2Error(result.error, result.status) : v2Json(result.data);
}

async function previewInvitationV2(request, storage, now) {
  const parsed = await readObject(request);
  if (parsed.error) return v2Error(parsed.error, parsed.status);
  const token = parsed.value.invitation_token;
  if (!validInvitationToken(token)) return v2Error('invalid invitation_token');
  const invitation = await storage.get(invitationKey(await sha256(token)));
  if (!invitation) return v2Error('invitation not found', 404);
  if (invitation.consumed_at) return v2Error('invitation already used', 410);
  if (now.getTime() >= new Date(invitation.expires_at).getTime()) {
    return v2Error('invitation expired', 410);
  }
  const relationship = await storage.get(relationshipKey(invitation.relationship_id));
  if (!relationship) return v2Error('relationship not found', 404);
  return v2Json({
    ...relationshipMetadata(relationship),
    expires_at: invitation.expires_at,
  });
}

async function acceptInvitationV2(request, storage, now) {
  const identity = identityFromRequest(request);
  if (identity.error) return v2Error(identity.error, identity.status);
  const parsed = await readObject(request);
  if (parsed.error) return v2Error(parsed.error, parsed.status);
  const token = parsed.value.invitation_token;
  if (!validInvitationToken(token)) return v2Error('invalid invitation_token');
  const [secretHash, tokenHash] = await Promise.all([
    sha256(identity.secret),
    sha256(token),
  ]);

  const result = await storage.transaction(async (txn) => {
    const inviteKey = invitationKey(tokenHash);
    const invitation = await txn.get(inviteKey);
    if (!invitation) return { error: 'invitation not found', status: 404 };
    const relationship = await txn.get(relationshipKey(invitation.relationship_id));
    if (!relationship) return { error: 'relationship not found', status: 404 };
    const memberKey = relationshipMemberKey(relationship.id, identity.handle);
    const member = await txn.get(memberKey);

    if (invitation.consumed_at) {
      if (
        invitation.consumed_by !== identity.handle
        || !member
        || member.secret_hash !== secretHash
      ) {
        return { error: 'invitation unavailable', status: 410 };
      }
      return { data: relationshipMetadata(relationship) };
    }
    if (now.getTime() >= new Date(invitation.expires_at).getTime()) {
      await txn.delete(relationshipInvitationKey(relationship.id, tokenHash));
      return { error: 'invitation expired', status: 410 };
    }
    if (member && member.secret_hash !== secretHash) {
      return { error: 'handle already belongs to another identity', status: 409 };
    }
    if (!member && relationship.member_count >= relationship.member_limit) {
      return { error: 'relationship is full', status: 409 };
    }

    const acceptedAt = now.toISOString();
    if (!member) {
      await txn.put(memberKey, {
        secret_hash: secretHash,
        joined_at: acceptedAt,
        machine_ids: [],
        record_keys: [],
      });
      await txn.put(costHistoryKey(relationship.id, identity.handle), {});
      relationship.member_count += 1;
      await txn.put(relationshipKey(relationship.id), relationship);
    }
    invitation.consumed_at = acceptedAt;
    invitation.consumed_by = identity.handle;
    await txn.put(inviteKey, invitation);
    await txn.delete(relationshipInvitationKey(relationship.id, tokenHash));
    return { data: relationshipMetadata(relationship) };
  });
  return result.error ? v2Error(result.error, result.status) : v2Json(result.data);
}

async function authenticateV2Request(request, storage, id) {
  if (!validRelationshipId(id)) return { response: v2Error('invalid relationship_id') };
  const identity = identityFromRequest(request);
  if (identity.error) return { response: v2Error(identity.error, identity.status) };
  const auth = await authenticateRelationship(storage, id, identity);
  if (auth.error) return { response: v2Error(auth.error, auth.status) };
  return { identity, ...auth };
}

function arraysEqual(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function memberMachineIDs(member) {
  return member.machine_ids ?? [
    ...new Set((member.record_keys ?? []).map((recordKey) => recordKey.split(':')[0])),
  ];
}

async function prepareSubmissionDays(machineID, days) {
  return Promise.all(days.map(async ({ date, rec }) => ({
    date,
    rec,
    recordKey: `${machineID}:${date}:${await sha256(JSON.stringify(rec))}`,
  })));
}

async function planRelationshipSubmission(storage, id, identity, machineID, days) {
  const secretHash = await sha256(identity.secret);
  return storage.transaction(async (txn) => {
    const member = await txn.get(relationshipMemberKey(id, identity.handle));
    if (!member || member.secret_hash !== secretHash) {
      return { error: 'invalid member credentials', status: 401 };
    }

    const recordKeys = member.record_keys ?? [];
    const machineIDs = memberMachineIDs(member);
    const hasMachine = machineIDs.includes(machineID);
    if (!hasMachine && machineIDs.length >= MAX_MACHINES_PER_MEMBER) {
      return { error: 'too many machines for this member', status: 409 };
    }

    const incomingByLogicalKey = new Map(
      days.map((day) => [logicalRecordKey(day.recordKey), day.recordKey]),
    );
    const previousRecordKeys = Object.fromEntries(
      recordKeys
        .filter((recordKey) => incomingByLogicalKey.has(logicalRecordKey(recordKey)))
        .map((recordKey) => [logicalRecordKey(recordKey), recordKey]),
    );
    const unchangedRecords = recordKeys.filter(
      (recordKey) => !incomingByLogicalKey.has(logicalRecordKey(recordKey)),
    );
    const combinedRecords = [
      ...unchangedRecords,
      ...incomingByLogicalKey.values(),
    ].sort((a, b) => {
      const dateOrder = recordDate(a).localeCompare(recordDate(b));
      return dateOrder || a.localeCompare(b);
    });
    const overflow = Math.max(0, combinedRecords.length - MAX_RECORDS_PER_MEMBER);
    const evicted = combinedRecords.slice(0, overflow);
    if (days.some(({ recordKey }) => evicted.includes(recordKey))) {
      return { error: 'date is outside the retained history window', status: 409 };
    }
    const retained = combinedRecords.slice(overflow);
    const retainedSet = new Set(retained);
    return {
      expected_machine_ids: machineIDs,
      expected_record_keys: recordKeys,
      machine_ids: hasMachine ? machineIDs : [...machineIDs, machineID],
      record_keys: retained,
      previous_record_keys: previousRecordKeys,
      obsolete: recordKeys.filter((recordKey) => !retainedSet.has(recordKey)),
      has_cost_history: (await txn.get(costHistoryKey(id, identity.handle))) !== undefined,
    };
  });
}

async function finalizeRelationshipSubmission(
  storage,
  id,
  identity,
  machineID,
  days,
  oldRecords,
  plan,
  now,
) {
  const secretHash = await sha256(identity.secret);
  return storage.transaction(async (txn) => {
    const memberKey = relationshipMemberKey(id, identity.handle);
    const member = await txn.get(memberKey);
    if (
      !member
      || member.secret_hash !== secretHash
      || !arraysEqual(memberMachineIDs(member), plan.expected_machine_ids)
      || !arraysEqual(member.record_keys ?? [], plan.expected_record_keys)
    ) {
      return { error: 'submission state changed', status: 409 };
    }

    const historyKey = costHistoryKey(id, identity.handle);
    const storedCostHistory = await txn.get(historyKey);
    const costHistory = storedCostHistory ?? {};
    const isSummaryMigration = storedCostHistory === undefined;
    if (isSummaryMigration) {
      for (const [recordKey, rec] of oldRecords) {
        const date = recordDate(recordKey);
        costHistory[date] = stableCost((costHistory[date] ?? 0) + (rec.c ?? 0));
      }
    }
    for (const { date, rec, recordKey } of days) {
      const previousRecordKey = plan.previous_record_keys[logicalRecordKey(recordKey)];
      const previousCost = oldRecords.get(previousRecordKey)?.c ?? 0;
      costHistory[date] = stableCost(Math.max(
        0,
        (costHistory[date] ?? 0) + rec.c - previousCost,
      ));
    }

    member.machine_ids = plan.machine_ids;
    member.record_keys = plan.record_keys;
    await txn.put(memberKey, member);
    await txn.put(historyKey, costHistory);

    const weekStart = isoWeekStart(now);
    const today = utcDay(now);
    const modelSummaries = new Map();
    const loadModelSummary = async (summaryMachineID) => {
      if (modelSummaries.has(summaryMachineID)) {
        return modelSummaries.get(summaryMachineID);
      }
      const key = weekModelKey(id, identity.handle, summaryMachineID);
      const existing = await txn.get(key);
      const entry = {
        key,
        existed: existing !== undefined,
        summary: existing?.week_start === weekStart
          ? existing
          : { week_start: weekStart, days: {} },
      };
      modelSummaries.set(summaryMachineID, entry);
      return entry;
    };

    if (isSummaryMigration) {
      for (const [recordKey, rec] of oldRecords) {
        const date = recordDate(recordKey);
        if (date < weekStart || date > today) continue;
        const summaryMachineID = recordKey.split(':')[0];
        const entry = await loadModelSummary(summaryMachineID);
        entry.summary.days[date] = rec.models ?? {};
      }
    }

    const currentModels = await loadModelSummary(machineID);
    for (const { date, rec } of days) {
      if (date >= weekStart && date <= today) currentModels.summary.days[date] = rec.models;
    }
    for (const { key, existed, summary } of modelSummaries.values()) {
      if (Object.keys(summary.days).length) {
        await txn.put(key, summary);
      } else if (existed) {
        await txn.delete(key);
      }
    }
    for (const { recordKey } of days) {
      await txn.delete(cleanupKey(id, identity.handle, recordKey));
    }
    for (const recordKey of plan.obsolete) {
      await txn.put(cleanupKey(id, identity.handle, recordKey), recordKey);
    }
    return {};
  });
}

async function stageRelationshipCleanup(storage, id, handle, recordKeys) {
  if (!recordKeys.length) return;
  await storage.transaction(async (txn) => {
    for (const recordKey of recordKeys) {
      await txn.put(cleanupKey(id, handle, recordKey), recordKey);
    }
  });
}

async function deleteDurableObjectKeys(storage, keys) {
  for (let index = 0; index < keys.length; index += DURABLE_OBJECT_BULK_LIMIT) {
    const batch = keys.slice(index, index + DURABLE_OBJECT_BULK_LIMIT);
    try {
      await storage.delete(batch);
    } catch {
      // Cleanup markers are retained for a later submission retry.
    }
  }
}

async function drainRelationshipCleanup(env, storage, id, handle) {
  const prefix = cleanupPrefix(id, handle);
  const [member, entries] = await Promise.all([
    storage.get(relationshipMemberKey(id, handle)),
    storage.list({ prefix, limit: MAX_CLEANUP_ENTRIES_PER_DRAIN }),
  ]);
  const committed = new Set(member?.record_keys ?? []);
  const candidates = [];
  const committedMarkers = [];
  for (const [key, recordKey] of entries) {
    if (committed.has(recordKey)) committedMarkers.push(key);
    else candidates.push({ key, recordKey });
  }
  await deleteDurableObjectKeys(storage, committedMarkers);

  const cleanupCandidates = candidates.slice(0, MAX_CLEANUP_KV_DELETES_PER_DRAIN);
  const results = await Promise.allSettled(cleanupCandidates.map(({ recordKey }) => (
    env.BRRRN_KV.delete(relationshipDayKey(id, handle, recordKey))
  )));
  const deletedMarkers = cleanupCandidates.flatMap(({ key }, index) => (
    results[index].status === 'fulfilled' ? [key] : []
  ));
  await deleteDurableObjectKeys(storage, deletedMarkers);
}

function weekModelRecords(summaries, now) {
  const weekStart = isoWeekStart(now);
  const today = utcDay(now);
  const records = [];
  for (const summary of summaries) {
    if (summary?.week_start !== weekStart) continue;
    for (const [date, models] of Object.entries(summary.days)) {
      if (date >= weekStart && date <= today) {
        records.push({ [date]: { t: 0, c: 0, cc: 0, cx: 0, models } });
      }
    }
  }
  return records;
}

async function submitRelationshipDaysV2(request, env, storage, id, now) {
  const auth = await authenticateV2Request(request, storage, id);
  if (auth.response) return auth.response;
  await drainRelationshipCleanup(env, storage, id, auth.identity.handle);
  const parsed = await readObject(request);
  if (parsed.error) return v2Error(parsed.error, parsed.status);
  const body = parsed.value;
  if (!validMachineId(body.machine_id)) {
    return v2Error('machine_id must be 1-64 letters, numbers, _ or -');
  }
  const checked = validateDays(body.days);
  if (!checked.ok) return v2Error(checked.error);
  const days = uniqueDays(checked.days);
  const maxDate = utcDay(now);
  if (days.some(({ date }) => date < MIN_SUBMIT_DATE || date > maxDate)) {
    return v2Error(`dates must be between ${MIN_SUBMIT_DATE} and ${maxDate}`);
  }
  if (!(await enforceV2Limit(
    request,
    storage,
    env,
    'submit-records',
    1200,
    60,
    Math.max(days.length, 1),
  ))) {
    return v2Error('too many submitted records', 429);
  }

  const preparedDays = await prepareSubmissionDays(body.machine_id, days);
  const plan = await planRelationshipSubmission(
    storage,
    id,
    auth.identity,
    body.machine_id,
    preparedDays,
  );
  if (plan.error) return v2Error(plan.error, plan.status);

  const oldRecordKeys = plan.has_cost_history
    ? Object.values(plan.previous_record_keys)
    : plan.expected_record_keys;
  let oldRecords;
  try {
    oldRecords = await exactRelationshipValues(
      env,
      id,
      auth.identity.handle,
      [...new Set(oldRecordKeys)],
    );
  } catch {
    return v2Error('relationship data temporarily unavailable', 503);
  }
  const committedBeforeWrite = new Set(plan.expected_record_keys);
  await stageRelationshipCleanup(
    storage,
    id,
    auth.identity.handle,
    preparedDays
      .map(({ recordKey }) => recordKey)
      .filter((recordKey) => !committedBeforeWrite.has(recordKey)),
  );
  const writeResults = await Promise.allSettled(preparedDays.map(({ recordKey, rec }) => (
    env.BRRRN_KV.put(
      relationshipDayKey(id, auth.identity.handle, recordKey),
      JSON.stringify({ ...rec, models: {} }),
    )
  )));
  if (writeResults.some(({ status }) => status === 'rejected')) {
    await drainRelationshipCleanup(env, storage, id, auth.identity.handle);
    return v2Error('submission temporarily unavailable', 503);
  }

  const finalized = await finalizeRelationshipSubmission(
    storage,
    id,
    auth.identity,
    body.machine_id,
    preparedDays,
    oldRecords,
    plan,
    now,
  );
  if (finalized.error) {
    await drainRelationshipCleanup(env, storage, id, auth.identity.handle);
    return v2Error(finalized.error, finalized.status);
  }

  await drainRelationshipCleanup(env, storage, id, auth.identity.handle);
  return v2Json({ ok: true, days_stored: preparedDays.length });
}

function costHistoryRecords(costHistory, now) {
  const firstDate = [monthStart(now), isoWeekStart(now)].sort()[0];
  const lastDate = utcDay(now);
  return Object.entries(costHistory).flatMap(([date, cost]) => (
    date >= firstDate && date <= lastDate
      ? [{ [date]: { t: 0, c: cost, cc: 0, cx: 0, models: {} } }]
      : []
  ));
}

async function relationshipBoardSnapshot(storage, id, identity) {
  const secretHash = await sha256(identity.secret);
  return storage.transaction(async (txn) => {
    const relationship = await txn.get(relationshipKey(id));
    const caller = await txn.get(relationshipMemberKey(id, identity.handle));
    if (!relationship || !caller || caller.secret_hash !== secretHash) {
      return { error: 'invalid member credentials', status: 401 };
    }

    const prefix = `v2:member:${id}:`;
    const entries = await txn.list({ prefix });
    const snapshots = [...entries].map(([key, member]) => ({
      handle: key.slice(prefix.length),
      member,
    }));
    const historyKeys = snapshots.map(({ handle }) => costHistoryKey(id, handle));
    const modelKeys = snapshots.flatMap(({ handle, member }) => (
      memberMachineIDs(member).map((machineID) => weekModelKey(id, handle, machineID))
    ));
    const [histories, models] = await Promise.all([
      durableObjectValues(txn, historyKeys),
      durableObjectValues(txn, modelKeys),
    ]);

    return {
      relationship,
      members: snapshots.map(({ handle, member }) => ({
        handle,
        member,
        costHistory: histories.get(costHistoryKey(id, handle)),
        modelSummaries: memberMachineIDs(member).flatMap((machineID) => {
          const summary = models.get(weekModelKey(id, handle, machineID));
          return summary ? [summary] : [];
        }),
      })),
    };
  });
}

async function getRelationshipBoardV2(request, env, storage, id, now) {
  if (!validRelationshipId(id)) return v2Error('invalid relationship_id');
  const identity = identityFromRequest(request);
  if (identity.error) return v2Error(identity.error, identity.status);

  for (let attempt = 0; attempt < 2; attempt += 1) {
    const snapshot = await relationshipBoardSnapshot(storage, id, identity);
    if (snapshot.error) return v2Error(snapshot.error, snapshot.status);
    const members = [];
    let retry = false;

    try {
      for (const memberSnapshot of snapshot.members) {
        const { handle, member, costHistory, modelSummaries } = memberSnapshot;
        let records;
        if (costHistory !== undefined) {
          records = costHistoryRecords(costHistory, now);
        } else {
          const firstDate = [monthStart(now), isoWeekStart(now)].sort()[0];
          const lastDate = utcDay(now);
          const recordKeys = (member.record_keys ?? []).filter((recordKey) => {
            const date = recordDate(recordKey);
            return date >= firstDate && date <= lastDate;
          });
          records = await exactRelationshipRecords(env, id, handle, recordKeys);
          const latest = await storage.get(relationshipMemberKey(id, handle));
          if (!latest || !arraysEqual(latest.record_keys ?? [], member.record_keys ?? [])) {
            retry = true;
            break;
          }
        }
        const aggregate = aggregateMember(
          [...records, ...weekModelRecords(modelSummaries, now)],
          now,
          MAX_MODELS_PER_MEMBER_RESPONSE,
        );
        if (costHistory !== undefined) {
          aggregate.streak_days = computeStreak(costHistory, now);
        }
        members.push({ handle, ...aggregate });
      }
    } catch {
      retry = true;
    }

    if (retry) continue;
    members.sort((a, b) => b.today_usd - a.today_usd || a.handle.localeCompare(b.handle));
    return v2Json({
      ...relationshipMetadata(snapshot.relationship),
      streak_threshold_usd: STREAK_THRESHOLD_USD,
      members,
    });
  }

  return v2Error('relationship data temporarily unavailable', 503);
}

async function coherentRelationshipMemberRecords(env, storage, id, handle) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const member = await storage.get(relationshipMemberKey(id, handle));
    if (!member) return null;
    const recordKeys = member.record_keys ?? [];
    try {
      const records = await exactRelationshipRecords(env, id, handle, recordKeys);
      const latest = await storage.get(relationshipMemberKey(id, handle));
      if (latest && arraysEqual(latest.record_keys ?? [], recordKeys)) return records;
    } catch {
      const latest = await storage.get(relationshipMemberKey(id, handle));
      if (latest && arraysEqual(latest.record_keys ?? [], recordKeys)) throw new Error('missing');
    }
  }
  throw new Error('changing');
}

async function getRelationshipMemberV2(request, env, storage, id, handleValue) {
  const auth = await authenticateV2Request(request, storage, id);
  if (auth.response) return auth.response;
  const handle = normalizeHandle(handleValue);
  if (!handle) return v2Error('member not found', 404);
  let records;
  try {
    records = await coherentRelationshipMemberRecords(env, storage, id, handle);
  } catch {
    return v2Error('relationship data temporarily unavailable', 503);
  }
  if (!records) return v2Error('member not found', 404);
  return v2Json({
    handle,
    streak_threshold_usd: STREAK_THRESHOLD_USD,
    days: memberSeries(records),
  });
}

async function getBoard(env, storage, code, now) {
  const pit = await pitExists(env.BRRRN_KV, code);
  if (!pit) return error('pit not found', 404, true);
  const memberPrefix = `member:${code}:`;
  const memberKeys = await listKeys(env.BRRRN_KV, memberPrefix);
  const handles = memberKeys.map((key) => key.slice(memberPrefix.length));
  const machinePrefix = `${BOARD_MACHINE_PREFIX}${code}:`;
  const [memberValues, migratedMarkers, machineSummaries] = await Promise.all([
    kvJsonValues(env.BRRRN_KV, memberKeys),
    storage.list({ prefix: `${BOARD_MIGRATED_PREFIX}${code}:` }),
    storage.list({ prefix: machinePrefix }),
  ]);
  const summariesByHandle = new Map();
  for (const [key, machine] of machineSummaries) {
    const rest = key.slice(machinePrefix.length);
    const split = rest.indexOf(':');
    if (split < 0) continue;
    const handle = rest.slice(0, split);
    let list = summariesByHandle.get(handle);
    if (!list) {
      list = [];
      summariesByHandle.set(handle, list);
    }
    list.push(machine);
  }
  // Migrated members (the steady state) resolve from Durable Object summaries
  // with no day-record reads. A member who has not submitted since summaries
  // shipped has no marker yet, so fall back to a one-off full scan until their
  // next submit migrates them; this keeps the board correct during the rollout.
  const recordsByMember = await Promise.all(handles.map((handle) => {
    if (migratedMarkers.has(boardMigratedKey(code, handle))) {
      return (summariesByHandle.get(handle) ?? []).map((machine) => (
        machineSummaryToRecords(machine, now)
      ));
    }
    return dailyRecords(env, `day:${code}:${handle}:`);
  }));
  const members = memberKeys.map((key, index) => ({
    handle: handles[index],
    display_name: memberValues.get(key)?.display_name ?? null,
    ...aggregateMember(recordsByMember[index], now),
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

function v2RateForRequest(request) {
  const path = new URL(request.url).pathname;
  if (request.method === 'POST' && path === '/v2/relationships') {
    return { action: 'create', limit: 20, ttl: 3600 };
  }
  if (request.method === 'POST' && path.endsWith('/invitations')) {
    return { action: 'invite', limit: 60, ttl: 3600 };
  }
  if (request.method === 'POST' && path.endsWith('/submit')) {
    return { action: 'submit-attempt', limit: 120, ttl: 60 };
  }
  if (request.method === 'POST') {
    return { action: 'invitation-use', limit: 120, ttl: 60 };
  }
  if (path.endsWith('/board')) {
    return { action: 'board-read', limit: 30, ttl: 60 };
  }
  if (/\/member\/[^/]+$/.test(path)) {
    return { action: 'member-read', limit: 60, ttl: 60 };
  }
  return { action: 'read', limit: 240, ttl: 60 };
}

async function coordinatedRoute(request, env, storage) {
  const url = new URL(request.url);
  const path = url.pathname;
  const now = new Date(env.__TEST_NOW || Date.now());

  if (request.method === 'POST' && path === '/pit') {
    return createPit(request, env, now);
  }

  if (path.startsWith('/v2/') || path === '/v2/relationships') {
    if (!storage) return v2Error('relationship storage unavailable', 503);

    if (request.method === 'POST' && path === '/v2/relationships') {
      return createRelationshipV2(request, storage, now);
    }
    if (request.method === 'POST' && path === '/v2/invitations/preview') {
      return previewInvitationV2(request, storage, now);
    }
    if (request.method === 'POST' && path === '/v2/invitations/accept') {
      return acceptInvitationV2(request, storage, now);
    }

    let match = path.match(/^\/v2\/relationships\/([^/]+)\/invitations$/);
    if (request.method === 'POST' && match) {
      return createInvitationV2(request, storage, match[1], now);
    }
    match = path.match(/^\/v2\/relationships\/([^/]+)\/submit$/);
    if (request.method === 'POST' && match) {
      return submitRelationshipDaysV2(request, env, storage, match[1], now);
    }
    match = path.match(/^\/v2\/relationships\/([^/]+)\/board$/);
    if (request.method === 'GET' && match) {
      return getRelationshipBoardV2(request, env, storage, match[1], now);
    }
    match = path.match(/^\/v2\/relationships\/([^/]+)\/member\/([^/]+)$/);
    if (request.method === 'GET' && match) {
      const decoded = decodePathSegment(match[2]);
      if (decoded.error) return v2Error(decoded.error);
      return getRelationshipMemberV2(request, env, storage, match[1], decoded.value);
    }
    return v2Error('not found', 404);
  }

  let match = path.match(/^\/pit\/([^/]+)\/join$/);
  if (request.method === 'POST' && match) {
    return joinPit(request, env, storage, match[1], now);
  }

  match = path.match(/^\/pit\/([^/]+)\/submit$/);
  if (request.method === 'POST' && match) {
    return submitDays(request, env, storage, match[1], now);
  }

  match = path.match(/^\/pit\/([^/]+)\/rename$/);
  if (request.method === 'POST' && match) {
    return renamePit(request, env, storage, match[1]);
  }

  // The board reads per-member summaries from Durable Object storage, so it is
  // served here (with storage) rather than straight from the Worker.
  match = path.match(/^\/pit\/([^/]+)\/board$/);
  if (request.method === 'GET' && match) {
    return getBoard(env, storage, match[1], now);
  }

  return error('not found', 404);
}

class BoundedSerialQueue {
  constructor(capacity) {
    this.capacity = capacity;
    this.depth = 0;
    this.tail = Promise.resolve();
  }

  async run(operation) {
    if (this.depth >= this.capacity) return { saturated: true };
    this.depth += 1;
    let release;
    const previous = this.tail;
    this.tail = new Promise((resolve) => { release = resolve; });
    await previous;
    try {
      return { saturated: false, value: await operation() };
    } finally {
      this.depth -= 1;
      release();
    }
  }
}

export class Coordinator {
  constructor(ctx, env) {
    this.env = env;
    this.storage = ctx.storage;
    this.v2RateQueue = new BoundedSerialQueue(MAX_PENDING_ADMISSIONS);
    this.legacyRateQueue = new BoundedSerialQueue(MAX_PENDING_ADMISSIONS);
    this.v2MutationQueue = new BoundedSerialQueue(MAX_PENDING_MUTATIONS);
    this.legacyMutationQueue = new BoundedSerialQueue(MAX_PENDING_LEGACY_MUTATIONS);
    this.pendingAdmissionsByIP = new Map();
    this.activeBodyReads = 0;
    this.activeBodyReadsByIP = new Map();
    this.activeBoardReads = 0;
    this.activeMemberReads = 0;
    this.activeLegacyBoardReads = 0;
  }

  async admitV2(request) {
    const ip = request.headers.get('cf-connecting-ip') || 'unknown';
    const pendingForIP = this.pendingAdmissionsByIP.get(ip) ?? 0;
    if (
      this.v2RateQueue.depth >= MAX_PENDING_ADMISSIONS
      || pendingForIP >= MAX_PENDING_ADMISSIONS_PER_IP
    ) {
      return { saturated: true };
    }
    this.pendingAdmissionsByIP.set(ip, pendingForIP + 1);
    try {
      const queued = await this.v2RateQueue.run(async () => {
        const rate = v2RateForRequest(request);
        return enforceV2Limit(
          request,
          this.storage,
          this.env,
          rate.action,
          rate.limit,
          rate.ttl,
        );
      });
      return queued.saturated
        ? queued
        : { saturated: false, allowed: queued.value };
    } finally {
      const remaining = (this.pendingAdmissionsByIP.get(ip) ?? 1) - 1;
      if (remaining) this.pendingAdmissionsByIP.set(ip, remaining);
      else this.pendingAdmissionsByIP.delete(ip);
    }
  }

  async admitLegacySubmit(request) {
    const queued = await this.legacyRateQueue.run(() => (
      enforceLegacySubmitLimit(
        request,
        this.storage,
        this.env,
        'submit-attempt',
        LEGACY_SUBMIT_ATTEMPT_LIMIT,
      )
    ));
    return queued.saturated
      ? queued
      : { saturated: false, allowed: queued.value };
  }

  async bufferRequest(request, privateResponse) {
    if (request.method !== 'POST') return { request };
    const ip = request.headers.get('cf-connecting-ip') || 'unknown';
    const activeForIP = this.activeBodyReadsByIP.get(ip) ?? 0;
    if (
      this.activeBodyReads >= MAX_CONCURRENT_BODY_READS
      || activeForIP >= MAX_CONCURRENT_BODY_READS_PER_IP
    ) {
      return { saturated: true };
    }

    this.activeBodyReads += 1;
    this.activeBodyReadsByIP.set(ip, activeForIP + 1);
    try {
      return await bufferCoordinatedRequest(
        request,
        privateResponse,
        requestBodyTimeout(this.env),
      );
    } finally {
      this.activeBodyReads -= 1;
      const remaining = (this.activeBodyReadsByIP.get(ip) ?? 1) - 1;
      if (remaining) this.activeBodyReadsByIP.set(ip, remaining);
      else this.activeBodyReadsByIP.delete(ip);
    }
  }

  async fetch(request) {
    const path = new URL(request.url).pathname;
    const isV2 = path.startsWith('/v2/') || path === '/v2/relationships';
    const isLegacySubmit = request.method === 'POST'
      && /^\/pit\/[^/]+\/submit$/.test(path);
    if (isV2) {
      const admission = await this.admitV2(request);
      if (admission.saturated) return v2RetryableError('service busy');
      if (!admission.allowed) return v2Error('too many requests', 429);
    } else if (isLegacySubmit) {
      const admission = await this.admitLegacySubmit(request);
      if (admission.saturated) return error('service busy', 503);
      if (!admission.allowed) return error('too many submit attempts', 429);
    }

    let routedRequest = request;
    const isPitCreate = request.method === 'POST' && path === '/pit';
    if ((isV2 && request.method === 'POST') || isPitCreate) {
      const buffered = await this.bufferRequest(request, isV2);
      if (buffered.saturated) {
        return isV2
          ? v2RetryableError('service busy')
          : error('service busy', 503);
      }
      if (buffered.response) return buffered.response;
      routedRequest = buffered.request;
    }

    if (request.method === 'GET') {
      if (isV2 && path.endsWith('/board')) {
        if (this.activeBoardReads >= MAX_CONCURRENT_BOARD_READS) {
          return v2RetryableError('service busy');
        }
        this.activeBoardReads += 1;
        try {
          return await coordinatedRoute(request, this.env, this.storage);
        } finally {
          this.activeBoardReads -= 1;
        }
      }
      if (isV2 && /\/member\/[^/]+$/.test(path)) {
        if (this.activeMemberReads >= MAX_CONCURRENT_MEMBER_READS) {
          return v2RetryableError('service busy');
        }
        this.activeMemberReads += 1;
        try {
          return await coordinatedRoute(request, this.env, this.storage);
        } finally {
          this.activeMemberReads -= 1;
        }
      }
      if (/^\/pit\/[^/]+\/board$/.test(path)) {
        if (this.activeLegacyBoardReads >= MAX_CONCURRENT_BOARD_READS) {
          return error('service busy', 503, true);
        }
        this.activeLegacyBoardReads += 1;
        try {
          return await coordinatedRoute(request, this.env, this.storage);
        } finally {
          this.activeLegacyBoardReads -= 1;
        }
      }
      return coordinatedRoute(request, this.env, this.storage);
    }

    const mutationQueue = isV2
      ? this.v2MutationQueue
      : this.legacyMutationQueue;
    const queued = await mutationQueue.run(() => (
      coordinatedRoute(routedRequest, this.env, this.storage)
    ));
    if (queued.saturated) {
      return isV2
        ? v2RetryableError('service busy')
        : error('service busy', 503);
    }
    return queued.value;
  }
}

function coordinatedFetch(request, env) {
  if (!env.COORDINATOR) return coordinatedRoute(request, env, env.__TEST_DO_STORAGE);
  const id = env.COORDINATOR.idFromName('global');
  return env.COORDINATOR.get(id).fetch(request);
}

async function bufferCoordinatedRequest(request, privateResponse, timeoutMs) {
  if (request.method !== 'POST') return { request };
  const body = await readTextBounded(request, timeoutMs);
  if (body.error) {
    return {
      response: privateResponse
        ? v2Error(body.error, body.status)
        : error(body.error, body.status),
    };
  }
  return {
    request: new Request(request.url, {
      method: request.method,
      headers: request.headers,
      body: body.text,
    }),
  };
}

async function route(request, env) {
  const url = new URL(request.url);
  const path = url.pathname;
  const now = new Date(env.__TEST_NOW || Date.now());

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (request.method === 'POST' && path === '/pit') {
    return coordinatedFetch(request, env);
  }

  if (path.startsWith('/v2/') || path === '/v2/relationships') {
    if (!env.COORDINATOR) {
      const buffered = await bufferCoordinatedRequest(
        request,
        true,
        requestBodyTimeout(env),
      );
      return buffered.response ?? coordinatedFetch(buffered.request, env);
    }
    return coordinatedFetch(request, env);
  }

  let match = path.match(/^\/pit\/([^/]+)\/(join|submit|rename)$/);
  if (request.method === 'POST' && match) {
    const buffered = await bufferCoordinatedRequest(request, false);
    return buffered.response ?? coordinatedFetch(buffered.request, env);
  }

  match = path.match(/^\/pit\/([^/]+)\/board$/);
  if (request.method === 'GET' && match) return coordinatedFetch(request, env);

  match = path.match(/^\/pit\/([^/]+)\/member\/([^/]+)$/);
  if (request.method === 'GET' && match) {
    return getMember(env, match[1], decodeURIComponent(match[2]));
  }

  return error('not found', 404, request.method === 'GET');
}

export { route as fetch };
export default { fetch: route };
