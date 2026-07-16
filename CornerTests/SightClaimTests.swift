import Testing
@testable import Corner

/// The app has no camera, and the moment it pretends otherwise the whole thing
/// falls over: tell someone they're dropping a hand they never dropped and every
/// true thing said afterwards reads as a guess too.
///
/// The prompt forbids this at length. A live probe showed the model doing it
/// anyway in one round out of three — it knows what a corner sounds like, and a
/// real corner watches. So the prompt asks and this enforces.
struct SightClaimTests {

    /// Straight from the probe, all written before the fighter threw a punch.
    @Test(arguments: [
        "You're chaining them now.",
        "You're slipping clean.",
        "You're stacking the defense now.",
        "You're not thinking about the slip anymore.",
        "You are dropping your right hand.",
    ])
    func reportsAreCut(sentence: String) {
        #expect(SessionGenerator.withoutSightClaims(sentence).isEmpty)
    }

    /// The half that matters. Cutting is only safe if it leaves the forward-facing
    /// line alone — that's the part worth hearing.
    @Test func theForwardHalfSurvives() {
        let talk = "You're chaining them now. Next round add the pivot. Same work, just turn it."
        let cleaned = SessionGenerator.withoutSightClaims(talk)

        #expect(!cleaned.contains("chaining"), "the claim must go")
        #expect(cleaned.contains("Next round add the pivot."), "the instruction must stay")
        #expect(cleaned.contains("Same work, just turn it."))
    }

    /// False positives are the real risk: this only ever deletes, so anything it
    /// wrongly matches is coaching the fighter never hears.
    @Test(arguments: [
        "Next round is the same jab, just faster.",
        "You're going to feel this one in the legs.",       // a promise, not a report
        "You've been on the jab all week.",                 // history we actually have
        "Don't let it get lazy when you're tired.",         // not sentence-initial
        "Keep the hands up.",
        "That's the session. Well done.",
    ])
    func honestLinesAreLeftAlone(sentence: String) {
        #expect(SessionGenerator.withoutSightClaims(sentence) == sentence)
    }

    /// A talk that was nothing but claims leaves nothing to say. Silence during
    /// the rest is fine; an empty string handed to a speech synthesizer is not.
    @Test func nothingLeftIsNothingSaid() {
        #expect(SessionGenerator.withoutSightClaims("You're slipping clean.").isEmpty)
    }
}
