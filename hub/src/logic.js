// Pure logic for the brrrn hub. No Worker APIs here so everything is
// testable under plain node. All date math is UTC; "now" is always a
// parameter so tests stay deterministic.

export const STREAK_THRESHOLD_USD = 5;
export const MAX_DAYS_PER_REQUEST = 400;
export const MAX_MODELS_PER_DAY = 30;
export const MAX_MODEL_NAME_LEN = 64;

// Suffix charset: a-z0-9 without the ambiguous l/1/o/0.
export const CODE_CHARS = 'abcdefghijkmnpqrstuvwxyz23456789';

export const WORDS = [
  'acorn', 'amber', 'anchor', 'apple', 'arrow', 'aspen', 'atlas', 'autumn', 'badge', 'bamboo',
  'basil', 'beach', 'beacon', 'berry', 'birch', 'bison', 'blaze', 'bloom', 'bluff', 'breeze',
  'brick', 'brook', 'cabin', 'candle', 'canyon', 'cedar', 'charm', 'cherry', 'cliff', 'cloud',
  'clover', 'cobalt', 'comet', 'coral', 'cove', 'crane', 'creek', 'crest', 'crisp', 'dawn',
  'delta', 'desert', 'drift', 'dune', 'dusk', 'eagle', 'earth', 'echo', 'elder', 'ember',
  'falcon', 'fern', 'field', 'fig', 'flame', 'flare', 'flint', 'forge', 'fox', 'frost',
  'gale', 'garnet', 'geyser', 'ginger', 'glade', 'gleam', 'glen', 'glow', 'gorge', 'grove',
  'gust', 'harbor', 'hawk', 'hazel', 'heron', 'hill', 'holly', 'honey', 'ice', 'iris',
  'iron', 'ivory', 'ivy', 'jade', 'jasper', 'juniper', 'kelp', 'kiln', 'lagoon', 'lake',
  'lark', 'lava', 'leaf', 'ledge', 'lemon', 'lilac', 'lily', 'linen', 'lotus', 'lunar',
  'maple', 'marble', 'marsh', 'meadow', 'mesa', 'mint', 'mist', 'moon', 'moss', 'night',
  'north', 'nova', 'oak', 'ocean', 'onyx', 'opal', 'orbit', 'otter', 'palm', 'peak',
  'pearl', 'pebble', 'pine', 'plume', 'pond', 'poppy', 'prism', 'quartz', 'quill', 'rain',
  'raven', 'reef', 'ridge', 'river', 'robin', 'rowan', 'sage', 'sand', 'shale', 'shore',
  'silver', 'sky', 'slate', 'smoke', 'snow', 'solar', 'spark', 'spruce', 'star', 'stone',
];

export function generateJoinCode(rng = Math.random) {
  const pick = (pool) => pool[Math.floor(rng() * pool.length)];
  let suffix = '';
  for (let i = 0; i < 4; i++) suffix += pick(CODE_CHARS);
  return `${pick(WORDS)}-${pick(WORDS)}-${suffix}`;
}

export function normalizeHandle(handle) {
  if (typeof handle !== 'string') return null;
  const h = handle.toLowerCase();
  return /^[a-z0-9_-]{1,24}$/.test(h) ? h : null;
}

// ---- UTC window math ----

function toDate(now) {
  return now instanceof Date ? now : new Date(now);
}

export function utcDay(now) {
  return toDate(now).toISOString().slice(0, 10);
}

export function addDays(dateStr, n) {
  const [y, m, d] = dateStr.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d) + n * 86400000).toISOString().slice(0, 10);
}

// Monday 00:00 UTC of the ISO week containing `now`.
export function isoWeekStart(now) {
  const d = toDate(now);
  const sinceMonday = (d.getUTCDay() + 6) % 7;
  return addDays(utcDay(d), -sinceMonday);
}

export function monthStart(now) {
  return utcDay(now).slice(0, 7) + '-01';
}

// ---- day record validation ----

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function validDateString(value) {
  if (typeof value !== 'string' || !DATE_RE.test(value)) return false;
  const [year, month, day] = value.split('-').map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year
    && date.getUTCMonth() === month - 1
    && date.getUTCDate() === day;
}

function finiteNonNeg(v) {
  return typeof v === 'number' && Number.isFinite(v) && v >= 0;
}

function optionalUsd(v) {
  return v === undefined ? 0 : v;
}

