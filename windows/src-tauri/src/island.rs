// Island window: placement on the chosen display, the two window sizes
// (full panel / invisible wake strip), click-through and the cursor poll.
//
// There is no notch on a PC, so the island is a black shape drawn at the top
// centre of the main display inside a borderless, transparent, always-on-top
// window that never takes focus.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, Monitor, PhysicalPosition, PhysicalSize, WebviewWindow};

use windows::Win32::Foundation::{HWND, POINT};
use windows::core::BOOL;
use windows::Win32::Foundation::LPARAM;
use windows::Win32::System::Ole::RevokeDragDrop;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON, VK_RBUTTON};
use windows::Win32::UI::WindowsAndMessaging::{EnumChildWindows, GetClassNameW};
use windows::Win32::UI::WindowsAndMessaging::{
    GetCursorPos, GetWindowLongPtrW, SetWindowLongPtrW, GWL_EXSTYLE, WS_EX_NOACTIVATE,
    WS_EX_TOOLWINDOW, WindowFromPoint, GetAncestor, GA_ROOT, GetWindowThreadProcessId,
};

/// Logical size of the full window — the largest island view, like the macOS panel.
pub const PANEL_W: f64 = 720.0;
pub const PANEL_H: f64 = 320.0;
/// Logical size of the invisible strip that wakes the island when it is hidden.
pub const STRIP_W: f64 = 240.0;
pub const STRIP_H: f64 = 6.0;

pub const WINDOW_LABEL: &str = "island";

/// Margin around the island that still counts as "on the island", in logical px.
/// Wider than the macOS 6 pt because a click must never be swallowed.
const HIT_MARGIN: f64 = 14.0;

#[derive(Serialize, Clone)]
pub struct CursorPayload {
    pub x: f64,
    pub y: f64,
    /// Left button held: lets the island tell a drag of Mochi from a hover.
    pub down: bool,
}

#[derive(Serialize, Clone)]
pub struct ScreenInfo {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub scale: f64,
}

/// The island shape in window-logical coordinates, pushed by the front end.
/// The poll thread owns the click-through decision so it lands in the same 16 ms
/// tick as the cursor read — an IPC round trip here loses clicks.
#[derive(Clone, Copy, Default)]
pub struct IslandRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

fn outside_press(rect: IslandRect, x: f64, y: f64, down: bool, was_down: bool) -> bool {
    down && !was_down && rect.w > 0.0 && rect.h > 0.0
        && !(x >= rect.x && x <= rect.x + rect.w && y >= rect.y && y <= rect.y + rect.h)
}

/// A click outside the island closes it — a click, not a press. A press that
/// turns into a drag is someone fetching a file from Explorer to drop on Mochi,
/// and closing then made the drop impossible.
#[derive(Default)]
struct OutsideClick {
    press: Option<(f64, f64)>,
}

/// How far the cursor may move between press and release and still be a click.
const CLICK_SLOP: f64 = 6.0;

impl OutsideClick {
    /// One poll tick; true when a click outside has just completed.
    fn tick(&mut self, press_edge_outside: bool, down: bool, was_down: bool, x: f64, y: f64) -> bool {
        if press_edge_outside {
            self.press = Some((x, y));
            return false;
        }
        let Some((px, py)) = self.press else { return false };
        if down && ((x - px).abs() > CLICK_SLOP || (y - py).abs() > CLICK_SLOP) {
            // It became a drag: whatever is being dragged may be meant for us.
            self.press = None;
            return false;
        }
        if !down && was_down {
            self.press = None;
            return true;
        }
        false
    }
}

/// Wakes / parks the cursor poll thread so a hidden island costs literally nothing.
pub struct PollGate {
    active: Mutex<bool>,
    cv: Condvar,
    pub collapsed: AtomicBool,
    pub rect: Mutex<IslandRect>,
    /// Mirrors the window flag so we only call into Win32 when it changes.
    ignoring: AtomicBool,
}

impl PollGate {
    pub fn new() -> Self {
        Self {
            active: Mutex::new(false),
            cv: Condvar::new(),
            collapsed: AtomicBool::new(true),
            rect: Mutex::new(IslandRect::default()),
            ignoring: AtomicBool::new(false),
        }
    }

    pub fn set_rect(&self, rect: IslandRect) {
        *self.rect.lock().unwrap() = rect;
    }

