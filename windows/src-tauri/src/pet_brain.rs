// What the desktop pet does on its own — the pure bits of macOS PetBrain.swift
// (#7), kept apart so they can be tested; pet.rs drives the windows with them.
//
// • fling: let go of a drag with speed and Mochi flies — gravity, bounces off
//   the work area's sides and top with a squash, slides to a stop on the floor;
// • peek: left within 14 px of a side edge, it slides 42 % off and peeks;
// • "come here": five wide back-and-forths of the mouse call it over;
// • the window walker: it sits on the top edge of the front ordinary window;
// • presenting: a presenter app's full-screen window, or a sharing app's
//   screen-wide overlay, sends it out of sight.
//
// Units are logical pixels (macOS points), y pointing down, relative to the
// work area's top-left corner unless said otherwise.

use crate::capture::TopWindow;

/// Mochi in flight.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Body {
    pub x: f64,
    pub y: f64,
    pub vx: f64,
    pub vy: f64,
}

/// One 1/60 s step of a throw inside a `w` × `h` work area: (bumped, at rest).
pub fn step(b: &mut Body, w: f64, h: f64, size: f64, dt: f64) -> (bool, bool) {
    b.vy += 2600.0 * dt;
    b.x += b.vx * dt;
    b.y += b.vy * dt;
    let mut bumped = false;
    if b.x < 0.0 {
        b.x = 0.0;
        b.vx = -b.vx * 0.55;
        bumped = b.vx.abs() > 150.0;
    }
    if b.x > w - size {
        b.x = w - size;
        b.vx = -b.vx * 0.55;
        bumped = b.vx.abs() > 150.0;
    }
    if b.y < 0.0 {
        b.y = 0.0;
        b.vy = -b.vy * 0.4;
        bumped = true;
    }
    let mut grounded = false;
    if b.y > h - size {
        b.y = h - size;
        if b.vy.abs() < 240.0 {
            b.vy = 0.0;
            b.vx *= 0.86;
            grounded = true;
        } else {
            b.vy = -b.vy * 0.5;
            bumped = true;
        }
    }
    (bumped, grounded && b.vx.abs() < 25.0)
}

/// How fast a drag was going when let go: the last ~0.1 s of (seconds, x, y) samples.
pub fn release_velocity(samples: &[(f64, f64, f64)], now: f64) -> (f64, f64) {
    let recent: Vec<&(f64, f64, f64)> = samples.iter().filter(|s| now - s.0 < 0.1).collect();
    match (recent.first(), recent.last()) {
        (Some(a), Some(b)) if b.0 > a.0 => ((b.1 - a.1) / (b.0 - a.0), (b.2 - a.2) / (b.0 - a.0)),
        _ => (0.0, 0.0),
    }
}

/// How many times the cursor turned back, counting only legs wider than `min_leg`.
pub fn count_turns(xs: &[f64], min_leg: f64) -> u32 {
    let Some(&first) = xs.first() else { return 0 };
    let (mut turns, mut dir, mut anchor) = (0, 0.0, first);
    for &x in &xs[1..] {
        let d = x - anchor;
        if d.abs() <= min_leg {
            continue;
        }
        let nd = d.signum();
        if nd != dir {
            turns += 1;
            dir = nd;
        }
        anchor = x;
    }
    turns
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Left,
    Right,
}

/// At rest within 14 px of a side edge of a `w`-wide work area: it peeks from there.
pub fn peek_side(x: f64, w: f64, size: f64) -> Option<Side> {
    if x <= 14.0 {
        Some(Side::Left)
    } else if x >= w - size - 14.0 {
        Some(Side::Right)
    } else {
        None
    }
}

/// Physical rectangles: (left, top, right, bottom).
pub type Rect = (i32, i32, i32, i32);

fn center_in(r: Rect, area: Rect) -> bool {
    let (cx, cy) = ((r.0 + r.2) / 2, (r.1 + r.3) / 2);
    cx >= area.0 && cx < area.2 && cy >= area.1 && cy < area.3
}

/// The front-most ordinary window on that work area, if there's room above it
/// for Mochi (`size` and `min` in physical pixels). The front window filling
/// the screen means nowhere to sit.
pub fn front_window(windows: &[TopWindow], work: Rect, size: i32, min: (i32, i32)) -> Option<(isize, Rect)> {
    for w in windows {
        let r = w.rect;
        if !w.titled || w.floating || r.2 - r.0 < min.0 || r.3 - r.1 < min.1 || !center_in(r, work) {
            continue;
        }
        return (r.1 - size > work.1).then_some((w.hwnd, r));
    }
    None
}

/// Apps whose full-screen window means presenting (slides, a video).
const PRESENTERS: &[&str] = &[
    "powerpnt.exe", "pitch.exe", "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe", "vivaldi.exe",
    "arc.exe", "vlc.exe", "video.ui.exe", "microsoft.media.player.exe",
];
/// Apps that draw a screen-wide overlay (any kind of window) while you share.
const SHARERS: &[&str] = &["zoom.exe", "ms-teams.exe", "teams.exe", "webex.exe", "ciscocollabhost.exe", "webexmta.exe", "atmgr.exe"];

