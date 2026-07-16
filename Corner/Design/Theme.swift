import SwiftUI

/// The whole design system. Native chrome, custom heart.
///
/// The accent is deliberately scarce: active timer, listening indicator, start action.
/// Nothing else. If everything is red, nothing is.
enum Theme {

    enum Palette {
        /// True black. OLED, and a dark garage at 7am.
        static let background = Color.black

        /// The one accent.
        static let accent = Color(red: 1.0, green: 0.29, blue: 0.16)

        /// Rest state. A "breathe" signal readable from across the room by peripheral vision alone.
        static let rest = Color(red: 0.04, green: 0.24, blue: 0.24)

        static let primaryText = Color.white
        static let secondaryText = Color(white: 0.55)
    }

    enum Layout {
        static let gutter: CGFloat = 24
        static let stackSpacing: CGFloat = 16
    }

    /// Sized to be read from across a room, not from arm's length.
    enum Fonts {
        static func timer(_ size: CGFloat = 128) -> Font {
            .system(size: size, weight: .bold, design: .rounded).monospacedDigit()
        }

        static let combo = Font.system(size: 64, weight: .black, design: .default)
        static let roundLabel = Font.system(size: 22, weight: .semibold, design: .rounded)
    }
}

extension View {
    /// Rest inverts the screen so peripheral vision alone tells you the state.
    func cornerBackground(resting: Bool) -> some View {
        background(
            (resting ? Theme.Palette.rest : Theme.Palette.background)
                .animation(.smooth(duration: 0.6), value: resting)
                .ignoresSafeArea()
        )
    }
}
