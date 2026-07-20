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

extension VoiceCommand {

    /// What the cornerman says back.
    ///
    /// Without this, "pause" is silence and a number that stopped changing on a
    /// screen across the room — indistinguishable from not being heard at all.
    /// You'd have to walk over and look, which is the one thing the app promises
    /// you never have to do.
    ///
    /// Nil where the action already answers for itself: `start` is followed by the
    /// intro, `timeCheck` and `endSession` speak, and there's no point saying
    /// "moving on" before saying "moving on".
    ///
    /// **Never put a command phrase in one of these.** "One more at the end"
    /// contains "one more", so the app hearing itself would queue another round —
    /// and another, and another. The echo filter catches it right up until one
    /// word comes back garbled and the match fails. `acknowledgementsAreNotCommands`
    /// is what actually holds this.
    ///
    /// `nonisolated` because the project builds with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise pin this
    /// to the main actor — and `openingLines(of:)` is nonisolated and reads it
    /// through a key path, which Swift 6 rejects outright.
    nonisolated var acknowledgement: String? {
        switch self {
        case .pause: "Pausing."
        case .resume: "Back to work."
        case .nextRound: "Moving on."
        case .oneMoreRound: "Adding a round at the end."
        case .cancel: "As you were."
        // `confirm` is followed by the session ending, which speaks for itself.
        case .start, .timeCheck, .endSession, .confirm: nil
        }
    }
}

/// The bell, as the engine sees it.
///
/// A protocol only so tests can count rings — a test can't hear the real one, and
/// the bell is now the app's primary signal, so "did it ring" is worth asserting.
@MainActor
protocol Ringer {
    func ring()
}

