import Testing
@testable import Corner

/// The parser is the only part of the ears that can be judged without a gym,
/// so it gets judged hard.
struct CommandParserTests {

    // MARK: - The overlaps that motivate the design

    /// Every one of these pairs is a phrase that contains a shorter phrase mapping
    /// to a *different* command. Without longest-match-wins, each would misfire.
    @Test(arguments: [
        ("next round", VoiceCommand.nextRound),
        ("next", .nextRound),
        ("one more round", .oneMoreRound),
        ("one more", .oneMoreRound),
        ("another round", .oneMoreRound),
    ])
    func resolvesOverlappingPhrases(input: String, expected: VoiceCommand) {
        #expect(CommandParser.parse(input) == expected)
    }

    // MARK: - Each of the seven

    @Test(arguments: [
        ("let's go", VoiceCommand.start), ("lets go", .start), ("start", .start), ("begin", .start),
        ("pause", .pause), ("hold on", .pause), ("wait", .pause),
        ("resume", .resume), ("keep going", .resume), ("continue", .resume),
        ("next round", .nextRound), ("next", .nextRound),
        ("one more round", .oneMoreRound), ("another round", .oneMoreRound),
        ("how much time", .timeCheck), ("time check", .timeCheck), ("how long", .timeCheck),
        ("end session", .endSession), ("i'm done", .endSession), ("that's it", .endSession),
    ])
    func recognizesCommand(input: String, expected: VoiceCommand) {
        #expect(CommandParser.parse(input) == expected)
    }

    /// The five that went when the callouts did. A fighter who says "faster" out
    /// of habit gets silence, which is honest — there's no pace to change. Left
    /// mapped to anything, they'd be understood and do nothing, and the fighter
    /// couldn't tell which.
    @Test(arguments: ["skip", "skip it", "again", "repeat", "stop", "slower", "slow down", "faster", "speed up", "harder"])
    func theCalloutCommandsAreGone(input: String) {
        #expect(CommandParser.parse(input) == nil)
    }

    @Test func everyCommandHasAtLeastOnePhrase() {
        let covered = Set(VoiceCommand.allCases.filter { command in
            CommandParser.contextualStrings.contains { CommandParser.parse($0) == command }
        })
        #expect(covered == Set(VoiceCommand.allCases))
    }

    // MARK: - Real transcripts

    /// A transcript arrives with filler around it; nobody says a bare keyword.
    @Test(arguments: [
        ("okay pause", VoiceCommand.pause),
        ("uh, can we go to the next round", .nextRound),
        ("alright let's go", .start),
        ("hey, how much time is left", .timeCheck),
    ])
    func findsCommandsInsideFiller(input: String, expected: VoiceCommand) {
        #expect(CommandParser.parse(input) == expected)
    }

    /// Volatile transcripts accumulate, so the newest command is the real one.
    @Test func mostRecentCommandWins() {
        #expect(CommandParser.parse("lets go pause") == .pause)
        #expect(CommandParser.parse("pause resume") == .resume)
    }

    @Test(arguments: ["PAUSE!", "Pause.", "  pause  "])
    func ignoresCaseAndPunctuation(input: String) {
        #expect(CommandParser.parse(input) == .pause)
    }

    // MARK: - Silence

    /// A false positive is worse than a miss. The fighter works in silence now,
    /// so anything the mic picks up is them breathing, their music, or someone
    /// else in the room — and none of it should touch the session.
    @Test(arguments: ["", "   ", "one two three", "hello there", "jab cross hook"])
    func staysSilentWhenNoCommandIsPresent(input: String) {
        #expect(CommandParser.parse(input) == nil)
    }

    // MARK: - Echo

    /// The app hearing itself. Corner talk that says "next round" must not skip
    /// the round the fighter is standing in.
    @Test(arguments: [
        "next round",             // the danger case: a real command in the script
        "Next round",             // recognizers don't promise casing
        "round we start",         // caught mid-line, as the speaker bleeds in
        "next rou",               // volatile results arrive mid-word
        "NEXT ROUND, SNAP IT",
    ])
    func recognizesItsOwnVoice(heard: String) {
        #expect(CommandParser.isEcho(heard, of: "Next round we start on the jab. Snap it back."))
    }

    /// The other half, and the one that matters more: a fighter talking over the
    /// cornerman must still get through. If this fails, the app is deaf whenever
    /// it's speaking — which is the whole bug this replaced.
    @Test(arguments: [
        "pause",
        "give me something for the body",
        "my shoulder hurts",
        "faster",
    ])
    func doesNotMistakeTheFighterForItself(heard: String) {
        #expect(!CommandParser.isEcho(heard, of: "Next round we start on the jab. Snap it back."))
    }

    /// Empty is nobody. Yielding it would cut the cornerman off at every pause
    /// between words.
    @Test(arguments: ["", "   ", "!"])
    func treatsSilenceAsEcho(heard: String) {
        #expect(CommandParser.isEcho(heard, of: "Round two. Body work."))
    }
}
