import Foundation
import os

/// What's happening right now, so the cornerman answers about *this* round
/// rather than in the abstract.
nonisolated struct CoachingMoment: Sendable {
    var roundIndex: Int
    var totalRounds: Int
    var focus: String
    var secondsLeft: Int
    var isResting: Bool
    var currentCombos: [Combo]
    var level: TrainingProfile.Level
}

/// The cornerman's answer to something you said.
nonisolated struct CornermanReply: Decodable, Sendable, Equatable {
    /// One of the twelve, or "none". This is the safety net *under* the phrase
    /// list — it catches wordings the parser missed — never the primary path.
    let command: String
    /// Said out loud, immediately. Empty when nothing needs saying.
    let reply: String
    /// Replaces the rest of this round's combos. Empty leaves them alone.
    /// This is the part the twelve commands fundamentally cannot do.
    let combos: [Combo]

    /// Maps back onto the existing command path, so an interpreted "kick it off"
    /// runs exactly the same code as a parsed "let's go".
    var resolvedCommand: VoiceCommand? {
        command == "none" ? nil : VoiceCommand(rawValue: command)
    }

    static let nothing = CornermanReply(command: "none", reply: "", combos: [])
}

/// Answers the things the twelve commands can't.
///
/// A protocol for the same reason `Voice` and `VoiceRecognizer` are: the engine
/// shouldn't know a network exists, and the conversation has to be testable
/// without one.
nonisolated protocol Coach: Sendable {
    /// Never throws. Someone mid-round said something we didn't understand; the
    /// worst acceptable outcome is that nothing happens, not that the workout
    /// breaks.
    func interpret(_ utterance: String, during moment: CoachingMoment) async -> CornermanReply
}

