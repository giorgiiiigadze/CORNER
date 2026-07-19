import Foundation
import SwiftData
import os

/// Keeps a fighter's history with their account rather than their phone.
///
/// Two directions, both dumb on purpose:
///
/// - **Push** uploads anything the server hasn't got. Sessions are immutable —
///   a finished workout never changes — so an upsert on `remoteID` is the whole
///   conflict story. Two phones can't disagree about a session that neither can
///   edit.
/// - **Pull** inserts anything the device hasn't got. Same id, same rule.
///
/// What it deliberately doesn't do is delete. A session missing locally means
/// "this phone hasn't seen it", not "the user removed it" — and treating the
/// two the same is how a sync wipes a year of training the first time someone
/// installs on a second device. Deletion crossing devices needs tombstones, and
/// that's a bigger feature than this.
///
/// Failure is silent by design. This runs behind a screen showing numbers that
/// are already correct locally; an alert saying the cloud is unreachable
/// interrupts a workout to report something the fighter cannot act on and does
/// not need to know.
@MainActor
struct SessionSync {

    let auth: AuthController
    let context: ModelContext

    private var log: Logger { Logger(subsystem: "Giorgi.Corner", category: "sync") }

    private var endpoint: URL {
        Supabase.url.appending(path: "rest/v1/sessions")
    }

    /// Pull first, then push.
    ///
    /// That order matters on a fresh install: pulling first means the device
    /// learns the ids the server already holds, so the push that follows has
    /// nothing to send for those. The other way round, a device that had
    /// claimed legacy records would re-upload rows it was about to receive.
    func run() async {
        // One at a time, but never *instead of*. Startup and "session just
        // finished" both call this and they overlap — and the first version
        // simply returned when a run was already going, which threw the second
        // call away. That's how a session trained during the launch sync sat
        // unsent until the next cold start: the only call that would have
        // uploaded it was the one that got dropped.
        //
        // Now an overlapping call asks for another pass instead, and the run in
        // flight does it before finishing. Still one at a time, still no double
        // write, and nothing is lost.
        guard !Self.isRunning else {
            Self.wantsAnotherPass = true
            log.info("Sync already running — queued another pass")
            return
        }

        Self.isRunning = true
        defer { Self.isRunning = false }

        repeat {
            Self.wantsAnotherPass = false

            guard let token = await auth.token() else {
                log.error("Sync skipped: no access token")
                return
            }
            guard let userID = auth.userID else {
                log.error("Sync skipped: no user id")
                return
            }

            await pull(token: token, userID: userID)
            await push(token: token, userID: userID)
        } while Self.wantsAnotherPass
    }

    /// Static because `SessionSync` is a struct built fresh at each call site —
    /// an instance flag would guard nothing.
    ///
    /// Safe as shared mutable state only because the type is `@MainActor`: every
    /// read and write happens on the main actor, and the `await`s above suspend
    /// rather than hand it to another thread.
    @MainActor private static var isRunning = false
    @MainActor private static var wantsAnotherPass = false

    // MARK: - Down

