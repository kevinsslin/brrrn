use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::agg::{Entry, Source, Usage};

const CACHE_VERSION: u32 = 4;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Fingerprint {
    size: u64,
    mtime_ns: u128,
}

#[derive(Serialize, Deserialize, Default)]
struct CacheFile {
    version: u32,
    timezone: String,
    files: HashMap<String, CachedFile>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct CachedFile {
    size: u64,
    mtime_ns: u128,
    records: u64,
    claims: Vec<u64>,
    dependencies: Vec<u64>,
    entries: Vec<CachedEntry>,
}

#[derive(Serialize, Deserialize, Clone)]
struct CachedEntry {
    date: String,
    source: u8,
    model: String,
    speed: String,
    usage: [u64; 6],
}

pub struct ScanCache {
    path: PathBuf,
    timezone: String,
    files: HashMap<String, CachedFile>,
    touched: HashSet<String>,
}

impl ScanCache {
    pub fn load(path: &Path, utc: bool) -> Self {
        let timezone = if utc { "utc" } else { "local" }.to_string();
        let files = std::fs::read_to_string(path)
            .ok()
            .and_then(|raw| serde_json::from_str::<CacheFile>(&raw).ok())
            .filter(|c| c.version == CACHE_VERSION && c.timezone == timezone)
            .map(|c| c.files)
            .unwrap_or_default();
        Self {
            path: path.to_path_buf(),
            timezone,
            files,
            touched: HashSet::new(),
        }
    }

    /// Return cached contributions only if the file fingerprint and dedup
    /// dependencies still match this traversal. A new earlier claim, or a
    /// missing file that used to own a duplicate, forces a message-level rescan.
    pub fn take_if_fresh(
        &mut self,
        path: &Path,
        seen: &mut HashSet<u64>,
    ) -> Option<(Vec<Entry>, u64)> {
        let key = path.to_string_lossy().into_owned();
        let current = fingerprint(path)?;
        let cached = self.files.get(&key)?;
        if cached.size != current.size || cached.mtime_ns != current.mtime_ns {
            return None;
        }
        if cached.claims.iter().any(|h| seen.contains(h))
            || cached.dependencies.iter().any(|h| !seen.contains(h))
        {
            return None;
        }
        let entries: Option<Vec<Entry>> =
            cached.entries.iter().map(CachedEntry::to_entry).collect();
        let entries = entries?;
        seen.extend(cached.claims.iter().copied());
        self.touched.insert(key);
        Some((entries, cached.records))
    }

    pub fn store_if_unchanged(
        &mut self,
        path: &Path,
        before: Fingerprint,
        entries: &[Entry],
        claims: &[u64],
        dependencies: &[u64],
    ) -> bool {
        if fingerprint(path) != Some(before) {
            return false;
        }
        self.store(path, before, entries, claims, dependencies);
        true
    }

    fn store(
        &mut self,
        path: &Path,
        fingerprint: Fingerprint,
        entries: &[Entry],
        claims: &[u64],
        dependencies: &[u64],
    ) {
        let key = path.to_string_lossy().into_owned();
        self.touched.insert(key.clone());
        self.files.insert(
            key,
            CachedFile {
                size: fingerprint.size,
                mtime_ns: fingerprint.mtime_ns,
                records: entries.len() as u64,
                claims: claims.to_vec(),
                dependencies: dependencies.to_vec(),
                entries: condense(entries)
                    .into_iter()
                    .map(CachedEntry::from_entry)
                    .collect(),
            },
        );
    }

    pub fn save(mut self) -> std::io::Result<()> {
        self.files.retain(|k, _| self.touched.contains(k));
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let doc = CacheFile {
            version: CACHE_VERSION,
            timezone: self.timezone,
            files: self.files,
        };
        let bytes = serde_json::to_vec(&doc)?;
        let tmp = self
            .path
            .with_extension(format!("tmp-{}", std::process::id()));
        std::fs::write(&tmp, bytes)?;
        std::fs::rename(tmp, self.path)
    }
}

pub fn fingerprint(path: &Path) -> Option<Fingerprint> {
    let meta = path.metadata().ok()?;
    let modified = meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    Some(Fingerprint {
        size: meta.len(),
        mtime_ns: modified.as_nanos(),
    })
}

fn condense(entries: &[Entry]) -> Vec<Entry> {
    let mut grouped: BTreeMap<(NaiveDate, Source, String, String), Usage> = BTreeMap::new();
    for e in entries {
        grouped
            .entry((e.date, e.source, e.model.clone(), e.speed.clone()))
            .or_default()
            .add(&e.usage);
    }
    grouped
        .into_iter()
        .map(|((date, source, model, speed), usage)| Entry {
            date,
            source,
            model,
            speed,
            usage,
        })
        .collect()
}

impl CachedEntry {
    fn from_entry(e: Entry) -> Self {
        Self {
            date: e.date.to_string(),
            source: e.source.as_u8(),
            model: e.model,
            speed: e.speed,
            usage: e.usage.to_array(),
        }
    }

