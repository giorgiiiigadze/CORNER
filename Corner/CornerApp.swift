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

    var body: some Scene {
        WindowGroup {
            // Three states, not two. `restoring` is the moment before the
            // stored token has been checked, and it has to be its own frame:
            // falling back to the sign-in screen would flash a login at someone
            // already signed in, on every single launch.
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
            .preferredColorScheme(.dark)
            .task { await auth.restore() }
        }
        // Every finished session is stored here and fed back into the next
        // prompt. It's what makes session 20 different from session 1.
        // Both models, or the `TodaySession` query faults the moment Home
        // appears — a `@Query` for a type the container doesn't know about is a
        // runtime crash, not a compile error. Adding an entity is a lightweight
        // migration, so existing histories survive it.
        .modelContainer(for: [TrainingRecord.self, TodaySession.self])
    }
}
