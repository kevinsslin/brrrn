import test from 'node:test';
import assert from 'node:assert/strict';
import {
  WORDS,
  CODE_CHARS,
  STREAK_THRESHOLD_USD,
  MAX_DAYS_PER_REQUEST,
  generateJoinCode,
  normalizeHandle,
  utcDay,
  addDays,
  isoWeekStart,
  monthStart,
  validateDays,
  mergeDayRecords,
  computeStreak,
  aggregateMember,
  memberSeries,
} from '../src/logic.js';

// Fixed "now": Wednesday 2026-01-07. ISO week starts Monday 2026-01-05.
const NOW = '2026-01-07T12:00:00Z';

function seqRng(values) {
  let i = 0;
  return () => values[i++ % values.length];
}

function day(overrides = {}) {
  return {
    date: '2026-01-07',
    tokens: 100,
    cost_usd: 1.5,
    claude_usd: 1,
    codex_usd: 0.5,
    models: { 'claude-fable-5': { input_tokens: 80, output_tokens: 20, cost_usd: 1.5 } },
    ...overrides,
  };
}

// ---- join codes ----

test('word list is large, lowercase, and duplicate free', () => {
  assert.ok(WORDS.length >= 140, `expected >= 140 words, got ${WORDS.length}`);
  assert.equal(new Set(WORDS).size, WORDS.length);
  for (const w of WORDS) assert.match(w, /^[a-z]+$/);
});

test('code charset excludes ambiguous characters', () => {
  for (const c of ['l', '1', 'o', '0']) assert.ok(!CODE_CHARS.includes(c));
  assert.match(CODE_CHARS, /^[a-z2-9]+$/);
});

test('generateJoinCode format is word-word-xxxx', () => {
  for (let i = 0; i < 50; i++) {
    const code = generateJoinCode();
    const m = code.match(/^([a-z]+)-([a-z]+)-([a-z0-9]{4})$/);
    assert.ok(m, `bad code ${code}`);
    assert.ok(WORDS.includes(m[1]));
    assert.ok(WORDS.includes(m[2]));
    for (const c of m[3]) assert.ok(CODE_CHARS.includes(c));
  }
});

test('generateJoinCode is deterministic under an injected rng', () => {
  const low = generateJoinCode(seqRng([0]));
  assert.equal(low, `${WORDS[0]}-${WORDS[0]}-${CODE_CHARS[0].repeat(4)}`);
  const high = generateJoinCode(seqRng([0.999999]));
  const lastWord = WORDS[WORDS.length - 1];
  const lastChar = CODE_CHARS[CODE_CHARS.length - 1];
  assert.equal(high, `${lastWord}-${lastWord}-${lastChar.repeat(4)}`);
});

// ---- handles ----

test('normalizeHandle lowercases and validates', () => {
  assert.equal(normalizeHandle('Kevin'), 'kevin');
  assert.equal(normalizeHandle('a_b-9'), 'a_b-9');
  assert.equal(normalizeHandle('x'.repeat(24)), 'x'.repeat(24));
  assert.equal(normalizeHandle(''), null);
  assert.equal(normalizeHandle('x'.repeat(25)), null);
  assert.equal(normalizeHandle('has space'), null);
  assert.equal(normalizeHandle('emoji🔥'), null);
  assert.equal(normalizeHandle(42), null);
  assert.equal(normalizeHandle(null), null);
});

// ---- UTC window math ----

test('utcDay handles Date and string inputs', () => {
  assert.equal(utcDay(new Date('2026-01-07T23:59:59Z')), '2026-01-07');
  assert.equal(utcDay('2026-01-07T00:00:00Z'), '2026-01-07');
});

test('addDays crosses month and year boundaries', () => {
  assert.equal(addDays('2026-01-01', -1), '2025-12-31');
  assert.equal(addDays('2026-01-31', 1), '2026-02-01');
  assert.equal(addDays('2026-01-07', 0), '2026-01-07');
});

test('isoWeekStart on a Monday is the same day', () => {
  assert.equal(isoWeekStart('2026-01-05T00:00:00Z'), '2026-01-05');
  assert.equal(isoWeekStart('2026-01-05T23:59:59Z'), '2026-01-05');
});

test('isoWeekStart on a Sunday is the previous Monday', () => {
  assert.equal(isoWeekStart('2026-01-04T12:00:00Z'), '2025-12-29');
});

test('isoWeekStart mid-week and across a year boundary', () => {
  assert.equal(isoWeekStart(NOW), '2026-01-05');
  // Thursday 2026-01-01 belongs to the week starting Monday 2025-12-29.
  assert.equal(isoWeekStart('2026-01-01T08:00:00Z'), '2025-12-29');
});

