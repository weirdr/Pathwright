//! Pathwright Updater: a system tray app (macOS and Windows) that keeps the Pathwright addon up
//! to date. Every 15 minutes (and on "Check for updates now") it looks at the addon's GitHub
//! releases (tags Pathwright-vX.Y.Z, .github/workflows/addon-release.yml); when one is newer than the one
//! it installed, it downloads its zip and installs it into WoW Forever's AddOns folder, quietly:
//! the game uses it at the next /reload or login. It finds the folder by itself (as the desktop
//! app does), or takes the one picked from its menu. On its first run it asks whether to start
//! at login (a choice in its menu after that). `--uninstall` (its Windows installer runs it when
//! the updater is removed) only takes it off the programs started at login.
#![cfg_attr(windows, windows_subsystem = "windows")]

mod autostart;
mod github;
mod install;
mod settings;
mod wow;

use settings::Settings;
use std::sync::mpsc;
use std::time::Duration;
use tao::event::{Event, StartCause};
use tao::event_loop::{ControlFlow, EventLoopBuilder};
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIconBuilder};

/// Between two looks at the releases (GitHub allows 60 an hour without an account).
const EVERY: Duration = Duration::from_mins(15);
/// The tray icon: the desktop app's.
const ICON_PNG: &[u8] = include_bytes!("../../../app/src-tauri/icons/32x32.png");

enum UserEvent {
    Status(String),
    Menu(MenuEvent),
}

/// Look for a new release and install it: the status line of the menu.
fn check() -> String {
    let mut settings = Settings::load();
    let Some(addons) = settings.addons.clone().filter(|p| p.is_dir()).or_else(wow::detect) else {
        return "WoW Forever not found: choose its folder".to_owned();
    };
    if settings.addons.as_ref() != Some(&addons) {
        settings.addons = Some(addons.clone());
        settings.save();
    }
    let release = match github::latest() {
        Ok(Some(release)) => release,
        Ok(None) => return "No addon release yet".to_owned(),
        Err(_) => return "GitHub unreachable: trying again later".to_owned(),
    };
    let installed = settings.installed.as_deref() == Some(release.tag.as_str());
    if installed && addons.join("Pathwright_Guide").is_dir() {
        return format!("Up to date: {}", release.tag);
    }
    let result = github::download(&release).and_then(|zip| install::install(&addons, &zip));
    match result {
        Ok(_) => {
            settings.installed = Some(release.tag.clone());
            settings.save();
            format!("Up to date: {}", release.tag)
        }
        Err(error) => {
            let mut text = format!("Update failed: {error:#}");
            text.truncate(90);
            text
        }
    }
}

