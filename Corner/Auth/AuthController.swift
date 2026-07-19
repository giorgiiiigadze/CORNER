import Foundation
import os

/// Who the backend thinks we are, and the token that proves it.
///
/// Hand-rolled against Supabase's REST endpoints rather than pulling in their
/// SDK. This project has no third-party dependencies — Claude and ElevenLabs are
/// both plain `URLSession` — and the whole of what's needed here is three POSTs.
/// A package would be more code in the build than out of it.
///
/// Email and password, which is not the end state: Sign in with Apple is the
/// right flow for an iOS app and needs a paid developer account. What this does
/// buy, and anonymous auth didn't, is an account that outlives the install — so
/// a subscription attached to it survives a reinstall, a new phone, and a
/// restore. That's the property the paywall will depend on.
@MainActor
@Observable
final class AuthController {

    enum State: Equatable {
        /// Before the stored token has been checked. Distinct from `signedOut`
        /// so the first frame isn't a sign-in screen flashed at someone who is
        /// already signed in.
        case restoring
        case signedOut
        case signedIn
    }

    private(set) var state: State = .restoring

    /// The signed-in address, for Settings to show. Read off whichever response
    /// last carried a session — sign-in, sign-up and refresh all include the
    /// user, so it survives a relaunch without a separate call to fetch it.
    private(set) var email: String?

    /// The Supabase user id. What every stored session is keyed to, so a second
    /// person signing in on this phone sees their own history rather than the
    /// last person's.
    private(set) var userID: String?
    private(set) var problem: String?
    private(set) var notice: String?
    private(set) var isWorking = false

    /// Bearer token for the Edge Function. Short-lived by design — an hour,
    /// typically — and refreshed from the Keychain token when it lapses.
    private var accessToken: String?
    private var expiry: Date?

    private let log = Logger(subsystem: "Giorgi.Corner", category: "auth")

    // MARK: - Session

    /// Called once at launch. Silent when there's nothing stored — a first run
    /// should land on the sign-in screen, not on an error about not being
    /// signed in.
    func restore() async {
        guard let refresh = TokenStore.read() else {
            state = .signedOut
            return
        }

        do {
            try await send(path: "token?grant_type=refresh_token", body: ["refresh_token": refresh])
            state = .signedIn
        } catch {
            // A refresh token that no longer works is a signed-out user, not a
            // failure to report: it expires, and it's revoked when the account
            // is deleted or the password changed elsewhere.
            log.info("Stored session no longer valid — signing out")
            TokenStore.clear()
            state = .signedOut
        }
    }

    /// A live access token, refreshed if it's about to lapse.
    ///
    /// The sixty-second margin is for the session engine: a token that passes
    /// this check and expires mid-flight fails the request, and during a workout
    /// that's a round opening in silence.
    func token() async -> String? {
        if let accessToken, let expiry, expiry.timeIntervalSinceNow > 60 {
            return accessToken
        }

        guard let refresh = TokenStore.read() else { return nil }
        try? await send(path: "token?grant_type=refresh_token", body: ["refresh_token": refresh])
        return accessToken
    }

    func signIn(email: String, password: String) async {
        await attempt(path: "token?grant_type=password", email: email, password: password)
    }

    func signUp(email: String, password: String) async {
        await attempt(path: "signup", email: email, password: password)
    }

    func signOut() {
        TokenStore.clear()
        accessToken = nil
        expiry = nil
        problem = nil
        notice = nil
        email = nil
        userID = nil
        state = .signedOut
    }

    // MARK: - Supabase

    private func attempt(path: String, email: String, password: String) async {
        problem = nil
        notice = nil

        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@"), !password.isEmpty else {
            problem = "Enter an email and a password."
            return
        }
        guard password.count >= 6 else {
            // Said here rather than let the server say it: a round-trip to be
            // told the password is short is a round-trip we already knew the
            // answer to.
            problem = "Password must be at least 6 characters."
            return
        }

        isWorking = true
        defer { isWorking = false }

        do {
            try await send(path: path, body: ["email": email, "password": password])

            // Signing up with email confirmation on returns a user but no
            // session — the account exists and is waiting on a click in an
            // inbox. Treating that as success would drop them into an app that
            // 401s on every request.
            if accessToken == nil {
                notice = "Check your email to confirm the account, then sign in."
            } else {
                state = .signedIn
            }
        } catch let failure as Failure {
            problem = failure.message
        } catch {
            problem = "Couldn't reach the server. Check your connection."
        }
    }

    private struct Failure: Error {
        let message: String
    }

    /// Every auth endpoint answers with the same session shape, so they share
    /// this. `access_token` is optional because the sign-up-pending-confirmation
    /// case legitimately has none.
    private func send(path: String, body: [String: String]) async throws {
        guard let url = URL(string: Supabase.authURL.absoluteString + "/" + path) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Supabase.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard (200..<300).contains(status) else {
            log.error("Auth \(path) failed (\(status)): \(String(data: data.prefix(300), encoding: .utf8) ?? "", privacy: .public)")
            throw Failure(message: Self.readable(data, status: status))
        }

        let session = try JSONDecoder().decode(Session.self, from: data)
        email = session.user?.email ?? email
        userID = session.user?.id ?? userID

        if let token = session.access_token, let refresh = session.refresh_token {
            accessToken = token
            expiry = Date(timeIntervalSinceNow: TimeInterval(session.expires_in ?? 3_600))
            TokenStore.save(refresh)
        } else {
            accessToken = nil
            expiry = nil
        }
    }

    /// Supabase's own wording where it has any, because it's better than
    /// anything generic: "Invalid login credentials" and "User already
    /// registered" are exactly what the person needs to read.
    private static func readable(_ data: Data, status: Int) -> String {
        struct APIError: Decodable {
            let msg: String?
            let error_description: String?
            let message: String?
        }

        let decoded = try? JSONDecoder().decode(APIError.self, from: data)
        if let message = decoded?.msg ?? decoded?.error_description ?? decoded?.message, !message.isEmpty {
            return message
        }
        return "Sign in failed (\(status))."
    }

    private struct Session: Decodable {
        let access_token: String?
        let refresh_token: String?
        let expires_in: Int?
        let user: User?

        struct User: Decodable {
            let id: String?
            let email: String?
        }
    }
}
