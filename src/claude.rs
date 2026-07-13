use std::collections::HashSet;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::BufRead;
use std::path::Path;

use chrono::{DateTime, Local, NaiveDate, Utc};
use walkdir::WalkDir;

use crate::agg::{Agg, Key, Source, Usage};
use crate::pricing::Pricing;

/// Scan ~/.claude/projects/**/*.jsonl. Each assistant message line carries a
/// `message.usage` block with token counts, model, and speed. Resumed sessions
/// copy history into new files, so entries are deduped on (message.id, requestId).
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

        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            if !line.contains("\"usage\"") || !line.contains("\"model\"") {
                continue;
            }
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
            let msg = &v["message"];
            let Some(model) = msg["model"].as_str() else { continue };
            if model == "<synthetic>" {
                continue;
            }
            let usage = &msg["usage"];
            if !usage.is_object() {
                continue;
            }

            let mut dedup = DefaultHasher::new();
            match (msg["id"].as_str(), v["requestId"].as_str()) {
                (None, None) => v["uuid"].as_str().unwrap_or("").hash(&mut dedup),
                (mid, rid) => (mid.unwrap_or(""), rid.unwrap_or("")).hash(&mut dedup),
            }
            if !seen.insert(dedup.finish()) {
                continue;
            }

            let (cache_w5m, cache_w1h) = match usage["cache_creation"].as_object() {
                Some(cc) => (
                    cc.get("ephemeral_5m_input_tokens").and_then(|x| x.as_u64()).unwrap_or(0),
                    cc.get("ephemeral_1h_input_tokens").and_then(|x| x.as_u64()).unwrap_or(0),
                ),
                None => (usage["cache_creation_input_tokens"].as_u64().unwrap_or(0), 0),
            };
            let u = Usage {
                input: usage["input_tokens"].as_u64().unwrap_or(0),
                cache_read: usage["cache_read_input_tokens"].as_u64().unwrap_or(0),
                cache_w5m,
                cache_w1h,
                output: usage["output_tokens"].as_u64().unwrap_or(0),
                reasoning: 0,
            };
            if u.is_zero() {
                continue;
            }

            let Some(date) = parse_date(v["timestamp"].as_str(), utc) else { continue };
            if min_date.is_some_and(|m| date < m) {
                continue;
            }

            let speed = usage["speed"].as_str().unwrap_or("standard").to_string();
            let key = Key { source: Source::Claude, model: model.to_string(), speed };
            agg.add(date, key, u, pricing.resolve(model));
        }
    }
    files
}

/// Bucket a timestamp into a calendar day, in UTC (leaderboard-comparable)
/// or the machine's local timezone.
pub fn parse_date(ts: Option<&str>, utc: bool) -> Option<NaiveDate> {
    let dt = DateTime::parse_from_rfc3339(ts?).ok()?;
    Some(if utc {
        dt.naive_utc().date()
    } else {
        dt.with_timezone(&Local).date_naive()
    })
}

/// Skip whole files last written before the cutoff: no record inside can be newer.
pub fn skip_by_mtime(path: &Path, min_date: Option<NaiveDate>, utc: bool) -> bool {
    let Some(min) = min_date else { return false };
    let Ok(meta) = path.metadata() else { return false };
    let Ok(mtime) = meta.modified() else { return false };
    let mtime_date = if utc {
        DateTime::<Utc>::from(mtime).date_naive()
    } else {
        DateTime::<Local>::from(mtime).date_naive()
    };
    mtime_date < min
}
