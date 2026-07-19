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

    /// How much of each day's work actually got done, 0 to 1, keyed by the start
    /// of that day. Days with no training aren't in here at all — absent and
    /// zero are different facts, and only one of them should draw a ring.
    ///
    /// Keyed by day rather than by session, and compared that way: a session at
    /// 23:50 and one at 00:10 are different days and have to mark different
    /// circles.
    let progress: [Date: Double]

    /// The day the dashboard below is showing, or nil for the running totals.
    ///
    /// A binding rather than a callback because the strip both sets and reflects
    /// it: the highlight is the same fact the dashboard is reading, and two
    /// copies of one fact drift.
    @Binding var selection: Date?

    /// How far back you can scroll. Twelve weeks is a season of training, and
    /// far enough that the strip stops being a week and starts being a record.
    private static let weeksBack = 12

    /// Fixed rather than divided by seven: the strip scrolls now, so a slot has
    /// to be one width everywhere instead of a fraction of a screen that only
    /// happens to fit the current week.
    static let slot: CGFloat = 46

    private let calendar = Calendar.current

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    Button {
                        // Tapping the selected day clears it. There's no other
                        // way back to the running totals, and a control that can
                        // only ever be turned on is a trap.
                        // Animated here, at the source. `contentTransition`
                        // only rolls digits when the value that feeds them
                        // changes inside an animation — set outside one, the
                        // dashboard snapped between numbers instead.
                        withAnimation(.snappy(duration: 0.28)) {
                            selection = isSelected(day) ? nil : calendar.startOfDay(for: day)
                        }
                    } label: {
                    VStack(spacing: 6) {
                        Text(day, format: .dateTime.weekday(.abbreviated))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(isToday(day) || isSelected(day) ? .primary : .secondary)

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
                    .padding(.vertical, 11)
                    .padding(.horizontal, 4)
                    .frame(width: Self.slot)
                    .background {
                        // One highlight, the same grey, for both "today" and
                        // "the day you're looking at". The accent was doing a
                        // third job here — it already means the ring on a
                        // trained day and the fill on the chart's bar, and a
                        // container in the same red made the strip louder than
                        // the numbers it's a control for. The ring inside still
                        // tells today apart from any other selected day.
                        if isSelected(day) || isToday(day) {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground))
                        }
                    }
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
        }
        // A light impact rather than `.selection`: this is a tap on a target,
        // not a detent being passed, and the impact is the crisper of the two
        // through a glove. Triggered on the value changing, so clearing a
        // selection is felt as well as setting one.
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: selection)
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
        .accessibilityLabel("Training calendar. \(trainedThisWeek) of 7 days trained this week, \(completedThisWeek) finished in full.")
    }

    /// Outline in every state, filled in none.
    ///
    /// A trained day is the accent, today is ink, everything else is the
    /// quietest grey the system has. All three are strokes on purpose: a solid
    /// disc made the trained days the loudest thing on the screen, louder than
    /// the session button, which inverts what the header is for.
    @ViewBuilder
    private func ring(for day: Date) -> some View {
        if let fraction = fraction(for: day) {
            ZStack {
                // The unfilled remainder stays visible behind the arc. Without
                // it a half-finished session reads as a broken circle rather
                // than as half of a whole one — the missing part is the point.
                Circle()
                    .strokeBorder(Color(.quaternaryLabel), lineWidth: 2)

                Circle()
                    // `strokeBorder` insets by half the line width; `stroke` on
                    // a trimmed shape doesn't, so the path is inset by hand to
                    // keep both rings on exactly the same circle.
                    .inset(by: 1)
                    .trim(from: 0, to: fraction)
                    .stroke(Theme.Palette.accentLight, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    // Twelve o'clock, not three: a ring that starts at the right
                    // edge reads as an arbitrary arc, one that starts at the top
                    // reads as a dial being filled.
                    .rotationEffect(.degrees(-90))
            }
        } else if isToday(day) {
            Circle().strokeBorder(Color(.label), lineWidth: 2)
        } else if isPast(day) {
            // Dashed for a day that came and went without work. A solid ring
            // reads as a container waiting to be filled; a broken one reads as
            // a gap, which is what a missed day is.
            Circle().strokeBorder(
                Color(.quaternaryLabel),
                style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
            )
        } else {
            // Solid, and quiet, for the days ahead. They haven't been missed —
            // drawing them like the misses behind you would be a reproach for
            // something that hasn't happened.
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

    private func isSelected(_ day: Date) -> Bool {
        guard let selection else { return false }
        return calendar.isDate(selection, inSameDayAs: day)
    }

    /// Strictly before today. Today is never "past" however late it is — the day
    /// isn't over, and the strip shouldn't write it off before it is.
    private func isPast(_ day: Date) -> Bool {
        calendar.startOfDay(for: day) < calendar.startOfDay(for: .now)
    }

    private func isTrained(_ day: Date) -> Bool {
        fraction(for: day) != nil
    }

    /// Nil on a day you didn't train, which is what separates "no ring" from a
    /// ring that happens to be empty.
    private func fraction(for day: Date) -> Double? {
        progress[calendar.startOfDay(for: day)]
    }

    private var trainedThisWeek: Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: .now) else { return 0 }
        return days.filter { week.contains($0) && isTrained($0) }.count
    }

    /// Days finished in full, for the accessibility summary — a partial day is
    /// still a day trained, but it isn't a day completed, and a screen reader
    /// shouldn't flatten the two.
    private var completedThisWeek: Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: .now) else { return 0 }
        return days.filter { week.contains($0) && (fraction(for: $0) ?? 0) >= 1 }.count
    }

    /// Full-strength on a day that means something, dimmed on the days either
    /// side — including the ones ahead, which haven't happened and shouldn't
    /// read as though they were missed.
    private func number(for day: Date) -> Color {
        if isTrained(day) || isToday(day) { return Color(.label) }
        return Color(.tertiaryLabel)
    }
}