    private func pull(token: String, userID: String) async {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "select", value: "*")]

        var request = URLRequest(url: components.url!)
        request.setValue(Supabase.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                log.error("Pull failed: \(String(data: data.prefix(200), encoding: .utf8) ?? "", privacy: .public)")
                return
            }

            let rows = try Self.decoder.decode([Row].self, from: data)

            // Every id on the device, not just this user's. Scoped to the
            // signed-in user, a row already stored under another owner reads as
            // unknown and gets inserted a second time — `remoteID` names a
            // session globally, so the check has to be global too.
            let known = Set(allLocalIDs())

            var inserted = 0
            for row in rows where !known.contains(row.id) {
                context.insert(row.record(userID: userID))
                inserted += 1
            }

            try? context.save()
            // Counted, not inferred. `rows.count - known.count` subtracted a
            // local total from a remote one and printed nonsense — usually
            // negative — which made the one diagnostic for "sync ran and stored
            // nothing" useless.
            log.info("Pulled \(rows.count) sessions, \(inserted) new")
        } catch {
            log.error("Pull failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Up

    private func push(token: String, userID: String) async {
        let mine = localRecords()
        let pending = mine.filter { !$0.isSynced }

        guard !pending.isEmpty else {
            // Said out loud, because "nothing to send" and "never ran" look
            // identical in a log that stays quiet — and they point at completely
            // different bugs. The owned count comes too: zero there means the
            // records exist under a different user id than the one signing in,
            // which is a fault worth seeing rather than reading as "all synced".
            log.info("Nothing to push — \(mine.count) session(s) owned, all synced")
            return
        }

        let rows = pending.map { Row(record: $0, userID: userID) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(Supabase.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Upsert. A retry after a half-failed upload must not create a second
        // copy of a session the server already has.
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "prefer")

        do {
            request.httpBody = try Self.encoder.encode(rows)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            guard (200..<300).contains(status) else {
                log.error("Push failed (\(status)): \(String(data: data.prefix(200), encoding: .utf8) ?? "", privacy: .public)")
                return
            }

            // Marked only after the server confirms. A flag set optimistically
            // is a session that silently never reaches the account.
            for record in pending { record.isSynced = true }
            try? context.save()
            log.info("Pushed \(pending.count) sessions")
        } catch {
            log.error("Push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Local

    /// This user's records — what gets uploaded.
    private func localRecords() -> [TrainingRecord] {
        let userID = auth.userID ?? ""
        let descriptor = FetchDescriptor<TrainingRecord>(
            predicate: #Predicate { $0.userID == userID }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Every id on the device, whoever owns it — what the pull checks against.
    ///
    /// Unfiltered on purpose. These ids are unique across accounts and devices,
    /// so "do we already have this session" is a question about the store, not
    /// about the signed-in user.
    private func allLocalIDs() -> [UUID] {
        let descriptor = FetchDescriptor<TrainingRecord>()
        return ((try? context.fetch(descriptor)) ?? []).map(\.remoteID)
    }

    // MARK: - Wire format

    /// One row, in the server's spelling. Kept apart from `TrainingRecord` so a
    /// column rename is a change here and not in the model the whole app reads.
    private struct Row: Codable {
        let id: UUID
        let user_id: String
        let performed_at: Date
        let title: String
        let focuses: [String]
        let rounds_planned: Int
        let rounds_completed: Int
        let ended_early: Bool
        let session_seconds: Int?
        let pause_count: Int?

        init(record: TrainingRecord, userID: String) {
            id = record.remoteID
            user_id = userID
            performed_at = record.date
            title = record.title
            focuses = record.focuses
            rounds_planned = record.roundsPlanned
            rounds_completed = record.roundsCompleted
            ended_early = record.endedEarly
            session_seconds = record.sessionSeconds
            pause_count = record.pauseCount
        }

        /// Arrives already synced, by definition — it came from the server.
        func record(userID: String) -> TrainingRecord {
            let record = TrainingRecord(
                remoteID: id,
                userID: userID,
                date: performed_at,
                title: title,
                focuses: focuses,
                roundsPlanned: rounds_planned,
                roundsCompleted: rounds_completed,
                endedEarly: ended_early,
                sessionSeconds: session_seconds,
                pauseCount: pause_count
            )
            record.isSynced = true
            return record
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Postgres returns microseconds — `2026-07-19T14:26:23.463394+00:00` — and
    /// the stock `.iso8601` strategy rejects any fractional part. Both formats
    /// are tried rather than assuming, because a date that fails to parse loses
    /// the session it belongs to.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { source in
            let text = try source.singleValueContainer().decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }

            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }

            throw DecodingError.dataCorrupted(
                .init(codingPath: source.codingPath, debugDescription: "Unreadable date: \(text)")
            )
        }
        return decoder
    }()
}
