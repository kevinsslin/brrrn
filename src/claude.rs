use std::collections::HashSet;
use std::io::BufRead;
use std::path::Path;

use crate::agg::{Entry, Source, Usage};
use crate::hash::stable_hash;
use crate::windows::parse_date_hour;

/// Scan one Claude Code session file (~/.claude/projects/**/*.jsonl). Each
/// assistant message line carries a `message.usage` block with token counts,
/// model, and speed. Resumed sessions copy history into new files, so entries
/// are deduped on (message.id, requestId) against the shared `seen` set.
/// Returns contributed entries, hashes claimed by this file, and hashes whose
/// contribution depended on an earlier file (needed for cache correctness).
pub fn scan_file(
    path: &Path,
    seen: &mut HashSet<u64>,
    utc: bool,
) -> (Vec<Entry>, Vec<u64>, Vec<u64>, bool) {
    let mut entries = Vec::new();
    let mut claimed = Vec::new();
    let mut dependencies = Vec::new();
    let mut local_claims = HashSet::new();
    let mut complete = true;
    let Ok(file) = std::fs::File::open(path) else {
        return (entries, claimed, dependencies, false);
    };
    let mut reader = std::io::BufReader::with_capacity(1 << 20, file);
    let mut line = String::new();

    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {}
            Err(_) => {
                complete = false;
                break;
            }
        }
        if !line.contains("\"usage\"") || !line.contains("\"model\"") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
        let msg = &v["message"];
        let Some(model) = msg["model"].as_str() else {
            continue;
        };
        if model == "<synthetic>" {
            continue;
        }
        let usage = &msg["usage"];
        if !usage.is_object() {
            continue;
        }

        let identity = match (msg["id"].as_str(), v["requestId"].as_str()) {
            (None, None) => format!("u:{}", v["uuid"].as_str().unwrap_or("")),
            (mid, rid) => format!("m:{}\0{}", mid.unwrap_or(""), rid.unwrap_or("")),
        };
        let hash = stable_hash(identity.as_bytes());
        if !seen.insert(hash) {
            if !local_claims.contains(&hash) {
                dependencies.push(hash);
            }
            continue;
        }

        let (cache_w5m, cache_w1h) = match usage["cache_creation"].as_object() {
            Some(cc) => (
                cc.get("ephemeral_5m_input_tokens")
                    .and_then(|x| x.as_u64())
                    .unwrap_or(0),
                cc.get("ephemeral_1h_input_tokens")
                    .and_then(|x| x.as_u64())
                    .unwrap_or(0),
            ),
            None => (
                usage["cache_creation_input_tokens"].as_u64().unwrap_or(0),
                0,
            ),
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
            seen.remove(&hash);
            continue;
        }
        let Some((date, hour)) = parse_date_hour(v["timestamp"].as_str(), utc) else {
            seen.remove(&hash);
            continue;
        };

        claimed.push(hash);
        local_claims.insert(hash);
        entries.push(Entry {
            date,
            hour,
            source: Source::Claude,
            model: model.to_string(),
            speed: usage["speed"].as_str().unwrap_or("standard").to_string(),
            usage: u,
        });
    }
    (entries, claimed, dependencies, complete)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str, content: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("brrrn-claude-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join(name);
        std::fs::write(&p, content).unwrap();
        p
    }

    fn msg_line(id: &str, req: &str, model: &str, extra_usage: &str) -> String {
        format!(
            r#"{{"timestamp":"2026-07-13T23:30:00.000Z","requestId":"{req}","message":{{"id":"{id}","model":"{model}","usage":{{"input_tokens":10,"cache_read_input_tokens":200,"output_tokens":20{extra_usage}}}}}}}"#
        )
    }

    #[test]
    fn unreadable_or_missing_file_is_incomplete() {
        let path = std::env::temp_dir().join("brrrn-definitely-missing-session.jsonl");
        let _ = std::fs::remove_file(&path);
        let (_, _, _, complete) = scan_file(&path, &mut HashSet::new(), true);
        assert!(!complete);
    }

    #[test]
    fn parses_dedups_and_buckets_utc() {
        let content = [
            msg_line("m1", "r1", "claude-opus-4-8", r#","cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":50}"#),
            msg_line("m1", "r1", "claude-opus-4-8", ""), // exact duplicate: dropped
            msg_line("m2", "r2", "<synthetic>", ""),     // synthetic: dropped
            r#"{"type":"user","message":{"role":"user"}}"#.to_string(), // no usage
            "not json at all".to_string(),
            msg_line("m3", "r3", "claude-fable-5", r#","cache_creation_input_tokens":30,"speed":"fast""#),
        ]
        .join("\n");
        let path = fixture("basic.jsonl", &content);

        let mut seen = HashSet::new();
        let (entries, claimed, dependencies, complete) = scan_file(&path, &mut seen, true);

        assert!(complete);
        assert_eq!(entries.len(), 2);
        assert_eq!(claimed.len(), 2);
        assert!(dependencies.is_empty()); // duplicate was within this same file

        let e1 = &entries[0];
        assert_eq!(e1.model, "claude-opus-4-8");
        assert_eq!(e1.speed, "standard");
        assert_eq!(e1.date, "2026-07-13".parse().unwrap()); // UTC, not local
        assert_eq!(
            e1.usage,
            Usage {
                input: 10,
                cache_read: 200,
                cache_w5m: 100,
                cache_w1h: 50,
                output: 20,
                reasoning: 0
            }
        );

        let e2 = &entries[1];
        assert_eq!(e2.speed, "fast");
        // flat cache_creation_input_tokens lands in the 5m bucket
        assert_eq!(e2.usage.cache_w5m, 30);
        assert_eq!(e2.usage.cache_w1h, 0);
    }

    #[test]
    fn dedup_spans_files_via_shared_seen_set() {
        let line = msg_line("m9", "r9", "claude-opus-4-8", "");
        let a = fixture("dup_a.jsonl", &line);
        let b = fixture("dup_b.jsonl", &line);

        let mut seen = HashSet::new();
        let (ea, _, _, _) = scan_file(&a, &mut seen, true);
        let (eb, hb, dependencies, _) = scan_file(&b, &mut seen, true);
        assert_eq!(ea.len(), 1);
        assert_eq!(eb.len(), 0); // resumed-session copy is not double counted
        assert!(hb.is_empty());
        assert_eq!(dependencies.len(), 1);
    }
}
