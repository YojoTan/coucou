// The Calendar pill on Windows. EventKit has no twin for an unpackaged app
// (Windows.ApplicationModel.Appointments needs package identity), so Coucou
// reads an iCal address instead — Google's "secret address in iCal format",
// Outlook's "publish calendar" — kept in the Credential Manager like a key,
// fetched every 5 minutes while the pill is on, over https only.
//
// The feed's VEVENTs for the next 24 hours: single events, and the common
// recurrences (daily, weekly on given days, monthly by day or "2nd Tuesday",
// yearly), with their exceptions (EXDATE, moved or cancelled instances).
// Times with a TZID go through Windows' own ICU, which knows the IANA names and
// maps Outlook's Windows zone names. All-day events are left out, as on macOS.
// The island raises the toasts (5 minutes before, and at the start).

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter};

pub const TASK_ID: &str = "integration_calendar";
/// The iCal address, in the Credential Manager (it is a secret: anyone with it
/// reads the calendar).
pub const SECRET: &str = "calendar-ical-url";
const FETCH_EVERY: Duration = Duration::from_secs(5 * 60);
const MAX_FEED: usize = 8 * 1024 * 1024;
const HOUR_MS: i64 = 3_600_000;
const DAY_MS: i64 = 24 * HOUR_MS;

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEvent {
    pub id: String,
    pub title: String,
    /// Epoch milliseconds.
    pub start: i64,
    pub end: i64,
    pub link: Option<String>,
}

// ── Civil dates ───────────────────────────────────────────────────────────────

/// A wall-clock date and time, before any time zone.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Civil {
    y: i32,
    m: u32,
    d: u32,
    hh: u32,
    mm: u32,
    ss: u32,
}

/// Days since 1970-01-01 (H. Hinnant's days_from_civil).
fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y } as i64;
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(z: i64) -> (i32, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    ((if m <= 2 { y + 1 } else { y }) as i32, m, d)
}

/// 0 = Monday … 6 = Sunday.
fn weekday(days: i64) -> i64 {
    (days + 3).rem_euclid(7)
}

fn days_in_month(y: i32, m: u32) -> u32 {
    let next = if m == 12 { days_from_civil(y + 1, 1, 1) } else { days_from_civil(y, m + 1, 1) };
    (next - days_from_civil(y, m, 1)) as u32
}

impl Civil {
    fn days(&self) -> i64 {
        days_from_civil(self.y, self.m, self.d)
    }

    fn on_day(&self, days: i64) -> Civil {
        let (y, m, d) = civil_from_days(days);
        Civil { y, m, d, ..*self }
    }

    fn utc_ms(&self) -> i64 {
        self.days() * DAY_MS + (self.hh as i64 * 3600 + self.mm as i64 * 60 + self.ss as i64) * 1000
    }
}

// ── Time zones (Windows' ICU) ─────────────────────────────────────────────────

/// Where a DATE-TIME's wall clock is.
#[derive(Clone, Debug, PartialEq)]
enum Zone {
    Utc,
    /// No zone at all: the PC's own.
    Floating,
    Named(String),
}

/// A wall-clock time in a zone → epoch milliseconds. None for an unknown zone
/// name, which then falls back to the PC's zone.
fn to_ms(zone: &Zone, c: Civil) -> i64 {
    match zone {
        Zone::Utc => c.utc_ms(),
        Zone::Floating => icu_ms(None, c).unwrap_or_else(|| c.utc_ms()),
        Zone::Named(name) => icu_ms(Some(name), c).or_else(|| icu_ms(None, c)).unwrap_or_else(|| c.utc_ms()),
    }
}

