import Testing
@testable import Corner

// MARK: - Doubles

private actor FakeVoice: Voice {
    private(set) var lines: [String] = []
    private(set) var cancelCount = 0
    private(set) var prewarmed: [String] = []
    private(set) var didStopPrewarming = false

    /// When held, `say` suspends until `finish` — a real line occupies seconds of
    /// wall clock, and without that there's no window in which to observe what
    /// happens *during* one. Ordering claims ("the line lands before the bell")
    /// are untestable against a voice that returns instantly.
    private var holdsLines = false
    private var inProgress: CheckedContinuation<Void, Never>?

    func hold() { holdsLines = true }

    /// Lets the line currently playing reach its end.
    func finish() { resumeInProgress() }

    func say(_ text: String) async {
        lines.append(text)
        guard holdsLines else { return }
        await withCheckedContinuation { inProgress = $0 }
    }

    func cancel() async {
        cancelCount += 1
        resumeInProgress()
    }

    private func resumeInProgress() {
        inProgress?.resume()
        inProgress = nil
    }

    /// Appends, mirroring the real voice: each batch adds to what's cached.
    /// Replacing here would hide a batch clobbering the one before it.
    func prewarm(_ lines: [String]) async { prewarmed.append(contentsOf: lines) }
    func stopPrewarming() async { didStopPrewarming = true }
}

private actor FakeRecognizer: VoiceRecognizer {
    private let stream: AsyncStream<VoiceCommand>
    private let continuation: AsyncStream<VoiceCommand>.Continuation
    private let transcriptStream: AsyncStream<String>
    private let transcriptContinuation: AsyncStream<String>.Continuation
    private let unmatchedStream: AsyncStream<String>
    private let unmatchedContinuation: AsyncStream<String>.Continuation

    /// Every line the engine announced it was saying, nils included — the nils
    /// are what prove the echo filter is lowered again afterwards.
    private(set) var spokenLines: [String?] = []
    private(set) var didStart = false
    private(set) var didStop = false

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: VoiceCommand.self)
        (transcriptStream, transcriptContinuation) = AsyncStream.makeStream(of: String.self)
        (unmatchedStream, unmatchedContinuation) = AsyncStream.makeStream(of: String.self)
    }

    var commands: AsyncStream<VoiceCommand> { stream }
    var transcripts: AsyncStream<String> { transcriptStream }
    var unmatched: AsyncStream<String> { unmatchedStream }

    func start() async throws { didStart = true }
    func stop() async {
        didStop = true
        continuation.finish()
        transcriptContinuation.finish()
        unmatchedContinuation.finish()
    }
    func setSpeaking(_ line: String?) async { spokenLines.append(line) }

    /// Simulates the user speaking.
    func hear(_ command: VoiceCommand) { continuation.yield(command) }

    /// Simulates raw text arriving from the transcriber.
    func transcribe(_ text: String) { transcriptContinuation.yield(text) }

    /// Simulates a finished sentence the phrase list made nothing of.
    func say(unrecognised text: String) { unmatchedContinuation.yield(text) }
}

/// Stands in for Claude. Returns whatever it's told to, and records what it was
/// asked — the second half is what proves the parser's hits never reach it.
private actor FakeIntentReader: IntentReader {
    private let reading: VoiceCommand?
    private(set) var asked: [String] = []

    init(reads reading: VoiceCommand?) {
        self.reading = reading
    }

    func interpret(_ heard: String) async -> VoiceCommand? {
        asked.append(heard)
        return reading
    }
}

/// The bell is the app's primary signal now, so "did it ring, and when" is worth
/// asserting. A test can't hear the real one.
@MainActor
private final class FakeBell: Ringer {
    private(set) var rings = 0
    func ring() { rings += 1 }
}

/// Parks every wait the session schedules, so the engine settles somewhere
/// stable and observable instead of racing a real clock. A three-minute round
/// costs no test time.
///
/// Everything the engine sleeps on now goes through here at one-second
/// granularity — the countdown is the only clock left. The echo drain
/// deliberately uses real time, being a fact about speaker hardware rather than
/// about pacing.
private struct GateTicker: Ticker {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3600))  // cancellable, unlike a parked continuation
    }
}

/// A clock that actually runs, for the few behaviours a parked one can't show.
///
/// Skipping is one: `skipToNextRound` sets `secondsRemaining` to zero, but the
/// countdown only reads it after a sleep returns — under `GateTicker` that's an
/// hour away, so the skip never lands. Five milliseconds a second puts a
/// three-minute round under a second while still leaving a command room to
/// arrive mid-round.
private struct FastTicker: Ticker {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .milliseconds(5))
    }
}

