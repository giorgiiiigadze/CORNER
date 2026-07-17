import Foundation

/// The seven, and the two answers. Taught during onboarding, listed in Settings,
/// never needed on screen.
///
/// There were twelve. `skip`, `again`, `stop`, `slower` and `faster` all meant
/// "do something to the combo callouts" — skip this one, repeat that one, pace
/// them differently — and there are no callouts now. They're gone rather than
/// left as no-ops: a command that's understood and does nothing is worse than one
/// that isn't understood, because the fighter can't tell which happened.
///
/// `confirm` and `cancel` are not commands and never act alone — they're answers
/// to the one question the app asks. Said into a running round they do nothing,
/// which is what makes it safe for words this common to be in the grammar at all.
nonisolated enum VoiceCommand: String, Sendable, CaseIterable, Hashable {
    case start
    case pause
    case resume
    case nextRound
    case oneMoreRound
    case timeCheck
    case endSession
    case confirm
    case cancel

    /// Whether this is an answer rather than an instruction.
    var answersAQuestion: Bool {
        self == .confirm || self == .cancel
    }
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

    /// Finished sentences the phrase list didn't recognise — candidates for
    /// `IntentReader`, which is slow and costs money and therefore never sees a
    /// word the parser could handle itself.
    ///
    /// Finished ones only, and that's the difference between a feature and a
    /// bill: volatile results arrive many times a second, so yielding those
    /// would be a network call per syllable of a sentence nobody was saying to
    /// the app anyway.
    var unmatched: AsyncStream<String> { get async }

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
