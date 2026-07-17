import ActivityKit
import Foundation

/// What the Lock Screen and the Dynamic Island are told about a running
/// session — and nothing else. Compiled into the app and the widget extension
/// both; ActivityKit matches the two sides up by this type's name and its
/// JSON encoding, so this one file is the contract.
///
/// `nonisolated` for the same reason the models are: both targets build with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and ActivityKit encodes and
/// decodes these off the main actor.
nonisolated struct SessionActivityAttributes: ActivityAttributes {

    /// The session's phase, reduced to what a glance at the Lock Screen can
    /// use. `announcing` is the opener being spoken — a round named but not
    /// yet started, so there's no clock to show for it.
    nonisolated enum Phase: String, Codable, Hashable {
        case announcing
        case work
        case rest
        case paused
        case done
    }

    nonisolated struct ContentState: Codable, Hashable {
        var phase: Phase
        var roundIndex: Int
        var totalRounds: Int
        var focus: String

        /// When the running countdown lands. The system ticks the widget's
        /// clock toward this on its own, so the app only speaks up at
        /// transitions — bell, pause, resume — never once a second.
        /// Nil whenever no clock is running.
        var endsAt: Date?

        /// The clock, frozen, for the paused card — a timer that kept
        /// falling through a pause would be lying about the time.
        var secondsRemaining: Int
    }

    /// The session's title. Fixed for the life of the activity.
    var title: String
}
