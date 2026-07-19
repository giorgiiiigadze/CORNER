import Foundation
import os

/// Talks to the Claude Messages API over raw HTTP.
///
/// There is no official Anthropic SDK for Swift, so this is hand-rolled against
/// `POST /v1/messages` — the sanctioned approach for languages without an SDK.
///
/// The one thing worth understanding here is **structured outputs**: passing a
/// JSON schema in `output_config.format` makes the API *guarantee* the response
/// text parses to that shape. Without it we'd be prompting for JSON and writing
/// defensive parsing for the day the model wraps it in a markdown fence. With
/// it, `JSONDecoder` is enough.
/// A model plus the request shape it accepts.
///
/// These travel together because they are not independent: adaptive thinking is
/// the only thinking mode on Opus 4.8 and is *rejected outright* by Haiku 4.5.
/// Bundling them makes switching models a one-line change instead of a 400 that
/// only shows up at runtime.
nonisolated struct ClaudeModel: Sendable {
    /// What the app calls this model when asking the proxy for it. The id and
    /// the token budget are the server's business.
    let name: String
    let id: String
    let maxTokens: Int
    /// Off for Haiku 4.5 — the model has no adaptive mode, and sending one is a 400.
    let usesAdaptiveThinking: Bool

    /// The default. Measured at ~0.2¢ per session — 8x cheaper than Opus 4.8 and
    /// several seconds faster, with no loss of combo quality on this task.
    /// Writing boxing combinations is not a frontier problem.
    static let haiku = ClaudeModel(
        name: "haiku",
        id: "claude-haiku-4-5",
        // No thinking tokens to leave room for, and a session is ~400 tokens.
        maxTokens: 8_000,
        usesAdaptiveThinking: false
    )

    /// Kept for comparison. Better spoken-form rhythm; ~8x the price.
    static let opus = ClaudeModel(
        name: "opus",
        id: "claude-opus-4-8",
        // Thinking tokens are billed as output and count against this.
        maxTokens: 16_000,
        usesAdaptiveThinking: true
    )
}

nonisolated struct ClaudeClient: Sendable {

    enum Failure: Error, LocalizedError {
        case missingAPIKey
        case http(status: Int, message: String)
        case refused(String?)
        case truncated
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                "Sign in to have the cornerman write you a session."
            case .http(let status, let message):
                "Claude returned \(status): \(message)"
            case .refused(let why):
                "Claude declined the request. \(why ?? "")"
            case .truncated:
                "The response was cut off before it finished."
            case .malformedResponse:
                "Couldn't read Claude's response."
            }
        }
    }

    /// Hands back a live Supabase access token, or nil when there's no session.
    ///
    /// A closure rather than a stored token: this client outlives any single
    /// token — they last about an hour — and asking at the moment of the call is
    /// what lets `AuthController` refresh underneath without anyone here knowing.
    private let token: @Sendable () async -> String?
    private let model: ClaudeModel
    private let urlSession: URLSession
    private let log = Logger(subsystem: "Giorgi.Corner", category: "claude")

    private static var endpoint: URL { Supabase.functionURL.appending(path: "session") }

    init(
        token: @escaping @Sendable () async -> String?,
        model: ClaudeModel = .haiku,
        urlSession: URLSession = .shared
    ) {
        self.token = token
        self.model = model
        self.urlSession = urlSession
    }

    /// Talks to the Edge Function, which holds the Anthropic key.
    ///
    /// The key used to ship inside the binary, read out of `Info.plist` — and an
    /// `.ipa` is a zip, so anyone holding the app held the key and could spend
    /// against it. Now the app carries nothing but the signed-in user's token,
    /// which is worth nothing to anyone else and expires by itself.
    static func viaProxy(
        token: @escaping @Sendable () async -> String?,
        model: ClaudeModel = .haiku
    ) -> ClaudeClient {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = false
        return ClaudeClient(
            token: token,
            model: model,
            urlSession: URLSession(configuration: configuration)
        )
    }

    // MARK: - Requests

    /// Sends one message and decodes the reply against `schema`.
    func complete<T: Decodable>(
        system: String,
        user: String,
        schema: [String: Any],
        returning: T.Type = T.self
    ) async throws -> T {
        // The model is named, not specified. `max_tokens`, the thinking mode and
        // the Anthropic version live on the server, which is the point of having
        // one: a patched app can't ask for a more expensive model or a token
        // budget that turns one tap into a bill.
        let body: [String: Any] = [
            "model": model.name,
            "system": system,
            "user": user,
            "schema": schema,
        ]

        guard let token = await token() else { throw Failure.missingAPIKey }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(Supabase.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = ContinuousClock.now
        let (data, response) = try await urlSession.data(for: request)
        let elapsed = ContinuousClock.now - started

        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard http.statusCode == 200 else {
            throw Failure.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }

        let reply = try decode(data)

        // A refusal arrives as a successful 200 with an empty or partial
        // `content`, so reading content[0] first would crash on the one path
        // that most needs a clear message.
        if reply.stopReason == "refusal" {
            throw Failure.refused(reply.stopDetails?.explanation)
        }
        if reply.stopReason == "max_tokens" {
            throw Failure.truncated
        }

        guard let json = reply.content.first(where: { $0.type == "text" })?.text else {
            throw Failure.malformedResponse
        }

        log.info("""
            Generated in \(elapsed.formatted(), privacy: .public) — \
            in: \(reply.usage?.inputTokens ?? 0), out: \(reply.usage?.outputTokens ?? 0)
            """)

        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            // Structured outputs make this near-impossible; if it fires, the
            // schema and the Swift type have drifted apart.
            log.error("Schema/type mismatch: \(error.localizedDescription, privacy: .public)")
            throw Failure.malformedResponse
        }
    }

    // MARK: - Response

    private struct Reply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct StopDetails: Decodable {
            let explanation: String?
        }
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
        }

        let content: [Block]
        let stopReason: String?
        let stopDetails: StopDetails?
        let usage: Usage?
    }

    private func decode(_ data: Data) throws -> Reply {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Reply.self, from: data)
        } catch {
            throw Failure.malformedResponse
        }
    }

    private static func errorMessage(from data: Data) -> String {
        struct APIError: Decodable {
            struct Inner: Decodable { let message: String }
            let error: Inner
        }
        if let parsed = try? JSONDecoder().decode(APIError.self, from: data) {
            return parsed.error.message
        }
        return String(data: data, encoding: .utf8) ?? "unknown error"
    }
}
