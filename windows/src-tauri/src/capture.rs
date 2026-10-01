// Window attach — drag Mochi out of the island and drop it on a window to ask
// about it (after upstream PR #11; macOS WindowContextCapture).
//
// On release, the window under the cursor is found from the z-order (not
// WindowFromPoint, which would find the island's own panel), its visible area
// is copied from the screen and saved as a PNG in the inbox with the Windows
// Imaging Component — no image crate. The chat then gets the screenshot as an
// attached file plus the app and the window title as context.
//
// Only on that explicit gesture, never in the background, and only what is
// visible on screen at that moment. The PNG stays in Coucou's inbox and goes to
// the chat engine only if the user then asks something.

use std::path::{Path, PathBuf};

use serde::Serialize;
use windows::core::{BOOL, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, GENERIC_WRITE, HWND, LPARAM, POINT, RECT};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits, ReleaseDC,
    SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, SRCCOPY,
};
use windows::Win32::Graphics::Imaging::{
    CLSID_WICImagingFactory, GUID_ContainerFormatPng, GUID_WICPixelFormat32bppBGRA, IWICImagingFactory,
    WICBitmapEncoderNoCache, WICBitmapInterpolationModeFant,
};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClassNameW, GetCursorPos, GetSystemMetrics, GetWindowThreadProcessId, IsIconic, IsWindowVisible,
    SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

use crate::files;
use crate::jump::window_title;

/// Same cap as ScreenCaptureKit attachments on macOS: enough to read, small to send.
const MAX_WIDTH: u32 = 1568;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AttachedWindow {
    pub name: String,
    pub path: String,
    pub size: u64,
    pub app_name: String,
    pub title: String,
}

/// Shell surfaces that are "no window" for this purpose.
const NOT_A_WINDOW: [&str; 4] = ["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"];

struct Hit {
    point: POINT,
    me: u32,
    found: Option<(HWND, RECT)>,
}

fn bounds(hwnd: HWND) -> Option<RECT> {
    let mut rect = RECT::default();
    unsafe {
        DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, (&mut rect as *mut RECT).cast(), std::mem::size_of::<RECT>() as u32)
            .ok()?;
    }
    Some(rect)
}

fn class_name(hwnd: HWND) -> String {
    let mut buf = [0u16; 128];
    let len = unsafe { GetClassNameW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..len.max(0) as usize])
}

unsafe extern "system" fn topmost_at(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let hit = unsafe { &mut *(lparam.0 as *mut Hit) };
    if !unsafe { IsWindowVisible(hwnd) }.as_bool() || unsafe { IsIconic(hwnd) }.as_bool() {
        return true.into();
    }
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    if pid == hit.me {
        return true.into();
    }
    let mut cloaked = 0u32;
    let is_cloaked = unsafe {
        DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, (&mut cloaked as *mut u32).cast(), 4).is_ok() && cloaked != 0
    };
    if is_cloaked || window_title(hwnd).trim().is_empty() {
        return true.into();
    }
    let Some(r) = bounds(hwnd) else { return true.into() };
    let p = hit.point;
    if p.x >= r.left && p.x < r.right && p.y >= r.top && p.y < r.bottom {
        if NOT_A_WINDOW.contains(&class_name(hwnd).as_str()) {
            // The desktop or the taskbar is on top here: there is no window to attach.
            return false.into();
        }
        hit.found = Some((hwnd, r));
        return false.into();
    }
    true.into()
}

fn exe_of(pid: u32) -> Option<PathBuf> {
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
        let _ = CloseHandle(handle);
        ok.then(|| PathBuf::from(String::from_utf16_lossy(&buf[..len as usize])))
    }
}

