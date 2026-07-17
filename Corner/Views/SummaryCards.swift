import Charts
import SwiftUI

/// The dashboard: Apple's Summary shape, Corner's manners.
///
/// The shape is borrowed and worth borrowing — one hero, then a grid of small
/// cards, each a name, one big number, and a sparkline. It reads at a glance and
/// everyone already knows how to use it.
///
/// What isn't borrowed is the colour. Fitness gives every card its own hue —
/// purple steps, blue distance, red move — because it has a dozen unrelated
/// metrics and colour is how you tell them apart at speed. Corner has four, they
/// all measure the same thing, and its accent is spent on the two moments that
/// matter: the listening dot and the start action. So this is ink and one accent
/// on today's bar. That restraint is the "not too much like Apple Fitness" part.
///
/// The ink is the system's, not the Theme's: `.primary`, `.secondary` and the
/// grouped-background greys are the same colours Settings and Fitness are built
/// from, so these cards are system chrome rather than an imitation of it, and
/// they'll follow contrast and appearance settings without being asked. The one
/// exception is today's bar, which stays the Corner accent — that's the brand,
/// and it's the only thing on this screen that should be.
struct SummaryCards: View {

    let stats: TrainingStats

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 12) {
            hero

            LazyVGrid(columns: columns, spacing: 12) {
                rounds
                sessions
                streak
                drilling
            }

            // The asterisk on every minute figure above.
            if stats.sessionsWithoutMinutes > 0 {
                Text("\(stats.sessionsWithoutMinutes) earlier \(stats.sessionsWithoutMinutes == 1 ? "session isn't" : "sessions aren't") counted in minutes — they were trained before the app timed them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Cards

    /// Minutes, in the hero slot, because it's the closest thing Corner has to a
    /// Move ring: the one number that means "I did the work."
    private var hero: some View {
        // All time, not this week. The bars underneath still show the last seven
        // days, so the card answers both — the total is what you've built, and
        // the bars are whether you're still building it.
        //
        // "Worked", not "on the bag": it counts the rests too, and a minute spent
        // breathing between rounds is not a minute on the bag.
        Card(title: "Minutes worked", caption: "All time") {
            Text("\(stats.minutesTotal)")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())

            Chart(stats.week) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Minutes", day.minutes)
                )
                .foregroundStyle(isToday(day.date) ? Theme.Palette.accent : Color(.quaternaryLabel))
                .cornerRadius(3)
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 68)
        }
    }

    private var rounds: some View {
        Card(title: "Rounds", caption: "This week") {
            Big("\(stats.roundsThisWeek)")

            Chart(stats.week) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Rounds", day.rounds)
                )
                .foregroundStyle(isToday(day.date) ? Theme.Palette.accent : Color(.quaternaryLabel))
                .cornerRadius(2)
            }
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .frame(height: 34)
        }
    }

    private var sessions: some View {
        Card(title: "Sessions", caption: lastTrainedText) {
            Big("\(stats.totalSessions)")
            Spacer(minLength: 0)
        }
    }

    private var streak: some View {
        Card(title: "Streak", caption: stats.streak == 1 ? "day" : "days") {
            Big("\(stats.streak)")
            Spacer(minLength: 0)
        }
    }

    /// The one card that isn't a number, because the answer isn't one.
    private var drilling: some View {
        Card(title: "Drilling", caption: "Lately") {
            if stats.recentFocuses.isEmpty {
                Text("—")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(stats.recentFocuses.prefix(3), id: \.self) { focus in
                        Text(focus)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Derived

    private var lastTrainedText: String {
        guard let last = stats.lastTrained else { return "None yet" }
        return last.formatted(.relative(presentation: .named)).capitalized
    }

    private func isToday(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }
}

// MARK: - Pieces

/// One card. Everything that makes the grid look like a grid lives here rather
/// than being repeated five times and drifting.
private struct Card<Content: View>: View {
    let title: String
    let caption: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }
}

/// The number on a small card. One place, so all four agree.
private struct Big: View {
    let value: String

    init(_ value: String) { self.value = value }

    var body: some View {
        Text(value)
            .font(.system(size: 32, weight: .heavy, design: .rounded))
            .foregroundStyle(.primary)
            .contentTransition(.numericText())
    }
}

#Preview {
    let stats = TrainingStats(
        week: (0..<7).reversed().map { back in
            TrainingStats.Day(
                date: Calendar.current.date(byAdding: .day, value: -back, to: .now)!,
                minutes: [12, 0, 18, 24, 0, 9, 21][back],
                rounds: [4, 0, 6, 8, 0, 3, 7][back]
            )
        },
        minutesThisWeek: 84,
        roundsThisWeek: 28,
        sessionsThisWeek: 5,
        streak: 3,
        totalSessions: 19,
        totalRounds: 112,
        lastTrained: .now,
        recentFocuses: ["Hooks", "Body work", "Footwork"],
        sessionsWithoutMinutes: 2
    )

    ScrollView {
        SummaryCards(stats: stats)
            .padding()
    }
    .background(Theme.Palette.background)
}
