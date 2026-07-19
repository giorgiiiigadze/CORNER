import AVFoundation
import SwiftUI

/// Boring on purpose.
///
/// This is the "native chrome" half of the design: a stock grouped list that
/// behaves exactly like every other iOS settings screen. The Live Session
/// screen is where the brand lives; spending personality here would only make
/// the app feel less like Apple built it.
///
/// A tab rather than a sheet, so there's nothing to dismiss — the tab bar is
/// how you leave.
struct SettingsView: View {

    @Environment(AuthController.self) private var auth
    @Environment(\.modelContext) private var modelContext

    @AppStorage(SessionSync.Report.resultKey) private var lastSync: String = "Not yet"
    @State private var isSyncing = false

    @AppStorage(ElevenLabsVoice.preferenceKey) private var cornermanVoiceID: String = ElevenLabsCatalog.defaultVoiceID
    @AppStorage(SessionEngine.coachingKey) private var speaksCoaching: Bool = true

    @State private var cornerman: [ElevenLabsCatalog.Entry] = []
    @State private var cornermanProblem: String?
    @State private var loadingCornerman = true


    private let preview = VoicePreviewer()

    /// Who's signed in, and the way out. Deliberately the whole of the account
    /// surface — there's no profile to edit, no name to set, and nothing else
    /// the app knows about you that isn't on this screen already.
    private var account: some View {
        Section("Account") {
            LabeledContent("Signed in", value: auth.email ?? "—")
                .font(.subheadline)

            Button("Sign out", role: .destructive) {
                auth.signOut()
            }
            .font(.subheadline)
        }
    }

    /// Whether the sessions on this phone have reached the account.
    ///
    /// On screen rather than in a log, because this is the one thing on the
    /// device the user can't otherwise find out and can't afford to be wrong
    /// about: a backup that quietly isn't happening looks exactly like one that
    /// is, right up until the phone is replaced.
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

    var body: some View {
        List {
            account

            backup

            Section {
                Toggle("Talk me through it", isOn: $speaksCoaching)
                    .font(.subheadline)
            } footer: {
                Text(speaksCoaching
                     ? "The cornerman calls each round and what it's for."
                     : "Bell and clock only. He still answers your commands — \u{201C}pause\u{201D}, \u{201C}how much time\u{201D} — he just won't talk over the work.")
            }

            Section {
                cornermanVoices
            } header: {
                Text("Cornerman voice")
            } footer: {
                Text("Tap to hear it. The voice is the app — pick one you'd take instructions from.")
            }

            Section("The twelve commands") {
                ForEach(CommandReference.all, id: \.command) { entry in
                    LabeledContent(entry.say, value: entry.does)
                        .font(.subheadline)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .task { await loadCornermanVoices() }
    }

    /// The cornerman. The only voice the user picks.
    ///
    /// iOS speech is still under this as an emergency fallback, but it is
    /// deliberately not offered here: it's what speaks if the network dies
    /// mid-round, and the alternative in that moment is silence, not choice.
    @ViewBuilder
    private var cornermanVoices: some View {
        if loadingCornerman {
            HStack(spacing: 12) {
                ProgressView()
                Text("Loading voices\u{2026}")
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        } else if let cornermanProblem {
            VStack(alignment: .leading, spacing: 6) {
                Label("Can't load voices", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text(cornermanProblem)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.secondaryText)
                Button("Try again") { Task { await loadCornermanVoices() } }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        } else {
            ForEach(cornerman) { voice in
                Button {
                    cornermanVoiceID = voice.id
                    if let url = voice.previewURL { preview.play(url: url) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(voice.name)
                                .foregroundStyle(Theme.Palette.primaryText)
                            if let description = voice.description {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                        }
                        Spacer()
                        if voice.id == cornermanVoiceID {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.Palette.accent)
                        }
                    }
                }
            }
        }
    }

    private func loadCornermanVoices() async {
        loadingCornerman = true
        cornermanProblem = nil
        defer { loadingCornerman = false }
        do {
            cornerman = try await ElevenLabsCatalog.load(token: { await auth.token() })
        } catch {
            cornermanProblem = error.localizedDescription
        }
    }

    // MARK: - Pieces



}

/// Speaks the sample line. Separate from `Cornerman` because a preview has no
/// business muting the recognizer or waiting for anything.
@MainActor
private final class VoicePreviewer {
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVPlayer?


    /// Previews a cornerman voice by streaming the sample ElevenLabs hosts.
    ///
    /// Deliberately not generating our own preview: auditioning a dozen voices
    /// would burn a dozen paid generations, and these samples are free.
    func play(url: URL) {
        synthesizer.stopSpeaking(at: .immediate)
        player?.pause()
        player = AVPlayer(url: url)
        player?.play()
    }
}

nonisolated enum CommandReference {
    nonisolated struct Entry {
        let command: VoiceCommand
        let say: String
        let does: String
    }

    static let all: [Entry] = [
        Entry(command: .start, say: "\u{201C}Let\u{2019}s go\u{201D}", does: "Start"),
        Entry(command: .pause, say: "\u{201C}Pause\u{201D}", does: "Stop the clock"),
        Entry(command: .resume, say: "\u{201C}Resume\u{201D}", does: "Carry on"),
        Entry(command: .nextRound, say: "\u{201C}Next round\u{201D}", does: "Skip to the next round"),
        Entry(command: .oneMoreRound, say: "\u{201C}One more round\u{201D}", does: "Add a round"),
        Entry(command: .timeCheck, say: "\u{201C}How much time\u{201D}", does: "Speaks the clock"),
        Entry(command: .endSession, say: "\u{201C}End session\u{201D}", does: "Done"),
        Entry(command: .confirm, say: "\u{201C}Yes\u{201D}", does: "Answers \u{201C}You sure?\u{201D}"),
        Entry(command: .cancel, say: "\u{201C}No\u{201D}", does: "Never mind"),
    ]
}
