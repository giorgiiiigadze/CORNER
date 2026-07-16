import Foundation

/// The twelve. Taught during onboarding, listed in Settings, never needed on screen.
nonisolated enum VoiceCommand: String, Sendable, CaseIterable, Hashable {
    case start
    case pause
    case resume
    case stop
    case slower
    case faster
    case again
    case skip
    case nextRound
    case oneMoreRound
    case timeCheck
    case endSession
}

/// The ears.
///
/// This protocol exists so the session engine never learns which speech framework
/// is underneath it, and so a recognizer can be faked in tests without a microphone.
nonisolated protocol VoiceRecognizer: Sendable {
    /// Commands as they are heard. Finishes when `stop()` is called.
    var commands: AsyncStream<VoiceCommand> { get async }

    /// Raw transcript text, whether or not it parsed into a command.
    ///
    /// This is the instrument the gym test needs: without seeing what the phone
    /// actually heard, a missed command and a misheard one look identical, and
    /// "it didn't work" is unfalsifiable.
    var transcripts: AsyncStream<String> { get async }

    /// Things said that the twelve commands don't cover — "give me something for
    /// the body", "my shoulder hurts".
    ///
    /// Everything on this stream costs a network round-trip and real money, so
    /// it's gated hard: finalized results only, never half-heard volatile ones,
    /// and never a single stray word. The twelve never appear here — they're
    /// answered on-device and instantly, and must stay that way.
    var unhandled: AsyncStream<String> { get async }

    func start() async throws
    func stop() async

    /// Tells the recognizer what the cornerman is saying right now, or nil when
    /// he's quiet.
    ///
    /// Not a mute. Recognition keeps running throughout — the recognizer uses the
    /// line to discard the app's own voice arriving back through the microphone,
    /// while still hearing everything else. That's the difference between a coach
    /// you can interrupt and one who talks until he's finished.
    func setSpeaking(_ line: String?) async
}
