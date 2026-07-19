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

    /// 8, not 12 — the tiles read as one block this way rather than as cards
    /// drifting apart. The column spacing and the two stack spacings below are
    /// the same number on purpose: the gap between two tiles side by side and
    /// the gap between two rows have to match, or the grid looks skewed.
    static let gap: CGFloat = 8

    private let columns = [
        GridItem(.flexible(), spacing: Self.gap),
        GridItem(.flexible(), spacing: Self.gap),
    ]

    var body: some View {
        VStack(spacing: Self.gap) {
            hero

            // Square, all four, which is the whole point of a grid — Fitness's
            // small tiles are one size and the eye reads them as a set rather
            // than as four things that happen to be near each other. Left to
            // themselves the rows disagree: `rounds` carries a sparkline and the
            // Streak/Drilling row underneath doesn't, so the grid came out with
            // a tall row above a short one.
            //
            // An aspect ratio rather than a fixed height: the tile is half the
            // gutter-width whatever the device is, so it stays square on an SE
            // and on a Pro Max, and it grows with Dynamic Type instead of
            // clipping at a number picked on one simulator.
            LazyVGrid(columns: columns, spacing: Self.gap) {
                rounds.aspectRatio(1, contentMode: .fit)
                sessions.aspectRatio(1, contentMode: .fit)
                streak.aspectRatio(1, contentMode: .fit)
                drilling.aspectRatio(1, contentMode: .fit)
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
        Card(title: "Minutes worked", caption: "All time", showsChevron: false) {
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
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                        .font(.caption2)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            .frame(height: 68)
        }
    }

    private var rounds: some View {
        Card(title: "Rounds", caption: "This week") {
            Big("\(stats.roundsThisWeek)")

            // The sparkline sits on the floor of the tile, not directly under
            // the number. This is the Fitness construction and the reason it
            // works: number at the top, chart on the baseline, the gap between
            // them absorbing whatever height is left over. Floating the chart up
            // against the number left a band of dead space under it that made
            // the tile look unfinished — and made the four tiles disagree, since
            // only this one and the hero have a chart to float.
            Spacer(minLength: 8)

            Chart(stats.week) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Rounds", day.rounds)
                )
                .foregroundStyle(isToday(day.date) ? Theme.Palette.accent : Color(.quaternaryLabel))
                .cornerRadius(2)
            }
            .chartYAxis(.hidden)
            // Narrow weekday initials, the same axis the hero carries. On a tile
            // this size they're the difference between a decorative squiggle and
            // a chart you can actually read a day off.
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                        .font(.system(size: 9))
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            // Flexible rather than fixed: the tile is square and its height
            // follows the device width, so a hardcoded 34pt was a different
            // proportion of the card on every phone.
            .frame(maxHeight: .infinity)
        }
    }

    /// The running total, with this week's count on the baseline. The total is
    /// what you've built and the week is whether you're still building it — the
    /// same two-part answer the hero gives, at tile scale.
    private var sessions: some View {
        Card(title: "Sessions", caption: lastTrainedText) {
            Big("\(stats.totalSessions)")
            Spacer(minLength: 8)
            Footnote(
                stats.sessionsThisWeek == 0
                    ? "None this week"
                    : "\(stats.sessionsThisWeek) this week"
            )
        }
    }

    /// The streak, over the week that produced it.
    ///
    /// A bare streak number is the least legible card on the screen: "3" tells
    /// you nothing about whether you're mid-run or about to break one. The dots
    /// are the same seven days the other cards are counting, so a glance says
    /// which days you trained and — because today is always the last dot —
    /// whether today is still open.
    private var streak: some View {
        Card(title: "Streak", caption: stats.streak == 1 ? "day" : "days") {
            Big("\(stats.streak)")
            Spacer(minLength: 8)
            WeekDots(week: stats.week)
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
    /// Off for the hero, on for the tiles — the shape Fitness uses, where the
    /// Activity Ring carries no chevron and the four tiles below it all do.
    var showsChevron: Bool = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    // The title yields before the chevron does: on a narrow tile
                    // a long word should shrink rather than shove the disclosure
                    // off the edge.
                    .minimumScaleFactor(0.85)

                if showsChevron {
                    Spacer(minLength: 0)
                    Chevron()
                }
            }

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
        // Fills its slot in both directions, and pins the content to the top.
        // Height matters as much as width once the tiles are square: without
        // `maxHeight` the background hugged the content while the square frame
        // around it stayed full size, so each card floated at its own offset and
        // the row came out visibly ragged — Rounds sitting lower than Sessions
        // because it has a sparkline to be taller than.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }
}

/// The disclosure affordance in the corner of a tile: a chevron on a filled
/// disc, sized off the caption so it tracks Dynamic Type instead of staying a
/// fixed dot while the text around it grows.
private struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(5)
            .background(Color(.tertiarySystemFill), in: .circle)
            // Decoration, not a control — the card itself is what a fighter
            // would tap once these lead anywhere, so this must not become a
            // second VoiceOver stop announcing "button" on top of it.
            .accessibilityHidden(true)
    }
}

/// The quiet line on a tile's baseline. Sits where the sparkline sits on the
/// cards that have one, so all four tiles share a floor rather than each ending
/// wherever its content ran out.
private struct Footnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Seven days as seven marks: filled where work was done, hollow where it
/// wasn't, and the accent on today.
///
/// Capsules rather than circles because they read at this size — a 6pt circle
/// is a speck on a tile, and the eye needs to count seven of them at a glance
/// without stopping to look.
private struct WeekDots: View {
    let week: [TrainingStats.Day]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(week) { day in
                Image(systemName: day.trained ? "checkmark" : "minus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(day.trained ? Theme.Live.workOnDark : Color(.quaternaryLabel))
                    .frame(maxWidth: .infinity)
            }
        }
        // Reads as one thing, not seven — VoiceOver spelling out seven icons is
        // noise, and the streak number above already says the total.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(week.filter(\.trained).count) of the last 7 days trained")
    }
}

/// The number on a small card. One place, so all four agree.
private struct Big: View {
    let value: String

    init(_ value: String) { self.value = value }

    var body: some View {
        Text(value)
            .font(.system(size: 32, weight: .bold, design: .rounded))
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
