import AVFoundation
import Speech
import SwiftData
import SwiftUI

/// Home. Not yet the hero card the plan calls for, but no longer scaffolding:
/// every input the cornerman sees now comes from the user or their history.
struct ContentView: View {

    /// Newest first — the order the profile builder and the history list both want.
    @Query(sort: \TrainingRecord.date, order: .reverse) private var history: [TrainingRecord]
    @Environment(\.modelContext) private var modelContext
    @AppStorage(TrainingProfile.levelKey) private var level: String = TrainingProfile.Level.beginner.rawValue

    @State private var sessions: [Session] = []
    @State private var live: SessionEngine?
    @State private var problem: String?
    @State private var planned: PlannedSession?
    @State private var isGenerating = false
    @State private var showingSettings = false
    @State private var showingSetup = false
    @State private var request = SessionRequest()

    private let audioSession = AudioSessionController()

    /// Built fresh from real history every time it's read — what they drilled,
    /// what they asked for, what they didn't finish. Nothing invented.
    private var profile: TrainingProfile {
        TrainingProfile.from(
            history: history,
            level: TrainingProfile.Level(rawValue: level) ?? .beginner
        )
    }

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

                Section("What the cornerman knows about you") {
                    whatItKnows
                }

                if !history.isEmpty {
                    Section("History") {
                        ForEach(history) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.title)
                                    .font(.subheadline.weight(.medium))
                                Text("\(record.roundsCompleted)/\(record.roundsPlanned) rounds \u{00B7} \(record.date.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                        }
                        .onDelete(perform: delete)
                    }
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
            .sheet(isPresented: $showingSetup) {
                SessionSetupSheet(request: $request) {
                    Task { await generate() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { load() }
        .fullScreenCover(item: $live) { engine in
            LiveSessionView(engine: engine) { summary in
                record(summary)
            }
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
            Button("Write me a session") {
                showingSetup = true
            }
            .foregroundStyle(Theme.Palette.accent)
        }
    }

    /// What the cornerman actually knows about you. Shown because "the AI
    /// learns from your sessions" is a claim, and a claim you can't inspect is
    /// indistinguishable from a lie.
    @ViewBuilder
    private var whatItKnows: some View {
        if history.isEmpty {
            Text("Nothing yet. It learns from sessions you finish.")
                .font(.footnote)
                .foregroundStyle(Theme.Palette.secondaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !profile.recentFocuses.isEmpty {
                    Text("You've drilled: \(profile.recentFocuses.prefix(5).joined(separator: ", "))")
                }
                ForEach(profile.notes, id: \.self) { note in
                    Text(note)
                }
            }
            .font(.footnote)
            .foregroundStyle(Theme.Palette.secondaryText)
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

        // Everything here is now real: the request is what the user picked in
        // the sheet, and the profile is derived from sessions they finished.
        var request = self.request
        request.profile = profile

        let generator = SessionGenerator(client: try? ClaudeClient.fromBundle())
        planned = await generator.plan(request)
    }

    /// Records what happened, so the next session can differ from this one.
    ///
    /// Only sessions with a completed round count — abandoning at the setup
    /// screen shouldn't teach the cornerman anything.
    private func record(_ summary: SessionSummary) {
        guard summary.roundsCompleted > 0 else { return }
        modelContext.insert(TrainingRecord(summary: summary))
        // A dropped session is a lost lesson; surface it rather than swallow it.
        do { try modelContext.save() } catch {
            problem = "Couldn't save this session to your history: \(error.localizedDescription)"
        }
    }

    private func summary(of session: Session) -> String {
        let seconds = session.rounds.reduce(0) { $0 + $1.durationSeconds + $1.restSeconds }
        return "\(session.rounds.count) rounds · \(seconds / 60) min"
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { modelContext.delete(history[index]) }
        try? modelContext.save()
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

        // The real voice when there's a key, the on-device one otherwise — and
        // the on-device one is also ElevenLabs' fallback if the network dies
        // mid-session.
        let native = Cornerman()
        let voice: any Voice = ElevenLabsVoice.fromBundle(fallback: native) ?? native

        live = SessionEngine(
            session: session,
            voice: voice,
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
