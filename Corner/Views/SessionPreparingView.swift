import SwiftUI

/// The live screen before there's a session to run.
///
/// Writing a session is a call to Claude, and that takes as long as the network
/// takes — a second on a good day, several on a bad one. The old flow spent that
/// time on Home with nothing on screen: "Write it" dismissed the sheet and then
/// *nothing happened*, sometimes for long enough to tap it again. The session
/// screen appearing at the end was the first evidence anything had been asked
/// for.
///
/// So this is the same screen, held. It comes up on the tap, in the live
/// screen's own light palette and gutter, and `LiveSessionView` replaces it in
/// place when the plan lands — same background, same corner, no second
/// presentation. What the fighter sees is one screen that starts out waiting.
///
/// It deliberately has no clock and no round bars. Reserving their space and
/// leaving them empty was worse: a 00:00 timer on a light screen reads as a
/// session that's started and gone wrong, not as one still being written.
struct SessionPreparingView: View {

    /// What the fighter asked for, so the wait says something specific rather
    /// than spinning. They chose it ten seconds ago; this is the confirmation
    /// that it's what's being written.
    let request: SessionRequest

    /// Set when the write failed. The screen stays up and says so — dropping
    /// straight back to Home would look identical to the tap not registering,
    /// which is the exact confusion this screen exists to end.
    let problem: String?

    /// Backing out. Cancels the write on the way.
    let onCancel: () -> Void

    /// Drives the pulse on the mark. One slow breath, matching `HomeSkeleton` —
    /// the app's one idiom for "this is coming".
    @State private var breathing = false

    var body: some View {
        VStack(spacing: Theme.Layout.stackSpacing) {
            header
            Spacer()
            if let problem {
                failure(problem)
            } else {
                waiting
            }
            Spacer()
            footer
        }
        .padding(Theme.Layout.gutter)
        // The live screen's background, and the same modifier it uses — so the
        // handover is one screen changing its mind, not a cut between two.
        .cornerBackground(Theme.Live.background)
        // Pinned to match the screen it becomes, which is black whatever the
        // phone is set to.
        .preferredColorScheme(.dark)
        .onAppear { breathing = true }
    }

    // MARK: - Pieces

    /// Empty, and it has to be: it holds the space `LiveSessionView`'s listening
    /// indicator will occupy, so nothing below it shifts on the swap.
    private var header: some View {
        HStack {
            Spacer()
        }
        .frame(height: 28)
    }

    private var waiting: some View {
        VStack(spacing: 10) {
            Text("Writing your session")
                .font(Theme.Fonts.focus)
                .foregroundStyle(Theme.Live.primaryText)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .lineLimit(2)
                .opacity(breathing ? 1 : 0.45)
                .animation(
                    .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                    value: breathing
                )

            // The order they picked it in, and the same words the sheet used.
            Text(shape)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Live.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private func failure(_ problem: String) -> some View {
        VStack(spacing: 10) {
            Text("Couldn't write it")
                .font(Theme.Fonts.focus)
                .foregroundStyle(Theme.Live.primaryText)
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            Text(problem)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Live.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// Cancel, in the footer where the live screen keeps End — the same corner
    /// of the screen means the same kind of thing, which is "get me out of here".
    private var footer: some View {
        Button(problem == nil ? "Cancel" : "Close", action: onCancel)
            .font(.headline)
            .foregroundStyle(Theme.Live.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(.rect)
    }

    private var shape: String {
        "\(request.focus) · \(request.rounds) × \(request.roundSeconds / 60) min"
    }
}

#Preview("Waiting") {
    SessionPreparingView(request: SessionRequest(), problem: nil) {}
}

#Preview("Failed") {
    SessionPreparingView(
        request: SessionRequest(),
        problem: "The network dropped while the session was being written."
    ) {}
}