/// The IANA id for a TZID: as is if ICU knows it, else as a Windows zone name.
fn iana(name: &str) -> Option<Vec<u16>> {
    use windows::Win32::Globalization::{ucal_getCanonicalTimeZoneID, ucal_getTimeZoneIDForWindowsID, U_ZERO_ERROR};
    let id: Vec<u16> = name.trim_matches('"').encode_utf16().collect();
    let mut buf = [0u16; 128];
    unsafe {
        let mut status = U_ZERO_ERROR;
        let mut system = 0i8;
        let n = ucal_getCanonicalTimeZoneID(id.as_ptr(), id.len() as i32, buf.as_mut_ptr(), buf.len() as i32, &mut system, &mut status);
        if status.0 <= 0 && n > 0 && system != 0 {
            return Some(id);
        }
        let mut status = U_ZERO_ERROR;
        let n = ucal_getTimeZoneIDForWindowsID(id.as_ptr(), id.len() as i32, windows::core::s!("001"), buf.as_mut_ptr(), buf.len() as i32, &mut status);
        (status.0 <= 0 && n > 0).then(|| buf[..n as usize].to_vec())
    }
}

fn icu_ms(zone: Option<&str>, c: Civil) -> Option<i64> {
    use windows::Win32::Globalization::{ucal_close, ucal_getMillis, ucal_open, ucal_set, ucal_setDateTime, UCAL_GREGORIAN, UCAL_MILLISECOND, U_ZERO_ERROR};
    let id = match zone {
        Some(name) => Some(iana(name)?),
        None => None,
    };
    unsafe {
        let mut status = U_ZERO_ERROR;
        let (ptr, len) = id.as_ref().map_or((std::ptr::null(), 0), |v| (v.as_ptr(), v.len() as i32));
        let cal = ucal_open(ptr, len, windows::core::s!("en_US"), UCAL_GREGORIAN, &mut status);
        if cal.is_null() || status.0 > 0 {
            return None;
        }
        ucal_setDateTime(cal, c.y, c.m as i32 - 1, c.d as i32, c.hh as i32, c.mm as i32, c.ss as i32, &mut status);
        ucal_set(cal, UCAL_MILLISECOND, 0);
        let ms = ucal_getMillis(cal as *const *const core::ffi::c_void, &mut status);
        ucal_close(cal);
        (status.0 <= 0).then_some(ms as i64)
    }
}

// ── Parsing ───────────────────────────────────────────────────────────────────

/// A DTSTART / DTEND / EXDATE / RECURRENCE-ID value.
#[derive(Clone, Debug, PartialEq)]
struct When {
    at: Civil,
    zone: Zone,
    date_only: bool,
}

impl When {
    fn ms(&self) -> i64 {
        to_ms(&self.zone, self.at)
    }
}

#[derive(Default, Debug)]
struct RawEvent {
    uid: String,
    summary: String,
    start: Option<When>,
    end: Option<When>,
    duration_ms: Option<i64>,
    location: String,
    description: String,
    url: String,
    cancelled: bool,
    rrule: Option<String>,
    exdates: Vec<When>,
    recurrence_id: Option<When>,
}

/// Content lines, with folded lines joined back (RFC 5545 §3.1).
fn unfold(text: &str) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for raw in text.split('\n') {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        if let Some(rest) = line.strip_prefix([' ', '\t']) {
            if let Some(last) = lines.last_mut() {
                last.push_str(rest);
                continue;
            }
        }
        lines.push(line.to_string());
    }
    lines
}

/// NAME;PARAM=V;PARAM="V":VALUE → (NAME, params, VALUE).
fn property(line: &str) -> Option<(String, Vec<(String, String)>, String)> {
    let mut quoted = false;
    let colon = line.char_indices().find(|&(_, c)| {
        if c == '"' {
            quoted = !quoted;
        }
        c == ':' && !quoted
    })?.0;
    let (head, value) = (&line[..colon], &line[colon + 1..]);
    let mut parts = head.split(';');
    let name = parts.next()?.trim().to_ascii_uppercase();
    let params = parts
        .filter_map(|p| p.split_once('='))
        .map(|(k, v)| (k.trim().to_ascii_uppercase(), v.trim().trim_matches('"').to_string()))
        .collect();
    Some((name, params, value.to_string()))
}

fn unescape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n' | 'N') => out.push('\n'),
                Some(other) => out.push(other),
                None => {}
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn digits(s: &str) -> Option<u32> {
    (!s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())).then(|| s.parse().ok())?
}

