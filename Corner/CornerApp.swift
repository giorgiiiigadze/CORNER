//
//  CornerApp.swift
//  Corner
//
//  Created by giorgi giorgadze on 16/07/2026.
//

import SwiftData
import SwiftUI

@main
struct CornerApp: App {

    /// Owned here rather than in `ContentView` so a sign-out doesn't tear down
    /// and rebuild the whole tab tree — and so the token survives whatever the
    /// app is doing when it needs refreshing.
    @State private var auth = AuthController()

    /// Whether the splash has handed over. Separate from `auth.state` on
    /// purpose: the restore finishing is *a* condition for lifting the splash,
    /// not the only one — see `openingSequence` for the other.
    @State private var launching = true

    /// How long the mark stays up regardless of how fast the restore lands.
    ///
    /// On a warm start the stored token is already good and `restore()` returns
    /// in low milliseconds, which without a floor is a red square that strobes
    /// once and vanishes — worse than no splash at all. Long enough to read as
    /// deliberate, short enough that nobody waits on it: the restore is nearly
    /// always finished inside this, so in practice this is the launch time, not
    /// an addition to it.
    private let minimumOnScreen = Duration.milliseconds(900)

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Three states, not two. `restoring` is the moment before the
                // stored token has been checked, and it has to be its own frame:
                // falling back to the sign-in screen would flash a login at someone
                // already signed in, on every single launch.
                //
                // Built from the first frame, underneath the splash rather than
                // after it. That's the point of the overlay: the view tree, the
                // model container and the queries are all standing up while the
                // mark is on screen, so lifting it reveals a finished screen
                // instead of starting the work that builds one.
                Group {
                    switch auth.state {
                    case .restoring:
                        HomeSkeleton()

                    case .signedOut:
                        SignInView(auth: auth)

                    case .signedIn:
                        // Keyed by user id: changing accounts rebuilds the view, and
                        // with it the queries, so nothing from the last session
                        // survives on screen.
                        ContentView(userID: auth.userID ?? "")
                            .environment(auth)
                            .id(auth.userID ?? "")
                    }
                }

                if launching {
                    SplashView()
                        // Fades out over what's already there. No move, no
                        // scale: the mark is centred and Home's content is not,
                        // so anything that travels draws a line between two
                        // unrelated layouts.
                        .transition(.opacity)
                        // Above the real tree in z-order, and it has to swallow
                        // touches too — a tap that lands on a tab bar nobody
                        // can see yet is a screen the user didn't ask for.
                        .zIndex(1)
                }
            }
            .preferredColorScheme(.dark)
            .animation(.easeInOut(duration: 0.35), value: launching)
            .task { await openingSequence() }
        }
        // Every finished session is stored here and fed back into the next
        // prompt. It's what makes session 20 different from session 1.
        // Both models, or the `TodaySession` query faults the moment Home
        // appears — a `@Query` for a type the container doesn't know about is a
        // runtime crash, not a compile error. Adding an entity is a lightweight
        // migration, so existing histories survive it.
        .modelContainer(for: [TrainingRecord.self, TodaySession.self])
    }

    /// The launch: restore the session, hold the mark for the floor, drop it.
    ///
    /// Both concurrently rather than in sequence, because they're not dependent
    /// — the wait is a presentation floor, not a step — and running them in
    /// series would add the floor to every launch instead of hiding the restore
    /// inside it. A slow restore overruns the floor and the splash simply stays
    /// up for it, which is the behaviour we want and the reason it exists.
    private func openingSequence() async {
        async let restored: Void = auth.restore()
        // `Void?`, not `Void`: `try?` wraps the sleep's result, and the only
        // thing it can throw is cancellation — which we handle by carrying on
        // and lifting the splash, since a cancelled launch has no one waiting.
        async let floor: Void? = try? await Task.sleep(for: minimumOnScreen)

        _ = await (restored, floor)
        launching = false
    }
}
