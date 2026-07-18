import Foundation
import os

/// Reads intent out of speech the phrase list didn't catch.
///
/// Exists as a protocol so the engine never learns whether a network is
/// involved, and so the wiring can be tested without one.
nonisolated protocol IntentReader: Sendable {
    /// The command this speech meant, or nil if it wasn't for us.
    func interpret(_ heard: String) async -> VoiceCommand?
}

/// The second pass. Claude reads what the fighter actually meant.
///
/// `CommandParser` is still the first pass and still handles nearly everything:
/// it's instant, free, and works in a garage with no signal, which is the pitch.
/// This runs only on what the phrase list didn't recognise, which is where the
/// list's whole problem lives — "stop" isn't in it, and neither is "hang on, my
/// shoulder's gone", and both plainly mean pause. A phrase list can only ever be
/// extended toward the things people say; it can't be finished.
///
/// The cost of this arrangement is honest: a phrase that hits the list acts in
/// microseconds, and one that needs Claude acts in about a second. That's the
/// right way round — the common words stay instant, and the sentences nobody
/// anticipated work at all instead of not working.
nonisolated struct CommandInterpreter: IntentReader {

    private let client: ClaudeClient?
    private let log = Logger(subsystem: "Giorgi.Corner", category: "intent")

    /// Nil client — no key, or offline — means the phrase list is the whole
    /// story, exactly as it was before this existed.
    init(client: ClaudeClient?) {
        self.client = client
    }

    func interpret(_ heard: String) async -> VoiceCommand? {
        guard let client else { return nil }

        do {
            let reading: Reading = try await client.complete(
                system: Self.systemPrompt,
                user: heard,
                schema: Self.schema
            )
            if let command = reading.command.voiceCommand {
                log.debug("""
                    Read \(heard, privacy: .public) -> \
                    \(command.rawValue, privacy: .public)
                    """)
            }
            return reading.command.voiceCommand
        } catch {
            // Never throws outward: a session must not break because a sentence
            // couldn't be classified. The fighter says it again, or says one of
            // the words the parser already knows.
            log.error("Couldn't read intent: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Prompt

    /// States the situation and the bias, and trusts the model with the rest —
    /// the same reason the session prompt isn't a list of steps.
    ///
    /// The bias toward `none` is the entire safety story. This runs on *every*
    /// sentence the parser didn't recognise, which in a gym means music, someone
    /// else's conversation, and a fighter swearing at a bag. None of that is an
    /// instruction, and a session that obeys the room is worse than one that
    /// needs a word repeated.
    private static let systemPrompt = """
        A fighter is doing a heavy-bag round with their phone propped somewhere \
        across the room. They control it by talking to it. You are reading one \
        thing the microphone picked up, and deciding whether it was an \
        instruction to the app — and if so, which one.

        The commands, and what someone means by them:

        - start: begin the session. They're ready.
        - pause: stop the clock for now. "Stop", "hang on", "give me a second", \
        "my shoulder's gone" — anything that means the work is halting but the \
        session isn't over.
        - resume: start the clock again after a pause.
        - next_round: skip ahead. They're done with this round early.
        - one_more_round: add a round to the end.
        - time_check: how long is left in this round.
        - end_session: the workout is over now.
        - confirm: yes, to a question the app asked.
        - cancel: no, to a question the app asked.
        - none: it wasn't an instruction.

        Now the thing that decides whether this is any good.

        The microphone hears the whole room — music, other people talking, the \
        fighter breathing and swearing at the bag and muttering to themselves. \
        Almost all of it is not for you. You are reading it anyway, because the \
        app couldn't recognise it, and "couldn't recognise it" is what talking to \
        yourself sounds like from here.

        So answer none unless the sentence was plainly aimed at the app, as an \
        instruction, right now. Not "mentions resting" — *asks to rest*. "I'm \
        dying here" is a man talking to himself. "Give me a minute" is a man \
        talking to you. If you're weighing it up, it's none.

        end_session ends the workout, so it needs to be unmistakable. "I'm done" \
        after the last round is done. "I'm done with this round" is not — that's \
        next_round. "I'm so done" is someone suffering out loud, and it's none.

        confirm and cancel are answers, not instructions. The app asks "You \
        sure?" before it ends a session, and "yeah, I'm done" or "no, keep \
        going" are how a person answers that. Read them as answers when they're \
        shaped like one. If nothing was asked they do nothing, so the cost of \
        reading one wrong is a word that lands on silence.
        """

    // MARK: - Schema

    // Computed rather than stored, because `[String: Any]` isn't `Sendable` —
    // `Any` could be anything, so a shared `static let` is something Swift 6
    // can't prove is safe to read from two threads. Building it fresh at each
    // call site means there's nothing shared to reason about. It's built once
    // per API call, which is nothing next to the request it's attached to.
    private static var schema: [String: Any] { [
        "type": "object",
        "additionalProperties": false,
        "required": ["command"],
        "properties": [
            "command": [
                "type": "string",
                "enum": [
                    "start", "pause", "resume", "next_round",
                    "one_more_round", "time_check", "end_session",
                    "confirm", "cancel", "none",
                ],
                "description": "The instruction this was, or none if it wasn't one.",
            ],
        ],
    ] }

    private struct Reading: Decodable {
        /// Its own type rather than `VoiceCommand` because it has a case
        /// `VoiceCommand` must never have: `none` is the answer most of the
        /// time, and it isn't a command.
        enum Intent: String, Decodable {
            case start, pause, resume, confirm, cancel
            case nextRound = "next_round"
            case oneMoreRound = "one_more_round"
            case timeCheck = "time_check"
            case endSession = "end_session"
            case none

            var voiceCommand: VoiceCommand? {
                switch self {
                case .start: .start
                case .pause: .pause
                case .resume: .resume
                case .nextRound: .nextRound
                case .oneMoreRound: .oneMoreRound
                case .timeCheck: .timeCheck
                case .endSession: .endSession
                case .confirm: .confirm
                case .cancel: .cancel
                case .none: nil
                }
            }
        }

        let command: Intent
    }
}