/// 20261001, 20261001T143000, 20261001T143000Z.
fn when(value: &str, params: &[(String, String)]) -> Option<When> {
    let v = value.trim();
    let (date, time) = v.split_once('T').map_or((v, None), |(d, t)| (d, Some(t)));
    if date.len() != 8 {
        return None;
    }
    let (y, m, d) = (digits(&date[..4])? as i32, digits(&date[4..6])?, digits(&date[6..8])?);
    if !(1..=12).contains(&m) || d == 0 || d > days_in_month(y, m) {
        return None;
    }
    let tzid = params.iter().find(|(k, _)| k == "TZID").map(|(_, v)| v.clone());
    let Some(time) = time else {
        return Some(When { at: Civil { y, m, d, hh: 0, mm: 0, ss: 0 }, zone: Zone::Floating, date_only: true });
    };
    let (clock, utc) = time.strip_suffix('Z').map_or((time, false), |t| (t, true));
    if clock.len() < 6 {
        return None;
    }
    let (hh, mm, ss) = (digits(&clock[..2])?, digits(&clock[2..4])?, digits(&clock[4..6])?.min(59));
    if hh > 23 || mm > 59 {
        return None;
    }
    let zone = if utc {
        Zone::Utc
    } else {
        tzid.map_or(Zone::Floating, |t| if t.eq_ignore_ascii_case("UTC") || t == "Z" { Zone::Utc } else { Zone::Named(t) })
    };
    Some(When { at: Civil { y, m, d, hh, mm, ss }, zone, date_only: false })
}

/// P1D, PT1H30M, P1W, -PT15M → milliseconds (the sign is dropped).
fn duration_ms(s: &str) -> Option<i64> {
    let s = s.trim().trim_start_matches(['+', '-']).strip_prefix('P')?;
    let (mut total, mut num, mut in_time) = (0i64, String::new(), false);
    for c in s.chars() {
        match c {
            'T' => in_time = true,
            '0'..='9' => num.push(c),
            _ => {
                let n: i64 = num.parse().ok()?;
                num.clear();
                total += n * match (c, in_time) {
                    ('W', false) => 7 * DAY_MS,
                    ('D', false) => DAY_MS,
                    ('H', true) => HOUR_MS,
                    ('M', true) => 60_000,
                    ('S', true) => 1000,
                    _ => return None,
                };
            }
        }
    }
    Some(total)
}

fn parse(text: &str) -> Vec<RawEvent> {
    let mut events = Vec::new();
    let mut current: Option<RawEvent> = None;
    // VALARMs inside a VEVENT have their own DESCRIPTION, TRIGGER…
    let mut nested = 0;
    for line in unfold(text) {
        let Some((name, params, value)) = property(&line) else { continue };
        match (name.as_str(), value.trim().to_ascii_uppercase().as_str()) {
            ("BEGIN", "VEVENT") => {
                current = Some(RawEvent::default());
                nested = 0;
                continue;
            }
            ("END", "VEVENT") => {
                if let Some(e) = current.take() {
                    events.push(e);
                }
                continue;
            }
            ("BEGIN", _) if current.is_some() => {
                nested += 1;
                continue;
            }
            ("END", _) if current.is_some() => {
                nested -= 1;
                continue;
            }
            _ => {}
        }
        let Some(e) = current.as_mut() else { continue };
        if nested > 0 {
            continue;
        }
        match name.as_str() {
            "UID" => e.uid = value,
            "SUMMARY" => e.summary = unescape(&value),
            "LOCATION" => e.location = unescape(&value),
            "DESCRIPTION" => e.description = unescape(&value),
            "URL" => e.url = value,
            "STATUS" => e.cancelled = value.trim().eq_ignore_ascii_case("CANCELLED"),
            "DTSTART" => e.start = when(&value, &params),
            "DTEND" => e.end = when(&value, &params),
            "DURATION" => e.duration_ms = duration_ms(&value),
            "RRULE" => e.rrule = Some(value),
            "EXDATE" => e.exdates.extend(value.split(',').filter_map(|v| when(v, &params))),
            "RECURRENCE-ID" => e.recurrence_id = when(&value, &params),
            _ => {}
        }
    }
    events
}

