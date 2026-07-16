import Foundation
import Observation
import os

/// Abstracts the passage of time so the engine can be tested without waiting
/// three real minutes for a round to end.
nonisolated protocol Ticker: Sendable {
    func sleep(for duration: Duration) async throws
}

nonisolated struct SystemTicker: Ticker {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// The session state machine.
///
/// Main-actor isolated because the view observes it directly and a one-second
/// countdown costs nothing. Nothing here blocks — every wait is an `await` — so the
/// audio threads underneath are never held up by it.
@MainActor
@Observable
final class SessionEngine {

    enum Phase: Equatable {
        case idle
        case announcing
        case active
        case resting
        case debrief
    }

    // MARK: - Observable state

    private(set) var phase: Phase = .idle
    private(set) var round: Round?
    private(set) var currentCombo: Combo?
    private(set) var secondsRemaining: TimeInterval = 0
    private(set) var isPaused = false
    private(set) var isListening = false
    /// Flips once, when the session is over by any route — the last round
    /// finishing, "end session", or the End button. The view watches this so a
    /// voice-ended session still gets recorded; without it, saying "end session"
    /// would leave the screen up and the history unwritten.
    private(set) var isFinished = false
    private(set) var tempo = Tempo.default
    /// True while `again` is looping the last combo, until `stop`.
    private(set) var isRepeating = false
    /// The last thing the phone heard, command or not. M1 diagnostics.
    private(set) var lastHeard: String?

    var isResting: Bool { phase == .resting }

    /// What happened, for the history. Read once the session is over.
    var summary: SessionSummary {
        SessionSummary(
            title: session.title,
            focuses: session.rounds.map(\.focus),
            roundsPlanned: session.rounds.count,
            roundsCompleted: completedRounds,
            slowerRequests: slowerRequests,
            fasterRequests: fasterRequests,
            endedEarly: endedEarly
        )
    }

    // MARK: - Collaborators

    private let session: Session
    private let voice: any Voice
    private let recognizer: any VoiceRecognizer
    private let ticker: any Ticker
    /// Answers the things the twelve commands can't. Nil when there's no key —
    /// the twelve keep working regardless, which is the point of the split.
    private let coach: (any Coach)?
    private let level: TrainingProfile.Level
    private let log = Logger(subsystem: "Giorgi.Corner", category: "session")

    // MARK: - Private state

    private var sessionTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var unhandledTask: Task<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastCombo: Combo?
    private var bonusRounds: [Round] = []
    private var skipRequested = false

    /// What's actually being drilled right now.
    ///
    /// Separate from `round.combos` because the cornerman can replace them
    /// mid-round — "give me something for the body" rewrites the rest of the
    /// round. The round stays as Claude planned it; this is what's being served.
    private(set) var activeCombos: [Combo] = []

    /// The line being spoken right now, or nil when the cornerman is quiet.
    /// Read by the transcript stream to know whether there's anything to cut off.
    private var speaking: String?

    /// Counts lines so a finished one can tell whether it's still the current
    /// one before lowering the echo filter behind a newer line's back.
    private var speechGeneration = 0

    /// How long the speaker keeps bleeding a line after playback ends.
    static let echoDrain: Duration = .milliseconds(300)

    /// Combos called so far this round. Drives the cue rhythm; resets at the bell.
    private var calloutCount = 0

    /// Often enough that the round is coached rather than counted; rare enough
    /// that a cue stays a cue. A three-minute round is around thirty-five
    /// callouts, so this lands roughly eight — two or three cues, each said a
    /// handful of times, which is the repetition the whole idea rests on.
    nonisolated static let calloutsPerCue = 4
    /// One interpretation in flight at a time. Each costs a network call, and a
    /// second reply landing on top of the first would fight over the combos.
    private var isInterpreting = false

    // Observed, not inferred. These become the training history that makes the
    // next session different from this one.
    private var completedRounds = 0
    private var slowerRequests = 0
    private var fasterRequests = 0
    private var endedEarly = false

    /// A line the countdown wants said, drained by the callout loop.
    ///
    /// The countdown and the callouts run concurrently, so the countdown can't
    /// speak directly — it would talk over a combo mid-word. Handing the line
    /// to the loop that already owns the voice keeps them serialized.
    private var pendingCue: String?

    init(
        session: Session,
        voice: any Voice,
        recognizer: any VoiceRecognizer,
        ticker: any Ticker = SystemTicker(),
        coach: (any Coach)? = nil,
        level: TrainingProfile.Level = .beginner
    ) {
        self.session = session
        self.voice = voice
        self.recognizer = recognizer
        self.ticker = ticker
        self.coach = coach
        self.level = level
    }

    // MARK: - Lifecycle

    /// Begins listening. The session itself doesn't start until the user says so —
    /// this is the whole point of the app.
    func beginListening() async throws {
        // Fire this first and don't wait: the user is wrapping their hands, and
        // that dead time is exactly the budget a cloud voice needs. By the time
        // they say "let's go", round one is already sitting on disk.
        //
        // Round one only — the rest is fetched as each round approaches. See
        // `openingLines`.
        Task { [voice, session] in
            await voice.prewarm(Self.openingLines(of: session))
        }

        try await recognizer.start()
        isListening = true

        let stream = await recognizer.commands
        commandTask = Task { [weak self] in
            for await command in stream {
                guard let self else { return }
                await self.handle(command)
            }
        }

        let transcripts = await recognizer.transcripts
        transcriptTask = Task { [weak self] in
            for await text in transcripts {
                guard let self else { return }
                self.lastHeard = text
                await self.bargeIn()
            }
        }

        // Everything the twelve don't cover. Note what isn't here: the twelve
        // themselves never touch this path — they're parsed on-device and acted
        // on instantly, and a command that waited for a network round-trip would
        // undo the entire reason this app feels responsive.
        let unhandled = await recognizer.unhandled
        unhandledTask = Task { [weak self] in
            for await text in unhandled {
                await self?.interpret(text)
            }
        }
    }

    /// Stops the cornerman mid-word because the fighter started talking.
    ///
    /// Fires on volatile results — the first syllable, not the finished sentence
    /// — because the whole point is to stop *before* talking over someone. What
    /// they're saying doesn't matter yet and often isn't known yet; that they're
    /// saying anything is enough. The command or the question lands a moment
    /// later through its own path.
    ///
    /// Safe to call on anything reaching the transcript stream: the recognizer
    /// has already discarded the cornerman's own voice, so whatever arrives here
    /// while he's speaking is a real voice in the room.
    private func bargeIn() async {
        guard speaking != nil else { return }
        await voice.cancel()
    }

    // MARK: - Conversation

    /// Hands something we didn't understand to the cornerman.
    ///
    /// Deliberately doesn't pause the round while it thinks. A coach takes a
    /// second to answer and the fighter keeps working; freezing the session for
    /// a network call would be far stranger than a late reply.
    private func interpret(_ utterance: String) async {
        guard let coach, !isInterpreting, phase != .idle else { return }
        isInterpreting = true
        defer { isInterpreting = false }

        let moment = CoachingMoment(
            roundIndex: round?.index ?? 0,
            totalRounds: session.rounds.count,
            focus: round?.focus ?? "",
            secondsLeft: Int(secondsRemaining.rounded()),
            isResting: phase == .resting,
            currentCombos: activeCombos,
            level: level
        )

        let reply = await coach.interpret(utterance, during: moment)
        guard !Task.isCancelled else { return }
        await apply(reply)
    }

    private func apply(_ reply: CornermanReply) async {
        // A rephrase — "kick it off" — routes through the same command path a
        // parsed "let's go" takes, so there's one implementation of each action.
        if let command = reply.resolvedCommand {
            await handle(command)
        }

        // The thing no command can do: change what they're drilling.
        if !reply.combos.isEmpty {
            activeCombos = reply.combos
            lastCombo = nil
            log.info("Combos replaced mid-round: \(reply.combos.count, privacy: .public)")
            // Fetched in the background so a cloud voice has them ready by the
            // next callout instead of stalling on the first one.
            Task { [voice] in await voice.prewarm(reply.combos.map(\.spoken)) }
        }

        if !reply.reply.isEmpty {
            await say(reply.reply)
        }
    }

    func end() async {
        sessionTask?.cancel()
        commandTask?.cancel()
        transcriptTask?.cancel()
        unhandledTask?.cancel()
        resumeWaiters()
        await voice.cancel()
        // Anything still downloading is for rounds that will never be heard.
        await voice.stopPrewarming()
        await recognizer.stop()
        isListening = false
        phase = .idle
        isFinished = true
    }

    // MARK: - Commands

    func handle(_ command: VoiceCommand) async {
        log.debug("Command: \(command.rawValue, privacy: .public)")

        switch command {
        case .start:
            guard phase == .idle else { return }
            startSession()

        case .pause:
            guard !isPaused, phase != .idle else { return }
            isPaused = true
            // Cut the line off mid-word. A cornerman who finishes his sentence
            // after you've said stop isn't paused.
            await voice.cancel()

        case .resume:
            guard isPaused else { return }
            isPaused = false
            resumeWaiters()

        case .stop:
            // "Stop" only ever means "stop repeating". Ending the workout is
            // `endSession`, and conflating them would end sessions by accident.
            isRepeating = false

        case .slower:
            slowerRequests += 1
            tempo.slower()
            await say(tempo.isSlowest ? "That's as slow as I go." : "Slowing down.")

        case .faster:
            fasterRequests += 1
            tempo.faster()
            await say(tempo.isFastest ? "That's as fast as I go." : "Picking it up.")

        case .again:
            isRepeating = true

        case .skip:
            skipRequested = true
            await voice.cancel()

        case .nextRound:
            skipToNextRound()

        case .oneMoreRound:
            addBonusRound()

        case .timeCheck:
            await say(timeRemainingSpoken())

        case .endSession:
            endedEarly = phase != .debrief
            await say("Session over. Good work.")
            await end()
        }
    }


    // MARK: - Session flow

    /// Everything needed before the first bell — and nothing more.
    ///
    /// Deliberately not the whole session. A cloud voice charges per character,
    /// so fetching round six here means paying for it before the user has said
    /// "let's go", and paying again for every session they open and back out of.
    /// Round six is twenty minutes away; it can wait until round five.
    ///
    /// Also why the session is ready to start in seconds rather than a minute.
    nonisolated static func openingLines(of session: Session) -> [String] {
        var lines: [String] = []
        // Said the instant they say "let's go".
        if let intro = session.intro { lines.append(intro) }
        if let first = session.rounds.first {
            lines.append(contentsOf: self.lines(for: first, in: session))
        }
        // Answers to commands and the clock — these can land at any moment in
        // any round, so they're needed from the start. They're also identical
        // every session, so after the first they're already cached and free.
        lines.append(contentsOf: [
            "Last thirty seconds.",
            "Slowing down.", "Picking it up.",
            "That's as slow as I go.", "That's as fast as I go.",
            "That's the session. Well done.", "Session over. Good work.",
        ])
        return lines
    }

    /// One round's worth. Fetched while the previous round is being worked.
    nonisolated static func lines(for round: Round, in session: Session) -> [String] {
        var lines = ["Round \(round.index). \(round.focus)."]
        lines.append(contentsOf: round.combos.map(\.spoken))
        // Cheap to fetch and heard eight times a round: each one is paid for
        // once and then replayed from the cache all session. Leaving them out
        // would stall the round on a network fetch every fourth callout, which
        // is the one place a cue must not land — it's supposed to drop into the
        // rhythm, not interrupt it.
        lines.append(contentsOf: round.cues)
        if let talk = round.cornerTalk { lines.append(talk) }
        if round.index != session.rounds.count {
            lines.append("Round \(round.index + 1) coming up.")
        }
        return lines
    }

    private func startSession() {
        sessionTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    private func runSession() async {
        var index = 0
        var rounds = session.rounds


        // Before the first bell: what today is for. A corner tells you the plan
        // before you start throwing, and it's the whole difference between
        // being coached and being counted at.
        if let intro = session.intro {
            phase = .announcing
            await say(intro)
            guard !Task.isCancelled else { return }
        }

        while index < rounds.count {
            guard !Task.isCancelled else { return }
            let round = rounds[index]
            self.round = round

            phase = .announcing

            // Fetch the next round now, while this one is being worked. Three
            // minutes of slack is far more than a cloud voice needs, and it
            // means a session abandoned at round two never pays for round six.
            if index + 1 < rounds.count {
                let next = rounds[index + 1]
                Task { [voice, session] in
                    await voice.prewarm(Self.lines(for: next, in: session))
                }
            }

            await say("Round \(round.index). \(round.focus).")

            phase = .active
            await runRound(round)
            guard !Task.isCancelled else { return }
            completedRounds += 1

            // A round requested mid-session lands after the current one.
            if !bonusRounds.isEmpty {
                rounds.append(contentsOf: bonusRounds)
                bonusRounds.removeAll()
            }

            let isLast = index == rounds.count - 1
            if !isLast, round.rest > 0 {
                phase = .resting
                await runRest(round)
            }
            index += 1
        }

        guard !Task.isCancelled else { return }
        phase = .debrief
        currentCombo = nil
        // A finished workout has no business sitting on the Lock Screen.
        await say("That's the session. Well done.")
        // The rounds are done and the wrap-up has played; nothing is left to
        // listen for. M5 replaces this with a real debrief screen.
        isFinished = true
    }

    private func runRound(_ round: Round) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                await self?.countDown(from: round.duration)
            }
            group.addTask { @MainActor [weak self] in
                await self?.callCombos(in: round)
            }
            // The countdown is the only task that finishes on its own; the callout
            // loop runs until the round is over.
            await group.next()
            group.cancelAll()
        }
        await voice.cancel()
        currentCombo = nil
    }

    private func runRest(_ round: Round) async {
        currentCombo = nil
        if let talk = round.cornerTalk {
            await say(talk)
        }
        await countDown(from: round.rest)
        await say("Round \(round.index + 1) coming up.")
    }

    private func countDown(from seconds: TimeInterval) async {
        secondsRemaining = seconds
        while secondsRemaining > 0 {
            await waitWhilePaused()
            guard !Task.isCancelled else { return }
            try? await ticker.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            secondsRemaining -= 1

            // Every corner in the world shouts this. It's free — we already
            // know the time — and it's the moment people find another gear.
            if phase == .active, secondsRemaining == 30 {
                pendingCue = "Last thirty seconds."
            }
        }
    }

    private func callCombos(in round: Round) async {
        // The round's own combos are the starting point; the cornerman may
        // replace them from here.
        activeCombos = round.combos
        lastCombo = nil
        calloutCount = 0
        guard !activeCombos.isEmpty else { return }

        while !Task.isCancelled {
            await waitWhilePaused()
            guard !Task.isCancelled else { return }

            calloutCount += 1

            // Drained here, between combos, so a cue never lands on top of one.
            // A timed cue outranks a drilled one — "last thirty seconds" is only
            // true for a moment, while "chin" is true all round and comes back
            // around in four callouts anyway.
            if let cue = pendingCue ?? Self.cue(at: calloutCount, from: round.cues) {
                pendingCue = nil
                await say(cue)
                guard !Task.isCancelled else { return }
            }

            guard let combo = nextCombo() else { return }
            lastCombo = combo
            currentCombo = combo

            await say(combo.spoken)
            guard !Task.isCancelled else { return }

            if skipRequested {
                skipRequested = false
                continue
            }
            await waitBetweenCallouts()
        }
    }

    /// The cue to drop before the `callout`-th combo of a round, or nil.
    ///
    /// Cycles rather than shuffles, and that's the whole mechanism. The point
    /// isn't variety — it's that the same two or three things keep coming back
    /// until the fighter stops hearing them as instructions and starts just
    /// doing them. A random pick would be more interesting and would teach
    /// nothing.
    ///
    /// A pure function of the count so the rhythm can be tested without a clock:
    /// the callout loop only turns when a real gap elapses, and the test ticker
    /// exists to stop exactly that.
    nonisolated static func cue(at callout: Int, from cues: [String]) -> String? {
        guard !cues.isEmpty, callout > 0, callout % calloutsPerCue == 0 else { return nil }
        return cues[(callout / calloutsPerCue - 1) % cues.count]
    }

    /// Waits out the gap, re-reading the tempo as it goes.
    ///
    /// Deliberately not one long sleep. `tempo.gap` is read once when a sleep
    /// starts, so a "faster" spoken half a second into a 3.5s gap wouldn't land
    /// until the gap after next — about five seconds later, by which time you've
    /// already decided the app ignored you. Slicing lets the wait that's already
    /// running shorten underneath itself, so the next combo comes early.
    ///
    /// Also gives pause-during-a-gap for free, which one long sleep can't.
    private func waitBetweenCallouts() async {
        var waited: TimeInterval = 0
        while waited < tempo.gap {
            await waitWhilePaused()
            guard !Task.isCancelled else { return }
            try? await ticker.sleep(for: .milliseconds(100))
            waited += 0.1
        }
    }

    /// Reads `activeCombos`, not `round.combos` — the cornerman can replace the
    /// pool mid-round and the very next callout has to come from the new one.
    private func nextCombo() -> Combo? {
        guard !activeCombos.isEmpty else { return nil }
        if isRepeating, let lastCombo, activeCombos.contains(lastCombo) { return lastCombo }
        // Avoid calling the same combo twice in a row — it reads as a bug to the
        // person hearing it, even though it's just a fair coin.
        if activeCombos.count > 1, let lastCombo {
            return activeCombos.filter { $0 != lastCombo }.randomElement() ?? activeCombos[0]
        }
        return activeCombos.randomElement()
    }

    private func skipToNextRound() {
        // Ending the countdown ends the round; `runSession` moves on by itself.
        secondsRemaining = 0
    }

    private func addBonusRound() {
        guard let template = round else { return }
        let next = Round(
            index: (session.rounds.last?.index ?? 0) + bonusRounds.count + 1,
            focus: "One more",
            durationSeconds: template.durationSeconds,
            restSeconds: 0,
            combos: template.combos,
            // Same cues as the round it's extending — an extra round asked for
            // out loud is more of what they were just doing, and the cues are
            // the part that's supposed to be sinking in by now.
            cues: template.cues,
            cornerTalk: nil
        )
        bonusRounds.append(next)
        log.info("Bonus round queued")
    }

    // MARK: - Speech

    /// Speaks, with the ears closed.
    ///
    /// The grace period after the line ends covers audio still draining out of the
    /// speaker; without it the tail of a corner talk comes straight back in as a
    /// command.
    private func say(_ text: String) async {
        // The ears stay open through every line, including this one.
        //
        // They used to close for anything that could make the app obey itself —
        // corner talk says "next round", the intro ends with "let's go" — which
        // worked, and meant the fighter could not interrupt the thirty seconds
        // of intro at the top of every session. Handing over the script instead
        // of closing the mic keeps the protection and gives back the interruption:
        // the recognizer drops these exact words and hears everything else.
        speechGeneration += 1
        let generation = speechGeneration

        speaking = text
        await recognizer.setSpeaking(text)

        await voice.say(text)
        speaking = nil

        // Audio is still draining out of the speaker when `say` returns, and that
        // tail echoes like the rest of the line — so the filter outlives the line
        // by a beat.
        //
        // Detached, because waiting here would put 300ms between every combo and
        // the next. At the fastest tempo the gap is 500ms, so blocking would make
        // "faster" 60% weaker than it reads — the exact bug this app already had
        // once. Real time rather than the injected ticker: this is a property of
        // the hardware, not of session pacing.
        Task { [recognizer] in
            try? await Task.sleep(for: Self.echoDrain)
            // A newer line has already raised the filter; clearing it now would
            // strip the guard off a line that's still playing.
            guard self.speechGeneration == generation else { return }
            await recognizer.setSpeaking(nil)
        }
    }

    private func timeRemainingSpoken() -> String {
        let total = Int(secondsRemaining.rounded())
        let minutes = total / 60
        let seconds = total % 60

        let label = switch phase {
        case .resting: "left in the break"
        default: "left in the round"
        }

        if minutes > 0 && seconds > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") \(seconds) \(label)."
        } else if minutes > 0 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") \(label)."
        }
        return "\(seconds) second\(seconds == 1 ? "" : "s") \(label)."
    }

    // MARK: - Pause gate

    private func waitWhilePaused() async {
        guard isPaused else { return }
        await withCheckedContinuation { continuation in
            pauseWaiters.append(continuation)
        }
    }

    private func resumeWaiters() {
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
