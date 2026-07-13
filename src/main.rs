mod agg;
mod claude;
mod codex;
mod pricing;

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;

use chrono::{Datelike, Duration, Local, NaiveDate};
use clap::Parser;

use agg::{Agg, Source};
use pricing::Pricing;

const PRICING_URL: &str =
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";

#[derive(Parser)]
#[command(name = "brrrn", version, about = "Your tokens go brrrn: local burn + cost report for Claude Code and Codex")]
struct Args {
    /// Report period: all, today, week (last 7 days), month (calendar month)
    #[arg(long, default_value = "all")]
    period: String,

    /// Day boundary timezone: utc (leaderboard-comparable) or local
    #[arg(long, default_value = "utc")]
    tz: String,

    /// Emit machine-readable JSON instead of tables
    #[arg(long)]
    json: bool,

    /// Show per-day breakdown (last 14 days)
    #[arg(long)]
    daily: bool,

    /// Path to LiteLLM pricing JSON (default: ~/Library/Caches/brrrn/litellm_prices.json)
    #[arg(long)]
    pricing: Option<PathBuf>,

    /// Download the latest pricing table before reporting (uses curl)
    #[arg(long)]
    update_pricing: bool,

    /// Claude Code data dir (default: ~/.claude/projects)
    #[arg(long)]
    claude_dir: Option<PathBuf>,

    /// Codex data dir (default: ~/.codex/sessions)
    #[arg(long)]
    codex_dir: Option<PathBuf>,
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").expect("HOME not set"))
}

fn min_date_for(period: &str, today: NaiveDate) -> Result<Option<NaiveDate>, String> {
    match period {
        "all" => Ok(None),
        "today" => Ok(Some(today)),
        "week" => Ok(Some(today - Duration::days(6))),
        "month" => Ok(Some(today.with_day(1).unwrap())),
        other => Err(format!("unknown period '{other}' (use all|today|week|month)")),
    }
}

fn main() {
    let args = Args::parse();
    let utc = match args.tz.as_str() {
        "utc" => true,
        "local" => false,
        other => {
            eprintln!("error: unknown tz '{other}' (use utc|local)");
            std::process::exit(2);
        }
    };
    let today = if utc {
        chrono::Utc::now().date_naive()
    } else {
        Local::now().date_naive()
    };
    let min_date = match min_date_for(&args.period, today) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(2);
        }
    };

    let pricing_path = args
        .pricing
        .unwrap_or_else(|| home().join("Library/Caches/brrrn/litellm_prices.json"));
    if args.update_pricing || !pricing_path.exists() {
        if let Some(dir) = pricing_path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        eprintln!("fetching pricing table from LiteLLM ...");
        let ok = Command::new("curl")
            .args(["-sL", "--max-time", "60", "-o"])
            .arg(&pricing_path)
            .arg(PRICING_URL)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !ok && !pricing_path.exists() {
            eprintln!("error: could not fetch pricing table; pass --pricing <path>");
            std::process::exit(1);
        }
    }
    let pricing = match Pricing::load(&pricing_path) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };

    let claude_dir = args.claude_dir.unwrap_or_else(|| home().join(".claude/projects"));
    let codex_dir = args.codex_dir.unwrap_or_else(|| home().join(".codex/sessions"));

    let started = std::time::Instant::now();
    let mut agg = Agg::default();
    let mut files = 0u64;
    if claude_dir.exists() {
        files += claude::scan(&claude_dir, &pricing, &mut agg, min_date, utc);
    }
    if codex_dir.exists() {
        files += codex::scan(&codex_dir, &pricing, &mut agg, min_date, utc);
    }

    if args.json {
        print_json(&agg, &args.period, today, utc);
    } else {
        print_report(&agg, &args.period, today, min_date, utc);
        if args.daily {
            print_daily(&agg, today);
        }
        eprintln!(
            "\nscanned {files} files / {} records in {:.1}s",
            agg.records,
            started.elapsed().as_secs_f64()
        );
    }
}

fn fmt_tokens(n: u64) -> String {
    match n {
        0..=999 => n.to_string(),
        1_000..=999_999 => format!("{:.1}K", n as f64 / 1e3),
        1_000_000..=999_999_999 => format!("{:.1}M", n as f64 / 1e6),
        _ => format!("{:.2}B", n as f64 / 1e9),
    }
}