// ── Recurrence ────────────────────────────────────────────────────────────────

const DAYS: [&str; 7] = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"];

struct Rule {
    freq: String,
    interval: i64,
    count: Option<u32>,
    until: Option<i64>,
    /// (ordinal, weekday): 0 = every such weekday.
    by_day: Vec<(i64, i64)>,
    by_month_day: Vec<i64>,
    week_start: i64,
}

fn rule(text: &str) -> Option<Rule> {
    let mut r = Rule { freq: String::new(), interval: 1, count: None, until: None, by_day: vec![], by_month_day: vec![], week_start: 0 };
    for part in text.split(';') {
        let (k, v) = part.split_once('=')?;
        match k.trim().to_ascii_uppercase().as_str() {
            "FREQ" => r.freq = v.trim().to_ascii_uppercase(),
            "INTERVAL" => r.interval = v.trim().parse::<i64>().ok()?.max(1),
            "COUNT" => r.count = Some(v.trim().parse().ok()?),
            "UNTIL" => r.until = Some(when(v, &[]).map(|w| if w.date_only { w.at.utc_ms() + DAY_MS - 1 } else { w.ms() })?),
            "BYDAY" => {
                for d in v.split(',') {
                    let d = d.trim().to_ascii_uppercase();
                    if !d.is_ascii() {
                        return None;
                    }
                    let (n, day) = d.split_at(d.len().checked_sub(2)?);
                    let wd = DAYS.iter().position(|x| *x == day)? as i64;
                    let ord = if n.is_empty() { 0 } else { n.trim_start_matches('+').parse::<i64>().ok()? };
                    r.by_day.push((ord, wd));
                }
            }
            "BYMONTHDAY" => {
                for d in v.split(',') {
                    r.by_month_day.push(d.trim().parse().ok()?);
                }
            }
            "WKST" => r.week_start = DAYS.iter().position(|x| x.eq_ignore_ascii_case(v.trim()))? as i64,
            // BYSETPOS, BYHOUR, BYWEEKNO…: beyond what a calendar Mochi needs.
            "BYMONTH" | "BYSETPOS" | "BYYEARDAY" | "BYWEEKNO" | "BYHOUR" | "BYMINUTE" | "BYSECOND" => return None,
            _ => {}
        }
    }
    matches!(r.freq.as_str(), "DAILY" | "WEEKLY" | "MONTHLY" | "YEARLY").then_some(r)
}

/// The first day (since 1970) of the rule's k-th period.
fn period_start(r: &Rule, start: &Civil, k: i64) -> i64 {
    let first = start.days();
    match r.freq.as_str() {
        "DAILY" => first + k * r.interval,
        "WEEKLY" => first - (weekday(first) - r.week_start).rem_euclid(7) + k * 7 * r.interval,
        "MONTHLY" => {
            let months = (start.m as i64 - 1) + k * r.interval;
            days_from_civil(start.y + months.div_euclid(12) as i32, months.rem_euclid(12) as u32 + 1, 1)
        }
        _ => days_from_civil(start.y + (k * r.interval) as i32, 1, 1),
    }
}

