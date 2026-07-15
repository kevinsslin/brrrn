use std::collections::{BTreeMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::agg::{Agg, Source};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub hub_url: String,
    #[serde(default)]
    pub handle: String,
    #[serde(default)]
    pub secret: Option<String>,
    #[serde(default)]
    pub machine_id: Option<String>,
    #[serde(default)]
    pub pits: Vec<String>,
    #[serde(default)]
    pub relationships: Vec<String>,
    #[serde(default)]
    pub backfilled_pits: Vec<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

impl Config {
    pub fn load(path: &Path) -> Result<Self, String> {
        let raw = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read config {}: {e}", path.display()))?;
        serde_json::from_str(&raw).map_err(|e| format!("invalid config {}: {e}", path.display()))
    }

    pub fn load_or_default(path: &Path) -> Result<Self, String> {
        if path.exists() {
            Self::load(path)
        } else {
            Ok(Self::default())
        }
    }

    pub fn update<F>(path: &Path, change: F) -> Result<Self, String>
    where
        F: FnOnce(&mut Self) -> Result<(), String>,
    {
        let process_mutex = process_mutex(path)?;
        let _process_guard = process_mutex
            .lock()
            .map_err(|_| "config process lock is poisoned".to_string())?;
        let _lock = ConfigLock::acquire(path)?;
        let mut config = Self::load_or_default(path)?;
        change(&mut config)?;
        config.save_unlocked(path)?;
        Ok(config)
    }

    pub fn append_pit(path: &Path, code: &str) -> Result<Self, String> {
        Self::append_unique(path, code, |config| &mut config.pits)
    }

    pub fn append_relationship(path: &Path, identifier: &str) -> Result<Self, String> {
        Self::append_unique(path, identifier, |config| &mut config.relationships)
    }

    pub fn append_backfill_marker(path: &Path, identifier: &str) -> Result<Self, String> {
        Self::append_unique(path, identifier, |config| &mut config.backfilled_pits)
    }

    pub fn append_backfill_marker_if_matches(
        path: &Path,
        expected: &Self,
        identifier: &str,
    ) -> Result<Self, String> {
        let identifier = identifier.trim();
        if identifier.is_empty() {
            return Err("social identifier cannot be empty".to_string());
        }
        Self::update(path, |config| {
            let identity_matches = config.hub_url == expected.hub_url
                && config.handle == expected.handle
                && config.secret == expected.secret
                && config.machine_id == expected.machine_id;
            if !identity_matches || !config.pits.iter().any(|pit| pit == identifier) {
                return Err(
                    "config changed during submission; backfill marker was not saved".to_string(),
                );
            }
            if !config
                .backfilled_pits
                .iter()
                .any(|marker| marker == identifier)
            {
                config.backfilled_pits.push(identifier.to_string());
            }
            Ok(())
        })
    }

    fn append_unique<F>(path: &Path, value: &str, field: F) -> Result<Self, String>
    where
        F: FnOnce(&mut Self) -> &mut Vec<String>,
    {
        let normalized = value.trim();
        if normalized.is_empty() {
            return Err("social identifier cannot be empty".to_string());
        }
        Self::update(path, |config| {
            let values = field(config);
            if !values.iter().any(|existing| existing == normalized) {
                values.push(normalized.to_string());
            }
            Ok(())
        })
    }

    fn save_unlocked(&self, path: &Path) -> Result<(), String> {
        let parent = path
            .parent()
            .ok_or_else(|| format!("config has no parent directory: {}", path.display()))?;
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;

        let mut bytes = serde_json::to_vec_pretty(self).map_err(|e| e.to_string())?;
        bytes.push(b'\n');
        static NEXT_TEMPORARY: AtomicU64 = AtomicU64::new(0);
        let sequence = NEXT_TEMPORARY.fetch_add(1, Ordering::Relaxed);
        let temporary = parent.join(format!(
            ".{}.tmp-{}-{sequence}",
            path.file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("config"),
            std::process::id()
        ));

        let result = (|| {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options
                .open(&temporary)
                .map_err(|e| format!("cannot create temporary config: {e}"))?;
            file.write_all(&bytes)
                .map_err(|e| format!("cannot write temporary config: {e}"))?;
            file.sync_all()
                .map_err(|e| format!("cannot sync temporary config: {e}"))?;
            std::fs::rename(&temporary, path).map_err(|e| format!("cannot save config: {e}"))?;
            protect_private(path)?;
            sync_parent_directory(parent)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        result
    }

    pub fn hub(&self) -> Result<&str, String> {
        if self.hub_url.trim().is_empty() {
            Err("hub is not configured; run: brrrn config set-hub <url>".to_string())
        } else {
            Ok(self.hub_url.trim_end_matches('/'))
        }
    }

    pub fn identity(&self) -> Result<(&str, &str, &str), String> {
        let secret = self
            .secret
            .as_deref()
            .ok_or("not joined; run: brrrn pit join <code> --as <handle>")?;
        let machine = self
            .machine_id
            .as_deref()
            .ok_or("missing machine_id in config")?;
        if self.handle.is_empty() {
            return Err("missing handle in config".to_string());
        }
        Ok((&self.handle, secret, machine))
    }
}

fn process_mutex(config_path: &Path) -> Result<Arc<Mutex<()>>, String> {
    static MUTEXES: OnceLock<Mutex<BTreeMap<PathBuf, Arc<Mutex<()>>>>> = OnceLock::new();
    let key = std::path::absolute(config_lock_path(config_path))
        .map_err(|e| format!("cannot resolve config lock path: {e}"))?;
    let mut mutexes = MUTEXES
        .get_or_init(|| Mutex::new(BTreeMap::new()))
        .lock()
        .map_err(|_| "config lock registry is poisoned".to_string())?;
    Ok(mutexes
        .entry(key)
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone())
}

fn config_lock_path(config_path: &Path) -> PathBuf {
    let mut lock_name = config_path.as_os_str().to_os_string();
    lock_name.push(".lock");
    PathBuf::from(lock_name)
}

struct ConfigLock {
    file: File,
}

impl ConfigLock {
    fn acquire(config_path: &Path) -> Result<Self, String> {
        let parent = config_path
            .parent()
            .ok_or_else(|| format!("config has no parent directory: {}", config_path.display()))?;
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
        let lock_path = config_lock_path(config_path);
        let mut options = OpenOptions::new();
        options.read(true).write(true).create(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let file = options
            .open(&lock_path)
            .map_err(|e| format!("cannot open config lock {}: {e}", lock_path.display()))?;
        protect_private(&lock_path)?;
        lock_file(&file)?;
        Ok(Self { file })
    }
}

impl Drop for ConfigLock {
    fn drop(&mut self) {
        unlock_file(&self.file);
    }
}

#[cfg(unix)]
fn lock_file(file: &File) -> Result<(), String> {
    use std::os::fd::AsRawFd;

    let mut lock = libc::flock {
        l_type: libc::F_WRLCK as libc::c_short,
        l_whence: libc::SEEK_SET as libc::c_short,
        l_start: 0,
        l_len: 0,
        l_pid: 0,
    };
    loop {
        let result = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLKW, &mut lock) };
        if result == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(format!("cannot lock config: {error}"));
        }
    }
}

#[cfg(not(unix))]
fn lock_file(_file: &File) -> Result<(), String> {
    Ok(())
}

#[cfg(unix)]
fn unlock_file(file: &File) {
    use std::os::fd::AsRawFd;

    let mut lock = libc::flock {
        l_type: libc::F_UNLCK as libc::c_short,
        l_whence: libc::SEEK_SET as libc::c_short,
        l_start: 0,
        l_len: 0,
        l_pid: 0,
    };
    let _ = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETLK, &mut lock) };
}

