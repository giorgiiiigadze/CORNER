import Foundation

/// Turns whatever the transcriber heard into one of the seven commands.
///
/// Pure by design — no framework, no state, no I/O. Every accuracy decision in the
/// app that can be reasoned about without a microphone lives here.
nonisolated enum CommandParser {

    /// Phrases people actually say, not the enum names.
    ///
    /// Order in this array does not matter; `parse` resolves overlaps by position
    /// and length. But it matters that the *phrases* are real: nobody standing at a
    /// bag says "next round" as often as they say "next".
    private static let phrases: [(String, VoiceCommand)] = [
        ("lets go", .start), ("let us go", .start), ("start", .start),
        ("begin", .start), ("ready", .start),

        ("pause", .pause), ("hold on", .pause), ("hold up", .pause), ("wait", .pause),

        ("resume", .resume), ("continue", .resume), ("keep going", .resume),
        ("carry on", .resume), ("go on", .resume),

        ("next round", .nextRound), ("next", .nextRound),

        ("one more round", .oneMoreRound), ("another round", .oneMoreRound),
        ("one more", .oneMoreRound),

        ("how much time", .timeCheck), ("time check", .timeCheck),
        ("how long", .timeCheck), ("how long left", .timeCheck),

        ("end session", .endSession), ("end workout", .endSession),
        ("im done", .endSession), ("i am done", .endSession),
        ("finish", .endSession), ("thats it", .endSession),
    ]

    /// Lowercases, drops apostrophes so "let's" reads as "lets", and reduces
    /// everything else to single-spaced words fenced by spaces, so that a phrase
    /// search can require word boundaries with plain substring matching.
    static func normalize(_ text: String) -> String {
        let deapostrophized = text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let lettersOnly = String(deapostrophized.map { $0.isLetter || $0.isNumber ? $0 : " " })
        let words = lettersOnly.split(separator: " ")
        return " " + words.joined(separator: " ") + " "
    }

    /// The most recent command in `text`, or nil.
    ///
    /// Two rules resolve the overlaps, and both matter:
    ///
    /// - **Latest wins.** A transcript accumulates ("lets go ... pause"), so the
    ///   command the user just said is the one at the end.
    /// - **Longest wins at the same position.** " next round " also contains " next ",
    ///   and " one more round " also contains " one more ". Without this, every
    ///   `nextRound` would fire as a bare `next` and "one more round" would be heard
    ///   as a request to repeat a combo.
    static func parse(_ text: String) -> VoiceCommand? {
        let haystack = normalize(text)

        var best: (position: Int, length: Int, command: VoiceCommand)?

        for (phrase, command) in phrases {
            guard let range = haystack.range(of: " \(phrase) ", options: .backwards) else { continue }
            let position = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let length = phrase.count

            if let current = best {
                let better = position > current.position
                    || (position == current.position && length > current.length)
                if better { best = (position, length, command) }
            } else {
                best = (position, length, command)
            }
        }

        return best?.command
    }

    /// Whether `heard` is just the app listening to itself.
    ///
    /// The microphone picks up the speaker. Hardware echo cancellation removes
    /// most of it, but not reliably enough to bet the session on: a leaked
    /// "next round" from corner talk would skip a round the fighter is still in.
    ///
    /// The app closed the mic entirely while it spoke, which was airtight and
    /// also meant it couldn't be interrupted for the thirty seconds of the intro.
    /// This is the trade that buys that back — the app knows its own script, so
    /// it can discard its own words and still hear a voice in the room.
    ///
    /// Deliberately generous about what counts as an echo. A missed barge-in is
    /// a beat of talking over someone; a false one is the session obeying a
    /// command nobody gave.
    static func isEcho(_ heard: String, of spoken: String) -> Bool {
        let heardWords = normalize(heard).split(separator: " ")
        // No words at all, so nothing to attribute to anyone. Calling this an
        // echo is what stops every silence between two words from reading as
        // someone speaking.
        guard !heardWords.isEmpty else { return true }

        let haystack = normalize(spoken)

        // Every word has to come from the script. One that doesn't means someone
        // else is talking, which is the only thing worth acting on.
        //
        // Word-wise rather than a contiguous match, because echo cancellation
        // strips the line unevenly: what comes back is the cornerman's words with
        // holes in them ("next round … snap it"), never a clean run.
        return heardWords.enumerated().allSatisfy { index, word in
            // Only the last word may be a fragment — volatile results arrive
            // mid-word, "rou" on the way to "round". Allowing it anywhere else
            // would let "go" match "going" in the middle of a real sentence.
            let isLast = index == heardWords.count - 1
            return haystack.contains(isLast ? " \(word)" : " \(word) ")
        }
    }

    /// Everything the recognizer should be biased toward hearing.
    ///
    /// Fed to `AnalysisContext.contextualStrings` so the transcriber favours these
    /// over similar-sounding everyday words. This is the single highest-leverage
    /// accuracy knob available for a fixed grammar this small.
    static var contextualStrings: [String] {
        phrases.map(\.0)
    }
}
