//! Feedback reports: the addon's "What went wrong?" window leaves them in its saved variables
//! (`PathwrightDB.feedback`: lines `PWFB1:<id>:<the report's JSON in base64>`), which the game
//! writes to `WTF/Account/<account>/SavedVariables/Pathwright_Profile.lua` at a reload or a
//! logout. The updater reads those lines there (nothing else of the file), posts each report
//! once to the project's relay (`relay/worker.js`), which opens a GitHub issue, and tells the
//! addon through `Pathwright_Guide/Updater.lua`: when it last ran here, and the reports it sent
//! with their issue's address. The addon reads that file at the next login.
//!
//! Only what the player sent with OK in that window leaves the computer: the report's text,
//! which the window shows.

use crate::settings::Settings;
use anyhow::{Context, Result, bail};
use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The relay the reports are posted to (see relay/README.md). Were it empty, no report would be
/// sent and the addon would not be told an updater runs here.
pub const RELAY_URL: &str = "https://pathwright-feedback.rlincoln66.workers.dev/";
/// The start of a report's line in the saved variables (Feedback.lua).
const PREFIX: &str = "PWFB1:";
/// The most a report may weigh once decoded: the addon cuts its own well under that.
const MAX_REPORT: usize = 16 * 1024;
/// Reports remembered as sent (their id and their issue), the newest kept.
const MAX_SENT: usize = 20;
/// Between two tries of a report the relay did not take.
const RETRY: Duration = Duration::from_mins(5);
/// Between two notes of "seen at" in Updater.lua when nothing else changed.
const SEEN_EVERY: u64 = 6 * 3600;
const USER_AGENT: &str = concat!("pathwright-updater/", env!("CARGO_PKG_VERSION"));
/// The first line of Updater.lua as this updater writes it: the file the addon ships with
/// does not start so.
const HEADER: &str = "-- Written by the Pathwright Updater: when it last ran here, and the feedback reports it sent.";

/// A report waiting in the saved variables.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    pub id: String,
    pub json: String,
}

/// The addon's saved variables, one file per game account, for the game whose AddOns folder
/// this is (`…/_forever_/Interface/AddOns` → `…/_forever_/WTF/Account/*/SavedVariables`).
pub fn saved_variables(addons: &Path) -> Vec<PathBuf> {
    let Some(game) = addons.parent().and_then(Path::parent) else {
        return Vec::new();
    };
    let Ok(accounts) = std::fs::read_dir(game.join("WTF").join("Account")) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = accounts
        .filter_map(Result::ok)
        .map(|account| account.path().join("SavedVariables").join("Pathwright_Profile.lua"))
        .filter(|file| file.is_file())
        .collect();
    files.sort();
    files
}

fn base64(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let (mut bits, mut count) = (0u32, 0u8);
    for byte in text.bytes() {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            _ => return None,
        };
        bits = (bits << 6) | u32::from(value);
        count += 1;
        if count == 4 {
            out.extend_from_slice(&[(bits >> 16) as u8, (bits >> 8) as u8, bits as u8]);
            (bits, count) = (0, 0);
        }
    }
    match count {
        0 => {}
        2 => out.push((bits >> 4) as u8),
        3 => out.extend_from_slice(&[(bits >> 10) as u8, (bits >> 2) as u8]),
        _ => return None,
    }
    Some(out)
}

/// The reports in a saved variables file's text: every `PWFB1:<id>:<base64>` whose content is
/// a feedback report (a JSON object that says so, of a size a report has). Anything else in
/// the file is passed over.
pub fn waiting(text: &str) -> Vec<Report> {
    let mut reports: Vec<Report> = Vec::new();
    for (at, _) in text.match_indices(PREFIX) {
        let rest = &text[at + PREFIX.len()..];
        let Some((id, rest)) = rest.split_once(':') else {
            continue;
        };
        let known = |c: char| c.is_ascii_hexdigit() || c == '-';
        if id.is_empty() || id.len() > 40 || !id.chars().all(known) {
            continue;
        }
        let encoded: &str = rest
            .split(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '=')))
            .next()
            .unwrap_or("");
        if encoded.is_empty() || encoded.len() > MAX_REPORT * 2 {
            continue;
        }
        let Some(json) = base64(encoded).and_then(|bytes| String::from_utf8(bytes).ok()) else {
            continue;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&json) else {
            continue;
        };
        if json.len() > MAX_REPORT || value.get("report").and_then(|r| r.as_str()) != Some("pathwright-feedback") {
            continue;
        }
        if !reports.iter().any(|r| r.id == id) {
            reports.push(Report {
                id: id.to_owned(),
                json,
            });
        }
    }
    reports
}

