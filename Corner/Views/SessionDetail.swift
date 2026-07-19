import SwiftUI

/// One finished session, in full.
///
/// The card on Home answers "what did I do"; this answers "how did it go" —
/// which is a different question and the reason it's worth a screen. The two
/// facts that only live here are the pauses and the shortfall: six pauses in six
/// rounds is a session that was pitched wrong, and three of eight rounds is a
/// session that beat you. Neither belongs on a card you scroll past.
struct SessionDetail: View {

    let record: TrainingRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                totals
                if !record.focuses.isEmpty { drilled }
                if let note { verdict(note) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.background)
        // Blank, because the header below already says it. The same rule Home
        // and Profile follow: a screen that introduces itself doesn't need the
        // bar to introduce it again, and the title in both places at once is
        // just the sentence twice.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)

            Text(record.date, format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Totals

    /// Three numbers, the same shape the profile uses. Pauses are here and
    /// nowhere else in the app: they're the clearest evidence a session asked
    /// for more than the fighter had that day.
    private var totals: some View {
        HStack(spacing: 34) {
            total("\(record.roundsCompleted)", "Rounds")

            if let seconds = record.sessionSeconds, seconds >= 60 {
                total("\(seconds / 60)", "Minutes")
            }

            if let pauses = record.pauseCount {
                total("\(pauses)", pauses == 1 ? "Pause" : "Pauses")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func total(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.primary)

            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Focuses

    /// What each round was for, in order.
    ///
    /// Numbered rather than bulleted, because the order is the session: round
    /// one is the warm-up and round eight is what you had left, and a list that
    /// loses the order loses the shape of the work.
    private var drilled: some View {
        VStack(alignment: .leading, spacing: SummaryCards.gap) {
            Text("What you drilled")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(record.focuses.enumerated()), id: \.offset) { index, focus in
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .leading)

                        Text(focus)
                            .font(.subheadline)
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        // The rounds that were planned but never happened are
                        // dimmed rather than hidden — what you didn't get to is
                        // part of what the session was.
                        if index >= record.roundsCompleted {
                            Text("not reached")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 16)
                    .opacity(index >= record.roundsCompleted ? 0.5 : 1)

                    if index < record.focuses.count - 1 {
                        Divider()
                            .overlay(Color(.separator))
                            .padding(.leading, 50)
                    }
                }
            }
            .background(Theme.Palette.surface, in: .rect(cornerRadius: 18))
        }
    }

    // MARK: - Verdict

    /// Said plainly, and only when there's something to say. A line on every
    /// session that mostly reads "you finished it" is a line nobody reads by the
    /// third one, which is exactly when it would matter.
    private var note: String? {
        if record.endedEarly {
            let short = record.roundsPlanned - record.roundsCompleted
            return short > 0
                ? "Called it \(short) round\(short == 1 ? "" : "s") early."
                : "Called it early."
        }
        if record.roundsCompleted > record.roundsPlanned {
            let extra = record.roundsCompleted - record.roundsPlanned
            return "Asked for \(extra) more round\(extra == 1 ? "" : "s") than the plan had."
        }
        return nil
    }

    private func verdict(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.surface, in: .rect(cornerRadius: 18))
    }
}
