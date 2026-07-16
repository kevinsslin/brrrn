use std::collections::HashSet;
use std::io::BufRead;
use std::path::Path;

use crate::agg::{Entry, Source, Usage};
use crate::hash::stable_hash;
use crate::windows::parse_date_hour;

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

/// Scan one Codex rollout file (~/.codex/sessions/**/*.jsonl). `token_count`
/// events carry cumulative session totals; we take deltas between consecutive
/// events and attribute them to the model/effort from the most recent
/// `turn_context`. Rollouts forked from another session replay old events
/// verbatim, so events are deduped globally on (timestamp, totals) via the
/// shared `seen` set; deduped events still advance the delta baseline.
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

    let mut cur_model: Option<String> = None;
    let mut cur_effort: String = "default".to_string();
    let mut cur_tier: String = "default".to_string();
    let mut prev: Option<Totals> = None;

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

        // Service tier rides along in settings records (thread_settings).
        // It selects LiteLLM priority or flex rates and is part of the
        // variant identity like reasoning effort.
        if line.contains("\"service_tier\"") {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) {
                let p = &v["payload"];
                if let Some(t) = p["thread_settings"]["service_tier"]
                    .as_str()
                    .or_else(|| p["settings"]["service_tier"].as_str())
                    .or_else(|| p["service_tier"].as_str())
                {
                    cur_tier = t.to_string();
                }
            }
        }

        if line.contains("\"turn_context\"") {
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
                continue;
            };
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
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else {
            continue;
        };
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
        let identity = format!(
            "{ts}\0{}\0{}\0{}\0{}",
            total.input, total.output, total.cached, total.reasoning
        );
        let hash = stable_hash(identity.as_bytes());
        if !seen.insert(hash) {
            if !local_claims.contains(&hash) {
                dependencies.push(hash);
            }
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
            seen.remove(&hash);
            continue;
        }
        let Some((date, hour)) = parse_date_hour(v["timestamp"].as_str(), utc) else {
            seen.remove(&hash);
            continue;
        };

        claimed.push(hash);
        local_claims.insert(hash);
        let speed = if cur_tier == "default" || cur_tier.is_empty() {
            cur_effort.clone()
        } else {
            format!("{cur_effort} {cur_tier}")
        };
        entries.push(Entry {
            date,
            hour,
            source: Source::Codex,
            model: cur_model.clone().unwrap_or_else(|| "unknown".to_string()),
            speed,
            usage: u,
        });
    }
    (entries, claimed, dependencies, complete)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str, content: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("brrrn-codex-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join(name);
        std::fs::write(&p, content).unwrap();
        p
    }

    fn turn_ctx(model: &str, effort: &str) -> String {
        format!(
            r#"{{"timestamp":"2026-07-13T10:00:00.000Z","type":"turn_context","payload":{{"model":"{model}","effort":"{effort}"}}}}"#
        )
    }

    fn u(input: u64, cached: u64, output: u64, reasoning: u64) -> Totals {
        Totals {
            input,
            cached,
            output,
            reasoning,
        }
    }

    fn token_count(ts: &str, total: Totals, last: Totals) -> String {
        let Totals {
            input: ti,
            cached: tc,
            output: to,
            reasoning: tr,
        } = total;
        let Totals {
            input: li,
            cached: lc,
            output: lo,
            reasoning: lr,
        } = last;
        format!(
            r#"{{"timestamp":"{ts}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":{ti},"cached_input_tokens":{tc},"output_tokens":{to},"reasoning_output_tokens":{tr},"total_tokens":{t}}},"last_token_usage":{{"input_tokens":{li},"cached_input_tokens":{lc},"output_tokens":{lo},"reasoning_output_tokens":{lr},"total_tokens":{l}}}}}}}}}"#,
            t = ti + to,
            l = li + lo,
        )
    }

    #[test]
    fn priority_service_tier_joins_the_variant() {
        let settings = r#"{"timestamp":"2026-07-13T10:00:00.000Z","type":"event_msg","payload":{"type":"thread_settings_updated","thread_settings":{"model":"gpt-5.6-sol","service_tier":"priority"}}}"#;
        let back_to_default = r#"{"timestamp":"2026-07-13T10:00:02.500Z","type":"event_msg","payload":{"type":"thread_settings_updated","thread_settings":{"model":"gpt-5.6-sol","service_tier":"default"}}}"#;
        let content = [
            settings.to_string(),
            turn_ctx("gpt-5.6-sol", "xhigh"),
            token_count(
                "2026-07-13T10:00:01Z",
                u(1000, 400, 100, 50),
                u(1000, 400, 100, 50),
            ),
            back_to_default.to_string(),
            token_count(
                "2026-07-13T10:00:03Z",
                u(1500, 700, 160, 80),
                u(500, 300, 60, 30),
            ),
        ]
        .join("\n");
        let path = fixture("tier.jsonl", &content);

        let (entries, _, _, _) = scan_file(&path, &mut HashSet::new(), true);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].speed, "xhigh priority");
        assert_eq!(entries[1].speed, "xhigh");
    }

    #[test]
    fn deltas_model_switch_and_reset_fallback() {
        let content = [
            turn_ctx("gpt-5.5", "xhigh"),
            token_count(
                "2026-07-13T10:00:01Z",
                u(1000, 400, 100, 50),
                u(1000, 400, 100, 50),
            ),
            token_count(
                "2026-07-13T10:00:02Z",
                u(1500, 700, 160, 80),
                u(500, 300, 60, 30),
            ),
            turn_ctx("gpt-5.4", "high"),
            // totals went backwards: context reset, use last_token_usage
            token_count(
                "2026-07-13T10:00:03Z",
                u(1400, 700, 200, 90),
                u(300, 100, 40, 10),
            ),
            // old schema: info null, ignored
            r#"{"timestamp":"2026-07-13T10:00:04Z","type":"event_msg","payload":{"type":"token_count","info":null}}"#.to_string(),
        ]
        .join("\n");
        let path = fixture("session.jsonl", &content);

        let mut seen = HashSet::new();
        let (entries, _, _, _) = scan_file(&path, &mut seen, true);
        assert_eq!(entries.len(), 3);

        // first event: whole totals; input excludes cached reads
        assert_eq!(entries[0].model, "gpt-5.5");
        assert_eq!(entries[0].speed, "xhigh");
        assert_eq!(
            entries[0].usage,
            Usage {
                input: 600,
                cache_read: 400,
                cache_w5m: 0,
                cache_w1h: 0,
                output: 100,
                reasoning: 50
            }
        );

        // second event: delta vs first
        assert_eq!(
            entries[1].usage,
            Usage {
                input: 200,
                cache_read: 300,
                cache_w5m: 0,
                cache_w1h: 0,
                output: 60,
                reasoning: 30
            }
        );

        // third event: reset detected, attributed to new model from turn_context
        assert_eq!(entries[2].model, "gpt-5.4");
        assert_eq!(entries[2].speed, "high");
        assert_eq!(
            entries[2].usage,
            Usage {
                input: 200,
                cache_read: 100,
                cache_w5m: 0,
                cache_w1h: 0,
                output: 40,
                reasoning: 10
            }
        );
    }

    #[test]
    fn forked_rollout_replay_is_deduped_but_advances_baseline() {
        let original = [
            turn_ctx("gpt-5.5", "xhigh"),
            token_count(
                "2026-07-13T10:00:01Z",
                u(1000, 400, 100, 50),
                u(1000, 400, 100, 50),
            ),
        ]
        .join("\n");
        // fork replays the same event, then continues
        let fork = [
            turn_ctx("gpt-5.5", "xhigh"),
            token_count(
                "2026-07-13T10:00:01Z",
                u(1000, 400, 100, 50),
                u(1000, 400, 100, 50),
            ),
            token_count(
                "2026-07-13T10:05:00Z",
                u(1800, 900, 150, 70),
                u(800, 500, 50, 20),
            ),
        ]
        .join("\n");
        let a = fixture("orig.jsonl", &original);
        let b = fixture("fork.jsonl", &fork);

        let mut seen = HashSet::new();
        let (ea, _, _, _) = scan_file(&a, &mut seen, true);
        let (eb, _, dependencies, _) = scan_file(&b, &mut seen, true);
        assert_eq!(dependencies.len(), 1);

        assert_eq!(ea.len(), 1);
        // replayed event dropped, but the new event is a DELTA from the
        // replayed baseline, not the full cumulative total
        assert_eq!(eb.len(), 1);
        assert_eq!(
            eb[0].usage,
            Usage {
                input: 300,
                cache_read: 500,
                cache_w5m: 0,
                cache_w1h: 0,
                output: 50,
                reasoning: 20
            }
        );

        let total: u64 = ea.iter().chain(eb.iter()).map(|e| e.usage.total()).sum();
        assert_eq!(total, 1100 + 850); // no double counting of the replay
    }

    #[test]
    fn distinct_reasoning_totals_are_not_deduped() {
        let first = token_count(
            "2026-07-13T10:00:01Z",
            u(1000, 400, 100, 40),
            u(1000, 400, 100, 40),
        );
        let second = token_count(
            "2026-07-13T10:00:01Z",
            u(1000, 400, 100, 60),
            u(1000, 400, 100, 60),
        );
        let a = fixture("reasoning-a.jsonl", &first);
        let b = fixture("reasoning-b.jsonl", &second);

        let mut seen = HashSet::new();
        let (ea, _, _, _) = scan_file(&a, &mut seen, true);
        let (eb, _, _, _) = scan_file(&b, &mut seen, true);

        assert_eq!(ea.len(), 1);
        assert_eq!(eb.len(), 1);
    }

    #[test]
    fn unknown_model_when_no_turn_context() {
        let content = token_count("2026-07-13T10:00:01Z", u(100, 0, 10, 0), u(100, 0, 10, 0));
        let path = fixture("nomodel.jsonl", &content);
        let mut seen = HashSet::new();
        let (entries, _, _, _) = scan_file(&path, &mut seen, true);
        assert_eq!(entries[0].model, "unknown");
    }
}
