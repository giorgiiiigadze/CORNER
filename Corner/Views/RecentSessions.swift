import SwiftUI

/// The last few sessions, under the dashboard.
///
/// The dashboard says what you've done in aggregate; this says what you actually
/// did, with names on it. "28 rounds this week" is a number you can nod at —
/// "Hooks and body work, Tuesday, 8 rounds" is the thing you remember doing, and
/// it's what makes the numbers above mean anything.
///
/// Deliberately short. The History tab is the whole record, and a home screen
/// that lists everything is a history tab with worse navigation.
///
/// The cards themselves are in `SessionCard` — this is the heading, the limit,
/// and the decision about what Home shows.
///
/// Finished sessions only. The unfinished one used to sit at the top of this
/// list with a Resume button on it; it lives on History now, which is the tab
/// that holds every session there is rather than the three most recent.
struct RecentSessions: View {

    let history: [TrainingRecord]

    /// Enough to see a pattern, few enough that the dashboard above stays the
    /// point of the screen.
    private static let limit = 3

    private var recent: [TrainingRecord] {
        Array(history.prefix(Self.limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SummaryCards.gap) {
            Text("Recent sessions")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                // Aligns the heading with the card corners below it rather than
                // the screen edge — the cards are what it's naming.
                .padding(.leading, 4)

            if recent.isEmpty {
                empty
            } else {
                // A card each, not one card of hairline-separated rows. A
                // session is a thing that happened, with a headline worth
                // reading at a glance — rows made three of them into a table,
                // and a table is what the History tab is for.
                ForEach(recent) { record in
                    SessionCard(record: record)
                }
            }
        }
    }

    private var empty: some View {
        Text("Your finished sessions land here.")
            .font(.subheadline)
            .foregroundStyle(Theme.Palette.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.Palette.dashboardSurface, in: .rect(cornerRadius: 18))
    }
}
