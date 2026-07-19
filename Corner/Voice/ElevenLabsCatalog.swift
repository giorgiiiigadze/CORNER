import Foundation
import os

/// The ElevenLabs voices available to be the cornerman.
nonisolated struct ElevenLabsCatalog: Sendable {

    /// Rachel — a long-standing default. Used until the user picks, and as the
    /// fallback if the voice list can't be loaded.
    static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"

    nonisolated struct Entry: Identifiable, Sendable, Hashable, Decodable {
        let id: String
        let name: String
        /// ElevenLabs' own descriptors — "middle-aged", "american", "confident".
        /// Exactly what you want when casting a cornerman.
        let description: String?
        /// A short sample hosted by ElevenLabs. Free to play — previewing costs
        /// no credits, which matters when auditioning a dozen voices.
        let previewURL: URL?

        enum CodingKeys: String, CodingKey {
            case id = "voice_id"
            case name
            case labels
            case previewURL = "preview_url"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            previewURL = try? container.decodeIfPresent(URL.self, forKey: .previewURL)

            let labels = (try? container.decodeIfPresent([String: String].self, forKey: .labels)) ?? [:]
            // Keep it short and human — this is a subtitle in a list, not a spec.
            let interesting = ["gender", "age", "accent", "description", "use_case"]
            let parts = interesting.compactMap { labels[$0] }
            description = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        init(id: String, name: String, description: String?, previewURL: URL?) {
            self.id = id
            self.name = name
            self.description = description
            self.previewURL = previewURL
        }
    }

    private struct Response: Decodable {
        let voices: [Entry]
    }

    enum Failure: Error, LocalizedError {
        case missingKey
        case missingPermission
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .missingKey:
                "Sign in to choose a cornerman voice."
            case .missingPermission:
                // Worth its own case: the fix is one toggle on the key, and the
                // generic "401" would send you hunting for the wrong thing.
                "This ElevenLabs key can speak but can't list voices. Enable \u{201C}Voices\u{201D} read access on the key."
            case .http(let status):
                "ElevenLabs returned \(status)."
            }
        }
    }

    /// Every voice on the account, for the picker.
    static func load(token: @Sendable () async -> String?) async throws -> [Entry] {
        // No key to be missing any more — what can be missing is a session, and
        // that's what this now means: signed out, so the picker can't be filled.
        guard let session = await token() else { throw Failure.missingKey }

        var request = URLRequest(url: Supabase.functionURL.appending(path: "voices"))
        request.setValue(Supabase.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session)", forHTTPHeaderField: "authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard status == 200 else {
            throw status == 401 ? Failure.missingPermission : Failure.http(status)
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.voices.sorted { $0.name < $1.name }
    }
}
