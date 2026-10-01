// The desktop Mochi (macOS DesktopMochi + PetMenu, PRs #5 and #6): Mochi out
// of the island, as a companion on the desktop. Opt-in: Settings › Extras, or
// drag Mochi out of the island and drop it where there's no window.
//
// Three small windows, transparent, always on top, never taking focus:
// • `pet`, 92 px: the engine, eyes on the cursor; drag it anywhere (the spot is
//   remembered per screen); a click opens its menu, a right click too, a double
//   click sends it home; it follows you to the screen the cursor settles on —
//   a hop in an arc, or a teleport in sparkles when it's far;
// • `pet-bubble`: the current toast, beside it on the side with room (clicks
//   go through it);
// • `pet-menu`: a dark card with shortcuts and the worktrees, closed by a
//   choice, a click elsewhere, or Escape.
//
// The island stays the one place that knows what Mochi is up to: it sends the
// pet its look (pet-sync), its toasts, and runs what the menu picks.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, Monitor, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

pub const PET: &str = "pet";
pub const BUBBLE: &str = "pet-bubble";
pub const MENU: &str = "pet-menu";
const SIZE: f64 = 92.0;
const BUBBLE_W: f64 = 260.0;
const BUBBLE_H: f64 = 44.0;
const MENU_W: f64 = 300.0;

static VISIBLE: AtomicBool = AtomicBool::new(false);
static MENU_OPEN: AtomicBool = AtomicBool::new(false);
static FLYING: AtomicBool = AtomicBool::new(false);
static MOVED_AT: Mutex<Option<Instant>> = Mutex::new(None);

fn window(app: &AppHandle, label: &str) -> Option<WebviewWindow> {
    app.get_webview_window(label)
}

fn build(app: &AppHandle, label: &str, page: &str, w: f64, h: f64) -> Option<WebviewWindow> {
    if let Some(win) = window(app, label) {
        return Some(win);
    }
    let win = WebviewWindowBuilder::new(app, label, WebviewUrl::App(page.into()))
        .additional_browser_args(crate::BROWSER_ARGS)
        .title("Mochi")
        .inner_size(w, h)
        .resizable(false)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .maximizable(false)
        .minimizable(false)
        .build()
        .map_err(|e| crate::log::line(format!("{label} window failed: {e}")))
        .ok()?;
    crate::island::make_non_activating(&win);
    Some(win)
}

fn settings(app: &AppHandle) -> Option<crate::settings::Settings> {
    app.try_state::<crate::Shared>().map(|s| s.settings.lock().unwrap().clone())
}

/// Saves a change Rust made itself, and tells both windows.
fn update_settings(app: &AppHandle, change: impl FnOnce(&mut crate::settings::Settings)) {
    let Some(shared) = app.try_state::<crate::Shared>() else { return };
    let s = {
        let mut current = shared.settings.lock().unwrap();
        change(&mut current);
        current.clone()
    };
    if let Err(e) = crate::settings::save(&s) {
        crate::log::line(format!("pet: could not save settings: {e}"));
    }
    let _ = app.emit("settings-changed", s);
}

fn monitor_key(m: &Monitor) -> String {
    m.name().cloned().unwrap_or_else(|| format!("{}x{}", m.position().x, m.position().y))
}

fn monitor_at(app: &AppHandle, x: f64, y: f64) -> Option<Monitor> {
    app.available_monitors().ok()?.into_iter().find(|m| {
        let (p, s) = (m.position(), m.size());
        x >= p.x as f64 && x < (p.x + s.width as i32) as f64 && y >= p.y as f64 && y < (p.y + s.height as i32) as f64
    })
}

fn cursor() -> Option<(f64, f64)> {
    let mut p = windows::Win32::Foundation::POINT::default();
    unsafe { windows::Win32::UI::WindowsAndMessaging::GetCursorPos(&mut p) }.ok()?;
    Some((p.x as f64, p.y as f64))
}

fn pet_size(m: &Monitor) -> i32 {
    (SIZE * m.scale_factor()).round() as i32
}

/// The pet's remembered spot on a screen (relative to its work area), else bottom right.
fn saved_origin(app: &AppHandle, m: &Monitor) -> PhysicalPosition<i32> {
    let rel = settings(app).and_then(|s| s.pet_positions.get(&monitor_key(m)).copied()).unwrap_or([0.92, 0.92]);
    let wa = m.work_area();
    let s = pet_size(m);
    PhysicalPosition::new(
        wa.position.x + (rel[0].clamp(0.0, 1.0) * (wa.size.width as i32 - s).max(1) as f64) as i32,
        wa.position.y + (rel[1].clamp(0.0, 1.0) * (wa.size.height as i32 - s).max(1) as f64) as i32,
    )
}

