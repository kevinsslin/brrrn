use std::collections::HashSet;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::BufRead;
use std::path::Path;

use chrono::NaiveDate;
use walkdir::WalkDir;

use crate::agg::{Agg, Key, Source, Usage};
use crate::claude::{parse_date, skip_by_mtime};
use crate::pricing::Pricing;

#[derive(Clone, Copy, Default, PartialEq)]
struct Totals {
    input: u64,
    cached: u64,
    output: u64,
    reasoning: u64,
}

fn totals(v: &serde_json::Value) -> Totals {
    Totals {
        input: v["input_tokens"].as_u64().unwrap_or(0),
        cached: v["cached_input_tokens"].as_u64().unwrap_or(0),
        output: v["output_tokens"].as_u64().unwrap_or(0),
        reasoning: v["reasoning_output_tokens"].as_u64().unwrap_or(0),
    }
}

/// Scan ~/.codex/sessions/**/*.jsonl rollout files. `token_count` events carry
/// cumulative totals per session; we take deltas between consecutive events and
/// attribute them to the model/effort from the most recent `turn_context`.
/// Rollouts forked from another session replay old events verbatim, so events
/// are deduped globally on (timestamp, totals) before counting.
pub fn scan(
    dir: &Path,
    pricing: &Pricing,
    agg: &mut Agg,
    min_date: Option<NaiveDate>,
    utc: bool,
) -> u64 {
    let mut seen: HashSet<u64> = HashSet::new();
    let mut files = 0u64;

    for entry in WalkDir::new(dir).into_iter().filter_map(|e| e.ok()) {
        if !entry.file_type().is_file()
            || entry.path().extension().is_none_or(|e| e != "jsonl")
            || skip_by_mtime(entry.path(), min_date, utc)
        {
            continue;
        }
        files += 1;
        let Ok(file) = std::fs::File::open(entry.path()) else { continue };
        let mut reader = std::io::BufReader::with_capacity(1 << 20, file);
        let mut line = String::new();

        let mut cur_model: Option<String> = None;
        let mut cur_effort: String = "default".to_string();
        let mut prev: Option<Totals> = None;

        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }

            if line.contains("\"turn_context\"") {
                let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
                let p = &v["payload"];
                if let Some(m) = p["model"].as_str() {
                    cur_model = Some(m.to_string());
                }
                if let Some(e) = p["effort"]
                    .as_str()
                    .or_else(|| p["collaboration_mode"]["settings"]["reasoning_effort"].as_str())
                {
                    cur_effort = e.to_string();
                }
                continue;
            }
            if !line.contains("\"token_count\"") {
                continue;
            }
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
            let info = &v["payload"]["info"];
            if !info.is_object() {
                continue; // older schema logs token_count with info: null
            }
            let total = totals(&info["total_token_usage"]);

            let delta = match prev {
                None => total,
                Some(p) if total.input >= p.input && total.output >= p.output => Totals {
                    input: total.input - p.input,
                    cached: total.cached.saturating_sub(p.cached),
                    output: total.output - p.output,
                    reasoning: total.reasoning.saturating_sub(p.reasoning),
                },
                // Cumulative counter went backwards (context reset); fall back
                // to the last request's own usage.
                Some(_) => totals(&info["last_token_usage"]),
            };
            prev = Some(total);

            let ts = v["timestamp"].as_str().unwrap_or("");
            let mut dedup = DefaultHasher::new();
            (ts, total.input, total.output, total.cached).hash(&mut dedup);
            if !seen.insert(dedup.finish()) {
                continue;
            }

            let u = Usage {
                input: delta.input.saturating_sub(delta.cached),
                cache_read: delta.cached,
                cache_w5m: 0,
                cache_w1h: 0,
                output: delta.output,
                reasoning: delta.reasoning,
            };
            if u.is_zero() {
                continue;
            }
            let Some(date) = parse_date(v["timestamp"].as_str(), utc) else { continue };
            if min_date.is_some_and(|m| date < m) {
                continue;
            }

            let model = cur_model.clone().unwrap_or_else(|| "unknown".to_string());
            let key = Key { source: Source::Codex, model: model.clone(), speed: cur_effort.clone() };
            agg.add(date, key, u, pricing.resolve(&model));
        }
    }
    files
}