    /// Forces the next poll tick to re-apply the flag (after a window resize).
    pub fn forget_ignore_state(&self) {
        self.ignoring.store(false, Ordering::Relaxed);
    }

    pub fn set_active(&self, on: bool) {
        let mut guard = self.active.lock().unwrap();
        *guard = on;
        self.cv.notify_all();
    }

    fn wait_until_active(&self) {
        let mut guard = self.active.lock().unwrap();
        while !*guard {
            guard = self.cv.wait(guard).unwrap();
        }
    }

    fn is_active(&self) -> bool {
        *self.active.lock().unwrap()
    }
}

pub fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(WINDOW_LABEL)
}

fn cursor_physical() -> Option<(f64, f64)> {
    let mut p = POINT::default();
    unsafe { GetCursorPos(&mut p).ok()? };
    Some((p.x as f64, p.y as f64))
}

/// Lets dropped files reach the app again.
///
/// wry installs its drop target by walking the webview's child windows **once**,
/// when the webview is created. WebView2 creates `Chrome_RenderWidgetHostHWND`
/// later and registers its own target on it; being the innermost window, that one
/// wins, and since the page has no HTML5 drop handler it refuses everything — the
/// "no drop" cursor, with nothing reaching Tauri. Revoking it makes OLE fall
/// through to the target wry registered on the parent widget, which is the one
/// that feeds Tauri's drag events.
///
/// Cheap and idempotent, so it is simply re-run whenever a drag might be starting.
pub fn unblock_webview_drops(app: &AppHandle) {
    for label in [WINDOW_LABEL, "settings"] {
        let Some(win) = app.get_webview_window(label) else { continue };
        let Some(hwnd) = hwnd_of(&win) else { continue };
        unsafe {
            let _ = EnumChildWindows(Some(hwnd), Some(revoke_render_widget), LPARAM(0));
        }
    }
}

unsafe extern "system" fn revoke_render_widget(hwnd: HWND, _: LPARAM) -> BOOL {
    let mut name = [0u16; 64];
    let len = unsafe { GetClassNameW(hwnd, &mut name) };
    if len > 0 {
        let class = String::from_utf16_lossy(&name[..len as usize]);
        if class == "Chrome_RenderWidgetHostHWND" {
            let _ = unsafe { RevokeDragDrop(hwnd) };
        }
    }
    true.into()
}

/// True while the left mouse button is held — the only signal we get that a
/// drag might be in flight before it reaches the window.
fn left_button_down() -> bool {
    unsafe { (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000) != 0 }
}

fn right_button_down() -> bool {
    unsafe { (GetAsyncKeyState(VK_RBUTTON.0 as i32) as u16 & 0x8000) != 0 }
}

