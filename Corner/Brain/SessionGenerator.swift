import Foundation
import os

/// What the cornerman knows about you. Feeds the prompt.
nonisolated struct TrainingProfile: Sendable, Codable, Equatable {
    enum Level: String, Sendable, Codable, CaseIterable {
        case beginner, intermediate, advanced
    }

    /// Where the user's self-declared level lives. The one thing about them the
    /// app can't observe from a session, so it's the one thing Settings asks.
    static let levelKey = "trainingLevel"

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

    /// Drops sentences that report on a fighter nobody watched.
    ///
    /// The prompt forbids these at length and the model writes them anyway —
    /// "You're chaining them now" — because it knows what a corner sounds like,
    /// and a real corner watches. A prompt is a request; this is the guarantee,
    /// for the same reason `distinct` exists.
    ///
    /// Narrow on purpose, and it only ever deletes. A talk mangled into nonsense
    /// would be worse than one that overclaims, and what's left after a cut is
    /// the forward-facing half — the part worth hearing anyway.
    static func withoutSightClaims(_ talk: String) -> String {
        let text = talk as NSString
        var kept: [String] = []
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: .bySentences
        ) { sentence, _, _, _ in
            guard let sentence else { return }
            guard !claimsSight(sentence) else { return }
            kept.append(sentence.trimmingCharacters(in: .whitespaces))
        }
        return kept.joined(separator: " ")
    }

    /// "You're …ing" is the tell: the model narrating a round it did not see.
    private static func claimsSight(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased().trimmingCharacters(in: .whitespaces)
        let openers = ["you're ", "you are ", "you've ", "you look "]
        guard let opener = openers.first(where: { lowered.hasPrefix($0) }) else { return false }

        // "You've been working the jab all week" is history we actually have.
        if opener == "you've " { return false }

        // A participle in the first few words is what makes it a report of the
        // present. "You're going to feel this" is a promise about the next round,
        // not a claim about this one, and it's the one common false match.
        return lowered.dropFirst(opener.count)
            .split(separator: " ")
            .prefix(3)
            .contains { $0.hasSuffix("ing") && $0 != "going" }
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
        - display: for the screen, read across a room at a glance. Every beat \
        separated by " - " and nothing else: "1 - 2 - 3b", "slip - 1 - 2", \
        "1 - slip - 2 - 3b". Punches are always digits, never words — "jab - 2" \
        is wrong, "1 - 2" is right. Defensive beats are the one exception and are \
        spelled out, because they have no number: slip, roll, pivot, step. Never \
        commas.
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

        First, the hard constraint, because it cuts against everything you know \
        about coaching.

        You cannot see the fighter. There is no camera. You are writing this \
        before they have thrown a single punch, so you do not know whether their \
        hands are up, whether the jab was lazy, or how the last round went. There \
        was no last round yet.

        So never write a line that reports on them. Not "you're dropping your \
        right hand", not "you're slipping clean", not "that jab is snapping now", \
        not "you're getting tired". Every one of those is a guess, and the first \
        one that's wrong — they were slipping badly, and you said it looked clean \
        — tells them you aren't watching. After that, every true thing you say \
        reads as a guess too. It is the one mistake here you cannot take back.

        The tell is the word "you're" followed by what they're doing. If a line \
        has it, delete the line.

        This costs you less than it sounds. Face forward instead of backward: a \
        corner is most useful about the round that hasn't happened. "Next round \
        we chain them, don't rush the slip" needs no camera and is worth more \
        than any commentary on the round just finished. Talk about the plan, the \
        work, and what they've told you. Your authority comes from attention, not \
        from narrating.

        Now the voice, which matters more than any of the above.

        Economy. Every word earns its place. Real boxing coaching is terse to the \
        point of sounding cryptic to outsiders — single cues dropped into the \
        rhythm of the work, not speeches. "Hands up." "Chin." "Turn it over." \
        "There it is." "Again." The authority is in the calm, never the volume. \
        Warm, and completely unwilling to let anything slide. Not a cheerleader, \
        not a drill sergeant.

        One thing at a time. You cannot fix five things at once, and a fighter \
        thinking about five things is thinking about none of them.

        The intro is two sentences. What today is for, and the one thing to hold \
        onto. If they've been working on something recently, connect today to it. \
        Don't greet them, don't list the rounds, don't explain the notation. Say \
        the plan and get out of the way.

        Cues are the round's two or three corrections, and they are the heart of \
        this. Three to five words each, tied to that round's focus: "Hands up." \
        "Chin down." "Turn the hip over." "Snap it back." They get repeated all \
        round, on purpose — repetition is how an instruction becomes a reflex. So \
        write them to survive being heard eight times. No sentences, no \
        explanations, no variety for its own sake. Two or three. Not five.

        Corner talk is 15 seconds spoken during the rest, and it points forward, \
        never back. Say what the next round is and the one thing to hold onto in \
        it. "Next round is the same jab, just faster. Don't let it get lazy when \
        you're tired." That needs no camera. Not "great work, keep it up", and \
        not a report on the round they just finished — you didn't see it. Second \
        person, out loud, no lists, no preamble.
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
        "required": ["title", "intro", "rounds"],
        "properties": [
            "title": [
                "type": "string",
                "description": "Two or three words. 'Power day', 'Sharpen the jab'.",
            ],
            "intro": [
                "type": "string",
                "description": "Spoken before the first bell, ~15 seconds. What today is for and the one thing to hold onto throughout. Two or three sentences, no greeting, no list.",
            ],
            "rounds": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["focus", "combos", "cues", "cornerTalk"],
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
                        "cues": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Two or three corrections for this round, three to five words each: 'Hands up.' 'Turn the hip over.' Repeated between combos all round, so write them to survive being heard eight times. Never claims about what the fighter is doing — there is no camera.",
                        ],
                        "cornerTalk": [
                            "type": "string",
                            "description": "~15 seconds spoken during the rest after this round: one thing to carry into the next round, drawn from the plan. Never an observation — there is no camera.",
                        ],
                    ],
                ],
            ],
        ],
    ]
}

private extension String {
    /// Nil when there's nothing left to say, so callers can't hand a synthesizer
    /// an empty line to read.
    var ifNotEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

// MARK: - Wire types

/// What Claude returns. Deliberately not `Session` — the model decides the
/// coaching, the app decides identity and ordering.
private nonisolated struct GeneratedSession: Decodable {
    nonisolated struct GeneratedRound: Decodable {
        let focus: String
        let combos: [Combo]
        let cues: [String]
        let cornerTalk: String
    }

    let title: String
    let intro: String
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
            intro: intro,
            rounds: rounds.enumerated().map { index, round in
                let isLast = index == rounds.count - 1
                return Round(
                    index: index + 1,
                    focus: round.focus,
                    durationSeconds: roundSeconds,
                    // The last round has nothing to rest for.
                    restSeconds: isLast ? 0 : restSeconds,
                    combos: Self.distinct(round.combos),
                    // Three at most. The prompt asks for two or three, but a
                    // prompt is a request — and a round that cycles six cues
                    // teaches none of them, which is the one thing cues exist
                    // to do.
                    cues: Array(round.cues.prefix(3)),
                    // Nil rather than empty when every sentence claimed sight:
                    // a silent rest is honest, and an empty string would be sent
                    // to the synthesizer as a line to read.
                    cornerTalk: isLast ? nil : SessionGenerator.withoutSightClaims(round.cornerTalk).ifNotEmpty
                )
            }
        )
    }
}