fn pet_rect(app: &AppHandle) -> Option<(i32, i32, i32, i32)> {
    let win = window(app, PET)?;
    let (p, s) = (win.outer_position().ok()?, win.outer_size().ok()?);
    Some((p.x, p.y, s.width as i32, s.height as i32))
}

fn save_position(app: &AppHandle) {
    let Some((x, y, w, h)) = pet_rect(app) else { return };
    let Some(m) = monitor_at(app, (x + w / 2) as f64, (y + h / 2) as f64) else { return };
    let wa = m.work_area();
    let rel = [
        ((x - wa.position.x) as f64 / (wa.size.width as i32 - w).max(1) as f64).clamp(0.0, 1.0),
        ((y - wa.position.y) as f64 / (wa.size.height as i32 - h).max(1) as f64).clamp(0.0, 1.0),
    ];
    let key = monitor_key(&m);
    update_settings(app, |s| {
        s.pet_positions.insert(key, rel);
    });
}

#[derive(Serialize, Clone)]
struct Side {
    left: bool,
}

/// The bubble goes on whichever side of the pet has room.
fn place_bubble(app: &AppHandle) {
    let (Some(bubble), Some((x, y, w, h))) = (window(app, BUBBLE), pet_rect(app)) else { return };
    let Some(m) = monitor_at(app, (x + w / 2) as f64, (y + h / 2) as f64) else { return };
    let scale = m.scale_factor();
    let (bw, bh) = ((BUBBLE_W * scale) as i32, (BUBBLE_H * scale) as i32);
    let wa = m.work_area();
    let left = x + w + bw > wa.position.x + wa.size.width as i32;
    let bx = if left { x - bw + (6.0 * scale) as i32 } else { x + w - (6.0 * scale) as i32 };
    let by = y + h / 2 - bh / 2 - (10.0 * scale) as i32;
    let _ = bubble.set_size(PhysicalSize::new(bw as u32, bh as u32));
    let _ = bubble.set_position(PhysicalPosition::new(bx, by));
    let _ = bubble.emit("pet-side", Side { left });
}

fn move_pet(app: &AppHandle, to: PhysicalPosition<i32>) {
    if let Some(win) = window(app, PET) {
        let _ = win.set_position(to);
    }
    place_bubble(app);
}

/// Shows it (at a point, or at its spot on the cursor's screen).
fn show(app: &AppHandle, at: Option<(f64, f64)>) {
    let (Some(pet), Some(bubble)) = (build(app, PET, "pet.html", SIZE, SIZE), build(app, BUBBLE, "pet-bubble.html", BUBBLE_W, BUBBLE_H)) else { return };
    let _ = bubble.set_ignore_cursor_events(true);
    let (cx, cy) = at.or_else(cursor).unwrap_or((0.0, 0.0));
    let Some(m) = monitor_at(app, cx, cy).or_else(|| app.primary_monitor().ok().flatten()) else { return };
    let s = pet_size(&m);
    let _ = pet.set_size(PhysicalSize::new(s as u32, s as u32));
    let origin = match at {
        Some((x, y)) => PhysicalPosition::new(x as i32 - s / 2, y as i32 - s / 2),
        None => saved_origin(app, &m),
    };
    move_pet(app, origin);
    let _ = pet.show();
    let _ = bubble.show();
    let _ = pet.set_always_on_top(true);
    let _ = bubble.set_always_on_top(true);
    VISIBLE.store(true, Ordering::SeqCst);
    if at.is_some() {
        save_position(app);
    }
}

fn hide(app: &AppHandle) {
    close_menu(app);
    VISIBLE.store(false, Ordering::SeqCst);
    for label in [PET, BUBBLE] {
        if let Some(w) = window(app, label) {
            let _ = w.hide();
        }
    }
}

/// At launch, and whenever the setting changes.
pub fn apply(app: &AppHandle) {
    let on = settings(app).is_some_and(|s| s.desktop_mochi);
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || if on { show(&app2, None) } else { hide(&app2) });
}

/// Mochi dropped out of the island: out it comes, where it was dropped — if
/// there's no window there (a window gets attached instead).
pub fn drop_here(app: &AppHandle) -> bool {
    if crate::capture::window_under_cursor() {
        return false;
    }
    let Some(at) = cursor() else { return false };
    update_settings(app, |s| s.desktop_mochi = true);
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        show(&app2, Some(at));
        let _ = app2.emit_to(PET, "pet-hop", ());
    });
    true
}

