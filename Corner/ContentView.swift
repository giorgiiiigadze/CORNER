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

    /// The "get ready" beat before the first bell. Handed to the engine at build
    /// time, the same way the coaching preference is.
    @AppStorage(SessionEngine.countdownKey) private var countdownSeconds: Int = 3

    /// The live screen, from the tap that asks for a session to the end of it.
    ///
    /// Not the engine any more. The engine can't exist until the plan does, and
    /// the whole point is that the screen goes up before that — so this is
    /// present from the moment "Write it" is tapped, carrying the engine once
    /// there's one to carry. Nil means no session screen, which is the only
    /// thing the rest of this file ever asked it.
    @State private var live: SessionLaunch?

    /// The write itself, held so backing out can cancel it. Without this a
    /// cancelled session still finishes writing in the background and shoulders
    /// its way onto the screen a few seconds later.
    @State private var writing: Task<Void, Never>?

    @State private var problem: String?
    @State private var showingSetup = false
    @State private var request = SessionRequest()

    /// The day the dashboard is showing, or nil for running totals.
    @State private var selectedDay: Date?

    /// Whether the welcome sheet has been seen. Once, ever — not per account:
    /// it explains how the app works, and the app doesn't work differently for
    /// the second person to sign in on the same phone.
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome: Bool = false

    /// Whether it's on screen right now. Separate from `hasSeenWelcome` because
    /// the sheet doesn't appear the instant it's owed — see `offerWelcome`.
    @State private var showingWelcome = false

    /// First-run setup for a brand-new account: the intro, a name, Apple Health.
    /// Driven by `auth.isNewAccount`, which only a sign-up sets — a returning
    /// fighter signing in goes straight to Home.
    @State private var showingOnboarding = false

    /// Whether the splash is still up. Home is built and running underneath it,
    /// so this is the only honest signal that the fighter can see anything.
    @Environment(\.isLaunching) private var isLaunching

    @Environment(AuthController.self) private var auth

    /// The initials disc, rasterised for the profile tab. Nil until it's built,
    /// and nil when there's no identity — the tab shows the person icon then.
    @State private var profileTabIcon: Image?

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
            Tab(Page.history.title, systemImage: Page.history.icon, value: .history) {
                destination(.history) {
                    HistoryPage(history: history, onDelete: delete)
                }
            }
            // The profile tab wears the user's own mark, the way X puts your
            // avatar in the tab bar rather than a generic silhouette. It's the
            // initials disc — there's no uploaded photo in the app yet — and it
            // falls back to the person icon when there's no identity to build one
            // from. A tab item has to be an `Image`, so the disc is rasterised
            // into `profileTabIcon` and refreshed only when the identity changes.
            Tab(value: Page.profile) {
                destination(.profile) { ProfilePage(history: history) }
            } label: {
                Label {
                    Text(Page.profile.title)
                } icon: {
                    if let profileTabIcon {
                        profileTabIcon
                    } else {
                        Image(systemName: Page.profile.icon)
                    }
                }
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
            // The "+" that used to sit here, in the search slot, is gone. The bar
            // is navigation now and nothing else — a tab whose selection was an
            // action rather than a destination was the one control on it that
            // didn't behave like a tab. Writing a session is still Home's job.
        }
        // The open session lives in the iOS 26 accessory slot above the tab bar,
        // where Apple Music keeps Now Playing — present on every tab while
        // there's a session to resume, and *gone entirely* when there isn't.
        //
        // The modifier is applied conditionally rather than always-on with an
        // empty closure: returning no content from `tabViewBottomAccessory`
        // doesn't reliably collapse the bar — it can leave an empty glass
        // sliver above the tab bar. Only not applying the modifier at all
        // guarantees nothing is there. See `sessionAccessory` below.
        //
        // This replaces the green pill that sat on Home. A session in progress
        // isn't a Home thing; it's a state the whole app is in, and the
        // accessory is the one piece of chrome that's present regardless of
        // which tab you're on.
        // Every tab. A session in progress is a state the whole app is in, not a
        // Home thing — and keeping it on one tab was what made the bar grow and
        // shrink as you moved between them, since the accessory is part of the
        // bar's own height.
        .sessionAccessory(
            unfinishedToday.map {
                UnfinishedSession(title: $0.plan.focus, done: $0.done, total: $0.plan.roundCount)
            },
            onResume: resumeToday
        )
        // The bar stays put. It used to shrink to the selected tab on scroll —
        // the Apple Music gesture — which reads as the other tabs vanishing on a
        // bar this narrow, and buys back a strip of list nobody asked for.
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
        // Presented from here rather than from the app's root, so it lands on
        // Home with the tab bar behind it — not over the splash or the sign-in
        // screen, where it would be explaining a screen they haven't reached.
        .task(id: isLaunching) { await offerWelcome() }
        // Rebuild the tab avatar only when the identity behind it changes — a
        // new account, or a name arriving from the profile fetch. A signature
        // rather than the whole `auth`, so an unrelated auth change doesn't
        // re-rasterise the disc.
        .task(id: [auth.userID, auth.email, auth.displayName]) {
            profileTabIcon = renderProfileTabIcon()
        }
        .sheet(isPresented: $showingWelcome) {
            WelcomeSheet {
                hasSeenWelcome = true
                showingWelcome = false
            }
                // Full height — the Apple onboarding shape, a mockup up top and
                // a single button pinned to the bottom.
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
        // First-run setup, ahead of the welcome sheet: a new account gets the
        // full flow, and marking the welcome seen on the way out means the sheet
        // never also fires for them.
        .task(id: auth.isNewAccount) {
            if auth.isNewAccount { showingOnboarding = true }
        }
        .fullScreenCover(isPresented: $showingOnboarding) {
            OnboardingFlow {
                hasSeenWelcome = true
                auth.acknowledgeNewAccount()
                showingOnboarding = false
            }
        }
        .sheet(isPresented: $showingSetup) {
            SessionSetupSheet(request: $request) {
                writing = Task { await generate() }
            }
            // Tint is inherited, and the bar's is now white — which would leave
            // the sheet's "Write it" white on white. The accent belongs here:
            // this is the action that starts training.
            .tint(Theme.Palette.accent)
        }
        // Keyed on the launch, not the engine — the cover has to be up while the
        // engine is still nil, which is the entire change. The id is stable
        // across the swap, so filling the engine in swaps the *content* of a
        // presented cover rather than dismissing one and presenting another.
        .fullScreenCover(item: $live) { _ in
            liveScreen
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

        let sittings = history.filter { $0.sessionID == plan.sessionID }

        // A sitting that reached the debrief *is* the plan finished, whatever the
        // round arithmetic works out to. The count alone was leaving the
        // accessory up after a session seen through to the end: rounds added by
        // "one more round" and rounds cut short both make the total disagree with
        // the plan's, and either way there's nothing left to resume.
        if sittings.contains(where: { !$0.endedEarly }) { return nil }

        let done = sittings.reduce(0) { $0 + $1.roundsCompleted }
        guard done < plan.roundCount else { return nil }
        return (plan, done)
    }

    /// Picks up where the session stopped.
    ///
    /// The rounds already finished are dropped off the front rather than the
    /// engine being taught to start midway — `Session` is a plain struct, so the
    /// remainder *is* a session, and the engine runs it without knowing it's a
    /// second sitting.
    /// Rasterises the initials disc for the profile tab, or nil to fall back to
    /// the person icon.
    ///
    /// Nil when there's no email — no identity means no initials to draw, and
    /// the generic silhouette is the honest thing to show. `.original` so the
    /// disc keeps its colour rather than being flattened to the bar's tint the
    /// way a template glyph would.
    ///
    /// `ImageRenderer` is main-actor work, which the caller already is. Scale is
    /// fixed at 3 rather than read off a screen — the tab is small and 3x covers
    /// every current device without reaching for a deprecated `UIScreen`.
    @MainActor
    private func renderProfileTabIcon() -> Image? {
        guard let email = auth.email else { return nil }

        let renderer = ImageRenderer(
            content: InitialsAvatar(
                name: auth.displayName,
                email: email,
                seed: auth.userID ?? email,
                diameter: 26
            )
        )
        renderer.scale = 3

        // `.alwaysOriginal` on the UIImage, not `.original` on the SwiftUI
        // Image — the tab bar tints at the UIKit layer, and only the UIImage's
        // own rendering mode survives that. Set on the SwiftUI side alone, the
        // coloured disc came back as a flat white circle.
        guard let uiImage = renderer.uiImage else { return nil }
        return Image(uiImage: uiImage.withRenderingMode(.alwaysOriginal))
    }

    private func resumeToday() {
        guard let (plan, done) = unfinishedToday, let session = plan.session else { return }

        let remaining = Array(session.rounds.dropFirst(done))
        guard !remaining.isEmpty else { return }

        // Nothing trained yet means this isn't a resume at all — it's the first
        // start of a session that was written and walked away from. It gets the
        // intro and it says so on the way in; a fighter who never heard "here's
        // what today is for" shouldn't be told we're picking up where they left
        // off.
        let isFirstStart = done == 0
        live = SessionLaunch(
            headline: isFirstStart ? "Starting your session" : "Picking up where you left off"
        )

        Task {
            await launch(
                Session(
                    id: session.id,
                    title: session.title,
                    // No intro on a real resume. It's the "here's what today is
                    // for" line, and you've already heard it — replaying it
                    // would make the second half sound like a different workout.
                    intro: isFirstStart ? session.intro : nil,
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

    /// Home's navigation bar: the brand on the left, the person on the right.
    ///
    /// Two items and nothing else. In the system bar rather than a row of our own
    /// in the list, so it gets the scroll-edge treatment, the metrics and the hit
    /// targets for free — a hand-built header sitting in the content is a bar
    /// that has to reimplement all three and still scrolls away.
    /// Home's bar: the wordmark on the left, the person on the right.
    ///
    /// The name is a leading item rather than the `navigationTitle`, because an
    /// inline title is centred by the system and this one belongs on the left.
    /// Sized to the bar it sits in — an inline bar's height is the constraint,
    /// and type that ignores it is what made the earlier attempts look wrong.
    @ToolbarContentBuilder
    private var homeBar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Text("CORNER")
                // Bebas is condensed and already all caps, so it carries a
                // larger size in the same width the system face needed at 24.
                .font(Theme.Fonts.wordmark(36))
                .kerning(1)
                .foregroundStyle(.primary)
                // The bar hands a toolbar item a width and expects it to fit.
                // Without this the wordmark got squeezed to "C…" rather than
                // taking the room it needs.
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
        }
        // Off the glass. iOS 26 gives every bar item the shared Liquid Glass
        // background, which is right for controls and wrong for a wordmark — it
        // put the app's name in a capsule that looked like a button.
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(placement: .topBarTrailing) {
            // Straight to Profile rather than a menu — there's one thing behind
            // this button and it's the page it names.
            //
            // A plain symbol rather than the initials disc: this is a toolbar
            // item, and the bar wants a glyph it can shape and tint like every
            // other one. The disc is still the face of the Profile page itself,
            // where it's a portrait rather than a control.
            Button {
                page = .profile
            } label: {
                Image(systemName: "person.fill")
                    .padding(.horizontal, 4)
            }
            .accessibilityLabel("Your profile")
        }
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

            // The open session used to sit here, above the dashboard. It moved
            // to the tab bar accessory — see `tabViewBottomAccessory` above —
            // because a session in progress isn't a Home thing, it's a state
            // the whole app is in, and it should be reachable from any tab.

            // The "New session" button that sat here is gone. Nothing opens the
            // setup sheet now — `showingSetup` has no caller — so whatever
            // replaces this needs to be the thing that sets it.

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

            // The dashboard that sat here is gone, and so is the recent-sessions
            // list under it. Home is the week strip and the way into a session
            // while whatever replaces them is built.
        }
        .toolbar { homeBar }
        // The list's own top inset, trimmed. It's sized for a large title, and
        // Home's bar is inline — the week strip was sitting a title's worth of
        // space below a bar with two small items in it.
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
        // 8. The row insets above only control padding *inside* a section — the
        // space between two sections is this, and left at its default it read as
        // a break between two screens rather than a gap between two cards.
        .listSectionSpacing(8)
    }

    /// Writes today's session and runs it, with the screen up for all of it.
    ///
    /// The order is the point. The cover is presented on the first line, before
    /// a single network call — writing a session is a round-trip to Claude, and
    /// that used to happen with the sheet dismissed and Home on screen, so the
    /// tap had no visible effect until the plan came back. Long enough that the
    /// honest reading was that the button hadn't worked.
    ///
    /// Now the session screen is the response to the tap, and the writing
    /// happens behind it — same as the splash covering the launch restore.
    private func generate() async {
        // Instant, and deliberately the first thing: everything below is slow.
        live = SessionLaunch()

        // Everything here is now real: the request is what the user picked in
        // the sheet, and the profile is derived from sessions they finished.
        var request = self.request
        request.profile = profile

        let generator = SessionGenerator(client: ClaudeClient.viaProxy(token: { [auth] in await auth.token() }))
        let session = await generator.plan(request)

        // They may have cancelled while it was being written. Both checks: the
        // task is cancelled by the Cancel button, and `live` is nil if the cover
        // went away by any other route. Either way the plan is dropped rather
        // than stored — an unasked-for session shouldn't land in history.
        guard !Task.isCancelled, live != nil else { return }

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

    /// The live screen's two faces. One cover, one presentation, two contents.
    ///
    /// The wait and the session are the same screen at two moments, not two
    /// screens — same palette, same gutter, same background modifier — so the
    /// plan landing reads as the screen filling in rather than a new screen
    /// arriving.
    @ViewBuilder
    private var liveScreen: some View {
        if let engine = live?.engine {
            LiveSessionView(engine: engine) { summary in
                record(summary)
            }
        } else {
            SessionPreparingView(
                request: request,
                headline: live?.headline ?? "Writing your session",
                problem: live?.problem
            ) {
                cancelLaunch()
            }
        }
    }

    /// Shows the welcome sheet a beat after the app has settled, once.
    ///
    /// Two waits, and they're different things. The first is for the splash to
    /// lift: Home is built and running underneath it, so presenting on appear
    /// would put the sheet up behind the mark and reveal it already open — the
    /// fighter would never see it arrive, and would land on a modal instead of
    /// on their app.
    ///
    /// The second is the beat after that. Landing on Home and *then* being
    /// handed one thing to read is a different experience from being handed it
    /// at the door; the pause is what makes it feel like the app spoke up
    /// rather than blocked the way in.
    ///
    /// Keyed on `isLaunching`, so a slow restore that keeps the splash up
    /// longer simply moves the whole thing later rather than racing it.
    private func offerWelcome() async {
        // A new account gets the full setup flow instead — never both.
        guard !isLaunching, !hasSeenWelcome, !auth.isNewAccount, !showingOnboarding else { return }

        try? await Task.sleep(for: .seconds(1.5))

        // Re-checked: the sleep is cancellable and 1.5 seconds is long enough
        // for them to have gone somewhere else, or for the sheet to have been
        // dealt with on another path.
        guard !Task.isCancelled, !hasSeenWelcome, !showingOnboarding else { return }
        showingWelcome = true
    }

    /// Backing out before the session starts.
    ///
    /// Cancels the write first: a plan that arrives after this would otherwise
    /// be inserted and launched into an empty screen. Nothing to tear down on
    /// the audio side — the cover's own `onChange` handles that, and on this
    /// path the session was very likely never activated at all.
    private func cancelLaunch() {
        writing?.cancel()
        writing = nil
        live = nil
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

    /// Turns a written plan into a running session, on the screen that's already
    /// up.
    ///
    /// Every failure here now reports onto the live screen rather than into
    /// Home's alert. It has to: the cover is presented by the time this runs, so
    /// an alert raised behind it is an alert nobody can see, and the fighter is
    /// left looking at "Writing your session" forever.
    private func launch(_ session: Session) async {
        // Every path through here needs a screen to land on, and only
        // `generate()` opens one — so a resume used to run this whole method
        // against a nil `live`, where `live?.engine =` below is a silent no-op.
        // Tapping Resume did nothing at all, with no error and nothing in the
        // log: the session was built and immediately dropped.
        //
        // Created here rather than at each call site so a third caller can't
        // reintroduce it.
        if live == nil { live = SessionLaunch(headline: "Picking up where you left off") }

        guard await audioSession.requestMicrophoneAccess() else {
            live?.problem = "Microphone access is required. Enable it in Settings."
            return
        }
        guard await requestSpeechAccess() else {
            live?.problem = "Speech recognition access is required. Enable it in Settings."
            return
        }

        // Must precede the recognizer: the audio engine's input node reports a zero
        // sample rate until the session is active.
        do {
            try audioSession.activate()
        } catch {
            live?.problem = "Couldn't start audio: \(error.localizedDescription)"
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

        // Filled in rather than assigned: the cover is already up, and replacing
        // the whole launch would change its id and bounce the presentation.
        live?.engine = SessionEngine(
            session: session,
            voice: voice,
            recognizer: SpeechAnalyzerRecognizer(),
            speaksCoaching: speaksCoaching,
            countdownSeconds: countdownSeconds,
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

/// A session screen, from the tap to the bell.
///
/// One value covering both moments, and the identity is its own rather than the
/// engine's — that's what lets the cover stay presented while the engine appears
/// underneath it. Keying the presentation on the engine, as it used to, made the
/// engine's arrival a *new* item and therefore a new presentation, which is the
/// dismiss-and-represent flash this exists to avoid.
struct SessionLaunch: Identifiable {
    let id = UUID()

    /// What the waiting screen says it's doing. A written session and a resumed
    /// one both wait here, and only one of them is being written — "Writing your
    /// session" over a session that was written an hour ago is a small lie the
    /// fighter can catch.
    var headline = "Writing your session"

    /// Nil while the plan is still being written. Set once, when it lands.
    var engine: SessionEngine?

    /// Set if the session couldn't be started at all. Shown on the waiting
    /// screen, because by then it's the only screen there is.
    var problem: String?
}

private extension View {
    /// Adds the session accessory to the tab bar, or nothing at all.
    ///
    /// Conditional at the *modifier* level, not the content level: with a
    /// session it applies `tabViewBottomAccessory`, and without one it returns
    /// the view untouched — so when there's nothing to resume the accessory
    /// slot isn't in the hierarchy at all, rather than an empty bar the system
    /// might still reserve space for.
    @ViewBuilder
    func sessionAccessory(_ session: UnfinishedSession?, onResume: @escaping () -> Void) -> some View {
        if let session {
            tabViewBottomAccessory {
                SessionAccessory(session: session, onResume: onResume)
            }
        } else {
            self
        }
    }
}

#Preview {
    ContentView(userID: "preview")
        .environment(AuthController())
}
