import AVFoundation

/// Picks the on-device voice.
///
/// Emergency plumbing only. The cornerman is an ElevenLabs voice; this is what
/// speaks when the network dies mid-session, because a robot saying "Round three.
/// Body work" beats a bell out of nowhere in a garage with no signal.
///
/// Nothing here is user-facing. This used to back a picker — installed voices
/// listed by quality tier, with a preview line — and that's what the ElevenLabs
/// picker in Settings replaced. What's left is the one question worth asking:
/// which installed voice is the least bad.
nonisolated enum VoiceCatalog {

    /// The best installed voice for the user's language, or the system default.
    static func best() -> AVSpeechSynthesisVoice? {
        // Match on the language, not the full tag, so an en-GB phone still sees
        // en-US voices rather than an empty list.
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))

        let best = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .filter { !isNovelty($0) }
            .max { rank($0) < rank($1) }

        return best ?? AVSpeechSynthesisVoice(language: language)
    }

    private static func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: 2
        case .enhanced: 1
        default: 0
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
}
