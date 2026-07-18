import SwiftUI

/// The hero card at the top of Home: what you're doing today, and the one button
/// that starts it.
///
/// Deliberately knows nothing about SwiftData, the generator, or navigation. It
/// takes a `State` and two closures, which is what lets it be previewed in every
/// condition it can be in — including the loading one, which is otherwise the
/// hardest state in the app to see, since it lasts about a second and only when
/// the network cooperates.
///
/// It covers all three states Home can be in, not two: nothing written yet,
/// writing, written. That's what lets it be the only call to action on the
/// screen — Home used to also pin "Write me a session" to the bottom, and two
/// full-width red capsules that both mean "go" is one too many.
///
/// Dark, on a light screen, on purpose. Everything else on Home is off-white
/// with black type; the card is the inverse, so the eye lands on it first and
/// the red button sits on a surface that makes it look like a button rather than
/// a warning.
struct TodaySessionCard: View {

    /// What the card draws. A value type rather than the `Session` struct or the
    /// `TodaySession` model, so the card can't accidentally start depending on
    /// rounds, JSON, or a store it has no business touching.
    struct Plan: Equatable {
        /// Two or three words. The headline — the reason today isn't yesterday.
        var focus: String
        /// One line, under the headline. Claude's opener.
        var subtitle: String
        var roundCount: Int
        var totalSeconds: Int
        /// Who wrote it. On screen, always — see `originLabel`.
        var origin: SessionOrigin

        /// "6 rounds · 18 min". Built here rather than passed in, so every caller
        /// gets the same sentence.
        var meta: String {
            let minutes = max(1, totalSeconds / 60)
            let rounds = roundCount == 1 ? "1 round" : "\(roundCount) rounds"
            return "\(rounds) · \(minutes) min"
        }
    }

    enum State: Equatable {
        /// No session written yet. The card is the invitation.
        case empty
        /// The cornerman is still writing. No plan to draw yet.
        case loading
        case ready(Plan)
    }

    let state: State

    /// Starts the session on the card. Never called in `.empty` or `.loading` —
    /// there's nothing to start.
    let onStart: () -> Void

    /// Asks for a session: a different one in `.ready`, the first one in
    /// `.empty`. One closure rather than two because it's one job — the caller
    /// runs the same generator either way.
    let onRegenerate: () -> Void

    private static let corner: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow

            switch state {
            case .empty:
                empty
            case .loading:
                loading
            case .ready(let plan):
                ready(plan)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color("CardSurface"), in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        // The card is the one dark object on a light screen, so it gets the one
        // shadow too — without it the corners read as a hole rather than a card.
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        // The states are different heights; without this the card snaps.
        .animation(.snappy(duration: 0.35), value: state)
    }

    private var eyebrow: some View {
        Text("TODAY")
            .font(.system(size: 12, weight: .heavy))
            .kerning(1.4)
            .foregroundStyle(Color("CardSecondaryText"))
            .padding(.bottom, 10)
    }

    // MARK: - Ready

    private func ready(_ plan: Plan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headline(plan.focus)

            // Four lines, not three. The subtitle is Claude's `intro`, which is
            // written to be *spoken* before round one rather than read off a
            // card, so it runs long — at three lines a real generated session
            // cut off mid-word. Still bounded, because an intro that wants six
            // lines is pushing the Start button off the screen.
            Text(plan.subtitle)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color("CardSecondaryText"))
                .lineLimit(4)
                .padding(.top, 8)

