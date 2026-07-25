import SwiftData
import SwiftUI

/// Who you are and what you've built.
///
/// Built to the shape a social profile has — a full-bleed header with the name
/// laid over it, a line of totals, a row of actions, then the record below —
/// because that's the page a fighter already knows how to read. What's different
/// is the data: the numbers under the name aren't friends and followers, they're
/// sessions, rounds and the streak, which is the only standing this app keeps.
///
/// The split from Settings holds: this page is the *person* and the record,
/// Settings is the *app*.
struct ProfilePage: View {

    let history: [TrainingRecord]

    @Environment(AuthController.self) private var auth
    @Environment(\.modelContext) private var modelContext

    @AppStorage(SessionSync.Report.resultKey) private var lastSync: String = "Not yet"
    @State private var isSyncing = false

    private var stats: TrainingStats { TrainingStats.from(history: history) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                VStack(spacing: 22) {
                    statLine
                    if hasWeek { weekSection }
                    if hasBodyStats { bodySection }
                    backup
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.background)
        // The header runs to the very top edge, under the status bar and the
        // gear, the way a cover photo does — so the scroll content is allowed
        // into the top safe area and the bar draws no background over it.
        .ignoresSafeArea(edges: .top)
        .toolbar { bar }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: - Header

    /// The full-bleed cover. No uploaded photo yet, so the picture *is* the
    /// avatar: the whole banner is the seeded colour the small disc uses, the
    /// initials filling it edge to edge rather than sitting in a circle. The name
    /// and handle sit over the foot of it on a scrim, where a photo caption
    /// would. Square at the top so it meets the screen edge, rounded only at the
    /// bottom where the page begins.
    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            InitialsAvatar.color(seed: avatarSeed)

            // The initials as the portrait — huge, centred, dimmed just enough
            // that the name reading over the bottom of it stays the louder mark.
            Text(InitialsAvatar.initials(name: auth.displayName, email: auth.email))
                .font(.system(size: 180, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // A scrim so the name holds up over the colour, the same way a
            // caption stays legible over a photo.
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text("@\(handle)")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(20)
        }
        .frame(height: 460)
        .frame(maxWidth: .infinity)
        // Bottom corners only — the top meets the screen edge square.
        .clipShape(.rect(bottomLeadingRadius: 20, bottomTrailingRadius: 20, style: .continuous))
    }

    private var avatarSeed: String { auth.userID ?? auth.email ?? "" }

    /// The name over the header. The display name when there is one, otherwise
    /// the local part of the address — never the raw email, which reads as a
    /// login, not a person.
    private var displayName: String {
        if let name = auth.displayName, !name.isEmpty { return name }
        if let email = auth.email { return String(email.split(separator: "@").first ?? "Fighter") }
        return "Fighter"
    }

    /// The handle under the name, built from the address so it's stable and the
    /// user's own — spaces and dots folded to underscores the way a username is.
    private var handle: String {
        let base = auth.email.map { String($0.split(separator: "@").first ?? "") }
            ?? auth.displayName
            ?? "fighter"
        return base.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
    }

    // MARK: - Stat line

    /// Sessions, rounds and the streak, where the reference has friends,
    /// followers and following — the three totals that add up to a standing on
    /// this app. Rendered as one flowing line, bold number and quiet label, with
    /// a dot between.
    private var statLine: some View {
        HStack(spacing: 8) {
            statPiece("\(stats.totalSessions)", stats.totalSessions == 1 ? "session" : "sessions")
            dot
            statPiece("\(stats.totalRounds)", stats.totalRounds == 1 ? "round" : "rounds")
            dot
            statPiece("\(stats.streak)", stats.streak == 1 ? "day streak" : "day streak")
            Spacer(minLength: 0)
        }
    }

    private func statPiece(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var dot: some View {
        Text("·").font(.subheadline).foregroundStyle(.secondary)
    }

    // MARK: - This week

    /// The "Pins" slot, but a record rather than a scrapbook: the week's work in
    /// three tiles. Hidden until there's a week to show, so a fresh account isn't
    /// met with a row of zeroes.
    private var hasWeek: Bool { stats.sessionsThisWeek > 0 }

    private var weekSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("This week")

            HStack(spacing: 10) {
                tile("\(stats.sessionsThisWeek)", stats.sessionsThisWeek == 1 ? "session" : "sessions")
                tile("\(stats.roundsThisWeek)", "rounds")
                tile("\(stats.minutesThisWeek)", "min")
            }
        }
    }

    // MARK: - Body

    private var hasBodyStats: Bool {
        auth.weightKg != nil || auth.heightCm != nil || auth.birthdate != nil
    }

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Body")

            HStack(spacing: 10) {
                if let weight = ManageProfileView.weightText(auth.weightKg) {
                    tile(weight, "Weight")
                }
                if let height = ManageProfileView.heightText(auth.heightCm) {
                    tile(height, "Height")
                }
                if let age = ageText {
                    tile(age, "Age")
                }
            }
        }
    }

    private var ageText: String? {
        guard let birthdate = auth.birthdate else { return nil }
        let years = Calendar.current.dateComponents([.year], from: birthdate, to: .now).year
        return years.map(String.init)
    }

    // MARK: - Shared pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One figure in a card — the tile the week and body rows are built from.
    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.Palette.surface, in: .rect(cornerRadius: 12))
    }

    // MARK: - Backup

    /// Whether the sessions on this phone have reached the account — the one
    /// thing on the device a fighter can't otherwise find out, and can't afford
    /// to be wrong about.
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
                        ProgressView().tint(.black)
                    } else {
                        Text("Back up now").font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Theme.Palette.accent, in: Theme.buttonShape)
                .foregroundStyle(.black)
            }
            .disabled(isSyncing)

            Text("Finished sessions are copied to your account, so they follow you to a new phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Theme.Palette.surface, in: .rect(cornerRadius: 12))
    }

    // MARK: - Bar

    @ToolbarContentBuilder
    private var bar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape.fill")
                    .padding(.horizontal, 8)
            }
            .accessibilityLabel("Settings")
        }
    }
}
