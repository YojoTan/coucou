// The desktop Mochi (macOS DesktopMochi, PetMenu, PetBrain, PetHUD — PRs #5–#7):
// Mochi out of the island, as a companion on the desktop. Opt-in: Settings ›
// Extras, or drag Mochi out of the island and drop it where there's no window.
//
// Small windows, transparent, always on top, never taking focus:
// • `pet`, 92 px: the engine, eyes on the cursor. Drag it anywhere (the spot is
//   remembered per screen), throw it (it bounces), leave it at a side edge (it
//   peeks), wiggle the cursor over it (hearts), drop a file on it (it gulps
//   it). A click opens its menu, a right click too, a double click sends it
//   home. It follows you to the screen the cursor settles on; shake the mouse
//   and it comes over; opt-in, it walks on top of your windows;
// • `pet-bubble`: the current toast, or what Mochi says (an answer, "Ouch!");
// • `pet-menu`: shortcuts, "Ask Mochi…", the worktrees, "Hide 15 min";
// • `pet-approval`: a permission, with the island's own rules (pet/approval.ts);
// • `pet-squad`: a tiny Mochi per live session and busy Orca worktree;
// • `pet-visitor`: a paired LAN Mochi walking in to hand something over.
//
// It steps out of sight while you present or share on its screen.
// The island stays the one place that knows what Mochi is up to: it sends the
// pet its look, its toasts and cards, and runs what the pet's windows pick.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, Monitor, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use crate::pet_brain::{self, Body, Side};

pub const PET: &str = "pet";
pub const BUBBLE: &str = "pet-bubble";
pub const MENU: &str = "pet-menu";
pub const APPROVAL: &str = "pet-approval";
pub const SQUAD: &str = "pet-squad";
pub const VISITOR: &str = "pet-visitor";
const SIZE: f64 = 92.0;
const BUBBLE_W: f64 = 260.0;
const BUBBLE_H: f64 = 110.0;
const MENU_W: f64 = 300.0;
const CARD_W: f64 = 300.0;
const CARD_H: f64 = 136.0;
const SQUAD_H: f64 = 30.0;
const VISITOR_S: f64 = 64.0;

static VISIBLE: AtomicBool = AtomicBool::new(false);
static OUT_OF_SIGHT: AtomicBool = AtomicBool::new(false);
static MENU_OPEN: AtomicBool = AtomicBool::new(false);
static FLYING: AtomicBool = AtomicBool::new(false);
static DRAGGING: AtomicBool = AtomicBool::new(false);
static APPROVAL_ON: AtomicBool = AtomicBool::new(false);
static SQUAD_N: AtomicUsize = AtomicUsize::new(0);
static MOTION: AtomicU64 = AtomicU64::new(0);
static MOVED_AT: Mutex<Option<Instant>> = Mutex::new(None);
static SAMPLES: Mutex<VecDeque<(Instant, i32, i32)>> = Mutex::new(VecDeque::new());

/// What the pet is up to on its own.
struct Brain {
    peek: Option<Side>,
    pop_until: Option<Instant>,
    /// The window it sits on, and where along its top edge.
    perch: Option<(isize, i32)>,
    next_perch: Instant,
    next_stroll: Instant,
    hidden_until: Option<Instant>,
    shakes: VecDeque<(Instant, f64)>,
    last_summon: Option<Instant>,
    rng: pet_brain::Rng,
}

fn brain() -> MutexGuard<'static, Brain> {
    static B: OnceLock<Mutex<Brain>> = OnceLock::new();
    B.get_or_init(|| {
        Mutex::new(Brain {
            peek: None,
            pop_until: None,
            perch: None,
            next_perch: Instant::now() + Duration::from_secs(10),
            next_stroll: Instant::now(),
            hidden_until: None,
            shakes: VecDeque::new(),
            last_summon: None,
            rng: pet_brain::Rng::new(),
        })
    })
    .lock()
    .unwrap_or_else(|e| e.into_inner())
}

fn window(app: &AppHandle, label: &str) -> Option<WebviewWindow> {
    app.get_webview_window(label)
}

