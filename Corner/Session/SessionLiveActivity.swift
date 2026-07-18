// `@preconcurrency` because ActivityKit hasn't been audited for `Sendable`:
// `Activity` is a plain class, and `update`/`end` are nonisolated `async`, so
// calling them from this `@MainActor` class reads as sending a non-Sendable
// value across isolation. ActivityKit is documented as callable from any
// thread, so the risk Swift 6 is flagging isn't real here — this downgrades it
// to a warning for this one import rather than asserting `@unchecked Sendable`
// over Apple's type ourselves.
@preconcurrency import ActivityKit
import Foundation

/// The session's presence on the Lock Screen and in the Dynamic Island.
///
/// A thin shell around one `Activity`: requested the first time the engine has
/// something to show, updated at transitions, torn down with the session.
/// Deliberately not the engine's business — the engine keeps time, and this is
/// a mirror of it, owned by the screen that also owns every exit.
@MainActor
final class SessionLiveActivity {

    private var activity: Activity<SessionActivityAttributes>?

    /// Starts the activity on first call, updates it after. One entry point,
    /// because every caller wants the same thing: make the Lock Screen agree
    /// with the engine.
    ///
    /// `try?` on the request: a fighter who has Live Activities switched off
    /// still gets their session, just without the card.
    func sync(title: String, state: SessionActivityAttributes.ContentState) {
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            activity = try? Activity.request(
                attributes: SessionActivityAttributes(title: title),
                content: ActivityContent(state: state, staleDate: nil)
            )
        }
    }

    /// `.immediate`, not the default linger: the default keeps a finished
    /// card on the Lock Screen for a while, and a clock stuck where the
    /// session left it is a clock that's wrong.
    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
