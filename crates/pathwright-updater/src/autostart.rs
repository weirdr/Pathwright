//! Start at login: a LaunchAgent on macOS, the Run key on Windows.

#[cfg(target_os = "macos")]
use std::path::PathBuf;

#[cfg(target_os = "macos")]
const LABEL: &str = "com.pathwright.updater";
/// Under HKEY_CURRENT_USER: the programs Windows starts at login, by name.
#[cfg(windows)]
const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
#[cfg(windows)]
const VALUE: &str = "Pathwright Updater";

#[cfg(target_os = "macos")]
fn agent() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join("Library/LaunchAgents").join(format!("{LABEL}.plist")))
}

/// Whether the updater starts at login.
pub fn enabled() -> bool {
    #[cfg(target_os = "macos")]
    {
        agent().is_some_and(|p| p.is_file())
    }
    #[cfg(windows)]
    {
        windows_registry::CURRENT_USER
            .open(RUN_KEY)
            .and_then(|key| key.get_string(VALUE))
            .is_ok()
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        false
    }
}

/// Start (or no longer start) at login. Returns whether it worked.
pub fn set(on: bool) -> bool {
    let Ok(exe) = std::env::current_exe() else { return false };
    #[cfg(target_os = "macos")]
    {
        let Some(path) = agent() else { return false };
        if !on {
            return std::fs::remove_file(&path).is_ok() || !path.exists();
        }
        let plist = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>{LABEL}</string>
    <key>ProgramArguments</key><array><string>{}</string></array>
    <key>RunAtLoad</key><true/>
</dict>
</plist>
"#,
            exe.display()
        );
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        std::fs::write(path, plist).is_ok()
    }
    // Written through the registry's own calls: no other program is started for it.
    #[cfg(windows)]
    {
        let Ok(key) = windows_registry::CURRENT_USER.create(RUN_KEY) else {
            return false;
        };
        if on {
            key.set_string(VALUE, format!("\"{}\"", exe.display())).is_ok()
        } else {
            key.remove_value(VALUE).is_ok() || !enabled()
        }
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = (on, exe);
        false
    }
}
