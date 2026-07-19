import Foundation

/// Everything the dashboard shows, worked out from history in one pass.
///
/// Pure, and takes `now` rather than reading the clock, so every number here can
/// be tested at a fixed date instead of only being true on the day you wrote it.
/// Same reason `CommandParser` has no framework in it.
nonisolated struct TrainingStats: Equatable {

    /// One day's worth, for the bars.
    struct Day: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        let minutes: Int
        let rounds: Int

        /// Whether anything happened on this day.
        ///
        /// Rounds rather than minutes: sessions trained before the app timed
        /// them carry rounds with no minutes attached, and those days were
        /// still trained. Reading `minutes` alone would draw them as rest days.
        var trained: Bool { rounds > 0 }
    }

    /// Last seven days, oldest first. Days you didn't train are in here as
    /// zeroes — a week with a gap should look like a week with a gap, not like
    /// six days squeezed together.
    var week: [Day] = []

    /// Every minute ever trained.
    ///
    /// Summed in seconds and divided once at the end, not by adding up each
    /// session's floored minutes — twenty sessions each losing their last forty
    /// seconds is thirteen minutes that quietly never happened.
    var minutesTotal = 0

    var minutesThisWeek = 0
    var roundsThisWeek = 0
    var sessionsThisWeek = 0

    /// Consecutive days ending today, or yesterday if today hasn't happened yet.
    var streak = 0

    var totalSessions = 0
    var totalRounds = 0
    var lastTrained: Date?

    /// Newest first, de-duplicated.
    var recentFocuses: [String] = []

    /// Sessions from before the app recorded durations.
    ///
    /// Surfaced rather than swallowed, because every minute figure above quietly
    /// excludes them. A total that's wrong and says so is a total; one that's
    /// wrong and doesn't is a lie with a number on it.
    var sessionsWithoutMinutes = 0

    static func from(
        history: [TrainingRecord],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> TrainingStats {
        guard !history.isEmpty else { return TrainingStats() }

        let today = calendar.startOfDay(for: now)
        let sorted = history.sorted { $0.date > $1.date }

        let week: [Day] = (0..<7).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let onThatDay = history.filter { calendar.isDate($0.date, inSameDayAs: day) }
            return Day(
                date: day,
                // Integer minutes, floored: a session is either a minute on the
                // bag or it isn't, and 0.7 of one rounding up to 1 is the kind
                // of flattery that makes the whole screen untrustworthy.
                minutes: onThatDay.reduce(0) { $0 + ($1.sessionSeconds ?? 0) } / 60,
                rounds: onThatDay.reduce(0) { $0 + $1.roundsCompleted }
            )
        }

        let thisWeek = history.filter { record in
            guard let cutoff = calendar.date(byAdding: .day, value: -6, to: today) else { return false }
            return record.date >= cutoff
        }

        var seen = Set<String>()
        let focuses = sorted
            .prefix(4)
            .flatMap(\.focuses)
            .filter { seen.insert($0.lowercased()).inserted }

        return TrainingStats(
            week: week,
            minutesTotal: history.reduce(0) { $0 + ($1.sessionSeconds ?? 0) } / 60,
            minutesThisWeek: week.reduce(0) { $0 + $1.minutes },
            roundsThisWeek: week.reduce(0) { $0 + $1.rounds },
            sessionsThisWeek: thisWeek.count,
            streak: streak(history, today: today, calendar: calendar),
            totalSessions: history.count,
            totalRounds: history.reduce(0) { $0 + $1.roundsCompleted },
            lastTrained: sorted.first?.date,
            recentFocuses: Array(focuses.prefix(6)),
            sessionsWithoutMinutes: history.count(where: { $0.sessionSeconds == nil })
        )
    }

    /// Counts back from today, one day at a time, until a day is missing.
    ///
    /// Not training *today* doesn't break a streak — the day isn't over. Not
    /// training yesterday does. Anything else means the streak you've kept for a
    /// month reads as zero every morning until you train.
    private static func streak(
        _ history: [TrainingRecord],
        today: Date,
        calendar: Calendar
    ) -> Int {
        let trained = Set(history.map { calendar.startOfDay(for: $0.date) })

        var day = today
        if !trained.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day),
                  trained.contains(yesterday)
            else { return 0 }
            day = yesterday
        }

        var count = 0
        while trained.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}
