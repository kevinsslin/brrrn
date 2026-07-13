use std::path::PathBuf;
use std::process::Command;

use chrono::{Duration, Local, NaiveDate, Utc};
use clap::{Args as ClapArgs, Parser, Subcommand};
use serde::Deserialize;

use brrrn::pricing::Pricing;
use brrrn::social::{self, Board, Config, MemberDetail, PitCreateResponse};
use brrrn::windows::{month_start, week_start};
use brrrn::{report, scan};

const PRICING_URL: &str =
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";

#[derive(Parser)]
#[command(name = "brrrn", version, about = "Your tokens go brrrn: local burn + cost report for Claude Code and Codex")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    /// Report period: all, today, week (ISO week from Monday), month (calendar month)
    #[arg(long, default_value = "all", global = true)]
    period: String,

    /// Day boundary timezone: utc (leaderboard-comparable) or local
    #[arg(long, default_value = "utc", global = true)]
    tz: String,

    /// Emit machine-readable JSON instead of tables
    #[arg(long, global = true)]
    json: bool,

    /// Show per-day breakdown (last 14 days)
    #[arg(long, global = true)]
    daily: bool,

    /// Path to LiteLLM pricing JSON
    #[arg(long, global = true)]
    pricing: Option<PathBuf>,

    /// Download the latest pricing table before reporting
    #[arg(long, global = true)]
    update_pricing: bool,

    /// Claude Code data dir
    #[arg(long, global = true)]
    claude_dir: Option<PathBuf>,

    /// Codex data dir
    #[arg(long, global = true)]
    codex_dir: Option<PathBuf>,

    /// Scan cache path
    #[arg(long, global = true)]
    cache: Option<PathBuf>,

    /// Rescan every session file and do not use the scan cache
    #[arg(long, global = true)]
    no_cache: bool,

    /// Social config path
    #[arg(long, global = true)]
    config: Option<PathBuf>,
}

#[derive(Subcommand)]
enum Commands {
    /// Private friend-group leaderboard
    Pit(PitArgs),
    /// Upload local daily aggregates to every joined pit
    Submit,
    /// Create a shareable pre-filled post for today's burn
    Flex {
        /// Print the share URL without opening a browser
        #[arg(long)]
        no_open: bool,
    },
    /// Configure the leaderboard hub
    Config(ConfigArgs),
}

#[derive(ClapArgs)]
struct PitArgs {
    #[command(subcommand)]
    action: Option<PitAction>,
}

#[derive(Subcommand)]
enum PitAction {
    /// Create a private pit and print its invite code
    New {
        #[arg(long)]
        name: Option<String>,
    },
    /// Join a pit using its invite code
    Join {
        code: String,
        #[arg(long = "as")]
        handle: String,
    },
    /// Show one member's recent daily history
    Show {
        handle: String,
        #[arg(long)]
        pit: Option<String>,
    },
}

#[derive(ClapArgs)]
struct ConfigArgs {
    #[command(subcommand)]
    action: ConfigAction,
}

#[derive(Subcommand)]
enum ConfigAction {
    /// Set the Cloudflare Worker base URL
    SetHub { url: String },
    /// Print the current config (secret redacted)
    Show,
}

#[derive(Deserialize)]
struct OkResponse {
    ok: bool,
    #[serde(default)]
    days_stored: usize,
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").expect("HOME not set"))
}

