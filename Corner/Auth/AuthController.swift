import Foundation
import Network
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

    /// The name from `public.profiles`, when there is one.
    ///
    /// Nil covers three different situations and the UI treats them the same,
    /// which is right: nobody has set a name, the profiles table hasn't been
    /// created yet, or the fetch hasn't come back. In all three the address is
    /// what there is to show, and the avatar falls back to initials from it.
    ///
    /// Deliberately not blocking anything. It's fetched after the session is
    /// already good, so a profiles table that doesn't exist — or a network that
    /// doesn't answer — costs a log line and nothing else.
    private(set) var displayName: String?

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

    /// Watches for the network coming back, and is only running while we're
    /// signed in on a token we haven't been able to verify. See `restore`.
    private var reconnectMonitor: NWPathMonitor?

    /// Where the last-known identity is kept, so a launch with no signal can put
    /// the app up instead of the sign-in screen.
    ///
    /// Not the Keychain — the *token* lives there because it's a credential;
    /// these are just a user id and an address, and they need to be readable on
    /// the offline path to key the local queries and label the screen. The token
    /// stays the thing that proves who you are; this only remembers who that was.
    private enum Cached {
        static let userID = "auth.cached.userID"
        static let email = "auth.cached.email"
    }

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
            // Detached, and after the state is already `signedIn`: the profile
            // is decoration on a session that's good either way, and awaiting it
            // here would hold the splash up for a name.
            Task { await loadProfile() }
        } catch is Failure {
            // The *server* rejected the refresh token — this is the only failure
            // that means signed-out. A refresh token expires, and it's revoked
            // when the account is deleted or the password changed elsewhere;
            // when that happens Supabase answers with a 4xx, which is the only
            // thing that reaches this branch. Clearing here is correct.
            log.info("Stored session rejected — signing out")
            TokenStore.clear()
            clearCachedIdentity()
            state = .signedOut
        } catch {
            // We could not *reach* the server — no signal, airplane mode, a dead
            // café wifi. The token is almost certainly fine; the one thing we
            // must not do is throw it away, which is exactly the bug this fixes:
            // an offline launch used to clear the token and drop to sign-in, and
            // once it was cleared, getting signal back had nothing left to
            // restore.
            //
            // So: keep the token, put the app up on the last-known identity, and
            // watch for the network to come back to verify it. Signed-in offline
            // works — history is local, and everything that needs the network
            // already falls back on its own.
            if let cachedID = UserDefaults.standard.string(forKey: Cached.userID) {
                log.info("Offline at launch — restoring the last session and waiting for signal")
                userID = cachedID
                email = UserDefaults.standard.string(forKey: Cached.email)
                state = .signedIn
                waitForReconnect()
            } else {
                // Never got far enough to cache an identity. Nothing to show but
                // sign-in — but the token is still there, so signing in will
                // work the moment there's signal.
                log.info("Offline at launch with no cached identity — sign-in until signal")
                state = .signedOut
            }
        }
    }

    /// Re-verifies the session the moment the network returns.
    ///
    /// Started only from the offline branch of `restore`, and torn down as soon
    /// as it does its job — a monitor that outlived its reason to exist would be
    /// a refresh firing on every wifi flicker for the rest of the app's life.
    private func waitForReconnect() {
        guard reconnectMonitor == nil else { return }

        let monitor = NWPathMonitor()
        reconnectMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.reconcile() }
        }
        monitor.start(queue: DispatchQueue(label: "Giorgi.Corner.auth.reconnect"))
    }

    private func stopWaiting() {
        reconnectMonitor?.cancel()
        reconnectMonitor = nil
    }

    /// One attempt to turn an unverified offline session into a verified one.
    ///
    /// Three outcomes, and each ends the wait or keeps it: the refresh succeeds
    /// and we're fully signed in; the server rejects the token and we sign out
    /// for real (the account was deleted or the password changed while we were
    /// offline); or we still can't reach it, in which case we leave the monitor
    /// running for the next time signal returns.
    private func reconcile() async {
        // Nothing to do if a live token already arrived by another path.
        guard accessToken == nil, let refresh = TokenStore.read() else {
            stopWaiting()
            return
        }

        do {
            try await send(path: "token?grant_type=refresh_token", body: ["refresh_token": refresh])
            log.info("Signal returned — session verified")
            stopWaiting()
            Task { await loadProfile() }
        } catch is Failure {
            log.info("Signal returned — stored session was rejected, signing out")
            TokenStore.clear()
            clearCachedIdentity()
            stopWaiting()
            state = .signedOut
        } catch {
            // Still unreachable. Keep waiting.
        }
    }

    private func clearCachedIdentity() {
        UserDefaults.standard.removeObject(forKey: Cached.userID)
        UserDefaults.standard.removeObject(forKey: Cached.email)
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

        // Discarded deliberately, and `accessToken` is read below instead: a
        // refresh that fails leaves it nil, and returning nil is exactly right —
        // the caller falls back to the offline path rather than sending a token
        // it knows is dead. `@discardableResult` doesn't cover the `Optional`
        // that `try?` wraps around it, hence the explicit `_`.
        _ = try? await send(path: "token?grant_type=refresh_token", body: ["refresh_token": refresh])
        return accessToken
    }

    func signIn(email: String, password: String) async {
        await attempt(path: "token?grant_type=password", email: email, password: password)
    }

    func signUp(email: String, password: String) async {
        await attempt(path: "signup", email: email, password: password)
    }

    func signOut() {
        // A deliberate sign-out ends the offline-verify wait too — there's no
        // session left to verify.
        stopWaiting()
        TokenStore.clear()
        clearCachedIdentity()
        accessToken = nil
        expiry = nil
        problem = nil
        notice = nil
        email = nil
        userID = nil
        // Cleared with the rest of the identity. Left behind, the next person to
        // sign in on this phone would be greeted by the last one's name until
        // their own profile came back.
        displayName = nil
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
            // Answered by *this* response, not by reading `accessToken` back
            // afterwards. That field survives across calls, so a stale token
            // from an earlier sign-in could make a sign-up that's still waiting
            // on an email confirmation look like a completed one — and drop the
            // fighter into an app whose every request 401s.
            let started = try await send(path: path, body: ["email": email, "password": password])

            // Signing up with email confirmation on returns a user but no
            // session — the account exists and is waiting on a click in an
            // inbox.
            if started {
                state = .signedIn
                Task { await loadProfile() }
            } else {
                notice = "Check your email to confirm the account, then sign in."
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
    ///
    /// Returns whether *this* response carried a session. Callers must not infer
    /// it from `accessToken` afterwards: that field outlives a single call.
    @discardableResult
    private func send(path: String, body: [String: String]) async throws -> Bool {
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

        guard let token = session.access_token, let refresh = session.refresh_token else {
            accessToken = nil
            expiry = nil
            return false
        }

        accessToken = token
        expiry = Date(timeIntervalSinceNow: TimeInterval(session.expires_in ?? 3_600))
        TokenStore.save(refresh)

        // The moment we're provably signed in, so the *next* launch can put the
        // app up on this identity even with no signal. Written here rather than
        // at the call sites because every path that reaches it — sign-in,
        // sign-up, refresh, restore — is one where the token is now good.
        UserDefaults.standard.set(userID, forKey: Cached.userID)
        UserDefaults.standard.set(email, forKey: Cached.email)
        return true
    }

    /// Reads the row `public.profiles` holds for this account.
    ///
    /// Best-effort by construction. Every failure here — no table, no row, no
    /// signal, RLS saying no — lands in the same place: `displayName` stays nil
    /// and the app shows the address, which is what it showed before profiles
    /// existed. That's why nothing awaits this and why it never sets `problem`:
    /// a name is a nicety, and a fighter who can't train because a nicety
    /// didn't load is a worse outcome than a fighter with no name on screen.
    func loadProfile() async {
        guard let userID, let token = await token() else { return }

        var components = URLComponents(
            url: Supabase.url.appending(path: "rest/v1/profiles"),
            resolvingAgainstBaseURL: false
        )
        // `id=eq.<uid>` is PostgREST's filter syntax, and the RLS policy would
        // narrow it to this row anyway — sending it explicitly means the server
        // never assembles a result set we'd only throw away.
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(userID)"),
            URLQueryItem(name: "select", value: "display_name"),
        ]

        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.setValue(Supabase.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        // One row or none, returned as an object rather than an array — saves
        // unwrapping a single-element list on every read.
        request.setValue("application/vnd.pgrst.object+json", forHTTPHeaderField: "accept")

        struct Profile: Decodable { let display_name: String? }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            guard (200..<300).contains(status) else {
                // 404 here means the table hasn't been created yet — see
                // `supabase/migrations/0002_profiles.sql`, which has to be run
                // by hand. Logged rather than surfaced: the app works without it.
                log.info("No profile (\(status)) — falling back to the address")
                return
            }

            let profile = try JSONDecoder().decode(Profile.self, from: data)
            let trimmed = profile.display_name?.trimmingCharacters(in: .whitespacesAndNewlines)
            // Empty is nil. A name someone cleared to blank is a name they
            // haven't set, and the column being nullable is the whole reason
            // `0002` distinguishes those — don't reintroduce "" downstream.
            displayName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        } catch {
            log.info("Profile fetch failed: \(error.localizedDescription, privacy: .public)")
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
