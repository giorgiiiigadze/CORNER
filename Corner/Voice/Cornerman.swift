import AVFoundation
import os

/// The mouth.
///
/// `AVSpeechSynthesizer` only, deliberately. Personality is the product, but M1 is
/// testing whether voice *control* works — a robot voice is enough to answer that.
/// The `Voice` protocol is the seam ElevenLabs slots into later without the session
/// engine noticing.
nonisolated protocol Voice: Sendable {
    /// Returns when the line has finished playing, or immediately if cancelled.
    func say(_ text: String) async
    /// Cuts a line off mid-word. "Pause" has to freeze mid-combo, so callouts can
    /// never be fire-and-forget.
    func cancel() async
}

@MainActor
final class Cornerman: Voice {

    private let synthesizer = AVSpeechSynthesizer()
    private let coordinator = UtteranceCoordinator()
    private let log = Logger(subsystem: "Giorgi.Corner", category: "cornerman")
    private let voice: AVSpeechSynthesisVoice?

    /// Defaults to whatever the user picked in Settings, falling back to the
    /// best installed voice.
    init(voiceIdentifier: String? = UserDefaults.standard.string(forKey: VoiceCatalog.preferenceKey)) {
        voice = VoiceCatalog.resolve(voiceIdentifier)
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
        // Slightly quicker than default: a corner shouting a combo is not a
        // podcast, and the gap between callouts is what `Tempo` controls.
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
