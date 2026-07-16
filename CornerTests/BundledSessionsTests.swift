import Testing
@testable import Corner

/// The offline path, and the only one with no safety net under it.
///
/// `BundledSessions` is what runs when Claude can't be reached — a garage with no
/// signal, which is the pitch. Nothing else in the suite touches this file, so a
/// field added to `Round` breaks decoding and every test still passes. That's how
/// it nearly shipped: `cues` was added and these nine rounds didn't have it.
struct BundledSessionsTests {

    @Test func theyDecode() throws {
        let sessions = try BundledSessions.load()
        #expect(!sessions.isEmpty)
    }

    /// A round with no cues is a round the cornerman works in silence between
    /// combos — which is the machine reading numbers this was meant to replace.
    @Test func everyRoundIsCoached() throws {
        for session in try BundledSessions.load() {
            for round in session.rounds {
                #expect(!round.cues.isEmpty, "\(session.title) / \(round.focus) has no cues")
                #expect(round.cues.count <= 3, "\(round.focus) cycles too many to teach any")
            }
        }
    }

    /// The whole mechanism is repetition, so a cue is heard eight times a round.
    /// Anything sentence-length becomes unbearable by the third pass.
    @Test func cuesAreShort() throws {
        for session in try BundledSessions.load() {
            for round in session.rounds {
                for cue in round.cues {
                    let words = cue.split(separator: " ").count
                    #expect(words <= 5, "\"\(cue)\" is too long to repeat")
                }
            }
        }
    }

    /// Combos are served at random from the round's list, so a duplicate is a
    /// combo the fighter hears twice as often as the rest.
    @Test func combosAreDistinct() throws {
        for session in try BundledSessions.load() {
            for round in session.rounds {
                let displays = round.combos.map(\.display)
                #expect(Set(displays).count == displays.count, "\(round.focus) repeats a combo")
            }
        }
    }
}
