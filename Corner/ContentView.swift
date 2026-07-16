import AVFoundation
import Speech
import SwiftUI

/// M1 scaffolding, not a design.
///
/// The real Home screen arrives in M2. This exists only to get permissions granted
/// and a session on screen so the voice loop can be measured in a gym.
struct ContentView: View {

    @State private var sessions: [Session] = []
    @State private var live: SessionEngine?
    @State private var problem: String?
    @State private var planned: PlannedSession?
    @State private var isGenerating = false
    @State private var showingSettings = false

    private let audioSession = AudioSessionController()

    var body: some View {
        NavigationStack {
            List {
                Section("Today") {
                    todaysSession
                }

                Section {
                    ForEach(sessions) { session in
                        Button {
                            Task { await launch(session) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title)
                                    .font(.headline)
                                    .foregroundStyle(Theme.Palette.primaryText)
                                Text(summary(of: session))
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                        }
                    }
                } header: {
                    Text("Offline")
                } footer: {
                    Text("Prop the phone anywhere you can hear it, then say \u{201C}let\u{2019}s go\u{201D}.")
                }

                if let problem {
                    Section("Problem") {
                        Text(problem).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("CORNER")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
        .preferredColorScheme(.dark)
        .task { load() }
        .fullScreenCover(item: $live) { engine in
            LiveSessionView(engine: engine)
        }
    }

    /// The AI-generated session. M2 makes this the hero card; for now it just
    /// has to prove the brain works.
    @ViewBuilder
    private var todaysSession: some View {
        if isGenerating {
            HStack(spacing: 12) {
                ProgressView()
                Text("The cornerman is writing your session\u{2026}")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        } else if let planned {
            Button {
                Task { await launch(planned.session) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(planned.session.title)
                        .font(.headline)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text(summary(of: planned.session))
                        .font(.subheadline)
                        .foregroundStyle(Theme.Palette.secondaryText)
                    origin(planned.origin)
                }
            }
        } else {
            Button("Generate today\u{2019}s session") {
                Task { await generate() }
            }
            .foregroundStyle(Theme.Palette.accent)
        }
    }

    /// Says plainly whether Claude wrote this or whether it's the shipped JSON.
    /// Silently serving a fallback would make the moat impossible to evaluate.
    @ViewBuilder
    private func origin(_ origin: SessionOrigin) -> some View {
        switch origin {
        case .claude:
            Label("Written for you just now", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(Theme.Palette.accent)
        case .bundled(let reason):
            Label("Offline session \u{2014} \(reason)", systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
    }

    private func generate() async {
        isGenerating = true
        defer { isGenerating = false }

        let generator = SessionGenerator(client: try? ClaudeClient.fromBundle())
        planned = await generator.plan(
            SessionRequest(
                rounds: 3,
                focus: "sharpening the jab",
                profile: TrainingProfile(
                    level: .beginner,
                    recentFocuses: ["Straight punches", "Hooks"],
                    notes: ["Said 'too fast' during hook drills last session"]
                )
            )
        )
    }

    private func summary(of session: Session) -> String {
        let seconds = session.rounds.reduce(0) { $0 + $1.durationSeconds + $1.restSeconds }
        return "\(session.rounds.count) rounds · \(seconds / 60) min"
    }

    private func load() {
        do {
            sessions = try BundledSessions.load()
        } catch {
            problem = "Couldn't load sessions: \(error.localizedDescription)"
        }
    }

    private func launch(_ session: Session) async {
        problem = nil

        guard await audioSession.requestMicrophoneAccess() else {
            problem = "Microphone access is required. Enable it in Settings."
            return
        }
        guard await requestSpeechAccess() else {
            problem = "Speech recognition access is required. Enable it in Settings."
            return
        }

        // Must precede the recognizer: the audio engine's input node reports a zero
        // sample rate until the session is active.
        do {
            try audioSession.activate()
        } catch {
            problem = "Couldn't start audio: \(error.localizedDescription)"
            return
        }

        live = SessionEngine(
            session: session,
            voice: Cornerman(),
            recognizer: SpeechAnalyzerRecognizer()
        )
    }

    private func requestSpeechAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

extension SessionEngine: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

#Preview {
    ContentView()
}
