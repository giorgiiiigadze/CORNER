import SwiftUI

/// The app's destinations. Four tabs and nothing else — anything that isn't one
/// of these is a sheet or the live session.
enum Page: String, CaseIterable, Identifiable {
    case home
    case coach
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
        case .coach: "Coach"
        case .history: "History"
        case .profile: "Profile"
        case .create: "New session"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .coach: "figure.boxing"
        case .history: "clock.arrow.circlepath"
        case .profile: "person.crop.circle.fill"
        case .create: "plus"
        }
    }
}
