//! Installing a release's zip into the game's AddOns folder.
//!
//! The zip holds addon folders at its top (Pathwright_Profile, Pathwright_Guide...). Each one
//! replaces the installed folder of the same name, as a whole, keeping the files a player's own
//! app writes there (as scripts/install-addon.sh does). The new folders are unpacked first next
//! to AddOns, then swapped in: an error leaves the installed addon as it was.

use anyhow::{Context, Result, bail};
use std::collections::BTreeSet;
use std::fs;
use std::io::{Cursor, Read};
use std::path::{Component, Path, PathBuf};

/// Files the desktop app (and this updater: Updater.lua, feedback.rs) writes into the addon's
/// folders: an update keeps the installed ones.
const KEEP: &[&str] = &["Config.lua", "Routes.lua", "Services.lua", "Sent.lua", "Updater.lua"];
/// Next to AddOns (same disk, so folders move in at once): the new folders, the old ones.
const STAGING: &str = ".pathwright-update";
const BACKUP: &str = ".pathwright-previous";

/// Install `zip` into `addons` (the game's Interface/AddOns folder). Returns the folders updated.
pub fn install(addons: &Path, zip: &[u8]) -> Result<Vec<String>> {
    if !addons.is_dir() {
        bail!("{} is not a folder", addons.display());
    }
    let interface = addons.parent().context("the AddOns folder has no parent")?;
    let mut archive = zip::ZipArchive::new(Cursor::new(zip)).context("the release's zip")?;

    // Where everything goes: addon folders only, nothing outside them.
    let mut folders = BTreeSet::new();
    for i in 0..archive.len() {
        let entry = archive.by_index(i)?;
        let raw = entry.name().map(std::borrow::Cow::into_owned).unwrap_or_default();
        let path = entry
            .enclosed_name()
            .with_context(|| format!("an unsafe path in the zip: {raw}"))?;
        let Some(Component::Normal(first)) = path.components().next() else {
            bail!("an unexpected path in the zip: {raw}");
        };
        let first = first.to_string_lossy().into_owned();
        // An addon folder's own entry ("Pathwright_Guide/"), or anything inside one.
        if !first.starts_with("Pathwright") || (path.components().count() < 2 && !entry.is_dir()) {
            bail!("the zip holds more than Pathwright's addon folders: {raw}");
        }
        folders.insert(first);
    }
    if folders.is_empty() {
        bail!("the zip is empty");
    }

    let staging = interface.join(STAGING);
    remove(&staging)?;
    fs::create_dir_all(&staging)?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let Some(path) = entry.enclosed_name() else { continue };
        let target = staging.join(path);
        if entry.is_dir() {
            fs::create_dir_all(&target)?;
            continue;
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut bytes = Vec::with_capacity(entry.size() as usize);
        entry.read_to_end(&mut bytes)?;
        fs::write(&target, bytes).with_context(|| format!("writing {}", target.display()))?;
    }
    for folder in &folders {
        if !staging.join(folder).join(format!("{folder}.toc")).is_file() {
            remove(&staging)?;
            bail!("{folder} has no {folder}.toc in the zip");
        }
        for name in KEEP {
            let installed = addons.join(folder).join(name);
            if installed.is_file() {
                fs::copy(&installed, staging.join(folder).join(name))?;
            }
        }
    }

    // The swap: each installed folder aside, the new one in; on an error, the old ones back.
    let backup = interface.join(BACKUP);
    remove(&backup)?;
    fs::create_dir_all(&backup)?;
    let mut moved: Vec<&String> = Vec::new();
    let mut placed: Vec<&String> = Vec::new();
    let swapped = (|| -> Result<()> {
        for folder in &folders {
            let installed = addons.join(folder);
            if installed.exists() {
                fs::rename(&installed, backup.join(folder)).with_context(|| format!("moving {folder} aside"))?;
                moved.push(folder);
            }
            fs::rename(staging.join(folder), &installed)
                .with_context(|| format!("putting the new {folder} in place"))?;
            placed.push(folder);
        }
        Ok(())
    })();
    if let Err(error) = swapped {
        for folder in placed {
            let _ = fs::remove_dir_all(addons.join(folder));
        }
        for folder in moved {
            let _ = fs::rename(backup.join(folder), addons.join(folder));
        }
        let _ = remove(&staging);
        return Err(error);
    }
    remove(&backup)?;
    remove(&staging)?;
    Ok(folders.into_iter().collect())
}

fn remove(dir: &Path) -> Result<()> {
    if dir.exists() {
        fs::remove_dir_all(dir).with_context(|| format!("removing {}", dir.display()))?;
    }
    Ok(())
}

