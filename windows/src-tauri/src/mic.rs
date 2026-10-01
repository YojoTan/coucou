// "You're talking while muted" — port of DiscordMic.swift's level meter.
//
// Opt-in (Settings → Discord, off by default) and only while Discord has the
// user muted in a call: the default communications microphone's level through
// WASAPI, a number per packet — never kept, never sent. Speech for most of a
// second raises the alert, then 20 s of quiet before the next one. Windows
// shows its microphone icon meanwhile.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use tauri::{AppHandle, Emitter};

/// Input level, in dBFS, that counts as talking (DiscordMic.talkThreshold).
const TALK_DBFS: f32 = -38.0;

static GENERATION: AtomicU64 = AtomicU64::new(0);
static LISTENING: AtomicU64 = AtomicU64::new(0);

/// Starts or stops listening; extra calls with the same value do nothing.
pub fn set_listening(app: &AppHandle, on: bool) {
    let now_on = LISTENING.load(Ordering::SeqCst) != 0;
    if on == now_on {
        return;
    }
    let generation = GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    LISTENING.store(if on { generation } else { 0 }, Ordering::SeqCst);
    if on {
        let app = app.clone();
        std::thread::spawn(move || {
            if let Err(e) = listen(&app, generation) {
                crate::log::line(format!("mic: {e}"));
            }
            let _ = LISTENING.compare_exchange(generation, 0, Ordering::SeqCst, Ordering::SeqCst);
        });
    }
}

/// Peak level of a packet, in dBFS (float32 or int16 samples).
fn peak_dbfs(bytes: &[u8], bits: u16) -> f32 {
    let peak = if bits == 32 {
        bytes.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]).abs()).fold(0.0, f32::max)
    } else {
        bytes.chunks_exact(2).map(|c| (i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0).abs()).fold(0.0, f32::max)
    };
    if peak <= 1e-6 { -120.0 } else { 20.0 * peak.log10() }
}

/// 0.7 s of speech within the last 1.5 s.
fn loud_enough(history: &VecDeque<(Instant, f32)>, now: Instant) -> bool {
    let loud: f32 = history
        .iter()
        .filter(|(t, _)| now.duration_since(*t) <= Duration::from_millis(1500))
        .map(|(_, secs)| secs)
        .sum();
    loud > 0.7
}

fn listen(app: &AppHandle, generation: u64) -> windows::core::Result<()> {
    use windows::Win32::Media::Audio::{
        eCapture, eCommunications, IAudioCaptureClient, IAudioClient, IMMDeviceEnumerator, MMDeviceEnumerator,
        AUDCLNT_SHAREMODE_SHARED,
    };
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED};
    unsafe {
        let com = CoInitializeEx(None, COINIT_MULTITHREADED).is_ok();
        let result = (|| -> windows::core::Result<()> {
            let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
            let device = enumerator.GetDefaultAudioEndpoint(eCapture, eCommunications)?;
            let client: IAudioClient = device.Activate(CLSCTX_ALL, None)?;
            let format = client.GetMixFormat()?;
            let (bits, block) = ((*format).wBitsPerSample, (*format).nBlockAlign as usize);
            let init = client.Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 2_000_000, 0, format, None);
            CoTaskMemFree(Some(format as *const _));
            init?;
            let capture: IAudioCaptureClient = client.GetService()?;
            client.Start()?;
            let mut history: VecDeque<(Instant, f32)> = VecDeque::new();
            let mut last_alert = Instant::now() - Duration::from_secs(60);
            while GENERATION.load(Ordering::SeqCst) == generation {
                std::thread::sleep(Duration::from_millis(50));
                let mut loudest = -120.0f32;
                let mut seconds = 0.0f32;
                let mut packet = capture.GetNextPacketSize()?;
                while packet > 0 {
                    let mut data: *mut u8 = std::ptr::null_mut();
                    let (mut frames, mut flags) = (0u32, 0u32);
                    capture.GetBuffer(&mut data, &mut frames, &mut flags, None, None)?;
                    if !data.is_null() && frames > 0 {
                        let bytes = std::slice::from_raw_parts(data, frames as usize * block);
                        loudest = loudest.max(peak_dbfs(bytes, bits));
                        seconds += 0.05;
                    }
                    capture.ReleaseBuffer(frames)?;
                    packet = capture.GetNextPacketSize()?;
                }
                let now = Instant::now();
                if loudest > TALK_DBFS && seconds > 0.0 {
                    history.push_back((now, 0.05));
                }
                while history.front().is_some_and(|(t, _)| now.duration_since(*t) > Duration::from_secs(2)) {
                    history.pop_front();
                }
                if loud_enough(&history, now) && now.duration_since(last_alert) > Duration::from_secs(20) {
                    last_alert = now;
                    history.clear();
                    let _ = app.emit("discord-talking-muted", ());
                }
            }
            let _ = client.Stop();
            Ok(())
        })();
        if com {
            CoUninitialize();
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn levels_are_read_in_dbfs() {
        let loud: Vec<u8> = [0.5f32, -0.25].iter().flat_map(|s| s.to_le_bytes()).collect();
        assert!((peak_dbfs(&loud, 32) - (-6.02)).abs() < 0.1);
        let quiet: Vec<u8> = [100i16, -50].iter().flat_map(|s| s.to_le_bytes()).collect();
        assert!(peak_dbfs(&quiet, 16) < TALK_DBFS);
        assert_eq!(peak_dbfs(&[0; 8], 32), -120.0);
    }

    #[test]
    fn most_of_a_second_of_speech_counts() {
        let now = Instant::now();
        let mut h = VecDeque::new();
        for i in 0..10 {
            h.push_back((now - Duration::from_millis(i * 100), 0.05));
        }
        assert!(!loud_enough(&h, now), "0.5 s is not enough");
        for i in 0..6 {
            h.push_back((now - Duration::from_millis(i * 100 + 50), 0.05));
        }
        assert!(loud_enough(&h, now));
    }
}
