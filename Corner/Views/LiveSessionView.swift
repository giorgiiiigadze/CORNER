import SwiftUI

/// The custom heart.
///
/// Everything here is sized for a phone lying on a bench three metres away, seen
/// out of the corner of an eye, maybe twice a round. Anything that needs a second
/// look does not belong on this screen.
struct LiveSessionView: View {

    @State private var engine: SessionEngine
    @State private var startupError: String?
    @Environment(\.dismiss) private var dismiss

    /// The chosen "get ready" length, read here only so the ring knows what a
    /// full circle is worth. The engine reads it independently to run the clock.
    @AppStorage(SessionEngine.countdownKey) private var countdownSeconds: Int = 3

    /// The Lock Screen's copy of the clock. Owned here because this view owns
    /// every exit, and an activity that outlives its session is a stuck timer.
    @State private var liveActivity = SessionLiveActivity()

    /// Called once, with what actually happened, on the way out.
    private let onFinish: (SessionSummary) -> Void

    init(engine: SessionEngine, onFinish: @escaping (SessionSummary) -> Void) {
        _engine = State(initialValue: engine)
        self.onFinish = onFinish
    }

    /// Runs whether they said "end session", tapped End, or finished the last
    /// round — a session only teaches the cornerman something if it's recorded
    /// on every exit, not just the tidy one.
    private func finish() async {
        let summary = engine.summary
        liveActivity.end()
        await engine.end()
        onFinish(summary)
        dismiss()
    }

