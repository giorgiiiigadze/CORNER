import SwiftUI

/// What's on screen while the stored session is being checked.
///
/// The shape of Home rather than a spinner in the middle of nothing. A spinner
/// says "something is happening"; this says "your week is coming, and here is
/// where it will be" — so the real content arrives into a layout the eye has
/// already settled on instead of replacing a blank screen.
///
/// Deliberately dumb: no data, no state, nothing to get wrong. It mirrors the
/// week strip's metrics so the swap is a fade rather than a jump — which means
/// it has to be re-measured whenever those move. It drew a hero card, two square
/// tiles and a recent-sessions block until the dashboard was removed from Home;
/// a skeleton promising content that never arrives is worse than no skeleton.
struct HomeSkeleton: View {

    /// One slow breath, not a shimmer sweep. This screen is up for a few hundred
    /// milliseconds on a warm start; anything faster reads as a glitch, and
    /// anything travelling across the screen draws the eye to the wait itself.
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            week
            Spacer()
        }
        .padding(.horizontal, 16)
        // Measured against the real screen rather than derived: Home's content
        // sits in a `NavigationStack` and a `List`, and reproducing those
        // containers here didn't reproduce their insets, so this is read off a
        // screenshot instead.
        //
        // It's a constant that has to be re-measured whenever Home's top
        // spacing moves — it was 37 until the list's top content margin was
        // trimmed, which lifted the real calendar and left this 21pt high.
        // If the calendar ever jumps on load, this is the line.
        .padding(.top, 58)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.background)
        .opacity(dim ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        // One element to VoiceOver, and it says what's happening. Seven unlabelled
        // grey rectangles is worse than silence.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading your training")
    }

    // MARK: - Pieces

    private var week: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { _ in
                VStack(spacing: 6) {
                    // 13, matching a `caption2` line box rather than the 10 that
                    // looked about right — the strip is short by three points a
                    // row otherwise.
                    block(width: 24, height: 13, corner: 3)
                    // 42, tracking `WeekStrip`'s day circles. Move one and this
                    // has to move with it or the strip jumps on load.
                    Circle()
                        .fill(fill)
                        .frame(width: 42, height: 42)
                }
                // The real cells carry this to reserve room for today's
                // highlight. Without it the placeholder strip is 22pt shorter
                // and everything below sits high, which is what made the swap
                // jump.
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Parts

    /// The card grey, one step down from a real card so the placeholder doesn't
    /// pass for content that's finished loading.
    private var fill: Color { Color(.tertiarySystemFill) }

    private func block(width: CGFloat, height: CGFloat, corner: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(fill)
            .frame(width: width, height: height)
    }
}

#Preview {
    HomeSkeleton()
        .preferredColorScheme(.dark)
}
