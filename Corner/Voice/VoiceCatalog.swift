import AVFoundation

/// The voices actually installed on this phone.
///
/// The important thing this file encodes: iOS ships only the **compact** voice
/// by default, and compact is what makes text-to-speech sound like a robot.
/// Enhanced and Premium sound like a person — but Apple downloads them on the
/// user's request only, and there is no API to trigger it. An app can detect
/// their absence and say so; it cannot fix it silently.
nonisolated enum VoiceCatalog {

    /// Where the chosen voice is stored. `Cornerman` reads this at init.
    static let preferenceKey = "cornerVoiceIdentifier"

    nonisolated struct Entry: Identifiable, Sendable, Hashable {
        let id: String          // AVSpeechSynthesisVoice.identifier
        let name: String
        let quality: Tier

        enum Tier: Int, Sendable, Comparable, CaseIterable {
            case compact = 0, enhanced = 1, premium = 2

            var label: String {
                switch self {
                case .compact: "Compact"
                case .enhanced: "Enhanced"
                case .premium: "Premium"
                }
            }

            /// Only worth saying something about the ones that aren't good.
            var note: String? {
                switch self {
                case .compact: "Robotic — the default iOS voice"
                case .enhanced: nil
                case .premium: nil
                }
            }

            static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
        }
    }

    /// Installed voices for the user's language, best first.
    static func installed() -> [Entry] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        // Match on the language, not the full tag, so an en-GB phone still sees
        // en-US voices rather than an empty list.
        let prefix = String(language.prefix(2))

        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .map { voice in
                let tier: Entry.Tier = switch voice.quality {
                case .premium: .premium
                case .enhanced: .enhanced
                default: .compact
                }
                return Entry(id: voice.identifier, name: voice.name, quality: tier)
            }
            .sorted {
                $0.quality != $1.quality ? $0.quality > $1.quality : $0.name < $1.name
            }
    }

    /// True when the phone has nothing but robots installed — the case worth
    /// telling the user about, since only they can fix it.
    static var needsBetterVoiceDownload: Bool {
        !installed().contains { $0.quality > .compact }
    }

    /// The stored choice, the best installed voice, or the system default.
    static func resolve(_ identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier, let chosen = AVSpeechSynthesisVoice(identifier: identifier) {
            return chosen
        }
        if let best = installed().first, let voice = AVSpeechSynthesisVoice(identifier: best.id) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    /// A real callout, not "the quick brown fox". You're choosing a voice to
    /// shout combinations at you, so it should audition doing that.
    static let previewLine = "One, two, slip, hook. Hands up — thirty seconds."
}
