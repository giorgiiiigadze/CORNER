import Testing
@testable import Corner

/// The offline path, and the only one with no safety net under it.
///
/// `BundledSessions` is what runs when Claude can't be reached — a garage with no
/// signal, which is the pitch. Nothing else in the suite touches this file, so a
/// change to `Round` breaks decoding and every other test still passes. That's
/// how it nearly shipped once: `cues` was added and these nine rounds didn't
/// have it.
struct BundledSessionsTests {

    @Test func theyDecode() throws {
        let sessions = try BundledSessions.load()
        #expect(!sessions.isEmpty)
    }

    /// The intro is the only thing the app says all session, so a bundled session
    /// without one is twenty silent minutes with no idea what they're for.
    @Test func everySessionSaysWhatItIsFor() throws {
        for session in try BundledSessions.load() {
            let intro = session.intro ?? ""
            #expect(!intro.isEmpty, "\(session.title) never says what it's for")
        }
    }

    /// Two sentences, same as the prompt demands of Claude. These are the only
    /// intros written by hand, so nothing else stops them drifting back into the
    /// five-sentence speech they used to be — and the fighter gets one idea to
    /// hold for twenty minutes, so it had better be one.
    @Test func introsAreTwoSentences() throws {
        for session in try BundledSessions.load() {
            let sentences = (session.intro ?? "").filter { ".!?".contains($0) }.count
            #expect(sentences <= 2, "\(session.title)'s intro is a speech, not a plan")
        }
    }

    /// The focus is read off a screen from across a room. A sentence doesn't fit
    /// and doesn't get read.
    @Test func everyRoundHasAShortFocus() throws {
        for session in try BundledSessions.load() {
            for round in session.rounds {
                #expect(!round.focus.isEmpty, "\(session.title) round \(round.index) has no focus")
                let words = round.focus.split(separator: " ").count
                #expect(words <= 4, "\"\(round.focus)\" is too long to read at a glance")
            }
        }
    }

    /// The last round has nothing to rest for, and resting after it would leave
    /// the fighter standing there waiting for a bell that means nothing.
    @Test func theLastRoundHasNoRest() throws {
        for session in try BundledSessions.load() {
            #expect(session.rounds.last?.restSeconds == 0, "\(session.title) rests after the last round")
        }
    }
}
