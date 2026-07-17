import AVFoundation
import os

/// The bell.
///
/// It's now the primary signal in the app: the cornerman says what today is for
/// and then goes quiet, so this is what tells the fighter a round started, a
/// round ended, and rest is over. It has to carry across a room over music.
///
/// Synthesized rather than bundled. A struck bell is a handful of partials under
/// an exponential decay, which is a few dozen lines here — against an audio file
/// that needs licensing, sits in the repo forever, and can't be retuned without
/// finding another one. Rendered once at startup and replayed from memory, so
/// ringing it costs nothing.
///
/// Deliberately not a `Voice`. The bell is not speech: it must never be routed
/// through `say`, never handed to the recognizer's echo filter, and never
/// cancelled by a barge-in. Its own player keeps all three from being possible.
@MainActor
final class Bell: Ringer {

    /// Rendered once for the life of the process. It's the same bell every time,
    /// and eighty thousand samples is not worth recomputing per session.
    private static let samples: Data = render()

    private var player: AVAudioPlayer?
    private let log = Logger(subsystem: "Giorgi.Corner", category: "bell")

    /// Fire and forget. The round doesn't wait for the bell to stop ringing, the
    /// same way a fighter doesn't.
    func ring() {
        do {
            // Rebuilt per ring: an `AVAudioPlayer` that's still ringing can't be
            // restarted cleanly, and rounds can end faster than the tail decays
            // when someone says "next round" twice.
            let player = try AVAudioPlayer(data: Self.samples)
            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            self.player = player
        } catch {
            // A missing bell is a session with no signal in it, but it isn't a
            // reason to stop the workout.
            log.error("Bell failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Synthesis

    private static let sampleRate = 44_100.0
    private static let duration = 1.8

    /// A bell's partials aren't a harmonic series — that's what makes it read as
    /// struck metal rather than an organ. These ratios are the classic
    /// inharmonic set, and the high ones decay fastest, which is the "ting"
    /// giving way to the hum.
    private static let partials: [(ratio: Double, amplitude: Double, decay: Double)] = [
        (1.00, 1.00, 1.6),
        (2.00, 0.60, 2.4),
        (2.76, 0.40, 3.4),
        (5.40, 0.25, 5.0),
        (8.93, 0.10, 7.0),
    ]

    /// Bright enough to cut through a gym, low enough not to be shrill on a phone
    /// speaker.
    private static let fundamental = 620.0

    static func render() -> Data {
        let frames = Int(sampleRate * duration)
        var pcm = [Int16]()
        pcm.reserveCapacity(frames)

        for frame in 0..<frames {
            let t = Double(frame) / sampleRate
            var value = 0.0
            for partial in partials {
                let envelope = exp(-partial.decay * t)
                value += partial.amplitude * envelope * sin(2 * .pi * fundamental * partial.ratio * t)
            }

            // The strike itself. Without a moment of noise at the front it sounds
            // like a tone that faded in rather than something that was hit.
            if t < 0.006 {
                value += Double.random(in: -0.4...0.4) * (1 - t / 0.006)
            }

            // Normalized against the partial amplitudes rather than clipped, so a
            // retune can't silently start distorting.
            let total = partials.reduce(0) { $0 + $1.amplitude } + 0.4
            let scaled = (value / total) * 0.9
            pcm.append(Int16(max(-1, min(1, scaled)) * Double(Int16.max)))
        }

        return wav(pcm)
    }

    /// Wraps samples in a WAV container: 16-bit mono PCM, which `AVAudioPlayer`
    /// reads from memory without touching the filesystem.
    private static func wav(_ samples: [Int16]) -> Data {
        let bitsPerSample = 16
        let channels = 1
        let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = samples.count * bitsPerSample / 8

        var data = Data()
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(36 + dataBytes)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)             // PCM header length
        u16(1)              // PCM, uncompressed
        u16(channels)
        u32(Int(sampleRate))
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        ascii("data")
        u32(dataBytes)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