fn config_path(cli: &Cli) -> PathBuf {
    cli.config.clone().unwrap_or_else(|| social::default_config_path(&home()))
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

fn scan_data(cli: &Cli, min_date: Option<NaiveDate>, utc: bool) -> Result<(brrrn::agg::Agg, scan::ScanStats), String> {
    let pricing = load_pricing(cli.pricing.clone(), cli.update_pricing)?;
    let claude_dir = cli.claude_dir.clone().unwrap_or_else(|| home().join(".claude/projects"));
    let codex_dir = cli.codex_dir.clone().unwrap_or_else(|| home().join(".codex/sessions"));
    let cache_path = if cli.no_cache {
        None
    } else {
        Some(cli.cache.clone().unwrap_or_else(|| home().join("Library/Caches/brrrn/scan-v2.json")))
    };
    Ok(scan::scan_all(
        &claude_dir,
        &codex_dir,
        &pricing,
        min_date,
        utc,
        cache_path.as_deref(),
    ))
}

fn run_report(cli: &Cli) -> Result<(), String> {
    let utc = match cli.tz.as_str() {
        "utc" => true,
        "local" => false,
        other => return Err(format!("unknown tz '{other}' (use utc|local)")),
    };
    let today = if utc { Utc::now().date_naive() } else { Local::now().date_naive() };
    let min_date = min_date_for(&cli.period, today)?;
    let started = std::time::Instant::now();
    let (agg, stats) = scan_data(cli, min_date, utc)?;

    if cli.json {
        report::print_json(&agg, &cli.period, today, utc);
    } else {
        report::print_report(&agg, &cli.period, today, min_date, utc);
        if cli.daily {
            report::print_daily(&agg, today);
        }
        eprintln!(
            "\n{} files ({} cached, {} scanned) / {} records in {:.2}s",
            stats.files_total,
            stats.files_cached,
            stats.files_scanned,
            stats.records,
            started.elapsed().as_secs_f64()
        );
        if let Some(e) = stats.cache_error {
            eprintln!("warning: could not save scan cache: {e}");
        }
    }
    Ok(())
}

fn load_config(cli: &Cli) -> Result<(Config, PathBuf), String> {
    let path = config_path(cli);
    Ok((Config::load_or_default(&path)?, path))
}

fn run_config(cli: &Cli, action: &ConfigAction) -> Result<(), String> {
    let (mut config, path) = load_config(cli)?;
    match action {
        ConfigAction::SetHub { url } => {
            if !(url.starts_with("https://") || url.starts_with("http://localhost") || url.starts_with("http://127.0.0.1")) {
                return Err("hub URL must use https (localhost may use http)".to_string());
            }
            config.hub_url = url.trim_end_matches('/').to_string();
            config.save(&path)?;
            println!("hub set to {}", config.hub_url);
        }
        ConfigAction::Show => {
            let mut value = serde_json::to_value(&config).map_err(|e| e.to_string())?;
            if value["secret"].is_string() {
                value["secret"] = serde_json::Value::String("<redacted>".to_string());
            }
            println!("{}", serde_json::to_string_pretty(&value).unwrap());
        }
    }
    Ok(())
}

fn run_pit(cli: &Cli, args: &PitArgs) -> Result<(), String> {
    match &args.action {
        Some(PitAction::New { name }) => pit_new(cli, name.as_deref()),
        Some(PitAction::Join { code, handle }) => pit_join(cli, code, handle),
        Some(PitAction::Show { handle, pit }) => pit_show(cli, handle, pit.as_deref()),
        None => pit_board(cli),
    }
}

fn pit_new(cli: &Cli, name: Option<&str>) -> Result<(), String> {
    let (config, _) = load_config(cli)?;
    let url = format!("{}/pit", config.hub()?);
    let response: PitCreateResponse = social::post(&url, &serde_json::json!({ "name": name }))?;
    println!("created pit: {}", response.code);
    println!("share this code, then join it yourself:");
    println!("  brrrn pit join {} --as <handle>", response.code);
    Ok(())
}

fn pit_join(cli: &Cli, code: &str, handle: &str) -> Result<(), String> {
    let (mut config, path) = load_config(cli)?;
    let hub = config.hub()?.to_string();
    let normalized = handle.to_lowercase();
    if !config.handle.is_empty() && config.handle != normalized {
        return Err(format!("this client already uses handle '{}'; one handle per client", config.handle));
    }
    let secret = config.secret.clone().unwrap_or(social::random_hex(24)?);
    let machine = config.machine_id.clone().unwrap_or(social::random_hex(12)?);
    let url = format!("{hub}/pit/{code}/join");
    let response: OkResponse = social::post(&url, &serde_json::json!({
        "handle": normalized,
        "secret": secret,
    }))?;
    if !response.ok {
        return Err("hub did not accept the join".to_string());
    }
    config.handle = normalized;
    config.secret = Some(secret);
    config.machine_id = Some(machine);
    if !config.pits.iter().any(|p| p == code) {
        config.pits.push(code.to_string());
    }
    config.save(&path)?;
    println!("joined pit {code} as {}", config.handle);
    println!("run `brrrn submit` to backfill your history");
    Ok(())
}

fn pit_board(cli: &Cli) -> Result<(), String> {
    let (config, _) = load_config(cli)?;
    let hub = config.hub()?;
    if config.pits.is_empty() {
        return Err("no pits configured; run: brrrn pit join <code> --as <handle>".to_string());
    }
    for (i, code) in config.pits.iter().enumerate() {
        let board: Board = social::get(&format!("{hub}/pit/{code}/board"))?;
        if i > 0 {
            println!();
        }
        print!("{}", social::format_board(&board));
    }
    Ok(())
}

fn selected_pit<'a>(config: &'a Config, requested: Option<&str>) -> Result<&'a str, String> {
    if let Some(code) = requested {
        return config.pits.iter().find(|p| p.as_str() == code).map(String::as_str)
            .ok_or_else(|| format!("pit {code} is not configured"));
    }
    config.pits.first().map(String::as_str)
        .ok_or_else(|| "no pits configured; run: brrrn pit join <code> --as <handle>".to_string())
}