/// Whether the window under the cursor is another of Coucou's own (the
/// settings window, the desktop pet, a native menu of the island…): a click
/// there is not a click "outside".
fn on_own_window(island: HWND, cx: f64, cy: f64) -> bool {
    unsafe {
        let hit = WindowFromPoint(POINT { x: cx as i32, y: cy as i32 });
        let root = GetAncestor(hit, GA_ROOT);
        if root.0.is_null() || root.0 == island.0 {
            return false;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(root, Some(&mut pid));
        pid == std::process::id()
    }
}

fn monitor_contains(m: &Monitor, x: f64, y: f64) -> bool {
    let p = m.position();
    let s = m.size();
    x >= p.x as f64
        && x < (p.x + s.width as i32) as f64
        && y >= p.y as f64
        && y < (p.y + s.height as i32) as f64
}

/// The display the island lives on: the primary one, or the one under the cursor.
fn target_monitor(app: &AppHandle, pref: &str) -> Option<Monitor> {
    let monitors = app.available_monitors().ok()?;
    if pref == "cursor" {
        if let Some((cx, cy)) = cursor_physical() {
            if let Some(m) = monitors.iter().find(|m| monitor_contains(m, cx, cy)) {
                return Some(m.clone());
            }
        }
    }
    app.primary_monitor()
        .ok()
        .flatten()
        .or_else(|| monitors.into_iter().next())
}

pub fn screen_info(app: &AppHandle, pref: &str) -> ScreenInfo {
    match target_monitor(app, pref) {
        Some(m) => {
            let scale = m.scale_factor();
            let p = m.position();
            let s = m.size();
            ScreenInfo {
                x: p.x as f64 / scale,
                y: p.y as f64 / scale,
                width: s.width as f64 / scale,
                height: s.height as f64 / scale,
                scale,
            }
        }
        None => ScreenInfo { x: 0.0, y: 0.0, width: 1920.0, height: 1080.0, scale: 1.0 },
    }
}

/// Places and sizes the window. `collapsed` picks the wake strip instead of the panel.
pub fn apply_geometry(app: &AppHandle, pref: &str, collapsed: bool) {
    let Some(m) = target_monitor(app, pref) else { return };
    place_on(app, &m, collapsed);
}

/// The island to the screen that holds this point (the desktop pet's), as it is.
pub fn place_on_screen_at(app: &AppHandle, x: f64, y: f64) {
    let Some(m) = app.available_monitors().ok().and_then(|ms| ms.into_iter().find(|m| monitor_contains(m, x, y))) else { return };
    let collapsed = app.try_state::<crate::Shared>().is_some_and(|s| s.gate.collapsed.load(Ordering::Relaxed));
    place_on(app, &m, collapsed);
    let _ = app.emit_to(WINDOW_LABEL, "screen-changed", ());
}

fn place_on(app: &AppHandle, m: &Monitor, collapsed: bool) {
    let Some(win) = window(app) else { return };

    let scale = m.scale_factor();
    let mp = *m.position();
    let ms = *m.size();

    let (lw, lh) = if collapsed { (STRIP_W, STRIP_H) } else { (PANEL_W, PANEL_H) };
    let pw = (lw * scale).round().max(1.0) as u32;
    let ph = (lh * scale).round().max(1.0) as u32;
    let x = mp.x + (ms.width as i32 - pw as i32) / 2;
    let y = mp.y;

    let _ = win.set_size(PhysicalSize::new(pw, ph));
    let _ = win.set_position(PhysicalPosition::new(x, y));
    // Moving across displays can rescale the window: re-assert the physical size.
    let _ = win.set_size(PhysicalSize::new(pw, ph));
    let _ = win.set_always_on_top(true);
}

fn hwnd_of(win: &WebviewWindow) -> Option<HWND> {
    let raw = win.hwnd().ok()?.0 as isize;
    if raw == 0 {
        return None;
    }
    Some(HWND(raw as *mut _))
}

/// WS_EX_NOACTIVATE keeps clicks from stealing focus; WS_EX_TOOLWINDOW keeps the
/// island out of Alt-Tab.
pub fn make_non_activating(win: &WebviewWindow) {
    let Some(hwnd) = hwnd_of(win) else { return };
    unsafe {
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let want = ex | WS_EX_NOACTIVATE.0 as isize | WS_EX_TOOLWINDOW.0 as isize;
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, want);
    }
}

/// Temporarily allow activation so a text field inside the island can be typed in.
pub fn set_activating(win: &WebviewWindow, activating: bool) {
    let Some(hwnd) = hwnd_of(win) else { return };
    unsafe {
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let want = if activating {
            ex & !(WS_EX_NOACTIVATE.0 as isize)
        } else {
            ex | WS_EX_NOACTIVATE.0 as isize
        };
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, want);
    }
}

/// Position, size and scale of the monitor the island lives on. Any change here
/// means the island has to be placed again.
fn current_screen_key(app: &AppHandle) -> Option<(i32, i32, u32, u32, u64)> {
    let pref = app
        .try_state::<crate::Shared>()
        .map(|s| s.settings.lock().unwrap().screen.clone())
        .unwrap_or_else(|| "primary".into());
    let m = target_monitor(app, &pref)?;
    let p = m.position();
    let size = m.size();
    Some((p.x, p.y, size.width, size.height, m.scale_factor().to_bits()))
}

