use std::collections::{BTreeMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::agg::{Agg, Source};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Config {
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
    pub backfilled_pits: Vec<String>,
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

    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| format!("cannot create {}: {e}", parent.display()))?;
        }
        let bytes = serde_json::to_vec_pretty(self).map_err(|e| e.to_string())?;
        let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
        std::fs::write(&tmp, bytes).map_err(|e| format!("cannot write config: {e}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        }
        std::fs::rename(&tmp, path).map_err(|e| format!("cannot save config: {e}"))
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
        let c: Config = serde_json::from_str(r#"{"hub_url":"https://hub","handle":"k"}"#).unwrap();
        assert!(c.pits.is_empty());
        assert!(c.backfilled_pits.is_empty());
        assert!(c.secret.is_none());
    }

    #[test]
    fn tweet_text_percent_encoding_is_utf8_safe() {
        assert_eq!(percent_encode("a b🔥"), "a%20b%F0%9F%94%A5");
    }
}
