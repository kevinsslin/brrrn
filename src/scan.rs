use std::collections::HashSet;
use std::path::Path;

use chrono::{DateTime, Local, NaiveDate, Utc};
use walkdir::WalkDir;

use crate::agg::{Agg, Entry};
use crate::cache::{fingerprint, ScanCache};
use crate::pricing::Pricing;
use crate::{claude, codex};

#[derive(Default)]
pub struct ScanStats {
    pub files_total: u64,
    pub files_scanned: u64,
    pub files_cached: u64,
    pub records: u64,
    pub cache_error: Option<String>,
}

/// Skip whole files last written before the cutoff: no record inside can be newer.
pub fn skip_by_mtime(path: &Path, min_date: Option<NaiveDate>, utc: bool) -> bool {
    let Some(min) = min_date else { return false };
    let Ok(meta) = path.metadata() else {
        return false;
    };
    let Ok(mtime) = meta.modified() else {
        return false;
    };
    let mtime_date = if utc {
        DateTime::<Utc>::from(mtime).date_naive()
    } else {
        DateTime::<Local>::from(mtime).date_naive()
    };
    mtime_date < min
}

pub fn add_entries(
    agg: &mut Agg,
    entries: &[Entry],
    pricing: &Pricing,
    min_date: Option<NaiveDate>,
) {
    for e in entries {
        let price = pricing.resolve_for_speed(&e.model, &e.speed);
        agg.add_streak_entry(e, price);
        if min_date.is_none_or(|m| e.date >= m) {
            agg.add_report_entry(e, price);
        }
    }
}

fn jsonl_files(dir: &Path, min_date: Option<NaiveDate>, utc: bool) -> Vec<std::path::PathBuf> {
    let mut files: Vec<_> = WalkDir::new(dir)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.file_type().is_file()
                && e.path().extension().is_some_and(|x| x == "jsonl")
                && !skip_by_mtime(e.path(), min_date, utc)
        })
        .map(|e| e.into_path())
        .collect();
    files.sort();
    files
}

fn newest_first(files: &mut [std::path::PathBuf]) {
    files.sort_by(|a, b| {
        let modified = |path: &Path| path.metadata().and_then(|meta| meta.modified()).ok();
        modified(b).cmp(&modified(a)).then_with(|| a.cmp(b))
    });
}

