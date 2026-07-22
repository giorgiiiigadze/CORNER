import SwiftUI

/// The app's destinations. Three tabs and nothing else — anything that isn't one
/// of these is a sheet or the live session.
enum Page: String, CaseIterable, Identifiable {
    case home
    case history
    case profile

    /// Not a page. It's the trailing button beside the tab bar — selecting it
    /// opens the setup sheet and hands the selection straight back, so it never
    /// becomes the current tab. It needs a case only because `Tab` is keyed by
    /// value and the detached slot has to have one.
    case create

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .profile: "Profile"
        case .create: "New session"
        }
    }

    /// Whether the navigation bar names the screen.
    ///
    /// False where the screen already introduces itself: Home's toolbar is its
    /// header, and Profile opens on a face and a name. A large title above
    /// either is the same word twice.
    var showsLargeTitle: Bool {
        switch self {
        case .home, .profile, .create: false
        case .history: true
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .history: "clock.arrow.circlepath"
        case .profile: "person.crop.circle.fill"
        case .create: "plus"
        }
    }
}
