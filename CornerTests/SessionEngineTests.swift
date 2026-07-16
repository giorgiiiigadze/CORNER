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
    /// Appends, mirroring the real voice: prewarm is called once per round and
    /// each batch adds to what's cached. Replacing here would hide a batch
    /// clobbering the one before it.
    func prewarm(_ lines: [String]) async { prewarmed.append(contentsOf: lines) }
    func stopPrewarming() async { didStopPrewarming = true }
}

private actor FakeRecognizer: VoiceRecognizer {
    private let stream: AsyncStream<VoiceCommand>
    private let continuation: AsyncStream<VoiceCommand>.Continuation
    private let transcriptStream: AsyncStream<String>
    private let transcriptContinuation: AsyncStream<String>.Continuation
    private let unhandledStream: AsyncStream<String>
    private let unhandledContinuation: AsyncStream<String>.Continuation

    /// Every line the engine announced it was saying, nils included — the nils
    /// are what prove the echo filter is lowered again afterwards.
    private(set) var spokenLines: [String?] = []
    private(set) var didStart = false
    private(set) var didStop = false

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: VoiceCommand.self)
        (transcriptStream, transcriptContinuation) = AsyncStream.makeStream(of: String.self)
        (unhandledStream, unhandledContinuation) = AsyncStream.makeStream(of: String.self)
    }

    var commands: AsyncStream<VoiceCommand> { stream }
    var transcripts: AsyncStream<String> { transcriptStream }
    var unhandled: AsyncStream<String> { unhandledStream }

    /// Simulates saying something the twelve don't cover.
    func say(_ text: String) { unhandledContinuation.yield(text) }

    func start() async throws { didStart = true }
    func stop() async {
        didStop = true
        continuation.finish()
        transcriptContinuation.finish()
        unhandledContinuation.finish()
    }
    func setSpeaking(_ line: String?) async { spokenLines.append(line) }

    /// Simulates the user speaking.
    func hear(_ command: VoiceCommand) { continuation.yield(command) }

    /// Simulates raw text arriving from the transcriber.
    func transcribe(_ text: String) { transcriptContinuation.yield(text) }
}

private actor FakeCoach: Coach {
    private let reply: CornermanReply
    private(set) var heard: [String] = []
    private(set) var moments: [CoachingMoment] = []

    init(reply: CornermanReply = .nothing) { self.reply = reply }

    func interpret(_ utterance: String, during moment: CoachingMoment) async -> CornermanReply {
        heard.append(utterance)
        moments.append(moment)
        return reply
    }
}

/// Parks every wait the session schedules, so the engine settles somewhere
/// stable and observable instead of racing a real clock. A three-minute round
/// costs no test time.
///
/// The threshold is 100ms rather than a second, and that matters: the gap
/// between callouts is now waited in 100ms slices, so that a "faster" can
/// shorten the gap already running. A one-second threshold would wave those
/// slices through and the callout loop would spin, calling combos as fast as the
/// CPU allows.
///
/// Nothing else in the engine sleeps on the injected ticker below a second — the
/// mute grace deliberately uses real time, being a fact about speaker hardware
/// rather than about pacing.
private struct GateTicker: Ticker {
    func sleep(for duration: Duration) async throws {
        guard duration >= .milliseconds(100) else { return }
        try await Task.sleep(for: .seconds(3600))  // cancellable, unlike a parked continuation
    }
}

// MARK: - Fixture

private let testSession = Session(
    id: "test",
    title: "Test",
    intro: "Two rounds. Keep your hands up.",
    rounds: [
        Round(
            index: 1, focus: "Straight punches", durationSeconds: 180, restSeconds: 60,
            combos: [Combo(display: "1 - 2", spoken: "one, two")],
            // Two, so the cycling is observable: a single cue can't prove it
            // moves on, and three can't prove it comes back around.
            cues: ["Hands up.", "Chin down."],
            cornerTalk: "Keep it long."
        ),
        Round(
            index: 2, focus: "Hooks", durationSeconds: 180, restSeconds: 0,
            combos: [Combo(display: "3", spoken: "hook")],
            cues: ["Turn the hip over."],
            cornerTalk: nil
        ),
    ]
)

@MainActor
struct SessionEngineTests {

    private func makeEngine(coach: FakeCoach? = nil) -> (SessionEngine, FakeVoice, FakeRecognizer) {
        let voice = FakeVoice()
        let recognizer = FakeRecognizer()
        let engine = SessionEngine(
            session: testSession,
            voice: voice,
            recognizer: recognizer,
            ticker: GateTicker(),
            coach: coach
        )
        return (engine, voice, recognizer)
    }