/// Double click (or the menu's "Back to the notch"): home again.
pub fn dock(app: &AppHandle) {
    update_settings(app, |s| s.desktop_mochi = false);
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || hide(&app2));
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "pet-docked", ());
}

/// After the pet was dragged: the bubble follows now, the spot is saved once it rests.
pub fn moved(app: &AppHandle) {
    if FLYING.load(Ordering::SeqCst) {
        return;
    }
    place_bubble(app);
    *MOVED_AT.lock().unwrap() = Some(Instant::now());
}

/// Starts a native drag of the pet window (from its mousedown).
pub fn drag(app: &AppHandle) {
    close_menu(app);
    if let Some(w) = window(app, PET) {
        let _ = w.start_dragging();
    }
}

// ── The menu ──────────────────────────────────────────────────────────────────

pub fn close_menu(app: &AppHandle) {
    if MENU_OPEN.swap(false, Ordering::SeqCst) {
        if let Some(w) = window(app, MENU) {
            let _ = w.hide();
        }
    }
}

/// Beside the pet, on the side with room, clamped to the work area.
fn place_menu(app: &AppHandle, height: f64) {
    let (Some(menu), Some((x, y, w, h))) = (window(app, MENU), pet_rect(app)) else { return };
    let Some(m) = monitor_at(app, (x + w / 2) as f64, (y + h / 2) as f64) else { return };
    let scale = m.scale_factor();
    let wa = m.work_area();
    let mh = ((height * scale) as i32).min(wa.size.height as i32 - (40.0 * scale) as i32).max(80);
    let mw = (MENU_W * scale) as i32;
    let right = x + w + mw + (8.0 * scale) as i32 <= wa.position.x + wa.size.width as i32;
    let mx = if right { x + w + (6.0 * scale) as i32 } else { x - mw - (6.0 * scale) as i32 };
    let top = wa.position.y + (8.0 * scale) as i32;
    let bottom = wa.position.y + wa.size.height as i32 - mh - (8.0 * scale) as i32;
    let my = (y + h / 2 - mh + (40.0 * scale) as i32).clamp(top, bottom.max(top));
    let _ = menu.set_size(PhysicalSize::new(mw as u32, mh as u32));
    let _ = menu.set_position(PhysicalPosition::new(mx, my));
}

pub fn toggle_menu(app: &AppHandle) {
    if MENU_OPEN.load(Ordering::SeqCst) {
        return close_menu(app);
    }
    let Some(menu) = build(app, MENU, "pet-menu.html", MENU_W, 360.0) else { return };
    place_menu(app, 360.0);
    let _ = menu.show();
    let _ = menu.set_always_on_top(true);
    MENU_OPEN.store(true, Ordering::SeqCst);
    // The island fills it in (the focused pill, the toast, the worktrees).
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "pet-menu-open", ());
    let _ = menu.emit("pet-menu-shown", ());
    crate::worktrees::watch(app, true);
}

/// The menu measured itself.
pub fn menu_size(app: &AppHandle, height: f64) {
    if MENU_OPEN.load(Ordering::SeqCst) {
        place_menu(app, height.clamp(80.0, 2000.0));
    }
}

/// A choice in the menu: it closes, the island comes to the pet's screen, then
/// does what was picked.
pub fn choose(app: &AppHandle, choice: serde_json::Value) {
    close_menu(app);
    crate::worktrees::watch(app, false);
    if choice.get("kind").and_then(|k| k.as_str()) == Some("settings") {
        crate::show_settings_window(app);
        return;
    }
    if let Some((x, y, w, h)) = pet_rect(app) {
        let app2 = app.clone();
        let _ = app.run_on_main_thread(move || {
            crate::island::place_on_screen_at(&app2, (x + w / 2) as f64, (y + h / 2) as f64);
        });
    }
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "pet-action", choice);
}

// ── Following, eyes, outside clicks ───────────────────────────────────────────

#[derive(Serialize, Clone, PartialEq)]
struct Look {
    x: f64,
    y: f64,
}

