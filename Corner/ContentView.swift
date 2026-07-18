import AVFoundation
import Speech
import SwiftData
import SwiftUI

/// The shell: the system tab bar, and whichever of the four pages it's pointing
/// at.
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
        // The system tab bar, not a facsimile of one. The pills we drew at the
        // top were a tab bar in everything but provenance — they cost us the
        // scroll-edge behaviour, the minimise-on-scroll, the accessibility
        // wiring and the large titles, all of which arrive free here.
        TabView(selection: $page) {
            Tab(Page.home.title, systemImage: Page.home.icon, value: .home) {
                destination(Page.home) { homePage }
            }
            Tab(Page.coach.title, systemImage: Page.coach.icon, value: .coach) {
                destination(.coach) { CoachPage(profile: profile) }
            }
            Tab(Page.history.title, systemImage: Page.history.icon, value: .history) {
                destination(.history) { HistoryPage(history: history, onDelete: delete) }
            }
            Tab(Page.settings.title, systemImage: Page.settings.icon, value: .settings) {
                destination(.settings) { SettingsView() }
            }
        }
        // The bar gets out of the way as you read down a list and comes back the
        // moment you reach for it — the behaviour every iOS 26 app has, which is
        // exactly the point of being native.
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(Theme.Palette.accent)
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

    /// Every tab gets its own stack and a large title, which is the other half
    /// of what "native" means here: the title used to be the widest pill in our
    /// own bar, and now it's where iOS puts it — collapsing into the nav bar as
    /// you scroll, without us animating anything.
    private func destination<Content: View>(
        _ page: Page,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .navigationTitle(page.title)
                .background(Theme.Palette.background)
        }
    }

    // MARK: - Home

    private var homePage: some View {
        List {
            // Always present, in all three states — that's what lets it be the
            // only call to action on the screen. There used to be a "Today"
            // section that appeared only once a session existed, and a red
            // button pinned to the bottom for when one didn't; the card is both,
            // so neither is here any more.
            Section {
                TodaySessionCard(
                    state: cardState,
                    onStart: start,
                    onRegenerate: { showingSetup = true }
                )
                // Same insets as the dashboard below: the list style already
                // insets the section, and a row inset is charged on top of it.
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 12, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listSectionMargins(.horizontal, 16)

            // Directly under the card rather than at the foot of the screen: a
            // failure to write today's session is about the card, and an error
            // parked below the dashboard is an error nobody reads.
            if let problem {
                Section {
                    Text(problem)
                        .font(.subheadline)
                        .foregroundStyle(.red)
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

        }
        .scrollContentBackground(.hidden)
    }

    /// Home's three states, in the card's terms. The order matters: generating
    /// wins over a session already on screen, so asking for "something else"
    /// puts the card straight into its loading state rather than leaving the old
    /// session sitting there looking startable.
    private var cardState: TodaySessionCard.State {
        if isGenerating { return .loading }
        guard let planned else { return .empty }

        let session = planned.session
        return .ready(
            TodaySessionCard.Plan(
                // The first round's focus: the session's opening intent, and the
                // closest the plan has to a one-word answer to "what's today?".
                focus: session.rounds.first?.focus ?? session.title,
                subtitle: session.intro ?? session.title,
                roundCount: session.rounds.count,
                totalSeconds: session.rounds.reduce(0) { $0 + $1.durationSeconds + $1.restSeconds },
                origin: planned.origin
            )
        )
    }

    /// Bridges the card's plain closure to the async launch.
    private func start() {
        guard let planned else { return }
        Task { await launch(planned.session) }
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
