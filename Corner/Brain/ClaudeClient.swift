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
    let id: String
    let maxTokens: Int
    /// Off for Haiku 4.5 — the model has no adaptive mode, and sending one is a 400.
    let usesAdaptiveThinking: Bool

    /// The default. Measured at ~0.2¢ per session — 8x cheaper than Opus 4.8 and
    /// several seconds faster, with no loss of combo quality on this task.
    /// Writing boxing combinations is not a frontier problem.
    static let haiku = ClaudeModel(
        id: "claude-haiku-4-5",
        // No thinking tokens to leave room for, and a session is ~400 tokens.
        maxTokens: 8_000,
        usesAdaptiveThinking: false
    )

    /// Kept for comparison. Better spoken-form rhythm; ~8x the price.
    static let opus = ClaudeModel(
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
                "No Claude API key. Add ANTHROPIC_API_KEY to Secrets.xcconfig."
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

    private let apiKey: String
    private let model: ClaudeModel
    private let urlSession: URLSession
    private let log = Logger(subsystem: "Giorgi.Corner", category: "claude")

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    init(apiKey: String, model: ClaudeModel = .haiku, urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.urlSession = urlSession
    }

    /// Reads the key that `Secrets.xcconfig` substituted into `Config/Info.plist`.
    ///
    /// This means the key ships inside the binary and can be extracted from the
    /// `.ipa`. That's the accepted M3 trade — it must be replaced by a proxy
    /// before this app is on anyone's phone but yours.
    static func fromBundle(model: ClaudeModel = .haiku) throws -> ClaudeClient {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "ANTHROPIC_API_KEY") as? String,
              key.hasPrefix("sk-ant-")
        else {
            throw Failure.missingAPIKey
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = false
        return ClaudeClient(
            apiKey: key,
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
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": model.maxTokens,
            // Guarantees the reply parses to `schema`, so JSONDecoder is enough.
            "output_config": ["format": ["type": "json_schema", "schema": schema]],
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]

        // Only sent where it's supported — Haiku 4.5 rejects it. Note there is
        // no `temperature` here either: it's a 400 on Opus 4.8, so the prompt is
        // the only steering lever regardless of model.
        if model.usesAdaptiveThinking {
            body["thinking"] = ["type": "adaptive"]
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
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
