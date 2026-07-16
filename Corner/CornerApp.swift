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
        .modelContainer(for: TrainingRecord.self)
    }
}
