import SwiftUI

/// The app's destinations. Four tabs and nothing else — anything that isn't one
/// of these is a sheet or the live session.
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