// MARK: - Fixture

private let testSession = Session(
    id: "test",
    title: "Test",
    intro: "Two rounds. Keep your hands up.",
    rounds: [
        Round(
            index: 1, focus: "Straight punches", opener: "Long and straight.",
            durationSeconds: 180, restSeconds: 60
        ),
        Round(
            index: 2, focus: "Hooks", opener: "Turn the hip.",
            durationSeconds: 180, restSeconds: 0
        ),
    ]
)

@MainActor
struct SessionEngineTests {

    private func makeEngine(
        intent: (any IntentReader)? = nil,
        ticker: any Ticker = GateTicker(),
        speaksCoaching: Bool = true
    ) -> (SessionEngine, FakeVoice, FakeRecognizer, FakeBell) {
        let voice = FakeVoice()
        let recognizer = FakeRecognizer()
        let bell = FakeBell()
        let engine = SessionEngine(
            session: testSession,
            voice: voice,
            recognizer: recognizer,
            speaksCoaching: speaksCoaching,
            intent: intent,
            ticker: ticker,
            bell: bell
        )
        return (engine, voice, recognizer, bell)
    }

    private func settle(_ times: Int = 20) async {
        for _ in 0..<times {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Waits for something to become true instead of guessing how long it takes.
    ///
    /// The echo filter is lowered by a detached task on a real 300ms timer, so a
    /// fixed number of yields is a race: it passes on an idle machine and fails
    /// when the suite runs in parallel.
    private func eventually(
        timeout: Duration = .seconds(2),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: - The premise

    @Test func staysIdleUntilTold() async throws {
        let (engine, voice, recognizer, bell) = makeEngine()
        try await engine.beginListening()
        await settle()

        #expect(engine.phase == .idle)
        #expect(await recognizer.didStart, "must be listening before it's told to start")
        #expect(await voice.lines.isEmpty, "nothing is said until the fighter says go")
        #expect(bell.rings == 0)
    }

    @Test func startBeginsTheFirstRound() async throws {
        let (engine, _, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        #expect(engine.phase == .active)
        #expect(engine.round?.index == 1)
        #expect(engine.round?.focus == "Straight punches")
    }

    // MARK: - Words the phrase list doesn't know

    /// The reason this exists. "Stop" isn't in the phrase list and never will be
    /// — the list can't be finished — but it plainly means pause, and a fighter
    /// who says it should get one.
    @Test func speechTheParserMissedIsReadForIntent() async throws {
        let reader = FakeIntentReader(reads: .pause)
        let (engine, _, recognizer, _) = makeEngine(intent: reader)
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.say(unrecognised: "stop")

        #expect(await eventually { engine.isPaused })
        #expect(await reader.asked == ["stop"])
    }

    /// None of that speech was an instruction, and the session has to be able to
    /// hear a room full of it without doing anything. This is the failure mode
    /// that would make the feature worse than not having it.
    @Test func speechThatMeansNothingChangesNothing() async throws {
        let reader = FakeIntentReader(reads: nil)
        let (engine, _, recognizer, _) = makeEngine(intent: reader)
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.say(unrecognised: "im dying here")
        await settle()

        #expect(!engine.isPaused)
        #expect(engine.phase == .active)
    }

    /// The engine's guards are the backstop for a misread. Claude saying "resume"
    /// when nothing is paused must be as inert as a person saying it.
    @Test func anImpossibleReadingIsIgnored() async throws {
        let reader = FakeIntentReader(reads: .resume)
        let (engine, _, recognizer, _) = makeEngine(intent: reader)
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.say(unrecognised: "carry on then")
        await settle()

        #expect(!engine.isPaused)
        #expect(engine.phase == .active)
    }

    /// No key, no network, no reader — and a session that behaves exactly as it
    /// did before any of this existed.
    @Test func withoutAReaderTheParserIsTheWholeStory() async throws {
        let (engine, _, recognizer, _) = makeEngine(intent: nil)
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.say(unrecognised: "stop")
        await settle()

        #expect(!engine.isPaused)
        #expect(engine.phase == .active)
    }

    // MARK: - A sentence, then the bell

    /// The order is the point. The bell means one thing — start punching — and a
    /// line said over a running clock turns three minutes into two-fifty.
    /// The silent mode is bell-and-clock, not a mute button: the round still
    /// starts on time and the commands still answer.
    @Test func silenceSkipsTheCoachingButStillRingsTheBell() async throws {
        let (engine, voice, recognizer, bell) = makeEngine(speaksCoaching: false)
        await voice.hold()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        // No intro, no round line — so nothing is holding the bell back.
        #expect(bell.rings == 1, "the round starts without waiting on a line")
        #expect(engine.phase == .active)

        let spoken = await voice.lines
        #expect(
            !spoken.contains("Round 1. Straight punches. Long and straight."),
            "the round opener is coaching and must stay quiet"
        )
    }

    /// Commands must still answer with the coaching off, or a fighter is talking
    /// to a phone that never replies and can't tell heard from missed.
    @Test func silenceStillAcknowledgesCommands() async throws {
        let (engine, voice, recognizer, _) = makeEngine(speaksCoaching: false)
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.hear(.pause)
        await settle()

        #expect(engine.isPaused)
        #expect(await voice.lines.contains("Pausing."))
    }

    @Test func theOpenerIsSaidBeforeTheBell() async throws {
        let (engine, voice, recognizer, bell) = makeEngine()
        await voice.hold()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        // Parked mid-intro: nothing has rung yet.
        #expect(bell.rings == 0)

        await voice.finish()   // intro
        await settle()
        #expect(await voice.lines.last == "Round 1. Straight punches. Long and straight.")
        #expect(bell.rings == 0, "the round-one line lands before the bell, not after")

        await voice.finish()   // round one's opener
        await settle()
        #expect(bell.rings == 1)
        #expect(engine.phase == .active)
    }

    /// Walking out of a round is one transition, so it gets one bell.
    ///
    /// The round-one bell, then "next round", then the round-two opener and its
    /// bell — two rings total. A third would be the old behaviour: the round
    /// ending and the round starting each ringing, a sentence apart, which
    /// sounds like a mistake rather than a transition.
    @Test func skippingARoundRingsOnce() async throws {
        let (engine, voice, recognizer, bell) = makeEngine(ticker: FastTicker())
        try await engine.beginListening()
        await recognizer.hear(.start)
        #expect(await eventually { engine.phase == .active }, "round one under way")
        #expect(bell.rings == 1, "round one's bell")

        await recognizer.hear(.nextRound)

        // Round two being active means its bell has already gone — the engine
        // rings and then counts down. So the count here is the whole story: two
        // if the handover rang once, three if round one's ending rang too.
        #expect(await eventually { engine.round?.index == 2 && engine.phase == .active })
        #expect(bell.rings == 2, "one bell for one transition, not two")
        #expect(await voice.lines.contains("Moving on."), "the skip answers itself in words")
    }

    /// Walking out of the *last* round still rings, because nothing follows it
    /// to do the job. There the bell is the session ending, not a handover.
    @Test func skippingTheLastRoundStillRings() async throws {
        let (engine, _, recognizer, bell) = makeEngine(ticker: FastTicker())
        try await engine.beginListening()
        await recognizer.hear(.start)
        #expect(await eventually { engine.phase == .active })

        await recognizer.hear(.nextRound)   // out of round one, into round two
        #expect(await eventually { engine.round?.index == 2 && engine.phase == .active })
        #expect(bell.rings == 2)

        await recognizer.hear(.nextRound)   // out of round two, which is the last

        #expect(await eventually { engine.phase == .debrief })
        #expect(bell.rings == 3, "the last round's bell is the session ending")
    }

    /// Silence is still the default once the bell goes: he says his sentence and
    /// gets out of the way. If this fails, something started talking over a
    /// running round again — which costs money per line and is the thing the
    /// whole rewrite removed.
    @Test func nothingIsSaidDuringTheRoundItself() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        #expect(await voice.lines == [
            "Two rounds. Keep your hands up.",
            "Round 1. Straight punches. Long and straight.",
        ])
    }

