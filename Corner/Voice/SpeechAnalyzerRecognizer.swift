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

    /// Read from the realtime audio thread, so it cannot live in actor state.
    private final class MuteFlag: Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        var isMuted: Bool { lock.withLock { $0 } }
        func set(_ value: Bool) { lock.withLock { $0 = value } }
    }

    private let locale: Locale
    private let engine = AVAudioEngine()
    private let muteFlag = MuteFlag()
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

    var commands: AsyncStream<VoiceCommand> { commandStream }
    var transcripts: AsyncStream<String> { transcriptStream }

    init(locale: Locale = Locale.current) {
        self.locale = locale
        (commandStream, commandContinuation) = AsyncStream.makeStream(of: VoiceCommand.self)
        (transcriptStream, transcriptContinuation) = AsyncStream.makeStream(of: String.self)
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
        log.info("Recognizer stopped")
    }

    func setMuted(_ muted: Bool) {
        muteFlag.set(muted)
    }

    // MARK: - Model

    private func makeTranscriber() async throws -> SpeechTranscriber {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.localeUnsupported(locale)
        }

        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            // `.fastResults` is the obvious tuning knob if commands feel laggy in a
            // gym; it trades accuracy for latency, and a false `.endSession` costs
            // more than a slow one, so it stays off until measured.
            reportingOptions: [.volatileResults],
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
        let captureFormat = input.outputFormat(forBus: 0)

        guard captureFormat.sampleRate > 0 else { throw Failure.noCompatibleAudioFormat }

        let converter = AVAudioConverter(from: captureFormat, to: analysisFormat)
        let continuation = inputContinuation
        let muteFlag = self.muteFlag

        input.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { buffer, _ in
            // Realtime audio thread. No actor hops, no allocation beyond the
            // conversion buffer, no logging.
            guard !muteFlag.isMuted else { return }
            guard let converter,
                  let converted = Self.convert(buffer, using: converter, to: analysisFormat)
            else { return }

            // Deliberately no `bufferStartTime`. Muting drops buffers, so the stream
            // does contain gaps, and the timestamped initializer exists for exactly
            // that — but the mic's clock starts at an arbitrary host value, and
            // handing the analyzer a stream that begins hours in is a risk with no
            // payoff here. Treating the audio as contiguous only means words either
            // side of a gap may merge, which no command phrase depends on.
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

        // Published before any filtering, so the screen shows what was heard even
        // when it parses to nothing or repeats — that distinction is the whole
        // point of the instrument.
        if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            transcriptContinuation.yield(text)
        }

        let end = result.range.end
        guard end > consumedThrough else { return }
        guard let command = CommandParser.parse(text) else { return }

        // Ending the session is the one irreversible command, so it alone waits for
        // a finalized transcript. Everything else is cheap to get wrong and
        // expensive to delay.
        if command == .endSession && !result.isFinal { return }

        consumedThrough = end
        log.debug("Heard \(text, privacy: .public) -> \(command.rawValue, privacy: .public)")
        commandContinuation.yield(command)
    }

    private func log(error: Error) {
        log.error("Recognition failed: \(error.localizedDescription, privacy: .public)")
    }
}
