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
                // A card each, not one card of hairline-separated rows. A
                // session is a thing that happened, with a headline worth
                // reading at a glance — rows made three of them into a table,
                // and a table is what the History tab is for.
                ForEach(recent) { record in
                    // The whole card is the target, not a chevron in the corner
                    // of it — these are read at a glance and tapped with gloves
                    // on, and a small hit area is the wrong trade for both.
                    NavigationLink {
                        SessionDetail(record: record)
                    } label: {
                        row(record)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The one card you can act on: what's left of today, and the way back in.
    ///
    /// Built to the same pattern as a finished session — title and status, then
    /// a headline, then the detail — so the difference between them is what they
    /// *say*, not how they're drawn. The previous version was its own layout
    /// entirely: a progress bar and a button elbowing each other in one row,
    /// with the title squeezed to a caption beside them.
    private func resumeRow(_ unfinished: Unfinished) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(unfinished.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Says why this card looks different from the ones below it.
                // Without it the only clue is the button, which is a thing to
                // press rather than a thing to read.
                Text("In progress")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accentLight)
            }

            HStack(spacing: 8) {
                Image(systemName: "figure.boxing")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accentLight)

                Text("\(unfinished.done) of \(unfinished.total) rounds")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
            }

            // Full width, under the headline rather than beside it. The same
            // fraction the calendar ring draws — two readings of one number, in
            // the two places you'd look for it.
            ProgressView(value: unfinished.fraction)
                .progressViewStyle(.linear)
                .tint(Theme.Palette.accentLight)

            Button(action: onResume) {
                Text("Resume")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.Palette.accent, in: .capsule)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }

    /// One session: what it was and when, the headline underneath, and the
    /// details small at the bottom.
    ///
    /// Rounds are the headline rather than minutes. Minutes are how long you
    /// were in the room; rounds are how much work happened in it, and a session
    /// is remembered by its rounds.
    private func row(_ record: TrainingRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(record.date, format: .dateTime.hour().minute())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "figure.boxing")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accentLight)

                Text(record.roundsCompleted == 1 ? "1 round" : "\(record.roundsCompleted) rounds")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 14) {
                if let seconds = record.sessionSeconds, seconds >= 60 {
                    detail("clock", "\(seconds / 60) min")
                }

                // Only when it's true. "Finished" on every other card is noise
                // that makes the one card carrying news harder to spot.
                if record.endedEarly {
                    detail("flag.slash", "ended early")
                }

                if let focus = record.focuses.first {
                    detail("target", focus)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }

    /// One small fact, icon then value — the row of them under the headline.
    private func detail(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    private var empty: some View {
        Text("Your finished sessions land here.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }

}
