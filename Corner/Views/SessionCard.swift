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

    /// Whether every round that was planned actually got worked.
    ///
    /// Both halves are needed. `endedEarly` catches walking out; the round count
    /// catches the quieter version, where the session was let run but rounds were
    /// skipped past — and a card that went green for that would be calling a
    /// session complete that wasn't.
    private var isComplete: Bool {
        !record.endedEarly
            && record.roundsPlanned > 0
            && record.roundsCompleted >= record.roundsPlanned
    }

    /// The brand lime for a session finished in full, grey for anything less.
    ///
    /// The card's whole surface carries it, so a scroll through History reads as
    /// a record of what actually got done before a single word is read.
    ///
    /// Grey rather than a second colour for the unfinished ones. This was green
    /// against red, and the accent turning lime collapsed that pair into two
    /// greens a foot apart on the same screen. Colour for the ones you finished,
    /// its absence for the ones you didn't, says the same thing with one hue.
    private var tint: Color {
        isComplete ? Theme.Palette.accent : Color(.systemGray)
    }

    /// The lime is bright enough to say its piece at a whisper; the grey needs
    /// more of itself to lift off the black at all.
    private var fillOpacity: Double { isComplete ? 0.16 : 0.20 }
    private var tileOpacity: Double { isComplete ? 0.22 : 0.26 }

    /// The Fitness Workout card, in Corner's colours.
    ///
    /// The shape is borrowed on purpose: a big glyph in the corner, the name of
    /// the thing in type you can read across a room, and the facts underneath as
    /// a row of equal tiles. What's left out is the play button — Fitness's cards
    /// launch a workout, and these are a record of one that already happened.
    /// Adding an action that looked like "start" to a card about the past would
    /// be the one part of that design that doesn't survive the translation.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "figure.boxing")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(tint)

                Spacer(minLength: 8)

                timestamp
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // The name is the headline now, where rounds used to be. That's the
            // Fitness construction — "Outdoor Walk" over its numbers — and it
            // reads better in a long list, where every card otherwise opened with
            // the same word.
            Text(record.title)
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            // Equal tiles across the width, the way the reference lays out its
            // three controls. Rounds always; the rest only when there's something
            // to say.
            HStack(spacing: 8) {
                statTile("figure.boxing", record.roundsCompleted == 1 ? "1 round" : "\(record.roundsCompleted) rounds")

                if let seconds = record.sessionSeconds, seconds >= 60 {
                    statTile("clock", "\(seconds / 60) min")
                }

                // Only when it's true. "Finished" on every other card is noise
                // that makes the one card carrying news harder to spot.
                if record.endedEarly {
                    statTile("flag.slash", "Ended early")
                } else if let focus = record.focuses.first {
                    statTile("target", focus)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(fillOpacity), in: .rect(cornerRadius: 26))
    }

    /// One fact, in a tile that shares the row equally with its siblings.
    private func statTile(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .padding(.horizontal, 10)
        .background(tint.opacity(tileOpacity), in: .rect(cornerRadius: 14))
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
                    .foregroundStyle(.black)
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

/// The open session, in the tab bar's accessory slot.
///
/// This is the iOS 26 `tabViewBottomAccessory` — the bar that floats above the
/// tab bar, where Apple Music keeps Now Playing. It replaces a green pill that
/// used to sit at the top of Home, and the move is the whole point: an open
/// session isn't part of any one screen, it's a state the app is in, and the
/// accessory is the system's slot for exactly that — present on every tab,
/// gone the moment there's nothing to resume.
///
/// Nothing here draws a background. The accessory is a system glass container;
/// giving it a fill of our own would be a card inside a card, and the reason to
/// use the native slot at all is to stop hand-drawing this chrome. So this is
/// only the contents: a mark, what the session is, and the count.
///
/// One line, because that's the height the slot gives. The full `ResumeCard` —
/// progress bar, big round count, a button — still lives on History, where
/// there's room to look at a session rather than just be reminded of one.
struct SessionAccessory: View {

    let session: UnfinishedSession
    let onResume: () -> Void

    /// Whether a round has actually been trained against this plan. A plan is
    /// stored the moment it's written — before the first bell — so "unfinished"
    /// and "ready to start" are genuinely different states, not one phrased two
    /// ways.
    private var hasStarted: Bool { session.done > 0 }

    var body: some View {
        // No hand-set padding, no pixel font sizes, no fixed play frame. The
        // accessory insets its own content and the type is semantic, so the
        // system places all of this on its own metrics the way it does Apple
        // Music's — the bar decides the margins and the sizes, not us.
        //
        // Two controls, not one wrapping button: the row is the main tap (the
        // whole label opens the session, as tapping Now Playing opens the
        // player), and the play is its own button beside it. That split is the
        // native shape — a labelled control with a trailing action.
        HStack {
            Button(action: onResume) {
                HStack {
                    artwork

                    // One line now. The round count moved out — the bar says
                    // what the session is, and the count is a detail for the
                    // History card, not for a glance from another tab.
                    Text(hasStarted ? "Session unfinished" : "Ready to start")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                hasStarted
                    ? "Session unfinished, \(session.done) of \(session.total) rounds. Resume."
                    : "Session ready to start, \(session.total) rounds. Start."
            )

            Button(action: onResume) {
                Image(systemName: "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Start")
        }
        // Breathing room off the accessory's edges. The system inset alone left
        // the art and the play sitting hard against the glass; this is the gap
        // Apple Music keeps between its content and the pill.
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        // The accessory takes the height of what it's handed, so this is what
        // sets it. A *minimum* rather than a fixed height: the padding above
        // still wins when the type grows, so Dynamic Type can push it taller but
        // never squeeze it shorter than this.
        .frame(minHeight: 84)
    }

    /// The leading square. A plain filled box, no mark inside — the album-art
    /// slot Apple Music keeps, the same footprint a real session thumbnail would
    /// take if there's ever one to show.
    ///
    /// The brand colour, not the hardcoded red it was: that value predated the
    /// accent moving to lime and was the last thing on the bar still carrying the
    /// old palette.
    private var artwork: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.Palette.accent)
            .frame(width: 36, height: 36)
    }
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
                Theme.Palette.dashboardSurface,
                in: .rect(cornerRadius: 18)
            )
    }
}