    fn to_entry(&self) -> Option<Entry> {
        Some(Entry {
            date: self.date.parse().ok()?,
            source: Source::from_u8(self.source)?,
            model: self.model.clone(),
            speed: self.speed.clone(),
            usage: Usage::from_array(self.usage),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(date: &str, model: &str, input: u64) -> Entry {
        Entry {
            date: date.parse().unwrap(),
            source: Source::Claude,
            model: model.into(),
            speed: "standard".into(),
            usage: Usage {
                input,
                ..Default::default()
            },
        }
    }

    fn temp(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("brrrn-cache-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn round_trip_condenses_and_claims_hashes() {
        let dir = temp("roundtrip");
        let source = dir.join("session.jsonl");
        std::fs::write(&source, "fixture").unwrap();
        let path = dir.join("cache.json");

        let mut cache = ScanCache::load(&path, true);
        cache.store(
            &source,
            fingerprint(&source).unwrap(),
            &[entry("2026-07-13", "m", 2), entry("2026-07-13", "m", 3)],
            &[10, 20],
            &[],
        );
        cache.save().unwrap();

        let mut loaded = ScanCache::load(&path, true);
        let mut seen = HashSet::new();
        let (entries, records) = loaded.take_if_fresh(&source, &mut seen).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(records, 2);
        assert_eq!(entries[0].usage.input, 5);
        assert_eq!(seen, HashSet::from([10, 20]));
    }

    #[test]
    fn changed_file_misses_cache() {
        let dir = temp("changed");
        let source = dir.join("session.jsonl");
        std::fs::write(&source, "one").unwrap();
        let path = dir.join("cache.json");
        let mut cache = ScanCache::load(&path, true);
        cache.store(
            &source,
            fingerprint(&source).unwrap(),
            &[entry("2026-07-13", "m", 1)],
            &[10],
            &[],
        );
        cache.save().unwrap();

        std::fs::write(&source, "now a different size").unwrap();
        let mut loaded = ScanCache::load(&path, true);
        assert!(loaded.take_if_fresh(&source, &mut HashSet::new()).is_none());
    }

    #[test]
    fn hash_collision_forces_rescan() {
        let dir = temp("collision");
        let source = dir.join("session.jsonl");
        std::fs::write(&source, "fixture").unwrap();
        let path = dir.join("cache.json");
        let mut cache = ScanCache::load(&path, true);
        cache.store(
            &source,
            fingerprint(&source).unwrap(),
            &[entry("2026-07-13", "m", 1)],
            &[42],
            &[],
        );
        cache.save().unwrap();

        let mut loaded = ScanCache::load(&path, true);
        let mut seen = HashSet::from([42]);
        assert!(loaded.take_if_fresh(&source, &mut seen).is_none());
    }

    #[test]
    fn append_after_scan_is_not_cached_as_complete() {
        let dir = temp("append-race");
        let source = dir.join("session.jsonl");
        std::fs::write(&source, "first").unwrap();
        let before = fingerprint(&source).unwrap();
        std::fs::write(&source, "first plus appended data").unwrap();

        let mut cache = ScanCache::load(&dir.join("cache.json"), true);
        assert!(!cache.store_if_unchanged(
            &source,
            before,
            &[entry("2026-07-13", "m", 1)],
            &[1],
            &[],
        ));
    }

    #[test]
    fn missing_prior_file_dependency_forces_rescan() {
        let dir = temp("dependency");
        let source = dir.join("duplicate.jsonl");
        std::fs::write(&source, "fixture").unwrap();
        let path = dir.join("cache.json");
        let mut cache = ScanCache::load(&path, true);
        // This file contributed nothing because hash 99 belonged to an earlier
        // file. If that earlier file disappears, this file must be rescanned.
        cache.store(&source, fingerprint(&source).unwrap(), &[], &[], &[99]);
        cache.save().unwrap();

        let mut loaded = ScanCache::load(&path, true);
        assert!(loaded.take_if_fresh(&source, &mut HashSet::new()).is_none());

        let mut loaded = ScanCache::load(&path, true);
        let mut seen = HashSet::from([99]);
        assert!(loaded.take_if_fresh(&source, &mut seen).is_some());
    }

    #[test]
    fn timezone_change_invalidates_cache() {
        let dir = temp("tz");
        let source = dir.join("session.jsonl");
        std::fs::write(&source, "fixture").unwrap();
        let path = dir.join("cache.json");
        let mut cache = ScanCache::load(&path, true);
        cache.store(
            &source,
            fingerprint(&source).unwrap(),
            &[entry("2026-07-13", "m", 1)],
            &[42],
            &[],
        );
        cache.save().unwrap();

        let mut local = ScanCache::load(&path, false);
        assert!(local.take_if_fresh(&source, &mut HashSet::new()).is_none());
    }
}
