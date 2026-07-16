import AVFoundation
import SwiftUI

/// Boring on purpose.
///
/// This is the "native chrome" half of the design: a stock grouped list that
/// behaves exactly like every other iOS settings screen. The Live Session
/// screen is where the brand lives; spending personality here would only make
/// the app feel less like Apple built it.
struct SettingsView: View {

    @AppStorage(VoiceCatalog.preferenceKey) private var voiceIdentifier: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var previewing: String?

    private let voices = VoiceCatalog.installed()
    private let preview = VoicePreviewer()

    var body: some View {
        NavigationStack {
            List {
                if VoiceCatalog.needsBetterVoiceDownload {
                    Section {
                        downloadPrompt
                    }
                }

                Section {
                    ForEach(voices) { voice in
                        row(for: voice)
                    }
                } header: {
                    Text("Cornerman voice")
                } footer: {
                    Text("Tap to hear it call a combination. The voice is the app — pick one you'd take instructions from.")
                }

                Section("The twelve commands") {
                    ForEach(CommandReference.all, id: \.command) { entry in
                        LabeledContent(entry.say, value: entry.does)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Pieces

    /// The highest-value thing on this screen. Only the user can install a good
    /// voice, so the app's whole job is to tell them it's worth doing and where.
    private var downloadPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Only robot voices installed", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text("""
                iOS ships one basic voice and downloads the good ones on request. \
                A Premium voice sounds like a person and costs nothing.
                """)
            .font(.footnote)
            .foregroundStyle(Theme.Palette.secondaryText)
            Text("Settings \u{203A} Accessibility \u{203A} Spoken Content \u{203A} Voices \u{203A} English")
                .font(.footnote.weight(.medium))
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func row(for voice: VoiceCatalog.Entry) -> some View {
        Button {
            voiceIdentifier = voice.id
            previewing = voice.id
            preview.play(voice.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(voice.name)
                        .foregroundStyle(Theme.Palette.primaryText)
                    if let note = voice.quality.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
                Spacer()
                Text(voice.quality.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(voice.quality > .compact ? Theme.Palette.accent : Theme.Palette.secondaryText)
                if isSelected(voice) {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
        }
    }

    /// An empty stored value means "never chosen", which resolves to the best
    /// installed voice — so that's the one to tick.
    private func isSelected(_ voice: VoiceCatalog.Entry) -> Bool {
        voiceIdentifier.isEmpty ? voice.id == voices.first?.id : voice.id == voiceIdentifier
    }
}

/// Speaks the sample line. Separate from `Cornerman` because a preview has no
/// business muting the recognizer or waiting for anything.
@MainActor
private final class VoicePreviewer {
    private let synthesizer = AVSpeechSynthesizer()

    func play(_ identifier: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: VoiceCatalog.previewLine)
        utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
        utterance.rate = 0.54
        synthesizer.speak(utterance)
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
        Entry(command: .pause, say: "\u{201C}Pause\u{201D}", does: "Freeze mid-combo"),
        Entry(command: .resume, say: "\u{201C}Resume\u{201D}", does: "Carry on"),
        Entry(command: .slower, say: "\u{201C}Slower\u{201D}", does: "More space between calls"),
        Entry(command: .faster, say: "\u{201C}Faster\u{201D}", does: "Less space"),
        Entry(command: .again, say: "\u{201C}Again\u{201D}", does: "Repeat the last combo"),
        Entry(command: .stop, say: "\u{201C}Stop\u{201D}", does: "Quit repeating"),
        Entry(command: .skip, say: "\u{201C}Skip\u{201D}", does: "Next combo"),
        Entry(command: .nextRound, say: "\u{201C}Next round\u{201D}", does: "End this round"),
        Entry(command: .oneMoreRound, say: "\u{201C}One more round\u{201D}", does: "Add a round"),
        Entry(command: .timeCheck, say: "\u{201C}How much time\u{201D}", does: "Speaks the clock"),
        Entry(command: .endSession, say: "\u{201C}End session\u{201D}", does: "Done"),
    ]
}
