import SwiftUI

/// The app's destinations. Four tabs and nothing else — anything that isn't one
/// of these is a sheet or the live session.
enum Page: String, CaseIterable, Identifiable {
    case home
    case history
    case coach
    case profile

    /// Not a page. It's the trailing button beside the tab bar — selecting it
    /// opens the setup sheet and hands the selection straight back, so it never
    /// becomes the current tab. It needs a case only because `Tab` is keyed by
    /// value and the detached slot has to have one.
    case create

    var id: String { rawValue }

    var title: String {
        switch self {
        // The app's name, not the screen's. Home is the first thing opened and
        // the large title is where iOS puts a wordmark.
        case .home: "CORNER"
        case .history: "History"
        // What the coach knows, not what it says. The page is a list of
        // standing instructions, and "Coach" is the shortest name for the thing
        // they're instructions to.
        case .coach: "Coach"
        case .profile: "Profile"
        case .create: "New session"
        }
    }

    /// Whether the navigation bar names the screen with a *large* title.
    ///
    /// False where the screen already introduces itself: Profile opens on a face
    /// and a name, and a large title above that is the same word twice. Home is
    /// false too, but for a different reason — it carries the app's wordmark as a
    /// leading bar item instead, because an inline title centres and this one is
    /// meant to sit on the left.
    var showsLargeTitle: Bool {
        switch self {
        case .home, .profile, .create: false
        case .history, .coach: true
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .history: "clock.arrow.circlepath"
        case .coach: "text.bubble.fill"
        case .profile: "person.crop.circle.fill"
        case .create: "plus"
        }
    }
}
