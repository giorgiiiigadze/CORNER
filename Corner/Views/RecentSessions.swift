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
struct RecentSessions: View {

    let history: [TrainingRecord]

    /// Today's session, if it was left partway through. Sits above the finished
    /// ones because it's the only row on the screen that's a thing to *do*
    /// rather than a thing that happened.
    var unfinished: Unfinished?
    var onResume: () -> Void = {}

    struct Unfinished {
        let title: String
        let done: Int
        let total: Int

        var fraction: Double {
            total > 0 ? min(Double(done) / Double(total), 1) : 0
        }
    }

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

            if let unfinished {
                resumeRow(unfinished)
            }

            if recent.isEmpty && unfinished == nil {
                empty
            } else {
                // One card holding rows, rather than a card per session: three
                // separate tiles would out-weigh the dashboard above them, and
                // these are a list, not a set of readouts.
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, record in
                        row(record)

                        if index < recent.count - 1 {
                            Divider()
                                .overlay(Color(.separator))
                                .padding(.leading, 14)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            }
        }
    }

    /// The one row you can act on: what's left of today, and a way back into it.
    private func resumeRow(_ unfinished: Unfinished) -> some View {
        Button(action: onResume) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(unfinished.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(unfinished.done) of \(unfinished.total) rounds")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // The same fraction the calendar ring draws, as a bar. Two
                    // readings of one number, in the two places you'd look.
                    ProgressView(value: unfinished.fraction)
                        .progressViewStyle(.linear)
                        .tint(Theme.Palette.accent)
                }

                Spacer(minLength: 8)

                Text("Resume")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.Palette.accent, in: .capsule)
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func row(_ record: TrainingRecord) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(detail(for: record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(record.date, format: .dateTime.weekday(.abbreviated))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(14)
    }

    private var empty: some View {
        Text("Your finished sessions land here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }

    /// Rounds and minutes, and the minutes only when they were measured — an old
    /// session with no duration says nothing rather than claiming zero.
    private func detail(for record: TrainingRecord) -> String {
        var parts = ["\(record.roundsCompleted) rounds"]

        if let seconds = record.sessionSeconds, seconds >= 60 {
            parts.append("\(seconds / 60) min")
        }
        if record.endedEarly {
            parts.append("ended early")
        }
        return parts.joined(separator: " · ")
    }
}
