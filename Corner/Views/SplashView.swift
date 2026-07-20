import SwiftUI

/// The first thing on screen, and the only thing, until the app knows who it's
/// for.
///
/// Not decoration for its own sake. The work at launch — reading the Keychain,
/// trading the refresh token for a live session, standing up the SwiftData
/// container — takes as long as it takes, and on a cold start over a bad
/// connection that's a second or more of a view tree that can't yet say
/// anything true. This covers exactly that window, and it's built to be
/// *behind*-friendly: the real UI is mounted underneath from the first frame,
/// so when this goes away there's nothing left to construct.
///
/// The mark is the one from the sign-in screen, at the same weight. A splash
/// that introduces a different logo than the next screen reads as two apps.
struct SplashView: View {

    /// Drives the one animation there is: the mark settles in rather than
    /// appearing at rest. Off until `onAppear` so the transition actually has
    /// a frame to run from.
    @State private var settled = false

    var body: some View {
        ZStack {
            // Opaque, and the same colour the app underneath uses. This has to
            // cover a live view tree, so anything translucent shows the real
            // Home ghosting through the wait.
            Theme.Palette.background
                .ignoresSafeArea()

            VStack(spacing: 20) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.Palette.accent)
                    .frame(width: 76, height: 76)
                    .overlay {
                        Image(systemName: "figure.boxing")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(.white)
                    }

                Text("Corner")
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(.primary)
            }
            // A hair up from centre. Dead centre reads low, because the eye
            // weights a stacked mark by its top block rather than its bounds.
            .padding(.bottom, 40)
            .scaleEffect(settled ? 1 : 0.92)
            .opacity(settled ? 1 : 0)
        }
        // Slow enough to be a fade rather than a cut, quick enough that it's
        // finished well inside the shortest launch we'd ever hold for.
        .animation(.easeOut(duration: 0.45), value: settled)
        .onAppear { settled = true }
        // One element, and it says the app's name rather than describing a red
        // square. VoiceOver announces it on launch, which is the same thing a
        // sighted user gets.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Corner")
    }
}

#Preview {
    SplashView()
        .preferredColorScheme(.dark)
}