/// Presenting or sharing on that monitor: a presenter app's ordinary window or a
/// sharing app's window covering all of it. A full-screen editor doesn't count.
pub fn presenting(windows: &[TopWindow], monitor: Rect) -> bool {
    windows.iter().any(|w| {
        let r = w.rect;
        let covers = (r.0 - monitor.0).abs() < 2 && (r.1 - monitor.1).abs() < 2 && (r.2 - monitor.2).abs() < 2 && (r.3 - monitor.3).abs() < 2;
        covers && ((!w.floating && PRESENTERS.contains(&w.exe.as_str())) || SHARERS.contains(&w.exe.as_str()))
    })
}

/// A small xorshift: the walker's pauses don't need more.
pub struct Rng(u64);

impl Rng {
    pub fn new() -> Self {
        let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0x9E37_79B9, |d| d.as_nanos() as u64);
        Rng(seed | 1)
    }

    /// A number in [lo, hi).
    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        lo + (self.0 % 1_000_000) as f64 / 1_000_000.0 * (hi - lo)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_throw_bounces_and_comes_to_rest_on_the_floor() {
        let (w, h, s) = (1920.0, 1040.0, 92.0);
        let mut b = Body { x: 900.0, y: 300.0, vx: 3000.0, vy: -800.0 };
        let (mut bumps, mut steps) = (0, 0);
        loop {
            let (bumped, rest) = step(&mut b, w, h, s, 1.0 / 60.0);
            bumps += bumped as u32;
            steps += 1;
            assert!(b.x >= 0.0 && b.x <= w - s && b.y >= 0.0 && b.y <= h - s, "stays inside");
            if rest || steps > 2000 {
                break;
            }
        }
        assert!(steps < 2000, "it stops");
        assert!(bumps >= 2, "the right wall and the floor");
        assert_eq!(b.y, h - s, "on the floor");
    }

    #[test]
    fn the_last_tenth_of_a_second_sets_the_speed() {
        let samples = [(0.0, 0.0, 0.0), (0.95, 100.0, 0.0), (1.0, 160.0, 30.0)];
        let (vx, vy) = release_velocity(&samples, 1.0);
        assert!((vx - 1200.0).abs() < 1e-6 && (vy - 600.0).abs() < 1e-6);
        assert_eq!(release_velocity(&samples[..1], 1.0), (0.0, 0.0));
    }

    #[test]
    fn only_wide_back_and_forths_count_as_a_shake() {
        let shake = [0.0, 40.0, 0.0, 40.0, 0.0, 40.0, 0.0];
        assert_eq!(count_turns(&shake, 22.0), 6);
        let jitter = [0.0, 5.0, 0.0, 5.0, 0.0, 5.0, 0.0];
        assert_eq!(count_turns(&jitter, 22.0), 0);
        let sweep = [0.0, 30.0, 60.0, 90.0, 120.0];
        assert_eq!(count_turns(&sweep, 22.0), 1, "one direction is not a shake");
    }

    #[test]
    fn edges_make_it_peek() {
        assert_eq!(peek_side(10.0, 1920.0, 92.0), Some(Side::Left));
        assert_eq!(peek_side(1920.0 - 92.0 - 5.0, 1920.0, 92.0), Some(Side::Right));
        assert_eq!(peek_side(600.0, 1920.0, 92.0), None);
    }

    fn win(rect: Rect, exe: &str, titled: bool, floating: bool) -> TopWindow {
        TopWindow { hwnd: rect.0 as isize + 1, rect, titled, floating, exe: exe.into() }
    }

    #[test]
    fn it_sits_on_the_front_ordinary_window_with_room_above() {
        let work = (0, 0, 1920, 1040);
        let list = [
            win((100, 100, 300, 160), "palette.exe", true, true),  // an overlay: skipped
            win((2000, 200, 2800, 900), "far.exe", true, false),   // another screen: skipped
            win((400, 300, 1400, 900), "code.exe", true, false),
            win((0, 0, 1920, 1040), "chrome.exe", true, false),
        ];
        assert_eq!(front_window(&list, work, 92, (240, 120)).map(|w| w.1), Some((400, 300, 1400, 900)));
        let maximized = [win((0, 0, 1920, 1040), "code.exe", true, false)];
        assert_eq!(front_window(&maximized, work, 92, (240, 120)), None, "no room above a maximized window");
    }

    #[test]
    fn presenting_is_a_presenter_or_a_sharer_on_the_whole_screen() {
        let screen = (0, 0, 1920, 1080);
        assert!(presenting(&[win((0, 0, 1920, 1080), "powerpnt.exe", true, false)], screen));
        assert!(presenting(&[win((0, 0, 1920, 1080), "zoom.exe", false, true)], screen), "a share overlay");
        assert!(!presenting(&[win((0, 0, 1920, 1080), "code.exe", true, false)], screen), "a full-screen editor");
        assert!(!presenting(&[win((0, 0, 1920, 1040), "chrome.exe", true, false)], screen), "maximized is not full screen");
    }
}
