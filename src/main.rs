use std::path::PathBuf;
use std::process::Command;

use chrono::{Local, NaiveDate};
use clap::Parser;

use brrrn::pricing::Pricing;
use brrrn::windows::{month_start, week_start};
use brrrn::{report, scan};

const PRICING_URL: &str =
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";

#[derive(Parser)]
#[command(name = "brrrn", version, about = "Your tokens go brrrn: local burn + cost report for Claude Code and Codex")]
struct Args {
    /// Report period: all, today, week (ISO week from Monday), month (calendar month)
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
        "week" => Ok(Some(week_start(today))),
        "month" => Ok(Some(month_start(today))),
        other => Err(format!("unknown period '{other}' (use all|today|week|month)")),
    }
}

fn load_pricing(path_override: Option<PathBuf>, force_update: bool) -> Result<Pricing, String> {
    let path = path_override
        .unwrap_or_else(|| home().join("Library/Caches/brrrn/litellm_prices.json"));
    if force_update || !path.exists() {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        eprintln!("fetching pricing table from LiteLLM ...");
        let ok = Command::new("curl")
            .args(["-sL", "--max-time", "60", "-o"])
            .arg(&path)
            .arg(PRICING_URL)
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if !ok && !path.exists() {
            return Err("could not fetch pricing table; pass --pricing <path>".to_string());
        }
    }
    Pricing::load(&path)
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

    let pricing = match load_pricing(args.pricing, args.update_pricing) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    };

    let claude_dir = args.claude_dir.unwrap_or_else(|| home().join(".claude/projects"));
    let codex_dir = args.codex_dir.unwrap_or_else(|| home().join(".codex/sessions"));

    let started = std::time::Instant::now();
    let (agg, stats) = scan::scan_all(&claude_dir, &codex_dir, &pricing, min_date, utc);

    if args.json {
        report::print_json(&agg, &args.period, today, utc);
    } else {
        report::print_report(&agg, &args.period, today, min_date, utc);
        if args.daily {
            report::print_daily(&agg, today);
        }
        eprintln!(
            "\nscanned {} files / {} records in {:.1}s",
            stats.files_scanned,
            agg.records,
            started.elapsed().as_secs_f64()
        );
    }
}
