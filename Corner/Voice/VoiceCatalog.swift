import AVFoundation

/// The iOS voices installed on this phone.
///
/// Emergency plumbing only. The cornerman is an ElevenLabs voice; this is what
/// speaks when the network dies mid-round, because a robot calling "one, two"
/// beats a silent round in a garage with no signal.
///
/// Nothing here is user-facing any more — Settings offers only real voices —
/// so this picks the best available on its own.
nonisolated enum VoiceCatalog {

    /// Kept so an existing stored choice is still honoured, but nothing writes
    /// it any more.
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
            .filter { !isNovelty($0) }
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

    /// iOS ships a set of joke voices — Albert, Bad News, Bahh, Bells, Boing,
    /// Bubbles — alongside the real ones. They're indistinguishable by quality
    /// (all report `.default`), so they have to be excluded by identifier.
    /// A cornerman that sounds like "Boing" is worse than no fallback at all.
    private static func isNovelty(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.identifier.contains("speech.synthesis.voice")
            || voice.identifier.contains("eloquence")
    }

    /// True when the phone has nothing but robots installed.
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