pub fn scan_all(
    claude_dir: &Path,
    codex_dir: &Path,
    pricing: &Pricing,
    min_date: Option<NaiveDate>,
    utc: bool,
    cache_path: Option<&Path>,
) -> (Agg, ScanStats) {
    let mut agg = Agg::default();
    let mut stats = ScanStats::default();
    let mut cache = cache_path.map(|p| ScanCache::load(p, utc));

    if claude_dir.exists() {
        let mut seen: HashSet<u64> = HashSet::new();
        let mut files = jsonl_files(claude_dir, None, utc);
        // Resumed sessions can carry a partial copy of a message whose
        // finalized usage appears in the newer file. Let that copy own the
        // global dedupe claim; exact history copies still collapse normally.
        newest_first(&mut files);
        for path in files {
            stats.files_total += 1;
            let cached = cache
                .as_mut()
                .and_then(|c| c.take_if_fresh(&path, &mut seen));
            let (entries, records) = match cached {
                Some((entries, records)) => {
                    stats.files_cached += 1;
                    (entries, records)
                }
                None => {
                    stats.files_scanned += 1;
                    let before = fingerprint(&path);
                    let (entries, claims, dependencies, complete) =
                        claude::scan_file(&path, &mut seen, utc);
                    let records = entries.len() as u64;
                    if let (Some(c), Some(before)) = (cache.as_mut(), before) {
                        if complete {
                            c.store_if_unchanged(&path, before, &entries, &claims, &dependencies);
                        }
                    }
                    (entries, records)
                }
            };
            stats.records += records;
            add_entries(&mut agg, &entries, pricing, min_date);
        }
    }
    if codex_dir.exists() {
        let mut seen: HashSet<u64> = HashSet::new();
        for path in jsonl_files(codex_dir, None, utc) {
            stats.files_total += 1;
            let cached = cache
                .as_mut()
                .and_then(|c| c.take_if_fresh(&path, &mut seen));
            let (entries, records) = match cached {
                Some((entries, records)) => {
                    stats.files_cached += 1;
                    (entries, records)
                }
                None => {
                    stats.files_scanned += 1;
                    let before = fingerprint(&path);
                    let (entries, claims, dependencies, complete) =
                        codex::scan_file(&path, &mut seen, utc);
                    let records = entries.len() as u64;
                    if let (Some(c), Some(before)) = (cache.as_mut(), before) {
                        if complete {
                            c.store_if_unchanged(&path, before, &entries, &claims, &dependencies);
                        }
                    }
                    (entries, records)
                }
            };
            stats.records += records;
            add_entries(&mut agg, &entries, pricing, min_date);
        }
    }
    if let Some(c) = cache {
        if let Err(e) = c.save() {
            stats.cache_error = Some(e.to_string());
        }
    }
    (agg, stats)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agg::{Entry, Source, Usage};

    fn temp(name: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!("brrrn-scan-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn period_filter_does_not_truncate_streak_history() {
        let pricing = Pricing::from_json_str(
            r#"{"m":{"input_cost_per_token":1.0,"output_cost_per_token":1.0}}"#,
        )
        .unwrap();
        let entries: Vec<Entry> = ["2026-07-11", "2026-07-12", "2026-07-13"]
            .into_iter()
            .map(|d| Entry {
                date: d.parse().unwrap(),
                hour: 0,
                source: Source::Claude,
                model: "m".to_string(),
                speed: "standard".to_string(),
                usage: Usage {
                    input: 5,
                    ..Default::default()
                },
            })
            .collect();
        let mut agg = Agg::default();
        add_entries(
            &mut agg,
            &entries,
            &pricing,
            Some("2026-07-13".parse().unwrap()),
        );

        assert_eq!(agg.records, 1); // report is one day
        assert_eq!(agg.daily.len(), 1);
        assert_eq!(agg.daily_cost().len(), 3); // streak still sees all three
    }

    #[test]
    fn resumed_claude_files_prefer_the_newer_finalized_usage() {
        let root = temp("claude-resume-finalized");
        let claude_dir = root.join("claude");
        let codex_dir = root.join("codex");
        std::fs::create_dir_all(&claude_dir).unwrap();
        std::fs::create_dir_all(&codex_dir).unwrap();
        let partial = r#"{"timestamp":"2026-07-13T23:30:00.000Z","requestId":"r-stream","message":{"id":"m-stream","model":"claude-test","usage":{"input_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":25708,"output_tokens":7,"iterations":[]}}}"#;
        let finalized = r#"{"timestamp":"2026-07-13T23:30:01.000Z","requestId":"r-stream","message":{"id":"m-stream","model":"claude-test","usage":{"input_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":25708,"output_tokens":134,"iterations":[{"type":"message","input_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":25708,"output_tokens":134}]}}}"#;
        std::fs::write(claude_dir.join("a-partial.jsonl"), partial).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
        std::fs::write(claude_dir.join("z-finalized.jsonl"), finalized).unwrap();
        let pricing = Pricing::from_json_str(
            r#"{"claude-test":{"input_cost_per_token":1.0,"output_cost_per_token":1.0}}"#,
        )
        .unwrap();

        let (agg, _) = scan_all(&claude_dir, &codex_dir, &pricing, None, true, None);

        let (_, (usage, _)) = agg.by_key.iter().next().unwrap();
        assert_eq!(usage.cache_w5m, 25_708);
        assert_eq!(usage.output, 134);
    }

    #[test]
    fn priority_service_tier_uses_litellm_priority_prices() {
        let pricing = Pricing::from_json_str(
            r#"{
                "gpt-test": {
                    "input_cost_per_token": 1.0,
                    "output_cost_per_token": 4.0,
                    "cache_read_input_token_cost": 0.1,
                    "input_cost_per_token_priority": 2.0,
                    "output_cost_per_token_priority": 8.0,
                    "cache_read_input_token_cost_priority": 0.2
                }
            }"#,
        )
        .unwrap();
        let entry = Entry {
            date: "2026-07-13".parse().unwrap(),
            hour: 0,
            source: Source::Codex,
            model: "gpt-test".to_string(),
            speed: "xhigh priority".to_string(),
            usage: Usage {
                input: 10,
                cache_read: 20,
                output: 3,
                ..Default::default()
            },
        };
        let mut agg = Agg::default();

        add_entries(&mut agg, &[entry], &pricing, None);

        let day = &agg.daily[&"2026-07-13".parse().unwrap()][&Source::Codex];
        assert_eq!(day.cost, 10.0 * 2.0 + 20.0 * 0.2 + 3.0 * 8.0);
    }

    #[test]
    fn flex_service_tier_uses_litellm_flex_prices() {
        let pricing = Pricing::from_json_str(
            r#"{
                "gpt-test": {
                    "input_cost_per_token": 1.0,
                    "output_cost_per_token": 4.0,
                    "cache_read_input_token_cost": 0.1,
                    "input_cost_per_token_flex": 0.5,
                    "output_cost_per_token_flex": 2.0,
                    "cache_read_input_token_cost_flex": 0.05
                }
            }"#,
        )
        .unwrap();
        let entry = Entry {
            date: "2026-07-13".parse().unwrap(),
            hour: 0,
            source: Source::Codex,
            model: "gpt-test".to_string(),
            speed: "high flex".to_string(),
            usage: Usage {
                input: 10,
                cache_read: 20,
                output: 3,
                ..Default::default()
            },
        };
        let mut agg = Agg::default();

        add_entries(&mut agg, &[entry], &pricing, None);

        let day = &agg.daily[&"2026-07-13".parse().unwrap()][&Source::Codex];
        assert_eq!(day.cost, 10.0 * 0.5 + 20.0 * 0.05 + 3.0 * 2.0);
    }
}
