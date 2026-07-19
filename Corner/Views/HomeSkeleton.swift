import SwiftUI

/// What's on screen while the stored session is being checked.
///
/// The shape of Home rather than a spinner in the middle of nothing. A spinner
/// says "something is happening"; this says "your dashboard is coming, and here
/// is where each piece will be" — so the real content arrives into a layout the
/// eye has already settled on instead of replacing a blank screen.
///
/// Deliberately dumb: no data, no state, nothing to get wrong. It mirrors Home's
/// metrics — the same 8pt gutter, 18pt corners and square tiles — so the swap is
/// a fade rather than a jump.
struct HomeSkeleton: View {

    /// One slow breath, not a shimmer sweep. This screen is up for a few hundred
    /// milliseconds on a warm start; anything faster reads as a glitch, and
    /// anything travelling across the screen draws the eye to the wait itself.
    @State private var dim = false

    private let gap = SummaryCards.gap

    var body: some View {
        // Explicit gaps, not one uniform spacing. The real screen doesn't use
        // one: 26 under the masthead, 8 between the dashboard's own cards, 20
        // before Recent sessions. A single value made the tiles sit ~18pt low.
        VStack(alignment: .leading, spacing: 0) {
            week
            hero
                .padding(.top, 20)
            tiles
                .padding(.top, gap)
            recent
                .padding(.top, 20)
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

    /// The calendar's cells, at the calendar's own metrics.
    ///
    /// Eight of them at a fixed `WeekStrip.slot`, not seven spread across the
    /// width. The real strip scrolls and parks on today, so eight columns are on
    /// screen with the first one clipped — seven even thirds put every circle in
    /// the wrong place and the difference showed the instant the real one
    /// arrived.
    ///
    /// The width is read off `WeekStrip` rather than copied. A placeholder whose
    /// job is to be the same shape as something else shouldn't hold its own
    /// opinion about that shape.
    private var week: some View {
        HStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { _ in
                VStack(spacing: 6) {
                    // 13, matching a `caption2` line box rather than the 10 that
                    // looked about right — the strip is short by three points a
                    // row otherwise, and everything under it rides up.
                    block(width: 24, height: 13, corner: 3)
                    Circle()
                        .fill(fill)
                        .frame(width: 34, height: 34)
                }
                // The real cells carry this to reserve room for today's
                // highlight. Without it the placeholder strip is 22pt shorter
                // and the whole dashboard below sits high, which is what made
                // the swap jump.
                .padding(.vertical, 11)
                .padding(.horizontal, 4)
                .frame(width: WeekStrip.slot)
            }
        }
        // Anchored right, like the strip it stands in for: that one opens
        // scrolled to today, so it's the leading edge that runs off screen.
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var hero: some View {
        // 202: title, caption, the 44pt number and a 68pt chart, plus the card's
        // own padding. Measured off the real card rather than guessed — 190 left
        // the tiles under it 12pt high.
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(fill)
            .frame(height: 202)
    }

    private var tiles: some View {
        HStack(spacing: gap) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(fill)
                .aspectRatio(1, contentMode: .fit)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(fill)
                .aspectRatio(1, contentMode: .fit)
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: gap) {
            block(width: 140, height: 18, corner: 5)
                .padding(.leading, 4)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(fill)
                .frame(height: 96)
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
