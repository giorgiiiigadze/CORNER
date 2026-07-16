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

    init(engine: SessionEngine) {
        _engine = State(initialValue: engine)
    }

    var body: some View {
        ZStack {
            VStack(spacing: Theme.Layout.stackSpacing) {
                header
                Spacer()
                timer
                combo
                Spacer()
                footer
            }
            .padding(Theme.Layout.gutter)
        }
        .cornerBackground(resting: engine.isResting)
        .preferredColorScheme(.dark)
        // The whole premise is that you can't touch this. Letting it sleep would
        // end the workout for you.
        .persistentSystemOverlays(.hidden)
        .task { await startListening() }
        .alert("Can't hear you", isPresented: .constant(startupError != nil)) {
            Button("OK") { dismiss() }
        } message: {
            Text(startupError ?? "")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text(headline)
                .font(Theme.Fonts.roundLabel)
                .foregroundStyle(Theme.Palette.secondaryText)
            Spacer()
            listeningIndicator
        }
    }

    private var timer: some View {
        Text(clock)
            .font(Theme.Fonts.timer())
            .foregroundStyle(timerColor)
            .contentTransition(.numericText(countsDown: true))
            .animation(.smooth(duration: 0.2), value: engine.secondsRemaining)
    }

    @ViewBuilder
    private var combo: some View {
        // Reserve the space so the timer doesn't jump between callouts.
        Text(engine.currentCombo?.display ?? " ")
            .font(Theme.Fonts.combo)
            .foregroundStyle(Theme.Palette.primaryText)
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.15), value: engine.currentCombo)
            .frame(maxWidth: .infinity)
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
            .foregroundStyle(Theme.Palette.secondaryText.opacity(0.7))
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
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            Spacer()
            Button("End") {
                Task {
                    await engine.end()
                    dismiss()
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.Palette.secondaryText)
            .buttonStyle(.plain)
        }
    }

    /// Proof that voice control is alive. Without it, a quiet moment is
    /// indistinguishable from a crash.
    private var listeningIndicator: some View {
        Circle()
            .fill(engine.isListening ? Theme.Palette.accent : Theme.Palette.secondaryText)
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

    private var headline: String {
        switch engine.phase {
        case .idle: "Say \"let's go\""
        case .announcing, .active:
            if let round = engine.round { "R\(round.index) · \(round.focus)" } else { "" }
        case .resting: "Rest"
        case .debrief: "Done"
        }
    }

    private var clock: String {
        let total = max(0, Int(engine.secondsRemaining.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var timerColor: Color {
        if engine.isResting { return Theme.Palette.primaryText }
        return engine.phase == .active ? Theme.Palette.accent : Theme.Palette.primaryText
    }

    private func startListening() async {
        do {
            try await engine.beginListening()
        } catch {
            startupError = error.localizedDescription
        }
    }
}
