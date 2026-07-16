import Testing
@testable import Corner

// MARK: - Doubles

private actor FakeVoice: Voice {
    private(set) var lines: [String] = []
    private(set) var cancelCount = 0

    func say(_ text: String) async { lines.append(text) }
    func cancel() async { cancelCount += 1 }
}

private actor FakeRecognizer: VoiceRecognizer {
    private let stream: AsyncStream<VoiceCommand>
    private let continuation: AsyncStream<VoiceCommand>.Continuation
    private let transcriptStream: AsyncStream<String>
    private let transcriptContinuation: AsyncStream<String>.Continuation

    private(set) var muteChanges: [Bool] = []
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
    func setMuted(_ muted: Bool) async { muteChanges.append(muted) }

    /// Simulates the user speaking.
    func hear(_ command: VoiceCommand) { continuation.yield(command) }

    /// Simulates raw text arriving from the transcriber.
    func transcribe(_ text: String) { transcriptContinuation.yield(text) }
}

/// Lets the short waits through and parks the long ones.
///
/// The 300ms mute grace passes instantly so speech completes, while the round
/// countdown and the gap between callouts park indefinitely. The engine therefore
/// settles in a stable, observable state instead of racing a real clock — and a
/// three-minute round costs no test time.
private struct GateTicker: Ticker {
    func sleep(for duration: Duration) async throws {
        guard duration >= .seconds(1) else { return }
        try await Task.sleep(for: .seconds(3600))  // cancellable, unlike a parked continuation
    }
}

// MARK: - Fixture

private let testSession = Session(
    id: "test",
    title: "Test",
    rounds: [
        Round(
            index: 1, focus: "Straight punches", durationSeconds: 180, restSeconds: 60,
            combos: [Combo(display: "1 - 2", spoken: "one, two")],
            cornerTalk: "Hands up."
        ),
        Round(
            index: 2, focus: "Hooks", durationSeconds: 180, restSeconds: 0,
            combos: [Combo(display: "3", spoken: "hook")],
            cornerTalk: nil
        ),
    ]
)

@MainActor
struct SessionEngineTests {

    private func makeEngine() -> (SessionEngine, FakeVoice, FakeRecognizer) {
        let voice = FakeVoice()
        let recognizer = FakeRecognizer()
        let engine = SessionEngine(
            session: testSession,
            voice: voice,
            recognizer: recognizer,
            ticker: GateTicker()
        )
        return (engine, voice, recognizer)
    }

    /// Lets the engine's tasks run until they park.
    private func settle() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - The premise

    /// The app must never start on its own. The user says when.
    @Test func staysIdleUntilTold() async throws {
        let (engine, _, recognizer) = makeEngine()
        try await engine.beginListening()
        await settle()

        #expect(engine.phase == .idle)
        #expect(engine.isListening)
        #expect(await recognizer.didStart)
    }

    @Test func startBeginsTheFirstRound() async throws {
        let (engine, voice, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        #expect(engine.phase == .active)
        #expect(engine.round?.index == 1)
        #expect(engine.currentCombo?.display == "1 - 2")

        let lines = await voice.lines
        #expect(lines.first == "Round 1. Straight punches.")
        #expect(lines.contains("one, two"))
    }

    /// The self-hearing guard. Corner talks contain phrases like "next round",
    /// so the ears must close every time the cornerman speaks, and reopen after.
    @Test func closesItsEarsWhileSpeaking() async throws {
        let (engine, _, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        let changes = await recognizer.muteChanges
        #expect(changes.contains(true))
        #expect(changes.last == false, "must always reopen its ears, or voice control dies silently")
        // Strictly alternating: every mute is matched by an unmute.
        #expect(!zip(changes, changes.dropFirst()).contains { $0 == $1 })
    }

    // MARK: - Commands

    @Test func pauseFreezesAndCutsTheCurrentLine() async throws {
        let (engine, voice, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        let cancelsBefore = await voice.cancelCount
        await recognizer.hear(.pause)
        await settle()

        #expect(engine.isPaused)
        #expect(await voice.cancelCount > cancelsBefore, "pause must cut speech mid-word")
    }

    @Test func resumeUnfreezes() async throws {
        let (engine, _, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        await recognizer.hear(.pause)
        await settle()
        #expect(engine.isPaused)

        await recognizer.hear(.resume)
        await settle()
        #expect(!engine.isPaused)
    }

    /// Pause before the session has started is meaningless and must not wedge it.
    @Test func pauseIsIgnoredWhenIdle() async throws {
        let (engine, _, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.pause)
        await settle()

        #expect(!engine.isPaused)
        #expect(engine.phase == .idle)
    }

    @Test func slowerAndFasterMoveTheTempo() async throws {
        let (engine, _, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        let original = engine.tempo.gap
        await recognizer.hear(.slower)
        await settle()
        #expect(engine.tempo.gap > original)

        await recognizer.hear(.faster)
        await recognizer.hear(.faster)
        await settle()
        #expect(engine.tempo.gap < original)
    }

    @Test func againRepeatsUntilStop() async throws {
        let (engine, _, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.hear(.again)
        await settle()
        #expect(engine.isRepeating)

        await recognizer.hear(.stop)
        await settle()
        #expect(!engine.isRepeating, "\"stop\" ends the repeat — it must never end the session")
        #expect(engine.phase == .active)
    }

    @Test func timeCheckSpeaksTheRemainingTime() async throws {
        let (engine, voice, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.hear(.timeCheck)
        await settle()

        let lines = await voice.lines
        #expect(lines.contains { $0.contains("left in the round") })
    }

    /// Text that parses to nothing must still surface, or the gym test can't tell
    /// a mishearing apart from silence.
    @Test func surfacesWhatItHeardEvenWhenItIsNotACommand() async throws {
        let (engine, _, recognizer) = makeEngine()
        try await engine.beginListening()

        await recognizer.transcribe("slow her down")
        await settle()

        #expect(engine.lastHeard == "slow her down")
    }

    @Test func endSessionStopsEverything() async throws {
        let (engine, _, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.hear(.endSession)
        await settle()

        #expect(engine.phase == .idle)
        #expect(!engine.isListening)
        #expect(await recognizer.didStop)
    }
}

// MARK: - Tempo

struct TempoTests {

    @Test func clampsAtBothEnds() {
        var tempo = Tempo.default

        for _ in 0..<50 { tempo.slower() }
        #expect(tempo.isSlowest)
        let slowest = tempo.gap
        tempo.slower()
        #expect(tempo.gap == slowest, "must not drift past the slowest setting")

        for _ in 0..<50 { tempo.faster() }
        #expect(tempo.isFastest)
        let fastest = tempo.gap
        tempo.faster()
        #expect(tempo.gap == fastest)
    }

    /// Callouts overlapping each other would be unusable, so the fastest gap has
    /// to leave room for a combo to actually be spoken.
    @Test func fastestGapStillLeavesRoomToSpeak() {
        var tempo = Tempo.default
        for _ in 0..<50 { tempo.faster() }
        #expect(tempo.gap >= 1.0)
    }

    @Test func roundTripsBackToStart() {
        var tempo = Tempo.default
        let original = tempo.gap
        tempo.slower()
        tempo.faster()
        #expect(abs(tempo.gap - original) < 0.001)
    }
}
