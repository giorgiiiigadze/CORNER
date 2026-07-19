import SwiftUI
// For the semantic `UIColor`s the palette is built from — `Color(.label)` and
// friends resolve through `Color.init(_: UIColor)`, which isn't visible on
// SwiftUI alone.
import UIKit

/// The whole design system. Native chrome, custom heart.
///
/// The accent is deliberately scarce: listening indicator, start action. Nothing
/// else. If everything is red, nothing is. The live screen's own two colours —
/// `Live.work` and `Live.resting` — aren't decoration and aren't the accent:
/// they're the state, and they're the only place green and red appear.
enum Theme {

    /// The chrome — home, history, settings. Dark, and read at arm's length with
    /// the phone in your hand.
    ///
    /// Every value here is a system semantic colour rather than a literal, which
    /// is the whole point: it's the grouped-background family Fitness and Health
    /// are built from, so the cards sit at exactly the lift the platform intends
    /// and the whole app matches its neighbours on the home screen. It also means
    /// Increase Contrast and the accessibility appearances are handled for free —
    /// a hand-mixed near-black gets none of that.
    enum Palette {
        /// True black under the cards, the way a grouped list reads in dark mode.
        static let background = Color(.systemGroupedBackground)

        /// Cards and rows, lifted off the background by a hair.
        static let surface = Color(.secondarySystemGroupedBackground)

        /// The one accent. Shared with the timer — it's the brand. #CC0404.
        static let accent = Color(red: 0.8, green: 0.016, blue: 0.016)

        static let primaryText = Color(.label)
        static let secondaryText = Color(.secondaryLabel)

        /// The header pills. A hair lighter than the background — enough to shape
        /// the row, not enough to shout.
        static let pill = Color(.tertiarySystemFill)

        /// Divider-weight. Borders and rules.
        static let hairline = Color(.separator)
    }

    /// The live timer. Light while the rest of the app is dark, and its own
    /// palette entirely: it's read across a gym, out of the corner of an eye,
    /// from a phone propped on a bench — not held. Every value here answers to
    /// that, not to taste.
    ///
    /// Nothing in here aliases `Palette` any more, and that's deliberate rather
    /// than duplication. These three used to borrow the chrome's values on the
    /// grounds that the app was "one thing" — but the chrome is dark now, and
    /// inheriting would have turned the work and rest washes into near-black
    /// backgrounds carrying dark green and dark red type, which is the one
    /// combination this screen cannot survive. It's pinned to its own literals
    /// so a future change to the chrome can't reach in here again.
    enum Live {
        /// Before the first bell, and after the last. The off-white the chrome
        /// used to be, kept because the pale washes below are built to sit
        /// against it.
        static let background = Color(red: 0.973, green: 0.969, blue: 0.961)

        /// The screen while the round runs. Pale on purpose: it has to carry
        /// near-black type and a dark green clock, so it's a wash of colour
        /// rather than a green — enough to answer "is it on?" from the corner of
        /// an eye, not enough to fight the numbers sitting on it.
        static let workBackground = Color(red: 0.87, green: 0.94, blue: 0.87)

        static let accent = Palette.accent

        /// The clock while the round is running, and the bar filling under it.
        /// Dark for a green, because it has to hold up on a pale wash — the
        /// bright greens read as mint at three metres and vanish.
        static let work = Color(red: 0.10, green: 0.52, blue: 0.24)

        /// `work`, lifted to survive the dark chrome.
        ///
        /// The same green in the same family, and it has to be a second value
        /// rather than a reuse: `work` is dark *on purpose*, tuned against a
        /// near-white wash, and dropping it onto a `#1C1C1E` card leaves a
        /// bottle-green smudge you can't read at arm's length — the exact
        /// failure `work`'s own comment describes, mirrored. This is what the
        /// chrome uses when it wants to say "trained".
        static let workOnDark = Color(red: 0.20, green: 0.78, blue: 0.35)

        /// The clock while resting. Built to the same recipe as `work` and for
        /// the same reason: dark, because it sits on a pale background too.
        static let resting = Color(red: 0.70, green: 0.12, blue: 0.10)

        /// The screen while you breathe. The same wash as `workBackground` with
        /// the red channel lifted instead of the green — the two states are one
        /// construction in two hues, so neither can drift.
        static let restBackground = Color(red: 0.94, green: 0.87, blue: 0.87)

        /// One ink for every state now that all three backgrounds are pale. Not
        /// `Color(.label)`: that inverts to white in dark mode, and these sit on
        /// a screen that stays pale no matter what the system is doing.
        static let primaryText = Color(white: 0.09)
        static let secondaryText = Color(white: 0.45)
    }

    enum Layout {
        static let gutter: CGFloat = 24
        static let stackSpacing: CGFloat = 16
    }

    /// Sized to be read from across a room, not from arm's length.
    enum Fonts {
        /// Heavier than it was: on a light screen a bold numeral thins out at
        /// three metres in a way it doesn't on black.
        static func timer(_ size: CGFloat = 120) -> Font {
            .system(size: size, weight: .heavy, design: .rounded).monospacedDigit()
        }

        /// The one line of coaching on screen. Sized to be read from wherever the
        /// phone ended up, which is the whole reason it's this big.
        static let focus = Font.system(size: 56, weight: .black, design: .default)
        static let roundLabel = Font.system(size: 22, weight: .semibold, design: .rounded)

        /// Names the number above it. Small, grey, and never the thing you read
        /// from across the room — it's there for the glance where you've lost
        /// track of what you're looking at.
        static let caption = Font.system(size: 15, weight: .semibold)
    }
}

extension View {
    /// The whole screen states the round: green while it runs, red while you
    /// breathe, off-white when nothing is happening.
    ///
    /// Takes the colour rather than a `resting` flag — the caller knows the
    /// phase, and there are three states to say, not two.
    func cornerBackground(_ color: Color) -> some View {
        background(
            color
                .animation(.smooth(duration: 0.6), value: color)
                .ignoresSafeArea()
        )
    }
}
