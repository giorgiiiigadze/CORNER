import AVFoundation
import os

/// The mouth.
///
/// The `Voice` protocol is the seam ElevenLabs sits behind, so the session engine
/// never learns whether a line came off the network or out of the phone.
nonisolated protocol Voice: Sendable {
    /// Returns when the line has finished playing, or immediately if cancelled.
    func say(_ text: String) async

    /// Cuts a line off mid-word.
    ///
    /// Only used to shut him up when a session ends. Nothing else cancels a line
    /// any more: he speaks before the bell and then goes quiet, so an interruption
    /// has nothing to save.
    func cancel() async

    /// A batch of lines that will be needed soon.
    ///
    /// This is the seam that makes a cloud voice usable at a bell: the session is
    /// known ahead of time, so audio is fetched during the slack — the intro while
    /// the fighter wraps their hands, round N+1 while they work round N. On-device
    /// voices ignore it.
    func prewarm(_ lines: [String]) async

    /// Stop fetching anything not yet needed. Called when a session ends, so an
    /// abandoned workout doesn't keep paying for rounds nobody will hear.
    func stopPrewarming() async
}

extension Voice {
    /// `Cornerman` synthesizes locally and instantly — nothing to warm, and so
    /// nothing to stop.
    func prewarm(_ lines: [String]) async {}
    func stopPrewarming() async {}
}

@MainActor
final class Cornerman: Voice {

    private let synthesizer = AVSpeechSynthesizer()
    private let coordinator = UtteranceCoordinator()
    private let log = Logger(subsystem: "Giorgi.Corner", category: "cornerman")
    private let voice: AVSpeechSynthesisVoice?

    /// No voice to pass in: Settings offers ElevenLabs voices only, so there's no
    /// on-device choice to honour. This is the fallback, and it takes the best
    /// thing installed.
    init() {
        voice = VoiceCatalog.best()
        synthesizer.delegate = coordinator
        log.info("Voice: \(self.voice?.name ?? "system default", privacy: .public)")
    }

    nonisolated func say(_ text: String) async {
        await MainActor.run { self.enqueue(text) }
        await coordinator.waitForIdle()
    }

    nonisolated func cancel() async {
        await MainActor.run { _ = self.synthesizer.stopSpeaking(at: .immediate) }
    }

    private func enqueue(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // Slightly quicker than default: a corner talking to you between rounds
        // is not a podcast.
        utterance.rate = 0.54
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0
        coordinator.expect(utterance)
        synthesizer.speak(utterance)
    }

    /// Prefers a premium or enhanced voice when the user has downloaded one —
    /// the compact default is the single biggest thing that makes TTS sound cheap.
    private static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }

        return candidates.first { $0.quality == .premium }
            ?? candidates.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: language)
    }
}

/// Bridges the synthesizer's delegate callbacks — which arrive on an unspecified
/// queue — back into `async`.
private final class UtteranceCoordinator: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    private struct State {
        var pending = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func expect(_ utterance: AVSpeechUtterance) {
        state.withLock { $0.pending += 1 }
    }

    func waitForIdle() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                guard state.pending > 0 else { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    private func settle() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.pending = max(0, state.pending - 1)
            guard state.pending == 0 else { return [] }
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        settle()
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        settle()
    }
}