    /// A round with nothing honest left to say still announces itself. The
    /// alternative is a bell out of nowhere.
    @Test func aRoundWithNoOpenerStillAnnouncesItself() {
        let round = Round(index: 3, focus: "Body work", opener: nil, durationSeconds: 180, restSeconds: 0)
        #expect(SessionEngine.openerLine(for: round) == "Round 3. Body work.")
    }

    // MARK: - Answering back

    /// The one that matters, and the reason these lines are worded the way they
    /// are rather than the obvious way.
    ///
    /// "One more at the end" is the natural thing to say for `oneMoreRound` — and
    /// it contains "one more", so the app hearing its own voice would queue
    /// another round, then hear itself again. The echo filter stops that right up
    /// until one word comes back garbled and the match fails.
    ///
    /// Exhaustive over `allCases`, so a command added later can't quietly bring a
    /// self-triggering line with it.
    @Test func acknowledgementsAreNotCommands() {
        for command in VoiceCommand.allCases {
            guard let line = command.acknowledgement else { continue }
            #expect(
                CommandParser.parse(line) == nil,
                "\"\(line)\" parses as \(CommandParser.parse(line)?.rawValue ?? "") — the app would obey itself"
            )
        }
    }

    /// The nastiest version of the same bug. The app asks "You sure?" and then
    /// listens for "yes" — so if its own question parses to anything, one
    /// garbled word past the echo filter ends the session by itself, and the
    /// fighter never said a word.
    @Test func theQuestionIsNotAnAnswer() {
        #expect(CommandParser.parse(SessionEngine.confirmEndLine) == nil)
    }

    @Test func pauseSaysSo() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.pause)
        await settle()

        #expect(engine.isPaused)
        #expect(await voice.lines.last == "Pausing.")
    }

    /// A command that was ignored says nothing. Silence means "that did nothing",
    /// which is true — "resume" when you aren't paused shouldn't sound like it
    /// worked.
    @Test func anIgnoredCommandIsNotAcknowledged() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.resume)   // never paused
        await settle()

        #expect(await voice.lines.isEmpty)
    }

    /// Same trap as the round openers: an answer fetched when it's due is an
    /// answer that arrives too late to be one.
    @Test func acknowledgementsAreFetchedUpFront() async throws {
        let warmed = Set(SessionEngine.openingLines(of: testSession))
        for command in VoiceCommand.allCases {
            guard let line = command.acknowledgement else { continue }
            #expect(warmed.contains(line), "\"\(line)\" would stall on a network call")
        }
    }

    // MARK: - What gets paid for

    /// The money test. Fetching the whole session the moment the live screen
    /// opens means paying for round six before "let's go" — and paying again
    /// every time someone opens a session and backs out.
    @Test func theOpeningDoesNotPayForLaterRounds() async throws {
        let lines = SessionEngine.openingLines(of: testSession)

        #expect(lines.contains("Two rounds. Keep your hands up."))
        #expect(lines.contains("Round 1. Straight punches. Long and straight."))
        #expect(!lines.contains { $0.contains("Hooks") }, "round two waits until round one is being worked")
    }

    /// Time-check answers are deliberately absent: ~180 of them, only heard when
    /// asked for, and identical in every session forever. Fetching them all up
    /// front would pay for 178 lines nobody hears.
    @Test func theOpeningDoesNotPayForTimeChecks() async throws {
        let lines = SessionEngine.openingLines(of: testSession)
        #expect(!lines.contains { $0.contains("left in the round") })
    }

    /// Round two arrives while round one is being worked — three minutes of
    /// slack, so it's ready without ever being paid for early.
    @Test func theNextRoundIsFetchedDuringTheCurrentOne() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        #expect(await voice.prewarmed.contains("Round 2. Hooks. Turn the hip."))
    }

    /// The cache is keyed on a hash of the text, so the line the prefetcher
    /// fetched and the line the engine says have to match to the character.
    /// Diverge and nothing warns you: it's a miss, a stall at the bell, and the
    /// same words billed twice. This is why `openerLine` exists.
    @Test func theLineFetchedIsExactlyTheLineSaid() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        let warmed = Set(await voice.prewarmed)
        for line in await voice.lines {
            #expect(warmed.contains(line), "\"\(line)\" was spoken but never fetched — cache miss at the bell")
        }
    }

    // MARK: - Nothing cuts him off

    /// Barge-in is gone, and this is the shape of its absence.
    ///
    /// It existed to interrupt a three-minute stream of combo callouts you needed
    /// to talk over. There's no stream: he says one sentence before each bell and
    /// stops. So there's nothing an interruption would save, and allowing one cost
    /// real money — the fighter's own "let's go" was still being finalized as the
    /// intro started, and cut it off mid-sentence every single session.
    @Test func speechDoesNotCutHimOff() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        await voice.hold()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        // The recognizer finishing with the utterance it already acted on — the
        // exact thing that was chopping the intro.
        await recognizer.transcribe("lets go")
        // And someone talking over him, which is now simply his problem to ignore.
        await recognizer.transcribe("hey give me something")
        await settle()

        #expect(await voice.cancelCount == 0, "his lines run to the end, always")
        #expect(engine.phase == .announcing, "still mid-intro")
    }

    /// `pause` is about the clock, and his lines land before the clock starts —
    /// so it has nothing to interrupt either. It still pauses; he just finishes
    /// his sentence first.
    @Test func pauseDoesNotCutHimOff() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        await voice.hold()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.pause)
        await settle()

        #expect(engine.isPaused)
        #expect(await voice.cancelCount == 0, "the intro finishes; the pause lands at the countdown")
    }

    /// The protection that must survive dropping the mute: the recognizer can
    /// only discard an echo of a line it was given.
    @Test func tellsTheRecognizerWhatItIsSaying() async throws {
        let (engine, _, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        #expect(await recognizer.spokenLines.contains("Two rounds. Keep your hands up."))

        // `.some(nil)` rather than `nil`: `spokenLines` is `[String?]`, so `last`
        // is doubly optional and comparing it to `nil` asks whether the array is
        // empty — which is true of a session that never spoke at all.
        let lowered = await eventually { await recognizer.spokenLines.last == .some(nil) }
        #expect(lowered, "must always lower the filter, or real speech gets eaten")
    }

    // MARK: - Commands

    @Test func resumeUnfreezes() async throws {
        let (engine, _, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.pause)
        await settle()
        await recognizer.hear(.resume)
        await settle()

        #expect(!engine.isPaused)
    }

    @Test func pauseIsIgnoredWhenIdle() async throws {
        let (engine, _, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.pause)
        await settle()

        #expect(!engine.isPaused, "nothing is running, so there's nothing to pause")
    }

    @Test func timeCheckSpeaksTheRemainingTime() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.timeCheck)
        await settle()

        let said = await voice.lines
        #expect(said.contains { $0.contains("left in the round") })
    }

    @Test func surfacesWhatItHeardEvenWhenItIsNotACommand() async throws {
        let (engine, _, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.transcribe("hook to the body")
        await settle()

        #expect(engine.lastHeard == "hook to the body")
    }

    @Test func endSessionStopsEverything() async throws {
        let (engine, _, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.endSession)
        await settle()
        await recognizer.hear(.confirm)
        await settle()

        #expect(engine.isFinished)
        #expect(!engine.isListening)
        #expect(await recognizer.didStop)
    }

    // MARK: - The one question

    /// A misheard "finish" used to end the workout outright. Now it asks, and a
    /// session survives being misheard.
    @Test func endingAsksFirstAndDoesNotEnd() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.endSession)
        await settle()

        #expect(engine.awaitingEndConfirmation)
        #expect(!engine.isFinished, "the session must survive the question")
        #expect(engine.phase == .active, "and the round must keep running under it")
        #expect(await voice.lines.contains(SessionEngine.confirmEndLine))
    }

    @Test func sayingNoKeepsTheSessionAlive() async throws {
        let (engine, _, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.endSession)
        await settle()
        await recognizer.hear(.cancel)
        await settle()

        #expect(!engine.awaitingEndConfirmation)
        #expect(!engine.isFinished)
        #expect(engine.phase == .active)
    }

    /// Someone who means it repeats themselves rather than answering.
    @Test func sayingItTwiceIsAlsoConfirmation() async throws {
        let (engine, _, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.endSession)
        await settle()
        await recognizer.hear(.endSession)
        await settle()

        #expect(engine.isFinished)
    }

    /// "Yes" is a word people say to each other in gyms. It must be inert unless
    /// it's answering something.
    @Test func yesMeansNothingWhenNothingWasAsked() async throws {
        let (engine, _, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.confirm)
        await settle()

        #expect(!engine.isFinished)
        #expect(engine.phase == .active)
    }

    /// The stale-answer bug: ask, move on, and a "yeah" two minutes later must
    /// not land on a question nobody remembers.
    @Test func movingOnForgetsTheQuestion() async throws {
        let (engine, _, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.endSession)
        await settle()

        await recognizer.hear(.timeCheck)
        await settle()
        #expect(!engine.awaitingEndConfirmation)

        await recognizer.hear(.confirm)
        await settle()
        #expect(!engine.isFinished, "that yes was answering nothing")
    }

    /// Nothing to lose before the first bell, so the question would be ceremony —
    /// and a confirmation you always say yes to is one you stop reading.
    @Test func endingBeforeItStartsDoesNotAsk() async throws {
        let (engine, _, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.endSession)
        await settle()

        #expect(!engine.awaitingEndConfirmation)
        #expect(engine.isFinished)
    }

    /// An abandoned workout must stop paying for lines nobody will hear.
    @Test func endingStopsPrewarming() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.endSession)
        await settle()

        #expect(await voice.didStopPrewarming)
    }
}
