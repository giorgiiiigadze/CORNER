import AVFoundation
import Speech
import SwiftData
import SwiftUI

/// The shell: the header, and whichever of the three pages it's pointing at.
///
/// Session state lives here rather than in `HomePage` because it outlives the
/// page — you can wander to History mid-generation and come back to a finished
/// session.
struct ContentView: View {

    @State private var page = Page.home

    /// Newest first — the order the profile builder and the history list both want.
    @Query(sort: \TrainingRecord.date, order: .reverse) private var history: [TrainingRecord]
    @Environment(\.modelContext) private var modelContext
    @AppStorage(TrainingProfile.levelKey) private var level: String = TrainingProfile.Level.beginner.rawValue
    @AppStorage(CoachingNotes.key) private var notesData: Data = Data()

    @State private var live: SessionEngine?
    @State private var problem: String?
    @State private var planned: PlannedSession?
    @State private var isGenerating = false
    @State private var showingSetup = false
    @State private var request = SessionRequest()

    private let audioSession = AudioSessionController()

    /// Built fresh from real history every time it's read — what they drilled,
    /// what they asked for, what they didn't finish, and what they told the
    /// Coach page outright. Nothing invented.
    private var profile: TrainingProfile {
        TrainingProfile.from(
            history: history,
            level: TrainingProfile.Level(rawValue: level) ?? .beginner,
            standing: CoachingNotes.decode(notesData).map(\.text)
        )
    }

    var body: some View {
        // A paging TabView rather than a `switch`, so the pages can also be
        // swiped between. Same binding as the header, so tapping a pill and
        // swiping are the same gesture by other means. The dots are off —
        // the header is already the indicator.
        TabView(selection: $page) {
            homePage
                .tag(Page.home)
            CoachPage(profile: profile)
                .tag(Page.coach)
            HistoryPage(history: history, onDelete: delete)
                .tag(Page.history)
            SettingsView()
                .tag(Page.settings)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // `safeAreaInset` rather than stacking the header above this in a VStack:
        // it reserves the header's height so nothing starts underneath it, while
        // still letting the lists scroll *behind* it. That second half is what
        // the header's material has to blur — in a VStack there's nothing back
        // there but flat colour, and a blur over flat colour is just colour.
        .safeAreaInset(edge: .top, spacing: 0) {
            CornerHeader(page: $page)
        }
        .background(Theme.Palette.background)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showingSetup) {
            SessionSetupSheet(request: $request) {
                Task { await generate() }
            }
        }
        .fullScreenCover(item: $live) { engine in
            LiveSessionView(engine: engine) { summary in
                record(summary)
            }
        }
        // Hand the audio back when the workout screen goes away.
        //
        // `activate` claims `.playAndRecord` with `.duckOthers`, and nothing was
        // ever giving it up: the session stayed live for the rest of the app's
        // life, so the music the fighter was training to stayed quiet after they
        // finished, until they force-quit. `deactivate` is also the only thing
        // that removes the interruption observers.
        //
        // On dismissal rather than in `end()`, because the session ends by three
        // different routes and this has to happen on all of them.
        .onChange(of: live == nil) { _, gone in
            if gone { audioSession.deactivate() }
        }
    }

    // MARK: - Home

    private var homePage: some View {
        List {
            // Only when there's something to say. With no session written yet
            // the call to action is the fixed bar below, not a row up here —
            // an empty "Today" would just be a heading over nothing.
            if isGenerating || planned != nil {
                Section("Today") {
                    todaysSession
                }
            }

            // Under today's session rather than over it. Home's job is to get a
            // fighter training in two taps, and the dashboard is the reason to
            // train, not the way — a screen that leads with last week's numbers
            // asks you to read before it lets you work.
            Section {
                SummaryCards(stats: TrainingStats.from(history: history))
                    // Zero, not 16. The list style already insets the section,
                    // and any row inset is charged on top of that — the cards
                    // were paying the margin twice and coming out narrow.
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listSectionMargins(.horizontal, 16)

            if let problem {
                Section("Problem") {
                    Text(problem).foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        // iOS 26 washes the edges of a scroll view where it meets a bar, and
        // ours meets one it doesn't know about: the header is a `safeAreaInset`,
        // so the system tints behind it, and pours the same wash at the bottom
        // where there's no bar at all — an empty slab over the last card. The
        // header is meant to be pills and nothing else, so both go.
        .scrollEdgeEffectHidden(true, for: .all)
        // Pinned under the list rather than in it, so the call to action is
        // under the thumb no matter where the scroll ended up.
        .safeAreaInset(edge: .bottom) {
            if !isGenerating && planned == nil {
                writeSessionButton
            }
        }
    }

    /// The start of everything, in the brand red the timer shares.
    private var writeSessionButton: some View {
        Button {
            showingSetup = true
        } label: {
            Text("Write me a session")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Theme.Palette.accent, in: Capsule())
        }
        .padding(.horizontal, Theme.Layout.gutter)
        .padding(.bottom, 8)
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
            recognizer: SpeechAnalyzerRecognizer(),
            // Same key as the session writer, and the same shrug when there
            // isn't one: no key means the phrase list, which still works.
            intent: CommandInterpreter(client: try? ClaudeClient.fromBundle())
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