            Text(plan.meta)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color("CardSecondaryText"))
                .monospacedDigit()
                .padding(.top, 14)

            originLabel(plan.origin)
                .padding(.top, 6)

            startButton
                .padding(.top, 20)

            regenerateButton
                .padding(.top, 4)
        }
        // One announcement rather than four, and the buttons stay separate.
        .accessibilityElement(children: .contain)
    }

    /// Says plainly whether Claude wrote this or whether it's the shipped JSON.
    ///
    /// Carried over from the row this card replaced, and not optional: silently
    /// serving a fallback would make the product's central claim impossible to
    /// evaluate. Quiet rather than coloured — it's a fact to be checked, not a
    /// badge to be shown off.
    @ViewBuilder
    private func originLabel(_ origin: SessionOrigin) -> some View {
        switch origin {
        case .claude:
            Label("Written for you just now", systemImage: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color("CardSecondaryText"))
        case .bundled(let reason):
            Label("Offline session \u{2014} \(reason)", systemImage: "wifi.slash")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color("CardSecondaryText"))
        }
    }

    private var startButton: some View {
        primaryButton("Start", action: onStart)
            .accessibilityHint("Begins today's session")
    }

    /// Quiet on purpose. It's the escape hatch, not the offer — a second button
    /// with equal weight would make the card a question instead of an answer.
    private var regenerateButton: some View {
        Button(action: onRegenerate) {
            Text("Something else")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color("CardSecondaryText"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(.rect)
        }
        .buttonStyle(PressableCardButton())
        .accessibilityHint("Writes a different session")
    }

    // MARK: - Empty

    /// No session yet. The card asks for one rather than sitting there empty, so
    /// Home never needs a separate call to action underneath it.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline("Nothing yet")

            Text("Tell the cornerman how long you've got and what you want to work on.")
                .font(.system(size: 16))
                .foregroundStyle(Color("CardSecondaryText"))
                .lineLimit(3)
                .padding(.top, 8)

            primaryButton("Write me a session", action: onRegenerate)
                .padding(.top, 20)
                .accessibilityHint("Writes today's session")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Loading

    /// Shaped like the ready state rather than a spinner in the middle —
    /// headline, a line under it, and a button-sized block where the button
    /// goes. It is still shorter than the ready card (there's no meta row and no
    /// second button), so the card does grow when the session lands; the point
    /// is that it grows rather than rearranging.
    private var loading: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(Color("CardSecondaryText"))
                Text("Writing your session\u{2026}")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color("CardPrimaryText"))
            }

            Text("The cornerman is reading what you've been working on.")
                .font(.system(size: 16))
                .foregroundStyle(Color("CardSecondaryText"))
                .lineLimit(2)
                .padding(.top, 10)

            // Where the button will be, so the card doesn't grow under the
            // thumb at the moment the fighter reaches for it.
            Capsule()
                .fill(Color("CardSecondaryText").opacity(0.18))
                .frame(height: 52)
                .padding(.top, 20)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Writing your session")
    }

    // MARK: - Pieces

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 34, weight: .black, design: .default))
            .foregroundStyle(Color("CardPrimaryText"))
            .lineLimit(2)
            // The headline is two or three words by contract, but nothing stops
            // Claude returning five — better to shrink than to clip.
            .minimumScaleFactor(0.7)
    }

    /// The red capsule. One definition, so `.empty` and `.ready` can't drift.
    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(Color("CardStart"), in: Capsule())
        }
        .buttonStyle(PressableCardButton())
    }
}

/// The dip a card button gives back under a thumb. Same idea as the old header
/// pills — acknowledgement, not a performance.
private struct PressableCardButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Previews

#Preview("Ready") {
    TodaySessionCard(
        state: .ready(
            TodaySessionCard.Plan(
                focus: "Straight punches",
                subtitle: "Turn the hip, don't arm it. Six rounds, and the last two are where it counts.",
                roundCount: 6,
                totalSeconds: 1_080,
                origin: .claude
            )
        ),
        onStart: {},
        onRegenerate: {}
    )
    .padding(Theme.Layout.gutter)
    .background(Theme.Palette.background)
}

#Preview("Empty") {
    TodaySessionCard(state: .empty, onStart: {}, onRegenerate: {})
        .padding(Theme.Layout.gutter)
        .background(Theme.Palette.background)
}

#Preview("Loading") {
    TodaySessionCard(state: .loading, onStart: {}, onRegenerate: {})
        .padding(Theme.Layout.gutter)
        .background(Theme.Palette.background)
}

/// The offline case. Worth its own preview because the disclosure line is the
/// longest thing on the card and the one most likely to wrap badly.
#Preview("Offline") {
    TodaySessionCard(
        state: .ready(
            TodaySessionCard.Plan(
                focus: "Counter-punching off the back foot",
                subtitle: "Let them lead. You're not chasing today \u{2014} you're waiting, then answering.",
                roundCount: 12,
                totalSeconds: 2_400,
                origin: .bundled(reason: "no signal")
            )
        ),
        onStart: {},
        onRegenerate: {}
    )
    .padding(Theme.Layout.gutter)
    .background(Theme.Palette.background)
}

/// Every state at once, which is the only way to check they're a family.
#Preview("States") {
    ScrollView {
        VStack(spacing: 16) {
            TodaySessionCard(state: .empty, onStart: {}, onRegenerate: {})
            TodaySessionCard(state: .loading, onStart: {}, onRegenerate: {})
            TodaySessionCard(
                state: .ready(
                    TodaySessionCard.Plan(
                        focus: "Body shots",
                        subtitle: "Get under it and dig.",
                        roundCount: 4,
                        totalSeconds: 720,
                        origin: .claude
                    )
                ),
                onStart: {},
                onRegenerate: {}
            )
        }
        .padding(Theme.Layout.gutter)
    }
    .background(Theme.Palette.background)
}