/// "msedge" → "Microsoft Edge": the names people use, for the common ones.
fn friendly(stem: &str) -> String {
    let known = [
        ("msedge", "Microsoft Edge"), ("chrome", "Google Chrome"), ("firefox", "Firefox"), ("brave", "Brave"),
        ("opera", "Opera"), ("code", "VS Code"), ("cursor", "Cursor"), ("windowsterminal", "Windows Terminal"),
        ("explorer", "File Explorer"), ("winword", "Word"), ("excel", "Excel"), ("powerpnt", "PowerPoint"),
        ("outlook", "Outlook"), ("olk", "Outlook"), ("teams", "Teams"), ("ms-teams", "Teams"), ("slack", "Slack"),
        ("notepad", "Notepad"), ("acrord32", "Acrobat Reader"), ("acrobat", "Acrobat"), ("figma", "Figma"),
        ("notion", "Notion"), ("obsidian", "Obsidian"), ("spotify", "Spotify"), ("orca", "Orca"),
    ];
    let lower = stem.to_lowercase();
    known
        .iter()
        .find(|(k, _)| *k == lower)
        .map(|(_, v)| v.to_string())
        .unwrap_or_else(|| {
            let mut c = stem.chars();
            c.next().map(|f| f.to_uppercase().chain(c).collect()).unwrap_or_default()
        })
}

/// The visible pixels of `r` (physical screen coordinates), BGRA, top-down.
fn grab(r: RECT) -> Result<(u32, u32, Vec<u8>), String> {
    // Only what is on the screens: a window hanging off an edge is cut there.
    let (vx, vy, vw, vh) = unsafe {
        (
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN),
        )
    };
    let left = r.left.max(vx);
    let top = r.top.max(vy);
    let w = r.right.min(vx + vw) - left;
    let h = r.bottom.min(vy + vh) - top;
    if !(16..=16384).contains(&w) || !(16..=16384).contains(&h) {
        return Err("That window has no visible area to capture.".into());
    }
    unsafe {
        let screen = GetDC(None);
        if screen.is_invalid() {
            return Err("The screen can't be read.".into());
        }
        let mem = CreateCompatibleDC(Some(screen));
        let bmp = CreateCompatibleBitmap(screen, w, h);
        let old = SelectObject(mem, bmp.into());
        let copied = BitBlt(mem, 0, 0, w, h, Some(screen), left, top, SRCCOPY).is_ok();
        SelectObject(mem, old);
        let mut pixels = vec![0u8; (w * h * 4) as usize];
        let mut info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h,
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let lines = if copied {
            GetDIBits(mem, bmp, 0, h as u32, Some(pixels.as_mut_ptr().cast()), &mut info, DIB_RGB_COLORS)
        } else {
            0
        };
        let _ = DeleteObject(bmp.into());
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        if lines == 0 {
            return Err("That window can't be captured.".into());
        }
        // A screen blit leaves alpha undefined; the PNG must be opaque.
        for px in pixels.chunks_exact_mut(4) {
            px[3] = 255;
        }
        Ok((w as u32, h as u32, pixels))
    }
}

/// BGRA pixels → PNG at `dest`, scaled down to MAX_WIDTH, through WIC.
fn save_png(dest: &Path, w: u32, h: u32, pixels: &[u8]) -> Result<(), String> {
    let wide: Vec<u16> = dest.as_os_str().to_string_lossy().encode_utf16().chain([0]).collect();
    let (w2, h2) = if w > MAX_WIDTH { (MAX_WIDTH, ((h as u64 * MAX_WIDTH as u64) / w as u64).max(1) as u32) } else { (w, h) };
    unsafe {
        let com = CoInitializeEx(None, COINIT_MULTITHREADED).is_ok();
        let result = (|| -> windows::core::Result<()> {
            let factory: IWICImagingFactory = CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
            let bitmap = factory.CreateBitmapFromMemory(w, h, &GUID_WICPixelFormat32bppBGRA, w * 4, pixels)?;
            let scaler = factory.CreateBitmapScaler()?;
            scaler.Initialize(&bitmap, w2, h2, WICBitmapInterpolationModeFant)?;
            let stream = factory.CreateStream()?;
            stream.InitializeFromFilename(PCWSTR(wide.as_ptr()), GENERIC_WRITE.0)?;
            let encoder = factory.CreateEncoder(&GUID_ContainerFormatPng, std::ptr::null())?;
            encoder.Initialize(&stream, WICBitmapEncoderNoCache)?;
            let mut frame = None;
            encoder.CreateNewFrame(&mut frame, std::ptr::null_mut())?;
            let frame: windows::Win32::Graphics::Imaging::IWICBitmapFrameEncode = frame.ok_or_else(windows::core::Error::from_win32)?;
            frame.Initialize(None::<&windows::Win32::System::Com::StructuredStorage::IPropertyBag2>)?;
            frame.SetSize(w2, h2)?;
            let mut format = GUID_WICPixelFormat32bppBGRA;
            frame.SetPixelFormat(&mut format)?;
            frame.WriteSource(&scaler, std::ptr::null())?;
            frame.Commit()?;
            encoder.Commit()?;
            Ok(())
        })();
        if com {
            CoUninitialize();
        }
        result.map_err(|e| format!("The capture couldn't be saved: {e}"))
    }
}

