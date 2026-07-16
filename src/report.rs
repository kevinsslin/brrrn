use std::collections::BTreeMap;

use chrono::NaiveDate;

use crate::agg::{Agg, Key, Source, Usage};
use crate::windows::{month_start, streak_days, week_start, STREAK_THRESHOLD_USD};

pub fn fmt_tokens(n: u64) -> String {
    match n {
        0..=999 => n.to_string(),
        1_000..=999_999 => format!("{:.1}K", n as f64 / 1e3),
        1_000_000..=999_999_999 => format!("{:.1}M", n as f64 / 1e6),
        _ => format!("{:.2}B", n as f64 / 1e9),
    }
}

pub fn fmt_money(v: f64) -> String {
    let total_cents = (v * 100.0).round() as i64;
    let whole = total_cents / 100;
    let cents = total_cents % 100;
    let mut s = whole.to_string();
    let mut out = String::new();
    while s.len() > 3 {
        let tail = s.split_off(s.len() - 3);
        out = format!(",{tail}{out}");
    }
    format!("${s}{out}.{cents:02}")
}

/// (tokens, cost, unpriced_tokens) per source for days in [from, to].
fn window(agg: &Agg, from: NaiveDate, to: NaiveDate) -> BTreeMap<Source, (u64, f64, u64)> {
    let mut out: BTreeMap<Source, (u64, f64, u64)> = BTreeMap::new();
    for (_, per_source) in agg.daily.range(from..=to) {
        for (src, d) in per_source {
            let e = out.entry(*src).or_default();
            e.0 += d.tokens;
            e.1 += d.cost;
            e.2 += d.unpriced_tokens;
        }
    }
    out
}

fn source_cost(agg: &Agg, src: Source, from: NaiveDate, to: NaiveDate) -> f64 {
    window(agg, from, to).get(&src).map(|v| v.1).unwrap_or(0.0)
}

fn print_window_row(agg: &Agg, label: &str, from: NaiveDate, to: NaiveDate) {
    let w = window(agg, from, to);
    let tokens: u64 = w.values().map(|v| v.0).sum();
    let cost: f64 = w.values().map(|v| v.1).sum();
    let claude = w.get(&Source::Claude).map(|v| v.1).unwrap_or(0.0);
    let codex = w.get(&Source::Codex).map(|v| v.1).unwrap_or(0.0);
    println!(
        "{label:<12} {:>8}  {:>12}   (claude {} / codex {})",
        fmt_tokens(tokens),
        fmt_money(cost),
        fmt_money(claude),
        fmt_money(codex),
    );
}

pub fn print_report(
    agg: &Agg,
    period: &str,
    today: NaiveDate,
    min_date: Option<NaiveDate>,
    utc: bool,
) {
    let first = agg.daily.keys().next().copied().unwrap_or(today);
    let tz = if utc { "UTC" } else { "local time" };
    println!("brrrn: token burn across Claude Code + Codex (days in {tz})\n");

    println!("{:<12} {:>8}  {:>12}", "period", "tokens", "cost");
    if period == "all" {
        print_window_row(agg, "today", today, today);
        print_window_row(agg, "this week", week_start(today), today);
        print_window_row(agg, "this month", month_start(today), today);
        print_window_row(agg, "all time", first, today);
    } else {
        print_window_row(agg, period, min_date.unwrap_or(first), today);
    }

    let streak = streak_days(agg.daily_cost(), today, STREAK_THRESHOLD_USD);
    println!(
        "\nstreak: {streak} day{} (days >= {})",
        if streak == 1 { "" } else { "s" },
        fmt_money(STREAK_THRESHOLD_USD)
    );

    // By-model table, sorted by cost desc, unpriced rows last.
    let mut rows: Vec<_> = agg.by_key.iter().collect();
    rows.sort_by(|a, b| {
        let ca = a.1 .1.unwrap_or(-1.0);
        let cb = b.1 .1.unwrap_or(-1.0);
        cb.partial_cmp(&ca).unwrap()
    });

    println!(
        "\n{:<12} {:<28} {:<9} {:>8} {:>9} {:>9} {:>8} {:>12}",
        "source", "model", "speed/eff", "input", "cache_r", "cache_w", "output", "cost"
    );
    let mut unpriced: Vec<String> = Vec::new();
    for (key, (u, cost)) in rows {
        let cost_s = match cost {
            Some(c) => fmt_money(*c),
            None => {
                unpriced.push(key.model.clone());
                "n/a".to_string()
            }
        };
        println!(
            "{:<12} {:<28} {:<9} {:>8} {:>9} {:>9} {:>8} {:>12}",
            key.source.label(),
            key.model,
            key.speed,
            fmt_tokens(u.input),
            fmt_tokens(u.cache_read),
            fmt_tokens(u.cache_w5m + u.cache_w1h),
            fmt_tokens(u.output),
            cost_s,
        );
    }
    if !unpriced.is_empty() {
        unpriced.sort();
        unpriced.dedup();
        println!(
            "\nnote: no pricing found for: {} (tokens counted, cost excluded)",
            unpriced.join(", ")
        );
    }
}

