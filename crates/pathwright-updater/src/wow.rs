//! Where WoW Forever's AddOns folder is on this computer (as the desktop app's game.rs looks).

use std::path::{Path, PathBuf};

/// Where World of Warcraft usually is, under a drive.
const USUAL_PLACES: &[&str] = &[
    "Program Files (x86)/World of Warcraft",
    "Program Files/World of Warcraft",
    "World of Warcraft",
    "Games/World of Warcraft",
    "Blizzard/World of Warcraft",
    "Battle.net/World of Warcraft",
    "Program Files (x86)/Battle.net/World of Warcraft",
];

/// The folders where Battle.net installed its games, written as plain text paths in its
/// product.db ("C:/Program Files (x86)/World of Warcraft").
fn battle_net_paths(product_db: &Path) -> Vec<PathBuf> {
    let Ok(bytes) = std::fs::read(product_db) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for run in bytes.split(|b| !(0x20..0x7f).contains(b)) {
        let Ok(text) = std::str::from_utf8(run) else { continue };
        if !text.contains("World of Warcraft") {
            continue;
        }
        let start = text
            .as_bytes()
            .windows(3)
            .position(|w| w[0].is_ascii_alphabetic() && w[1] == b':' && (w[2] == b'/' || w[2] == b'\\'));
        if let Some(start) = start {
            out.push(PathBuf::from(text[start..].replace('/', std::path::MAIN_SEPARATOR_STR)));
        }
    }
    out
}

/// WoW Forever's Interface/AddOns folder, when found (the game's folder holding `_forever_`).
pub fn detect() -> Option<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    if cfg!(windows) {
        let data = std::env::var_os("ProgramData").map_or_else(|| PathBuf::from(r"C:\ProgramData"), PathBuf::from);
        roots.extend(battle_net_paths(&data.join(r"Battle.net\Agent\product.db")));
        for drive in b'C'..=b'Z' {
            let root = PathBuf::from(format!("{}:\\", drive as char));
            if root.is_dir() {
                roots.extend(USUAL_PLACES.iter().map(|p| root.join(p)));
            }
        }
    } else if cfg!(target_os = "macos") {
        roots.push(PathBuf::from("/Applications/World of Warcraft"));
        if let Some(home) = dirs::home_dir() {
            roots.push(home.join("Applications/World of Warcraft"));
        }
    }
    roots
        .into_iter()
        .map(|root| root.join("_forever_").join("Interface").join("AddOns"))
        .find(|addons| addons.is_dir())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn battle_net_tells_where_it_installed_the_game() {
        let dir = std::env::temp_dir().join(format!("pathwright-updater-bnet-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("product.db");
        std::fs::write(&db, b"\x0a\x03wow\x1a\x1aD:/Games/World of Warcraft\x12\x04enUS").unwrap();
        let paths = battle_net_paths(&db);
        assert_eq!(paths.len(), 1);
        assert!(paths[0].to_string_lossy().starts_with("D:"));
        assert!(paths[0].to_string_lossy().ends_with("World of Warcraft"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
