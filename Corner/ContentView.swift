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

    /// Whose data this screen is showing. Everything below is scoped to it.
    private let userID: String

    /// Newest first — the order the profile builder and the history list both want.
    @Query private var history: [TrainingRecord]

    /// Today's plan, persisted so it survives a relaunch mid-session.
    @Query private var plans: [TodaySession]

    /// The filters are built here rather than declared on the properties,
    /// because a `@Query` predicate has to close over the signed-in user and a
    /// property initialiser can't see one. Without this every account on a
    /// shared phone would read the last one's history as its own.
    init(userID: String) {
        self.userID = userID
        _history = Query(
            filter: #Predicate<TrainingRecord> { $0.userID == userID },
            sort: \TrainingRecord.date,
            order: .reverse
        )
        _plans = Query(
            filter: #Predicate<TodaySession> { $0.userID == userID },
            sort: \TodaySession.generatedAt,
            order: .reverse
        )
    }
    @Environment(\.modelContext) private var modelContext
    @AppStorage(TrainingProfile.levelKey) private var level: String = TrainingProfile.Level.beginner.rawValue
    @AppStorage(CoachingNotes.key) private var notesData: Data = Data()

    @State private var live: SessionEngine?
    @State private var problem: String?
    @State private var planned: PlannedSession?
    @State private var isGenerating = false
    @State private var showingSetup = false
    @State private var request = SessionRequest()

    @Environment(AuthController.self) private var auth

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

            // The detached button beside the bar, and it's a real tab role
            // rather than anything drawn by hand: iOS 26 lifts a `.search` tab
            // out of the bar and renders it as its own circle on the trailing
            // edge. Cal AI spends that slot on compose instead of search, which
            // is what this is.
            //
            // The content is never seen. Selecting this tab is an *action*, not
            // a destination — `bounce(to:)` below opens the setup sheet and puts
            // the selection straight back where it was, so the bar never shows a
            // fifth page as current.
            Tab(value: Page.create, role: .search) {
                Color.clear
            } label: {
                // White, against the accent the other four carry. The bar's
                // tint is the brand red; this one control is the app's primary
                // action and reads as a separate object, so it takes its own
                // ink. On the label rather than the `Tab` — `Tab` isn't a view.
                Label("New session", systemImage: "plus")
                    .tint(.white)
            }
        }
        .onChange(of: page) { previous, current in
            guard current == .create else { return }
            page = previous == .create ? .home : previous

            // One session a day. With today's still unfinished the button
            // resumes it rather than writing over it, and with today's finished
            // it says so instead of quietly doing nothing — a button that
            // ignores you is worse than one that answers.
            if unfinishedToday != nil {
                resumeToday()
            } else if todayPlan != nil {
                problem = "Today's session is done. The next one is tomorrow."
            } else {
                showingSetup = true
            }
        }
        // All four tabs, all the time. The iOS 26 minimize gesture collapses the
        // bar to the selected tab alone as you scroll, which reads as the other
        // three having disappeared — and this app's whole navigation is four
        // destinations wide. Trading that legibility for a few points of list
        // height isn't worth it here.
        .tabBarMinimizeBehavior(.never)
        .tint(Theme.Palette.accent)
        // The chrome is dark; the live timer pins itself back to light, because a
        // pale screen across a gym is the one thing that screen is for.
        .preferredColorScheme(.dark)
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
        .task {
            claimLegacyRecords()
            // Claim first, then sync: a legacy record with no owner would
            // otherwise be pushed under an empty user id, which RLS rejects.
            await SessionSync(auth: auth, context: modelContext).run()
        }
    }

    /// Every tab gets its own stack and a large title, which is the other half
    /// of what "native" means here: the title used to be the widest pill in our
    /// own bar, and now it's where iOS puts it — collapsing into the nav bar as
    /// you scroll, without us animating anything.
    ///
    /// Home is the exception. It carries a branded header of its own — mark and
    /// wordmark on the left, streak on the right — and a large "Home" sitting
    /// above that would be two titles stacked, naming the same screen twice.
    private func destination<Content: View>(
        _ page: Page,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .navigationTitle(page == .home ? "" : page.title)
                .navigationBarTitleDisplayMode(page == .home ? .inline : .large)
                .background(Theme.Palette.background)
        }
    }

    /// Hands sessions recorded before accounts existed to whoever signs in
    /// first.
    ///
    /// They carry an empty owner, so the filtered queries above can't see them —
    /// without this, upgrading the app would look exactly like losing every
    /// session ever trained. Assigning them to the current user is the only
    /// answer available: nothing recorded who trained them, and on a phone with
    /// one owner it's also the right one.
    private func claimLegacyRecords() {
        guard !userID.isEmpty else { return }

        let records = FetchDescriptor<TrainingRecord>(predicate: #Predicate { $0.userID == "" })
        let plans = FetchDescriptor<TodaySession>(predicate: #Predicate { $0.userID == "" })

        guard let orphanedRecords = try? modelContext.fetch(records),
              let orphanedPlans = try? modelContext.fetch(plans),
              !(orphanedRecords.isEmpty && orphanedPlans.isEmpty)
        else { return }

        for record in orphanedRecords { record.userID = userID }
        for plan in orphanedPlans { plan.userID = userID }
        try? modelContext.save()
    }

    /// Today's plan, if one was written today. One a day is the rule: the
    /// cornerman writes a session in the morning and you train it, rather than
    /// rerolling until you get one you like — which is how a training app turns
    /// into a slot machine.
    private var todayPlan: TodaySession? {
        plans.first { Calendar.current.isDateInToday($0.generatedAt) }
    }

    /// Rounds finished today, across however many sittings it took.
    private var roundsDoneToday: Int {
        history
            .filter { Calendar.current.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.roundsCompleted }
    }

    /// What's left of today, or nil when today is done or was never started.
    ///
    /// Nil rather than zero on a finished day: "nothing left" and "no session"
    /// are different states and the Home screen shows different things for them.
    private var unfinishedToday: (plan: TodaySession, done: Int)? {
        guard let plan = todayPlan, roundsDoneToday < plan.roundCount else { return nil }
        return (plan, roundsDoneToday)
    }

    /// Picks up where the session stopped.
    ///
    /// The rounds already finished are dropped off the front rather than the
    /// engine being taught to start midway — `Session` is a plain struct, so the
    /// remainder *is* a session, and the engine runs it without knowing it's a
    /// second sitting.
    private func resumeToday() {
        guard let (plan, done) = unfinishedToday, let session = plan.session else { return }

        let remaining = Array(session.rounds.dropFirst(done))
        guard !remaining.isEmpty else { return }

        Task {
            await launch(
                Session(
                    id: session.id,
                    title: session.title,
                    // No intro on a resume. It's the "here's what today is for"
                    // line, and you've already heard it — replaying it would
                    // make the second half sound like a different workout.
                    intro: nil,
                    rounds: remaining
                )
            )
        }
    }

    /// How much of each day's planned work got finished, 0 to 1.
    ///
    /// Summed across the day rather than averaged per session: two sessions of
    /// four rounds each, one abandoned after one round, is five rounds out of
    /// eight — not the midpoint of 100% and 25%. The day is the unit here
    /// because the day is what the calendar draws.
    ///
    /// Sessions with nothing planned are counted as finished. That's the honest
    /// reading: a session with no plan can't have fallen short of one, and
    /// dividing by zero to find out would be worse.
    private var dayProgress: [Date: Double] {
        let calendar = Calendar.current
        var planned: [Date: Int] = [:]
        var completed: [Date: Int] = [:]

        for record in history {
            let day = calendar.startOfDay(for: record.date)
            planned[day, default: 0] += max(record.roundsPlanned, record.roundsCompleted)
            completed[day, default: 0] += record.roundsCompleted
        }

        return planned.reduce(into: [:]) { result, entry in
            let (day, total) = entry
            let done = completed[day] ?? 0
            result[day] = total > 0 ? min(Double(done) / Double(total), 1) : 1
        }
    }

    /// The masthead: who the app is, and the one number that says whether you're
    /// keeping at it.
    ///
    /// The streak rather than any of the other four stats, and on the header
    /// rather than only in the grid below, because it's the number that changes
    /// how you feel about opening the app — the total minutes are a record, the
    /// streak is a stake.
    private var header: some View {
        HStack(spacing: 10) {
            // Placeholder mark. A rounded square at icon proportions so the real
            // artwork can drop straight in without the row reflowing around it.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.Palette.accent)
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: "figure.boxing")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }

            Text("Corner")
                .font(.title.weight(.bold))
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            streakPill
        }
        .padding(.horizontal, 4)
    }

    /// The masthead and the calendar under it, as one block.
    ///
    /// The strip is deliberately not inset with the header: it scrolls, and a
    /// scrolling row that stops short of the screen edge reads as clipped rather
    /// than as continuing. The header keeps its margin, the strip runs full
    /// width, and the negative inset undoes the padding they'd otherwise share.
    private var masthead: some View {
        VStack(alignment: .leading, spacing: 26) {
            header

            WeekStrip(progress: dayProgress)
                .padding(.horizontal, -16)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var streakPill: some View {
        let streak = TrainingStats.from(history: history).streak
        return HStack(spacing: 5) {
            Image(systemName: "flame.fill")
                // The flame carries the accent whether or not the streak is
                // alive: a grey flame next to a zero reads as a broken feature
                // rather than as a streak waiting to start.
                .foregroundStyle(Theme.Palette.accent)
                .font(.system(size: 14, weight: .bold))

            Text("\(streak)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(Theme.Palette.surface, in: .capsule)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(streak == 1 ? "1 day streak" : "\(streak) day streak")
    }

    // MARK: - Home

    private var homePage: some View {
        List {
            Section {
                masthead
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
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
                VStack(spacing: 20) {
                    SummaryCards(stats: TrainingStats.from(history: history))
                    RecentSessions(
                        history: history,
                        unfinished: unfinishedToday.map {
                            .init(title: $0.plan.focus, done: $0.done, total: $0.plan.roundCount)
                        },
                        onResume: resumeToday
                    )
                }
                    // Zero, not 16. The list style already insets the section,
                    // and any row inset is charged on top of that — the cards
                    // were paying the margin twice and coming out narrow.
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listSectionMargins(.horizontal, 16)

        }
        .scrollContentBackground(.hidden)
        // The calendar inside the masthead already hides its own indicator; this
        // is the page's. A bar tracking down the edge of a screen this short is
        // chrome that reports something the content already makes obvious.
        .scrollIndicators(.hidden)
        // 8, the same gap the dashboard tiles use between each other. The row
        // insets above only control padding *inside* a section — the space
        // between two sections is this, and left at its default it was reading
        // as a break between two screens rather than a gap between two cards.
        .listSectionSpacing(SummaryCards.gap)
    }

    private func generate() async {
        isGenerating = true
        defer { isGenerating = false }

        // Everything here is now real: the request is what the user picked in
        // the sheet, and the profile is derived from sessions they finished.
        var request = self.request
        request.profile = profile

        let generator = SessionGenerator(client: try? ClaudeClient.fromBundle())
        let session = await generator.plan(request)
        planned = session

        // Stored before it runs, not after: the point is that a session
        // abandoned halfway — or interrupted by a crash — can still be found and
        // finished. Written at the end it would only ever record what already
        // worked.
        modelContext.insert(TodaySession(planned: session, userID: userID))
        try? modelContext.save()

        // Straight into the workout. The Today card used to sit between these
        // two steps — it held the written session and waited for a second tap
        // on Start. With the card gone the sheet is the whole decision, so
        // "Write it" means write it and go.
        await launch(session.session)
    }

    /// Records what happened, so the next session can differ from this one.
    ///
    /// Only sessions with a completed round count — abandoning at the setup
    /// screen shouldn't teach the cornerman anything.
    private func record(_ summary: SessionSummary) {
        guard summary.roundsCompleted > 0 else { return }
        modelContext.insert(TrainingRecord(summary: summary, userID: userID))
        // A dropped session is a lost lesson; surface it rather than swallow it.
        do { try modelContext.save() } catch {
            problem = "Couldn't save this session to your history: \(error.localizedDescription)"
        }

        // Straight up to the account. Waiting for the next launch would mean a
        // fighter who finishes a session and switches phones loses it — and the
        // record is already safe locally, so a failure here costs nothing but a
        // later retry.
        Task { await SessionSync(auth: auth, context: modelContext).run() }
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
        // `nonisolated(nonsending)` is *not* what's wanted here, and neither is
        // plain inference: the project builds with
        // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which pins this closure to
        // the main actor — but `requestAuthorization` calls back on an arbitrary
        // background queue. Swift 6 compiles that isolation into a runtime queue
        // assertion, so the callback trapped in `_dispatch_assert_queue_fail`
        // every single time Start was tapped. `@Sendable` opts the closure out of
        // the default isolation, which is the truth: it runs wherever Speech says.
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

extension SessionEngine: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

#Preview {
    ContentView(userID: "preview")
        .environment(AuthController())
}
