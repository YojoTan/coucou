import Foundation
import AVFoundation
import Speech

// MARK: - DiscordMic (GitHub build) — Coucou's own ear during a Discord call
// Two opt-in uses of the microphone, both off by default and both only while
// in a Discord call (Settings › Discord):
//
// • "You're talking while muted": while Discord has you muted, the input level
//   only — a number per buffer, never kept, never sent. Speech for most of a
//   second raises the alert, then 20 s of quiet before the next one.
// • "Transcribe my voice": while you're not muted, your side of the call goes
//   to Apple's on-device speech recognition; the text stays in memory until the
//   call ends, for the "Summarize the call" button, and is dropped after.
//
// macOS shows its orange microphone dot whenever either is listening.

#if !APPSTORE
@MainActor
final class DiscordMic {
    static let shared = DiscordMic()
    static let alertKey = "discord-muted-alert"
    static let transcribeKey = "discord-transcribe"
    /// Input level, in dBFS, that counts as talking. A calibration knob: a loud
    /// room or a quiet microphone may want it moved.
    nonisolated static let talkThreshold: Float = -38

    private let engine = AVAudioEngine()
    private var running = false
    private let meter = Meter()
    private var recognizer: SFSpeechRecognizer?
    private var recognition: SFSpeechRecognitionTask?
    private var restart: Timer?
    private var poll: Timer?
    private var lastAlert = Date.distantPast
    private(set) var transcript = ""
    private var partial = ""
    private var last = (inCall: false, muted: false)

    private init() {
        // Discord (or a new headset) can reconfigure the input mid-call: the engine
        // stops by itself; start over clean with the new format.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.stop()
                self.update(inCall: self.last.inCall, muted: self.last.muted)
            }
        }
    }

    /// Called whenever the call, the mute or a setting changes.
    func update(inCall: Bool, muted: Bool) {
        last = (inCall, muted)
        let d = UserDefaults.standard
        let wantsAlert = d.bool(forKey: Self.alertKey) && inCall && muted
        let wantsText = d.bool(forKey: Self.transcribeKey) && inCall && !muted
        meter.mode = wantsAlert ? .level : (wantsText ? .speech : .off)
        if wantsText { startRecognition() } else { stopRecognition() }
        if (wantsAlert || wantsText) && !running { start() }
        if !(wantsAlert || wantsText) && running { stop() }
    }

    /// The call ended: the transcript is handed over once, then forgotten.
    func takeTranscript() -> String {
        let t = (transcript + " " + partial).trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        partial = ""
        return t
    }

    static func requestMic() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    nonisolated static func requestSpeech() async -> Bool {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    // MARK: Engine

    private func start() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let input = engine.inputNode
        guard input.outputFormat(forBus: 0).sampleRate > 0 else { return }
        // Never two taps on the bus (installTap raises), and the bus's own current
        // format (nil): a format read earlier can be stale after a device change.
        input.removeTap(onBus: 0)
        Self.installTap(input, meter: meter)
        do { try engine.start() } catch { input.removeTap(onBus: 0); return }
        running = true
        poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        poll?.invalidate()
        poll = nil
        meter.reset()
    }

    /// Four times a second: has the muted user been talking?
    private func check() {
        guard meter.mode == .level else { return }
        // 0.7 s of speech within the last 1.5 s.
        guard meter.loudSeconds(within: 1.5) > 0.7, Date().timeIntervalSince(lastAlert) > 20 else { return }
        lastAlert = Date()
        meter.reset()
        DiscordService.talkingWhileMuted()
    }

    // Callbacks the audio and speech frameworks call on their own threads must
    // not be formed inside this @MainActor class: Swift would make them
    // main-actor closures and trap when another thread calls them.

    nonisolated private static func installTap(_ input: AVAudioInputNode, meter: Meter) {
        input.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            meter.take(buffer)
        }
    }

    nonisolated private static func recognize(_ r: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              _ onMain: @escaping @MainActor @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        r.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true || error != nil
            Task { @MainActor in onMain(text, final) }
        }
    }

    // MARK: Speech

    private func startRecognition() {
        guard recognition == nil, SFSpeechRecognizer.authorizationStatus() == .authorized else { return }
        let r = recognizer ?? SFSpeechRecognizer()
        recognizer = r
        guard let r, r.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Never off this Mac: without on-device support, no transcript at all.
        guard r.supportsOnDeviceRecognition else { return }
        request.requiresOnDeviceRecognition = true
        meter.request = request
        recognition = Self.recognize(r, request) { [weak self] text, final in
            guard let self else { return }
            if let text { self.partial = text }
            if final { self.commitPartial() }
        }
        // A recognition request runs about a minute; roll over to a fresh one.
        restart = Timer.scheduledTimer(withTimeInterval: 50, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopRecognition()
                self.update(inCall: self.last.inCall, muted: self.last.muted)
            }
        }
    }

    private func stopRecognition() {
        restart?.invalidate()
        restart = nil
        meter.request?.endAudio()
        meter.request = nil
        recognition?.finish()
        recognition = nil
        commitPartial()
    }

    private func commitPartial() {
        guard !partial.isEmpty else { return }
        transcript += (transcript.isEmpty ? "" : " ") + partial
        partial = ""
        // ponytail: a long call keeps its last ~30k characters; chunked summaries if that bites.
        if transcript.count > 30_000 { transcript = String(transcript.suffix(30_000)) }
    }
}

/// The audio thread's side: levels, or buffers to the recognizer.
private final class Meter: @unchecked Sendable {
    enum Mode { case off, level, speech }
    private let lock = NSLock()
    private var _mode: Mode = .off
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var loud: [(Date, Double)] = []

    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }

    func take(_ buffer: AVAudioPCMBuffer) {
        switch mode {
        case .off: return
        case .speech: request?.append(buffer)
        case .level:
            guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let db = 10 * log10(max(sum / Float(n), 1e-10))
            guard db > DiscordMic.talkThreshold else { return }
            let seconds = Double(n) / buffer.format.sampleRate
            lock.withLock {
                loud.append((Date(), seconds))
                if loud.count > 200 { loud.removeFirst(loud.count - 200) }
            }
        }
    }

    func loudSeconds(within window: TimeInterval) -> Double {
        let since = Date().addingTimeInterval(-window)
        return lock.withLock { loud.filter { $0.0 > since }.reduce(0) { $0 + $1.1 } }
    }

    func reset() { lock.withLock { loud.removeAll() } }
}
#endif
