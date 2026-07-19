import SwiftUI

/// The calendar, under the masthead: which days you trained, running back as far
/// as you care to scroll.
///
/// Weeks rather than a rolling seven days, which is the whole point of the
/// shape. A rolling window always ends on today and so can never show you what's
/// left — this one has days ahead of it, dimmed, and that empty space to the
/// right of today is the part that actually asks something of you.
///
/// It's deliberately the same question the Streak tile answers further down the
/// screen, in a different tense: the tile says how long the run is, this says
/// which days it's made of and whether today is still open.
struct WeekStrip: View {

    /// Days that saw work. Compared by day, not by instant — a session at 23:50
    /// and one at 00:10 are different days and have to mark different circles.
    let trained: Set<Date>

    /// How far back you can scroll. Twelve weeks is a season of training, and
    /// far enough that the strip stops being a week and starts being a record.
    private static let weeksBack = 12

    /// Fixed rather than divided by seven: the strip scrolls now, so a slot has
    /// to be one width everywhere instead of a fraction of a screen that only
    /// happens to fit the current week.
    private static let slot: CGFloat = 46

    private let calendar = Calendar.current

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 6) {
                        Text(day, format: .dateTime.weekday(.abbreviated))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(isToday(day) ? .primary : .secondary)

                        Text(day, format: .dateTime.day())
                            .font(.subheadline.weight(isToday(day) ? .bold : .regular))
                            .foregroundStyle(number(for: day))
                            .frame(width: 34, height: 34)
                            .background { ring(for: day) }
                    }
                    // The padding is on every cell, not just today's — it's what
                    // reserves the room the highlight sits in. Applied only to
                    // the current day, the row would shift sideways each time
                    // the date rolled over.
                    .padding(.vertical, 8)
                    .frame(width: Self.slot)
                    .background {
                        if isToday(day) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        // Inside the scroll, not around it: the row still runs edge to edge as
        // it moves, but it can't come to rest with today's circle flush against
        // the bezel. Without this the trailing anchor parks the current day half
        // off the screen, which is the one day that must always be whole.
        .contentMargins(.horizontal, 16, for: .scrollContent)
        // Opens on the current week and scrolls back into history, rather than
        // opening three months ago and asking you to find today.
        .defaultScrollAnchor(.trailing)
        // The circles are the full height of the row, so the default clip shaves
        // their edges as they pass the bounds.
        .scrollClipDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Training calendar. \(trainedThisWeek) of 7 days trained this week.")
    }

    /// Outline in every state, filled in none.
    ///
    /// A trained day is the accent, today is ink, everything else is the
    /// quietest grey the system has. All three are strokes on purpose: a solid
    /// disc made the trained days the loudest thing on the screen, louder than
    /// the session button, which inverts what the header is for.
    @ViewBuilder
    private func ring(for day: Date) -> some View {
        if isTrained(day) {
            Circle().strokeBorder(Theme.Palette.accent, lineWidth: 2)
        } else if isToday(day) {
            Circle().strokeBorder(Color(.label), lineWidth: 2)
        } else {
            Circle().strokeBorder(Color(.quaternaryLabel), lineWidth: 1.5)
        }
    }

    // MARK: - Days

    /// Whole weeks, oldest first, ending with the one today falls in — so every
    /// column lines up under its weekday for the entire scroll.
    private var days: [Date] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now),
              let start = calendar.date(byAdding: .weekOfYear, value: -Self.weeksBack, to: thisWeek.start)
        else { return [] }

        let count = (Self.weeksBack + 1) * 7
        return (0..<count).compactMap {
            calendar.date(byAdding: .day, value: $0, to: start)
        }
    }

    private func isToday(_ day: Date) -> Bool { calendar.isDateInToday(day) }

    private func isTrained(_ day: Date) -> Bool {
        trained.contains { calendar.isDate($0, inSameDayAs: day) }
    }

    private var trainedThisWeek: Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: .now) else { return 0 }
        return days.filter { week.contains($0) && isTrained($0) }.count
    }

    /// Full-strength on a day that means something, dimmed on the days either
    /// side — including the ones ahead, which haven't happened and shouldn't
    /// read as though they were missed.
    private func number(for day: Date) -> Color {
        if isTrained(day) || isToday(day) { return Color(.label) }
        return Color(.tertiaryLabel)
    }
}
