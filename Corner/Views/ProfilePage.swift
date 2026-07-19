import SwiftData
import SwiftUI

/// Who you are and what you've built.
///
/// Centred and top-heavy on purpose — the shape every profile screen has, and it
/// earns its place here: the avatar and the three numbers under it are the whole
/// point of the page, and a fighter opening it is looking for a total, not a
/// control. Everything adjustable is one tap further in.
///
/// The split from Settings is by subject. This page is about the *person* — the
/// account, the record, whether that record is safely off the phone. Settings is
/// about the *app*: which voice it uses, whether it talks.
struct ProfilePage: View {

    let history: [TrainingRecord]

    @Environment(AuthController.self) private var auth
    @Environment(\.modelContext) private var modelContext

    @AppStorage(SessionSync.Report.resultKey) private var lastSync: String = "Not yet"
    @State private var isSyncing = false

    private var stats: TrainingStats { TrainingStats.from(history: history) }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                identity
                totals
                backup
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.background)
        .toolbar { bar }
    }

    // MARK: - Identity

    private var identity: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(Theme.Palette.accentLight)
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: "figure.boxing")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(.white)
                }

            // The address until there's a name to show. `display_name` is in the
            // profiles table waiting for it, and this is the line it lands on.
            Text(auth.email ?? "Signed in")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if let since = stats.lastTrained {
                Text("Last trained \(since.formatted(.relative(presentation: .named)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Totals

    /// Three numbers in a row, big over small. The all-time figures, not this
    /// week's: Home already answers "am I still going", and this answers "what
    /// have I done", which is the question a profile is for.
    private var totals: some View {
        // Sized to their content and grouped in the middle, rather than three
        // equal thirds spread across the width. That's what keeps them reading
        // as one line under the name instead of as a row of separate columns —
        // and it's why the reference needs no rules between them.
        HStack(spacing: 34) {
            total("\(stats.totalSessions)", "Sessions")
            total("\(stats.totalRounds)", "Rounds")
            total("\(stats.minutesTotal)", "Minutes")
        }
        .frame(maxWidth: .infinity)
    }

    private func total(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())

            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Backup

    /// Whether the sessions on this phone have reached the account.
    ///
    /// On screen rather than in a log, because it's the one thing on the device
    /// a fighter can't otherwise find out and can't afford to be wrong about: a
    /// backup that quietly isn't happening looks exactly like one that is, right
    /// up until the phone is replaced.
    private var backup: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Training backup")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(lastSync)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button {
                isSyncing = true
                Task {
                    await SessionSync(auth: auth, context: modelContext).run()
                    isSyncing = false
                }
            } label: {
                Group {
                    if isSyncing {
                        ProgressView().tint(.white)
                    } else {
                        Text("Back up now").font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Theme.Palette.accent, in: .capsule)
                .foregroundStyle(.white)
            }
            .disabled(isSyncing)

            Text("Finished sessions are copied to your account, so they follow you to a new phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Theme.Palette.surface, in: .rect(cornerRadius: 18))
    }

    // MARK: - Bar

    /// The wide button in the header, where the reference has "Edit".
    ///
    /// Settings rather than an edit screen, because there's nothing to edit yet
    /// — `display_name` is waiting in the profiles table and the moment it's
    /// wired this is the button that opens it.
    @ToolbarContentBuilder
    private var bar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape.fill")
                    // Padding widens the capsule; the bar still owns the height
                    // and the material. A frame here is what made the first
                    // toolbar attempt look like nothing else on the phone.
                    .padding(.horizontal, 8)
            }
            // The word is gone, so the label has to live here — a bare glyph
            // announces itself as "gearshape" to VoiceOver otherwise.
            .accessibilityLabel("Settings")
        }
    }
}
