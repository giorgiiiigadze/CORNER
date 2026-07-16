import Foundation

// These are pure data, shared across the recognizer actor and the main actor alike.
// The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would
// otherwise pin them to the main actor and make every model access a cross-actor
// hop — or, in Swift 6 mode, an error.

/// A single called combination.
///
/// `display` and `spoken` differ on purpose: the screen wants "1 - 2 - slip",
/// the synthesizer needs "one two, slip" or it reads digits like a phone number.
nonisolated struct Combo: Codable, Sendable, Hashable, Identifiable {
    var id: String { display }
    let display: String
    let spoken: String
}

nonisolated struct Round: Codable, Sendable, Identifiable {
    var id: Int { index }
    let index: Int
    let focus: String
    let durationSeconds: Int
    let restSeconds: Int
    let combos: [Combo]

    /// Two or three short corrections, dropped between combos and repeated all
    /// round: "Hands up." "Chin." "Turn it over."
    ///
    /// Not a claim to have seen anything — the app has no camera. These are the
    /// drill. A corner says "hands up" on a rhythm through a round whether or not
    /// the hands just dropped, because the repetition is the point: it stops
    /// being an instruction and becomes a reflex. That works blind, and it's the
    /// difference between coaching and reading combos off a list.
    ///
    /// Deliberately few. You cannot fix five things at once, and a fighter
    /// thinking about five things is thinking about none of them.
    let cues: [String]

    /// Spoken during the rest that follows this round.
    let cornerTalk: String?

    var duration: TimeInterval { TimeInterval(durationSeconds) }
    var rest: TimeInterval { TimeInterval(restSeconds) }
}

nonisolated struct Session: Codable, Sendable, Identifiable {
    let id: String
    let title: String
    /// What the coach says before round one — what today is about and the one
    /// thing to hold onto. Without it the app is a timer with a vocabulary:
    /// it calls combos at you with no reason for any of them.
    let intro: String?
    let rounds: [Round]
}

/// How fast the cornerman calls combos. Mutated by "slower" / "faster".
///
/// This is a value type with clamped steps rather than a raw number so that
/// the engine can't drift into a state where callouts overlap.
nonisolated struct Tempo: Sendable, Equatable {
    /// Seconds between the end of one callout and the start of the next.
    var gap: TimeInterval

    static let `default` = Tempo(gap: 3.5)

    /// The floor is low on purpose. What a person feels is the *cycle* — roughly
    /// two seconds of spoken combo plus this gap — so a 1.5s floor meant the
    /// fastest possible pace was still a combo every 3.5 seconds. That isn't a
    /// flurry, and no amount of asking could get one.
    private static let range: ClosedRange<TimeInterval> = 0.5...7.0

    /// Scaled, not fixed.
    ///
    /// A flat ±0.75s step is perceptually wrong: it's a huge change down at 1s
    /// and nothing at all up at 7s. Worse, one step from the 3.5s default moved
    /// the cycle by ~14% — under the threshold of noticing, which is exactly why
    /// "faster" felt like it did nothing. A multiplier makes every step the same
    /// *proportional* change, and the first one is a ~30% cut.
    private static let scale: Double = 0.7

    mutating func slower() { gap = min(Self.range.upperBound, gap / Self.scale) }
    mutating func faster() { gap = max(Self.range.lowerBound, gap * Self.scale) }

    var isSlowest: Bool { gap >= Self.range.upperBound }
    var isFastest: Bool { gap <= Self.range.lowerBound }
}

nonisolated enum BundledSessions {
    /// Also the offline fallback once Claude generates sessions in M3, so this isn't throwaway.
    static func load() throws -> [Session] {
        guard let url = Bundle.main.url(forResource: "BundledSessions", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Session].self, from: data)
    }
}