test('monthStart is the first of the current UTC month', () => {
  assert.equal(monthStart(NOW), '2026-01-01');
  assert.equal(monthStart('2025-12-31T23:59:59Z'), '2025-12-01');
});

// ---- streak ----

test('streak threshold constant is 5', () => {
  assert.equal(STREAK_THRESHOLD_USD, 5);
});

test('streak of empty history is 0', () => {
  assert.equal(computeStreak({}, NOW), 0);
});

test('today exactly at the threshold counts', () => {
  assert.equal(computeStreak({ '2026-01-07': 5 }, NOW), 1);
});

test('consecutive qualifying days count back from today', () => {
  const costs = { '2026-01-07': 10, '2026-01-06': 6, '2026-01-05': 5.5 };
  assert.equal(computeStreak(costs, NOW), 3);
});

test('incomplete today below threshold does not break the streak', () => {
  const costs = { '2026-01-07': 2, '2026-01-06': 6, '2026-01-05': 8 };
  assert.equal(computeStreak(costs, NOW), 2);
});

test('today and yesterday both below threshold means 0', () => {
  const costs = { '2026-01-07': 2, '2026-01-06': 1, '2026-01-05': 9 };
  assert.equal(computeStreak(costs, NOW), 0);
});

test('a gap breaks the streak', () => {
  const costs = { '2026-01-07': 10, '2026-01-05': 10, '2026-01-04': 10 };
  assert.equal(computeStreak(costs, NOW), 1);
});

test('a below-threshold day breaks the streak', () => {
  const costs = { '2026-01-07': 10, '2026-01-06': 4.99, '2026-01-05': 10 };
  assert.equal(computeStreak(costs, NOW), 1);
});

test('streak crosses month and year boundaries', () => {
  const costs = { '2026-01-02': 6, '2026-01-01': 6, '2025-12-31': 6 };
  assert.equal(computeStreak(costs, '2026-01-02T09:00:00Z'), 3);
});

// ---- day record validation ----

test('validateDays accepts a well formed record and compacts it', () => {
  const res = validateDays([day()]);
  assert.equal(res.ok, true);
  assert.equal(res.days.length, 1);
  assert.equal(res.days[0].date, '2026-01-07');
  assert.deepEqual(res.days[0].rec, {
    t: 100,
    c: 1.5,
    cc: 1,
    cx: 0.5,
    models: { 'claude-fable-5': { i: 80, o: 20, c: 1.5 } },
  });
});

test('validateDays treats missing split and models as zero', () => {
  const res = validateDays([
    { date: '2026-01-07', tokens: 10, cost_usd: 0.25 },
  ]);
  assert.equal(res.ok, true);
  assert.deepEqual(res.days[0].rec, { t: 10, c: 0.25, cc: 0, cx: 0, models: {} });
});

test('validateDays rejects non-arrays and malformed dates', () => {
  assert.equal(validateDays(null).ok, false);
  assert.equal(validateDays('nope').ok, false);
  for (const bad of ['2026/01/07', '26-01-07', '2026-1-7', 'garbage', '2026-01-07T00:00:00Z', '2026-02-30', '2026-13-01']) {
    assert.equal(validateDays([day({ date: bad })]).ok, false, `accepted ${bad}`);
  }
});

test('validateDays rejects negative and non-finite numbers', () => {
  assert.equal(validateDays([day({ tokens: -1 })]).ok, false);
  assert.equal(validateDays([day({ cost_usd: -0.01 })]).ok, false);
  assert.equal(validateDays([day({ claude_usd: Infinity })]).ok, false);
  assert.equal(validateDays([day({ codex_usd: NaN })]).ok, false);
  assert.equal(validateDays([day({ tokens: '100' })]).ok, false);
  const badModel = day({ models: { m: { input_tokens: -5, output_tokens: 0, cost_usd: 0 } } });
  assert.equal(validateDays([badModel]).ok, false);
});

test('validateDays rejects oversize payload shapes', () => {
  assert.equal(MAX_DAYS_PER_REQUEST, 400);
  const many = Array.from({ length: 401 }, (_, i) => day({ date: `2025-01-${String((i % 28) + 1).padStart(2, '0')}` }));
  assert.equal(validateDays(many).ok, false);
  assert.equal(validateDays(Array.from({ length: 400 }, () => day())).ok, true);

  const models = {};
  for (let i = 0; i < 31; i++) models[`model-${i}`] = { input_tokens: 1, output_tokens: 1, cost_usd: 0.1 };
  assert.equal(validateDays([day({ models })]).ok, false);

  const longName = { [`m${'x'.repeat(64)}`]: { input_tokens: 1, output_tokens: 1, cost_usd: 0.1 } };
  assert.equal(validateDays([day({ models: longName })]).ok, false);
});

