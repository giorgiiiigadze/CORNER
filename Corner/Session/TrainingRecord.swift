import Foundation
import SwiftData

/// One finished session, kept so the next one can be different.
///
/// This is the moat in one file. Without it the cornerman has amnesia: it
/// writes a good session, then meets you again as a stranger. A timer app can
/// copy everything else in this project — it cannot copy knowing that you
/// drilled hooks on Tuesday and asked twice for it to slow down.
@Model
final class TrainingRecord {
    /// Names this session everywhere, on every device.
    ///
    /// Minted here rather than by the server, because the phone has to be able
    /// to record a session before it has ever reached the network — a gym with
    /// no signal is the normal case. The row upserts under this id whenever the
    /// upload does happen, so a session can't be stored twice.
    var remoteID: UUID = UUID()

    /// Whether the server has this one yet. False for everything trained
    /// offline, and for everything recorded before sync existed.
    var isSynced: Bool = false

    /// Whose session this was.
    ///
    /// Empty means it predates accounts. Those are claimed by the first user to
    /// sign in after the upgrade — which is right for a single-user device and
    /// is the only answer available, since nothing recorded an owner at the time.
    var userID: String = ""

    var date: Date = Date()
    var title: String = ""
    /// The focus of each round, in order. The strongest signal we have about
    /// what this person has actually been working on.
    var focuses: [String] = []
    var roundsPlanned: Int = 0
    var roundsCompleted: Int = 0
    /// True when they said "end session" rather than finishing the last round.
    var endedEarly: Bool = false

    /// Seconds the session ran — rounds and rests, not pauses. Measured, not planned.
    ///
    /// Optional, and that's the whole point: `nil` means this session predates
    /// the app recording it, which is a different fact from a session where you
    /// trained for zero seconds. Defaulting to 0 would quietly fold old sessions
    /// into every total and average as if you'd stood there doing nothing, and
    /// nothing downstream could ever tell the difference. History you didn't
    /// record is missing, not zero.
    var sessionSeconds: Int?

    /// How often the clock was stopped. Real evidence the session was pitched
    /// wrong, rather than a guess from how it looked on paper.
    ///
    /// Optional for the same reason as `sessionSeconds`.
    var pauseCount: Int?

    init(
        remoteID: UUID = UUID(),
        userID: String = "",
        date: Date = .now,
        title: String,
        focuses: [String],
        roundsPlanned: Int,
        roundsCompleted: Int,
        endedEarly: Bool,
        sessionSeconds: Int? = nil,
        pauseCount: Int? = nil
    ) {
        self.remoteID = remoteID
        self.userID = userID
        self.date = date
        self.title = title
        self.focuses = focuses
        self.roundsPlanned = roundsPlanned
        self.roundsCompleted = roundsCompleted
        self.endedEarly = endedEarly
        self.sessionSeconds = sessionSeconds
        self.pauseCount = pauseCount
    }

    convenience init(summary: SessionSummary, userID: String, date: Date = .now) {
        self.init(
            userID: userID,
            date: date,
            title: summary.title,
            focuses: summary.focuses,
            roundsPlanned: summary.roundsPlanned,
            roundsCompleted: summary.roundsCompleted,
            endedEarly: summary.endedEarly,
            sessionSeconds: summary.sessionSeconds,
            pauseCount: summary.pauseCount
        )
    }
}

/// What the engine observed. Kept separate from `TrainingRecord` so the engine
/// never touches SwiftData and stays testable without a store.
nonisolated struct SessionSummary: Sendable, Equatable {
    var title: String
    var focuses: [String]
    var roundsPlanned: Int
    var roundsCompleted: Int
    var endedEarly: Bool
    /// Not optional here, unlike on `TrainingRecord`: the engine watched the
    /// whole session, so it always knows. Only stored history can be unsure.
    var sessionSeconds: Int = 0
    var pauseCount: Int = 0
}

// MARK: - History → profile

extension TrainingProfile {

    /// Builds the profile Claude sees from what actually happened.
    ///
    /// Everything derived here is an observation, not an inference about the
    /// person: what they drilled, what they asked for, what they didn't finish.
    /// The things we can't observe — their skill, their bad rib — aren't guessed
    /// from a session count; they're asked for, and arrive as `level` and
    /// `standing` rather than being invented in this function.
    static func from(
        history: [TrainingRecord],
        level: Level,
        standing: [String] = []
    ) -> TrainingProfile {
        let recent = history.sorted { $0.date > $1.date }.prefix(4)

        // Newest first, de-duplicated: repeating "Hooks" four times tells Claude
        // nothing extra and crowds out older focuses that still matter.
        var seen = Set<String>()
        let focuses = recent
            .flatMap(\.focuses)
            .filter { seen.insert($0.lowercased()).inserted }

        return TrainingProfile(
            level: level,
            recentFocuses: Array(focuses.prefix(10)),
            notes: notes(from: Array(recent)),
            standing: standing
        )
    }

    private static func notes(from recent: [TrainingRecord]) -> [String] {
        guard let last = recent.first else { return [] }
        var notes: [String] = []

        if last.endedEarly {
            notes.append("Ended their last session early, after \(last.roundsCompleted) of \(last.roundsPlanned) rounds")
        }

        if let days = Calendar.current.dateComponents([.day], from: last.date, to: .now).day, days >= 14 {
            notes.append("Hasn't trained in \(days) days — ease them back in")
        }

        if recent.count >= 3 {
            notes.append("This is session \(recent.count + 1) or later — they're consistent")
        }

        return notes
    }
}