/// Post a report to the relay. Returns the address of the issue it opened.
pub fn send(relay: &str, report: &Report) -> Result<String> {
    let body = format!(r#"{{"id":"{}","report":{}}}"#, report.id, report.json);
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(30)))
        .user_agent(USER_AGENT)
        .build()
        .into();
    let mut response = agent
        .post(relay)
        .header("Content-Type", "application/json")
        .send(body.as_bytes())
        .context("the relay")?;
    let answer = response.body_mut().read_to_string().context("the relay's answer")?;
    let value: serde_json::Value = serde_json::from_str(&answer).context("the relay's answer")?;
    let Some(url) = value.get("url").and_then(|u| u.as_str()) else {
        bail!("the relay gave no issue");
    };
    if !issue_address(url) {
        bail!("the relay's answer is not an issue's address");
    }
    Ok(url.to_owned())
}

/// Whether a text is the address of a GitHub issue and nothing more: it goes into a Lua file.
fn issue_address(url: &str) -> bool {
    url.len() < 120
        && url.starts_with("https://github.com/")
        && url
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, ':' | '/' | '.' | '-' | '_' | '#'))
}

/// `Pathwright_Guide/Updater.lua` as the addon reads it.
pub fn updater_file(now: u64, sent: &BTreeMap<String, String>) -> String {
    let mut lines = format!("{HEADER}\n");
    let _ = writeln!(lines, "Pathwright.updater = {{ at = {now}, sent = {{");
    for (id, url) in sent {
        if id.chars().all(|c| c.is_ascii_hexdigit() || c == '-') && issue_address(url) {
            let _ = writeln!(lines, "    [\"{id}\"] = \"{url}\",");
        }
    }
    lines.push_str("} }\n");
    lines
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

/// What the watch remembers between two looks: when each file last changed, the reports the
/// relay did not take yet, when the addon was last told the updater runs.
#[derive(Default)]
pub struct Watch {
    seen: BTreeMap<PathBuf, SystemTime>,
    pending: Vec<Report>,
    tried: Option<std::time::Instant>,
    told: u64,
}

impl Watch {
    /// One look: read the saved variables that changed, send the reports not sent yet, tell the
    /// addon. Returns what to show of it (a report sent), if anything.
    pub fn look(&mut self, relay: &str, addons: &Path) -> Option<String> {
        if relay.is_empty() || !addons.join("Pathwright_Guide").is_dir() {
            return None;
        }
        let sent = Settings::load().sent;
        for file in saved_variables(addons) {
            let Ok(changed) = std::fs::metadata(&file).and_then(|m| m.modified()) else {
                continue;
            };
            if self.seen.get(&file) == Some(&changed) {
                continue;
            }
            self.seen.insert(file.clone(), changed);
            let Ok(text) = std::fs::read_to_string(&file) else {
                continue;
            };
            for report in waiting(&text) {
                let known = sent.contains_key(&report.id) || self.pending.iter().any(|p| p.id == report.id);
                if !known {
                    self.pending.push(report);
                    self.tried = None;
                }
            }
        }
        let mut shown = None;
        let due = self.tried.is_none_or(|at| at.elapsed() >= RETRY);
        if due && !self.pending.is_empty() {
            self.tried = Some(std::time::Instant::now());
            let (mut left, mut went) = (Vec::new(), Vec::new());
            for report in std::mem::take(&mut self.pending) {
                match send(relay, &report) {
                    Ok(url) => {
                        shown = Some(format!("Feedback sent: {url}"));
                        went.push((report.id, url));
                    }
                    Err(error) => {
                        eprintln!("pathwright-updater: feedback {} not sent: {error:#}", report.id);
                        left.push(report);
                    }
                }
            }
            self.pending = left;
            if !went.is_empty() {
                // Read again: the check for updates may have saved its own in the meantime.
                let mut settings = Settings::load();
                settings.sent.extend(went);
                while settings.sent.len() > MAX_SENT {
                    settings.sent.pop_first();
                }
                settings.save();
            }
        }
        // The addon is told: at once when a report went, else now and then that we run here, and
        // again when the file is no longer ours (the addon installed anew brings an empty one).
        let time = now();
        let file = addons.join("Pathwright_Guide").join("Updater.lua");
        let ours = std::fs::read_to_string(&file).is_ok_and(|text| text.starts_with(HEADER));
        let due = shown.is_some() || !ours || time.saturating_sub(self.told) >= SEEN_EVERY;
        if due && std::fs::write(&file, updater_file(time, &Settings::load().sent)).is_ok() {
            self.told = time;
        }
        shown
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAVED: &str = r#"
PathwrightDB = {
["feedback"] = {
"PWFB1:1795491613-cb51:eyJyZXBvcnQiOiJwYXRod3JpZ2h0LWZlZWRiYWNrIiwidiI6MSwid2hhdF93ZW50X3dyb25nIjoiTm8gd29sdmVzIn0=", -- [1]
"PWFB1:1795491700-00ff:bm90IGpzb24=", -- [2]
"PWFB1:1795491800-zzzz:eyJyZXBvcnQiOiJwYXRod3JpZ2h0LWZlZWRiYWNrIn0=", -- [3]
"PWFB1:1795491900-0a0a:eyJyZXBvcnQiOiJzb21ldGhpbmctZWxzZSJ9", -- [4]
},
["errors"] = {
},
}
"#;

    #[test]
    fn only_the_feedback_reports_are_read_from_the_saved_variables() {
        let reports = waiting(SAVED);
        assert_eq!(
            reports.len(),
            1,
            "one report: the others are not JSON, not a report, or ill named"
        );
        assert_eq!(reports[0].id, "1795491613-cb51");
        assert_eq!(
            reports[0].json,
            r#"{"report":"pathwright-feedback","v":1,"what_went_wrong":"No wolves"}"#
        );
    }

    #[test]
    fn base64_is_read_with_and_without_padding() {
        assert_eq!(base64("TWFu").unwrap(), b"Man");
        assert_eq!(base64("TWE=").unwrap(), b"Ma");
        assert_eq!(base64("TQ==").unwrap(), b"M");
        assert!(base64("T").is_none() && base64("TW*u").is_none());
    }

    #[test]
    fn the_addon_is_told_only_of_issues() {
        let mut sent = BTreeMap::new();
        sent.insert(
            "1795491613-cb51".to_owned(),
            "https://github.com/weirdr/Pathwright/issues/12".to_owned(),
        );
        sent.insert(
            "1795491700-00ff".to_owned(),
            "https://github.com/x\" } os.exit() --".to_owned(),
        );
        let file = updater_file(1_795_491_999, &sent);
        assert!(file.contains("Pathwright.updater = { at = 1795491999, sent = {"));
        assert!(file.contains(r#"["1795491613-cb51"] = "https://github.com/weirdr/Pathwright/issues/12","#));
        assert!(!file.contains("os.exit"), "an address that is not one is left out");
    }

    #[test]
    fn the_saved_variables_are_found_next_to_the_addons() {
        let dir = std::env::temp_dir().join(format!("pathwright-feedback-{}", std::process::id()));
        let addons = dir.join("_forever_/Interface/AddOns");
        let saved = dir.join("_forever_/WTF/Account/ACCOUNT/SavedVariables");
        std::fs::create_dir_all(&addons).unwrap();
        std::fs::create_dir_all(&saved).unwrap();
        std::fs::write(saved.join("Pathwright_Profile.lua"), SAVED).unwrap();
        assert_eq!(saved_variables(&addons), vec![saved.join("Pathwright_Profile.lua")]);
        // Without a relay nothing is read or written.
        assert!(Watch::default().look("", &addons).is_none());
        assert!(!addons.join("Pathwright_Guide/Updater.lua").exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn the_addon_is_told_again_when_its_file_is_no_longer_ours() {
        let dir = std::env::temp_dir().join(format!("pathwright-told-{}", std::process::id()));
        let addons = dir.join("_forever_/Interface/AddOns");
        let file = addons.join("Pathwright_Guide/Updater.lua");
        // As the addon ships it: its comment shows what the updater writes, and is not it.
        let shipped = "--   Pathwright.updater = { at = 1795490000, sent = {} }\nPathwright.updater = nil\n";
        std::fs::create_dir_all(addons.join("Pathwright_Guide")).unwrap();
        std::fs::write(&file, shipped).unwrap();
        let mut watch = Watch::default();
        // No saved variables, so nothing to send: the relay is never called.
        assert!(watch.look("http://127.0.0.1:9/", &addons).is_none());
        assert!(
            std::fs::read_to_string(&file).unwrap().starts_with(HEADER),
            "told at the first look"
        );
        std::fs::write(&file, shipped).unwrap();
        assert!(watch.look("http://127.0.0.1:9/", &addons).is_none());
        assert!(
            std::fs::read_to_string(&file).unwrap().starts_with(HEADER),
            "and again once installed anew"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
