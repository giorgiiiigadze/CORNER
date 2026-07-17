@preconcurrency import AVFoundation
import Foundation
import os

/// The cornerman's real voice.
///
/// The problem with cloud text-to-speech in this app is latency: his line has to
/// land the moment the round turns over, and a two-second round trip while the
/// fighter stands waiting for a bell is the whole illusion gone.
///
/// We designed that away. Claude hands us the whole session up front, so every
/// line is known before the user says "let's go" — all of it is fetched and
/// cached while they're still wrapping their hands, and the round itself is
/// pure local playback. That's also why this uses the *quality* model rather
/// than the low-latency one: we're not paying for speed we can't use.
///
/// Three layers of safety, because a workout must never stop:
/// cache → network → `Cornerman` (on-device speech).
actor ElevenLabsVoice: Voice {

    /// The chosen voice, stored by Settings.
    static let preferenceKey = "cornermanVoiceID"

    /// The quality model. Latency is irrelevant here — see the note above.
    static let model = "eleven_multilingual_v2"

    private let apiKey: String
    private let voiceID: String
    private let cache: AudioCache
    private let player = AudioPlayer()
    /// Used whenever the cloud can't deliver. A robot cornerman beats silence.
    private let fallback: any Voice
    private let urlSession: URLSession
    private let log = Logger(subsystem: "Giorgi.Corner", category: "elevenlabs")

    private var prewarmTasks: [Task<Void, Never>] = []

    init(
        apiKey: String,
        voiceID: String,
        fallback: any Voice,
        cache: AudioCache = AudioCache(),
        urlSession: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.fallback = fallback
        self.cache = cache
        self.urlSession = urlSession
    }

    /// Nil when there's no key, so the app quietly stays on the native voice
    /// rather than failing.
    static func fromBundle(fallback: any Voice) -> ElevenLabsVoice? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "ELEVENLABS_API_KEY") as? String,
              key.hasPrefix("sk_")
        else { return nil }

        let voiceID = UserDefaults.standard.string(forKey: preferenceKey) ?? ElevenLabsCatalog.defaultVoiceID
        return ElevenLabsVoice(apiKey: key, voiceID: voiceID, fallback: fallback)
    }

    // MARK: - Voice

    func say(_ text: String) async {
        guard let audio = await audio(for: text) else {
            // Network died and it isn't cached — say it in the robot voice
            // rather than let a round open in silence.
            await fallback.say(text)
            return
        }
        await player.play(audio)
    }

    func cancel() async {
        // Not awaited: stopping is a lock acquisition, not a suspension, so
        // ending a session can't be left waiting behind a line that's still
        // playing. Nothing else cancels — see `Voice.cancel`.
        player.stop()
        await fallback.cancel()
    }

    /// Fetches a batch of lines before they're needed.
    ///
    /// Called once for the opening, then once per round as each approaches.
    /// Deliberately *additive* — an earlier version cancelled the previous batch,
    /// which was right when this was called once per session and silently wrong
    /// the moment it became once per round: round two's fetch would have killed
    /// round one's mid-flight, and the fighter would have got a bell with no
    /// coach in the only round that can't wait.
    func prewarm(_ lines: [String]) async {
        prewarmTasks.append(Task { [weak self] in
            await self?.fetchAll(lines)
        })
    }

    /// Abandons anything still downloading.
    ///
    /// Called when the session ends. Without it, quitting during round two leaves
    /// round three's audio being fetched and billed for a round nobody will hear.
    func stopPrewarming() async {
        prewarmTasks.forEach { $0.cancel() }
        prewarmTasks.removeAll()
    }

    private func fetchAll(_ lines: [String]) async {
        let needed = await withTaskGroup(of: String?.self) { group -> [String] in
            for line in Set(lines) {
                group.addTask { [cache] in
                    await cache.contains(voiceID: self.voiceID, model: Self.model, text: line) ? nil : line
                }
            }
            var missing: [String] = []
            for await line in group { if let line { missing.append(line) } }
            return missing
        }

        guard !needed.isEmpty else {
            log.info("All \(lines.count) lines already cached — this session costs nothing to voice")
            return
        }
        log.info("Fetching \(needed.count) of \(Set(lines).count) lines")

        // Keep the order the caller gave us (round one first) and cap
        // concurrency — hammering the API with 60 parallel requests invites a
        // rate limit, and we have minutes of slack anyway.
        let ordered = lines.filter(needed.contains)
        await withTaskGroup(of: Void.self) { group in
            var index = 0
            let limit = 4
            while index < ordered.count {
                if index >= limit { await group.next() }
                let line = ordered[index]
                group.addTask { [weak self] in _ = await self?.audio(for: line) }
                index += 1
            }
        }
    }

    // MARK: - Fetch

    private func audio(for text: String) async -> Data? {
        if let cached = await cache.data(voiceID: voiceID, model: Self.model, text: text) {
            return cached
        }
        guard !Task.isCancelled else { return nil }

        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": Self.model,
        ])

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                log.error("TTS failed (\(status)): \(String(data: data.prefix(200), encoding: .utf8) ?? "", privacy: .public)")
                return nil
            }
            await cache.store(data, voiceID: voiceID, model: Self.model, text: text)
            return data
        } catch {
            log.error("TTS request failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Plays one line at a time and returns when it's finished.
///
/// Separate from `Cornerman` because that one drives a speech synthesizer and
/// this one drives mp3 bytes, but both have to satisfy the same contract: the
/// caller awaits the line, and "pause" can cut it off mid-word.
private nonisolated final class AudioPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {

    private struct State {
        var player: AVAudioPlayer?
        var finished: CheckedContinuation<Void, Never>?
    }

    // Lock rather than an actor: `AVAudioPlayer` calls its delegate back on an
    // arbitrary thread, and every path here must resume the waiting caller
    // exactly once. `takeContinuation` is the only place that hands it out, so
    // a double-resume — which traps — isn't expressible.
    private let state = OSAllocatedUnfairLock(initialState: State())

    func play(_ data: Data) async {
        stop()
        await withCheckedContinuation { continuation in
            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                state.withLock {
                    $0.player = player
                    $0.finished = continuation
                }
                // Set state before playing: a very short line could finish
                // before the assignment and find nobody to resume.
                if !player.play() {
                    takeContinuation()?.resume()
                }
            } catch {
                continuation.resume()
            }
        }
    }

    /// Cuts the line off. Without resuming the waiter here, "pause" would hang
    /// the round forever waiting for audio that was already stopped.
    func stop() {
        state.withLock { $0.player?.stop() }
        takeContinuation()?.resume()
    }

    private func takeContinuation() -> CheckedContinuation<Void, Never>? {
        state.withLock { state in
            state.player = nil
            defer { state.finished = nil }
            return state.finished
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        takeContinuation()?.resume()
    }
}
