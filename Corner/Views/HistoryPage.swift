import SwiftUI

/// Every session you finished, newest first.
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

    var body: some View {
        if history.isEmpty {
            empty
        } else {
            // The dashboard lives on home. This page is the evidence underneath
            // it — every session, one line each, deletable.
            List {
                ForEach(history) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.Palette.primaryText)
                        Text(detail(for: record))
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
                .onDelete(perform: onDelete)
            }
            .scrollContentBackground(.hidden)
            // As on home: no system wash behind the header, none at the bottom.
            .scrollEdgeEffectHidden(true, for: .all)
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

    private func detail(for record: TrainingRecord) -> String {
        "\(record.roundsCompleted)/\(record.roundsPlanned) rounds \u{00B7} \(record.date.formatted(.relative(presentation: .named)))"
    }
}
