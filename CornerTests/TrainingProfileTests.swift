import Foundation
import Testing
@testable import Corner

/// The profile is what the cornerman is told about you. If it's wrong, every
/// session is wrong, and the failure is invisible — you'd just get a session
/// that felt slightly off. Worth testing hard.
@MainActor
struct TrainingProfileTests {

    private func record(
        daysAgo: Int = 0,
        title: String = "Session",
        focuses: [String] = ["Hooks"],
        planned: Int = 6,
        completed: Int = 6,
        endedEarly: Bool = false
    ) -> TrainingRecord {
        TrainingRecord(
            date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now)!,
            title: title,
            focuses: focuses,
            roundsPlanned: planned,
            roundsCompleted: completed,
            endedEarly: endedEarly
        )
    }

    // MARK: - First session

    /// The empty case has to be clean: no invented history, no fake notes.
    /// Inventing a past is exactly the bug this whole file replaced.
    @Test func firstSessionHasNoHistoryAndInventsNothing() {
        let profile = TrainingProfile.from(history: [], level: .beginner)

        #expect(profile.recentFocuses.isEmpty)
        #expect(profile.notes.isEmpty)
        #expect(profile.level == .beginner)
    }

    // MARK: - Focuses

    @Test func focusesAreNewestFirst() {
        let history = [
            record(daysAgo: 7, focuses: ["Body shots"]),
            record(daysAgo: 1, focuses: ["Uppercuts"]),
            record(daysAgo: 3, focuses: ["Footwork"]),
        ]
        let profile = TrainingProfile.from(history: history, level: .intermediate)

        #expect(profile.recentFocuses == ["Uppercuts", "Footwork", "Body shots"])
    }

    /// Repeating "Hooks" four times tells Claude nothing extra and pushes out
    /// older focuses that still matter.
    @Test func repeatedFocusesAreCollapsed() {
        let history = [
            record(daysAgo: 1, focuses: ["Hooks", "Hooks"]),
            record(daysAgo: 2, focuses: ["hooks", "Jab"]),
        ]
        let profile = TrainingProfile.from(history: history, level: .beginner)

        #expect(profile.recentFocuses == ["Hooks", "Jab"])
    }

    // MARK: - Notes

    // The two tempo-note tests that lived here are gone with the counters they
    // read. "Slower" and "faster" were about the pace of combo callouts, and
    // there are none — so the note could only ever have summed two zeroes, while
    // these tests kept passing by building records with the numbers baked in.
    // A green test over unreachable code is worse than no test.

    @Test func endingEarlyIsRemembered() {
        let history = [record(daysAgo: 1, planned: 6, completed: 2, endedEarly: true)]
        let profile = TrainingProfile.from(history: history, level: .beginner)

        #expect(profile.notes.contains { $0.contains("early") && $0.contains("2 of 6") })
    }

    @Test func aLongLayoffIsRemembered() {
        let history = [record(daysAgo: 30)]
        let profile = TrainingProfile.from(history: history, level: .advanced)

        #expect(profile.notes.contains { $0.contains("Hasn't trained") })
    }

    @Test func recentTrainingIsNotMistakenForALayoff() {
        let history = [record(daysAgo: 2)]
        let profile = TrainingProfile.from(history: history, level: .advanced)

        #expect(!profile.notes.contains { $0.contains("Hasn't trained") })
    }

    // MARK: - Level

    /// Skill is the one thing a session log can't reveal — a beginner and a pro
    /// both just "did six rounds". So it's asked, never inferred.
    @Test func levelComesFromTheUserNotTheHistory() {
        let history = (1...20).map { record(daysAgo: $0) }
        let profile = TrainingProfile.from(history: history, level: .beginner)

        #expect(profile.level == .beginner)
    }

    // MARK: - Standing instructions

    /// Same argument as `level`, and the stakes are higher: "no body work, my
    /// ribs are shot" is not derivable from any session log, and the cost of
    /// dropping it is a session that hurts someone.
    @Test func standingInstructionsSurviveTheHistory() {
        let history = (1...20).map { record(daysAgo: $0) }
        let profile = TrainingProfile.from(
            history: history,
            level: .advanced,
            standing: ["Southpaw", "Ribs are shot — no body work"]
        )

        #expect(profile.standing == ["Southpaw", "Ribs are shot — no body work"])
    }

    /// They're what the fighter said, not what the app watched. Letting them
    /// leak into `notes` would blur a line the prompt depends on: notes are
    /// observations, and observations can be wrong in a way these can't.
    @Test func standingInstructionsAreNotObservations() {
        let profile = TrainingProfile.from(
            history: [record(endedEarly: true)],
            level: .beginner,
            standing: ["Southpaw"]
        )

        #expect(!profile.notes.contains("Southpaw"))
        #expect(profile.standing == ["Southpaw"])
    }

    @Test func noStandingInstructionsIsTheDefault() {
        #expect(TrainingProfile.from(history: [], level: .beginner).standing.isEmpty)
    }
}
