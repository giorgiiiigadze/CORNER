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

        /// The raised cards — dashboard tiles and session cards. A touch lighter
        /// than `surface`'s dark resolve, pinned to an exact value so they read
        /// the same on every device rather than tracking the system grey. #212122.
        static let dashboardSurface = Color(red: 0.129, green: 0.129, blue: 0.133)

        /// The one accent. Shared with the timer — it's the brand. #FF002F.
        static let accent = Color(red: 1.0, green: 0.0, blue: 0.184)

        /// The same red, lifted. #FF3333.
        ///
        /// For the small marks: the identity square, the streak flame, the ring
        /// on a day that was trained. `accent` is mixed for large fills against
        /// white — on a black screen, at the size of a 2pt ring or a 14pt glyph,
        /// it goes muddy and stops reading as red at all. This is the same hue
        /// with the brightness a small mark needs to survive.
        ///
        /// Two values rather than one everywhere, because the failure runs both
        /// ways: this one on a full-width button would glare.
        static let accentLight = Color(red: 1.0, green: 0.2, blue: 0.2)

        static let primaryText = Color(.label)
        static let secondaryText = Color(.secondaryLabel)

        /// The header pills. A hair lighter than the background — enough to shape
        /// the row, not enough to shout.
        static let pill = Color(.tertiarySystemFill)

        /// Divider-weight. Borders and rules.
        static let hairline = Color(.separator)

        /// The Rounds sparkline. Health's blue, read off a screenshot rather
        /// than sampled — nudge it here if it's a shade out.
        ///
        /// Not the accent, and that's the point of it being a different hue
        /// entirely: red on this screen means "this is the day the numbers are
        /// describing", and a chart drawn in the same red made every bar look
        /// like it was making that claim.
        static let chart = Color(red: 0.04, green: 0.65, blue: 0.94)

        /// The rules behind the bars. Barely there — they exist to give the
        /// bars a floor to stand on, not to be read.
        static let chartGrid = Color(white: 1).opacity(0.08)
    }

    /// The live timer. Black, and its own palette entirely: it's read across a
    /// gym, out of the corner of an eye, from a phone propped on a bench — not
    /// held. Every value here answers to that, not to taste.
    ///
    /// **This screen used to be light, and the reversal is worth recording.**
    /// The pale version's argument was that a bright screen carries further
    /// across a room, and it does — but it was carrying a *wash*: work and rest
    /// were said by tinting the whole background pale green or pale red, which
    /// meant every value here was tuned to survive sitting on a tint. That's why
    /// the clock was a dark bottle green, and why an off-white background needed
    /// its own near-black ink.
    ///
    /// Black moves the state off the field and into the marks. The clock and the
    /// round bars carry the colour now, against a background that never changes,
    /// which is how the Fitness and Workout screens this is modelled on do it —
    /// and a saturated green numeral on black is louder at three metres than a
    /// dark one on a pale wash ever was. The washes are gone rather than
    /// darkened: a deep green field behind a green clock is the one thing that
    /// would undo the contrast this buys.
    ///
    /// Nothing in here aliases `Palette`, which is deliberate rather than
    /// duplication. The chrome is grouped-list dark; this is true black with its
    /// own lifted greens and reds, and the two have drifted apart before. Pinned
    /// to literals so a change to the chrome can't reach in here again.
    enum Live {
        /// Every phase, start to finish. It does not change — the marks on it do.
        static let background = Color.black

        /// The floating control panel at the foot of the screen.
        ///
        /// `#1C1C1E`, which is what `Palette.surface` resolves to in the dark —
        /// so the panel is the same grey as a card on Home, and the app has one
        /// colour for "a surface with things on it" rather than two that nearly
        /// match. Written as a literal rather than reaching for
        /// `secondarySystemGroupedBackground` because everything in `Live` is
        /// pinned: the semantic colour follows the system appearance and this
        /// screen doesn't.
        static let panel = Color(red: 0.110, green: 0.110, blue: 0.118)

        /// The circular controls inside the panel. `#2A2A2B` — lifted off the
        /// panel by about the step the panel is lifted off the black, so the
        /// stack reads as two even steps of depth rather than three arbitrary
        /// greys.
        static let control = Color(red: 0.165, green: 0.165, blue: 0.169)

        static let accent = Palette.accentLight

        /// The clock while the round is running, and the bars filling under it.
        ///
        /// Saturated and light for a green, which is the exact inverse of what
        /// this value used to be: on black, the dark bottle green it was tuned to
        /// be on a pale wash disappears into the background at any distance.
        static let work = Color(red: 0.20, green: 0.78, blue: 0.35)

        /// The clock while resting. Same recipe as `work`, same reason — lifted
        /// to survive black, not dropped to survive a pale wash.
        static let resting = Color(red: 1.0, green: 0.27, blue: 0.24)

        /// One ink for every state now that the background never moves. Not
        /// `Color(.label)`: that follows the system appearance, and this screen
        /// is black whatever the phone is set to.
        static let primaryText = Color.white
        static let secondaryText = Color(white: 0.56)

        /// Unfilled round bars, and any rule that has to be visible without
        /// being read.
        static let track = Color(white: 0.22)
    }

    enum Layout {
        static let gutter: CGFloat = 24
        static let stackSpacing: CGFloat = 16

        /// The corner on every full-width button in the app.
        ///
        /// A rounded rectangle rather than a capsule. At these heights a capsule
        /// has no straight edge left at all, which reads as a pill — a thing you
        /// toggle or a label you don't press. This keeps a flat run through the
        /// middle, so it still reads as a button.
        ///
        /// Roughly a third of the button's height, which is the proportion that
        /// holds whether the button is 44 or 52 tall. One constant because four
        /// screens draw this button and they were four separate literals away
        /// from disagreeing.
        static let buttonCorner: CGFloat = 20
    }

    /// The shape every full-width button is cut to. Continuous, matching the
    /// system's own controls rather than the tighter circular curve.
    static var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Layout.buttonCorner, style: .continuous)
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