    var body: some View {
        VStack(spacing: Theme.Layout.stackSpacing) {
            Spacer()
            timer
            Spacer()
            focus
            Spacer()
            rounds
            heardTranscript
        }
        .padding(Theme.Layout.gutter)
        // The panel is an inset rather than an overlay, so the session's own
        // content lays out in the space above it. Floated on top instead, the
        // round bars ended up underneath it on the short phones — and the bars
        // are the one thing here you're meant to catch without looking.
        .safeAreaInset(edge: .bottom, spacing: 0) { panel }
        // One background for every phase now. The state is in the clock and the
        // bars; see `Theme.Live` for why it left the field.
        .cornerBackground(Theme.Live.background)
        // Pinned dark, the way it used to be pinned light: this screen is black
        // whatever the phone is set to.
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(.hidden)
        // "Get ready", over the top of the built session, so the first bell lands
        // the moment it clears. Driven by the engine, so it shows whether the
        // session was started by the button or by "let's go".
        .overlay {
            if let remaining = engine.countdownRemaining {
                SessionCountdown(
                    remaining: remaining,
                    total: countdownSeconds,
                    title: engine.sessionTitle
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: engine.countdownRemaining == nil)
        .task { await startListening() }
        // The premise is that you never touch the phone — which means iOS never
        // sees a touch, and locks the screen out from under a running workout.
        // Held only for the session, never app-wide.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        // Catches every exit that isn't the End button: "end session", or the
        // last round finishing on its own.
        .onChange(of: engine.isFinished) { _, finished in
            guard finished else { return }
            Task { await finish() }
        }
        // The Lock Screen mirror. Keyed to transitions, never to the tick —
        // the system runs the widget's clock toward `endsAt` on its own, so
        // updating on `secondsRemaining` would be sixty pushes a minute for
        // nothing.
        .onChange(of: engine.phase) { syncLiveActivity() }
        .onChange(of: engine.isPaused) { syncLiveActivity() }
        .onChange(of: engine.totalRounds) { syncLiveActivity() }
        .alert("Can't hear you", isPresented: .constant(startupError != nil)) {
            Button("OK") { dismiss() }
        } message: {
            Text(startupError ?? "")
        }
    }

    // MARK: - Pieces

    /// Just the listening dot now — where you are in the session moved under the
    /// clock, where Strava puts the name of a number.
    private var timer: some View {
        VStack(spacing: 2) {
            Text(clock)
                .font(Theme.Fonts.timer())
                .foregroundStyle(timerColor)
                .contentTransition(.numericText(countsDown: true))
                .animation(.smooth(duration: 0.2), value: engine.secondsRemaining)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            caption(headline)
        }
    }

    /// What this round is for.
    ///
    /// The only coaching on screen, and the only place the session's shape is
    /// visible now that the cornerman goes quiet after the intro. Sits where the
    /// combo callout used to, in the same big type, because the job is the same:
    /// readable at a glance from wherever the phone ended up.
    private var focus: some View {
        VStack(spacing: 2) {
            // Reserve the space so the timer doesn't jump between rounds.
            Text(engine.isResting ? "Rest" : (engine.round?.focus ?? " "))
                .font(Theme.Fonts.focus)
                .foregroundStyle(Theme.Live.primaryText)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.smooth(duration: 0.15), value: engine.round?.focus)
                .animation(.smooth(duration: 0.15), value: engine.isResting)
                .frame(maxWidth: .infinity)
            caption(engine.isResting ? "Breathe" : "This round")
        }
    }

    /// The session's shape, one bar per round — Strava's splits strip, which maps
    /// onto rounds almost exactly.
    ///
    /// It earns its place by answering the thing the numbers can't: how much is
    /// left. "Round 3 of 6" is that answer in a form you have to read; this is
    /// the same answer in a form you can catch sideways from three metres, which
    /// is the only way this screen is ever looked at.
    private var rounds: some View {
        HStack(spacing: 4) {
            ForEach(1...max(engine.totalRounds, 1), id: \.self) { index in
                bar(index)
            }
        }
        .frame(height: 6)
        // No caption. A row of bars that fill as the session runs doesn't need
        // to be told it's the rounds — and the label was the one piece of text
        // on this screen nobody reads twice.
        //
        // The padding is what the caption used to occupy, kept so the strip
        // sits down near the panel rather than floating in the middle of the
        // gap left behind.
        .padding(.top, 20)
    }

    /// One round: a track, and a fill that grows across it as the round runs.
    ///
    /// The fill is the same colour as the clock above it — green working, red
    /// resting — so the two never disagree about what's happening. Rounds behind
    /// you stay green and full; rounds ahead are bare track.
    private func bar(_ index: Int) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Live.track)
                Capsule()
                    .fill(fillColor(index))
                    .frame(width: proxy.size.width * fill(index))
                    // Linear and exactly one second: the clock ticks once a
                    // second, so anything springy would visibly overshoot and
                    // settle between ticks, and a bar that wobbles is a bar
                    // that's lying about the time.
                    .animation(.linear(duration: 1), value: engine.secondsRemaining)
                    .animation(.smooth(duration: 0.3), value: engine.isResting)
            }
        }
    }

    /// How much of this round's bar is filled, 0 to 1.
    ///
    /// Rounds behind you are full, rounds ahead are empty, and the one you're in
    /// tracks the clock.
    private func fill(_ index: Int) -> Double {
        guard let current = engine.round?.index else { return 0 }
        if index == current { return roundProgress }
        return index < current ? 1 : 0
    }

    private func fillColor(_ index: Int) -> Color {
        index == engine.round?.index ? phaseColor : Theme.Live.work
    }

    /// Names the number above it, in Strava's small grey.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Live.secondaryText)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.15), value: text)
    }

    /// The controls, in a panel that sits on the session rather than in it.
    ///
    /// Modelled on the Workout app's: a rounded slab lifted off the black, the
    /// elapsed clock across the top, the buttons under it. The reason it's a
    /// panel and not a row of text buttons is that this screen is operated by
    /// voice and glanced at from three metres — when someone does reach for it,
    /// they're reaching without looking, and a 72pt circle in a fixed place is
    /// findable that way where a footnote-sized "End" never was.
    ///
    /// It carries the elapsed *session*, not the round. The round is the hero
    /// clock in the middle of the screen; repeating it here would spend the
    /// panel's one number on something already the largest thing in the room.
    private var panel: some View {
        VStack(spacing: 14) {
            grabber
            panelClock
            controls
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(
            Theme.Live.panel,
            in: .rect(cornerRadius: 42, style: .continuous)
        )
        .padding(.horizontal, 10)
        // Clear of the home indicator, which sits directly under this.
        .padding(.bottom, 8)
    }

    /// The grab handle across the top of the panel.
    ///
    /// Purely a shape — nothing here is draggable. It's what tells you the slab
    /// is an object resting on the screen rather than a band painted across the
    /// bottom of it, and without it the panel reads as the screen simply being a
    /// different colour down there.
    private var grabber: some View {
        Capsule()
            .fill(Theme.Live.secondaryText.opacity(0.5))
            .frame(width: 36, height: 5)
    }

    /// Left to right: whether it's listening, how long you've been at it, where
    /// you are in the session. The three things the big type doesn't say.
    private var panelClock: some View {
        HStack {
            listeningIndicator
                .frame(width: 44, alignment: .leading)

            Spacer()

            Text(elapsed)
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(timerColor)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.2), value: engine.sessionSeconds)

            Spacer()

            Text(engine.round.map { "\($0.index)/\(engine.totalRounds)" } ?? "—")
                .font(Theme.Fonts.caption.monospacedDigit())
                .foregroundStyle(Theme.Live.secondaryText)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// M1 instrumentation, not a design element. Seeing "it heard 'slow her'"
    /// instead of "nothing happened" is the difference between a measurement and a
    /// shrug. Delete this once the gym test is passed.
    ///
    /// Outside the panel rather than in it: the panel is a designed object with
    /// three things in it, and a monospaced debug line sitting inside the slab
    /// read as damage rather than as a readout. Above it, it's plainly a note
    /// laid on the screen — which is what it is.
    private var heardTranscript: some View {
        Text(engine.lastHeard ?? " ")
            .font(.caption.monospaced())
            .foregroundStyle(Theme.Live.secondaryText.opacity(0.7))
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.default, value: engine.lastHeard)
    }

    /// End, the primary, and next round — in the Workout app's arrangement, and
    /// for its reason: the destructive one is furthest from the thumb that's
    /// reaching for the big one in the middle.
    ///
    /// Every one of these is something you can already say out loud, and saying
    /// it is still the intended way. These are for the times the gym is too loud
    /// to be heard, which is the failure mode a voice-first screen has to have
    /// an answer for.
    private var controls: some View {
        HStack(spacing: 18) {
            // Grey, not red, and that's a change forced by the black screen:
            // red is the resting clock now, so a red End button sitting six
            // inches under a red timer read as part of the state rather than as
            // a control. Recessive suits it anyway — this is the button you use
            // once, at the end, and never in a hurry.
            circleButton("xmark", tint: Theme.Live.secondaryText, size: Self.secondarySize) {
                Task { await finish() }
            }
            .accessibilityLabel("End session")

            circleButton(primaryIcon, tint: Theme.Live.primaryText, size: Self.primarySize) {
                Task { await engine.handle(primaryCommand) }
            }
            .accessibilityLabel(primaryLabel)

            circleButton("forward.end.fill", tint: Theme.Live.primaryText, size: Self.secondarySize) {
                Task { await engine.handle(.nextRound) }
            }
            // Nothing to skip to before the first bell, and skipping the last
            // round is what the End button is for.
            .disabled(engine.phase == .idle)
            .accessibilityLabel("Next round")
        }
    }

    /// Start/pause, and it's half again the size of the other two.
    ///
    /// The size difference is the hierarchy — there's no colour doing that job
    /// here, since red belongs to the resting clock and everything else in the
    /// panel is grey on grey. It's also the one you reach for with the phone on
    /// a bench and your hands wrapped, which is an argument for the largest
    /// target the panel can hold.
    private static let primarySize: CGFloat = 110
    private static let secondarySize: CGFloat = 74

    private func circleButton(
        _ icon: String,
        tint: Color,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Circle()
                .fill(Theme.Live.control)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: size * 0.36, weight: .semibold))
                        .foregroundStyle(tint)
                }
        }
        .buttonStyle(.plain)
    }

    /// Play before the bell and after a pause, pause while it's running. The one
    /// button says what tapping it will do, not what the session is doing.
    private var primaryIcon: String {
        engine.phase == .idle || engine.isPaused ? "play.fill" : "pause.fill"
    }

    private var primaryCommand: VoiceCommand {
        if engine.phase == .idle { .start } else if engine.isPaused { .resume } else { .pause }
    }

    private var primaryLabel: String {
        switch primaryCommand {
        case .start: "Start session"
        case .resume: "Resume"
        default: "Pause"
        }
    }

    /// Proof that voice control is alive. Without it, a quiet moment is
    /// indistinguishable from a crash.
    private var listeningIndicator: some View {
        Circle()
            .fill(engine.isListening ? Theme.Live.accent : Theme.Live.secondaryText)
            .frame(width: 12, height: 12)
            .opacity(engine.isListening ? 1 : 0.4)
            .scaleEffect(engine.isListening && !engine.isPaused ? 1.0 : 0.7)
            .animation(
                engine.isListening && !engine.isPaused
                    ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                    : .default,
                value: engine.isListening || engine.isPaused
            )
            .accessibilityLabel(engine.isListening ? "Listening" : "Not listening")
    }

    // MARK: - Derived

    /// Deliberately not the focus — that's in 56pt in the middle of the screen
    /// now that the combo callout isn't. Saying it twice wastes the only other
    /// line there's room for, and where you are in the session is the thing the
    /// big text can't tell you.
    private var headline: String {
        switch engine.phase {
        case .idle: "Say \"let's go\""
        case .announcing, .active, .resting:
            if let round = engine.round {
                "Round \(round.index) of \(engine.totalRounds)"
            } else { "" }
        case .debrief: "Done"
        }
    }

    private var clock: String {
        let total = max(0, Int(engine.secondsRemaining.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The whole session so far, zero-padded so the panel's number doesn't
    /// change width every time the tens column rolls.
    private var elapsed: String {
        let total = max(0, engine.sessionSeconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// Green while the round runs, red while it doesn't. The clock and the bar
    /// below it both read from this, so they can't drift apart.
    private var phaseColor: Color {
        engine.isResting ? Theme.Live.resting : Theme.Live.work
    }

    /// Coloured only while a clock is meaningfully running. Idle and the debrief
    /// get plain ink — green there would be claiming a state that isn't on.
    private var timerColor: Color {
        switch engine.phase {
        case .active: Theme.Live.work
        case .resting: Theme.Live.resting
        case .idle, .announcing, .debrief: Theme.Live.primaryText
        }
    }

    /// How far through the round we are, counting its rest as part of it.
    ///
    /// Continuous across the bell on purpose: work fills the bar to three
    /// quarters, rest carries it the rest of the way, and it never runs
    /// backwards. Restarting the fill at the bell would read as a new round
    /// beginning, which is the one thing the bell doesn't mean.
    private var roundProgress: Double {
        guard let round = engine.round else { return 0 }
        let total = round.duration + round.rest
        guard total > 0 else { return 0 }

        let elapsed: TimeInterval = switch engine.phase {
        // `secondsRemaining` is still sitting at the *previous* countdown's zero
        // while the opener is spoken. Reading it here would fill the bar to the
        // end of a round that hasn't started.
        case .idle, .announcing: 0
        case .active: round.duration - engine.secondsRemaining
        case .resting: round.duration + round.rest - engine.secondsRemaining
        case .debrief: total
        }

        return min(max(elapsed / total, 0), 1)
    }

    private func startListening() async {
        do {
            try await engine.beginListening()
        } catch {
            startupError = error.localizedDescription
        }
    }

    // MARK: - Live Activity

    /// Makes the Lock Screen agree with the engine. Idle means nothing has
    /// started, so there's nothing to show; the debrief ends the card — a
    /// session that's over has no business on the Lock Screen.
    private func syncLiveActivity() {
        switch engine.phase {
        case .idle:
            break
        case .announcing, .active, .resting:
            liveActivity.sync(title: engine.summary.title, state: liveActivityState)
        case .debrief:
            liveActivity.end()
        }
    }

    /// The engine's state, translated for the widget. `endsAt` only while a
    /// countdown is genuinely running: the opener has no clock yet, and a
    /// pause freezes the number instead — a target date would keep the
    /// widget's clock falling through it.
    private var liveActivityState: SessionActivityAttributes.ContentState {
        var remaining = max(0, Int(engine.secondsRemaining.rounded()))
        let phase: SessionActivityAttributes.Phase
        var endsAt: Date?

        if engine.isPaused {
            phase = .paused
        } else {
            switch engine.phase {
            case .active:
                phase = .work
                endsAt = Date(timeIntervalSinceNow: engine.secondsRemaining)
            case .resting:
                phase = .rest
                endsAt = Date(timeIntervalSinceNow: engine.secondsRemaining)
            case .announcing:
                phase = .announcing
                // `secondsRemaining` is still the previous countdown's zero
                // while the opener is spoken — same trap `roundProgress`
                // documents. Show the round about to start, not a dead 0:00.
                remaining = engine.round?.durationSeconds ?? 0
            case .idle, .debrief:
                phase = .done
            }
        }

        return SessionActivityAttributes.ContentState(
            phase: phase,
            roundIndex: engine.round?.index ?? 1,
            totalRounds: engine.totalRounds,
            focus: engine.round?.focus ?? "",
            endsAt: endsAt,
            secondsRemaining: remaining
        )
    }
}
