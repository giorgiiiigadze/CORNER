import SwiftUI

/// The one thing to say before the first session.
///
/// Shown once, on the first launch after signing in, and never again. It is
/// deliberately a single idea with a single button: an onboarding flow that
/// explains the whole app is one nobody reads, and everything else here is
/// discoverable by doing it. What isn't discoverable is that the cornerman
/// talks: a fighter who props the phone on a bench and hears a bell has no
/// reason to suspect there was a voice they could have turned on.
///
/// The layout is Apple's own onboarding shape — a large mockup filling the top,
/// a centred title and subtitle under it, and a single full-width button pinned
/// to the bottom. It's a full-height sheet, not the small card it started as.
struct WelcomeSheet: View {

    /// Called when they're done. The caller records that so this never returns.
    let onContinue: () -> Void

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Fills the top of the panel, the way Apple's onboarding leads
                // with a device mockup. A fraction of the sheet rather than a
                // fixed height, so it holds its proportion on an SE and a Pro Max
                // both.
                artwork
                    .frame(height: geo.size.height * 0.44)

                Text("He Talks You Through Every Round")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 32)

                Text("Prop your phone up and leave it. Every round is called out loud: what it's for, and the one thing to hold onto. It's on by default.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.top, 12)

                Spacer(minLength: 24)

                Button(action: onContinue) {
                    Text("Continue")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        // A flat grey capsule, matching the reference. On the
                        // near-black sheet the glass read as almost nothing —
                        // grey is the quiet, legible button the layout wants.
                        .background(Color(.tertiarySystemGroupedBackground), in: .capsule)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.background)
    }

    /// Placeholder for the artwork.
    ///
    /// Drop the asset into `Assets.xcassets` and swap the fill for
    /// `Image("Welcome").resizable().scaledToFill().clipShape(...)` — the frame
    /// and corner are already the box the real image should sit in, so nothing
    /// around it needs to move.
    private var artwork: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(Color(.tertiarySystemGroupedBackground))
            .frame(maxWidth: .infinity)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    Color.black
        .sheet(isPresented: .constant(true)) {
            WelcomeSheet {}
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .preferredColorScheme(.dark)
        }
}
