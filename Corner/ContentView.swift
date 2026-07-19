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

    /// On by default: a cornerman who says nothing is a timer, and the coaching
    /// is what the app is for. Turning it off is a choice, not the starting
    /// point.
    @AppStorage(SessionEngine.coachingKey) private var speaksCoaching: Bool = true

    @State private var live: SessionEngine?
    @State private var problem: String?
    @State private var planned: PlannedSession?
    @State private var isGenerating = false
    @State private var showingSetup = false
    @State private var request = SessionRequest()

    /// The day the dashboard is showing, or nil for running totals.
    @State private var selectedDay: Date?

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
            Tab(Page.profile.title, systemImage: Page.profile.icon, value: .profile) {
                destination(.profile) { ProfilePage(history: history) }
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

            // Always a new session. Train twice in a day if you want to — the
            // cornerman's job is to write what you ask for, not to ration it.
            //
            // Picking up an unfinished session is still possible and is the
            // Resume row's job. Two controls, two meanings: this one writes,
            // that one continues. It used to be one button guessing between
            // them, which meant a fighter who wanted a second session got given
            // the first one back.
            showingSetup = true
        }
        // All four tabs, all the time. The iOS 26 minimize gesture collapses the
        // bar to the selected tab alone as you scroll, which reads as the other
        // three having disappeared — and this app's whole navigation is four
        // destinations wide. Trading that legibility for a few points of list
        // height isn't worth it here.
        .tabBarMinimizeBehavior(.never)
        // White for the selected tab, not the brand red.
        //
        // The accent had four jobs on this screen — the trained ring, the
        // highlighted bar, the streak flame, the session button — and a fifth
        // spent on "which tab am I looking at" made none of them mean anything
        // in particular. Ink for navigation, red for the training.
        .tint(.white)
        // The chrome is dark; the live timer pins itself back to light, because a
        // pale screen across a gym is the one thing that screen is for.
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingSetup) {
            SessionSetupSheet(request: $request) {
                Task { await generate() }
            }
            // Tint is inherited, and the bar's is now white — which would leave
            // the sheet's "Write it" white on white. The accent belongs here:
            // this is the action that starts training.
            .tint(Theme.Palette.accent)
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
        // Keyed on the id rather than fired once on appear. `userID` arrives
        // from a network round-trip, and this view can be built in a frame where
        // it's still empty — a bare `.task` would then claim nothing, and since
        // the queries above hide unowned records, every session ever trained
        // would look deleted. Re-running when the id lands fixes that, and the
        // empty guard inside means the early pass costs nothing.
        .task(id: userID) {
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
    /// Home and Profile are the exceptions. Home's title is its toolbar; the
    /// Profile page opens with an avatar and a name, and a large "Profile"
    /// above that names the screen twice while pushing the face off the fold.
    private func destination<Content: View>(
        _ page: Page,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .navigationTitle(page.showsLargeTitle ? page.title : "")
                .navigationBarTitleDisplayMode(page.showsLargeTitle ? .large : .inline)
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

    /// Rounds finished against one plan, across however many sittings it took.
    ///
    /// Per plan, not per day. Counting the day's total was right while a day
    /// held one session and wrong the moment it could hold two: finishing an
    /// eight-round session and then starting a six-round one left the day's
    /// count already past the second plan's total, so a session you'd barely
    /// begun reported itself complete and the Resume row never appeared.
    private func roundsDone(against plan: TodaySession) -> Int {
        history
            .filter { $0.sessionID == plan.sessionID }
            .reduce(0) { $0 + $1.roundsCompleted }
    }

    /// What's left of the latest plan, or nil when it's finished or was never
    /// started.
    ///
    /// Nil rather than zero on a finished session: "nothing left" and "nothing
    /// started" are different states and Home shows different things for them.
    private var unfinishedToday: (plan: TodaySession, done: Int)? {
        guard let plan = todayPlan else { return nil }

        // An empty id can't be matched to any record, so it would always read as
        // untouched and offer to resume a session already trained. Plans written
        // before sessions were linked are the only ones like this.
        guard !plan.sessionID.isEmpty else { return nil }

        let done = roundsDone(against: plan)
        guard done < plan.roundCount else { return nil }
        return (plan, done)
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

    /// The picked day's numbers, gathered from the same history the dashboard
    /// already reads. Nil when nothing is picked, which is what puts the cards
    /// back on the running totals.
    ///
    /// Built even for a day with no sessions: "0 rounds, rest day" is an answer,
    /// and falling back to the totals would silently ignore the tap.
    private var selectedDayStats: SummaryCards.Day? {
        guard let selectedDay else { return nil }

        let calendar = Calendar.current
        let onThatDay = history.filter { calendar.isDate($0.date, inSameDayAs: selectedDay) }

        return SummaryCards.Day(
            date: selectedDay,
            // Floored, and summed in seconds first — the same arithmetic
            // `TrainingStats` uses, so a day's figure can't disagree with the
            // total it contributes to.
            minutes: onThatDay.reduce(0) { $0 + ($1.sessionSeconds ?? 0) } / 60,
            rounds: onThatDay.reduce(0) { $0 + $1.roundsCompleted },
            sessions: onThatDay.count
        )
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

    /// The two controls in Home's navigation bar.
    ///
    /// Written the way Apple's own are: a `Button` with a title and a system
    /// image, and nothing else. Toolbar items take Liquid Glass, their metrics
    /// and their hit targets from the system on iOS 26 — the first version of
    /// this set an explicit 52×30 frame inside each one and applied
    /// `.buttonStyle(.glass)` by hand, which fought the sizing the bar was
    /// already doing and produced two stretched lozenges that looked like
    /// nothing else on the phone.
    ///
    /// The rule that follows: don't dress a toolbar item. Give it a label and
    /// let the bar shape it.
    @ToolbarContentBuilder
    private var homeBar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            // Nothing yet. Reminders are the obvious home for this — "you
            // haven't trained since Tuesday" — and the bell is here because the
            // layout was asked for, not because that exists.
            Button {} label: {
                Image(systemName: "bell.fill")
                    // Padding on the label, not a frame on the button.
                    //
                    // `.controlSize(.extraLarge)` and `.buttonBorderShape(...)`
                    // are the documented levers and neither does anything in
                    // this placement — both were tried and both were no-ops. The
                    // glass capsule hugs whatever it's given, so widening the
                    // content is what widens the button, and the system still
                    // owns the height, the material and the corner radius.
                    .padding(.horizontal, 10)
            }
            .accessibilityLabel("Reminders")
        }

        ToolbarItem(placement: .topBarTrailing) {
            // A button despite being a readout: a toolbar sizes a bare label
            // differently from a control, and the two stop looking like a pair.
            // A hand-built label, because a toolbar collapses `Label` to
            // icon-only in this placement and `labelStyle` doesn't survive it —
            // tried on the label and on the button, neither took. A flame with
            // no number is most of a streak missing.
            //
            // What isn't hand-built is the size: no frame, no button style. The
            // glass sizes itself around whatever it's given, and the first
            // version's fixed 52×30 is exactly what made these look wrong.
            Button {} label: {
                HStack(spacing: 5) {
                    Image(systemName: "flame.fill")
                    Text("\(TrainingStats.from(history: history).streak)")
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 6)
            }
            .accessibilityLabel("Training streak")
        }
    }

    /// The calendar, full width.
    ///
    /// Not inset with the rest of the screen: it scrolls, and a scrolling row
    /// that stops short of the edge reads as clipped rather than as continuing.
    /// The negative inset undoes the margin the section would otherwise apply.
    private var masthead: some View {
        WeekStrip(progress: dayProgress, selection: $selectedDay)
            .padding(.horizontal, -16)
            .padding(.bottom, 10)
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
                    SummaryCards(stats: TrainingStats.from(history: history), day: selectedDayStats)
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
        .toolbar { homeBar }
        // The list's own top inset, trimmed. It's sized for a large title, and
        // Home doesn't have one — the calendar was sitting a title's worth of
        // space below a bar with nothing in it but two buttons.
        .contentMargins(.top, 4, for: .scrollContent)
        .scrollContentBackground(.hidden)
        // The iOS 26 scroll-edge effect, on the top edge only. Content was
        // passing under the status bar with nothing between them — the clock and
        // the battery sitting directly on a moving dashboard, which is what made
        // scrolling look wrong.
        //
        // `.soft` rather than `.hard`: soft fades the blur out over a short
        // distance, hard draws a defined edge. There's no navigation bar here to
        // draw an edge under — Home's title is its own masthead — so a line
        // would be a border around nothing.
        .scrollEdgeEffectStyle(.soft, for: .top)
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

        let generator = SessionGenerator(client: ClaudeClient.viaProxy(token: { [auth] in await auth.token() }))
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
        // The token closure is the whole seam: the voice never sees a vendor
        // key, only proof that someone is signed in.
        let voice: any Voice = ElevenLabsVoice.viaProxy(
            fallback: native,
            token: { [auth] in await auth.token() }
        )

        live = SessionEngine(
            session: session,
            voice: voice,
            recognizer: SpeechAnalyzerRecognizer(),
            speaksCoaching: speaksCoaching,
            // Same key as the session writer, and the same shrug when there
            // isn't one: no key means the phrase list, which still works.
            intent: CommandInterpreter(client: ClaudeClient.viaProxy(token: { [auth] in await auth.token() }))
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