pub fn print_daily(agg: &Agg, today: NaiveDate) {
    println!("\n{:<12} {:>10} {:>12}", "day", "tokens", "cost");
    let from = today - chrono::Duration::days(13);
    for (day, per_source) in agg.daily.range(from..=today) {
        let tokens: u64 = per_source.values().map(|d| d.tokens).sum();
        let cost: f64 = per_source.values().map(|d| d.cost).sum();
        println!(
            "{:<12} {:>10} {:>12}",
            day.to_string(),
            fmt_tokens(tokens),
            fmt_money(cost)
        );
    }
}

fn window_json(agg: &Agg, from: NaiveDate, to: NaiveDate) -> serde_json::Value {
    let w = window(agg, from, to);
    serde_json::json!({
        "tokens": w.values().map(|v| v.0).sum::<u64>(),
        "cost_usd": w.values().map(|v| v.1).sum::<f64>(),
        "unpriced_tokens": w.values().map(|v| v.2).sum::<u64>(),
    })
}

fn source_json(agg: &Agg, src: Source, today: NaiveDate) -> serde_json::Value {
    serde_json::json!({
        "today_usd": source_cost(agg, src, today, today),
        "week_usd": source_cost(agg, src, week_start(today), today),
        "month_usd": source_cost(agg, src, month_start(today), today),
    })
}

/// Machine-readable output. This schema is frozen: the menu bar app decodes it.
pub fn json_value(agg: &Agg, period: &str, today: NaiveDate, utc: bool) -> serde_json::Value {
    let first = agg.daily.keys().next().copied().unwrap_or(today);
    let by_model = model_rows_json(&agg.by_key);
    let daily: Vec<_> = agg
        .daily
        .iter()
        .map(|(day, per_source)| {
            let mut entry = serde_json::json!({
                "date": day.to_string(),
                "tokens": per_source.values().map(|d| d.tokens).sum::<u64>(),
                "cost_usd": per_source.values().map(|d| d.cost).sum::<f64>(),
            });
            if let Some(hours) = agg.hourly.get(day) {
                entry["hours"] = hours.iter().map(|h| h.cost).collect();
                entry["hour_tokens"] = hours.iter().map(|h| h.tokens).collect();
            }
            entry
        })
        .collect();
    let mut value = serde_json::json!({
        "period": period,
        "tz": if utc { "utc" } else { "local" },
        "generated_on": today.to_string(),
        "windows": {
            "today": window_json(agg, today, today),
            "week": window_json(agg, week_start(today), today),
            "month": window_json(agg, month_start(today), today),
            "all": window_json(agg, first, today),
        },
        "by_source": {
            "claude": source_json(agg, Source::Claude, today),
            "codex": source_json(agg, Source::Codex, today),
        },
        "streak": {
            "days": streak_days(agg.daily_cost(), today, STREAK_THRESHOLD_USD),
            "threshold_usd": STREAK_THRESHOLD_USD,
        },
        "by_model": by_model,
        "daily": daily,
    });
    if period == "all" {
        value["models_by_period"] = serde_json::json!({
            "today": model_window_json(agg, today, today),
            "week": model_window_json(agg, week_start(today), today),
            "month": model_window_json(agg, month_start(today), today),
        });
    }
    value
}

fn model_window_json(agg: &Agg, from: NaiveDate, to: NaiveDate) -> Vec<serde_json::Value> {
    let mut totals: std::collections::HashMap<Key, (Usage, Option<f64>)> =
        std::collections::HashMap::new();
    for day in agg.daily_by_key.range(from..=to).map(|(_, day)| day) {
        for (key, (usage, cost)) in day {
            let slot = totals
                .entry(key.clone())
                .or_insert_with(|| (Usage::default(), cost.map(|_| 0.0)));
            slot.0.add(usage);
            if let (Some(cost), Some(total)) = (cost, slot.1.as_mut()) {
                *total += cost;
            }
        }
    }
    model_rows_json(&totals)
}