    /// Lets the engine's tasks run until they park.
    ///
    /// `times` exists for the one wait that isn't faked — the 300ms mute grace
    /// after a line that could trigger the app itself. Tests that assert on
    /// muting have to outlast it.
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
    /// when the suite runs in parallel. This waits for the outcome and gives up
    /// only when it's genuinely not coming.
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

    // MARK: - Cues

    /// The mechanism the whole idea rests on: the same two or three corrections
    /// keep coming back until they stop being instructions. Cycling, not
    /// shuffling — a random pick would be more interesting and teach nothing.
    @Test func cuesCycleSoTheyRepeat() {
        let cues = ["Hands up.", "Chin down."]
        let every = SessionEngine.calloutsPerCue

        #expect(SessionEngine.cue(at: every, from: cues) == "Hands up.")
        #expect(SessionEngine.cue(at: every * 2, from: cues) == "Chin down.")
        #expect(SessionEngine.cue(at: every * 3, from: cues) == "Hands up.", "must come back around")
        #expect(SessionEngine.cue(at: every * 4, from: cues) == "Chin down.")
    }

    /// Between cues the round is just work. A cue on every callout is a monologue,
    /// which is the opposite of the point.
    @Test func mostCalloutsCarryNoCue() {
        let cues = ["Hands up.", "Chin down."]
        for callout in 1..<SessionEngine.calloutsPerCue {
            #expect(SessionEngine.cue(at: callout, from: cues) == nil)
        }
    }

    /// A round can arrive with no cues — an old cached session, or a model that
    /// ignored the schema. It should be a quiet round, not a crash.
    @Test func noCuesIsSilentNotFatal() {
        #expect(SessionEngine.cue(at: SessionEngine.calloutsPerCue, from: []) == nil)
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
        #expect(lines.contains("Round 1. Straight punches."))
        #expect(lines.contains("one, two"))
    }

