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
            title: session.title,
            focuses: session.rounds.map(\.focus),
            roundsPlanned: session.rounds.count,
            roundsCompleted: completedRounds,
            endedEarly: endedEarly
        )
    }

    // MARK: - Collaborators

    private let session: Session
    private let voice: any Voice
    private let recognizer: any VoiceRecognizer
    private let ticker: any Ticker
    private let bell: any Ringer
    private let log = Logger(subsystem: "Giorgi.Corner", category: "session")

    // MARK: - Private state

    private var sessionTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var bonusRounds: [Round] = []

    /// The line being spoken right now, or nil when the cornerman is quiet.
    /// Read by the transcript stream to know whether there's anything to cut off.
    private var speaking: String?

    /// Counts lines so a finished one can tell whether it's still the current
    /// one before lowering the echo filter behind a newer line's back.
    private var speechGeneration = 0

    /// How long the speaker keeps bleeding a line after playback ends.
    static let echoDrain: Duration = .milliseconds(300)

    // Observed, not inferred. These become the training history that makes the
    // next session different from this one.
    private var completedRounds = 0
    private var endedEarly = false

    init(
        session: Session,
        voice: any Voice,
        recognizer: any VoiceRecognizer,
        ticker: any Ticker = SystemTicker(),
        // Not `= Bell()`: a default argument is evaluated at the call site, which
        // isn't on the main actor, and `Bell` is. Built here instead, where we
        // already are.
        bell: (any Ringer)? = nil
    ) {
        self.session = session
        self.voice = voice
        self.recognizer = recognizer
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
            await voice.prewarm(Self.spokenLines(of: session))
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
    }

    /// Stops the cornerman mid-word because the fighter started talking.
    ///
    /// Fires on volatile results — the first syllable, not the finished sentence
    /// — because the whole point is to stop *before* talking over someone. What
    /// they're saying doesn't matter yet and often isn't known yet; that they're
    /// saying anything is enough. The command lands a moment later through its
    /// own path.
    ///
    /// Still earns its place with the coach mostly silent: the intro is the one
    /// long line left, and it's exactly the one a fighter talks over to get going.
    ///
    /// Safe to call on anything reaching the transcript stream: the recognizer
    /// has already discarded the cornerman's own voice, so whatever arrives here
    /// while he's speaking is a real voice in the room.
    private func bargeIn() async {
        guard speaking != nil else { return }
        await voice.cancel()
    }

    func end() async {
        sessionTask?.cancel()
        commandTask?.cancel()
        transcriptTask?.cancel()
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

        case .nextRound:
            skipToNextRound()

        case .oneMoreRound:
            addBonusRound()

        case .timeCheck:
            // The one place the app speaks during a round, and only because it
            // was asked. The clock is on the screen; this is for when you don't
            // want to look.
            await say(timeRemainingSpoken())

        case .endSession:
            endedEarly = phase != .debrief
            await say("Session over. Good work.")
            await end()
        }
    }

    // MARK: - Session flow

    /// Everything the cornerman will say all session, which is now a very short
    /// list: the plan, and the two ways a session can end.
    ///
    /// The per-round prefetch is gone with the combos. Nothing inside a round is
    /// spoken, so there's nothing left to fetch as rounds approach — the whole
    /// session's audio is three lines, and only the intro is unique to it.
    ///
    /// Time-check answers aren't here on purpose: there are ~180 of them, they're
    /// only heard when asked for, and they're identical in every session forever,
    /// so they cost one fetch each ever and then come from the cache.
    nonisolated static func spokenLines(of session: Session) -> [String] {
        var lines: [String] = []
        if let intro = session.intro { lines.append(intro) }
        lines.append(contentsOf: ["That's the session. Well done.", "Session over. Good work."])
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

        // Before the first bell: what today is for. This is the only thing the
        // app says unprompted all session, so it's carrying the entire plan.
        if let intro = session.intro {
            phase = .announcing
            await say(intro)
            guard !Task.isCancelled else { return }
        }

        while index < rounds.count {
            guard !Task.isCancelled else { return }
            let round = rounds[index]
            self.round = round

            phase = .active
            bell.ring()
            await countDown(from: round.duration)
            guard !Task.isCancelled else { return }
            completedRounds += 1

            // Ends the round and opens the rest in one stroke, the way a real
            // bell does — there aren't two sounds, there's one transition.
            bell.ring()

            // A round requested mid-session lands after the current one.
            if !bonusRounds.isEmpty {
                rounds.append(contentsOf: bonusRounds)
                bonusRounds.removeAll()
            }

            let isLast = index == rounds.count - 1
            if !isLast, round.rest > 0 {
                phase = .resting
                await countDown(from: round.rest)
                guard !Task.isCancelled else { return }
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
        }
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
            restSeconds: 0
        )
        bonusRounds.append(next)
        log.info("Bonus round queued")
    }

    // MARK: - Speech

    /// Speaks, and tells the recognizer what's being said so it can ignore itself.
    private func say(_ text: String) async {
        // The ears stay open through every line, including this one.
        //
        // They used to close for anything that could make the app obey itself,
        // which worked and meant the fighter could not interrupt the intro at the
        // top of every session. Handing over the script instead of closing the
        // mic keeps the protection and gives back the interruption: the
        // recognizer drops these exact words and hears everything else.
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
