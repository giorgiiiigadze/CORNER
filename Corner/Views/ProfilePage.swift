import SwiftData
import SwiftUI

/// Who you are, what you've done, and the way to everything else.
///
/// The split from Settings is by subject, not by convenience: this page is about
/// the *person* — the account, the record, whether the record is safely off the
/// phone — and Settings is about the *app*, which voice it uses and whether it
/// talks. Preferences that would follow a fighter to a new phone belong here;
/// preferences that belong to this install belong there.
struct ProfilePage: View {

    let history: [TrainingRecord]

    @Environment(AuthController.self) private var auth
    @Environment(\.modelContext) private var modelContext

    @AppStorage(SessionSync.Report.resultKey) private var lastSync: String = "Not yet"
    @State private var isSyncing = false

    private var stats: TrainingStats { TrainingStats.from(history: history) }

    var body: some View {
        List {
            identity
            record
            backup

            Section {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape.fill")
                        .font(.subheadline)
                }
            }

            Section {
                Button("Sign out", role: .destructive) {
                    auth.signOut()
                }
                .font(.subheadline)
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Sections

    /// The mark and the address, at the top, doing what a profile header does:
    /// answering "whose app is this" before anything else on the screen.
    private var identity: some View {
        Section {
            HStack(spacing: 14) {
                Circle()
                    .fill(Theme.Palette.accentLight)
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "figure.boxing")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(auth.email ?? "Signed in")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(stats.totalSessions == 1 ? "1 session" : "\(stats.totalSessions) sessions")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .listRowBackground(Color.clear)
        }
    }

    /// The totals, not this week's. The dashboard on Home is for whether you're
    /// still going; this is for what you've built, which is the number a profile
    /// is for.
    private var record: some View {
        Section("Record") {
            LabeledContent("Sessions", value: "\(stats.totalSessions)")
            LabeledContent("Rounds", value: "\(stats.totalRounds)")
            LabeledContent("Minutes", value: "\(stats.minutesTotal)")
            LabeledContent("Streak", value: stats.streak == 1 ? "1 day" : "\(stats.streak) days")
        }
        .font(.subheadline)
    }

    /// Whether the sessions on this phone have reached the account.
    ///
    /// On screen rather than in a log, because it's the one thing on the device
    /// a fighter can't otherwise find out and can't afford to be wrong about: a
    /// backup that quietly isn't happening looks exactly like one that is, right
    /// up until the phone is replaced.
    private var backup: some View {
        Section {
            LabeledContent("Last backup", value: lastSync)
                .font(.subheadline)

            Button {
                isSyncing = true
                Task {
                    await SessionSync(auth: auth, context: modelContext).run()
                    isSyncing = false
                }
            } label: {
                HStack {
                    Text("Back up now")
                    if isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .font(.subheadline)
            .disabled(isSyncing)
        } header: {
            Text("Training backup")
        } footer: {
            Text("Finished sessions are kept on this phone and copied to your account, so they follow you to a new device.")
        }
    }
}
