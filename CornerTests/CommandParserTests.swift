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
        ("one more time", .again),
        ("another round", .oneMoreRound),
        ("skip it", .skip),
    ])
    func resolvesOverlappingPhrases(input: String, expected: VoiceCommand) {
        #expect(CommandParser.parse(input) == expected)
    }

    /// "One more round" is the trap: it contains "one more", and "one more time"
    /// means something else entirely. Getting this wrong turns a request for an
    /// extra round into a repeated combo.
    @Test func oneMoreRoundIsNotOneMoreTime() {
        #expect(CommandParser.parse("one more round") == .oneMoreRound)
        #expect(CommandParser.parse("one more time") == .again)
    }

    // MARK: - Each of the twelve

    @Test(arguments: [
        ("let's go", VoiceCommand.start), ("lets go", .start), ("start", .start), ("begin", .start),
        ("pause", .pause), ("hold on", .pause), ("wait", .pause),
        ("resume", .resume), ("keep going", .resume), ("continue", .resume),
        ("stop", .stop),
        ("slower", .slower), ("slow down", .slower), ("too fast", .slower),
        ("faster", .faster), ("speed up", .faster), ("harder", .faster), ("too slow", .faster),
        ("again", .again), ("repeat", .again),
        ("skip", .skip),
        ("how much time", .timeCheck), ("time check", .timeCheck), ("how long", .timeCheck),
        ("end session", .endSession), ("i'm done", .endSession), ("that's it", .endSession),
    ])
    func recognizesCommand(input: String, expected: VoiceCommand) {
        #expect(CommandParser.parse(input) == expected)
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
        ("uh, can you go slower", .slower),
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
        #expect(CommandParser.parse("slower faster") == .faster)
    }

    @Test(arguments: ["PAUSE!", "Pause.", "  pause  "])
    func ignoresCaseAndPunctuation(input: String) {
        #expect(CommandParser.parse(input) == .pause)
    }

    // MARK: - Silence

    /// A false positive is worse than a miss: combos are counted aloud, and
    /// "one two three" must never be mistaken for a command.
    @Test(arguments: ["", "   ", "one two three", "hello there", "jab cross hook"])
    func staysSilentWhenNoCommandIsPresent(input: String) {
        #expect(CommandParser.parse(input) == nil)
    }
}
