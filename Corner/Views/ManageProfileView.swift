import SwiftUI

/// The one screen where the fighter changes who the app thinks they are.
///
/// The shape is the reference Apple and everyone else uses for this: a large
/// avatar centred at the top, then grouped sections of tappable rows — a label
/// on the left, the current value greyed on the right, a chevron in. Nothing is
/// edited in place; each row pushes a small screen that does one thing.
///
/// What's here is chosen to fit Corner rather than copied field-for-field from a
/// social app. "About" is the name and a line of bio. "Body" is the two
/// measurements a training app can actually use plus a date of birth — and it
/// offers to fill them from Apple Health so most people never type them at all.
struct ManageProfileView: View {

    @Environment(AuthController.self) private var auth

    /// Read once so the whole screen shares one instance and one authorization
    /// prompt, rather than each import spinning up its own store.
    @State private var health = HealthProfile()
    @State private var importing = false
    @State private var importNote: String?

    /// Everything Health could fill is already filled. The import card hides once
    /// this is true — it exists to populate empty fields, not to sit around after.
    private var healthComplete: Bool {
        auth.heightCm != nil && auth.weightKg != nil && auth.birthdate != nil
    }

    var body: some View {
        List {
            avatarHeader

            // Only while there's still something for it to fill. Once height,
            // weight and date of birth are all set, the card has done its job and
            // would just be a button that re-reads what's already there.
            if health.isAvailable && !healthComplete {
                Section {
                    healthCard
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
            }

            Section("About") {
                NavigationLink {
                    TextFieldEditor(
                        title: "Name",
                        placeholder: "Your name",
                        initial: auth.displayName ?? "",
                        headline: "What should we call you?"
                    ) { await auth.updateProfile(displayName: $0) }
                } label: {
                    ProfileRow(title: "Name", value: auth.displayName, placeholder: "Add")
                }
            }
            .listRowBackground(Theme.Palette.surface)

            Section {
                NavigationLink {
                    MeasurementEditor(kind: .weight, initialSI: auth.weightKg) {
                        await auth.updateProfile(weightKg: $0)
                    }
                } label: {
                    ProfileRow(title: "Weight", value: Self.weightText(auth.weightKg), placeholder: "Add")
                }

                NavigationLink {
                    MeasurementEditor(kind: .height, initialSI: auth.heightCm) {
                        await auth.updateProfile(heightCm: $0)
                    }
                } label: {
                    ProfileRow(title: "Height", value: Self.heightText(auth.heightCm), placeholder: "Add")
                }

                NavigationLink {
                    BirthdateEditor(initial: auth.birthdate) { await auth.updateProfile(birthdate: $0) }
                } label: {
                    ProfileRow(title: "Date of birth", value: Self.birthdateText(auth.birthdate), placeholder: "Add")
                }
            } header: {
                Text("Body")
            } footer: {
                Text("Your height and weight let the cornerman size the work to you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("Manage Profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    /// The avatar, centred on the plain ground above the first card — the way
    /// the reference leads with the picture before any of the fields.
    ///
    /// The pencil badge is the recognisable "change your photo" affordance, but
    /// there's no upload flow yet — the picture is still initials on a coloured
    /// disc — so it's drawn as part of the avatar rather than wired to an action
    /// that would only disappoint. It goes live the day an image picker does.
    private var avatarHeader: some View {
        VStack(spacing: 0) {
            InitialsAvatar(
                name: auth.displayName,
                email: auth.email,
                seed: auth.userID ?? auth.email ?? "",
                diameter: 104
            )
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color(.systemGray3), in: .circle)
                    .overlay(Circle().stroke(Theme.Palette.background, lineWidth: 3))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - Apple Health

    /// The lead action of the screen, not a footnote under it.
    ///
    /// Importing from Health is the fast path — three fields filled from what the
    /// phone already knows, versus three screens of typing — so it's the first
    /// thing under the avatar, drawn as a full card with its own icon and a
    /// filled button, the shape iOS uses for the one thing it wants you to do on
    /// a screen. Manual entry stays below for anyone who'd rather, or who keeps
    /// nothing in Health.
    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 40, height: 40)
                    .background(Theme.Palette.accent, in: .rect(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Health")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Fill in your height, weight and date of birth automatically.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                Task { await importFromHealth() }
            } label: {
                Group {
                    if importing {
                        ProgressView().tint(.black)
                    } else {
                        Text("Fill in from Apple Health")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Theme.Palette.accent, in: Theme.buttonShape)
                .foregroundStyle(.black)
            }
            .disabled(importing)

            if let importNote {
                Text(importNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("You choose what it can read. Nothing leaves your phone without you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface, in: .rect(cornerRadius: 18))
    }

    /// Reads Health and saves whatever came back, one field at a time.
    ///
    /// Only writes the values Health actually had — a person who logged their
    /// weight but never their height gets the weight filled and the height left
    /// for them to add. Nothing is overwritten with nil.
    private func importFromHealth() async {
        importing = true
        importNote = nil
        defer { importing = false }

        let snapshot = await health.importSnapshot()
        guard !snapshot.isEmpty else {
            importNote = "Nothing to import. Add your details in the Health app, or enter them here."
            return
        }

        var saved = false
        if let kg = snapshot.weightKg { saved = await auth.updateProfile(weightKg: kg) || saved }
        if let cm = snapshot.heightCm { saved = await auth.updateProfile(heightCm: cm) || saved }
        if let dob = snapshot.birthdate { saved = await auth.updateProfile(birthdate: dob) || saved }

        importNote = saved
            ? "Filled in from Apple Health."
            : "Couldn't save what Health returned. Check your connection and try again."
    }

    // MARK: - Value formatting

    /// Weight and height are stored metric and shown in the reader's own units,
    /// so a value read from Health reads back the way they expect it. `nil`
    /// renders nothing — the row shows its "Add" prompt instead.

    private static var usesMetric: Bool { Locale.current.measurementSystem == .metric }

    static func weightText(_ kg: Double?) -> String? {
        guard let kg else { return nil }
        if usesMetric { return "\(Int(kg.rounded())) kg" }
        let lb = kg * 2.2046226218
        return "\(Int(lb.rounded())) lb"
    }

    static func heightText(_ cm: Double?) -> String? {
        guard let cm else { return nil }
        if usesMetric { return "\(Int(cm.rounded())) cm" }
        let totalInches = (cm / 2.54).rounded()
        let feet = Int(totalInches) / 12
        let inches = Int(totalInches) % 12
        return "\(feet)\u{2032} \(inches)\u{2033}"
    }

    static func birthdateText(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(.dateTime.year().month().day())
    }
}

/// One row of the profile list: a label, the current value greyed on the right,
/// and the chevron the enclosing `NavigationLink` supplies. When there's no
/// value yet it shows a faint "Add" so an empty field still reads as tappable.
private struct ProfileRow: View {
    let title: String
    let value: String?
    var placeholder: String = "Add"

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Text(value ?? placeholder)
                .foregroundStyle(value == nil ? .tertiary : .secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Editors

/// A one-field text editor pushed from a row. Handles both the single-line name
/// and the multi-line bio — the only difference is the text field's axis — and
/// owns its own save state so a slow network shows a spinner on the button that
/// caused it, not on the whole screen.
private struct TextFieldEditor: View {
    let title: String
    let placeholder: String
    let initial: String
    var axis: Axis = .horizontal
    var headline: String? = nil
    let save: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var failed = false
    @FocusState private var focused: Bool

    init(
        title: String,
        placeholder: String,
        initial: String,
        axis: Axis = .horizontal,
        headline: String? = nil,
        save: @escaping (String) async -> Bool
    ) {
        self.title = title
        self.placeholder = placeholder
        self.initial = initial
        self.axis = axis
        self.headline = headline
        self.save = save
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 16) {
            // A quiet white line above the field, so the screen asks rather than
            // just presents a box.
            if let headline {
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }

            // Big and borderless — the field is the screen, the same shape the
            // name step in onboarding uses. The placeholder greys out at the size
            // the typed value will land, so nothing shifts when they start.
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(.secondary), axis: axis)
                .font(.system(size: 34, weight: .bold))
                .multilineTextAlignment(.center)
                .focused($focused)
                .lineLimit(axis == .vertical ? 3 : 1, reservesSpace: axis == .vertical)
                .submitLabel(.done)
                .onSubmit { if axis == .horizontal { Task { await commit() } } }
                .padding(.top, 24)

            if failed {
                Text("Couldn't save. Check your connection and try again.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            // Pinned to the bottom, above the keyboard, and white — the primary
            // action of a screen that does exactly one thing.
            Button { Task { await commit() } } label: {
                Group {
                    if saving {
                        ProgressView().tint(.black)
                    } else {
                        Text("Save").font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(.white, in: Theme.buttonShape)
                .foregroundStyle(.black)
            }
            .disabled(saving || text == initial)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        // Keeps the Save button off the top of the keyboard.
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.Palette.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // Opens the keyboard the instant the screen does, so there's nothing to
        // tap before typing.
        .onAppear { focused = true }
    }

    private func commit() async {
        saving = true
        failed = false
        let ok = await save(text)
        saving = false
        if ok { dismiss() } else { failed = true }
    }
}

/// Height or weight, entered in the reader's own units and saved metric.
///
/// One editor for both because the shape is identical — a value, a unit, a Save
/// — and the only thing that differs is how many fields the unit needs: weight
/// and metric height are a single number, imperial height is feet and inches.
private struct MeasurementEditor: View {

    enum Kind { case weight, height }

    let kind: Kind
    /// The stored value, in SI: kilograms for weight, centimetres for height.
    let initialSI: Double?
    let save: (Double) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var primary: String = ""
    @State private var inches: String = ""
    @State private var saving = false
    @State private var failed = false

    private var usesMetric: Bool { Locale.current.measurementSystem == .metric }

    /// Whether this is the imperial-height case that needs a second field.
    private var isFeetInches: Bool { kind == .height && !usesMetric }

    var body: some View {
        List {
            Section {
                if isFeetInches {
                    HStack {
                        unitField($primary, unit: "ft")
                        unitField($inches, unit: "in")
                    }
                } else {
                    unitField($primary, unit: unitLabel)
                }
            } footer: {
                if failed {
                    Text("Couldn't save. Check your connection and try again.")
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle(kind == .weight ? "Weight" : "Height")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await commit() } }
                        .disabled(siValue == nil)
                }
            }
        }
        .onAppear(perform: seedFields)
    }

    private func unitField(_ text: Binding<String>, unit: String) -> some View {
        HStack {
            TextField("0", text: text)
                .keyboardType(.decimalPad)
            Text(unit)
                .foregroundStyle(.secondary)
        }
    }

    private var unitLabel: String {
        switch kind {
        case .weight: usesMetric ? "kg" : "lb"
        case .height: "cm"
        }
    }

    /// Fills the fields from the stored SI value, converted to the shown units.
    private func seedFields() {
        guard let initialSI else { return }
        switch kind {
        case .weight:
            let value = usesMetric ? initialSI : initialSI * 2.2046226218
            primary = String(Int(value.rounded()))
        case .height where usesMetric:
            primary = String(Int(initialSI.rounded()))
        case .height:
            let totalInches = Int((initialSI / 2.54).rounded())
            primary = String(totalInches / 12)
            inches = String(totalInches % 12)
        }
    }

    /// The entered value converted back to SI, or nil when the fields don't
    /// parse to a sensible number — which is what disables Save.
    private var siValue: Double? {
        switch kind {
        case .weight:
            guard let value = Double(primary.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
            return usesMetric ? value : value / 2.2046226218
        case .height where usesMetric:
            guard let value = Double(primary.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
            return value
        case .height:
            let feet = Double(primary) ?? 0
            let inch = Double(inches) ?? 0
            let totalInches = feet * 12 + inch
            guard totalInches > 0 else { return nil }
            return totalInches * 2.54
        }
    }

    private func commit() async {
        guard let siValue else { return }
        saving = true
        failed = false
        let ok = await save(siValue)
        saving = false
        if ok { dismiss() } else { failed = true }
    }
}

/// Date of birth, on a wheel. A birthday is a day, not an appointment, so the
/// picker shows date only, and it can't be in the future.
private struct BirthdateEditor: View {
    let initial: Date?
    let save: (Date) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var saving = false
    @State private var failed = false

    init(initial: Date?, save: @escaping (Date) async -> Bool) {
        self.initial = initial
        self.save = save
        // Defaults to a plausible adult birthday rather than today, so the wheel
        // opens somewhere a person is likely to scroll *from*, not a year they'd
        // never pick.
        _date = State(initialValue: initial ?? Calendar.current.date(byAdding: .year, value: -25, to: .now) ?? .now)
    }

    var body: some View {
        List {
            Section {
                DatePicker(
                    "Date of birth",
                    selection: $date,
                    in: ...Date.now,
                    displayedComponents: .date
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            } footer: {
                if failed {
                    Text("Couldn't save. Check your connection and try again.")
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .listRowBackground(Theme.Palette.surface)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("Date of birth")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await commit() } }
                }
            }
        }
    }

    private func commit() async {
        saving = true
        failed = false
        let ok = await save(date)
        saving = false
        if ok { dismiss() } else { failed = true }
    }
}
