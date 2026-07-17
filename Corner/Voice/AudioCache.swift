import CryptoKit
import Foundation
import os

/// Audio we've already paid for, kept on disk.
///
/// The economics inverted when the combo callouts went. This existed because
/// combos repeat forever — "one, two" is the same audio this week and next year
/// — so thirty-five callouts a round cost nothing after the first session. There
/// are no callouts, and almost everything the cornerman says now is unique to the
/// session that produced it.
///
/// What still hits is the fixed lines: the two endings, and the ~180 possible
/// answers to "how much time". Those are identical in every session forever, so
/// they cost one fetch each, ever. It's a much smaller saving than it was — but
/// it's also a much smaller bill, roughly five cents a session against a
/// per-round one.
///
/// Lives in Caches, so iOS may evict it under storage pressure. That's fine —
/// a miss costs a re-fetch, not a broken session.
actor AudioCache {

    private let directory: URL
    private let log = Logger(subsystem: "Giorgi.Corner", category: "audio-cache")

    init(name: String = "voice-lines") {
        let caches = URL.cachesDirectory
        directory = caches.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Keyed on voice *and* model as well as text — the same words in a
    /// different voice are different audio, and returning the wrong one would
    /// be a baffling bug to track down.
    private func path(voiceID: String, model: String, text: String) -> URL {
        let digest = SHA256.hash(data: Data("\(voiceID)|\(model)|\(text)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).mp3")
    }

    func data(voiceID: String, model: String, text: String) -> Data? {
        try? Data(contentsOf: path(voiceID: voiceID, model: model, text: text))
    }

    func store(_ data: Data, voiceID: String, model: String, text: String) {
        do {
            try data.write(to: path(voiceID: voiceID, model: model, text: text), options: .atomic)
        } catch {
            // A cache write failing costs money, not correctness — the line
            // still plays, we just pay for it again next time.
            log.warning("Cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func contains(voiceID: String, model: String, text: String) -> Bool {
        FileManager.default.fileExists(atPath: path(voiceID: voiceID, model: model, text: text).path)
    }

    /// Bytes currently cached. Shown in Settings so the saving is visible.
    func sizeOnDisk() -> Int64 {
        let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        return (files ?? []).reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func clear() {
        let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files ?? [] { try? FileManager.default.removeItem(at: file) }
    }
}
