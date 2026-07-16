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
    var date: Date = Date()
    var title: String = ""
    /// The focus of each round, in order. The strongest signal we have about
    /// what this person has actually been working on.
    var focuses: [String] = []
    var roundsPlanned: Int = 0
    var roundsCompleted: Int = 0
    /// How often they asked for the callouts to space out. Real evidence the
    /// pace was wrong for them, not a guess.
    /// True when they said "end session" rather than finishing the last round.
    var endedEarly: Bool = false

    init(
        date: Date = .now,
        title: String,
        focuses: [String],
        roundsPlanned: Int,
        roundsCompleted: Int,
        endedEarly: Bool
    ) {
        self.date = date
        self.title = title
        self.focuses = focuses
        self.roundsPlanned = roundsPlanned
        self.roundsCompleted = roundsCompleted
        self.endedEarly = endedEarly
    }

    convenience init(summary: SessionSummary, date: Date = .now) {
        self.init(
            date: date,
            title: summary.title,
            focuses: summary.focuses,
            roundsPlanned: summary.roundsPlanned,
            roundsCompleted: summary.roundsCompleted,
            endedEarly: summary.endedEarly
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
}

// MARK: - History → profile

extension TrainingProfile {

    /// Builds the profile Claude sees from what actually happened.
    ///
    /// Everything here is an observation, not an inference about the person:
    /// what they drilled, what they asked for, what they didn't finish. The one
    /// thing we can't observe is skill, so that stays a question for the user
    /// rather than something guessed from a session count.
    static func from(history: [TrainingRecord], level: Level) -> TrainingProfile {
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
            notes: notes(from: Array(recent))
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