fn build(app: &AppHandle, label: &str, page: &str, w: f64, h: f64, clicks: bool) -> Option<WebviewWindow> {
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
    if !clicks {
        let _ = win.set_ignore_cursor_events(true);
    }
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
    let all = app.available_monitors().ok()?;
    let inside = |m: &Monitor| {
        let (p, s) = (m.position(), m.size());
        x >= p.x as f64 && x < (p.x + s.width as i32) as f64 && y >= p.y as f64 && y < (p.y + s.height as i32) as f64
    };
    // Peeking, its centre may sit just off the screen: the nearest one, then.
    all.iter().find(|m| inside(m)).cloned().or_else(|| {
        all.into_iter().min_by_key(|m| {
            let (p, s) = (m.position(), m.size());
            let (cx, cy) = (p.x as f64 + s.width as f64 / 2.0, p.y as f64 + s.height as f64 / 2.0);
            ((cx - x).powi(2) + (cy - y).powi(2)) as i64
        })
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

fn work_rect(m: &Monitor) -> pet_brain::Rect {
    let wa = m.work_area();
    (wa.position.x, wa.position.y, wa.position.x + wa.size.width as i32, wa.position.y + wa.size.height as i32)
}

/// The pet's remembered spot on a screen (relative to its work area), else bottom right.
fn saved_origin(app: &AppHandle, m: &Monitor) -> PhysicalPosition<i32> {
    let rel = settings(app).and_then(|s| s.pet_positions.get(&monitor_key(m)).copied()).unwrap_or([0.92, 0.92]);
    let (l, t, r, b) = work_rect(m);
    let s = pet_size(m);
    PhysicalPosition::new(
        l + (rel[0].clamp(0.0, 1.0) * (r - l - s).max(1) as f64) as i32,
        t + (rel[1].clamp(0.0, 1.0) * (b - t - s).max(1) as f64) as i32,
    )
}

fn pet_rect(app: &AppHandle) -> Option<(i32, i32, i32, i32)> {
    let win = window(app, PET)?;
    let (p, s) = (win.outer_position().ok()?, win.outer_size().ok()?);
    Some((p.x, p.y, s.width as i32, s.height as i32))
}

/// The pet's screen, its scale, its work area.
fn pet_monitor(app: &AppHandle) -> Option<(Monitor, (i32, i32, i32, i32))> {
    let r = pet_rect(app)?;
    Some((monitor_at(app, (r.0 + r.2 / 2) as f64, (r.1 + r.3 / 2) as f64)?, r))
}

fn save_position(app: &AppHandle) {
    let Some((m, (x, y, w, h))) = pet_monitor(app) else { return };
    let (l, t, r, b) = work_rect(&m);
    let rel = [
        ((x - l) as f64 / (r - l - w).max(1) as f64).clamp(0.0, 1.0),
        ((y - t) as f64 / (b - t - h).max(1) as f64).clamp(0.0, 1.0),
    ];
    let key = monitor_key(&m);
    update_settings(app, |s| {
        s.pet_positions.insert(key, rel);
    });
}

#[derive(Serialize, Clone)]
struct BubbleSide {
    left: bool,
}

/// What Mochi says in its bubble (an answer, "Ouch!"); `translate` for Rust's own words.
#[derive(Serialize, Clone)]
struct Say {
    text: String,
    seconds: f64,
    translate: bool,
}

fn say(app: &AppHandle, text: &str, seconds: f64) {
    let _ = app.emit_to(BUBBLE, "pet-say", Say { text: text.into(), seconds, translate: true });
}

/// The bubble on whichever side has room; the permission card too; the squad over its head.
fn place_all(app: &AppHandle) {
    let Some((m, (x, y, w, h))) = pet_monitor(app) else { return };
    let scale = m.scale_factor();
    let (l, t, r, b) = work_rect(&m);
    let px = |v: f64| (v * scale) as i32;
    if let Some(bubble) = window(app, BUBBLE) {
        let (bw, bh) = (px(BUBBLE_W), px(BUBBLE_H));
        let left = x + w + bw > r;
        let bx = if left { x - bw + px(6.0) } else { x + w - px(6.0) };
        let _ = bubble.set_size(PhysicalSize::new(bw as u32, bh as u32));
        let _ = bubble.set_position(PhysicalPosition::new(bx, y + h / 2 - bh / 2 - px(10.0)));
        let _ = bubble.emit("pet-side", BubbleSide { left });
    }
    if APPROVAL_ON.load(Ordering::SeqCst) {
        if let Some(card) = window(app, APPROVAL) {
            let (cw, ch) = (px(CARD_W), px(CARD_H));
            let left = x + w + cw > r;
            let cx = if left { x - cw - px(4.0) } else { x + w + px(4.0) };
            let cy = (y + h / 2 - ch / 2 - px(24.0)).clamp(t, (b - ch).max(t));
            let _ = card.set_size(PhysicalSize::new(cw as u32, ch as u32));
            let _ = card.set_position(PhysicalPosition::new(cx, cy));
        }
    }
    let n = SQUAD_N.load(Ordering::SeqCst);
    if n > 0 {
        if let Some(squad) = window(app, SQUAD) {
            let (sw, sh) = (px(n.min(8) as f64 * 24.0 + 10.0), px(SQUAD_H));
            let sy = if y - sh + px(8.0) > t { y - sh + px(8.0) } else { y + h - px(4.0) };
            let sx = (x + w / 2 - sw / 2).clamp(l, (r - sw).max(l));
            let _ = squad.set_size(PhysicalSize::new(sw as u32, sh as u32));
            let _ = squad.set_position(PhysicalPosition::new(sx, sy));
        }
    }
}

fn move_pet(app: &AppHandle, to: PhysicalPosition<i32>) {
    if let Some(win) = window(app, PET) {
        let _ = win.set_position(to);
    }
    place_all(app);
}

/// Which of the pet's windows show: all of them while it's out and in sight.
fn refresh_visibility(app: &AppHandle) {
    let shown = VISIBLE.load(Ordering::SeqCst) && !OUT_OF_SIGHT.load(Ordering::SeqCst);
    let set = |label: &str, on: bool| {
        if let Some(w) = window(app, label) {
            let _ = if on { w.show() } else { w.hide() };
            if on {
                let _ = w.set_always_on_top(true);
            }
        }
    };
    set(PET, shown);
    set(BUBBLE, shown);
    set(APPROVAL, shown && APPROVAL_ON.load(Ordering::SeqCst));
    set(SQUAD, shown && SQUAD_N.load(Ordering::SeqCst) > 0);
    if !shown {
        close_menu(app);
    }
}

/// Shows it (at a point, or at its spot on the cursor's screen).
fn show(app: &AppHandle, at: Option<(f64, f64)>) {
    let (Some(pet), Some(_)) = (build(app, PET, "pet.html", SIZE, SIZE, true), build(app, BUBBLE, "pet-bubble.html", BUBBLE_W, BUBBLE_H, false)) else {
        return;
    };
    let (cx, cy) = at.or_else(cursor).unwrap_or((0.0, 0.0));
    let Some(m) = monitor_at(app, cx, cy).or_else(|| app.primary_monitor().ok().flatten()) else { return };
    let s = pet_size(&m);
    let _ = pet.set_size(PhysicalSize::new(s as u32, s as u32));
    let origin = match at {
        Some((x, y)) => PhysicalPosition::new(x as i32 - s / 2, y as i32 - s / 2),
        None => saved_origin(app, &m),
    };
    VISIBLE.store(true, Ordering::SeqCst);
    OUT_OF_SIGHT.store(false, Ordering::SeqCst);
    move_pet(app, origin);
    refresh_visibility(app);
    if at.is_some() {
        save_position(app);
    }
}

fn hide(app: &AppHandle) {
    VISIBLE.store(false, Ordering::SeqCst);
    stop_motion();
    brain().perch = None;
    refresh_visibility(app);
    if let Some(v) = window(app, VISITOR) {
        let _ = v.hide();
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

/// Double click (or the menu's "Back to the island"): home again.
pub fn dock(app: &AppHandle) {
    update_settings(app, |s| s.desktop_mochi = false);
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || hide(&app2));
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "pet-docked", ());
}

/// The pet window moved (a drag, a hop, a throw): its cards follow; a drag is sampled for the throw.
pub fn moved(app: &AppHandle) {
    place_all(app);
    if DRAGGING.load(Ordering::SeqCst) {
        if let Some((x, y, _, _)) = pet_rect(app) {
            let mut s = SAMPLES.lock().unwrap();
            s.push_back((Instant::now(), x, y));
            while s.len() > 16 {
                s.pop_front();
            }
        }
    } else if !FLYING.load(Ordering::SeqCst) {
        *MOVED_AT.lock().unwrap() = Some(Instant::now());
    }
}

/// Starts a native drag of the pet window (from its mousedown).
pub fn drag(app: &AppHandle) {
    close_menu(app);
    grabbed();
    SAMPLES.lock().unwrap().clear();
    DRAGGING.store(true, Ordering::SeqCst);
    if let Some(w) = window(app, PET) {
        let _ = w.start_dragging();
    }
}

// ── Moving on its own ─────────────────────────────────────────────────────────

fn begin_motion() -> u64 {
    FLYING.store(true, Ordering::SeqCst);
    MOTION.fetch_add(1, Ordering::SeqCst) + 1
}

fn alive(gen: u64) -> bool {
    MOTION.load(Ordering::SeqCst) == gen
}

fn end_motion(gen: u64) {
    if alive(gen) {
        FLYING.store(false, Ordering::SeqCst);
    }
}

fn stop_motion() {
    MOTION.fetch_add(1, Ordering::SeqCst);
    FLYING.store(false, Ordering::SeqCst);
}

/// A drag began, or it was called over: whatever it was doing stops.
fn grabbed() {
    stop_motion();
    let mut b = brain();
    b.perch = None;
    b.peek = None;
    b.pop_until = None;
    b.next_perch = Instant::now() + Duration::from_secs(20);
}

fn ease_in_out(k: f64) -> f64 {
    if k < 0.5 { 2.0 * k * k } else { 1.0 - (-2.0 * k + 2.0).powi(2) / 2.0 }
}

/// Off to another spot: a hop in an arc (`lift` overrides its height; a small
/// one reads as walking), or a teleport with sparkles when it's far.
fn travel(app: &AppHandle, to: PhysicalPosition<i32>, allow_teleport: bool, lift: Option<f64>) {
    let app = app.clone();
    let gen = begin_motion();
    std::thread::spawn(move || {
        let Some((m, (x, y, _, _))) = pet_monitor(&app) else { return end_motion(gen) };
        let scale = m.scale_factor();
        let (fx, fy, tx, ty) = (x as f64, y as f64, to.x as f64, to.y as f64);
        let distance = ((tx - fx).powi(2) + (ty - fy).powi(2)).sqrt() / scale;
        if allow_teleport && distance > 1400.0 {
            let _ = app.emit_to(PET, "pet-teleport", false);
            std::thread::sleep(Duration::from_millis(220));
            if alive(gen) {
                move_pet(&app, to);
                let _ = app.emit_to(PET, "pet-teleport", true);
            }
            return end_motion(gen);
        }
        let duration = match lift {
            Some(_) => 0.35 + (distance / 260.0).min(1.2),
            None => 0.45 + (distance / 3000.0).min(0.4),
        };
        let height = lift.unwrap_or_else(|| (40.0 + distance * 0.12).min(150.0)) * scale;
        let _ = app.emit_to(PET, "pet-hop", ());
        let start = Instant::now();
        while alive(gen) {
            let k = (start.elapsed().as_secs_f64() / duration).min(1.0);
            let e = ease_in_out(k);
            let arc = height * 4.0 * k * (1.0 - k);
            move_pet(&app, PhysicalPosition::new((fx + (tx - fx) * e) as i32, (fy + (ty - fy) * e - arc) as i32));
            if k >= 1.0 {
                let _ = app.emit_to(PET, "pet-hop", ());
                break;
            }
            std::thread::sleep(Duration::from_millis(16));
        }
        end_motion(gen);
    });
}

/// A short slide (into a peek, out of it): no hop, no sound. Saves the spot after.
fn glide(app: &AppHandle, to: PhysicalPosition<i32>) {
    let app = app.clone();
    let gen = begin_motion();
    std::thread::spawn(move || {
        let Some((x, y, _, _)) = pet_rect(&app) else { return end_motion(gen) };
        let (fx, fy) = (x as f64, y as f64);
        let start = Instant::now();
        while alive(gen) {
            let k = (start.elapsed().as_secs_f64() / 0.28).min(1.0);
            let e = ease_in_out(k);
            move_pet(&app, PhysicalPosition::new((fx + (to.x as f64 - fx) * e) as i32, (fy + (to.y as f64 - fy) * e) as i32));
            if k >= 1.0 {
                break;
            }
            std::thread::sleep(Duration::from_millis(16));
        }
        if alive(gen) {
            end_motion(gen);
            save_position(&app);
        }
    });
}

/// Let go with speed: it flies (gravity, bounces), then settles.
fn fling(app: &AppHandle, vx: f64, vy: f64) {
    let app = app.clone();
    let gen = begin_motion();
    std::thread::spawn(move || {
        let Some((m, (x, y, _, _))) = pet_monitor(&app) else { return end_motion(gen) };
        let scale = m.scale_factor();
        let (l, t, r, b) = work_rect(&m);
        let (w, h) = ((r - l) as f64 / scale, (b - t) as f64 / scale);
        let mut body = Body { x: (x - l) as f64 / scale, y: (y - t) as f64 / scale, vx, vy };
        let mut frames = 0;
        while alive(gen) && frames < 1200 {
            frames += 1;
            let (bumped, rest) = pet_brain::step(&mut body, w, h, SIZE, 1.0 / 60.0);
            if bumped {
                let _ = app.emit_to(PET, "pet-bump", ());
            }
            move_pet(&app, PhysicalPosition::new(l + (body.x * scale) as i32, t + (body.y * scale) as i32));
            if rest {
                break;
            }
            std::thread::sleep(Duration::from_millis(16));
        }
        if alive(gen) {
            end_motion(gen);
            settle(&app);
        }
    });
}

/// Where it peeks from a side: 42 % off the screen.
fn peek_origin(m: &Monitor, side: Side, y: i32) -> PhysicalPosition<i32> {
    let (l, _, r, _) = work_rect(m);
    let s = pet_size(m) as f64;
    match side {
        Side::Left => PhysicalPosition::new(l - (s * 0.42) as i32, y),
        Side::Right => PhysicalPosition::new(r - (s * 0.58) as i32, y),
    }
}

/// At rest: against a side edge it hides half and peeks; else it stays.
fn settle(app: &AppHandle) {
    let Some((m, (x, y, _, _))) = pet_monitor(app) else { return };
    let scale = m.scale_factor();
    let (l, _, r, _) = work_rect(&m);
    let side = pet_brain::peek_side((x - l) as f64 / scale, (r - l) as f64 / scale, SIZE);
    brain().peek = side;
    match side {
        Some(side) => glide(app, peek_origin(&m, side, y)),
        None => save_position(app),
    }
}

/// News (a toast, a permission, an answer) while it peeks: out for 5 s.
pub fn news(app: &AppHandle) {
    let side = brain().peek;
    let (Some(side), Some((m, (_, y, _, _)))) = (side, pet_monitor(app)) else { return };
    let (l, _, r, _) = work_rect(&m);
    let (s, gap) = (pet_size(&m), (4.0 * m.scale_factor()) as i32);
    brain().pop_until = Some(Instant::now() + Duration::from_secs(5));
    glide(app, PhysicalPosition::new(if side == Side::Left { l + gap } else { r - s - gap }, y));
}

/// "Hide 15 min" in the pet's menu.
pub fn hide_for(app: &AppHandle, seconds: u64) {
    brain().hidden_until = Some(Instant::now() + Duration::from_secs(seconds.min(24 * 3600)));
    set_out_of_sight(app, true);
}

fn set_out_of_sight(app: &AppHandle, hidden: bool) {
    if OUT_OF_SIGHT.swap(hidden, Ordering::SeqCst) != hidden {
        let app2 = app.clone();
        let _ = app.run_on_main_thread(move || refresh_visibility(&app2));
    }
}

/// Its window went away: down it goes, with a word about it.
fn fall(app: &AppHandle) {
    say(app, "Ouch!", 2.0);
    brain().next_perch = Instant::now() + Duration::from_secs(8);
    fling(app, 0.0, 900.0);
}

/// Every quarter second: the walker (opt-in), and back to peeking after news.
fn walker_tick(app: &AppHandle, walker: bool) {
    let busy = FLYING.load(Ordering::SeqCst) || DRAGGING.load(Ordering::SeqCst);
    let Some((m, (x, y, _, _))) = pet_monitor(app) else { return };
    let now = Instant::now();
    let (peek, pop_until) = {
        let b = brain();
        (b.peek, b.pop_until)
    };
    if let (Some(side), Some(until)) = (peek, pop_until) {
        if now > until && !busy {
            brain().pop_until = None;
            glide(app, peek_origin(&m, side, y));
        }
        return;
    }
    if !walker || busy || peek.is_some() || MENU_OPEN.load(Ordering::SeqCst) {
        return;
    }
    let scale = m.scale_factor();
    let s = pet_size(&m);
    let perch = brain().perch;
    if let Some((hwnd, dx)) = perch {
        let Some(r) = crate::capture::window_rect(hwnd) else {
            brain().perch = None;
            return fall(app);
        };
        let dx = dx.clamp(0, (r.2 - r.0 - s).max(0));
        let target = PhysicalPosition::new(r.0 + dx, r.1 - s + (4.0 * scale) as i32);
        if (target.x - x).abs() > 0 || (target.y - y).abs() > 0 {
            move_pet(app, target);
        }
        let stroll = {
            let mut b = brain();
            if now > b.next_stroll {
                b.next_stroll = now + Duration::from_secs_f64(b.rng.range(6.0, 14.0));
                let ndx = b.rng.range(0.0, (r.2 - r.0 - s).max(0) as f64) as i32;
                b.perch = Some((hwnd, ndx));
                Some(ndx)
            } else {
                None
            }
        };
        if let Some(ndx) = stroll {
            travel(app, PhysicalPosition::new(r.0 + ndx, target.y), true, Some(10.0));
        }
    } else if now > brain().next_perch {
        let pause = brain().rng.range(10.0, 25.0);
        brain().next_perch = now + Duration::from_secs_f64(pause);
        let min = ((240.0 * scale) as i32, (120.0 * scale) as i32);
        let Some((hwnd, r)) = pet_brain::front_window(&crate::capture::top_windows(), work_rect(&m), s, min) else { return };
        let (dx, stroll) = {
            let mut b = brain();
            (b.rng.range(0.0, (r.2 - r.0 - s).max(0) as f64) as i32, b.rng.range(6.0, 14.0))
        };
        {
            let mut b = brain();
            b.perch = Some((hwnd, dx));
            b.next_stroll = now + Duration::from_secs_f64(stroll);
        }
        travel(app, PhysicalPosition::new(r.0 + dx, r.1 - s + (4.0 * scale) as i32), true, None);
    }
}

/// Shake the mouse anywhere: five wide back-and-forths within 0.8 s call it over.
fn shake_check(app: &AppHandle, cx: f64, cy: f64, scale: f64) {
    let now = Instant::now();
    let turns = {
        let mut b = brain();
        b.shakes.push_back((now, cx / scale));
        while b.shakes.front().is_some_and(|(t, _)| now.duration_since(*t) > Duration::from_millis(800)) {
            b.shakes.pop_front();
        }
        if b.shakes.len() <= 6 || b.last_summon.is_some_and(|t| now.duration_since(t) < Duration::from_secs(3)) {
            return;
        }
        let xs: Vec<f64> = b.shakes.iter().map(|(_, x)| *x).collect();
        pet_brain::count_turns(&xs, 22.0)
    };
    if turns < 5 {
        return;
    }
    {
        let mut b = brain();
        b.last_summon = Some(now);
        b.shakes.clear();
    }
    grabbed();
    let Some(m) = monitor_at(app, cx, cy) else { return };
    let (l, t, r, b) = work_rect(&m);
    let (s, k) = (pet_size(&m), m.scale_factor());
    let to = PhysicalPosition::new(
        (cx as i32 + (30.0 * k) as i32).clamp(l, (r - s).max(l)),
        (cy as i32 + (20.0 * k) as i32).clamp(t, (b - s).max(t)),
    );
    travel(app, to, true, None);
}

// ── The menu ──────────────────────────────────────────────────────────────────

pub fn close_menu(app: &AppHandle) {
    if MENU_OPEN.swap(false, Ordering::SeqCst) {
        if let Some(w) = window(app, MENU) {
            crate::island::set_activating(&w, false);
            let _ = w.hide();
        }
    }
}

/// Beside the pet, on the side with room, clamped to the work area.
fn place_menu(app: &AppHandle, height: f64) {
    let (Some(menu), Some((m, (x, y, w, h)))) = (window(app, MENU), pet_monitor(app)) else { return };
    let scale = m.scale_factor();
    let (l, t, r, b) = work_rect(&m);
    let mh = ((height * scale) as i32).min(b - t - (40.0 * scale) as i32).max(80);
    let mw = (MENU_W * scale) as i32;
    let right = x + w + mw + (8.0 * scale) as i32 <= r;
    let mx = if right { x + w + (6.0 * scale) as i32 } else { (x - mw - (6.0 * scale) as i32).max(l) };
    let top = t + (8.0 * scale) as i32;
    let bottom = b - mh - (8.0 * scale) as i32;
    let my = (y + h / 2 - mh + (40.0 * scale) as i32).clamp(top, bottom.max(top));
    let _ = menu.set_size(PhysicalSize::new(mw as u32, mh as u32));
    let _ = menu.set_position(PhysicalPosition::new(mx, my));
}

pub fn toggle_menu(app: &AppHandle) {
    if MENU_OPEN.load(Ordering::SeqCst) {
        return close_menu(app);
    }
    let Some(menu) = build(app, MENU, "pet-menu.html", MENU_W, 360.0, true) else { return };
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

/// "Ask Mochi…" was clicked: the menu takes the keyboard (only while it shows).
pub fn menu_keyboard(app: &AppHandle) {
    if let (true, Some(w)) = (MENU_OPEN.load(Ordering::SeqCst), window(app, MENU)) {
        crate::island::set_activating(&w, true);
        let _ = w.set_focus();
    }
}

/// A choice in the menu: it closes, the island comes to the pet's screen, then
/// does what was picked.
pub fn choose(app: &AppHandle, choice: serde_json::Value) {
    close_menu(app);
    crate::worktrees::watch(app, false);
    match choice.get("kind").and_then(|k| k.as_str()) {
        Some("settings") => return crate::show_settings_window(app),
        // A question: the answer comes back in the bubble; the island stays put.
        Some("ask") => {
            let _ = app.emit_to(crate::island::WINDOW_LABEL, "pet-action", choice);
            return;
        }
        _ => {}
    }
    bring_island(app);
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "pet-action", choice);
}

/// The island to the pet's screen, as it is.
fn bring_island(app: &AppHandle) {
    if let Some((x, y, w, h)) = pet_rect(app) {
        let app2 = app.clone();
        let _ = app.run_on_main_thread(move || {
            crate::island::place_on_screen_at(&app2, (x + w / 2) as f64, (y + h / 2) as f64);
        });
    }
}

// ── Cards beside it, visitors ─────────────────────────────────────────────────

/// The island shows or hides the permission card or the squad (`count` members).
pub fn card(app: &AppHandle, kind: &str, show: bool, count: usize) {
    match kind {
        "approval" => {
            let was = APPROVAL_ON.swap(show, Ordering::SeqCst);
            if show && build(app, APPROVAL, "pet-approval.html", CARD_W, CARD_H, true).is_none() {
                return;
            }
            if show && !was {
                let _ = app.emit_to(PET, "pet-hop", ());
                news(app);
            }
        }
        "squad" => {
            let n = if show { count.min(8) } else { 0 };
            SQUAD_N.store(n, Ordering::SeqCst);
            if n > 0 && build(app, SQUAD, "pet-squad.html", n as f64 * 24.0 + 10.0, SQUAD_H, true).is_none() {
                return;
            }
        }
        _ => return,
    }
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        place_all(&app2);
        refresh_visibility(&app2);
    });
}

#[derive(Serialize, Clone)]
struct Visitor {
    name: String,
}

/// A paired Mochi brings something: in from the screen's edge, a hello, out again.
pub fn visit(app: &AppHandle, name: &str, saying: &str) {
    if !VISIBLE.load(Ordering::SeqCst) || OUT_OF_SIGHT.load(Ordering::SeqCst) {
        return;
    }
    let (Some(win), Some((m, (x, y, w, h)))) = (build(app, VISITOR, "pet-visitor.html", VISITOR_S, VISITOR_S, false), pet_monitor(app)) else {
        return;
    };
    let scale = m.scale_factor();
    let s = (VISITOR_S * scale) as i32;
    let (mp, ms) = (*m.position(), *m.size());
    let (left_edge, right_edge) = (mp.x, mp.x + ms.width as i32);
    let from_left = (x + w / 2) - left_edge > right_edge - (x + w / 2);
    let ground = y + h - s;
    let from = (if from_left { left_edge - s } else { right_edge }, ground);
    let to = (if from_left { x - s + (6.0 * scale) as i32 } else { x + w - (6.0 * scale) as i32 }, ground);
    let _ = win.set_size(PhysicalSize::new(s as u32, s as u32));
    let _ = win.set_position(PhysicalPosition::new(from.0, from.1));
    let _ = win.emit("pet-visitor", Visitor { name: name.into() });
    let _ = win.show();
    let _ = win.set_always_on_top(true);
    let (app2, who) = (app.clone(), name.to_string());
    std::thread::spawn(move || {
        // The first time, its page is still loading: say who it is again.
        for wait in [300, 700] {
            std::thread::sleep(Duration::from_millis(wait));
            let _ = app2.emit_to(VISITOR, "pet-visitor", Visitor { name: who.clone() });
        }
    });
    let (app, saying) = (app.clone(), saying.to_string());
    std::thread::spawn(move || {
        let walk = |a: (i32, i32), b: (i32, i32)| {
            let start = Instant::now();
            loop {
                let k = (start.elapsed().as_secs_f64() / 1.6).min(1.0);
                let hop = ((k * std::f64::consts::PI * 6.0).sin().abs() * 10.0 * scale) as i32;
                if let Some(v) = window(&app, VISITOR) {
                    let _ = v.set_position(PhysicalPosition::new(a.0 + ((b.0 - a.0) as f64 * k) as i32, a.1 - hop));
                }
                if k >= 1.0 {
                    break;
                }
                std::thread::sleep(Duration::from_millis(16));
            }
        };
        walk(from, to);
        std::thread::sleep(Duration::from_millis(300));
        let _ = app.emit_to(PET, "pet-fx", serde_json::json!({ "kind": "greet" }));
        let _ = app.emit_to(BUBBLE, "pet-say", Say { text: saying, seconds: 4.0, translate: false });
        std::thread::sleep(Duration::from_millis(2700));
        walk(to, from);
        if let Some(v) = window(&app, VISITOR) {
            let _ = v.hide();
        }
    });
}

/// A file over the pet (`over`), or dropped on it: it gulps it and the island takes it.
pub fn file_drop(app: &AppHandle, over: bool, path: Option<String>) {
    if over {
        let _ = app.emit_to(PET, "pet-hungry", ());
        return;
    }
    let Some(path) = path else { return };
    let _ = app.emit_to(PET, "pet-gulp", ());
    bring_island(app);
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "pet-dropped", path);
}

