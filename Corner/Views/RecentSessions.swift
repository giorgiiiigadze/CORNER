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
        VStack(alignment: .leading, spacing: 0) {
            // The system's own section heading: small, uppercase, tracked out and
            // grey. Home used a `.headline` in white here, which is the weight a
            // *title* carries — this is a label on a list, and the list under it
            // is what should be read first.
            Text("RECENT")
                .font(.caption.weight(.semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            if recent.isEmpty {
                empty
            } else {
                // Plain rows on the black, hairline-separated, with a chevron —
                // the native list Settings and Health are built from. The cards
                // that used to be here are still the right thing on History,
                // where a session is the subject; on Home the dashboard is the
                // subject and this is a list beneath it.
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, record in
                    row(record)

                    if index < recent.count - 1 {
                        Divider()
                            .overlay(Theme.Palette.hairline)
                    }
                }
            }
        }
    }

    /// Title over "6 rounds · Yesterday", with the chevron on the right.
    private func row(_ record: TrainingRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle(record))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 12)
        .contentShape(.rect)
    }

    /// "6 rounds · Yesterday" — the two facts a glance wants, on one line.
    private func subtitle(_ record: TrainingRecord) -> String {
        let rounds = record.roundsCompleted == 1 ? "1 round" : "\(record.roundsCompleted) rounds"
        let when = record.date.formatted(.relative(presentation: .named)).localizedCapitalized
        return "\(rounds) \u{00B7} \(when)"
    }

    private var empty: some View {
        Text("Your finished sessions land here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }
}
