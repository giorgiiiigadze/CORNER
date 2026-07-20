import SwiftUI

/// Every session you finished, newest first — and the one you haven't.
///
/// Its own page now rather than a section at the bottom of home: this is the
/// evidence behind "the cornerman learns from you", and evidence you have to
/// scroll past three other sections to find reads like a footnote.
///
/// Takes its records rather than querying for them, so the shell owns the one
/// `@Query` and the delete stays consistent with it.
struct HistoryPage: View {

    let history: [TrainingRecord]
    let onDelete: (IndexSet) -> Void

    /// Today's session if it was left partway through, and the way back into it.
    ///
    /// Here as well as on Home because this is the tab you open to ask "what
    /// have I been doing" — and a session you walked away from an hour ago is
    /// the truest answer to that, while being the one thing on the page you can
    /// still change. It was only ever on Home, which meant the screen devoted to
    /// your sessions was the one screen that didn't mention the live one.
    var unfinished: UnfinishedSession?
    var onResume: () -> Void = {}

    var body: some View {
        if history.isEmpty && unfinished == nil {
            empty
        } else {
            List {
                if let unfinished {
                    Section {
                        ResumeCard(session: unfinished, onResume: onResume)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .listSectionMargins(.horizontal, 16)
                }

                // The same card Home draws, not a two-line row that happens to
                // name the same session. This page used to be a table — title
                // and a grey subtitle — which quietly said the sessions here
                // were an index of the ones on Home rather than the same
                // objects.
                Section {
                    ForEach(history) { record in
                        SessionCard(record: record, stamp: .relativeDay)
                            // Zero leading and trailing: the section margin does
                            // the insetting, and a row inset is charged on top of
                            // it — which would leave these cards narrower than
                            // the identical ones on Home.
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    // On the `ForEach` over `history` alone, which is what keeps
                    // the index it hands back meaningful: the resume card is its
                    // own section, so it can't shift these by one and delete the
                    // wrong session.
                    .onDelete(perform: onDelete)
                }
                .listSectionMargins(.horizontal, 16)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.Palette.secondaryText)
            Text("No sessions yet")
                .font(.headline)
                .foregroundStyle(Theme.Palette.primaryText)
            Text("Finish one and it lands here.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.secondaryText)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