    /// The plan comes before the punches. A corner tells you what today is for
    /// before the first bell — without it this is a timer with a vocabulary.
    @Test func theIntroIsSaidBeforeAnythingElse() async throws {
        let (engine, voice, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        let lines = await voice.lines
        #expect(lines.first == "Two rounds. Keep your hands up.")

        let intro = lines.firstIndex(of: "Two rounds. Keep your hands up.")
        let firstRound = lines.firstIndex(of: "Round 1. Straight punches.")
        #expect(intro != nil && firstRound != nil && intro! < firstRound!)
    }

    /// Everything needed before the first bell must be fetched up front, or a
    /// cloud voice stalls on the opening line.
    @Test func theOpeningCoversRoundOneAndTheCues() async throws {
        let lines = Set(SessionEngine.openingLines(of: testSession))

        #expect(lines.contains("Two rounds. Keep your hands up."))   // intro
        #expect(lines.contains("Round 1. Straight punches."))
        #expect(lines.contains("one, two"))                          // round 1 combo
        #expect(lines.contains("Keep it long."))                     // round 1 corner talk
        // Every fourth callout is one of these. A cue that has to be fetched
        // when it's due arrives late, and a late cue isn't in the rhythm.
        #expect(lines.contains("Hands up."))
        #expect(lines.contains("Chin down."))
        // These can land at any moment in any round.
        #expect(lines.contains("Last thirty seconds."))
        #expect(lines.contains("Slowing down."))
    }

    /// The money test. Fetching the whole session the moment the live screen
    /// opens means paying for round six before "let's go" — and paying again
    /// every time someone opens a session and backs out.
    @Test func theOpeningDoesNotPayForLaterRounds() async throws {
        let lines = Set(SessionEngine.openingLines(of: testSession))

        #expect(!lines.contains("hook"), "round 2's combos must wait until round 1 is being worked")
        #expect(!lines.contains("Round 2. Hooks."))
    }

    @Test func onlyTheOpeningIsFetchedBeforeTheSessionStarts() async throws {
        let (engine, voice, _) = makeEngine()
        try await engine.beginListening()
        await settle()

        // Prewarmed on the live screen — before "let's go", while the user is
        // still wrapping their hands.
        let warmed = await voice.prewarmed
        #expect(warmed.contains("one, two"))
        #expect(warmed.contains("Two rounds. Keep your hands up."))
        #expect(!warmed.contains("hook"), "round 2 isn't paid for until it's close")
    }

    /// Round two arrives while round one is being worked — three minutes of
    /// slack, so it's ready without ever being paid for early.
    @Test func theNextRoundIsFetchedDuringTheCurrentOne() async throws {
        let (engine, voice, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        let warmed = await voice.prewarmed
        #expect(warmed.contains("hook"), "round 2's combo should be fetched once round 1 starts")
    }

    /// The reason commands feel instant.
    ///
    /// Combos are the bulk of what the cornerman says and they parse to nothing,
    /// so a voice in the room cuts him off mid-word. The fighter shouldn't have
    /// to wait for the sentence to end before asking for something.
    @Test func stopsTalkingWhenTheFighterSpeaks() async throws {
        let (engine, voice, recognizer) = makeEngine()
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

    /// The mirror of the above, and the reason it can't just cancel on every
    /// transcript: nothing is playing, so there's nothing to interrupt. Cancelling
    /// into silence is harmless today and would be a landmine the moment `cancel`
    /// grows a side effect.
    @Test func doesNotBargeInWhenTheCornermanIsQuiet() async throws {
        let (engine, voice, recognizer) = makeEngine()
        try await engine.beginListening()

        await recognizer.transcribe("just talking to myself")
        await settle()

        #expect(await voice.cancelCount == 0, "nothing is playing — nothing to cut off")
    }

    /// The protection that must survive dropping the mute. Corner talk really does
    /// say "next round", and an app that obeys its own voice is worse than a slow
    /// one. The recognizer can only filter the echo if it's told the script.
    @Test func tellsTheRecognizerWhatItIsSaying() async throws {
        let session = Session(
            id: "risky",
            title: "Risky",
            intro: "Next round we start on the jab.",   // parses to .nextRound
            rounds: [
                Round(
                    index: 1, focus: "Jab", durationSeconds: 180, restSeconds: 0,
                    combos: [Combo(display: "1", spoken: "jab")],
                    cues: ["Hands up."],
                    cornerTalk: nil
                )
            ]
        )
        let voice = FakeVoice()
        let recognizer = FakeRecognizer()
        let engine = SessionEngine(
            session: session, voice: voice, recognizer: recognizer, ticker: GateTicker()
        )

        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        #expect(
            await recognizer.spokenLines.contains("Next round we start on the jab."),
            "the recognizer can't discard an echo of a line it was never given"
        )

        // `.some(nil)` rather than `nil`: `spokenLines` is `[String?]`, so `last`
        // is doubly optional and comparing it to `nil` asks whether the array is
        // empty — which is true of a session that never spoke at all.
        //
        // Deliberately not asserting a strict line/nil alternation. The drain is
        // detached and generation-guarded, so a line raised while an earlier one
        // is still draining swallows the earlier nil — that's the guard working,
        // not a leak. What must hold is that the filter ends down.
        let lowered = await eventually { await recognizer.spokenLines.last == .some(nil) }
        #expect(lowered, "must always lower the filter, or real speech gets eaten")
    }

    /// The two halves have to agree. If the parser says a line is a command, the
    /// engine must mute for it; if it doesn't, the engine must not.
    @Test func theMuteDecisionMatchesTheParser() {
        #expect(CommandParser.parse("one, two, hook to the body") == nil)
        #expect(CommandParser.parse("jab, slip, one, two") == nil)
        #expect(CommandParser.parse("Next round, snap it back to your chin.") == .nextRound)
        #expect(CommandParser.parse("Hold onto this the whole way through. Let's go.") == .start)
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

    /// "escape" is what the recogniser hears when you say "skip".
    @Test func aMisheardSkipStillSkips() {
        #expect(CommandParser.parse("escape") == .skip)
        #expect(CommandParser.parse("skipped") == .skip)
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
        let (engine, voice, recognizer) = makeEngine()
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.hear(.endSession)
        await settle()

        #expect(engine.phase == .idle)
        #expect(!engine.isListening)
        #expect(await recognizer.didStop)
        #expect(await voice.didStopPrewarming, "quitting must stop paying for rounds nobody will hear")
    }

    // MARK: - Talking to the cornerman

    /// The guard on everything else here. The twelve are parsed on-device and
    /// must never wait for a network — if this fails, "pause" got slow again and
    /// the whole reason the app feels responsive is gone.
    @Test func theTwelveNeverReachTheCoach() async throws {
        let coach = FakeCoach()
        let (engine, _, recognizer) = makeEngine(coach: coach)
        try await engine.beginListening()

        await recognizer.hear(.start)
        await recognizer.hear(.pause)
        await recognizer.hear(.faster)
        await settle()

        #expect(await coach.heard.isEmpty, "commands must be answered on-device, never over the network")
        #expect(engine.isPaused, "and they must still work")
    }

    /// The thing no command can do: change what you're drilling, mid-round.
    @Test func aReplyCanReplaceTheCombosMidRound() async throws {
        let coach = FakeCoach(reply: CornermanReply(
            command: "none",
            reply: "Body work. Dig in.",
            combos: [
                Combo(display: "1 - 2b", spoken: "jab, cross to the body"),
                Combo(display: "3b - 2", spoken: "hook to the body, cross"),
            ]
        ))
        let (engine, voice, recognizer) = makeEngine(coach: coach)
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        #expect(engine.currentCombo?.display == "1 - 2", "precondition: drilling the round's own combos")

        await recognizer.say("give me something for the body")
        await settle()

        #expect(await coach.heard == ["give me something for the body"])
        #expect(await voice.lines.contains("Body work. Dig in."), "says why it changed")

        // Asserted on the pool rather than `currentCombo`: the ticker parks the
        // callout loop mid-gap, so the *next* combo hasn't been drawn yet. What
        // matters is that the round's own combos are gone and only the new ones
        // can be served from here.
        #expect(engine.activeCombos.map(\.display) == ["1 - 2b", "3b - 2"])
    }

    /// A rephrase the parser missed runs through the same command path a parsed
    /// one takes — one implementation of each action, not two.
    @Test func aReplyCanRunOneOfTheTwelve() async throws {
        let coach = FakeCoach(reply: CornermanReply(command: "pause", reply: "", combos: []))
        let (engine, _, recognizer) = makeEngine(coach: coach)
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.say("hold your horses a second")
        await settle()

        #expect(engine.isPaused)
    }

    /// Most of what a corner says needs no action at all.
    @Test func aReplyCanJustSaySomething() async throws {
        let coach = FakeCoach(reply: CornermanReply(
            command: "none", reply: "Two rounds in. Keep working.", combos: []
        ))
        let (engine, voice, recognizer) = makeEngine(coach: coach)
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.say("how am I doing")
        await settle()

        #expect(await voice.lines.contains("Two rounds in. Keep working."))
        #expect(!engine.isPaused, "answering a question shouldn't disturb the round")
    }

    /// Song lyrics, half a sentence aimed at someone else — the coach returns
    /// nothing and the round carries on untouched.
    @Test func silenceFromTheCoachChangesNothing() async throws {
        let coach = FakeCoach(reply: .nothing)
        let (engine, voice, recognizer) = makeEngine(coach: coach)
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()
        let before = await voice.lines.count

        await recognizer.say("and I was like baby baby baby oh")
        await settle()

        #expect(await voice.lines.count == before, "nothing said")
        #expect(!engine.isPaused)
    }

    /// The coach has to be told what's actually happening, or it answers in the
    /// abstract — and can't change combos it doesn't know about.
    @Test func theCoachIsGivenTheCurrentRound() async throws {
        let coach = FakeCoach()
        let (engine, _, recognizer) = makeEngine(coach: coach)
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.say("what are we working on")
        await settle()

        let moment = await coach.moments.first
        #expect(moment?.roundIndex == 1)
        #expect(moment?.focus == "Straight punches")
        #expect(moment?.currentCombos.isEmpty == false)
    }

    /// No key, no coach — and the session is completely unaffected. The twelve
    /// are the offline product.
    @Test func worksWithNoCoachAtAll() async throws {
        let (engine, _, recognizer) = makeEngine(coach: nil)
        try await engine.beginListening()
        await recognizer.hear(.start)
        await settle()

        await recognizer.say("give me something for the body")
        await settle()

        #expect(engine.phase == .active, "no coach, no crash, round carries on")
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

    /// The bar this change exists to clear.
    ///
    /// The old step moved the gap 3.5 → 2.75. But what a person feels is the
    /// cycle — ~2s of spoken combo plus the gap — so that was 5.5s → 4.75s, a
    /// 14% change, under the threshold of noticing. Saying "faster" and hearing
    /// no difference is indistinguishable from being ignored.
    @Test func oneStepIsBigEnoughToNotice() {
        var tempo = Tempo.default
        let before = tempo.gap
        tempo.faster()

        let change = (before - tempo.gap) / before
        #expect(change >= 0.25, "one 'faster' must cut the gap by at least a quarter")
    }

    /// A real flurry has to be reachable. The old 1.5s floor plus ~2s of combo
    /// audio meant the fastest possible pace was a combo every 3.5 seconds — no
    /// amount of asking could get anything sharper.
    @Test func repeatedFasterReachesAFlurry() {
        var tempo = Tempo.default
        for _ in 0..<10 { tempo.faster() }

        #expect(tempo.gap <= 0.6)
        #expect(tempo.isFastest)
    }

    /// Scaling has to be symmetric, or "slower" then "faster" would drift and
    /// the tempo would slowly wander away from where it started.
    @Test func roundTripsBackToStart() {
        var tempo = Tempo.default
        let original = tempo.gap
        tempo.slower()
        tempo.faster()
        #expect(abs(tempo.gap - original) < 0.001)
    }
}