fn icon() -> Option<Icon> {
    let mut decoder = png::Decoder::new(std::io::Cursor::new(ICON_PNG));
    decoder.set_transformations(png::Transformations::EXPAND);
    let mut reader = decoder.read_info().ok()?;
    let mut buffer = vec![0; reader.output_buffer_size()?];
    let frame = reader.next_frame(&mut buffer).ok()?;
    buffer.truncate(frame.buffer_size());
    let rgba = match frame.color_type {
        png::ColorType::Rgba => buffer,
        png::ColorType::Rgb => buffer.chunks(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect(),
        _ => return None,
    };
    Icon::from_rgba(rgba, frame.width, frame.height).ok()
}

fn main() {
    if std::env::args().any(|arg| arg == "--uninstall") {
        autostart::set(false);
        return;
    }
    // The first run asks whether to start at login, once its menu is there (below); the menu's
    // check box changes it after that.
    let mut first_run = !Settings::load().autostart_set;

    let mut event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    // A tray app only: no Dock icon on macOS.
    #[cfg(target_os = "macos")]
    {
        use tao::platform::macos::{ActivationPolicy, EventLoopExtMacOS};
        event_loop.set_activation_policy(ActivationPolicy::Accessory);
    }
    #[cfg(not(target_os = "macos"))]
    let _ = &mut event_loop;

    let proxy = event_loop.create_proxy();
    let menu_proxy = event_loop.create_proxy();
    MenuEvent::set_event_handler(Some(move |event| {
        let _ = menu_proxy.send_event(UserEvent::Menu(event));
    }));

    // The checks run on their own thread: now, every EVERY, and when asked (a message).
    let (ask, asked) = mpsc::channel::<()>();
    std::thread::spawn(move || {
        loop {
            let status = check();
            // Also on the standard error (a terminal shows it; nothing does otherwise).
            eprintln!("pathwright-updater: {status}");
            if proxy.send_event(UserEvent::Status(status)).is_err() {
                return;
            }
            match asked.recv_timeout(EVERY) {
                Ok(()) | Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
            }
        }
    });

    let status = MenuItem::new("Checking for updates…", false, None);
    let check_now = MenuItem::new("Check for updates now", true, None);
    let choose = MenuItem::new("Choose WoW folder…", true, None);
    let start_at_login = CheckMenuItem::new("Start at login", true, autostart::enabled(), None);
    let quit = MenuItem::new("Quit", true, None);
    let mut tray = None;

    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        match event {
            // The tray is made once the loop runs (macOS needs it so).
            Event::NewEvents(StartCause::Init) => {
                let menu = Menu::new();
                let _ = menu.append_items(&[
                    &MenuItem::new("Pathwright Updater", false, None),
                    &status,
                    &PredefinedMenuItem::separator(),
                    &check_now,
                    &choose,
                    &start_at_login,
                    &PredefinedMenuItem::separator(),
                    &quit,
                ]);
                let mut builder = TrayIconBuilder::new()
                    .with_menu(Box::new(menu))
                    .with_tooltip("Pathwright Updater");
                if let Some(icon) = icon() {
                    builder = builder.with_icon(icon);
                }
                tray = builder.build().ok();
                if first_run {
                    first_run = false;
                    let answer = rfd::MessageDialog::new()
                        .set_title("Pathwright Updater")
                        .set_description(
                            "Start Pathwright Updater when you log in, so the addon stays up to date?\n\n\
                             You can change this any time from its menu in the system tray.",
                        )
                        .set_buttons(rfd::MessageButtons::YesNo)
                        .show();
                    if answer == rfd::MessageDialogResult::Yes {
                        start_at_login.set_checked(autostart::set(true));
                    }
                    let mut settings = Settings::load();
                    settings.autostart_set = true;
                    settings.save();
                }
            }
            Event::UserEvent(UserEvent::Status(text)) => {
                status.set_text(&text);
                if let Some(tray) = &tray {
                    let _ = tray.set_tooltip(Some(format!("Pathwright Updater: {text}")));
                }
            }
            Event::UserEvent(UserEvent::Menu(event)) => {
                if event.id == check_now.id() {
                    status.set_text("Checking for updates…");
                    let _ = ask.send(());
                } else if event.id == choose.id() {
                    let picked = rfd::FileDialog::new()
                        .set_title("Choose World of Warcraft's folder (or its _forever_ or AddOns folder)")
                        .pick_folder();
                    if let Some(picked) = picked {
                        match install::addons_of(&picked) {
                            Some(addons) => {
                                let mut settings = Settings::load();
                                settings.addons = Some(addons);
                                // A new folder: the release goes in there too.
                                settings.installed = None;
                                settings.save();
                                status.set_text("Checking for updates…");
                                let _ = ask.send(());
                            }
                            None => status.set_text("No AddOns folder in the folder chosen"),
                        }
                    }
                } else if event.id == start_at_login.id() {
                    let on = start_at_login.is_checked();
                    if !autostart::set(on) {
                        start_at_login.set_checked(!on);
                    }
                } else if event.id == quit.id() {
                    tray = None;
                    *control_flow = ControlFlow::Exit;
                }
            }
            _ => {}
        }
    });
}
