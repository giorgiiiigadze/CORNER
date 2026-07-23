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

    /// Ten discs, the supplied set.
    ///
    /// This includes a red (#E74C3C) and two greens (#27AE60, #2ECC71), which
    /// the earlier palette deliberately avoided — red is the app's accent and
    /// green means a session is running. They're a different enough shade here
    /// (a flat orange-red, a Nephritis green) not to read as those signals on a
    /// small disc, but it's the reason the count is 10 and not the eight this
    /// started with: the constraint was dropped on purpose, not by oversight.
    private static let palette: [Color] = [
        Color(red: 0.906, green: 0.298, blue: 0.235),  // #E74C3C red
        Color(red: 0.902, green: 0.494, blue: 0.133),  // #E67E22 orange
        Color(red: 0.153, green: 0.682, blue: 0.376),  // #27AE60 green
        Color(red: 0.180, green: 0.800, blue: 0.443),  // #2ECC71 emerald
        Color(red: 0.102, green: 0.737, blue: 0.612),  // #1ABC9C teal
        Color(red: 0.161, green: 0.502, blue: 0.725),  // #2980B9 blue
        Color(red: 0.557, green: 0.267, blue: 0.678),  // #8E44AD purple
        Color(red: 0.847, green: 0.106, blue: 0.376),  // #D81B60 pink
        Color(red: 0.000, green: 0.592, blue: 0.655),  // #0097A7 cyan
        Color(red: 1.000, green: 0.341, blue: 0.133),  // #FF5722 deep orange
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
