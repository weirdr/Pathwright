//! The addon's releases on GitHub: the newest one, and its zip.

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use std::io::Read;

/// The repository the addon is released from.
pub const REPO: &str = "weirdr/Pathwright";
/// The addon's releases are tagged `addon-YYYY.MM.DD-HHMM` (.github/workflows/addon-release.yml);
/// the updater's own are `updater-v…` and are left alone.
const TAG_PREFIX: &str = "addon-";
/// The zip each addon release carries (scripts/addon-zip.sh).
const ASSET: &str = "Pathwright-addon.zip";
/// The most a zip may weigh (it is a few MB).
const MAX_ZIP: u64 = 200 * 1024 * 1024;
const USER_AGENT: &str = concat!("pathwright-updater/", env!("CARGO_PKG_VERSION"));
/// The longest a request may take: one that stalls (a network gone quiet) must not hold the
/// checks up for good.
const TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_global(Some(TIMEOUT))
        .user_agent(USER_AGENT)
        .build()
        .into()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    pub tag: String,
    pub zip_url: String,
}

#[derive(Deserialize)]
struct ApiRelease {
    tag_name: String,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    assets: Vec<ApiAsset>,
}

#[derive(Deserialize)]
struct ApiAsset {
    name: String,
    browser_download_url: String,
}

/// The newest addon release in a releases listing (GitHub lists them newest first).
pub fn newest_addon_release(json: &str) -> Result<Option<Release>> {
    let releases: Vec<ApiRelease> = serde_json::from_str(json).context("the releases listing")?;
    Ok(releases
        .into_iter()
        .filter(|r| !r.draft && r.tag_name.starts_with(TAG_PREFIX))
        .find_map(|r| {
            let asset = r.assets.into_iter().find(|a| a.name == ASSET)?;
            Some(Release {
                tag: r.tag_name,
                zip_url: asset.browser_download_url,
            })
        }))
}

/// Ask GitHub for the newest addon release.
pub fn latest() -> Result<Option<Release>> {
    let url = format!("https://api.github.com/repos/{REPO}/releases?per_page=20");
    let mut response = agent()
        .get(&url)
        .header("Accept", "application/vnd.github+json")
        .call()
        .context("GitHub's releases")?;
    let json = response.body_mut().read_to_string().context("GitHub's answer")?;
    newest_addon_release(&json)
}

/// Download a release's zip.
pub fn download(release: &Release) -> Result<Vec<u8>> {
    let mut response = agent()
        .get(&release.zip_url)
        .call()
        .with_context(|| format!("downloading {}", release.tag))?;
    let mut bytes = Vec::new();
    response
        .body_mut()
        .as_reader()
        .take(MAX_ZIP + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_ZIP {
        bail!("the zip of {} is too large", release.tag);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_newest_addon_release_with_its_zip_is_taken() {
        let json = r#"[
            {"tag_name": "updater-v0.1.0", "draft": false, "assets": [{"name": "x.exe", "browser_download_url": "u"}]},
            {"tag_name": "addon-2026.11.23-0500", "draft": true, "assets": [{"name": "Pathwright-addon.zip", "browser_download_url": "draft"}]},
            {"tag_name": "addon-2026.11.23-0400", "draft": false, "assets": []},
            {"tag_name": "addon-2026.11.23-0309", "draft": false, "assets": [{"name": "Pathwright-addon.zip", "browser_download_url": "https://example/zip"}]}
        ]"#;
        let release = newest_addon_release(json).unwrap().unwrap();
        assert_eq!(release.tag, "addon-2026.11.23-0309");
        assert_eq!(release.zip_url, "https://example/zip");
        assert_eq!(newest_addon_release("[]").unwrap(), None);
    }
}
