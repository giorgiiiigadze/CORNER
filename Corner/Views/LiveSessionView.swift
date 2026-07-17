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
        await engine.end()
        onFinish(summary)
        dismiss()
    }

    var body: some View {
        ZStack {
            VStack(spacing: Theme.Layout.stackSpacing) {
                header
                Spacer()
                timer
                Spacer()
                focus
                Spacer()
                rounds
                footer
            }
            .padding(Theme.Layout.gutter)
        }
        .cornerBackground(screen)
        .preferredColorScheme(.light)
        .persistentSystemOverlays(.hidden)
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
        .alert("Can't hear you", isPresented: .constant(startupError != nil)) {
            Button("OK") { dismiss() }
        } message: {
            Text(startupError ?? "")
        }
    }

    // MARK: - Pieces

    /// Just the listening dot now — where you are in the session moved under the
    /// clock, where Strava puts the name of a number.
    private var header: some View {
        HStack {
            Spacer()
            listeningIndicator
        }
    }

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
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(1...max(engine.totalRounds, 1), id: \.self) { index in
                    bar(index)
                }
            }
            .frame(height: 6)
            caption("Rounds")
        }
    }

    /// One round: a track, and a fill that grows across it as the round runs.
    ///
    /// The fill is the same colour as the clock above it — green working, red
    /// resting — so the two never disagree about what's happening. Rounds behind
    /// you stay green and full; rounds ahead are bare track.
    private func bar(_ index: Int) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Live.primaryText.opacity(0.12))
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

    private var footer: some View {
        VStack(spacing: 8) {
            heardTranscript
            controls
        }
    }

    /// M1 instrumentation, not a design element. Seeing "it heard 'slow her'"
    /// instead of "nothing happened" is the difference between a measurement and a
    /// shrug. Delete this once the gym test is passed.
    private var heardTranscript: some View {
        Text(engine.lastHeard ?? "—")
            .font(.caption.monospaced())
            .foregroundStyle(Theme.Live.secondaryText.opacity(0.7))
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.default, value: engine.lastHeard)
    }

    private var controls: some View {
        HStack {
            if engine.isPaused {
                Label("Paused — say \"resume\"", systemImage: "pause.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.Live.secondaryText)
            }
            Spacer()
            Button("End") {
                Task { await finish() }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.Live.secondaryText)
            .buttonStyle(.plain)
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

    /// Green while the round runs, red while it doesn't. The clock and the bar
    /// below it both read from this, so they can't drift apart.
    private var phaseColor: Color {
        engine.isResting ? Theme.Live.resting : Theme.Live.work
    }

    /// The background says the same thing the clock does, one state per phase.
    ///
    /// The green lands exactly on the bell — not on the opener before it — so
    /// the screen turning colour means "start punching" and nothing else, which
    /// is what the bell means too.
    private var screen: Color {
        switch engine.phase {
        case .active: Theme.Live.workBackground
        case .resting: Theme.Live.restBackground
        case .idle, .announcing, .debrief: Theme.Live.background
        }
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
}
