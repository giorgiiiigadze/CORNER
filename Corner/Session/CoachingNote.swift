import Foundation

/// One thing the fighter told the cornerman, in their own words.
///
/// "My ribs are shot, no body work." "I'm a southpaw." Standing instructions —
/// they hold for every session until deleted, which is what separates them from
/// the focus you pick in the setup sheet.
nonisolated struct CoachingNote: Codable, Sendable, Equatable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var added: Date = .now
}

/// Where the standing instructions live.
///
/// `UserDefaults` rather than SwiftData: there are a handful of these, they're
/// tiny, and unlike `TrainingRecord` they aren't history — nothing queries or
/// sorts them, the profile just reads the lot on the way into a prompt.
nonisolated enum CoachingNotes {
    static let key = "coachingNotes"

    /// Lossy on purpose. A corrupt blob costs the user their instructions, but
    /// trapping would cost them the app — and the page can write over it.
    static func decode(_ data: Data) -> [CoachingNote] {
        (try? JSONDecoder().decode([CoachingNote].self, from: data)) ?? []
    }

    static func encode(_ notes: [CoachingNote]) -> Data {
        (try? JSONEncoder().encode(notes)) ?? Data()
    }
}
