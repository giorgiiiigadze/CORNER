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

    func start() async throws
    func stop() async

    /// Suspends recognition while the cornerman is speaking, so the app
    /// doesn't hear its own callouts and obey itself.
    func setMuted(_ muted: Bool) async
}
