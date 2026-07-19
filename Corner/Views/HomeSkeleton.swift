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
            masthead
            week
                .padding(.top, 26)
            hero
                .padding(.top, 20)
            tiles
                .padding(.top, gap)
            recent
                .padding(.top, 20)
            Spacer()
        }
        .padding(.horizontal, 16)
        // Measured, not guessed, and this is the honest version of the comment:
        // Home's masthead sits inside a `NavigationStack` and a `List`, and the
        // inset those add came to 37pt on an iPhone 17 simulator. Reproducing
        // the containers here didn't reproduce the inset — a plain list styles
        // differently from the grouped one Home uses — so the number is taken
        // from the screen rather than derived. It's a nav bar's worth of space
        // and shouldn't move between devices, but it's a constant to re-check
        // if the masthead ever looks like it jumps on load.
        .padding(.top, 37)
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

    private var masthead: some View {
        HStack(spacing: 10) {
            block(width: 34, height: 34, corner: 9)
            block(width: 120, height: 26, corner: 8)
            Spacer(minLength: 8)
            block(width: 72, height: 34, corner: 17)
        }
        .padding(.horizontal, 4)
    }

    private var week: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { _ in
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
                .frame(maxWidth: .infinity)
            }
        }
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