/// The session state machine.
///
/// A session is a bell, a clock, and one spoken line at the top. The engine used
/// to call combinations through every round; it doesn't any more. The fighter is
/// told what today is for and then works in silence, so almost everything here is
/// about keeping time and staying out of the way.
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
    private(set) var secondsRemaining: TimeInterval = 0
    private(set) var isPaused = false
    private(set) var isListening = false
    /// Flips once, when the session is over by any route — the last round
    /// finishing, "end session", or the End button. The view watches this so a
    /// voice-ended session still gets recorded; without it, saying "end session"
    /// would leave the screen up and the history unwritten.
    private(set) var isFinished = false
    /// The last thing the phone heard, command or not. Diagnostics.
    private(set) var lastHeard: String?

    var isResting: Bool { phase == .resting }

    /// Includes rounds added mid-session by "one more round", so the screen never
    /// says "round 7 of 6".
    var totalRounds: Int { session.rounds.count + bonusRounds.count }

    /// What happened, for the history. Read once the session is over.
    var summary: SessionSummary {
        SessionSummary(
            sessionID: session.id,
            title: session.title,
            focuses: session.rounds.map(\.focus),
            roundsPlanned: session.rounds.count,
            roundsCompleted: completedRounds,
            endedEarly: endedEarly,
            sessionSeconds: sessionSeconds,
            pauseCount: pauseCount
        )
    }

    // MARK: - Collaborators

    private let session: Session
    private let voice: any Voice
    private let recognizer: any VoiceRecognizer
    private let ticker: any Ticker
    private let bell: any Ringer
    private let intent: (any IntentReader)?
    private let log = Logger(subsystem: "Giorgi.Corner", category: "session")

    // MARK: - Private state

    private var sessionTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var intentTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?

    /// True between "end session" and the answer to "You sure?".
    ///
    /// Deliberately doesn't stop the clock. If the answer never comes, the round
    /// they're still in was never interrupted — the question cost them nothing,
    /// which is the only way asking it is free.
    private(set) var awaitingEndConfirmation = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var bonusRounds: [Round] = []

    /// True when the countdown that just ended was ended by the fighter rather
    /// than by time. Set by `nextRound`, read once, and cleared immediately.
    private var skipRequested = false

    /// Counts lines so a finished one can tell whether it's still the current
    /// one before lowering the echo filter behind a newer line's back.
    private var speechGeneration = 0

    /// How long the speaker keeps bleeding a line after playback ends.
    static let echoDrain: Duration = .milliseconds(300)

    /// The question, asked before the one thing that can't be undone.
    ///
    /// Note what it doesn't say: "say yes to end it". That would put the word
    /// "yes" in the app's own mouth a second before it listens for exactly that
    /// word — and the echo filter holds right up until one syllable comes back
    /// garbled, at which point the app answers its own question and ends the
    /// session nobody meant to end. Same rule as `acknowledgement`. Two words is
    /// also just what a corner would say.
    /// `nonisolated` for the same reason `acknowledgement` is: the project builds
    /// with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which pins even a string
    /// constant to the main actor — and `openingLines(of:)` is nonisolated and
    /// prewarms this.
    nonisolated static let confirmEndLine = "You sure?"

    /// How long the question stands before it's forgotten.
    ///
    /// Long enough to answer mid-round while breathing hard; short enough that a
    /// "yeah" thrown at someone across the gym two minutes later can't land on a
    /// question the fighter no longer remembers being asked.
    static let confirmationWindow: Duration = .seconds(10)

    // Observed, not inferred. These become the training history that makes the
    // next session different from this one.
    private var completedRounds = 0
    private var endedEarly = false

    /// Seconds the session actually ran — rounds and the rests between them.
    ///
    /// Counted a tick at a time rather than derived from the plan, because the
    /// plan is a claim and this is the measurement: a round walked out of at
    /// forty seconds contributes forty, not its planned three minutes.
    ///
    /// Rest counts; a pause doesn't. The difference is that rest is the session
    /// running and a pause is the session stopped — five minutes of wrapping
    /// your hands mid-workout isn't time you trained, and counting it would mean
    /// the way to a big number is to walk away.
    /// Readable because the panel shows it: the elapsed clock sits beside the
    /// controls the way a workout screen's does, counting the whole session
    /// rather than the round. Still only written here.
    private(set) var sessionSeconds = 0

    /// How often they stopped the clock. Evidence about the session's pitch —
    /// six pauses in six rounds is a session that was too much.
    private var pauseCount = 0

    /// Where the coaching preference lives. Read at the call site rather than
    /// here so tests can set it either way without touching `UserDefaults`.
    nonisolated static let coachingKey = "cornerman.speaksCoaching"

    /// Whether the cornerman explains the work or just runs it.
    ///
    /// Off, the session becomes bell-and-clock with voice control: commands
    /// still answer, the time check still speaks, the bell still rings. What
    /// goes quiet is the narration — the intro and each round's "Round 3. Body
    /// work. Stay low."
    ///
    /// That's the distinction worth keeping. Silencing the acknowledgements too
    /// would leave a fighter talking to a phone that never answers, with no way
    /// to tell a heard command from a missed one.
    private let speaksCoaching: Bool

    init(
        session: Session,
        voice: any Voice,
        recognizer: any VoiceRecognizer,
        speaksCoaching: Bool = true,
        // Nil means the phrase list is the whole story — no key, or a caller
        // that doesn't want the network. The session runs identically either
        // way; it just understands fewer ways of saying things.
        intent: (any IntentReader)? = nil,
        ticker: any Ticker = SystemTicker(),
        // Not `= Bell()`: a default argument is evaluated at the call site, which
        // isn't on the main actor, and `Bell` is. Built here instead, where we
        // already are.
        bell: (any Ringer)? = nil
    ) {
        self.session = session
        self.voice = voice
        self.recognizer = recognizer
        self.speaksCoaching = speaksCoaching
        self.intent = intent
        self.ticker = ticker
        self.bell = bell ?? Bell()
    }

    // MARK: - Lifecycle

    /// Begins listening. The session itself doesn't start until the user says so —
    /// this is the whole point of the app.
    func beginListening() async throws {
        // Fire this first and don't wait: the user is wrapping their hands, and
        // that dead time is exactly the budget a cloud voice needs. By the time
        // they say "let's go", the intro is already sitting on disk.
        Task { [voice, session] in
            await voice.prewarm(Self.openingLines(of: session, coaching: speaksCoaching))
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
                self?.lastHeard = text
            }
        }

        // Everything the phrase list didn't recognise, read for intent.
        //
        // One at a time, on purpose: `for await` won't pull the next sentence
        // until this one is answered, and the stream keeps only the newest. So a
        // fighter talking through a slow round-trip can't stack up a queue of
        // commands that all land at once when the network catches up.
        if let intent {
            let unmatched = await recognizer.unmatched
            intentTask = Task { [weak self] in
                for await text in unmatched {
                    guard let command = await intent.interpret(text) else { continue }
                    guard let self else { return }
                    await self.handle(command)
                }
            }
        }
    }

    func end() async {
        sessionTask?.cancel()
        commandTask?.cancel()
        transcriptTask?.cancel()
        intentTask?.cancel()
        confirmationTask?.cancel()
        resumeWaiters()
        await voice.cancel()
        await voice.stopPrewarming()
        await recognizer.stop()
        isListening = false
        phase = .idle
        isFinished = true
    }

    // MARK: - Commands

    /// Seven, down from twelve.
    ///
    /// The five that went — skip, again, stop, slower, faster — every one of them
    /// meant "do something to the combo callouts", and there are none. They're
    /// gone from the parser too, so a fighter who says "faster" out of habit gets
    /// silence rather than a wrong guess.
    func handle(_ command: VoiceCommand) async {
        log.debug("Command: \(command.rawValue, privacy: .public)")

        // Before the first bell, "let's go" is the only word with any power.
        //
        // The screen comes up the moment a session is written, and it sits there
        // while hands get wrapped, the phone gets propped, and the room carries
        // on talking. Every one of those is a stretch of speech nobody is
        // addressing to the app, and the grammar is seven common phrases — so
        // the mic was live over a conversation with the power to queue rounds
        // and end sessions before anything had started.
        //
        // Most commands were individually inert at idle already, by their own
        // guards. Not all: "one more round" answered "Adding a round at the end"
        // and added nothing, and "time check" read out a clock that wasn't
        // running. One rule in one place is worth more than seven guards that
        // each have to remember.
        //
        // Silently. A cornerman who argues with a room he isn't part of is
        // worse than one who waits to be spoken to.
        guard phase != .idle || command == .start else {
            log.debug("Ignored — the session hasn't started")
            return
        }

        // Anything else means they've moved on, and a question they've moved on
        // from isn't standing any more. Without this, "end session" … "next" …
        // "yeah" ends the session on a "yeah" that was answering nothing.
        if awaitingEndConfirmation, !command.answersAQuestion, command != .endSession {
            forgetTheQuestion()
        }

        switch command {
        case .start:
            guard phase == .idle else { return }
            startSession()

        case .pause:
            guard !isPaused, phase != .idle else { return }
            isPaused = true
            // After the guard, so it counts pauses that happened rather than
            // times the word was said.
            pauseCount += 1
            // Deliberately doesn't cut off whatever he's saying. It used to, back
            // when he talked over a running clock — a cornerman still calling
            // combos after you've said stop isn't paused. He only speaks before
            // the bell now, so there's no clock running to stop and nothing the
            // interruption would buy. The pause lands at the next countdown.
            await acknowledge(command)

        case .resume:
            guard isPaused else { return }
            isPaused = false
            resumeWaiters()
            await acknowledge(command)

        case .nextRound:
            skipToNextRound()
            await acknowledge(command)

        case .oneMoreRound:
            addBonusRound()
            await acknowledge(command)

        case .timeCheck:
            // The one place the app speaks during a round, and only because it
            // was asked. The clock is on the screen; this is for when you don't
            // want to look.
            await say(timeRemainingSpoken())

        case .endSession:
            // Before the first bell and after the last there's nothing to lose,
            // so the question would be pure ceremony — and a confirmation you
            // always say yes to teaches you to say yes without reading it.
            guard phase != .idle, phase != .debrief else {
                await endNow()
                return
            }
            // Saying it twice is a confirmation too. Someone who means it tends
            // to repeat themselves, not answer.
            guard !awaitingEndConfirmation else {
                await endNow()
                return
            }
            await askToConfirmEnd()

        case .confirm:
            // Inert unless a question is standing, which is what lets a word as
            // common as "yeah" live in the grammar at all.
            guard awaitingEndConfirmation else { return }
            await endNow()

        case .cancel:
            guard awaitingEndConfirmation else { return }
            forgetTheQuestion()
            await acknowledge(command)
        }
    }

    /// Asks, and starts the clock on the question.
    private func askToConfirmEnd() async {
        awaitingEndConfirmation = true

        confirmationTask?.cancel()
        confirmationTask = Task { [weak self, ticker] in
            try? await ticker.sleep(for: Self.confirmationWindow)
            guard !Task.isCancelled else { return }
            // Silently. A cornerman who announces that he's stopped waiting for
            // an answer is talking during a round for no reason.
            self?.awaitingEndConfirmation = false
        }

        await say(Self.confirmEndLine)
    }

    private func forgetTheQuestion() {
        confirmationTask?.cancel()
        confirmationTask = nil
        awaitingEndConfirmation = false
    }

    private func endNow() async {
        forgetTheQuestion()
        endedEarly = phase != .debrief
        await say("Session over. Good work.")
        await end()
    }

    /// Says the confirmation, if the command has one.
    ///
    /// Always *after* the state has already changed, never before. The line takes
    /// a second to play, and a "pausing" that arrives before the clock actually
    /// stops is a promise, not a confirmation.
    private func acknowledge(_ command: VoiceCommand) async {
        guard let line = command.acknowledgement else { return }
        await say(line)
    }

    // MARK: - Session flow

    /// Everything the cornerman will say all session, which is now a very short
    /// list: the plan, and the two ways a session can end.
    ///
    /// The per-round prefetch is gone with the combos. Nothing inside a round is
    /// spoken, so there's nothing left to fetch as rounds approach — the whole
    /// session's audio is three lines, and only the intro is unique to it.
    ///
    /// What the cornerman says as a round opens, assembled in one place.
    ///
    /// One function because two callers need this string and they must agree to
    /// the character: the engine says it, and the prefetcher fetches it a round
    /// early. The cache key is a hash of the text, so a stray comma between them
    /// isn't a mismatch anyone would notice — it's a miss, a fighter waiting on a
    /// network call at the bell, and the same words billed twice.
    ///
    /// The number and focus are the app's, not the model's; there's no reason to
    /// let Claude get numbering wrong when a loop index is exact.
    nonisolated static func openerLine(for round: Round) -> String {
        var line = "Round \(round.index). \(round.focus)."
        if let opener = round.opener {
            line += " \(opener)"
        }
        return line
    }

    /// Everything needed before the first bell — and nothing more.
    ///
    /// Deliberately not the whole session. A cloud voice charges per character,
    /// so fetching round six here means paying for it before the user has said
    /// "let's go", and paying again for every session they open and back out of.
    /// Round six is twenty minutes away; it can wait until round five.
    ///
    /// Time-check answers aren't here on purpose: there are ~180 of them, they're
    /// only heard when asked for, and they're identical in every session forever,
    /// so they cost one fetch each ever and then come from the cache.
    nonisolated static func openingLines(of session: Session, coaching: Bool = true) -> [String] {
        var lines: [String] = []

        // Skipped entirely when the cornerman isn't explaining. These are the
        // only per-session lines in the batch — every other line below is the
        // same words in every session forever — so not fetching them is the
        // whole saving: a cloud voice charges per character, and a fighter who
        // trains silently shouldn't pay for narration nobody hears.
        if coaching {
            if let intro = session.intro { lines.append(intro) }
            if let first = session.rounds.first { lines.append(openerLine(for: first)) }
        }

        // Answers that can land at any moment, so they can't be fetched when
        // they're due — a "pausing" that arrives a second after the pause is
        // worse than none, because by then you've already said it again.
        //
        // They're the same words in every session forever, so this is one fetch
        // each, ever, and free from the second session on.
        lines.append(contentsOf: VoiceCommand.allCases.compactMap(\.acknowledgement))
        lines.append(contentsOf: ["That's the session. Well done.", "Session over. Good work."])
        // The question has to come back instantly or it isn't a question — a
        // fighter who says "end session" into two seconds of silence says it
        // again, and the second one is the confirmation.
        lines.append(confirmEndLine)
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

        // Before the first bell: what today is for, and the one thing to hold
        // onto all the way through.
        if speaksCoaching, let intro = session.intro {
            phase = .announcing
            await say(intro)
            guard !Task.isCancelled else { return }
        }

        while index < rounds.count {
            guard !Task.isCancelled else { return }
            let round = rounds[index]
            self.round = round

            // Fetch the next round's line now, while this one is being worked.
            // Three minutes of slack is far more than a cloud voice needs, and it
            // means a session abandoned at round two never pays for round six.
            if speaksCoaching, index + 1 < rounds.count {
                let next = rounds[index + 1]
                Task { [voice] in await voice.prewarm([Self.openerLine(for: next)]) }
            }

            // What this round is and the one thing to hold in it, then the bell.
            // In that order: the bell means start punching and nothing else, and
            // a line said over a running clock is three minutes that became two
            // minutes fifty.
            if speaksCoaching {
                phase = .announcing
                await say(Self.openerLine(for: round))
                guard !Task.isCancelled else { return }
            }

            phase = .active
            bell.ring()
            await countDown(from: round.duration)
            guard !Task.isCancelled else { return }
            completedRounds += 1

            // Cleared, not read: how the round ended no longer changes what
            // happens next, since a skipped round rests like any other. It still
            // has to be cleared here — left standing it would satisfy the guard
            // in `skipToNextRound` and swallow the fighter's next "next round",
            // which is the one they'd say to cut the rest short.
            _ = consumeSkip()

            // A round requested mid-session lands after the current one. Ahead
            // of the bell below, because appending here is what decides whether
            // this round is the last one.
            if !bonusRounds.isEmpty {
                rounds.append(contentsOf: bonusRounds)
                bonusRounds.removeAll()
            }

            let isLast = index == rounds.count - 1

            // Ends the round and opens the rest in one stroke, the way a real
            // bell does — there aren't two sounds, there's one transition.
            //
            // Unconditional now. It used to be suppressed on a skip, because a
            // skip went straight into the next round's opener and its bell, and
            // two rings a sentence apart sound like a mistake. A skip lands in
            // the rest now, so every route out of a round is the same
            // transition and earns the same single ring.
            bell.ring()

            // A skipped round still gets its rest.
            //
            // This reverses what the code did before, and the argument it used
            // is worth keeping visible: "next round" was taken to mean the next
            // *round*, so cutting a round short jumped the rest as well, on the
            // grounds that resting isn't moving on.
            //
            // What that missed is why the words get said. Nobody says "next
            // round" because they want less rest — they say it because the round
            // is done, their arms are gone, or the combination stopped working.
            // Skipping the rest as well answered "I'm finished with this round"
            // with "then you don't need to breathe", which is the opposite of
            // what a corner does. The rest is the recovery the next round is
            // planned around; taking it away is a punishment for asking.
            //
            // Ending the rest early is still one word away: "next round" during
            // the rest does exactly that, which is where a fighter who genuinely
            // wants to crack on says it.
            if !isLast, round.rest > 0 {
                phase = .resting
                await countDown(from: round.rest)
                guard !Task.isCancelled else { return }
                // A skip during the rest just ends the rest — it's already going
                // where they asked. Cleared so it can't skip the round after it.
                _ = consumeSkip()
            }
            index += 1
        }

        guard !Task.isCancelled else { return }
        phase = .debrief
        await say("That's the session. Well done.")
        isFinished = true
    }

    /// The whole of a round: time passing.
    ///
    /// No task group any more. There used to be two concurrent jobs here — the
    /// clock and the callout loop — and the loop was quietly the more important
    /// one, since the cues and the thirty-second shout were drained from inside
    /// it. Now there's only the clock.
    private func countDown(from seconds: TimeInterval) async {
        secondsRemaining = seconds
        while secondsRemaining > 0 {
            await waitWhilePaused()
            guard !Task.isCancelled else { return }
            try? await ticker.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            secondsRemaining -= 1

            // Here, and only here, is a second of session. This runs for rounds
            // and for rests, and a pause never reaches it — `waitWhilePaused` is
            // above it. So the total is the session as it actually ran, and
            // nothing downstream has to subtract anything.
            sessionSeconds += 1
        }
    }

    /// Ends whichever countdown is running, and says why it ended.
    ///
    /// The countdown reaching zero and the fighter cutting it short are the same
    /// zero, and `runSession` has to tell them apart: a round that ran its course
    /// is owed its rest, and a round the fighter walked out of isn't.
    private func skipToNextRound() {
        // Nothing to cut short while the opener is being spoken — the countdown
        // hasn't started, and it would overwrite this the moment it does.
        guard phase == .active || phase == .resting else { return }

        // A skip already in flight swallows the second ask. The recognizer is
        // the one that should never send two, and now doesn't — but a command
        // that can silently cost a round is worth refusing twice, and the honest
        // reading of "next round, next round" from someone standing at a bag is
        // one round anyway: they said it again because the first one didn't look
        // like it landed.
        guard !skipRequested else { return }

        skipRequested = true
        secondsRemaining = 0
    }

    /// Reads the skip and clears it, so it can't leak into the next countdown.
    private func consumeSkip() -> Bool {
        defer { skipRequested = false }
        return skipRequested
    }

    private func addBonusRound() {
        guard let template = round else { return }
        let next = Round(
            index: (session.rounds.last?.index ?? 0) + bonusRounds.count + 1,
            focus: "One more",
            // Nothing to say about a round the fighter invented on the spot.
            // Claude planned the session; this one wasn't in it, and inventing a
            // coaching line for it would mean guessing. "Round 7. One more."
            opener: nil,
            durationSeconds: template.durationSeconds,
            restSeconds: 0
        )
        bonusRounds.append(next)
        log.info("Bonus round queued")
    }

    // MARK: - Speech

    /// Speaks, and tells the recognizer what's being said so it can ignore itself.
    ///
    /// Every line runs to the end. Nothing cancels one: the fighter can't
    /// interrupt, and no command tries to. His lines are short and they all land
    /// before the clock starts, so there is nothing an interruption would save —
    /// and cutting the intro off mid-sentence, which is what actually happened,
    /// is the whole cost of allowing it.
    private func say(_ text: String) async {
        // The mic stays open throughout, but the recognizer is handed the script
        // so it can drop these exact words. Without that, an intro ending "let's
        // go" or an opener saying "save it for the next round" is a command the
        // app gives itself.
        speechGeneration += 1
        let generation = speechGeneration

        await recognizer.setSpeaking(text)
        await voice.say(text)

        // Audio is still draining out of the speaker when `say` returns, and that
        // tail echoes like the rest of the line — so the filter outlives the line
        // by a beat.
        //
        // Detached rather than awaited: holding the session here for 300ms after
        // every line was a real bug once. Real time rather than the injected
        // ticker, being a property of the hardware and not of session pacing.
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
