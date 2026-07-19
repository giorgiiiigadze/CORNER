import Foundation
import SwiftData

/// The session waiting to be trained — persisted so it survives a relaunch.
///
/// Named `TodaySession` rather than `Session` on purpose: `Session` is already
/// taken by the `Codable`/`Sendable` struct in `Models.swift` that Claude's JSON
/// decodes into and that `SessionEngine` runs. That one has to stay a value
/// type — it crosses actors, and a `@Model` class is neither `Sendable` nor
/// decodable from the API response. So this is a second, smaller thing: not the
/// session's plan, but the fact that a plan is sitting on the Home screen
/// unstarted.
///
/// It stores what the card draws and nothing else. The rounds themselves live
/// in `plan`, encoded, because the card never reads them and a relational
/// model of rounds would be a schema to migrate for no gain today.
@Model
final class TodaySession {

    /// Matches the underlying `Session.id`, so a stored card and the plan it
    /// came from can always be reconciled.
    /// Whose plan this is. See `TrainingRecord.userID` — same rule, same reason.
    var userID: String = ""

    var sessionID: String = ""

    /// Two or three words — what today is for. The card's headline.
    var focus: String = ""

    /// The one line under the headline. Claude's `intro` when there is one.
    var subtitle: String = ""

    var roundCount: Int = 0

    /// Rounds and rests, planned rather than measured — nothing has happened yet.
    var totalSeconds: Int = 0

    /// When it was written. The card is only "today's" while this is today;
    /// deciding that is the caller's business, but it can't decide without this.
    var generatedAt: Date = Date()

    /// True when Claude wrote it, false when it came from the bundled JSON.
    /// The app says which out loud elsewhere and shouldn't lose the fact here.
    var fromClaude: Bool = false

    /// The full plan, encoded. Kept whole so starting a session doesn't need a
    /// second round-trip to the generator after a relaunch.
    var plan: Data?

    init(
        userID: String = "",
        sessionID: String,
        focus: String,
        subtitle: String,
        roundCount: Int,
        totalSeconds: Int,
        generatedAt: Date = .now,
        fromClaude: Bool = false,
        plan: Data? = nil
    ) {
        self.userID = userID
        self.sessionID = sessionID
        self.focus = focus
        self.subtitle = subtitle
        self.roundCount = roundCount
        self.totalSeconds = totalSeconds
        self.generatedAt = generatedAt
        self.fromClaude = fromClaude
        self.plan = plan
    }
}

extension TodaySession {

    /// Builds the stored card from a freshly planned session.
    ///
    /// The focus is the first round's — the session's opening intent, and the
    /// closest thing the plan has to a one-word answer for "what's today?".
    convenience init(planned: PlannedSession, userID: String) {
        let session = planned.session
        self.init(
            userID: userID,
            sessionID: session.id,
            focus: session.rounds.first?.focus ?? session.title,
            subtitle: session.intro ?? session.title,
            roundCount: session.rounds.count,
            totalSeconds: session.rounds.reduce(0) { $0 + $1.durationSeconds + $1.restSeconds },
            generatedAt: .now,
            fromClaude: planned.origin.isClaude,
            plan: try? JSONEncoder().encode(session)
        )
    }

    /// The plan back out, or `nil` if it was never stored or no longer decodes.
    /// A card that can't produce its session is a card that can't be started —
    /// the caller has to be able to tell.
    var session: Session? {
        guard let plan else { return nil }
        return try? JSONDecoder().decode(Session.self, from: plan)
    }
}

/// `nonisolated` to match `SessionOrigin` itself. The project defaults to
/// `MainActor` isolation, which would otherwise pin this one property to the
/// main actor while the type it extends is free of it — and then reading it
/// from anywhere else is a Swift 6 error.
extension SessionOrigin {
    nonisolated var isClaude: Bool {
        if case .claude = self { return true }
        return false
    }
}