/// The days (since 1970) of one period of the rule, in order.
fn period_days(r: &Rule, start: &Civil, k: i64) -> Vec<i64> {
    let first = start.days();
    let mut days: Vec<i64> = match r.freq.as_str() {
        "DAILY" => {
            let d = first + k * r.interval;
            if r.by_day.is_empty() || r.by_day.iter().any(|&(_, wd)| wd == weekday(d)) { vec![d] } else { vec![] }
        }
        "WEEKLY" => {
            let week = first - (weekday(first) - r.week_start).rem_euclid(7) + k * 7 * r.interval;
            let wanted: Vec<i64> = if r.by_day.is_empty() { vec![weekday(first)] } else { r.by_day.iter().map(|&(_, wd)| wd).collect() };
            wanted.iter().map(|wd| week + (wd - r.week_start).rem_euclid(7)).collect()
        }
        "MONTHLY" => {
            let months = (start.m as i64 - 1) + k * r.interval;
            let (y, m) = (start.y + months.div_euclid(12) as i32, months.rem_euclid(12) as u32 + 1);
            let len = days_in_month(y, m) as i64;
            let base = days_from_civil(y, m, 1);
            if !r.by_day.is_empty() {
                r.by_day
                    .iter()
                    .filter_map(|&(ord, wd)| {
                        let firsts = base + (wd - weekday(base)).rem_euclid(7);
                        let all: Vec<i64> = (0..5).map(|i| firsts + 7 * i).filter(|d| *d < base + len).collect();
                        match ord {
                            0 => None, // every Monday of the month: rare, left out
                            n if n > 0 => all.get(n as usize - 1).copied(),
                            n => all.len().checked_sub(n.unsigned_abs() as usize).map(|i| all[i]),
                        }
                    })
                    .collect()
            } else {
                let wanted = if r.by_month_day.is_empty() { vec![start.d as i64] } else { r.by_month_day.clone() };
                wanted
                    .iter()
                    .filter_map(|&md| {
                        let day = if md < 0 { len + md + 1 } else { md };
                        (1..=len).contains(&day).then(|| base + day - 1)
                    })
                    .collect()
            }
        }
        _ => {
            // YEARLY: the start's month and day (a 29 February waits for a leap year).
            let y = start.y + (k * r.interval) as i32;
            if start.d <= days_in_month(y, start.m) { vec![days_from_civil(y, start.m, start.d)] } else { vec![] }
        }
    };
    days.sort_unstable();
    days.dedup();
    days
}

/// The starts (ms) of one event's instances that touch [from, to].
fn instances(e: &RawEvent, start: &When, duration: i64, from: i64, to: i64, moved: &HashSet<i64>) -> Vec<i64> {
    let single = || {
        let s = start.ms();
        if s <= to && s + duration >= from { vec![s] } else { vec![] }
    };
    let Some(r) = e.rrule.as_deref().and_then(rule) else { return single() };
    let skip: HashSet<i64> = e.exdates.iter().map(When::ms).chain(moved.iter().copied()).collect();
    let mut out = Vec::new();
    let mut seen = 0u32;
    for k in 0..200_000i64 {
        let days = period_days(&r, &start.at, k);
        let mut past_window = false;
        for d in days {
            let at = start.at.on_day(d);
            if at < start.at {
                continue;
            }
            seen += 1;
            if r.count.is_some_and(|c| seen > c) {
                return out;
            }
            let ms = to_ms(&start.zone, at);
            if r.until.is_some_and(|u| ms > u) {
                return out;
            }
            if ms > to {
                past_window = true;
                break;
            }
            if ms + duration >= from && !skip.contains(&ms) {
                out.push(ms);
            }
        }
        if past_window {
            break;
        }
        // Periods only move forward: once the next one begins past the window, stop.
        if period_start(&r, &start.at, k + 1) * DAY_MS > to + 2 * DAY_MS {
            break;
        }
    }
    out
}

/// Every timed, not-cancelled instance touching [now − 1 h, now + 24 h], by start.
fn upcoming(events: &[RawEvent], now: i64) -> Vec<CalendarEvent> {
    let (from, to) = (now - HOUR_MS, now + DAY_MS);
    // Instances moved or cancelled by an override (RECURRENCE-ID), per series.
    let mut moved: HashMap<&str, HashSet<i64>> = HashMap::new();
    for e in events {
        if let Some(rid) = &e.recurrence_id {
            moved.entry(e.uid.as_str()).or_default().insert(rid.ms());
        }
    }
    let none = HashSet::new();
    let mut out = Vec::new();
    for e in events {
        let Some(start) = &e.start else { continue };
        if start.date_only || e.cancelled {
            continue;
        }
        let duration = match (&e.end, e.duration_ms) {
            (Some(end), _) if !end.date_only => (end.ms() - start.ms()).max(0),
            (_, Some(d)) => d,
            _ => 0,
        };
        let moved = if e.recurrence_id.is_some() { &none } else { moved.get(e.uid.as_str()).unwrap_or(&none) };
        let link = super::meeting_link(&[Some(e.url.as_str()), Some(e.location.as_str()), Some(e.description.as_str())]);
        for s in instances(e, start, duration, from, to, moved) {
            out.push(CalendarEvent {
                id: format!("{}{}", e.uid, s / 1000),
                title: if e.summary.trim().is_empty() { "Event".into() } else { e.summary.trim().chars().take(140).collect() },
                start: s,
                end: s + duration,
                link: link.clone(),
            });
        }
    }
    out.sort_by_key(|e| e.start);
    out
}

