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
                if hasBodyStats { bodyStats }
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
            // Yours, not the app's. This was a red disc with a boxing glove on
            // it — the same image for every account on earth, which is a logo
            // in the place a profile picture goes.
            //
            // Seeded on the user id so the colour survives changing your
            // address, and so two people on one phone don't get the same disc.
            InitialsAvatar(
                name: auth.displayName,
                email: auth.email,
                seed: auth.userID ?? auth.email ?? ""
            )

            // The name when the profile has one, the address until then. Both
            // are the same line rather than a name *above* an address: one of
            // the two is always missing, and a layout that reserves space for
            // both is a gap on most accounts.
            Text(auth.displayName ?? auth.email ?? "Signed in")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            // The address moves down here once a name has taken the line above
            // it, so nothing that was on screen disappears when a name arrives.
            if auth.displayName != nil, let email = auth.email {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let since = stats.lastTrained {
                Text("Last trained \(since.formatted(.relative(presentation: .named)))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Stat item

    /// One big-over-small figure, grouped in the middle with its siblings rather
    /// than spread across the width — what keeps them reading as one line under
    /// the name instead of a row of separate columns.
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

    // MARK: - Body stats

    /// Weight, height and age, shown only once there's at least one of them —
    /// filled from Apple Health or typed in Manage Profile. An empty row here
    /// would be a prompt on a page that's meant to be a record, so it stays gone
    /// until there's something to record.
    private var hasBodyStats: Bool {
        auth.weightKg != nil || auth.heightCm != nil || auth.birthdate != nil
    }

    private var bodyStats: some View {
        HStack(spacing: 34) {
            if let weight = ManageProfileView.weightText(auth.weightKg) {
                total(weight, "Weight")
            }
            if let height = ManageProfileView.heightText(auth.heightCm) {
                total(height, "Height")
            }
            if let age = ageText {
                total(age, "Age")
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Age in whole years from the birthdate, which is what a profile shows —
    /// the date itself is an edit-screen detail, not a headline number.
    private var ageText: String? {
        guard let birthdate = auth.birthdate else { return nil }
        let years = Calendar.current.dateComponents([.year], from: birthdate, to: .now).year
        return years.map(String.init)
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