// ── Following, eyes, outside clicks ───────────────────────────────────────────

#[derive(Serialize, Clone, PartialEq)]
struct Look {
    x: f64,
    y: f64,
}

fn button_down(vk: windows::Win32::UI::Input::KeyboardAndMouse::VIRTUAL_KEY) -> bool {
    unsafe { (windows::Win32::UI::Input::KeyboardAndMouse::GetAsyncKeyState(vk.0 as i32) as u16 & 0x8000) != 0 }
}

fn inside(r: Option<(i32, i32, i32, i32)>, x: f64, y: f64) -> bool {
    r.is_some_and(|(rx, ry, rw, rh)| x >= rx as f64 && x < (rx + rw) as f64 && y >= ry as f64 && y < (ry + rh) as f64)
}

fn rect_of(app: &AppHandle, label: &str) -> Option<(i32, i32, i32, i32)> {
    let w = window(app, label)?;
    let (p, s) = (w.outer_position().ok()?, w.outer_size().ok()?);
    Some((p.x, p.y, s.width as i32, s.height as i32))
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
            let prefs = settings(&app);
            let pref = |f: fn(&crate::settings::Settings) -> bool| prefs.as_ref().is_some_and(f);

            // Out of sight while presenting on its screen, or on request.
            if ticks % 30 == 0 {
                let manual = brain().hidden_until.is_some_and(|t| Instant::now() < t);
                let covered = pref(|s| s.pet_hide) && pet_monitor(&app).is_some_and(|(m, _)| {
                    let (p, s) = (*m.position(), *m.size());
                    pet_brain::presenting(&crate::capture::top_windows(), (p.x, p.y, p.x + s.width as i32, p.y + s.height as i32))
                });
                set_out_of_sight(&app, manual || covered);
            }
            if OUT_OF_SIGHT.load(Ordering::SeqCst) {
                continue;
            }

            let (Some((cx, cy)), Some((m, rect))) = (cursor(), pet_monitor(&app)) else { continue };
            let (x, y, w, h) = rect;
            let scale = m.scale_factor();
            let left = button_down(VK_LBUTTON);
            let down = left || button_down(VK_RBUTTON);

            // A drag that ended: thrown, or settled where it was let go.
            if DRAGGING.load(Ordering::SeqCst) && !left {
                DRAGGING.store(false, Ordering::SeqCst);
                *MOVED_AT.lock().unwrap() = None;
                let now = Instant::now();
                let samples: Vec<(f64, f64, f64)> = SAMPLES
                    .lock()
                    .unwrap()
                    .iter()
                    .map(|(t, sx, sy)| (-(now.duration_since(*t).as_secs_f64()), *sx as f64 / scale, *sy as f64 / scale))
                    .collect();
                let (vx, vy) = pet_brain::release_velocity(&samples, 0.0);
                if (vx * vx + vy * vy).sqrt() > 700.0 {
                    fling(&app, vx.clamp(-4000.0, 4000.0), vy.clamp(-4000.0, 4000.0));
                } else {
                    settle(&app);
                }
            }

            // Its eyes on the cursor (the engine wants -1…1); peeking, on the screen.
            let peek = brain().peek;
            let look = match peek {
                Some(Side::Left) => Look { x: 0.85, y: -0.1 },
                Some(Side::Right) => Look { x: -0.85, y: -0.1 },
                None => Look {
                    x: ((cx - (x + w / 2) as f64) / scale / 320.0).clamp(-1.0, 1.0),
                    y: ((cy - (y + h / 2) as f64) / scale / 260.0).clamp(-1.0, 1.0),
                },
            };
            if last_look.as_ref() != Some(&look) {
                let _ = app.emit_to(PET, "pet-look", look.clone());
                last_look = Some(look);
            }
            // A move that rested (a programmatic one saves itself): remember the spot.
            let rested = MOVED_AT.lock().unwrap().is_some_and(|t| t.elapsed() > Duration::from_millis(400));
            if rested && !DRAGGING.load(Ordering::SeqCst) {
                *MOVED_AT.lock().unwrap() = None;
                save_position(&app);
            }
            // The menu closes on a click elsewhere, or Escape.
            if MENU_OPEN.load(Ordering::SeqCst) {
                let menu = rect_of(&app, MENU);
                if (down && !was_down && !inside(menu, cx, cy) && !inside(Some(rect), cx, cy)) || button_down(VK_ESCAPE) {
                    close_menu(&app);
                    crate::worktrees::watch(&app, false);
                }
            }
            was_down = down;
            // "Come here": a shake of the mouse.
            if pref(|s| s.pet_shake) && !DRAGGING.load(Ordering::SeqCst) {
                shake_check(&app, cx, cy, scale);
            }
            // The walker, and back to peeking after news.
            if ticks % 8 == 0 {
                walker_tick(&app, pref(|s| s.pet_walker));
            }
            // It follows you: the cursor settled 1.2 s on another screen.
            let busy = FLYING.load(Ordering::SeqCst) || DRAGGING.load(Ordering::SeqCst);
            if ticks % 12 != 0 || MENU_OPEN.load(Ordering::SeqCst) || down || busy || peek.is_some() || !pref(|s| s.pet_follow) {
                continue;
            }
            let here = monitor_key(&m);
            let Some(there) = monitor_at(&app, cx, cy) else { continue };
            let key = monitor_key(&there);
            if here == key {
                other = None;
                continue;
            }
            match &other {
                Some((k, since)) if *k == key && since.elapsed() >= Duration::from_millis(1200) => {
                    other = None;
                    brain().perch = None;
                    let to = saved_origin(&app, &there);
                    travel(&app, to, true, None);
                }
                Some((k, _)) if *k == key => {}
                _ => other = Some((key, Instant::now())),
            }
        }
    });
}