fn pit_show(cli: &Cli, handle: &str, requested: Option<&str>) -> Result<(), String> {
    let (config, _) = load_config(cli)?;
    let hub = config.hub()?;
    let code = selected_pit(&config, requested)?;
    let detail: MemberDetail = social::get(&format!("{hub}/pit/{code}/member/{handle}"))?;
    println!("{} in {}", detail.handle, code);
    println!("  {:<12} {:>12} {:>12}", "date (UTC)", "cost", "tokens");
    for day in detail.days.iter().rev().take(14).rev() {
        println!(
            "  {:<12} {:>12} {:>12}",
            day.date,
            report::fmt_money(day.cost_usd),
            report::fmt_tokens(day.tokens),
        );
    }
    Ok(())
}

fn run_submit(cli: &Cli) -> Result<(), String> {
    let (mut config, path) = load_config(cli)?;
    let hub = config.hub()?.to_string();
    let (handle, secret, machine) = config.identity()?;
    let handle = handle.to_string();
    let secret = secret.to_string();
    let machine = machine.to_string();
    if config.pits.is_empty() {
        return Err("no pits configured; run: brrrn pit join <code> --as <handle>".to_string());
    }

    let (agg, _) = scan_data(cli, None, true)?;
    let all_days = social::build_submit_days(&agg, None);
    let today = Utc::now().date_naive();
    let backfilled: std::collections::HashSet<_> = config.backfilled_pits.iter().cloned().collect();

    for code in config.pits.clone() {
        let days: Vec<_> = if backfilled.contains(&code) {
            all_days.iter().filter(|d| d.date.parse::<NaiveDate>().is_ok_and(|date| date >= today - Duration::days(1))).cloned().collect()
        } else {
            all_days.clone()
        };
        let mut stored = 0usize;
        for chunk in days.chunks(400) {
            let response: OkResponse = social::post(
                &format!("{hub}/pit/{code}/submit"),
                &serde_json::json!({
                    "handle": handle,
                    "secret": secret,
                    "machine_id": machine,
                    "days": chunk,
                }),
            )?;
            stored += response.days_stored;
        }
        if days.is_empty() {
            let _: OkResponse = social::post(
                &format!("{hub}/pit/{code}/submit"),
                &serde_json::json!({ "handle": handle, "secret": secret, "machine_id": machine, "days": [] }),
            )?;
        }
        if !config.backfilled_pits.contains(&code) {
            config.backfilled_pits.push(code.clone());
        }
        println!("submitted {stored} UTC day{} to {code}", if stored == 1 { "" } else { "s" });
    }
    config.save(&path)?;
    Ok(())
}

fn run_flex(cli: &Cli, no_open: bool) -> Result<(), String> {
    let today = Utc::now().date_naive();
    let (agg, _) = scan_data(cli, Some(today), true)?;
    let own = agg.daily.get(&today).map(|s| s.values().map(|d| d.cost).sum()).unwrap_or(0.0);
    let mut text = format!("I burned {} of AI tokens today 🔥", report::fmt_money(own));

    if let Ok((config, _)) = load_config(cli) {
        if let (Ok(hub), Some(code)) = (config.hub(), config.pits.first()) {
            if let Ok::<Board, _>(board) = social::get(&format!("{hub}/pit/{code}/board")) {
                let crew: f64 = board.members.iter().map(|m| m.today_usd).sum();
                text.push_str(&format!("\nMy crew burned {}.\n\nbrrrn", report::fmt_money(crew)));
            }
        }
    }
    let url = format!("https://twitter.com/intent/tweet?text={}", social::percent_encode(&text));
    println!("{url}");
    if !no_open {
        Command::new("open").arg(&url).status().map_err(|e| format!("cannot open browser: {e}"))?;
    }
    Ok(())
}

fn main() {
    let cli = Cli::parse();
    let result = match &cli.command {
        None => run_report(&cli),
        Some(Commands::Pit(args)) => run_pit(&cli, args),
        Some(Commands::Submit) => run_submit(&cli),
        Some(Commands::Flex { no_open }) => run_flex(&cli, *no_open),
        Some(Commands::Config(args)) => run_config(&cli, &args.action),
    };
    if let Err(e) = result {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