/// The meeting in progress if it started under 10 minutes ago, else the next one.
fn next(events: &[CalendarEvent], now: i64) -> Option<CalendarEvent> {
    let live: Vec<&CalendarEvent> = events.iter().filter(|e| e.end > now).collect();
    live.iter().find(|e| e.start > now - 10 * 60_000).or(live.first()).map(|e| (*e).clone())
}

// ── Fetching ──────────────────────────────────────────────────────────────────

/// webcal:// is the same feed over https; anything that isn't https is refused
/// (the address is a secret, it doesn't travel in clear).
fn feed_url(raw: &str) -> Option<url::Url> {
    let raw = raw.trim();
    let raw = raw.strip_prefix("webcal://").map(|r| format!("https://{r}")).unwrap_or_else(|| raw.to_string());
    let url = url::Url::parse(&raw).ok()?;
    (url.scheme() == "https" && url.host_str().is_some_and(|h| !h.is_empty())).then_some(url)
}

async fn fetch(url: url::Url) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::custom(|a| {
            if a.previous().len() < 3 && a.url().scheme() == "https" { a.follow() } else { a.stop() }
        }))
        .build()
        .map_err(|e| e.to_string())?;
    let mut resp = client.get(url).send().await.map_err(|_| "The calendar address can't be reached.".to_string())?;
    if !resp.status().is_success() {
        return Err("The calendar address answered with an error — check it in Settings › Integrations.".into());
    }
    let mut body = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| e.to_string())? {
        body.extend_from_slice(&chunk);
        if body.len() > MAX_FEED {
            return Err("That calendar is too big.".into());
        }
    }
    let text = String::from_utf8_lossy(&body).to_string();
    if !text.contains("BEGIN:VCALENDAR") {
        return Err("That address isn't an iCal calendar.".into());
    }
    Ok(text)
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Update {
    next: Option<CalendarEvent>,
    error: Option<String>,
}

struct Cache {
    fetched: Instant,
    address: String,
    events: Result<Vec<RawEvent>, String>,
}

static CACHE: Mutex<Option<Cache>> = Mutex::new(None);

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64)
}

