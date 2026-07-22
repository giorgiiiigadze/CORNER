import SwiftUI

/// Who you are, before there's a picture of you.
///
/// The pattern every app with accounts and no upload flow yet lands on: two
/// letters on a coloured disc. What makes it feel like *yours* rather than a
/// default is that the colour is derived from your account and never changes —
/// two people on the same phone get different discs, and yours is the same disc
/// on every launch.
///
/// This replaces a red circle with a boxing glove in it, which was the same
/// image for every user in the world.
struct InitialsAvatar: View {

    /// The display name, when there is one. `display_name` exists in the
    /// profiles table but isn't surfaced by `AuthController` yet — passing it
    /// here is a one-line change on the day it is.
    var name: String?

    /// Falls back to the address. Everyone has one of these.
    var email: String?

    /// What the colour is derived from. The user id rather than the email, so
    /// changing your address doesn't change your disc.
    let seed: String

    var diameter: CGFloat = 96

    var body: some View {
        Circle()
            .fill(background)
            .frame(width: diameter, height: diameter)
            .overlay {
                Text(initials)
                    // Proportional so this works at 96 on the profile and at 28
                    // in a row without a second set of numbers.
                    .font(.system(size: diameter * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    // Two wide letters at a small diameter would otherwise
                    // touch the edge of the disc.
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, diameter * 0.12)
            }
            .accessibilityLabel(name ?? email ?? "Your account")
    }

    // MARK: - Initials

    /// One or two letters, from the best source available.
    ///
    /// A name gives first-and-last; an address gives whatever the local part is
    /// made of, split on the separators people actually use. "gio.giorgadze@…"
    /// is GG, "giorgi@…" is G. Digits are dropped — "…20@gmail" shouldn't put a
    /// 2 on the disc.
    private var initials: String {
        if let name, let letters = Self.initials(fromWords: name.split(separator: " ")) {
            return letters
        }

        if let local = email?.split(separator: "@").first {
            let words = local.split(whereSeparator: { !$0.isLetter })
            if let letters = Self.initials(fromWords: words) { return letters }
        }

        return "?"
    }

    private static func initials(fromWords words: [Substring]) -> String? {
        let letters = words
            .compactMap(\.first)
            .filter(\.isLetter)
            .prefix(2)

        guard !letters.isEmpty else { return nil }
        return String(letters).uppercased()
    }

    // MARK: - Colour

    private var background: Color {
        Self.palette[Self.index(for: seed, count: Self.palette.count)]
    }

    /// Eight discs, and deliberately no red or green.
    ///
    /// Those two are spoken for: red is the app's accent and green means a
    /// session is running. An avatar that happened to be red would be the only
    /// red on Profile that doesn't mean "act on this", and the whole reason the
    /// accent works is that it appears rarely.
    private static let palette: [Color] = [
        Color(red: 0.35, green: 0.34, blue: 0.84),  // indigo
        Color(red: 0.58, green: 0.31, blue: 0.85),  // violet
        Color(red: 0.85, green: 0.28, blue: 0.58),  // magenta
        Color(red: 0.93, green: 0.49, blue: 0.19),  // orange
        Color(red: 0.16, green: 0.58, blue: 0.78),  // steel blue
        Color(red: 0.11, green: 0.60, blue: 0.60),  // teal
        Color(red: 0.47, green: 0.40, blue: 0.31),  // clay
        Color(red: 0.30, green: 0.44, blue: 0.72),  // slate
    ]

    /// A stable index for a string.
    ///
    /// FNV-1a rather than `hashValue`, and that's the whole point of writing it
    /// out: Swift seeds `Hashable` randomly *per process*, so a hash-based
    /// colour would be a different colour every single launch. This one is the
    /// same on every device, forever.
    private static func index(for seed: String, count: Int) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash % UInt64(count))
    }
}

#Preview {
    VStack(spacing: 20) {
        InitialsAvatar(email: "gio.giorgadze@example.com", seed: "user-1")
        HStack(spacing: 12) {
            ForEach(["a", "b", "c", "d", "e"], id: \.self) { seed in
                InitialsAvatar(name: "Giorgi Giorgadze", seed: seed, diameter: 44)
            }
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}
