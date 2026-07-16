import Foundation
import os

/// What the cornerman knows about you. Feeds the prompt.
nonisolated struct TrainingProfile: Sendable, Codable, Equatable {
    enum Level: String, Sendable, Codable, CaseIterable {
        case beginner, intermediate, advanced
    }

    var level: Level = .beginner
    /// Round focuses from recent sessions, newest first. Keeps session 20 from
    /// being session 1 — the whole reason this feature exists.
    var recentFocuses: [String] = []
    /// Free-text notes the app has learned, e.g. "said 'too fast' twice on hooks".
    var notes: [String] = []

    static let `default` = TrainingProfile()
}

nonisolated struct SessionRequest: Sendable {
    var rounds: Int = 6
    var roundSeconds: Int = 180
    var restSeconds: Int = 60
    /// "technique", "power", "conditioning", "freestyle" — free text, it's a prompt.
    var focus: String = "balanced"
    var profile: TrainingProfile = .default
}

/// Where a session came from. Surfaced in the UI, because "the AI wrote this for
/// you" and "this is one of two files we shipped" are different products and the
/// user deserves to know which one they got.
nonisolated enum SessionOrigin: Sendable, Equatable {
    case claude
    case bundled(reason: String)
}

nonisolated struct PlannedSession: Sendable {
    let session: Session
    let origin: SessionOrigin
}

/// Turns a request into a session, via Claude when possible and the bundled
/// JSON when not.
nonisolated struct SessionGenerator: Sendable {

    private let client: ClaudeClient?
    private let log = Logger(subsystem: "Giorgi.Corner", category: "brain")

    init(client: ClaudeClient?) {
        self.client = client
    }

    /// Never throws.
    ///
    /// A session that fails to generate must not stop a workout — the user is
    /// already wrapped up in a garage with no signal. Every failure path lands
    /// on the bundled sessions and says why.
    func plan(_ request: SessionRequest) async -> PlannedSession {
        guard let client else {
            return fallback(reason: "No API key — using a bundled session.")
        }

        do {
            let generated: GeneratedSession = try await client.complete(
                system: Self.systemPrompt,
                user: Self.userPrompt(for: request),
                schema: Self.schema
            )
            // Durations come from the request, not the model — the user picked
            // them, and the schema deliberately doesn't let Claude override.
            let session = generated.toSession(
                roundSeconds: request.roundSeconds,
                restSeconds: request.restSeconds
            )
            return PlannedSession(session: session, origin: .claude)
        } catch {
            log.error("Generation failed: \(error.localizedDescription, privacy: .public)")
            return fallback(reason: error.localizedDescription)
        }
    }

    private func fallback(reason: String) -> PlannedSession {
        let sessions = (try? BundledSessions.load()) ?? []
        guard let session = sessions.randomElement() else {
            // Bundled JSON is in the app bundle; if it's gone the build is broken.
            fatalError("BundledSessions.json missing from the app bundle")
        }
        return PlannedSession(session: session, origin: .bundled(reason: reason))
    }

    // MARK: - Prompt

    /// The cornerman.
    ///
    /// Deliberately states the goal and the constraints rather than enumerating
    /// steps: over-prescriptive prompts written for older models measurably
    /// reduce output quality on current ones.
    private static let systemPrompt = """
        You are a boxing coach writing the plan for one heavy-bag session that a \
        cornerman will call out loud, live, while the fighter works. You are not \
        writing an article. Every word you produce is either spoken into someone's \
        ear mid-round or shown in huge type on a phone across the room.

        Punch numbering: 1 jab, 2 cross, 3 lead hook, 4 rear hook, 5 lead uppercut, \
        6 rear uppercut. Add "b" for a body shot (2b is a cross to the body). \
        Defensive beats — slip, roll, pivot, step — are combined freely with punches.

        Each combo has two forms and they are not interchangeable:
        - display: numbers for the screen, separated by " - " and nothing else. \
        "1 - 2 - 3b". Never commas, never words.
        - spoken: what the voice says out loud. A speech synthesizer reads this \
        literally, so "1-2" has to be written "one, two" or it comes out as a phone \
        number. Those commas are the rhythm — they become the pauses the fighter \
        punches to, so a combo without them lands as mush. Always write them.

        Combos must be real boxing that flows: the stance and weight at the end of \
        one punch has to permit the next. A jab-hook off the same hand doesn't work; \
        1-2-3 does. Vary length within a round so it doesn't become a metronome.

        Give each round eight to twelve combos, and make every one of them \
        different. A three-minute round is around thirty-five callouts drawn from \
        that list, so a short list or a repeated entry is one the fighter hears \
        over and over until the round stops sounding like coaching.

        Corner talk is 15 seconds spoken during the rest — the most valuable 15 \
        seconds in the sport. A real corner gives one specific correction of \
        something they just saw, and one thing to do about it in the next round. \
        Not "great work, keep it up". Something like "You're dropping the right \
        hand coming back from the hook. Next round I want it glued to your chin." \
        Write in the coach's voice, second person, out loud. No lists, no preamble.
        """

    private static func userPrompt(for request: SessionRequest) -> String {
        var lines = [
            "Write a \(request.rounds)-round session.",
            "Rounds are \(request.roundSeconds) seconds with \(request.restSeconds) seconds of rest.",
            "Today's emphasis: \(request.focus).",
            "The fighter is \(request.profile.level.rawValue).",
        ]

        if !request.profile.recentFocuses.isEmpty {
            let recent = request.profile.recentFocuses.prefix(8).joined(separator: ", ")
            lines.append("""
                They already drilled these recently, newest first: \(recent). \
                Build on that rather than repeating it — this session should feel \
                like the next one, not another one.
                """)
        } else {
            lines.append("This is their first session, so establish the basics.")
        }

        if !request.profile.notes.isEmpty {
            lines.append("What you know about them: \(request.profile.notes.joined(separator: "; ")).")
        }

        lines.append("""
            Give each round a focus short enough to read at a glance — two or three \
            words. Give the session a title of the same length. Round one should \
            warm them up and the last round should be the hardest.
            """)

        return lines.joined(separator: "\n")
    }

    // MARK: - Schema

    /// Constrains the response so `JSONDecoder` is guaranteed to succeed.
    ///
    /// Every object needs `additionalProperties: false` and a complete `required`
    /// list. Note what's *absent*: ids and round numbers. Those are the app's
    /// business, not the model's — there's no reason to let it get numbering
    /// wrong when a loop index is exact.
    private static let schema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["title", "rounds"],
        "properties": [
            "title": [
                "type": "string",
                "description": "Two or three words. 'Power day', 'Sharpen the jab'.",
            ],
            "rounds": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["focus", "combos", "cornerTalk"],
                    "properties": [
                        "focus": [
                            "type": "string",
                            "description": "Two or three words, readable across a room.",
                        ],
                        "combos": [
                            "type": "array",
                            // Structured outputs don't support minItems/maxItems,
                            // so the count and the no-duplicates rule can only be
                            // asked for in the prompt — not enforced here.
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "required": ["display", "spoken"],
                                "properties": [
                                    "display": [
                                        "type": "string",
                                        "description": "Numbers for the screen, separated by ' - ' only: '1 - 2 - 3b'. No commas, no words.",
                                    ],
                                    "spoken": [
                                        "type": "string",
                                        "description": "Said aloud by a speech synthesizer. Words, never digits, comma-separated for rhythm: 'one, two, hook to the body'.",
                                    ],
                                ],
                            ],
                        ],
                        "cornerTalk": [
                            "type": "string",
                            "description": "~15 seconds spoken during the rest after this round: one specific correction, one instruction for the next round.",
                        ],
                    ],
                ],
            ],
        ],
    ]
}

