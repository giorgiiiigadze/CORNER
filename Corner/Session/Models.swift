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
    /// Spoken during the rest that follows this round. M3 replaces this with Claude.
    let cornerTalk: String?

    var duration: TimeInterval { TimeInterval(durationSeconds) }
    var rest: TimeInterval { TimeInterval(restSeconds) }
}

nonisolated struct Session: Codable, Sendable, Identifiable {
    let id: String
    let title: String
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

    private static let range: ClosedRange<TimeInterval> = 1.5...7.0
    private static let step: TimeInterval = 0.75

    mutating func slower() { gap = min(Self.range.upperBound, gap + Self.step) }
    mutating func faster() { gap = max(Self.range.lowerBound, gap - Self.step) }

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
