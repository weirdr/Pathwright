//! What the updater remembers: the AddOns folder, the release installed.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Settings {
    /// The game's Interface/AddOns folder (found, or picked by hand).
    #[serde(default)]
    pub addons: Option<PathBuf>,
    /// The tag of the addon release installed last (Pathwright-vX.Y.Z).
    #[serde(default)]
    pub installed: Option<String>,
    /// Start at login was set on the first run (then left to the player's choice).
    #[serde(default)]
    pub autostart_set: bool,
}

fn path() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join("Pathwright Updater").join("settings.json"))
}

impl Settings {
    pub fn load() -> Self {
        path()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) {
        let Some(path) = path() else { return };
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(text) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(path, text);
        }
    }
}