fn fmt_money(v: f64) -> String {
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

/// (tokens, cost, unpriced_tokens) across sources for days in [from, to].
fn window(agg: &Agg, from: NaiveDate, to: NaiveDate) -> BTreeMap<Source, (u64, f64, u64)> {
    let mut out: BTreeMap<Source, (u64, f64, u64)> = BTreeMap::new();
    for (day, per_source) in agg.daily.range(from..=to) {
        let _ = day;
        for (src, d) in per_source {
            let e = out.entry(*src).or_default();
            e.0 += d.tokens;
            e.1 += d.cost;
            e.2 += d.unpriced_tokens;
        }
    }
    out
}

fn print_window_rows(agg: &Agg, label: &str, from: NaiveDate, to: NaiveDate) {
    let w = window(agg, from, to);
    let tokens: u64 = w.values().map(|v| v.0).sum();
    let cost: f64 = w.values().map(|v| v.1).sum();
    let claude = w.get(&Source::Claude).copied().unwrap_or_default();
    let codex = w.get(&Source::Codex).copied().unwrap_or_default();
    println!(
        "{label:<12} {:>8}  {:>12}   (claude {} / codex {})",
        fmt_tokens(tokens),
        fmt_money(cost),
        fmt_money(claude.1),
        fmt_money(codex.1),
    );
}

fn print_report(agg: &Agg, period: &str, today: NaiveDate, min_date: Option<NaiveDate>, utc: bool) {
    let first = agg.daily.keys().next().copied().unwrap_or(today);
    let tz = if utc { "UTC" } else { "local time" };
    println!("brrrn: token burn across Claude Code + Codex (days in {tz})\n");

    if period == "all" {
        println!("{:<12} {:>8}  {:>12}", "period", "tokens", "cost");
        print_window_rows(agg, "today", today, today);
        print_window_rows(agg, "last 7d", today - Duration::days(6), today);
        print_window_rows(agg, "this month", today.with_day(1).unwrap(), today);
        print_window_rows(agg, "all time", first, today);
    } else {
        println!("{:<12} {:>8}  {:>12}", "period", "tokens", "cost");
        print_window_rows(agg, period, min_date.unwrap_or(first), today);
    }

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
        println!("\nnote: no pricing found for: {} (tokens counted, cost excluded)", unpriced.join(", "));
    }
}

fn print_daily(agg: &Agg, today: NaiveDate) {
    println!("\n{:<12} {:>10} {:>12}", "day", "tokens", "cost");
    let from = today - Duration::days(13);
    for (day, per_source) in agg.daily.range(from..=today) {
        let tokens: u64 = per_source.values().map(|d| d.tokens).sum();
        let cost: f64 = per_source.values().map(|d| d.cost).sum();
        println!("{:<12} {:>10} {:>12}", day.to_string(), fmt_tokens(tokens), fmt_money(cost));
    }
}

fn print_json(agg: &Agg, period: &str, today: NaiveDate, utc: bool) {
    let first = agg.daily.keys().next().copied().unwrap_or(today);
    let windows = serde_json::json!({
        "today": window_json(agg, today, today),
        "week": window_json(agg, today - Duration::days(6), today),
        "month": window_json(agg, today.with_day(1).unwrap(), today),
        "all": window_json(agg, first, today),
    });
    let by_model: Vec<_> = agg
        .by_key
        .iter()
        .map(|(k, (u, cost))| {
            serde_json::json!({
                "source": k.source.label(),
                "model": k.model,
                "speed": k.speed,
                "input_tokens": u.input,
                "cache_read_tokens": u.cache_read,
                "cache_write_tokens": u.cache_w5m + u.cache_w1h,
                "output_tokens": u.output,
                "reasoning_tokens": u.reasoning,
                "total_tokens": u.total(),
                "cost_usd": cost,
            })
        })
        .collect();
    let daily: Vec<_> = agg
        .daily
        .iter()
        .map(|(day, per_source)| {
            serde_json::json!({
                "date": day.to_string(),
                "tokens": per_source.values().map(|d| d.tokens).sum::<u64>(),
                "cost_usd": per_source.values().map(|d| d.cost).sum::<f64>(),
            })
        })
        .collect();
    let out = serde_json::json!({
        "period": period,
        "tz": if utc { "utc" } else { "local" },
        "generated_on": today.to_string(),
        "windows": windows,
        "by_model": by_model,
        "daily": daily,
    });
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
}

fn window_json(agg: &Agg, from: NaiveDate, to: NaiveDate) -> serde_json::Value {
    let w = window(agg, from, to);
    serde_json::json!({
        "tokens": w.values().map(|v| v.0).sum::<u64>(),
        "cost_usd": w.values().map(|v| v.1).sum::<f64>(),
        "unpriced_tokens": w.values().map(|v| v.2).sum::<u64>(),
    })
}