/// The real one, backed by Claude.
///
/// This is deliberately the *slow* path. The twelve are parsed on-device in
/// microseconds and must stay that way; anything routed here takes a second or
/// two and needs a signal. That trade only makes sense because what comes back
/// isn't a command — it's a change to what you're drilling, which no amount of
/// local parsing could produce.
nonisolated struct LiveCoach: Coach {

    private let client: ClaudeClient?
    private let log = Logger(subsystem: "Giorgi.Corner", category: "live-coach")

    init(client: ClaudeClient?) {
        self.client = client
    }

    /// Never throws. Someone mid-round said something we didn't understand; the
    /// worst acceptable outcome is that nothing happens, not that the workout
    /// breaks.
    func interpret(_ utterance: String, during moment: CoachingMoment) async -> CornermanReply {
        guard let client else { return .nothing }
        do {
            let reply: CornermanReply = try await client.complete(
                system: Self.systemPrompt,
                user: Self.userPrompt(utterance, moment),
                schema: Self.schema
            )
            log.info("\(utterance, privacy: .public) -> command: \(reply.command, privacy: .public), \(reply.combos.count) combos")
            return reply
        } catch {
            log.error("Couldn't interpret: \(error.localizedDescription, privacy: .public)")
            return .nothing
        }
    }

    // MARK: - Prompt

    private static let systemPrompt = """
        You are a boxing coach working a heavy-bag round with one fighter. They \
        just said something to you, mid-round, out of breath. Answer the way a \
        corner would: immediately, in a sentence or two, and then get back to work.

        Punch numbering: 1 jab, 2 cross, 3 lead hook, 4 rear hook, 5 lead uppercut, \
        6 rear uppercut. Add "b" for a body shot. 1, 3 and 5 are thrown with the \
        lead arm; 2, 4 and 6 with the rear arm.

        Combos have two forms and they are not interchangeable: display is numbers \
        for the screen, separated by " - " only ("1 - 2 - 3b"). spoken is read \
        aloud by a speech synthesizer, so words and never digits, comma-separated \
        for rhythm. Write it the way you'd shout it — "one, two, hook to the body", \
        not "jab cross hook body". It has to land as speech, not as a label. A body \
        shot is always "to the body", spelled out every single time, even in a \
        combo where every punch is one: "jab to the body, cross to the body", never \
        "jab body, cross body".

        You can do three things, in any combination:

        1. Run a command, if that's plainly what they meant. "kick it off" is \
        start. "hold up" is pause. Use "none" when they didn't ask for one.

        2. Change what they're drilling for the rest of this round. This is the \
        thing you can do that a button cannot. "Give me something for the body" \
        means new combos, right now. Eight to twelve of them, all different, real \
        boxing that flows.

        Only change the combos when they actually asked for different work. \
        Wanting more effort is not asking for different combos — if they say \
        "let's go" or "come on", answer them and leave the round alone. New \
        combos when they didn't ask for them just yanks the round out from under \
        someone mid-punch.

        3. Say something back. Keep it to what a corner shouts across a gym — one \
        or two sentences, no preamble, no lists.

        If they tell you something hurts, believe them, and be careful: which side \
        hurts decides everything, and you cannot guess it. "My shoulder hurts" \
        does not tell you whether it's the lead or the rear shoulder, and picking \
        wrong means you just told them to throw the punch that hurts.

        So when they don't say which side, don't assume. Give them work that \
        can't load either shoulder — jabs and body shots, nothing overhand, no \
        uppercuts, no rear hand — and ask which side it is so you can do better \
        next round. When they do say which side, drop every punch thrown with \
        that arm outright: for the rear shoulder that's 2, 4 and 6 gone entirely, \
        for the lead shoulder it's 1, 3 and 5.

        Never coach the pain. Don't tell them to fix their elbow or pack their \
        shoulder — you cannot see them, you don't know why it hurts, and a \
        technique note about an injury is a guess dressed as expertise. Change \
        the work, say what you changed, keep them moving. No medical advice, no \
        telling them to see a doctor: you're their corner, not their physio.

        If they ask how they're doing, answer from the round they're actually in. \
        Never claim to have seen something you can't see: you have no camera and no \
        idea whether their hands are up. Talk about the plan and the work, not \
        their form.

        If you genuinely can't tell what they meant — you caught song lyrics, or \
        half a sentence aimed at someone else — return none, no combos, and an \
        empty reply. Saying nothing is always better than guessing.
        """

    private static func userPrompt(_ utterance: String, _ moment: CoachingMoment) -> String {
        let combos = moment.currentCombos.map(\.display).joined(separator: ", ")
        let phase = moment.isResting
            ? "Resting, \(moment.secondsLeft) seconds until round \(moment.roundIndex + 1)."
            : "Round \(moment.roundIndex) of \(moment.totalRounds), \(moment.focus), \(moment.secondsLeft) seconds left."

        return """
            They said: "\(utterance)"

            \(phase)
            Currently drilling: \(combos.isEmpty ? "nothing yet" : combos)
            They're \(moment.level.rawValue).
            """
    }

    // MARK: - Schema

    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["command", "reply", "combos"],
        "properties": [
            "command": [
                "type": "string",
                // An enum, so the model can't invent an action the engine has no
                // code for. These are exactly `VoiceCommand`'s raw values.
                "enum": ["none"] + VoiceCommand.allCases.map(\.rawValue),
                "description": "Run one of the twelve, if that's clearly what they meant. 'none' otherwise.",
            ],
            "reply": [
                "type": "string",
                "description": "Said out loud right now. One or two sentences, coach's voice. Empty string if nothing needs saying.",
            ],
            "combos": [
                "type": "array",
                "description": "Replaces the rest of this round's combos. 8-12, all different. Empty array to leave the round alone.",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["display", "spoken"],
                    "properties": [
                        "display": [
                            "type": "string",
                            "description": "Numbers for the screen, separated by ' - ' only: '1 - 2 - 3b'.",
                        ],
                        "spoken": [
                            "type": "string",
                            "description": "Words, never digits, comma-separated: 'one, two, hook to the body'.",
                        ],
                    ],
                ],
            ],
        ],
    ]
}
