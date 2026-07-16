import Testing
@testable import Corner

// MARK: - Doubles

private actor FakeVoice: Voice {
    private(set) var lines: [String] = []
    private(set) var cancelCount = 0
    private(set) var prewarmed: [String] = []
    private(set) var didStopPrewarming = false

    /// When held, `say` suspends until `cancel` — which is what a real line does:
    /// it occupies seconds of wall clock and returns early when cut off. Without
    /// this, every line is instantaneous and there is no window in which to be
    /// interrupted, so barge-in can't be tested at all.
    private var holdsLines = false
    private var inProgress: CheckedContinuation<Void, Never>?

    func hold() { holdsLines = true }

    func say(_ text: String) async {
        lines.append(text)
        guard holdsLines else { return }
        await withCheckedContinuation { inProgress = $0 }
    }

    func cancel() async {
        cancelCount += 1
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

    /// Every line the engine announced it was saying, nils included — the nils
    /// are what prove the echo filter is lowered again afterwards.
    private(set) var spokenLines: [String?] = []
    private(set) var didStart = false
    private(set) var didStop = false

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: VoiceCommand.self)
        (transcriptStream, transcriptContinuation) = AsyncStream.makeStream(of: String.self)
    }

    var commands: AsyncStream<VoiceCommand> { stream }
    var transcripts: AsyncStream<String> { transcriptStream }

    func start() async throws { didStart = true }
    func stop() async {
        didStop = true
        continuation.finish()
        transcriptContinuation.finish()
    }
    func setSpeaking(_ line: String?) async { spokenLines.append(line) }

    /// Simulates the user speaking.
    func hear(_ command: VoiceCommand) { continuation.yield(command) }

    /// Simulates raw text arriving from the transcriber.
    func transcribe(_ text: String) { transcriptContinuation.yield(text) }
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

// MARK: - Fixture

private let testSession = Session(
    id: "test",
    title: "Test",
    intro: "Two rounds. Keep your hands up.",
    rounds: [
        Round(index: 1, focus: "Straight punches", durationSeconds: 180, restSeconds: 60),
        Round(index: 2, focus: "Hooks", durationSeconds: 180, restSeconds: 0),
    ]
)

@MainActor
struct SessionEngineTests {

    private func makeEngine() -> (SessionEngine, FakeVoice, FakeRecognizer, FakeBell) {
        let voice = FakeVoice()
        let recognizer = FakeRecognizer()
        let bell = FakeBell()
        let engine = SessionEngine(
            session: testSession,
            voice: voice,
            recognizer: recognizer,
            ticker: GateTicker(),
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

    // MARK: - Silence

    /// The whole point of the rewrite. The cornerman says what today is for and
    /// then shuts up: a round is a bell, three minutes, and a bell.
    ///
    /// If this fails, something started talking during a round again — which is
    /// the exact thing that was removed, and it costs money per line.
    @Test func aRoundIsBellSilenceBell() async throws {
        let (engine, voice, recognizer, bell) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        #expect(bell.rings == 1, "the round opens on the bell")

        let spoken = await voice.lines
        #expect(spoken == ["Two rounds. Keep your hands up."], "the intro, and then nothing")
    }

    @Test func theIntroIsSaidBeforeTheFirstBell() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        #expect(await voice.lines.first == "Two rounds. Keep your hands up.")
        #expect(engine.phase == .active, "and the round starts without waiting to be asked")
    }

    // MARK: - What gets paid for

    /// The money test, re-anchored.
    ///
    /// It used to assert that round two's *combos* weren't fetched up front. With
    /// no combos that assertion is vacuously true and tests nothing, so it now
    /// pins the real guarantee: the entire session is three lines, and only the
    /// intro is unique to it. Anything else appearing here is a per-session bill
    /// nobody agreed to.
    @Test func theWholeSessionIsThreeLines() async throws {
        let lines = SessionEngine.spokenLines(of: testSession)

        #expect(lines == [
            "Two rounds. Keep your hands up.",
            "That's the session. Well done.",
            "Session over. Good work.",
        ])
    }

    /// Time-check answers are deliberately absent: ~180 of them, only heard when
    /// asked for, and identical in every session forever. Fetching them all up
    /// front would pay for 178 lines nobody hears.
    @Test func theOpeningDoesNotPayForTimeChecks() async throws {
        let lines = SessionEngine.spokenLines(of: testSession)
        #expect(!lines.contains { $0.contains("left in the round") })
    }

    @Test func nothingPerRoundIsFetched() async throws {
        let (engine, voice, _, _) = makeEngine()
        try await engine.beginListening()
        await settle()

        let warmed = await voice.prewarmed
        #expect(warmed.contains("Two rounds. Keep your hands up."))
        #expect(!warmed.contains { $0.contains("Hooks") }, "a round's focus is read, not spoken")
        #expect(warmed.count == 3)
    }

    // MARK: - Barge-in

    /// Still earns its place with the coach nearly silent: the intro is the one
    /// long line left, and it's exactly the one a fighter talks over.
    @Test func stopsTalkingWhenTheFighterSpeaks() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        await voice.hold()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        // The engine is now suspended part-way through the intro.
        #expect(await voice.cancelCount == 0, "precondition: nothing interrupted yet")

        // Not a command, and not even a finished sentence — the first syllables
        // are the point. Waiting for a parse would mean talking over the fighter
        // for the length of whatever they're saying.
        await recognizer.transcribe("hey give me")
        await settle()

        #expect(await voice.cancelCount == 1, "speech during a line must cut the cornerman off")
    }

    /// The mirror, and the reason it can't just cancel on every transcript:
    /// nothing is playing, so there's nothing to interrupt.
    @Test func doesNotBargeInWhenTheCornermanIsQuiet() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        try await engine.beginListening()

        await recognizer.transcribe("just talking to myself")
        await settle()

        #expect(await voice.cancelCount == 0, "nothing is playing — nothing to cut off")
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

    @Test func pauseFreezesAndCutsTheCurrentLine() async throws {
        let (engine, voice, recognizer, _) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.pause)
        await settle()

        #expect(engine.isPaused)
        #expect(await voice.cancelCount >= 1, "a cornerman who finishes his sentence isn't paused")
    }

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

        #expect(engine.isFinished)
        #expect(!engine.isListening)
        #expect(await recognizer.didStop)
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
