use std::collections::{HashMap, HashSet};
use std::io::BufRead;
use std::path::Path;

use crate::agg::{Entry, Source, Usage};
use crate::hash::stable_hash;
use crate::windows::parse_date_hour;

fn parse_usage(usage: &serde_json::Value) -> Usage {
    // The nested object is the authoritative TTL split. The flat field is
    // used as 5m only for older records that predate the nested breakdown.
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
    Usage {
        input: usage["input_tokens"].as_u64().unwrap_or(0),
        cache_read: usage["cache_read_input_tokens"].as_u64().unwrap_or(0),
        cache_w5m,
        cache_w1h,
        output: usage["output_tokens"].as_u64().unwrap_or(0),
        reasoning: 0,
    }
}

/// Scan one Claude Code session file (~/.claude/projects/**/*.jsonl). Each
/// assistant message line carries a `message.usage` block with token counts,
/// model, and speed. A non-empty `usage.iterations` is authoritative and can
/// produce multiple priced entries. Resumed sessions copy history into new
/// files, so entries are deduped on (message.id, requestId) against `seen`.
/// Returns contributed entries, hashes claimed by this file, and hashes whose
/// contribution depended on an earlier file (needed for cache correctness).
pub fn scan_file(
    path: &Path,
    seen: &mut HashSet<u64>,
    utc: bool,
) -> (Vec<Entry>, Vec<u64>, Vec<u64>, bool) {
    struct EntryGroup {
        entries: Vec<Entry>,
        authoritative: bool,
        tokens: u64,
    }

    let mut entries = Vec::new();
    let mut claimed = Vec::new();
    let mut dependencies = Vec::new();
    let mut local_dependencies = HashSet::new();
    let mut entry_groups: HashMap<u64, EntryGroup> = HashMap::new();
    let mut claim_order = Vec::new();
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
        let response_refused = msg["stop_reason"].as_str() == Some("refusal");

        let identity = match (msg["id"].as_str(), v["requestId"].as_str()) {
            (None, None) => format!("u:{}", v["uuid"].as_str().unwrap_or("")),
            (mid, rid) => format!("m:{}\0{}", mid.unwrap_or(""), rid.unwrap_or("")),
        };
        let hash = stable_hash(identity.as_bytes());
        let claimed_locally = entry_groups.contains_key(&hash);
        if !claimed_locally && seen.contains(&hash) {
            if local_dependencies.insert(hash) {
                dependencies.push(hash);
            }
            continue;
        }

        let iterations = usage["iterations"].as_array().filter(|v| !v.is_empty());
        let billed: Vec<_> = match iterations {
            Some(iterations) => {
                let fallback_index = iterations
                    .iter()
                    .rposition(|item| item["type"].as_str() == Some("fallback_message"));
                iterations
                    .iter()
                    .enumerate()
                    .filter_map(|(index, iteration)| {
                        let u = parse_usage(iteration);
                        let is_model_attempt = matches!(
                            iteration["type"].as_str(),
                            Some("message" | "fallback_message")
                        );
                        let followed_by_fallback = fallback_index.is_some_and(|at| index < at);
                        // A refusal before output reports usage but is free.
                        // Mid-stream refusals have output and bill normally.
                        let free_refusal = is_model_attempt
                            && u.output == 0
                            && (response_refused || followed_by_fallback);
                        (!u.is_zero() && !free_refusal)
                            .then(|| (iteration["model"].as_str().unwrap_or(model).to_string(), u))
                    })
                    .collect()
            }
            None => {
                let u = parse_usage(usage);
                if u.is_zero() || (response_refused && u.output == 0) {
                    Vec::new()
                } else {
                    vec![(model.to_string(), u)]
                }
            }
        };
        if billed.is_empty() {
            continue;
        }
        let Some((date, hour)) = parse_date_hour(v["timestamp"].as_str(), utc) else {
            continue;
        };

        // Claude Code transcripts record `usage.speed` today; reasoning
        // effort is not written to session logs (unlike Codex). If a future
        // version starts logging it, pick it up without a release.
        let effort = usage["effort"]
            .as_str()
            .or_else(|| usage["reasoning_effort"].as_str())
            .or_else(|| msg["effort_level"].as_str());
        let speed = usage["speed"].as_str().unwrap_or("standard");
        let variant = match effort {
            Some(effort) if speed == "standard" => effort.to_string(),
            Some(effort) => format!("{speed} {effort}"),
            None => speed.to_string(),
        };
        let finalized: Vec<_> = billed
            .into_iter()
            .map(|(model, usage)| Entry {
                date,
                hour,
                source: Source::Claude,
                model,
                speed: variant.clone(),
                usage,
            })
            .collect();
        let candidate = EntryGroup {
            tokens: finalized.iter().map(|entry| entry.usage.total()).sum(),
            authoritative: iterations.is_some(),
            entries: finalized,
        };
        let should_replace = entry_groups.get(&hash).is_none_or(|current| {
            (candidate.authoritative && !current.authoritative)
                || (candidate.authoritative == current.authoritative
                    && candidate.tokens >= current.tokens)
        });
        if should_replace {
            entry_groups.insert(hash, candidate);
        }
        if !claimed_locally {
            seen.insert(hash);
            claimed.push(hash);
            claim_order.push(hash);
        }
    }
    for hash in claim_order {
        if let Some(group) = entry_groups.remove(&hash) {
            entries.extend(group.entries);
        }
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
    fn nested_cache_tiers_and_inclusive_output_are_authoritative() {
        let content = msg_line(
            "tiers",
            "r-tiers",
            "claude-opus-4-8",
            r#","cache_creation_input_tokens":999,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":50},"output_tokens_details":{"thinking_tokens":12}"#,
        );
        let path = fixture("tiers.jsonl", &content);

        let (entries, _, _, _) = scan_file(&path, &mut HashSet::new(), true);

        assert_eq!(entries[0].usage.cache_w5m, 100);
        assert_eq!(entries[0].usage.cache_w1h, 50);
        // Anthropic defines output_tokens as the inclusive billed total.
        assert_eq!(entries[0].usage.output, 20);
        assert_eq!(entries[0].usage.reasoning, 0);
    }

    #[test]
    fn empty_iterations_fall_back_to_top_level_usage() {
        let content = msg_line("empty", "r-empty", "claude-opus-4-8", r#","iterations":[]"#);
        let path = fixture("empty-iterations.jsonl", &content);

        let (entries, _, _, _) = scan_file(&path, &mut HashSet::new(), true);

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].usage.input, 10);
        assert_eq!(entries[0].usage.cache_read, 200);
        assert_eq!(entries[0].usage.output, 20);
    }

    #[test]
    fn future_effort_fields_flow_into_the_variant() {
        let content = [
            msg_line("e1", "r1", "claude-fable-5", r#","effort":"high""#),
            msg_line(
                "e2",
                "r2",
                "claude-fable-5",
                r#","speed":"fast","reasoning_effort":"max""#,
            ),
        ]
        .join("\n");
        let path = fixture("effort.jsonl", &content);

        let (entries, _, _, _) = scan_file(&path, &mut HashSet::new(), true);
        assert_eq!(entries[0].speed, "high");
        assert_eq!(entries[1].speed, "fast max");
    }

    #[test]
    fn fallback_chain_counts_each_billed_iteration() {
        // Anthropic reports the served fallback at the top level while the
        // iterations array also includes the billed declined attempt.
        let content = r#"{"timestamp":"2026-07-13T23:30:00.000Z","requestId":"r-fallback","message":{"id":"m-fallback","model":"claude-opus-4-8","usage":{"input_tokens":3,"cache_read_input_tokens":40,"cache_creation_input_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":50},"output_tokens":6,"iterations":[{"type":"message","model":"claude-fable-5","input_tokens":1,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":30,"ephemeral_1h_input_tokens":0},"output_tokens":2},{"type":"fallback_message","model":"claude-opus-4-8","input_tokens":3,"cache_read_input_tokens":40,"cache_creation_input_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":50},"output_tokens":6}]}}}"#;
        let path = fixture("fallback.jsonl", content);

        let (entries, claimed, _, _) = scan_file(&path, &mut HashSet::new(), true);

        assert_eq!(claimed.len(), 1); // one transcript message, two billed attempts
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].model, "claude-fable-5");
        assert_eq!(
            entries[0].usage,
            Usage {
                input: 1,
                cache_read: 20,
                cache_w5m: 30,
                cache_w1h: 0,
                output: 2,
                reasoning: 0,
            }
        );
        assert_eq!(entries[1].model, "claude-opus-4-8");
        assert_eq!(
            entries[1].usage,
            Usage {
                input: 3,
                cache_read: 40,
                cache_w5m: 0,
                cache_w1h: 50,
                output: 6,
                reasoning: 0,
            }
        );
    }

    #[test]
    fn fallback_chain_ignores_free_pre_output_refusal() {
        // Anthropic reports token usage for a refusal before output, but does
        // not bill it. The zero output distinguishes it from a billed
        // mid-stream refusal.
        let content = r#"{"timestamp":"2026-07-13T23:30:00.000Z","requestId":"r-free-refusal","message":{"id":"m-free-refusal","model":"claude-opus-4-8","stop_reason":"end_turn","usage":{"input_tokens":3,"cache_read_input_tokens":40,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"output_tokens":6,"iterations":[{"type":"message","model":"claude-fable-5","input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":300,"ephemeral_1h_input_tokens":0},"output_tokens":0},{"type":"fallback_message","model":"claude-opus-4-8","input_tokens":3,"cache_read_input_tokens":40,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"output_tokens":6}]}}}"#;
        let path = fixture("free-refusal.jsonl", content);

        let (entries, claimed, _, _) = scan_file(&path, &mut HashSet::new(), true);

        assert_eq!(claimed.len(), 1);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].model, "claude-opus-4-8");
        assert_eq!(entries[0].usage.input, 3);
        assert_eq!(entries[0].usage.output, 6);
    }

    #[test]
    fn standalone_pre_output_refusal_has_no_billed_usage() {
        let content = r#"{"timestamp":"2026-07-13T23:30:00.000Z","requestId":"r-refusal","message":{"id":"m-refusal","model":"claude-fable-5","stop_reason":"refusal","usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":300,"ephemeral_1h_input_tokens":0},"output_tokens":0}}}"#;
        let path = fixture("standalone-refusal.jsonl", content);

        let (entries, claimed, _, _) = scan_file(&path, &mut HashSet::new(), true);

        assert!(entries.is_empty());
        assert!(claimed.is_empty());
    }

    #[test]
    fn compaction_iteration_is_included_in_billed_usage() {
        // Top-level usage excludes compaction. The iteration has no model of
        // its own, so it inherits the response model for pricing.
        let content = r#"{"timestamp":"2026-07-13T23:30:00.000Z","requestId":"r-compact","message":{"id":"m-compact","model":"claude-opus-4-8","usage":{"input_tokens":3,"cache_read_input_tokens":40,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"output_tokens":6,"iterations":[{"type":"compaction","input_tokens":7,"cache_read_input_tokens":80,"cache_creation_input_tokens":90,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":90},"output_tokens":8},{"type":"message","input_tokens":3,"cache_read_input_tokens":40,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"output_tokens":6}]}}}"#;
        let path = fixture("compaction.jsonl", content);

        let (entries, claimed, _, _) = scan_file(&path, &mut HashSet::new(), true);

        assert_eq!(claimed.len(), 1);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].model, "claude-opus-4-8");
        assert_eq!(entries[0].usage.input, 7);
        assert_eq!(entries[0].usage.cache_read, 80);
        assert_eq!(entries[0].usage.cache_w1h, 90);
        assert_eq!(entries[0].usage.output, 8);
        assert_eq!(entries[1].usage.input, 3);
        assert_eq!(entries[1].usage.output, 6);
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

    #[test]
    fn finalized_duplicate_replaces_partial_usage_in_the_same_file() {
        let partial = r#"{"timestamp":"2026-07-13T23:30:00.000Z","requestId":"r-stream","message":{"id":"m-stream","model":"claude-opus-4-8","usage":{"input_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":25708,"output_tokens":7,"iterations":[]}}}"#;
        let finalized = r#"{"timestamp":"2026-07-13T23:30:01.000Z","requestId":"r-stream","message":{"id":"m-stream","model":"claude-opus-4-8","usage":{"input_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":25708,"output_tokens":134,"iterations":[{"type":"message","input_tokens":2,"cache_read_input_tokens":0,"cache_creation_input_tokens":25708,"output_tokens":134}]}}}"#;
        let path = fixture("streamed-final.jsonl", &format!("{partial}\n{finalized}"));

        let (entries, claimed, dependencies, _) = scan_file(&path, &mut HashSet::new(), true);

        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].usage.cache_w5m, 25_708);
        assert_eq!(entries[0].usage.output, 134);
        assert_eq!(claimed.len(), 1);
        assert!(dependencies.is_empty());
    }

    #[test]
    fn dedup_drops_every_iteration_copied_by_a_resumed_session() {
        let line = r#"{"timestamp":"2026-07-13T23:30:00.000Z","requestId":"r-resume","message":{"id":"m-resume","model":"claude-opus-4-8","usage":{"input_tokens":3,"cache_read_input_tokens":40,"cache_creation_input_tokens":0,"output_tokens":6,"iterations":[{"type":"compaction","input_tokens":7,"cache_read_input_tokens":80,"cache_creation_input_tokens":0,"output_tokens":8},{"type":"message","input_tokens":3,"cache_read_input_tokens":40,"cache_creation_input_tokens":0,"output_tokens":6}]}}}"#;
        let a = fixture("resume_iterations_a.jsonl", line);
        let b = fixture("resume_iterations_b.jsonl", line);

        let mut seen = HashSet::new();
        let (ea, _, _, _) = scan_file(&a, &mut seen, true);
        let (eb, _, dependencies, _) = scan_file(&b, &mut seen, true);

        assert_eq!(ea.len(), 2);
        assert!(eb.is_empty());
        assert_eq!(dependencies.len(), 1);
    }
}
