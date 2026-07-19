import Foundation

/// Where the backend lives, and the one key that's safe to ship.
///
/// The publishable key is *meant* to be in the binary — it identifies the
/// project, not the caller, and grants nothing on its own. That's the whole
/// difference between it and the Anthropic and ElevenLabs keys this exists to
/// get out of the app: those spend money, this one only says which project to
/// knock on. Anything that can actually be billed sits behind the Edge Function.
nonisolated enum Supabase {
    static let url = URL(string: "https://oszjkndzaoukburbdiad.supabase.co")!
    static let publishableKey = "sb_publishable_ECT9tgHHpuUrx8VfTjIzYw_YSAfjfhJ"

    static var authURL: URL { url.appending(path: "auth/v1") }

    /// The proxy. `ClaudeClient` and `ElevenLabsVoice` reach the vendors through
    /// here rather than holding keys of their own.
    static var functionURL: URL { url.appending(path: "functions/v1/corner") }
}
