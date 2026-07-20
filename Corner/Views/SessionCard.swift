import SwiftUI

/// A session left partway through — today's plan with rounds still on it.
///
/// A value rather than the `TodaySession` model because both screens that show
/// it want the same three facts and none of the rest, and because the thing
/// being described is "what's left", which the model doesn't store.
struct UnfinishedSession: Equatable {
    let title: String
    let done: Int
    let total: Int

    var fraction: Double {
        total > 0 ? min(Double(done) / Double(total), 1) : 0
    }
}

/// One session that happened.
///
/// Lives here rather than inside `RecentSessions` because it is now on two
/// screens: the last three on Home, and every one of them in History. It was
/// duplicated when History drew its own two-line rows, and the two drifted —
/// Home had cards with a headline you could read across the room, History had a
/// table. Same session, two different claims about what a session is.
///
/// Rounds are the headline rather than minutes. Minutes are how long you were in
/// the room; rounds are how much work happened in it, and a session is
/// remembered by its rounds.
struct SessionCard: View {

    let record: TrainingRecord

    /// How the timestamp reads. Home's list is the last three sessions, where
    /// the day is obvious and the hour is the useful part; History spans months,
    /// where the hour means nothing and "3 days ago" is the whole point.
    var stamp: Stamp = .timeOfDay

    enum Stamp {
        case timeOfDay
        case relativeDay
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                timestamp
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                    CardDetail(symbol: "clock", text: "\(seconds / 60) min")
                }

                // Only when it's true. "Finished" on every other card is noise
                // that makes the one card carrying news harder to spot.
                if record.endedEarly {
                    CardDetail(symbol: "flag.slash", text: "ended early")
                }

                if let focus = record.focuses.first {
                    CardDetail(symbol: "target", text: focus)
                }
            }
        }
        .sessionCard()
    }

    @ViewBuilder
    private var timestamp: some View {
        switch stamp {
        case .timeOfDay:
            Text(record.date, format: .dateTime.hour().minute())
        case .relativeDay:
            Text(record.date.formatted(.relative(presentation: .named)))
        }
    }
}

/// The one card you can act on: what's left of today, and the way back in.
///
/// Built to the same pattern as a finished session — title and status, then a
/// headline, then the detail — so the difference between them is what they
/// *say*, not how they're drawn. The version before this was its own layout
/// entirely: a progress bar and a button elbowing each other in one row, with
/// the title squeezed to a caption beside them.
struct ResumeCard: View {

    let session: UnfinishedSession
    let onResume: () -> Void

    private var hasStarted: Bool { session.done > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                // Says why this card looks different from the ones below it.
                // Without it the only clue is the button, which is a thing to
                // press rather than a thing to read.
                // Same distinction the Home banner makes, for the same reason: a
                // plan is saved before the first bell, so "In progress" on a
                // session nobody has started is the app describing a workout
                // that never happened.
                Text(hasStarted ? "In progress" : "Ready")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accentLight)
            }

            HStack(spacing: 8) {
                Image(systemName: "figure.boxing")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accentLight)

                Text(
                    hasStarted
                        ? "\(session.done) of \(session.total) rounds"
                        : (session.total == 1 ? "1 round" : "\(session.total) rounds")
                )
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
            }

            // Full width, under the headline rather than beside it. The same
            // fraction the calendar ring draws — two readings of one number, in
            // the two places you'd look for it.
            ProgressView(value: session.fraction)
                .progressViewStyle(.linear)
                .tint(Theme.Palette.accentLight)

            Button(action: onResume) {
                Text(hasStarted ? "Resume" : "Start")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Theme.Palette.accent, in: Theme.buttonShape)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .sessionCard()
    }
}