/// The AddOns folder of a folder picked by hand: the game's folder, its `_forever_` folder,
/// Interface, or AddOns itself.
pub fn addons_of(picked: &Path) -> Option<PathBuf> {
    let candidates = [
        picked.to_path_buf(),
        picked.join("AddOns"),
        picked.join("Interface/AddOns"),
        picked.join("_forever_/Interface/AddOns"),
    ];
    candidates
        .into_iter()
        .find(|c| c.is_dir() && c.file_name().is_some_and(|n| n.eq_ignore_ascii_case("AddOns")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pathwright-updater-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("_forever_/Interface/AddOns")).unwrap();
        dir
    }

    fn zip_of(files: &[(&str, &str)]) -> Vec<u8> {
        let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
        for (path, text) in files {
            writer
                .start_file(*path, zip::write::SimpleFileOptions::default())
                .unwrap();
            writer.write_all(text.as_bytes()).unwrap();
        }
        writer.finish().unwrap().into_inner()
    }

    #[test]
    fn an_update_replaces_the_folders_and_keeps_the_players_files() {
        let root = temp("update");
        let addons = root.join("_forever_/Interface/AddOns");
        fs::create_dir_all(addons.join("Pathwright_Guide")).unwrap();
        fs::write(addons.join("Pathwright_Guide/Old.lua"), "old").unwrap();
        fs::write(addons.join("Pathwright_Guide/Config.lua"), "mine").unwrap();
        fs::create_dir_all(addons.join("OtherAddon")).unwrap();
        let zip = zip_of(&[
            ("Pathwright_Guide/Pathwright_Guide.toc", "## Title: Pathwright"),
            ("Pathwright_Guide/Config.lua", "-- empty"),
            ("Pathwright_Guide/Builtin/Guide.lua", "guide"),
            ("Pathwright_Profile/Pathwright_Profile.toc", "## Title: Profile"),
        ]);
        let folders = install(&addons, &zip).unwrap();
        assert_eq!(folders, ["Pathwright_Guide", "Pathwright_Profile"]);
        assert!(!addons.join("Pathwright_Guide/Old.lua").exists(), "the old files go");
        assert_eq!(
            fs::read_to_string(addons.join("Pathwright_Guide/Config.lua")).unwrap(),
            "mine"
        );
        assert_eq!(
            fs::read_to_string(addons.join("Pathwright_Guide/Builtin/Guide.lua")).unwrap(),
            "guide"
        );
        assert!(addons.join("Pathwright_Profile/Pathwright_Profile.toc").is_file());
        assert!(addons.join("OtherAddon").is_dir(), "other addons untouched");
        assert!(!root.join("_forever_/Interface").join(STAGING).exists());
        assert!(!root.join("_forever_/Interface").join(BACKUP).exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_zip_with_anything_else_is_refused_and_nothing_changes() {
        let root = temp("refused");
        let addons = root.join("_forever_/Interface/AddOns");
        fs::create_dir_all(addons.join("Pathwright_Guide")).unwrap();
        fs::write(addons.join("Pathwright_Guide/Old.lua"), "old").unwrap();
        for files in [
            vec![("../evil.lua", "x")],
            vec![
                ("Pathwright_Guide/Pathwright_Guide.toc", "t"),
                ("OtherAddon/OtherAddon.toc", "t"),
            ],
            vec![("Pathwright_Guide/NoToc.lua", "x")],
        ] {
            assert!(install(&addons, &zip_of(&files)).is_err(), "{files:?}");
            assert_eq!(
                fs::read_to_string(addons.join("Pathwright_Guide/Old.lua")).unwrap(),
                "old"
            );
        }
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_picked_folder_leads_to_addons() {
        let root = temp("picked");
        let addons = root.join("_forever_/Interface/AddOns");
        assert_eq!(addons_of(&root), Some(addons.clone()));
        assert_eq!(addons_of(&root.join("_forever_")), Some(addons.clone()));
        assert_eq!(addons_of(&addons), Some(addons));
        assert_eq!(addons_of(&root.join("missing")), None);
        let _ = fs::remove_dir_all(root);
    }
}

#[cfg(test)]
mod published {
    use super::*;

    /// The newest release on GitHub, downloaded and installed into a temporary AddOns folder.
    /// Needs the network: `cargo test -p pathwright-updater -- --ignored`.
    #[test]
    #[ignore = "needs the network"]
    fn the_published_release_installs() {
        let release = crate::github::latest().unwrap().expect("an addon release");
        let zip = crate::github::download(&release).unwrap();
        let root = std::env::temp_dir().join(format!("pathwright-updater-published-{}", std::process::id()));
        let addons = root.join("_forever_/Interface/AddOns");
        fs::create_dir_all(&addons).unwrap();
        let folders = install(&addons, &zip).unwrap();
        assert!(folders.iter().any(|f| f == "Pathwright_Guide"), "{folders:?}");
        for folder in &folders {
            assert!(addons.join(folder).join(format!("{folder}.toc")).is_file(), "{folder}");
        }
        println!("{}: {folders:?}", release.tag);
        let _ = fs::remove_dir_all(root);
    }
}