/// Off to another spot: a hop in an arc (stepped at 60 fps), or a teleport when it's far.
fn travel(app: &AppHandle, to: PhysicalPosition<i32>) {
    let Some((x, y, _, _)) = pet_rect(app) else { return };
    let (fx, fy) = (x as f64, y as f64);
    let (tx, ty) = (to.x as f64, to.y as f64);
    let distance = ((tx - fx).powi(2) + (ty - fy).powi(2)).sqrt();
    FLYING.store(true, Ordering::SeqCst);
    if distance > 1400.0 {
        let _ = app.emit_to(PET, "pet-teleport", false);
        std::thread::sleep(Duration::from_millis(220));
        move_pet(app, to);
        let _ = app.emit_to(PET, "pet-teleport", true);
    } else {
        let duration = 0.45 + (distance / 3000.0).min(0.4);
        let lift = (40.0 + distance * 0.12).min(150.0);
        let _ = app.emit_to(PET, "pet-hop", ());
        let start = Instant::now();
        loop {
            let k = (start.elapsed().as_secs_f64() / duration).min(1.0);
            let e = if k < 0.5 { 2.0 * k * k } else { 1.0 - (-2.0 * k + 2.0).powi(2) / 2.0 };
            let arc = lift * 4.0 * k * (1.0 - k);
            move_pet(app, PhysicalPosition::new((fx + (tx - fx) * e) as i32, (fy + (ty - fy) * e - arc) as i32));
            if k >= 1.0 {
                break;
            }
            std::thread::sleep(Duration::from_millis(16));
        }
        let _ = app.emit_to(PET, "pet-hop", ());
    }
    FLYING.store(false, Ordering::SeqCst);
}

fn button_down(vk: windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY) -> bool {
    unsafe { (windows::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState(vk.0 as i32) as u16 & 0x8000) != 0 }
}

fn inside(r: Option<(i32, i32, i32, i32)>, x: f64, y: f64) -> bool {
    r.is_some_and(|(rx, ry, rw, rh)| x >= rx as f64 && x < (rx + rw) as f64 && y >= ry as f64 && y < (ry + rh) as f64)
}

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        use windows::Win32::UI::Input::KeyboardAndMouse::{VK_ESCAPE, VK_LBUTTON, VK_RBUTTON};
        let mut last_look: Option<Look> = None;
        let mut other: Option<(String, Instant)> = None;
        let mut was_down = false;
        let mut ticks = 0u32;
        loop {
            if !VISIBLE.load(Ordering::SeqCst) {
                last_look = None;
                std::thread::sleep(Duration::from_millis(400));
                continue;
            }
            std::thread::sleep(Duration::from_millis(33));
            ticks = ticks.wrapping_add(1);
            let (Some((cx, cy)), Some(rect)) = (cursor(), pet_rect(&app)) else { continue };
            let (x, y, w, h) = rect;
            let scale = monitor_at(&app, (x + w / 2) as f64, (y + h / 2) as f64).map_or(1.0, |m| m.scale_factor());
            // Its eyes on the cursor (the engine wants -1…1).
            let look = Look {
                x: ((cx - (x + w / 2) as f64) / scale / 320.0).clamp(-1.0, 1.0),
                y: ((cy - (y + h / 2) as f64) / scale / 260.0).clamp(-1.0, 1.0),
            };
            if last_look.as_ref() != Some(&look) {
                let _ = app.emit_to(PET, "pet-look", look.clone());
                last_look = Some(look);
            }
            // A drag that ended: save the spot once it rests.
            let rested = MOVED_AT.lock().unwrap().is_some_and(|t| t.elapsed() > Duration::from_millis(400));
            if rested {
                *MOVED_AT.lock().unwrap() = None;
                save_position(&app);
            }
            // The menu closes on a click elsewhere, or Escape.
            let down = button_down(VK_LBUTTON) || button_down(VK_RBUTTON);
            if MENU_OPEN.load(Ordering::SeqCst) {
                let menu = window(&app, MENU).and_then(|m| Some((m.outer_position().ok()?, m.outer_size().ok()?))).map(|(p, s)| (p.x, p.y, s.width as i32, s.height as i32));
                if (down && !was_down && !inside(menu, cx, cy) && !inside(Some(rect), cx, cy)) || button_down(VK_ESCAPE) {
                    close_menu(&app);
                    crate::worktrees::watch(&app, false);
                }
            }
            was_down = down;
            // It follows you: the cursor settled 1.2 s on another screen.
            if ticks % 12 != 0 || MENU_OPEN.load(Ordering::SeqCst) || down || !settings(&app).is_some_and(|s| s.pet_follow) {
                continue;
            }
            let here = monitor_at(&app, (x + w / 2) as f64, (y + h / 2) as f64).map(|m| monitor_key(&m));
            let Some(there) = monitor_at(&app, cx, cy) else { continue };
            let key = monitor_key(&there);
            if here.as_deref() == Some(key.as_str()) {
                other = None;
                continue;
            }
            match &other {
                Some((k, since)) if *k == key && since.elapsed() >= Duration::from_millis(1200) => {
                    other = None;
                    let to = saved_origin(&app, &there);
                    travel(&app, to);
                }
                Some((k, _)) if *k == key => {}
                _ => other = Some((key, Instant::now())),
            }
        }
    });
}