#[cfg(not(unix))]
fn unlock_file(_file: &File) {}

fn protect_private(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("cannot protect config {}: {e}", path.display()))?;
    }
    Ok(())
}

fn sync_parent_directory(parent: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        let directory = File::open(parent)
            .map_err(|e| format!("cannot open config directory {}: {e}", parent.display()))?;
        directory
            .sync_all()
            .map_err(|e| format!("cannot sync config directory {}: {e}", parent.display()))?;
    }
    Ok(())
}

pub fn default_config_path(home: &Path) -> PathBuf {
    home.join(".config/brrrn/config.json")
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct SubmitModel {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cost_usd: f64,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct SubmitDay {
    pub date: String,
    pub tokens: u64,
    pub cost_usd: f64,
    pub claude_usd: f64,
    pub codex_usd: f64,
    pub models: BTreeMap<String, SubmitModel>,
}

pub fn build_submit_days(agg: &Agg, since: Option<NaiveDate>) -> Vec<SubmitDay> {
    agg.daily
        .iter()
        .filter(|(date, _)| since.is_none_or(|min| **date >= min))
        .map(|(date, sources)| {
            let claude = sources.get(&Source::Claude);
            let codex = sources.get(&Source::Codex);
            let models = agg
                .daily_models
                .get(date)
                .map(|items| {
                    items
                        .iter()
                        .map(|(name, m)| {
                            (
                                name.clone(),
                                SubmitModel {
                                    input_tokens: m.input,
                                    output_tokens: m.output,
                                    cost_usd: m.cost,
                                },
                            )
                        })
                        .collect()
                })
                .unwrap_or_default();
            SubmitDay {
                date: date.to_string(),
                tokens: sources.values().map(|s| s.tokens).sum(),
                cost_usd: sources.values().map(|s| s.cost).sum(),
                claude_usd: claude.map(|s| s.cost).unwrap_or(0.0),
                codex_usd: codex.map(|s| s.cost).unwrap_or(0.0),
                models,
            }
        })
        .collect()
}

#[derive(Debug, Deserialize)]
pub struct PitCreateResponse {
    pub code: String,
}

#[derive(Debug, Deserialize)]
pub struct Board {
    pub name: Option<String>,
    pub code: String,
    pub members: Vec<BoardMember>,
}

#[derive(Debug, Deserialize)]
pub struct BoardMember {
    pub handle: String,
    pub today_usd: f64,
    pub week_usd: f64,
    pub month_usd: f64,
    pub streak_days: u32,
    pub top_model: Option<String>,
    #[serde(default)]
    pub models_week: Vec<BoardModel>,
}

#[derive(Debug, Deserialize)]
pub struct BoardModel {
    pub model: String,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cost_usd: f64,
}

#[derive(Debug, Deserialize)]
pub struct MemberDetail {
    pub handle: String,
    pub days: Vec<MemberDay>,
}

#[derive(Debug, Deserialize)]
pub struct MemberDay {
    pub date: String,
    pub tokens: u64,
    pub cost_usd: f64,
}

pub fn random_hex(bytes: usize) -> Result<String, String> {
    let mut file = std::fs::File::open("/dev/urandom")
        .map_err(|e| format!("cannot open system random source: {e}"))?;
    let mut buf = vec![0u8; bytes];
    std::io::Read::read_exact(&mut file, &mut buf)
        .map_err(|e| format!("cannot read system random source: {e}"))?;
    Ok(buf.iter().map(|b| format!("{b:02x}")).collect())
}

fn request(
    method: &str,
    url: &str,
    body: Option<&serde_json::Value>,
) -> Result<serde_json::Value, String> {
    let mut command = Command::new("curl");
    command.args([
        "-sS",
        "--connect-timeout",
        "10",
        "--max-time",
        "60",
        "-X",
        method,
        "-H",
        "content-type: application/json",
        "-w",
        "\n%{http_code}",
    ]);
    if body.is_some() {
        command.args(["--data-binary", "@-"]);
    }
    command
        .arg(url)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if body.is_some() {
        command.stdin(Stdio::piped());
    }
    let mut child = command
        .spawn()
        .map_err(|e| format!("cannot run curl: {e}"))?;
    if let Some(value) = body {
        let bytes = serde_json::to_vec(value).map_err(|e| e.to_string())?;
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(&bytes)
            .map_err(|e| e.to_string())?;
    }
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    if !output.status.success() {
        return Err(format!(
            "hub request failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let text = String::from_utf8(output.stdout).map_err(|e| e.to_string())?;
    let (raw, status) = text.rsplit_once('\n').ok_or("invalid response from hub")?;
    let status: u16 = status
        .trim()
        .parse()
        .map_err(|_| "invalid HTTP status from hub")?;
    let value: serde_json::Value =
        serde_json::from_str(raw).unwrap_or_else(|_| serde_json::json!({ "raw": raw }));
    if !(200..300).contains(&status) {
        let message = value["error"].as_str().unwrap_or("hub request failed");
        return Err(format!("hub returned {status}: {message}"));
    }
    Ok(value)
}

pub fn post<T: for<'de> Deserialize<'de>>(
    url: &str,
    body: &serde_json::Value,
) -> Result<T, String> {
    let value = request("POST", url, Some(body))?;
    serde_json::from_value(value).map_err(|e| format!("invalid hub response: {e}"))
}

pub fn get<T: for<'de> Deserialize<'de>>(url: &str) -> Result<T, String> {
    let value = request("GET", url, None)?;
    serde_json::from_value(value).map_err(|e| format!("invalid hub response: {e}"))
}

pub fn percent_encode(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

pub fn format_board(board: &Board) -> String {
    let title = board.name.as_deref().unwrap_or(&board.code);
    let mut out = format!("{title}  [{}]\n", board.code);
    out.push_str(&format!(
        "  {:<3} {:<20} {:>12} {:>12} {:>12}  {}\n",
        "#", "handle", "today", "week", "month", "streak"
    ));
    for (idx, member) in board.members.iter().enumerate() {
        out.push_str(&format!(
            "  {:<3} {:<20} {:>12} {:>12} {:>12}  {}d\n",
            idx + 1,
            member.handle,
            crate::report::fmt_money(member.today_usd),
            crate::report::fmt_money(member.week_usd),
            crate::report::fmt_money(member.month_usd),
            member.streak_days,
        ));
    }
    out
}

pub fn configured_pits(config: &Config) -> Result<HashSet<&str>, String> {
    if config.pits.is_empty() {
        return Err("no pits configured; run: brrrn pit join <code> --as <handle>".to_string());
    }
    Ok(config.pits.iter().map(String::as_str).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::agg::{Entry, Usage};
    use crate::pricing::Price;

    fn add(
        agg: &mut Agg,
        date: &str,
        source: Source,
        model: &str,
        input: u64,
        output: u64,
        input_price: f64,
    ) {
        agg.add_entry(
            &Entry {
                date: date.parse().unwrap(),
                hour: 0,
                source,
                model: model.into(),
                speed: "standard".into(),
                usage: Usage {
                    input,
                    output,
                    ..Default::default()
                },
            },
            Some(Price {
                input: input_price,
                output: input_price * 5.0,
                cache_read: input_price,
                cache_w5m: input_price,
                cache_w1h: input_price,
            }),
        );
    }

    #[test]
    fn submit_payload_sums_sources_and_preserves_model_detail() {
        let mut agg = Agg::default();
        add(
            &mut agg,
            "2026-07-12",
            Source::Claude,
            "fable",
            100,
            10,
            0.01,
        );
        add(&mut agg, "2026-07-12", Source::Codex, "gpt", 200, 20, 0.02);
        add(&mut agg, "2026-07-13", Source::Claude, "fable", 50, 5, 0.01);

        let days = build_submit_days(&agg, Some("2026-07-12".parse().unwrap()));
        assert_eq!(days.len(), 2);
        assert_eq!(days[0].tokens, 330);
        assert!(days[0].claude_usd > 0.0);
        assert!(days[0].codex_usd > days[0].claude_usd);
        assert_eq!(days[0].models["fable"].input_tokens, 100);
        assert_eq!(days[0].models["fable"].output_tokens, 10);
        assert_eq!(days[0].models["gpt"].input_tokens, 200);
    }

    #[test]
    fn submit_payload_since_filter_is_inclusive() {
        let mut agg = Agg::default();
        add(&mut agg, "2026-07-11", Source::Claude, "m", 1, 0, 1.0);
        add(&mut agg, "2026-07-12", Source::Claude, "m", 2, 0, 1.0);
        let days = build_submit_days(&agg, Some("2026-07-12".parse().unwrap()));
        assert_eq!(
            days.iter().map(|d| d.date.as_str()).collect::<Vec<_>>(),
            ["2026-07-12"]
        );
    }

    #[test]
    fn config_defaults_optional_fields() {
        let c: Config = serde_json::from_str(r#"{"handle":"k"}"#).unwrap();
        assert!(c.hub_url.is_empty());
        assert!(c.pits.is_empty());
        assert!(c.relationships.is_empty());
        assert!(c.backfilled_pits.is_empty());
        assert!(c.secret.is_none());

        for raw in [
            r#"{"hub_url":null}"#,
            r#"{"handle":null}"#,
            r#"{"pits":null}"#,
            r#"{"relationships":null}"#,
            r#"{"backfilled_pits":null}"#,
        ] {
            assert!(serde_json::from_str::<Config>(raw).is_err());
        }
    }

    #[test]
    fn backfill_marker_requires_the_submitted_identity_and_hub() {
        let fixture = ConfigFixture::new("backfill-match");
        let expected = Config::update(&fixture.path, |config| {
            config.hub_url = "https://old.example".into();
            config.handle = "kevin".into();
            config.secret = Some("secret".into());
            config.machine_id = Some("machine".into());
            config.pits.push("pit_one".into());
            Ok(())
        })
        .unwrap();

        Config::update(&fixture.path, |config| {
            config.hub_url = "https://new.example".into();
            config.relationships.push("rel_keep".into());
            Ok(())
        })
        .unwrap();
        assert!(
            Config::append_backfill_marker_if_matches(&fixture.path, &expected, "pit_one").is_err()
        );

        let config = Config::load(&fixture.path).unwrap();
        assert!(config.backfilled_pits.is_empty());
        assert_eq!(config.relationships, ["rel_keep"]);
    }

    #[test]
    fn config_update_preserves_unknown_fields_and_private_permissions() {
        let fixture = ConfigFixture::new("preserve");
        std::fs::write(
            &fixture.path,
            r#"{"hub_url":"https://hub","handle":"k","future":{"enabled":true}}"#,
        )
        .unwrap();

        Config::append_pit(&fixture.path, "pit_one").unwrap();
        Config::append_pit(&fixture.path, "pit_one").unwrap();
        Config::append_relationship(&fixture.path, "rel_one").unwrap();
        Config::append_relationship(&fixture.path, "rel_one").unwrap();
        Config::append_backfill_marker(&fixture.path, "pit_one").unwrap();
        Config::append_backfill_marker(&fixture.path, "pit_one").unwrap();

        let config = Config::load(&fixture.path).unwrap();
        assert_eq!(config.pits, ["pit_one"]);
        assert_eq!(config.relationships, ["rel_one"]);
        assert_eq!(config.backfilled_pits, ["pit_one"]);
        assert_eq!(config.extra["future"]["enabled"], true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&fixture.path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777;
            assert_eq!(mode, 0o600);
        }
    }

    #[test]
    fn config_update_never_replaces_malformed_json() {
        let fixture = ConfigFixture::new("malformed");
        let original = b"{broken";
        std::fs::write(&fixture.path, original).unwrap();

        let error = Config::update(&fixture.path, |config| {
            config.pits.push("pit_one".into());
            Ok(())
        })
        .unwrap_err();

        assert!(error.contains("invalid config"));
        assert_eq!(std::fs::read(&fixture.path).unwrap(), original);
    }

    #[test]
    fn config_update_serializes_writers_within_process() {
        let fixture = ConfigFixture::new("same-process");
        let first_path = fixture.path.clone();
        let first = std::thread::spawn(move || {
            Config::update(&first_path, |config| {
                config.pits.push("pit_one".into());
                std::thread::sleep(std::time::Duration::from_millis(200));
                Ok(())
            })
            .unwrap();
        });
        std::thread::sleep(std::time::Duration::from_millis(50));
        Config::update(&fixture.path, |config| {
            config.relationships.push("rel_one".into());
            Ok(())
        })
        .unwrap();
        first.join().unwrap();

        let config = Config::load(&fixture.path).unwrap();
        assert_eq!(config.pits, ["pit_one"]);
        assert_eq!(config.relationships, ["rel_one"]);
    }

    #[test]
    fn config_update_serializes_writers_across_processes() {
        let fixture = ConfigFixture::new("concurrent");
        let executable = std::env::current_exe().unwrap();
        let test_name = "social::tests::config_writer_helper";

        let mut first = Command::new(&executable)
            .args(["--exact", test_name, "--nocapture"])
            .env("BRRRN_CONFIG_WRITER_PATH", &fixture.path)
            .env("BRRRN_CONFIG_WRITER_FIELD", "pit")
            .env("BRRRN_CONFIG_WRITER_SLEEP_MS", "200")
            .spawn()
            .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));
        let mut second = Command::new(&executable)
            .args(["--exact", test_name, "--nocapture"])
            .env("BRRRN_CONFIG_WRITER_PATH", &fixture.path)
            .env("BRRRN_CONFIG_WRITER_FIELD", "relationship")
            .spawn()
            .unwrap();

        assert!(first.wait().unwrap().success());
        assert!(second.wait().unwrap().success());
        let config = Config::load(&fixture.path).unwrap();
        assert_eq!(config.pits, ["pit_one"]);
        assert_eq!(config.relationships, ["rel_one"]);
    }

    #[test]
    fn config_writer_helper() {
        let Some(path) = std::env::var_os("BRRRN_CONFIG_WRITER_PATH") else {
            return;
        };
        let field = std::env::var("BRRRN_CONFIG_WRITER_FIELD").unwrap();
        let sleep_ms = std::env::var("BRRRN_CONFIG_WRITER_SLEEP_MS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(0);
        Config::update(Path::new(&path), |config| {
            match field.as_str() {
                "pit" => config.pits.push("pit_one".into()),
                "relationship" => config.relationships.push("rel_one".into()),
                _ => panic!("unknown writer field"),
            }
            std::thread::sleep(std::time::Duration::from_millis(sleep_ms));
            Ok(())
        })
        .unwrap();
    }

    struct ConfigFixture {
        directory: PathBuf,
        path: PathBuf,
    }

    impl ConfigFixture {
        fn new(label: &str) -> Self {
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let id = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let directory = std::env::temp_dir()
                .join(format!("brrrn-config-{label}-{}-{id}", std::process::id()));
            std::fs::create_dir_all(&directory).unwrap();
            let path = directory.join("config.json");
            Self { directory, path }
        }
    }

    impl Drop for ConfigFixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.directory);
        }
    }

    #[test]
    fn tweet_text_percent_encoding_is_utf8_safe() {
        assert_eq!(percent_encode("a b🔥"), "a%20b%F0%9F%94%A5");
    }
}
