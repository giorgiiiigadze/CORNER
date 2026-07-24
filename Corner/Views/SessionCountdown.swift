import SwiftUI

/// "Get ready" — the few seconds between saying go and the first bell.
///
/// The shape Fitness uses to start a workout, and it's the right one: a ring
/// draining around one enormous digit, with the thing you're about to do named
/// underneath. Nothing here is a control. It's a beat to put the phone down and
/// get your hands up, and its length is the fighter's own choice in Settings.
///
/// Drawn over the live screen rather than as its own presentation, so the session
/// behind it is already built and the first bell lands the instant this clears.
struct SessionCountdown: View {

    /// Seconds left, counting down. The engine owns this — see
    /// `SessionEngine.countdownRemaining` — so it covers the button and "let's
    /// go" alike.
    let remaining: Int

    /// The full length, so the ring knows what a full circle means.
    let total: Int

    /// What's about to start, named under the ring.
    let title: String

    private var progress: Double {
        guard total > 0 else { return 0 }
        return Double(remaining) / Double(total)
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // The mark above the ring, the way Fitness puts the activity's glyph
            // over its countdown.
            Image(systemName: "figure.boxing")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.Live.accent)
                .frame(width: 62, height: 62)
                .background(Theme.Live.accent.opacity(0.18), in: .circle)

            ZStack {
                Circle()
                    .stroke(Theme.Live.accent.opacity(0.25), lineWidth: 14)

                // Drains anticlockwise as the seconds go, so the arc that's left
                // *is* the time that's left.
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.Live.accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: remaining)

                Text("\(remaining)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: remaining)
                    .monospacedDigit()
            }
            .frame(width: 240, height: 240)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 32)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Live.background)
        // One announcement rather than a digit read out three times.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Starting in \(remaining) seconds")
    }
}

#Preview {
    SessionCountdown(remaining: 3, total: 3, title: "Outdoor Walk")
        .preferredColorScheme(.dark)
}
