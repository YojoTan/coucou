import AppKit

// MARK: - SpotifyWatcher (GitHub build) — the Spotify pill
// After upstream PR #11 (the Windows media.rs). The Spotify app posts a
// distributed notification on every play, pause and track change, with the
// artist and title in it: listening costs nothing and needs no permission, no
// key, no OAuth. The buttons tell Spotify to play, pause or skip through Apple
// Events — macOS asks once before the first one, and only then.

#if !APPSTORE
struct SpotifyTrack: Sendable, Equatable {
    let playing: Bool
    let title: String
    let artist: String
}

final class SpotifyWatcher: @unchecked Sendable {
    static let shared = SpotifyWatcher()
    private var started = false
    private init() {}

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { note in
            let info = note.userInfo ?? [:]
            let player = info["Player State"] as? String ?? ""
            let title = info["Name"] as? String ?? ""
            let artist = info["Artist"] as? String ?? ""
            let track: SpotifyTrack? = player == "Stopped" || title.isEmpty
                ? nil
                : SpotifyTrack(playing: player == "Playing", title: title, artist: artist)
            MainActor.assumeIsolated {
                AppState.shared.spotifyNow = track
            }
        }
    }

    /// "playpause", "next track" or "previous track".
    @MainActor
    static func control(_ command: String) {
        guard ["playpause", "next track", "previous track"].contains(command),
              NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first != nil
        else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Spotify\" to \(command)")?.executeAndReturnError(&error)
        if let error { NSLog("Coucou: Spotify control failed: \(error)") }
    }
}
#endif