/// A session is open. Home's one green thing.
///
/// Sits under the week strip, above the dashboard, and it is deliberately not a
/// card: the cards below it are things that *happened*, laid out to be read.
/// This is a state — there is a session waiting for you right now — and it earns
/// the top of the screen by being the only item on Home that expires.
///
/// Green because green already means "the round is running" on the live screen,
/// and this is the same fact reported one screen up. It's the only green in the
/// chrome, the same way the accent red is the only red: a colour that appears
/// once means something, and a colour that appears everywhere is decoration.
///
/// Small on purpose. The full `ResumeCard` — progress bar, big round count,
/// full-width button — lives on History, where you go to look at sessions. Home
/// only has to say "you're mid-session, tap here", and a card that says that in
/// four elements is a card arguing with the dashboard underneath it.
struct LiveSessionIndicator: View {

    let session: UnfinishedSession
    let onResume: () -> Void

    /// Takes it off Home. The plan is untouched — it stays in History, and this
    /// is the fighter saying "I'm done with that one", which nothing else in the
    /// app was able to hear.
    ///
    /// It needs saying because the banner otherwise sits there for the rest of
    /// the day: end a session at four rounds of six because four was enough, and
    /// Home spends the evening insisting you're mid-session.
    let onDismiss: () -> Void

    /// Whether a round has actually been trained against this plan.
    ///
    /// The distinction the old copy didn't make. A plan is stored the moment
    /// it's written — before the first bell, and before permissions are even
    /// granted — so backing out of the live screen left Home announcing
    /// "Session in progress · 0/6" about a session that had never started. Two
    /// states, two sentences, and neither of them a lie.
    private var hasStarted: Bool { session.done > 0 }

    private var headline: String {
        hasStarted ? "Session unfinished" : "Ready to start"
    }

    private var tally: String {
        hasStarted
            ? "\(session.done)/\(session.total)"
            : (session.total == 1 ? "1 round" : "\(session.total) rounds")
    }

    /// The dot breathes, the way the live screen's listening indicator does.
    /// It's the difference between "a session exists" and "a session is live",
    /// and it's the one moving thing on an otherwise static screen.
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onResume) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Self.ink)
                        .frame(width: 8, height: 8)
                        // Only the unfinished one breathes. A session waiting to
                        // start isn't doing anything, and a pulse on it claims a
                        // clock is running somewhere.
                        .opacity(hasStarted && pulsing ? 0.35 : 1)
                        .animation(
                            hasStarted
                                ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                                : .default,
                            value: pulsing
                        )

                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Self.ink)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    // No chevron. The whole bar is the tap target and the X sits
                    // beside it — a third mark in the same corner was one more
                    // thing to read on the one element that should be read at a
                    // glance.
                    Text(tally)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Self.ink.opacity(0.75))
                }
                .padding(.leading, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                hasStarted
                    ? "Session unfinished, \(session.done) of \(session.total) rounds. Resume."
                    : "Session ready to start, \(session.total) rounds. Start."
            )

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Self.ink.opacity(0.55))
                    // A 44pt target on a 14pt glyph: this is a small mark beside
                    // the thing you actually meant to tap, and the cost of
                    // missing it is opening a session you were dismissing.
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")

            Spacer(minLength: 0)
                .frame(width: 4)
        }
        // Fully rounded, not a rounded rectangle. The dashboard under this is
        // all 18pt cards; matching that radius made the banner read as one more
        // card that happened to be green. A capsule reads as a status pill —
        // a different kind of object, which is what it is: the cards are things
        // that happened, this is a thing that's still going.
        .background(Theme.Live.work, in: .capsule)
        .onAppear { pulsing = true }
    }

    /// Near-black rather than white. The green is saturated enough that white
    /// type on it is the one combination that fails at arm's length — it glows
    /// and the letterforms fill in. Dark ink on a bright fill is how a warning
    /// label is built, and this is closer to a warning label than to a card.
    private static let ink = Color(white: 0.06)
}

/// One small fact, icon then value — the row of them under a card's headline.
struct CardDetail: View {

    let symbol: String
    let text: String

    var body: some View {
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
}

extension View {
    /// The card itself — padding, fill and corner.
    ///
    /// One definition for both cards and both screens. When this was written out
    /// at each site, the resume card and the session card were already a corner
    /// radius apart on Home alone.
    func sessionCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: .rect(cornerRadius: 18)
            )
    }
}