fn safe_stem(s: &str) -> String {
    let cleaned: String = s
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join("-");
    let cut: String = cleaned.chars().take(32).collect();
    if cut.is_empty() { "window".into() } else { cut }
}

/// Whether a window (not the desktop, not the taskbar) is under the cursor.
pub fn window_under_cursor() -> bool {
    let mut point = POINT::default();
    if unsafe { GetCursorPos(&mut point) }.is_err() {
        return true;
    }
    let mut hit = Hit { point, me: std::process::id(), found: None };
    unsafe {
        let _ = EnumWindows(Some(topmost_at), LPARAM(&mut hit as *mut Hit as isize));
    }
    hit.found.is_some()
}

/// The window under the cursor, captured into the inbox. Blocking.
pub fn attach() -> Result<AttachedWindow, String> {
    let mut point = POINT::default();
    unsafe { GetCursorPos(&mut point).map_err(|_| "The cursor position can't be read.".to_string())? };
    let mut hit = Hit { point, me: std::process::id(), found: None };
    unsafe {
        let _ = EnumWindows(Some(topmost_at), LPARAM(&mut hit as *mut Hit as isize));
    }
    let (hwnd, rect) = hit.found.ok_or("Drop Mochi on a window to ask about it.")?;

    let title = window_title(hwnd).trim().to_string();
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    let stem = exe_of(pid)
        .and_then(|p| p.file_stem().map(|s| s.to_string_lossy().to_string()))
        .unwrap_or_default();
    let app_name = if stem.is_empty() { "Window".to_string() } else { friendly(&stem) };

    let (w, h, pixels) = grab(rect)?;
    let dir = files::inbox_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let name = format!("{}-{stamp}.png", safe_stem(&app_name));
    let dest = dir.join(&name);
    save_png(&dest, w, h, &pixels)?;
    let size = std::fs::metadata(&dest).map(|m| m.len()).unwrap_or(0);
    Ok(AttachedWindow { name, path: dest.to_string_lossy().to_string(), size, app_name, title })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_friendly_and_file_safe() {
        assert_eq!(friendly("msedge"), "Microsoft Edge");
        assert_eq!(friendly("myapp"), "Myapp");
        assert_eq!(safe_stem("Microsoft Edge"), "Microsoft-Edge");
        assert_eq!(safe_stem("..\\..\\evil"), "evil");
        assert_eq!(safe_stem("***"), "window");
    }

    #[test]
    fn a_capture_is_encoded_as_png() {
        let dir = std::env::temp_dir().join(format!("coucou-capture-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let dest = dir.join("t.png");
        let (w, h) = (2000u32, 40u32);
        let pixels = vec![200u8; (w * h * 4) as usize];
        save_png(&dest, w, h, &pixels).expect("encoded");
        let bytes = std::fs::read(&dest).unwrap();
        assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
        // IHDR width/height, scaled to MAX_WIDTH.
        let width = u32::from_be_bytes(bytes[16..20].try_into().unwrap());
        let height = u32::from_be_bytes(bytes[20..24].try_into().unwrap());
        assert_eq!((width, height), (MAX_WIDTH, 31));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
