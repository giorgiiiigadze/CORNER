import SwiftUI

/// What the cornerman knows about you, and the one place you can argue with it.
///
/// This is the product's actual claim made inspectable. "The AI learns from your
/// sessions" is a sentence any timer app could print; the difference is being
/// able to open a page, read what it concluded, and tell it when it's wrong.
///
/// The two halves are deliberately separate and labelled as such. The top is
/// what you told it. The bottom is what it worked out from sessions you
/// finished, and it's read-only because it's evidence — a derived note you could
/// edit would be neither what you said nor what happened.
struct CoachPage: View {

    let profile: TrainingProfile

    @AppStorage(TrainingProfile.levelKey) private var level: String = TrainingProfile.Level.beginner.rawValue
    @AppStorage(CoachingNotes.key) private var notesData: Data = Data()

    @State private var drafting = ""
    @FocusState private var writing: Bool

    private var notes: [CoachingNote] { CoachingNotes.decode(notesData) }

    var body: some View {
        List {
            Section {
                Picker("Level", selection: $level) {
                    ForEach(TrainingProfile.Level.allCases, id: \.rawValue) { level in
                        Text(level.rawValue.capitalized).tag(level.rawValue)
                    }
                }
            } header: {
                Text("You")
            } footer: {
                // Lives here rather than in Settings now: it's the single most
                // important thing the generator is told, and Settings is where
                // you change the voice.
                Text("The one thing it can't learn from watching you train.")
            }

            Section {
                ForEach(notes) { note in
                    Text(note.text)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                .onDelete(perform: delete)

                add
            } header: {
                Text("What you've told it")
            } footer: {
                Text("Goes into every session it writes, and outranks anything it inferred. \u{201C}My ribs are shot, no body work.\u{201D} \u{201C}I'm a southpaw.\u{201D}")
            }

            Section {
                learned
            } header: {
                Text("What it worked out from your sessions")
            }
        }
        .scrollContentBackground(.hidden)
        // As on home: no system wash behind the header, none at the bottom.
        .scrollEdgeEffectHidden(true, for: .all)
    }

    /// A row rather than a toolbar button: the empty state and the add control
    /// are then the same thing, so there's never a page with nothing on it.
    private var add: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.body)
                .foregroundStyle(Theme.Palette.accent)

            TextField("Tell it something", text: $drafting, axis: .vertical)
                .font(.subheadline)
                .focused($writing)
                .submitLabel(.done)
                .onSubmit(commit)
        }
    }

    @ViewBuilder
    private var learned: some View {
        if profile.recentFocuses.isEmpty && profile.notes.isEmpty {
            Text("Nothing yet. It learns from sessions you finish.")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !profile.recentFocuses.isEmpty {
                    Text("You've drilled: \(profile.recentFocuses.prefix(5).joined(separator: ", "))")
                }
                ForEach(profile.notes, id: \.self) { note in
                    Text(note)
                }
            }
            .font(.footnote)
            .foregroundStyle(Theme.Palette.secondaryText)
        }
    }

    private func commit() {
        let text = drafting.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to say is not an instruction. Silently dropping it beats an
        // empty bullet arriving in the prompt.
        guard !text.isEmpty else {
            drafting = ""
            return
        }
        notesData = CoachingNotes.encode(notes + [CoachingNote(text: text)])
        drafting = ""
        writing = false
    }

    private func delete(_ offsets: IndexSet) {
        var kept = notes
        kept.remove(atOffsets: offsets)
        notesData = CoachingNotes.encode(kept)
    }
}
