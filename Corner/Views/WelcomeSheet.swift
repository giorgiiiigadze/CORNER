import SwiftUI

/// The one thing to say before the first session.
///
/// Shown once, on the first launch after signing in, and never again. It is
/// deliberately a single idea with a single button: an onboarding flow that
/// explains the whole app is one nobody reads, and everything else here is
/// discoverable by doing it. What isn't discoverable is that the cornerman
/// talks — a fighter who props the phone on a bench and hears a bell has no
/// reason to suspect there was a voice they could have turned on.
struct WelcomeSheet: View {

    /// Called when they're done. The caller records that so this never returns.
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            artwork

            // Three weights, three jobs. The old version had a headline and
            // then one grey block carrying both what the app does and where a
            // switch lives — two unrelated thoughts at the same size, which is
            // what made it read as a wall.
            //
            // Now: the promise, what actually happens, and the small print.
            // Each one is a step quieter than the last, so the eye can stop
            // after any of them and still have got something.
            Text("He talks you through it")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 26)

            Text("Prop the phone up and leave it there. Every round is called out loud: what it's for, and the one thing to hold onto.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 10)

            Spacer(minLength: 20)

            settingsHint

            Button(action: onContinue) {
                Text("Got it")
                    .font(.headline)
                    // Black on white. The red is the app's one accent and it's
                    // spent on starting a session — a red button here would be
                    // the loudest thing on a screen that isn't asking for the
                    // most important tap in the app.
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(.white, in: Theme.buttonShape)
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // #1F1F1F, a hair above the app's black. A sheet the same colour as the
        // screen behind it doesn't read as a sheet, it reads as the screen
        // having changed; this lifts just enough to sit on top.
        .background(Color(red: 0.122, green: 0.122, blue: 0.122))
    }

    /// Placeholder for the artwork.
    ///
    /// Drop the asset into `Assets.xcassets` and swap the body of this property
    /// for `Image("Welcome").resizable().scaledToFit()` — the frame and corner
    /// are already what the real image should sit in, so nothing around it
    /// needs to move.
    private var artwork: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color(.tertiarySystemGroupedBackground))
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
            }
            .accessibilityHidden(true)
    }

    /// Where the switch is, in the smallest type on the sheet.
    ///
    /// It's genuinely small print: coaching is on by default, so nobody has to
    /// act on this — it exists so the fighter who wants silence knows there's a
    /// way to get it, and doesn't go hunting. Set apart from the body copy
    /// rather than tacked onto it, because "here's what the app does" and
    /// "here's where a setting lives" are different kinds of sentence and
    /// reading them at one size is what made the first version confusing.
    private var settingsHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.Live.work)

            Text("Already on. Turn it off in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(Color(.tertiarySystemGroupedBackground), in: .capsule)
    }
}

#Preview {
    Color.black
        .sheet(isPresented: .constant(true)) {
            WelcomeSheet {}
                .preferredColorScheme(.dark)
        }
}