/// One tick: refetch when due (or `force`), then say what's next.
pub async fn tick(app: &AppHandle, force: bool) {
    if !super::pill_on(app, TASK_ID) {
        return;
    }
    let Some(address) = crate::secrets::get(SECRET) else {
        let _ = app.emit("extras-calendar", Update { next: None, error: Some("Paste your calendar's iCal address in Settings › Integrations.".into()) });
        return;
    };
    let due = force
        || CACHE.lock().unwrap().as_ref().is_none_or(|c| c.address != address || c.fetched.elapsed() >= FETCH_EVERY);
    if due {
        let events = match feed_url(&address) {
            None => Err("The calendar address must start with https:// (or webcal://).".to_string()),
            Some(url) => fetch(url).await.map(|text| parse(&text)),
        };
        *CACHE.lock().unwrap() = Some(Cache { fetched: Instant::now(), address, events });
    }
    let update = {
        let cache = CACHE.lock().unwrap();
        match cache.as_ref().map(|c| &c.events) {
            Some(Ok(events)) => Update { next: next(&upcoming(events, now_ms()), now_ms()), error: None },
            Some(Err(e)) => Update { next: None, error: Some(e.clone()) },
            None => Update { next: None, error: None },
        }
    };
    let _ = app.emit("extras-calendar", update);
}

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(5)).await;
        loop {
            tick(&app, false).await;
            tokio::time::sleep(Duration::from_secs(20)).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(y: i32, m: u32, d: u32, hh: u32, mm: u32) -> i64 {
        Civil { y, m, d, hh, mm, ss: 0 }.utc_ms()
    }

    #[test]
    fn civil_dates_round_trip() {
        for days in [-1000, 0, 19_000, 20_727, 60_000] {
            let (y, m, d) = civil_from_days(days);
            assert_eq!(days_from_civil(y, m, d), days);
        }
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(weekday(days_from_civil(2026, 10, 1)), 3, "1 October 2026 is a Thursday");
        assert_eq!(days_in_month(2028, 2), 29);
    }

    #[test]
    fn zones_go_through_icu() {
        let c = Civil { y: 2026, m: 10, d: 1, hh: 9, mm: 0, ss: 0 };
        assert_eq!(to_ms(&Zone::Named("America/Bogota".into()), c), ms(2026, 10, 1, 14, 0), "UTC−5");
        assert_eq!(to_ms(&Zone::Named("SA Pacific Standard Time".into()), c), ms(2026, 10, 1, 14, 0), "Outlook's name for it");
        assert_eq!(to_ms(&Zone::Named("Europe/Madrid".into()), c), ms(2026, 10, 1, 7, 0), "summer time, UTC+2");
        let winter = Civil { m: 12, ..c };
        assert_eq!(to_ms(&Zone::Named("Europe/Madrid".into()), winter), ms(2026, 12, 1, 8, 0), "UTC+1");
    }

    const FEED: &str = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n\
BEGIN:VEVENT\r\nUID:standup\r\nSUMMARY:Daily standup\r\nDTSTART;TZID=America/Bogota:20260901T093000\r\n\
DTEND;TZID=America/Bogota:20260901T094500\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR\r\n\
EXDATE;TZID=America/Bogota:20261002T093000\r\nLOCATION:https://meet.google.com/abc-defg-hij\r\nEND:VEVENT\r\n\
BEGIN:VEVENT\r\nUID:standup\r\nRECURRENCE-ID;TZID=America/Bogota:20261005T093000\r\nSUMMARY:Daily standup (moved)\r\n\
DTSTART;TZID=America/Bogota:20261005T110000\r\nDTEND;TZID=America/Bogota:20261005T111500\r\nEND:VEVENT\r\n\
BEGIN:VEVENT\r\nUID:review\r\nSUMMARY:Review\\, with notes\r\nDTSTART:20261001T200000Z\r\nDURATION:PT1H\r\n\
DESCRIPTION:Join: https://us02web.zoom.us/j/81234?pwd=x\\nThanks\r\nBEGIN:VALARM\r\nDESCRIPTION:Reminder\r\nTRIGGER:-PT10M\r\nEND:VALARM\r\nEND:VEVENT\r\n\
BEGIN:VEVENT\r\nUID:holiday\r\nSUMMARY:Holiday\r\nDTSTART;VALUE=DATE:20261001\r\nDTEND;VALUE=DATE:20261002\r\nEND:VEVENT\r\n\
BEGIN:VEVENT\r\nUID:gone\r\nSUMMARY:Cancelled\r\nSTATUS:CANCELLED\r\nDTSTART:20261001T150000Z\r\nDTEND:20261001T160000Z\r\nEND:VEVENT\r\n\
BEGIN:VEVENT\r\nUID:monthly\r\nSUMMARY:Retro\r\nDTSTART:20260106T170000Z\r\nDTEND:20260106T180000Z\r\nRRULE:FREQ=MONTHLY;BYDAY=1TU\r\nEND:VEVENT\r\n\
BEGIN:VEVENT\r\nUID:long-desc\r\nSUMMARY:Folded\r\nDTSTART:20261002T010000Z\r\nDTEND:20261002T020000Z\r\n\
DESCRIPTION:https://teams.microsoft.com/l/meetup-join/19%3am\r\n eeting_abc\r\nEND:VEVENT\r\n\
END:VCALENDAR\r\n";

    #[test]
    fn a_feeds_next_day_with_recurrences_and_exceptions() {
        let events = parse(FEED);
        assert_eq!(events.len(), 7, "the VALARM's DESCRIPTION stays out");
        // Thursday 1 October 2026, 08:00 in Bogotá (13:00 UTC).
        let now = ms(2026, 10, 1, 13, 0);
        let up = upcoming(&events, now);
        let titles: Vec<&str> = up.iter().map(|e| e.title.as_str()).collect();
        assert_eq!(titles, ["Daily standup", "Review, with notes", "Folded"], "no holiday, nothing cancelled");
        assert_eq!(up[0].start, ms(2026, 10, 1, 14, 30));
        assert_eq!(up[0].end - up[0].start, 15 * 60_000);
        assert_eq!(up[0].link.as_deref(), Some("https://meet.google.com/abc-defg-hij"));
        assert_eq!(up[1].link.as_deref(), Some("https://us02web.zoom.us/j/81234?pwd=x"));
        assert_eq!(up[2].link.as_deref(), Some("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc"), "folded line joined");
        assert_eq!(next(&up, now).unwrap().title, "Daily standup");
        let friday = upcoming(&events, ms(2026, 10, 2, 12, 0));
        assert!(!friday.iter().any(|e| e.title.starts_with("Daily")), "Friday's standup is an EXDATE");

        // Monday 5 October: the moved instance replaces the 09:30 one.
        let monday = upcoming(&events, ms(2026, 10, 5, 12, 0));
        let standups: Vec<i64> = monday.iter().filter(|e| e.title.starts_with("Daily")).map(|e| e.start).collect();
        assert_eq!(standups, [ms(2026, 10, 5, 16, 0)], "only the moved one, at 11:00 Bogotá");

        // Tuesday 6 October: the first Tuesday of the month.
        let retro = upcoming(&events, ms(2026, 10, 6, 10, 0));
        assert!(retro.iter().any(|e| e.title == "Retro" && e.start == ms(2026, 10, 6, 17, 0)));
        assert!(!upcoming(&events, ms(2026, 10, 13, 10, 0)).iter().any(|e| e.title == "Retro"), "not the second Tuesday");
    }

    #[test]
    fn counts_untils_and_durations() {
        let e = |rrule: &str| parse(&format!("BEGIN:VEVENT\r\nUID:x\r\nSUMMARY:x\r\nDTSTART:20260928T100000Z\r\nDURATION:PT30M\r\nRRULE:{rrule}\r\nEND:VEVENT\r\n"));
        let on = |events: &[RawEvent], d: u32| upcoming(events, ms(2026, 10, d, 9, 0)).len();
        assert_eq!(on(&e("FREQ=DAILY;COUNT=3"), 1), 0, "28, 29, 30 September only");
        assert_eq!(on(&e("FREQ=DAILY;COUNT=4"), 1), 1);
        assert_eq!(on(&e("FREQ=DAILY;UNTIL=20260930T235959Z"), 1), 0);
        assert_eq!(on(&e("FREQ=DAILY;INTERVAL=2"), 2), 1, "28, 30, 2");
        assert_eq!(on(&e("FREQ=DAILY;INTERVAL=2"), 1), 0);
        assert_eq!(on(&e("FREQ=WEEKLY"), 5), 1, "Mondays");
        assert_eq!(on(&e("FREQ=YEARLY;BYSETPOS=1"), 1), 0, "an unsupported rule keeps only the first instance");
        assert_eq!(duration_ms("P1DT2H"), Some(DAY_MS + 2 * HOUR_MS));
        assert_eq!(duration_ms("-PT15M"), Some(15 * 60_000));
    }

    #[test]
    fn only_https_feeds() {
        assert_eq!(feed_url("webcal://p01-calendars.icloud.com/x").unwrap().as_str(), "https://p01-calendars.icloud.com/x");
        assert!(feed_url("http://calendar.google.com/x.ics").is_none());
        assert!(feed_url("file:///C:/x.ics").is_none());
    }
}
