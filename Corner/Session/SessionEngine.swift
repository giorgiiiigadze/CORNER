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
    private(set) var tempo = Tempo.default
    /// True while `again` is looping the last combo, until `stop`.
    private(set) var isRepeating = false
    /// The last thing the phone heard, command or not. M1 diagnostics.
    private(set) var lastHeard: String?

    var isResting: Bool { phase == .resting }

    // MARK: - Collaborators

    private let session: Session
    private let voice: any Voice
    private let recognizer: any VoiceRecognizer
    private let ticker: any Ticker
    private let log = Logger(subsystem: "Giorgi.Corner", category: "session")

    // MARK: - Private state

    private var sessionTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastCombo: Combo?
    private var bonusRounds: [Round] = []
    private var skipRequested = false

    init(
        session: Session,
        voice: any Voice,
        recognizer: any VoiceRecognizer,
        ticker: any Ticker = SystemTicker()
    ) {
        self.session = session
        self.voice = voice
        self.recognizer = recognizer
        self.ticker = ticker
    }

    // MARK: - Lifecycle

    /// Begins listening. The session itself doesn't start until the user says so —
    /// this is the whole point of the app.
    func beginListening() async throws {
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
    }

    func end() async {
        sessionTask?.cancel()
        commandTask?.cancel()
        transcriptTask?.cancel()
        resumeWaiters()
        await voice.cancel()
        await recognizer.stop()
        isListening = false
        phase = .idle
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
            tempo.slower()
            await say(tempo.isSlowest ? "That's as slow as I go." : "Slowing down.")

        case .faster:
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
            await say("Session over. Good work.")
            await end()
        }
    }

    // MARK: - Session flow

    private func startSession() {
        sessionTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    private func runSession() async {
        var index = 0
        var rounds = session.rounds

        while index < rounds.count {
            guard !Task.isCancelled else { return }
            let round = rounds[index]
            self.round = round

            phase = .announcing
            await say("Round \(round.index). \(round.focus).")

            phase = .active
            await runRound(round)
            guard !Task.isCancelled else { return }

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
        await say("That's the session. Well done.")
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
        }
    }

    private func callCombos(in round: Round) async {
        guard !round.combos.isEmpty else { return }

        while !Task.isCancelled {
            await waitWhilePaused()
            guard !Task.isCancelled else { return }

            let combo = nextCombo(in: round)
            lastCombo = combo
            currentCombo = combo

            await say(combo.spoken)
            guard !Task.isCancelled else { return }

            if skipRequested {
                skipRequested = false
                continue
            }
            try? await ticker.sleep(for: .seconds(tempo.gap))
        }
    }

    private func nextCombo(in round: Round) -> Combo {
        if isRepeating, let lastCombo { return lastCombo }
        // Avoid calling the same combo twice in a row — it reads as a bug to the
        // person hearing it, even though it's just a fair coin.
        if round.combos.count > 1, let lastCombo {
            return round.combos.filter { $0 != lastCombo }.randomElement() ?? round.combos[0]
        }
        return round.combos.randomElement() ?? round.combos[0]
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
        await recognizer.setMuted(true)
        await voice.say(text)
        try? await ticker.sleep(for: .milliseconds(300))
        await recognizer.setMuted(false)
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
