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
        let price = pricing.resolve(&e.model);
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
        for path in jsonl_files(claude_dir, None, utc) {
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
}
