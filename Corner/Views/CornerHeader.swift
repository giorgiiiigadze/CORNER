import SwiftUI

/// Which page the header is showing. The app is three destinations and nothing
/// else — anything that isn't one of these is a sheet or the live session.
enum Page: String, CaseIterable, Identifiable {
    case home
    case coach
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .coach: "Coach"
        case .history: "History"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .coach: "figure.boxing"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape.fill"
        }
    }
}

/// The top bar: a row of pills, the selected one carrying the label and the rest
/// reduced to icons.
///
/// A tab bar in everything but position. It lives at the top because the bottom
/// of the screen is where the session starts, and a tab bar down there would put
/// navigation under the thumb that's reaching for "Write me a session".
struct CornerHeader: View {

    @Binding var page: Page

    private static let spacing: CGFloat = 8

    /// 44 is not a taste call: it's Apple's minimum touch target, and the row
    /// was under it at 38.
    private static let height: CGFloat = 44

    /// The selected pill's share of the row. The rest split what's left, so the
    /// selected one runs a bit over twice the width of a plain one — enough that
    /// the row has an obvious subject, not so much that the others become
    /// garnish.
    private static let selectedShare: CGFloat = 0.44

    /// Fixed because the row can't measure itself: `.frame(maxWidth: .infinity)`
    /// accepts whatever it's offered, so an HStack of them always lands on equal
    /// shares no matter what layout priority says — the higher-priority pill
    /// simply eats the row and leaves the others at zero. Real proportions need
    /// a real width, which is what the GeometryReader is for.
    var body: some View {
        GeometryReader { proxy in
            let widths = widths(in: proxy.size.width)

            HStack(spacing: Self.spacing) {
                ForEach(Page.allCases) { candidate in
                    pill(for: candidate)
                        .frame(width: widths[candidate] ?? 0)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: Self.height)
        .padding(.horizontal, Theme.Layout.gutter)
        .padding(.vertical, 10)
        // No background, so the bar is the pills and nothing else — the list
        // scrolls through the gaps between them rather than under a slab.
        // On the value, not inside the button's action: a swipe changes `page`
        // from inside TabView, which knows nothing about our `withAnimation`.
        // Animating the binding itself is what makes the pill follow a swipe and
        // a tap identically — which is the point, since they're the same move.
        .animation(.snappy(duration: 0.3), value: page)
    }

    /// Splits the row: `selectedShare` to the selected pill, the remainder
    /// divided evenly among the others.
    ///
    /// Clamped at the bottom so a plain pill never drops below a 44pt touch
    /// target — with four pages on the narrowest iPhone the arithmetic gets
    /// close, and a pill too small to hit is worse than a less dramatic row.
    private func widths(in total: CGFloat) -> [Page: CGFloat] {
        let count = Page.allCases.count
        let available = max(0, total - Self.spacing * CGFloat(count - 1))
        let others = CGFloat(count - 1)

        var plain = available * (1 - Self.selectedShare) / others
        plain = max(plain, min(44, available / CGFloat(count)))
        let selected = available - plain * others

        return Dictionary(uniqueKeysWithValues: Page.allCases.map {
            ($0, $0 == page ? selected : plain)
        })
    }

    /// Selection is carried by the label and the ink, not the fill: every pill
    /// is the same grey, exactly as in Notion's bar. That means colour alone
    /// never has to be the signal.
    private func pill(for candidate: Page) -> some View {
        let selected = candidate == page

        return Button {
            page = candidate
        } label: {
            HStack(spacing: 7) {
                Image(systemName: candidate.icon)
                    .font(.system(size: 15, weight: .semibold))
                if selected {
                    Text(candidate.title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        // The label is the selection signal, so it arrives and
                        // leaves rather than blinking: it grows out of the icon
                        // it sits beside and collapses back toward it.
                        .transition(
                            .scale(scale: 0.7, anchor: .leading)
                            .combined(with: .opacity)
                        )
                }
            }
            .foregroundStyle(selected ? Theme.Palette.primaryText : Theme.Palette.secondaryText)
            // The width comes from `widths(in:)` above; this only has to fill it.
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(Capsule().fill(Theme.Palette.pill))
            // The capsule is the thing changing width, so it has to be the thing
            // that clips — otherwise the outgoing label spills past its edge for
            // the length of the animation.
            .clipShape(.capsule)
        }
        .buttonStyle(PressablePill())
        .accessibilityLabel(candidate.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// Gives the pill something to say under a thumb.
///
/// `.plain` reports nothing on press, which on a flat grey capsule means a tap
/// that misses its target and a tap that lands look identical until the page
/// changes. The dip is small on purpose — acknowledgement, not a performance.
private struct PressablePill: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            // Faster than the page change: the press should feel like it's
            // tracking the finger, not waiting on the animation.
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview {
    @Previewable @State var page = Page.home

    VStack {
        CornerHeader(page: $page)
        Spacer()
    }
    .background(Theme.Palette.background)
}
