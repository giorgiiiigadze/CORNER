import AVFoundation
import os

/// Owns the `AVAudioSession`. The hardest twenty lines in the app.
///
/// `.playAndRecord` lets the cornerman talk while the mic stays open. `.duckOthers`
/// drops the user's music under callouts instead of stopping it. `.defaultToSpeaker`
/// matters because without it the route falls back to the receiver and nobody hears
/// a thing from across a garage.
@MainActor
final class AudioSessionController {

    private let log = Logger(subsystem: "Giorgi.Corner", category: "audio")
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    /// Fires when the system tore the session down mid-workout — a phone call,
    /// typically. The session engine uses this to pause rather than to silently die.
    var onInterruptionBegan: (() -> Void)?
    /// Fires when the system says we may resume.
    var onInterruptionEnded: (() -> Void)?

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetoothA2DP, .allowAirPlay]
        )
        try session.setActive(true, options: [])
        observeInterruptions()
        log.info("Audio session active — route: \(session.currentRoute.outputs.first?.portName ?? "none", privacy: .public)")
    }

    func deactivate() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        interruptionObserver = nil
        routeChangeObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Permission for the microphone. Speech recognition permission is requested
    /// separately by `requestSpeechAuthorization`.
    func requestMicrophoneAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }

            // Read off the notification here, not inside the closure below.
            // `Notification` isn't `Sendable`, so it can't cross into a
            // main-actor context — but the option set lifted out of it is a
            // `UInt` in a wrapper, and can. Same reason `type` is read up here.
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []

            MainActor.assumeIsolated {
                switch type {
                case .began:
                    self.log.info("Audio interrupted")
                    self.onInterruptionBegan?()
                case .ended:
                    if options.contains(.shouldResume) {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.onInterruptionEnded?()
                    }
                @unknown default:
                    break
                }
            }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let route = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "none"
                self.log.info("Route changed — now: \(route, privacy: .public)")
            }
        }
    }
}