fn model_rows_json(
    totals: &std::collections::HashMap<Key, (Usage, Option<f64>)>,
) -> Vec<serde_json::Value> {
    let mut rows: Vec<_> = totals
        .iter()
        .map(|(key, (usage, cost))| {
            serde_json::json!({
                "source": key.source.label(),
                "model": key.model,
                "speed": key.speed,
                "input_tokens": usage.input,
                "cache_read_tokens": usage.cache_read,
                "cache_write_tokens": usage.cache_w5m + usage.cache_w1h,
                "output_tokens": usage.output,
                "reasoning_tokens": usage.reasoning,
                "total_tokens": usage.total(),
                "cost_usd": cost,
            })
        })
        .collect();
    rows.sort_by(|a, b| {
        let ac = a["cost_usd"].as_f64().unwrap_or(-1.0);
        let bc = b["cost_usd"].as_f64().unwrap_or(-1.0);
        bc.partial_cmp(&ac)
            .unwrap()
            .then_with(|| a["source"].as_str().cmp(&b["source"].as_str()))
            .then_with(|| a["model"].as_str().cmp(&b["model"].as_str()))
            .then_with(|| a["speed"].as_str().cmp(&b["speed"].as_str()))
    });
    rows
}

pub fn print_json(agg: &Agg, period: &str, today: NaiveDate, utc: bool) {
    println!(
        "{}",
        serde_json::to_string_pretty(&json_value(agg, period, today, utc)).unwrap()
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn money_rounds_and_groups() {
        assert_eq!(fmt_money(401.999), "$402.00"); // cents carry, not "$401.100"
        assert_eq!(fmt_money(0.005), "$0.01");
        assert_eq!(fmt_money(1234.5), "$1,234.50");
        assert_eq!(fmt_money(1_000_000.0), "$1,000,000.00");
        assert_eq!(fmt_money(0.0), "$0.00");
    }

    #[test]
    fn tokens_humanize() {
        assert_eq!(fmt_tokens(999), "999");
        assert_eq!(fmt_tokens(1_000), "1.0K");
        assert_eq!(fmt_tokens(1_500_000), "1.5M");
        assert_eq!(fmt_tokens(2_100_000_000), "2.10B");
    }

    #[test]
    fn json_models_are_deterministically_sorted_by_cost() {
        use crate::agg::{Entry, Usage};
        use crate::pricing::Price;

        let mut agg = Agg::default();
        let date: NaiveDate = "2026-07-13".parse().unwrap();
        for (model, input) in [("cheap", 1), ("expensive", 10)] {
            agg.add_entry(
                &Entry {
                    date,
                    hour: 0,
                    source: Source::Claude,
                    model: model.into(),
                    speed: "standard".into(),
                    usage: Usage {
                        input,
                        ..Default::default()
                    },
                },
                Some(Price {
                    input: 1.0,
                    output: 1.0,
                    cache_read: 1.0,
                    cache_w5m: 1.0,
                    cache_w1h: 1.0,
                }),
            );
        }
        let v = json_value(&agg, "all", date, true);
        assert_eq!(v["by_model"][0]["model"], "expensive");
        assert_eq!(v["by_model"][1]["model"], "cheap");
    }

    #[test]
    fn all_period_json_includes_model_rows_for_each_app_window() {
        use crate::agg::{Entry, Usage};
        use crate::pricing::Price;

        let mut agg = Agg::default();
        let price = Price {
            input: 1.0,
            output: 1.0,
            cache_read: 1.0,
            cache_w5m: 1.0,
            cache_w1h: 1.0,
        };
        for (date, input) in [("2026-07-01", 1), ("2026-07-13", 2), ("2026-07-15", 4)] {
            agg.add_entry(
                &Entry {
                    date: date.parse().unwrap(),
                    hour: 0,
                    source: Source::Codex,
                    model: "gpt-test".into(),
                    speed: "high".into(),
                    usage: Usage {
                        input,
                        ..Default::default()
                    },
                },
                Some(price),
            );
        }

        let today: NaiveDate = "2026-07-15".parse().unwrap();
        let v = json_value(&agg, "all", today, true);

        assert_eq!(v["models_by_period"]["today"][0]["cost_usd"], 4.0);
        assert_eq!(v["models_by_period"]["week"][0]["cost_usd"], 6.0);
        assert_eq!(v["models_by_period"]["month"][0]["cost_usd"], 7.0);
    }
}
