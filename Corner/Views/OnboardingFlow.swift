import SwiftUI

/// First run, for a brand-new account only.
///
/// Three steps, in the order a fighter meets the app: what it is, who they are,
/// and letting Apple Health fill in the rest. Shown once, right after sign-up —
/// never on sign-in, where the person already knows all three answers. See
/// `AuthController.isNewAccount`, which is the only thing that opens this.
///
/// Each step is one idea with one button, the same discipline the old welcome
/// sheet kept. Nothing here is required: a name can wait, Health can be declined,
/// and every screen has a way past it, because a setup flow that traps someone at
/// the door is worse than an app that learns their name later.
struct OnboardingFlow: View {

    /// Called when they reach the end or skip out of the last step. The caller
    /// clears `isNewAccount` and marks the welcome seen so nothing re-presents.
    let onFinish: () -> Void

    @Environment(AuthController.self) private var auth

    @State private var step: Step = .welcome
    @State private var name: String = ""
    @State private var savingName = false
    @FocusState private var nameFocused: Bool

    @State private var health = HealthProfile()
    @State private var importing = false
    @State private var imported = false
    @State private var importNote: String?

    private enum Step: Int, CaseIterable {
        case welcome, name, health
    }

    var body: some View {
        VStack(spacing: 0) {
            progress
                .padding(.top, 20)
                .padding(.horizontal, 24)

            Group {
                switch step {
                case .welcome: welcomeStep
                case .name: nameStep
                case .health: healthStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .background(Theme.Palette.background)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .onAppear { name = auth.displayName ?? "" }
    }

    // MARK: - Progress

    /// Three dots, filling as they move through. Small on purpose — it's a
    /// reassurance that this is short, not a control.
    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Theme.Palette.accent : Theme.Palette.pill)
                    .frame(width: s == step ? 22 : 7, height: 7)
                    .animation(.snappy, value: step)
            }
            Spacer()
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        stepBody(
            icon: "figure.boxing",
            title: "He Talks You Through Every Round",
            message: "Prop your phone up and leave it. Every round is called out loud: what it's for, and the one thing to hold onto. It's on by default."
        )
    }

    private var nameStep: some View {
        VStack(spacing: 0) {
            Text("What should the cornerman call you?")
                .font(.system(size: 22, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 32)

            // Big, borderless, its own line — the field is the screen, not a box
            // inside it. The placeholder greys out at the same size the typed
            // name will land, so nothing shifts when they start.
            TextField("", text: $name, prompt: Text("Your name").foregroundColor(.secondary))
                .font(.system(size: 34, weight: .bold))
                .focused($nameFocused)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit(primaryAction)
                .padding(.top, 40)

            Spacer()
        }
        .padding(.horizontal, 24)
        .onAppear { nameFocused = true }
    }

    private var healthStep: some View {
        VStack(spacing: 0) {
            Spacer()
            iconMark("heart.fill", tint: Theme.Palette.accent)
            Text("Connect Apple Health")
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 28)
            Text(health.isAvailable
                 ? "Pull your height, weight and date of birth from Apple Health so the cornerman can size the work to you. You choose what it can read."
                 : "Apple Health isn't available on this device. You can add your height and weight any time in Manage Profile.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            if let importNote {
                Label(importNote, systemImage: imported ? "checkmark.circle.fill" : "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(imported ? .green : .secondary)
                    .padding(.top, 20)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    /// The shared shape for a plain step: a mark, a title, a line under it.
    private func stepBody(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 0) {
            Spacer()
            iconMark(icon, tint: Theme.Palette.accent)
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 28)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 12)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private func iconMark(_ systemName: String, tint: Color = .white) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 104, height: 104)
            .background(Theme.Palette.surface, in: .circle)
    }

    // MARK: - Footer

    /// The primary button, and — where a step is optional — a quiet way past it.
    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 14) {
            Button(action: primaryAction) {
                Group {
                    if savingName || importing {
                        ProgressView().tint(.white)
                    } else {
                        Text(primaryTitle).font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Theme.Palette.accent, in: Theme.buttonShape)
                .foregroundStyle(.white)
            }
            .disabled(savingName || importing)

            if let secondaryTitle {
                Button(secondaryTitle, action: advanceOrFinish)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .disabled(importing)
            }
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Continue"
        case .name: "Continue"
        case .health: health.isAvailable && !imported ? "Connect Apple Health" : "Start training"
        }
    }

    /// The skip line, shown only where there's something to skip.
    private var secondaryTitle: String? {
        switch step {
        case .welcome: nil
        case .name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Skip for now" : nil
        case .health: health.isAvailable && !imported ? "Not now" : nil
        }
    }

    // MARK: - Actions

    private func primaryAction() {
        switch step {
        case .welcome:
            advanceOrFinish()
        case .name:
            Task {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    savingName = true
                    _ = await auth.updateProfile(displayName: trimmed)
                    savingName = false
                }
                advanceOrFinish()
            }
        case .health:
            if health.isAvailable && !imported {
                Task { await connectHealth() }
            } else {
                advanceOrFinish()
            }
        }
    }

    /// Reads Health and saves whatever it returned, then either moves on or lets
    /// them tap "Start training". Never blocks the flow on a refusal — an empty
    /// result just leaves the fields for Manage Profile.
    private func connectHealth() async {
        importing = true
        importNote = nil
        defer { importing = false }

        let snapshot = await health.importSnapshot()
        if let kg = snapshot.weightKg { _ = await auth.updateProfile(weightKg: kg) }
        if let cm = snapshot.heightCm { _ = await auth.updateProfile(heightCm: cm) }
        if let dob = snapshot.birthdate { _ = await auth.updateProfile(birthdate: dob) }

        imported = true
        importNote = snapshot.isEmpty
            ? "Nothing to import yet. You can add your details in Manage Profile."
            : "Imported from Apple Health."
    }

    /// Moves to the next step, or ends the flow on the last one.
    private func advanceOrFinish() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            onFinish()
            return
        }
        withAnimation(.snappy) { step = next }
    }
}
