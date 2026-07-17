import Foundation
import Testing
@testable import Corner

/// The dashboard makes claims about the user's own training, which is the one
/// subject they can check from memory. A streak that's off by one is the whole
/// screen's credibility, and it'd be off by one silently.
@MainActor
struct TrainingStatsTests {

    /// A fixed "today", so these are true on every day rather than the day they
    /// were written.
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12))!

    private func record(
        daysAgo: Int,
        focuses: [String] = ["Hooks"],
        completed: Int = 6,
        sessionSeconds: Int? = 600
    ) -> TrainingRecord {
        TrainingRecord(
            date: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!,
            title: "Session",
            focuses: focuses,
            roundsPlanned: 6,
            roundsCompleted: completed,
            endedEarly: false,
            sessionSeconds: sessionSeconds,
            pauseCount: 0
        )
    }

    // MARK: - Empty

    @Test func noHistoryInventsNothing() {
        let stats = TrainingStats.from(history: [], now: now)

        #expect(stats.minutesThisWeek == 0)
        #expect(stats.streak == 0)
        #expect(stats.totalSessions == 0)
        #expect(stats.lastTrained == nil)
    }

    // MARK: - Minutes

    @Test func minutesComeFromSecondsActuallyTrained() {
        let stats = TrainingStats.from(
            history: [record(daysAgo: 0, sessionSeconds: 630), record(daysAgo: 1, sessionSeconds: 570)],
            now: now
        )

        // 10 minutes and 9 — floored, never flattered.
        #expect(stats.minutesThisWeek == 19)
    }

    @Test func totalMinutesCountEverySession() {
        let stats = TrainingStats.from(
            history: [record(daysAgo: 0, sessionSeconds: 600), record(daysAgo: 40, sessionSeconds: 1200)],
            now: now
        )

        #expect(stats.minutesTotal == 30, "all time means all time, not this week")
        #expect(stats.minutesThisWeek == 10)
    }

    /// Sum the seconds, then divide once. Adding up floored minutes throws away
    /// the tail of every session, and twenty sessions later that's a quarter of
    /// an hour the fighter trained and the app forgot.
    @Test func totalMinutesDoNotLoseEverySessionsRemainder() {
        let stats = TrainingStats.from(
            history: (0..<4).map { record(daysAgo: $0 * 10, sessionSeconds: 110) },
            now: now
        )

        // 4 × 1:50 is 7:20. Flooring each session first would say 4.
        #expect(stats.minutesTotal == 7)
    }

    /// The rule the whole feature stands on: a session recorded before the app
    /// timed anything must not be averaged in as if it were zero minutes of work.
    @Test func sessionsFromBeforeTimingAreExcludedAndCounted() {
        let stats = TrainingStats.from(
            history: [record(daysAgo: 0, sessionSeconds: 600), record(daysAgo: 1, sessionSeconds: nil)],
            now: now
        )

        #expect(stats.minutesThisWeek == 10, "the untimed session must not add zero minutes silently")
        #expect(stats.sessionsWithoutMinutes == 1, "and the screen has to be able to say so")
        #expect(stats.totalSessions == 2, "it still happened")
    }

    // MARK: - The week

    @Test func theWeekIsSevenDaysIncludingTheGaps() {
        let stats = TrainingStats.from(history: [record(daysAgo: 0), record(daysAgo: 3)], now: now)

        #expect(stats.week.count == 7)
        #expect(stats.week.filter { $0.minutes > 0 }.count == 2)
        #expect(stats.week.last?.minutes == 10, "today is the last bar")
    }

    @Test func olderSessionsDoNotCountThisWeek() {
        let stats = TrainingStats.from(history: [record(daysAgo: 30)], now: now)

        #expect(stats.minutesThisWeek == 0)
        #expect(stats.roundsThisWeek == 0)
        #expect(stats.totalSessions == 1)
        #expect(stats.totalRounds == 6)
    }

    // MARK: - Streak

    @Test func consecutiveDaysCount() {
        let stats = TrainingStats.from(
            history: [record(daysAgo: 0), record(daysAgo: 1), record(daysAgo: 2)],
            now: now
        )

        #expect(stats.streak == 3)
    }

    /// The one that matters. Not having trained *yet today* is not a broken
    /// streak — the day isn't over. Getting this wrong means a month-long streak
    /// reads as zero every morning until you train.
    @Test func todayIsNotOverYet() {
        let stats = TrainingStats.from(history: [record(daysAgo: 1), record(daysAgo: 2)], now: now)

        #expect(stats.streak == 2)
    }

    @Test func aMissedDayBreaksIt() {
        let stats = TrainingStats.from(
            history: [record(daysAgo: 0), record(daysAgo: 2), record(daysAgo: 3)],
            now: now
        )

        #expect(stats.streak == 1, "yesterday is missing, so the streak is today alone")
    }

    @Test func twoSessionsInADayAreStillOneDay() {
        let stats = TrainingStats.from(
            history: [record(daysAgo: 0), record(daysAgo: 0), record(daysAgo: 1)],
            now: now
        )

        #expect(stats.streak == 2)
    }

    @Test func aLongLayoffIsNoStreak() {
        let stats = TrainingStats.from(history: [record(daysAgo: 9)], now: now)

        #expect(stats.streak == 0)
    }

    // MARK: - Focuses

    @Test func focusesAreNewestFirstAndDeduplicated() {
        let stats = TrainingStats.from(
            history: [
                record(daysAgo: 0, focuses: ["Hooks", "Hooks"]),
                record(daysAgo: 1, focuses: ["Footwork"]),
            ],
            now: now
        )

        #expect(stats.recentFocuses == ["Hooks", "Footwork"])
    }
}