// ---- merge ----

test('mergeDayRecords overwrites per date and keeps other dates', () => {
  const existing = {
    '2026-01-05': { t: 1, c: 1, cc: 1, cx: 0, models: {} },
    '2026-01-06': { t: 2, c: 2, cc: 2, cx: 0, models: {} },
  };
  const incoming = validateDays([
    day({ date: '2026-01-06', tokens: 99, cost_usd: 9 }),
    day({ date: '2026-01-07', tokens: 7, cost_usd: 0.75 }),
  ]);
  assert.equal(incoming.ok, true);
  const merged = mergeDayRecords(existing, incoming.days);
  assert.deepEqual(Object.keys(merged).sort(), ['2026-01-05', '2026-01-06', '2026-01-07']);
  assert.equal(merged['2026-01-05'].t, 1);
  assert.equal(merged['2026-01-06'].t, 99);
  assert.equal(merged['2026-01-06'].c, 9);
  assert.equal(merged['2026-01-07'].c, 0.75);
  // Existing input is not mutated.
  assert.equal(existing['2026-01-06'].t, 2);
});

// ---- board aggregation ----

test('aggregateMember sums windows across machines', () => {
  const machineA = {
    '2026-01-07': { t: 100, c: 4, cc: 4, cx: 0, models: { fable: { i: 10, o: 5, c: 4 } } },
    '2026-01-04': { t: 10, c: 7, cc: 0, cx: 7, models: { codex: { i: 3, o: 1, c: 7 } } },
  };
  const machineB = {
    '2026-01-07': { t: 50, c: 3, cc: 1, cx: 2, models: { fable: { i: 1, o: 1, c: 1 }, codex: { i: 2, o: 2, c: 2 } } },
  };
  const agg = aggregateMember([machineA, machineB], NOW);
  assert.equal(agg.today_usd, 7);
  // 2026-01-04 is a Sunday: prior ISO week, same month.
  assert.equal(agg.week_usd, 7);
  assert.equal(agg.month_usd, 14);
  // today 7 >= 5, yesterday empty.
  assert.equal(agg.streak_days, 1);
  assert.equal(agg.top_model, 'fable');
  assert.deepEqual(agg.models_week, [
    { model: 'fable', input_tokens: 11, output_tokens: 6, cost_usd: 5 },
    { model: 'codex', input_tokens: 2, output_tokens: 2, cost_usd: 2 },
  ]);
});

test('aggregateMember with no data is all zeroes', () => {
  const agg = aggregateMember([], NOW);
  assert.deepEqual(agg, {
    today_usd: 0,
    week_usd: 0,
    month_usd: 0,
    streak_days: 0,
    top_model: null,
    models_week: [],
  });
});

test('aggregateMember week window includes Monday and excludes prior Sunday', () => {
  const rec = {
    '2026-01-05': { t: 1, c: 2, cc: 2, cx: 0, models: {} },
    '2026-01-04': { t: 1, c: 100, cc: 100, cx: 0, models: {} },
  };
  const agg = aggregateMember([rec], NOW);
  assert.equal(agg.week_usd, 2);
  assert.equal(agg.month_usd, 102);
});

test('aggregateMember ignores future dates in window sums', () => {
  const rec = { '2026-01-08': { t: 1, c: 50, cc: 50, cx: 0, models: {} } };
  const agg = aggregateMember([rec], NOW);
  assert.equal(agg.today_usd, 0);
  assert.equal(agg.week_usd, 0);
  assert.equal(agg.month_usd, 0);
});

// ---- member series ----

test('memberSeries sums across machines and sorts by date asc', () => {
  const machineA = {
    '2026-01-07': { t: 100, c: 4, cc: 4, cx: 0, models: {} },
    '2026-01-04': { t: 10, c: 7, cc: 0, cx: 7, models: {} },
  };
  const machineB = {
    '2026-01-07': { t: 50, c: 3, cc: 1, cx: 2, models: {} },
  };
  assert.deepEqual(memberSeries([machineA, machineB]), [
    { date: '2026-01-04', tokens: 10, cost_usd: 7 },
    { date: '2026-01-07', tokens: 150, cost_usd: 7 },
  ]);
});

test('memberSeries of nothing is empty', () => {
  assert.deepEqual(memberSeries([]), []);
});