/// The island follows the cursor's screen (macOS followCursorScreen), with the
/// "cursor" display setting and more than one screen: when the cursor settles
/// on another screen for half a second, or at once when it is within 60 px of
/// that screen's top edge (where the island is, and where a click looks for
/// it). Never while the island is open. A short look twice a second, only then.
pub fn spawn_screen_follow(app: AppHandle, gate: Arc<PollGate>) {
    std::thread::spawn(move || {
        let mut pending: Option<((i32, i32), std::time::Instant)> = None;
        loop {
            std::thread::sleep(Duration::from_millis(250));
            let follow = app
                .try_state::<crate::Shared>()
                .is_some_and(|s| s.settings.lock().unwrap().screen == "cursor");
            let Some(win) = window(&app).filter(|_| follow) else {
                std::thread::sleep(Duration::from_secs(1));
                continue;
            };
            let monitors = app.available_monitors().unwrap_or_default();
            if monitors.len() < 2 {
                pending = None;
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
            // Open: it stays where the user is working with it.
            let open = !gate.collapsed.load(Ordering::Relaxed) && gate.rect.lock().unwrap().h > 60.0;
            let (Some((cx, cy)), Ok(pos), Ok(size)) = (cursor_physical(), win.outer_position(), win.outer_size()) else { continue };
            let centre = (pos.x as f64 + size.width as f64 / 2.0, pos.y as f64 + 1.0);
            let here = monitors.iter().find(|m| monitor_contains(m, centre.0, centre.1));
            let Some(there) = monitors.iter().find(|m| monitor_contains(m, cx, cy)) else { continue };
            if open || here.is_some_and(|h| h.position() == there.position()) {
                pending = None;
                continue;
            }
            let key = (there.position().x, there.position().y);
            let near_top = cy - (there.position().y as f64) < 60.0 * there.scale_factor();
            let settled = match pending {
                Some((k, since)) if k == key => since.elapsed() >= Duration::from_millis(500),
                _ => {
                    pending = Some((key, std::time::Instant::now()));
                    false
                }
            };
            if near_top || settled {
                pending = None;
                let collapsed = gate.collapsed.load(Ordering::Relaxed);
                let handle = app.clone();
                let _ = app.run_on_main_thread(move || {
                    apply_geometry(&handle, "cursor", collapsed);
                    let _ = handle.emit_to(WINDOW_LABEL, "screen-changed", ());
                });
            }
        }
    });
}

/// Emits `cursor` (window-logical coordinates) at ~60 Hz while the island is
/// visible. Parked on a condvar the rest of the time.
pub fn spawn_cursor_poll(app: AppHandle, gate: Arc<PollGate>) {
    std::thread::spawn(move || {
        // Remembered across wakes so a display change while hidden is noticed the
        // moment the island comes back.
        let mut last_screen: Option<(i32, i32, u32, u32, u64)> = None;
        loop {
            gate.wait_until_active();
            let mut was_down = left_button_down();
            let mut was_right = right_button_down();
            let mut outside_click = OutsideClick::default();
            let mut last = (f64::MIN, f64::MIN);
            let mut ticks: u32 = 0;
            while gate.is_active() {
                std::thread::sleep(Duration::from_millis(16));

                // Monitors get plugged in, unplugged, rearranged and rescaled, and
                // an island pinned to coordinates that no longer exist is an island
                // nobody can reach. Checked about twice a second — the cursor poll
                // is already running, so this costs one monitor query.
                ticks = ticks.wrapping_add(1);
                if ticks % 30 == 0 {
                    let now = current_screen_key(&app);
                    if now.is_some() && now != last_screen {
                        let first = last_screen.is_none();
                        last_screen = now;
                        if !first {
                            crate::log::line("display layout changed — repositioning".to_string());
                            let _ = app.emit_to(WINDOW_LABEL, "screen-changed", ());
                        }
                    }
                }

                let Some(win) = window(&app) else { continue };
                let Ok(origin) = win.outer_position() else { continue };
                let scale = win.scale_factor().unwrap_or(1.0);
                let Some((cx, cy)) = cursor_physical() else { continue };
                let x = (cx - origin.x as f64) / scale;
                let y = (cy - origin.y as f64) / scale;
                let size = match win.inner_size() {
                    Ok(s) => (s.width as f64 / scale, s.height as f64 / scale),
                    Err(_) => (PANEL_W, PANEL_H),
                };
                // Sample button edges before the stationary-cursor fast path. A click
                // outside must dismiss even when the pointer has stopped moving.
                let down = left_button_down();
                let pressed = down && !was_down;
                let r = *gate.rect.lock().unwrap();
                // Coucou's own windows don't count: native select popups (they
                // belong to us even beyond the island's painted bounds), the
                // settings window, the desktop pet.
                let own = win.hwnd().is_ok_and(|hwnd| on_own_window(HWND(hwnd.0 as *mut _), cx, cy));
                let press_outside = outside_press(r, x, y, down, was_down) && !own;
                if outside_click.tick(press_outside, down, was_down, x, y) {
                    let _ = win.emit("outside-click", ());
                }
                // A right click elsewhere closes it too (there is no drag to protect).
                let right = right_button_down();
                if right && !was_right && outside_press(r, x, y, true, false) && !own {
                    let _ = win.emit("outside-click", ());
                }
                was_right = right;
                if was_down && !down {
                    let _ = win.emit("mouse-up", CursorPayload { x, y, down });
                }
                was_down = down;
                if pressed {
                    let handle = app.clone();
                    let _ = app.run_on_main_thread(move || unblock_webview_drops(&handle));
                }
                if (x - last.0).abs() < 1.0 && (y - last.1).abs() < 1.0 && !pressed {
                    continue;
                }
                last = (x, y);

                // Click-through: the window only takes the mouse over the island
                // shape. A small entry margin means the flag is already off by the
                // time a moving cursor reaches a button.
                let on_island = r.w > 0.0
                    && x >= r.x - HIT_MARGIN
                    && x <= r.x + r.w + HIT_MARGIN
                    && y >= r.y - HIT_MARGIN
                    && y <= r.y + r.h + HIT_MARGIN;

                // A file being dragged has to be able to find us. WS_EX_TRANSPARENT
                // — what click-through is on Windows — hides the window from
                // WindowFromPoint, so OLE finds no drop target and shows the "no
                // drop" cursor. macOS has no such problem: AppKit delivers drags to
                // registered destinations whatever ignoresMouseEvents says. So while
                // a button is held anywhere over the panel, the whole panel takes
                // the mouse, which also makes the drop zone as forgiving as the Mac's.
                // A press may be the start of a drag: make sure the drop target is
                // ours before the file arrives.
                let dragging = down
                    && x >= 0.0
                    && x <= size.0
                    && y >= 0.0
                    && y <= size.1;

                let accept = on_island || dragging;
                if gate.ignoring.load(Ordering::Relaxed) == accept {
                    gate.ignoring.store(!accept, Ordering::Relaxed);
                    let _ = win.set_ignore_cursor_events(!accept);
                }

                let _ = win.emit("cursor", CursorPayload { x, y, down });
            }
            // Parking: the island just collapsed to its wake strip, and the strip
            // must take the mouse. The tick that ran as it collapsed may have
            // queued click-through back on *after* set_collapsed cleared it — the
            // strip then let every hover pass straight through and the island
            // never woke (upstream issue #28). This thread's setters go through
            // the same queue, so clearing it here always lands last.
            if let Some(win) = window(&app) {
                let _ = win.set_ignore_cursor_events(false);
            }
            gate.ignoring.store(false, Ordering::Relaxed);
        }
    });
}

pub fn set_ignore_cursor(app: &AppHandle, ignore: bool) {
    if let Some(win) = window(app) {
        let _ = win.set_ignore_cursor_events(ignore);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_click_outside_closes_but_a_drag_that_starts_outside_does_not() {
        // Press, release in place: a click.
        let mut c = OutsideClick::default();
        assert!(!c.tick(true, true, false, 400.0, 50.0));
        assert!(!c.tick(false, true, true, 402.0, 51.0), "a jitter is still a click");
        assert!(c.tick(false, false, true, 402.0, 51.0));
        // Press, then move away with the button held: a file being dragged to us.
        let mut d = OutsideClick::default();
        assert!(!d.tick(true, true, false, 400.0, 50.0));
        assert!(!d.tick(false, true, true, 380.0, 40.0));
        assert!(!d.tick(false, false, true, 200.0, 30.0), "dropping it must not close the island");
        // A release with no press outside first (the press was on the island) is nothing.
        let mut e = OutsideClick::default();
        assert!(!e.tick(false, false, true, 400.0, 50.0));
    }

    #[test]
    fn outside_click_is_a_press_edge_outside_the_painted_rect() {
        let rect = IslandRect { x: 50.0, y: 10.0, w: 300.0, h: 150.0 };
        assert!(outside_press(rect, 400.0, 50.0, true, false));
        assert!(!outside_press(rect, 400.0, 50.0, true, true));
        assert!(!outside_press(rect, 400.0, 50.0, false, true));
        assert!(!outside_press(rect, 150.0, 50.0, true, false));
        assert!(!outside_press(rect, 350.0, 160.0, true, false));
        assert!(!outside_press(IslandRect::default(), 400.0, 50.0, true, false));
    }
}
