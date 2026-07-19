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
    var body: some Scene {
        WindowGroup {
            ContentView()
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