// MARK: - Wire types

/// What Claude returns. Deliberately not `Session` — the model decides the
/// coaching, the app decides identity and ordering.
private nonisolated struct GeneratedSession: Decodable {
    nonisolated struct GeneratedRound: Decodable {
        let focus: String
        let combos: [Combo]
        let cornerTalk: String
    }

    let title: String
    let rounds: [GeneratedRound]

    /// Drops repeated combos, keeping the first of each and the round's order.
    ///
    /// The prompt asks for distinct combos, but a prompt is a request and this
    /// is a guarantee. Observed in the wild: a five-combo round where the bare
    /// jab appeared three times, which the engine would then have served on a
    /// loop for three minutes.
    static func distinct(_ combos: [Combo]) -> [Combo] {
        var seen = Set<String>()
        return combos.filter { seen.insert($0.display).inserted }
    }

    func toSession(roundSeconds: Int, restSeconds: Int) -> Session {
        Session(
            id: UUID().uuidString,
            title: title,
            rounds: rounds.enumerated().map { index, round in
                let isLast = index == rounds.count - 1
                return Round(
                    index: index + 1,
                    focus: round.focus,
                    durationSeconds: roundSeconds,
                    // The last round has nothing to rest for.
                    restSeconds: isLast ? 0 : restSeconds,
                    combos: Self.distinct(round.combos),
                    cornerTalk: isLast ? nil : round.cornerTalk
                )
            }
        )
    }
}
