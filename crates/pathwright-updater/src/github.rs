//! The addon's releases on GitHub: the newest one, and its zip.

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use std::io::Read;

/// The repository the addon is released from.
pub const REPO: &str = "weirdr/Pathwright";
/// The addon's releases are tagged `Pathwright-vX.Y.Z` (.github/workflows/addon-release.yml);
/// those before were `addon-YYYY.MM.DD-HHMMSS`. The updater's own (`updater`) are left alone.
const SEMVER_PREFIX: &str = "Pathwright-v";
const LEGACY_PREFIX: &str = "addon-";
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

/// The version of a `Pathwright-vX.Y.Z` tag, None for another tag (the date-stamped ones before).
fn semver(tag: &str) -> Option<(u64, u64, u64)> {
    let mut parts = tag.strip_prefix(SEMVER_PREFIX)?.split('.');
    let version = (
        parts.next()?.parse().ok()?,
        parts.next()?.parse().ok()?,
        parts.next()?.parse().ok()?,
    );
    parts.next().is_none().then_some(version)
}

/// The newest addon release with its zip in a releases listing: the highest `Pathwright-vX.Y.Z`, else
/// (none yet) the first date-stamped one (GitHub lists them newest first).
pub fn newest_addon_release(json: &str) -> Result<Option<Release>> {
    let releases: Vec<ApiRelease> = serde_json::from_str(json).context("the releases listing")?;
    let usable: Vec<Release> = releases
        .into_iter()
        .filter(|r| !r.draft && (r.tag_name.starts_with(SEMVER_PREFIX) || r.tag_name.starts_with(LEGACY_PREFIX)))
        .filter_map(|r| {
            let asset = r.assets.into_iter().find(|a| a.name == ASSET)?;
            Some(Release {
                tag: r.tag_name,
                zip_url: asset.browser_download_url,
            })
        })
        .collect();
    let highest = usable
        .iter()
        .filter_map(|r| semver(&r.tag).map(|v| (v, r)))
        .max_by_key(|(v, _)| *v)
        .map(|(_, r)| r.clone());
    Ok(highest.or_else(|| usable.into_iter().next()))
}

fn get_json(url: &str) -> Result<String> {
    let mut response = agent()
        .get(url)
        .header("Accept", "application/vnd.github+json")
        .call()
        .context("GitHub's releases")?;
    response.body_mut().read_to_string().context("GitHub's answer")
}

/// Ask GitHub for the newest addon release: the release marked Latest (each addon release is,
/// the updater's never), else the highest in the listing. The listing alone is not enough:
/// GitHub does not order it by date, and puts the `Pathwright-v…` tags after the old `addon-…`
/// ones.
pub fn latest() -> Result<Option<Release>> {
    let marked = get_json(&format!("https://api.github.com/repos/{REPO}/releases/latest"));
    if let Ok(json) = marked
        && let Ok(Some(release)) = newest_addon_release(&format!("[{json}]"))
        && semver(&release.tag).is_some()
    {
        return Ok(Some(release));
    }
    let json = get_json(&format!("https://api.github.com/repos/{REPO}/releases?per_page=100"))?;
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

    #[test]
    fn the_highest_semantic_version_wins_over_the_listing_order_and_the_dates() {
        let json = r#"[
            {"tag_name": "Pathwright-v1.0.9", "draft": false, "assets": [{"name": "Pathwright-addon.zip", "browser_download_url": "u9"}]},
            {"tag_name": "Pathwright-v1.0.10", "draft": false, "assets": [{"name": "Pathwright-addon.zip", "browser_download_url": "u10"}]},
            {"tag_name": "Pathwright-v2.0.0", "draft": true, "assets": [{"name": "Pathwright-addon.zip", "browser_download_url": "draft"}]},
            {"tag_name": "addon-2026.11.23-114723", "draft": false, "assets": [{"name": "Pathwright-addon.zip", "browser_download_url": "old"}]}
        ]"#;
        let release = newest_addon_release(json).unwrap().unwrap();
        assert_eq!(release.tag, "Pathwright-v1.0.10");
        assert_eq!(release.zip_url, "u10");
        assert_eq!(semver("Pathwright-v1.2.3"), Some((1, 2, 3)));
        assert_eq!(semver("Pathwright-v1.2"), None);
        assert_eq!(semver("addon-2026.11.23-0309"), None);
    }
}