// Validates a submit `days` array. Returns {ok:true, days:[{date, rec}]}
// with records compacted to the stored {t, c, cc, cx, models} shape,
// or {ok:false, error}.
export function validateDays(days) {
  if (!Array.isArray(days)) return { ok: false, error: 'days must be an array' };
  if (days.length > MAX_DAYS_PER_REQUEST) {
    return { ok: false, error: `too many days (max ${MAX_DAYS_PER_REQUEST})` };
  }
  const out = [];
  for (const d of days) {
    if (typeof d !== 'object' || d === null || Array.isArray(d)) {
      return { ok: false, error: 'each day must be an object' };
    }
    if (!validDateString(d.date)) {
      return { ok: false, error: `invalid date: ${JSON.stringify(d.date)}` };
    }
    const tokens = d.tokens;
    const cost = d.cost_usd;
    const claude = optionalUsd(d.claude_usd);
    const codex = optionalUsd(d.codex_usd);
    if (![tokens, cost, claude, codex].every(finiteNonNeg)) {
      return { ok: false, error: `invalid numbers for ${d.date}` };
    }
    const models = {};
    if (d.models !== undefined) {
      if (typeof d.models !== 'object' || d.models === null || Array.isArray(d.models)) {
        return { ok: false, error: `models must be an object for ${d.date}` };
      }
      const names = Object.keys(d.models);
      if (names.length > MAX_MODELS_PER_DAY) {
        return { ok: false, error: `too many models for ${d.date} (max ${MAX_MODELS_PER_DAY})` };
      }
      for (const name of names) {
        if (name.length === 0 || name.length > MAX_MODEL_NAME_LEN) {
          return { ok: false, error: `invalid model name for ${d.date}` };
        }
        const m = d.models[name];
        if (
          typeof m !== 'object' || m === null ||
          ![m.input_tokens, m.output_tokens, m.cost_usd].every(finiteNonNeg)
        ) {
          return { ok: false, error: `invalid model entry ${name} for ${d.date}` };
        }
        models[name] = { i: m.input_tokens, o: m.output_tokens, c: m.cost_usd };
      }
    }
    out.push({ date: d.date, rec: { t: tokens, c: cost, cc: claude, cx: codex, models } });
  }
  return { ok: true, days: out };
}

// Overwrites per date, keeps other dates. Never mutates `existing`.
export function mergeDayRecords(existing, validatedDays) {
  const merged = { ...(existing || {}) };
  for (const { date, rec } of validatedDays) merged[date] = rec;
  return merged;
}

// ---- streak ----

// Consecutive UTC days with cost >= threshold, counting back from today.
// An incomplete today below the threshold does not break the streak: the
// count then starts from yesterday instead.
export function computeStreak(costByDate, now, threshold = STREAK_THRESHOLD_USD) {
  const today = utcDay(now);
  let cursor = today;
  if ((costByDate[today] ?? 0) < threshold) cursor = addDays(today, -1);
  let streak = 0;
  while ((costByDate[cursor] ?? 0) >= threshold) {
    streak += 1;
    cursor = addDays(cursor, -1);
  }
  return streak;
}

// ---- board aggregation ----

// machineRecords: array of stored day-record maps, one per machine_id.
export function aggregateMember(machineRecords, now) {
  const today = utcDay(now);
  const weekStart = isoWeekStart(now);
  const mStart = monthStart(now);
  const costByDate = {};
  let todayUsd = 0;
  let weekUsd = 0;
  let monthUsd = 0;
  const weekModels = {};

  for (const rec of machineRecords) {
    for (const [date, d] of Object.entries(rec)) {
      const cost = d.c || 0;
      costByDate[date] = (costByDate[date] || 0) + cost;
      if (date > today) continue;
      if (date === today) todayUsd += cost;
      if (date >= mStart) monthUsd += cost;
      if (date >= weekStart) {
        weekUsd += cost;
        for (const [name, m] of Object.entries(d.models || {})) {
          const agg = (weekModels[name] ??= { input_tokens: 0, output_tokens: 0, cost_usd: 0 });
          agg.input_tokens += m.i || 0;
          agg.output_tokens += m.o || 0;
          agg.cost_usd += m.c || 0;
        }
      }
    }
  }

  const modelsWeek = Object.entries(weekModels)
    .map(([model, m]) => ({ model, ...m }))
    .sort((a, b) => b.cost_usd - a.cost_usd || a.model.localeCompare(b.model));

  return {
    today_usd: todayUsd,
    week_usd: weekUsd,
    month_usd: monthUsd,
    streak_days: computeStreak(costByDate, now),
    top_model: modelsWeek.length ? modelsWeek[0].model : null,
    models_week: modelsWeek,
  };
}

// Per-day totals for one member, summed across machines, sorted date asc.
export function memberSeries(machineRecords) {
  const byDate = {};
  for (const rec of machineRecords) {
    for (const [date, d] of Object.entries(rec)) {
      const e = (byDate[date] ??= { date, tokens: 0, cost_usd: 0 });
      e.tokens += d.t || 0;
      e.cost_usd += d.c || 0;
    }
  }
  return Object.values(byDate).sort((a, b) => a.date.localeCompare(b.date));
}
