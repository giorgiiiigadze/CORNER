import SwiftUI

/// What the cornerman knows about you, and the only place to change it.
///
/// Standing instructions — "my ribs are shot, no body work", "I'm a southpaw" —
/// held until deleted. They were writable nowhere: `CoachingNotes` was read on
/// the way into every prompt and had no screen, so the one thing that shapes
/// what the coach says was the one thing the fighter couldn't say.
///
/// The distinction this page has to keep is against the setup sheet. The focus
/// picked there is *this* session; a note here is every session, and that's why
/// the two aren't the same control in two places.
struct CoachPage: View {

    @AppStorage(CoachingNotes.key) private var notesData: Data = Data()

    /// What's in the field. Cleared by adding, so the field is empty for the
    /// next one rather than needing to be cleared by hand.
    @State private var draft = ""

    @FocusState private var writing: Bool

    private var notes: [CoachingNote] {
        // Newest first. A note added is a note you're thinking about, and a
        // list that appends to the bottom hides it under everything you already
        // told it.
        CoachingNotes.decode(notesData).sorted { $0.added > $1.added }
    }

    private var canAdd: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            Section {
                composer
            } footer: {
                Text("Held for every session until you delete it. What you pick in the setup sheet is just that session.")
            }

            if notes.isEmpty {
                Section {
                    empty
                }
            } else {
                Section("Standing instructions") {
                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.text)

                            // When you said it. A note six weeks old about a
                            // rib is worth a second look; one from this morning
                            // isn't.
                            Text(note.added.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
    }

    /// The field and its button on one row, the way a message is written.
    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Tell the coach something", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($writing)
                .submitLabel(.done)

            Button(action: add) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            // Lime for a note there's something to add, grey for an empty
            // field. Disabled rather than hidden: a button that vanishes as you
            // clear the field moves the row out from under your thumb.
            .foregroundStyle(canAdd ? Theme.Palette.accent : Color(.tertiaryLabel))
            .disabled(!canAdd)
            .accessibilityLabel("Add instruction")
        }
        .sensoryFeedback(.success, trigger: notes.count)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing standing yet")
                .font(.subheadline.weight(.semibold))

            Text("Injuries, stance, anything that holds true every time you train. The coach reads these before it writes a session.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Read, append, write. The stored order doesn't matter — the list sorts
        // on the way out — so this appends rather than reordering the blob.
        var stored = CoachingNotes.decode(notesData)
        stored.append(CoachingNote(text: text))
        notesData = CoachingNotes.encode(stored)

        draft = ""
        writing = false
    }

    /// Deletes by identity rather than by index. The rows are sorted newest
    /// first and the stored order isn't, so an index into one is the wrong note
    /// in the other.
    private func delete(_ offsets: IndexSet) {
        let doomed = Set(offsets.map { notes[$0].id })
        notesData = CoachingNotes.encode(
            CoachingNotes.decode(notesData).filter { !doomed.contains($0.id) }
        )
    }
}
