import Foundation

// These are pure data, shared across the recognizer actor and the main actor alike.
// The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would
// otherwise pin them to the main actor and make every model access a cross-actor
// hop — or, in Swift 6 mode, an error.

/// One round of work.
///
/// Deliberately thin. The app used to call a list of combos through this round
/// every few seconds; it doesn't any more. The fighter is told what today is for
/// before the first bell and then works their own way, so a round is a stretch of
/// time with a name on it.
nonisolated struct Round: Codable, Sendable, Identifiable {
    var id: Int { index }
    let index: Int

    /// Two or three words: "Straight punches", "Body shots".
    ///
    /// Shown on screen, never spoken. It's the session's shape — the reason
    /// round four is different from round one — and it costs nothing to display,
    /// where saying it out loud would break the silence the round is for. Glance
    /// at it or ignore it.
    let focus: String

    let durationSeconds: Int
    let restSeconds: Int

    var duration: TimeInterval { TimeInterval(durationSeconds) }
    var rest: TimeInterval { TimeInterval(restSeconds) }
}

nonisolated struct Session: Codable, Sendable, Identifiable {
    let id: String
    let title: String

    /// What the coach says before round one — and now the only thing he says all
    /// session. Everything after this is a bell and a clock, so this line is
    /// carrying the whole plan.
    let intro: String?

    let rounds: [Round]
}

nonisolated enum BundledSessions {
    /// The offline fallback once Claude generates sessions, so this isn't throwaway:
    /// it's what runs in a garage with no signal, which is the pitch.
    static func load() throws -> [Session] {
        guard let url = Bundle.main.url(forResource: "BundledSessions", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Session].self, from: data)
    }
}
