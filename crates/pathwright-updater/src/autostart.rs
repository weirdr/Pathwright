//! Start at login: a LaunchAgent on macOS, the Run key on Windows.

#[cfg(target_os = "macos")]
use std::path::PathBuf;

#[cfg(target_os = "macos")]
const LABEL: &str = "com.pathwright.updater";
#[cfg(windows)]
const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
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
        reg(&["query", RUN_KEY, "/v", VALUE])
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
    #[cfg(windows)]
    {
        if on {
            let value = format!("\"{}\"", exe.display());
            reg(&["add", RUN_KEY, "/v", VALUE, "/t", "REG_SZ", "/d", &value, "/f"])
        } else {
            reg(&["delete", RUN_KEY, "/v", VALUE, "/f"]) || !enabled()
        }
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = (on, exe);
        false
    }
}

/// Run reg.exe without a console window; whether it succeeded.
#[cfg(windows)]
fn reg(args: &[&str]) -> bool {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    std::process::Command::new("reg")
        .args(args)
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}
