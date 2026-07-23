import AVFoundation
import SwiftUI

/// Boring on purpose.
///
/// This is the "native chrome" half of the design: a stock grouped list that
/// behaves exactly like every other iOS settings screen. The Live Session
/// screen is where the brand lives; spending personality here would only make
/// the app feel less like Apple built it.
///
/// Pushed from Profile rather than owning a tab. What's here is about the
/// *app* — which voice it uses, whether it talks, what it answers to. What's
/// about the *person* — the account, the record, whether the record is off the
/// phone — is on Profile, one level up.
struct SettingsView: View {

    /// The chosen voice's name, remembered so the row can say which one is on
    /// without a network round-trip to find out.
    nonisolated static let voiceNameKey = "cornerman.voiceName"

    @Environment(AuthController.self) private var auth

    @AppStorage(SessionEngine.coachingKey) private var speaksCoaching: Bool = true
    @AppStorage(SettingsView.voiceNameKey) private var cornermanVoiceName: String = ""

    /// The one thing the generator can't learn by watching you train. Moved
    /// here when the Coach tab was removed — it's a single choice that shapes
    /// every written session, and losing the only control for it would have
    /// quietly pinned everyone to "beginner" forever.
    @AppStorage(TrainingProfile.levelKey) private var level: String = TrainingProfile.Level.beginner.rawValue

    var body: some View {
        List {
            Section {
                SettingRow(
                    title: "Talk me through it",
                    description: speaksCoaching
                        ? "The cornerman calls each round and what it's for."
                        : "Bell and clock only. He still answers your commands."
                ) {
                    Toggle("", isOn: $speaksCoaching)
                        .labelsHidden()
                        // The system green, which is what a toggle is green
                        // everywhere else on the phone — a switch is one of the
                        // few controls with a colour people already know.
                        //
                        // Stated, not inherited: the tab bar tints this subtree
                        // white, so without this an "on" toggle would be a white
                        // track on a grey card — on and off telling each other
                        // apart by a shade.
                        //
                        // It was the brand red, which read as a warning on a
                        // control whose "on" state is the good one.
                        .tint(.green)
                }
            }
            .listRowBackground(Theme.Palette.surface)

            Section {
                Picker("Experience", selection: $level) {
                    ForEach(TrainingProfile.Level.allCases, id: \.rawValue) { level in
                        Text(level.rawValue.capitalized).tag(level.rawValue)
                    }
                }
            } footer: {
                Text("How hard the cornerman writes your sessions.")
            }
            .listRowBackground(Theme.Palette.surface)

            Section {
                NavigationLink {
                    VoicePicker()
                } label: {
                    SettingRow(
                        title: "Cornerman voice",
                        description: cornermanVoiceName.isEmpty
                            ? "Pick a voice you'd take instructions from."
                            : cornermanVoiceName
                    )
                }

                NavigationLink {
                    CommandsList()
                } label: {
                    SettingRow(
                        title: "Voice commands",
                        description: "The nine things he answers to, hands-free."
                    )
                }
            }
            .listRowBackground(Theme.Palette.surface)

            // Last, and on its own. Sign-out is the one thing here that can't be
            // undone by tapping again, and it has no business sitting a
            // thumb's-width from a voice picker.
            Section {
                Button("Sign out", role: .destructive) {
                    auth.signOut()
                }
                .font(.body)
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        // Grey, not the black the rest of the chrome uses.
        //
        // Black, the same as every other screen.
        //
        // This reverses an earlier decision, and the argument it reverses was:
        // the rows *are* a settings screen, so a grey ground makes a stack of
        // them read as one list rather than as cards floating in a void. That's
        // true in isolation. What it missed is that this screen is one tab away
        // from three black ones — and a ground that changes when you move
        // between tabs is more noticeable than any gain in how a list coheres.
        //
        // With the ground back to black the rows drop a step to `surface`,
        // which is the card grey the rest of the app uses. Same separation,
        // same colour as a card on Home.
        .background(Theme.Palette.background)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The voice list, on its own screen.
///
/// Pushed rather than inline because it's a dozen rows that each cost a network
/// fetch to describe — on the settings screen itself they buried two actual
/// settings under a wall of names.
struct VoicePicker: View {

    @Environment(AuthController.self) private var auth

    @AppStorage(ElevenLabsVoice.preferenceKey) private var cornermanVoiceID: String = ElevenLabsCatalog.defaultVoiceID
    @AppStorage(SettingsView.voiceNameKey) private var cornermanVoiceName: String = ""

    @State private var cornerman: [ElevenLabsCatalog.Entry] = []
    @State private var cornermanProblem: String?
    @State private var loadingCornerman = true

    private let preview = VoicePreviewer()

    var body: some View {
        List {
            Section {
                cornermanVoices
            } footer: {
                Text("Tap to hear it. The voice is the app, so pick one you'd take instructions from.")
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("Cornerman voice")
        .navigationBarTitleDisplayMode(.inline)
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
                    // Stored so Settings can name the current voice without
                    // fetching the whole catalogue to render one line.
                    cornermanVoiceName = voice.name
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

}

/// What he answers to. Reference, not settings — nothing here is adjustable,
/// which is exactly why it doesn't belong on the screen where things are.
struct CommandsList: View {
    var body: some View {
        List {
            Section {
                ForEach(CommandReference.all, id: \.command) { entry in
                    LabeledContent(entry.say, value: entry.does)
                        .font(.subheadline)
                }
            } footer: {
                Text("Say them at any point in a session. He answers even with the coaching turned off.")
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("Voice commands")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Speaks the sample line. Separate from `Cornerman` because a preview has no
/// business muting the recognizer or waiting for anything.
@MainActor
final class VoicePreviewer {
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
