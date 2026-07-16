@preconcurrency import AVFoundation
import CoreMedia
import Speech
import os

/// The ears, built on iOS 26's `SpeechAnalyzer`.
///
/// Three choices here carry the accuracy of the whole product:
///
/// 1. **Contextual biasing.** `AnalysisContext.contextualStrings` is seeded with every
///    command phrase, so the transcriber favours "slower" over "slow her" when a heavy
///    bag is being hit two metres away. For a twelve-word grammar this is the single
///    biggest lever available.
/// 2. **Volatile results.** Acting on tentative text rather than waiting for
///    finalization is what makes "pause" feel immediate mid-combo. The exception is
///    `.endSession` — see `handle(_:)`.
/// 3. **Hard mute while speaking.** Audio is dropped, not merely ignored, while the
///    cornerman talks. Corner talks contain phrases like "next round, snap it back",
///    and an app that obeys its own voice would end the session on its own.
actor SpeechAnalyzerRecognizer: VoiceRecognizer {

    enum Failure: Error, LocalizedError {
        case localeUnsupported(Locale)
        case assetsUnavailable
        case noCompatibleAudioFormat

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let l): "Speech recognition isn't supported for \(l.identifier)."
            case .assetsUnavailable: "The on-device speech model could not be installed."
            case .noCompatibleAudioFormat: "No microphone format the transcriber can read."
            }
        }
    }

    /// The line the cornerman is saying right now, or nil when he's quiet.
    ///
    /// Read from the realtime audio thread, so it cannot live in actor state.
    private final class SpokenLine: Sendable {
        private let lock = OSAllocatedUnfairLock<String?>(initialState: nil)
        var current: String? { lock.withLock { $0 } }
        func set(_ value: String?) { lock.withLock { $0 = value } }
    }

    private let locale: Locale
    private let engine = AVAudioEngine()
    private let spokenLine = SpokenLine()
    private let log = Logger(subsystem: "Giorgi.Corner", category: "voice")

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var isRunning = false

    /// Everything at or before this stream time has already produced a command.
    /// Without it, a phrase fires once as a volatile result and again when finalized.
    private var consumedThrough: CMTime = .negativeInfinity

    private let commandContinuation: AsyncStream<VoiceCommand>.Continuation
    private let commandStream: AsyncStream<VoiceCommand>
    private let transcriptContinuation: AsyncStream<String>.Continuation
    private let transcriptStream: AsyncStream<String>
    private let unhandledContinuation: AsyncStream<String>.Continuation
    private let unhandledStream: AsyncStream<String>

    var commands: AsyncStream<VoiceCommand> { commandStream }
    var transcripts: AsyncStream<String> { transcriptStream }
    var unhandled: AsyncStream<String> { unhandledStream }

    init(locale: Locale = Locale.current) {
        self.locale = locale
        (commandStream, commandContinuation) = AsyncStream.makeStream(of: VoiceCommand.self)
        (transcriptStream, transcriptContinuation) = AsyncStream.makeStream(of: String.self)
        (unhandledStream, unhandledContinuation) = AsyncStream.makeStream(of: String.self)
    }

    // MARK: - Lifecycle

    /// Requires an already-active `.playAndRecord` audio session — the input node
    /// reports a zero sample rate until the session is live.
    func start() async throws {
        guard !isRunning else { return }

        let transcriber = try await makeTranscriber()
        self.transcriber = transcriber

        let context = AnalysisContext()
        context.contextualStrings[.general] = CommandParser.contextualStrings

        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputContinuation = inputContinuation

        // This initializer *begins analysis by itself*. Do not also call
        // `start(inputSequence:)` — that stops the autonomous analysis and restarts
        // it on the sequence passed there, and an `AsyncStream` can only be iterated
        // once. Doing both leaves the mic feeding a stream nobody reads: no error,
        // no crash, and not a single command ever heard.
        let analyzer = SpeechAnalyzer(
            inputSequence: inputSequence,
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime),
            analysisContext: context
        )
        self.analyzer = analyzer

        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else {
            throw Failure.noCompatibleAudioFormat
        }

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    await self.handle(result)
                }
            } catch {
                await self.log(error: error)
            }
        }

        // Set before audio starts flowing: `handle(_:)` drops results while this is
        // false, and the analyzer is already consuming the sequence.
        isRunning = true
        do {
            try startCapturing(into: analysisFormat)
        } catch {
            isRunning = false
            throw error
        }
        log.info("Recognizer started")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        inputContinuation?.finish()
        resultsTask?.cancel()
        resultsTask = nil

        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        analyzer = nil
        transcriber = nil

        commandContinuation.finish()
        transcriptContinuation.finish()
        unhandledContinuation.finish()
        log.info("Recognizer stopped")
    }

    func setSpeaking(_ line: String?) {
        spokenLine.set(line)
    }

    // MARK: - Model

    private func makeTranscriber() async throws -> SpeechTranscriber {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.localeUnsupported(locale)
        }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            // All three, and they're a set — each one alone is a bad trade.
            //
            // `.fastResults` biases toward responsiveness at the cost of
            // accuracy; without it a command takes over a second to register,
            // which reads as being ignored. `.alternativeTranscriptions` is what
            // makes that affordable: the transcriber ranks several candidates,
            // and when the fast guess is junk ("escape" for "skip") the word
            // actually said is usually sitting right behind it — see
            // `command(in:)`. `.volatileResults` reports before finalizing.
            //
            // Ran fast-without-alternatives first (fast, misheard everything),
            // then alternatives-without-fast (accurate, sluggish). The speed and
            // the net belong together.
            reportingOptions: [.volatileResults, .fastResults, .alternativeTranscriptions],
            attributeOptions: []
        )

        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            break
        case .unsupported:
            throw Failure.localeUnsupported(supported)
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) else {
                throw Failure.assetsUnavailable
            }
            log.info("Downloading speech model for \(supported.identifier)")
            try await request.downloadAndInstall()
        @unknown default:
            break
        }

        try await AssetInventory.reserve(locale: supported)
        return transcriber
    }

    // MARK: - Capture

    private func startCapturing(into analysisFormat: AVAudioFormat) throws {
        let input = engine.inputNode

        // Hardware echo cancellation: subtracts what the device is playing from
        // what the mic hears. It's why Siri can listen while it talks, and it's
        // what lets the cornerman be interrupted mid-combo instead of the app
        // deafening itself every time it speaks.
        //
        // Must happen before `engine.start()` — the header is explicit that it
        // can only be toggled while the engine is stopped. Failure is survivable:
        // `say(_:)` still mutes for lines that could trigger the app itself, so a
        // phone without voice processing degrades to the old behaviour rather
        // than to a session that obeys its own voice.
        do {
            try input.setVoiceProcessingEnabled(true)
            log.info("Echo cancellation on — the mic can hear you over the cornerman")
        } catch {
            log.warning("No echo cancellation: \(error.localizedDescription, privacy: .public)")
        }

        // Read *after* enabling voice processing: turning it on can change the
        // node's format, and a converter built from the old one would produce
        // garbage.
        let captureFormat = input.outputFormat(forBus: 0)
        guard captureFormat.sampleRate > 0 else { throw Failure.noCompatibleAudioFormat }

        let converter = AVAudioConverter(from: captureFormat, to: analysisFormat)
        let continuation = inputContinuation

        input.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { buffer, _ in
            // Realtime audio thread. No actor hops, no allocation beyond the
            // conversion buffer, no logging.
            //
            // Every buffer goes through, including while the cornerman is talking.
            // Dropping them here is what made him impossible to interrupt: the
            // fighter's voice was thrown away before anything could recognize it.
            // Telling him apart from the speaker is a decision about *words*, so
            // it belongs where the words are — see the echo check in `results`.
            guard let converter,
                  let converted = Self.convert(buffer, using: converter, to: analysisFormat)
            else { return }

            // Deliberately no `bufferStartTime`. The mic's clock starts at an
            // arbitrary host value, and handing the analyzer a stream that begins
            // hours in is a risk with no payoff. The stream is unbroken now, so
            // there are no gaps for a timestamp to describe anyway.
            continuation?.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        try engine.start()
    }

    nonisolated private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var error: NSError?
        var supplied = false
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    // MARK: - Results

    private func handle(_ result: SpeechTranscriber.Result) {
        guard isRunning else { return }

        let text = String(result.text.characters)

        // The cornerman's own voice coming back in through the microphone.
        //
        // Dropped here, ahead of everything — the screen, the twelve commands,
        // the network — because an echo must not read as a person. It reaches
        // this far at all so that everything *else* said while he talks can get
        // through, which is what lets him be interrupted.
        //
        // Logged rather than silently swallowed: how much leaks past hardware
        // echo cancellation is precisely the number that says whether this holds
        // up in a real room, and there's no other way to see it.
        if let line = spokenLine.current, CommandParser.isEcho(text, of: line) {
            log.debug("Echo ignored: \(text, privacy: .public)")
            return
        }

        // Published before any further filtering, so the screen shows what was
        // heard even when it parses to nothing or repeats — that distinction is
        // the whole point of the instrument.
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            transcriptContinuation.yield(text)
        }

        let end = result.range.end
        guard end > consumedThrough else { return }

        guard let command = self.command(in: result) else {
            // Not one of the twelve. It might still be something worth answering
            // — "give me something for the body" — so hand it up rather than
            // dropping it. Gated because each one is a network call and money:
            // finalized only (a half-heard "give me some…" is worth nothing),
            // and at least two words (grunts and stray syllables aren't speech).
            if result.isFinal, isWorthInterpreting(text) {
                consumedThrough = end
                unhandledContinuation.yield(text)
            }
            return
        }

        // Ending the session is the one irreversible command, so it alone waits for
        // a finalized transcript. Everything else is cheap to get wrong and
        // expensive to delay.
        if command == .endSession && !result.isFinal { return }

        consumedThrough = end
        log.debug("Heard \(text, privacy: .public) -> \(command.rawValue, privacy: .public)")
        commandContinuation.yield(command)
    }

    /// Looks for a command in the transcriber's best guess, then in its
    /// runner-ups.
    ///
    /// Speech recognition doesn't produce *an* answer, it produces a ranked list
    /// and we were only ever reading the top of it. In a gym the winner is often
    /// junk while the word actually said sits second: "skip" comes back as
    /// "escape", and "skip" is right there behind it.
    ///
    /// Only consulted when the winner parses to nothing, so a clearly-heard
    /// command is never second-guessed by a lower-ranked one. Capped at a few
    /// candidates: the further down the list, the less it resembles what was
    /// said, and every extra guess is another chance to fire a command nobody
    /// asked for.
    private func command(in result: SpeechTranscriber.Result) -> VoiceCommand? {
        if let command = CommandParser.parse(String(result.text.characters)) {
            return command
        }
        return result.alternatives
            .prefix(3)
            .lazy
            .compactMap { CommandParser.parse(String($0.characters)) }
            .first
    }

    /// Cheap gate before spending a network call on a transcript.
    ///
    /// Two words minimum: "uh", "hah", a grunt between punches, and the mic
    /// catching a single word off a passing conversation are all noise, and the
    /// cornerman has nothing useful to say about them.
    private func isWorthInterpreting(_ text: String) -> Bool {
        CommandParser.normalize(text)
            .split(separator: " ")
            .count >= 2
    }

    private func log(error: Error) {
        log.error("Recognition failed: \(error.localizedDescription, privacy: .public)")
    }
}
