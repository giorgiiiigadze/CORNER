import SwiftUI

/// The one thing Home is for: the session waiting to be trained, and the way
/// into it.
///
/// Modelled on the Fitness "start workout" card — a quiet label, the name of the
/// thing in type you can read across a room, the shape of it in one line, and a
/// single filled control that is the whole point of the screen. The secondary
/// way out sits under the button as plain text, the way "Skip" sits under a
/// primary action, so there's never a question which of the two the card wants
/// you to press.
///
/// Two states, one frame. With a plan it's today's session and Start trains it;
/// without one it's an invitation and Start writes one. The container doesn't
/// change between them because the decision doesn't — you came here to train.
struct TodaySessionCard: View {

    /// Today's plan, or nil when none has been written yet.
    let plan: TodaySession?

    /// How many of the plan's rounds are already behind you. Turns "Start" into
    /// "Resume" and the header into a line that admits the session's mid-flight.
    var doneRounds: Int = 0

    /// The primary action: train the plan, or — with no plan — open the sheet
    /// that writes one.
    let onStart: () -> Void

    private var isResuming: Bool { plan != nil && doneRounds > 0 }

    /// The reminder sheet, and the time it's set to. Local to the card because
    /// there's nothing above it that needs to know a reminder is being picked —
    /// only that one got scheduled, which the toast below reports.
    @State private var pickingTime = false

    /// Defaults an hour out, on the minute — a plausible "later today", not this
    /// exact second, which no one means.
    @State private var reminderTime = Date.now.addingTimeInterval(3600)

    /// The confirmation line under the buttons after a reminder lands. Nil until
    /// one does.
    @State private var scheduledFor: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(header)
                .font(.footnote.weight(.semibold))
                .kerning(0.8)
                .foregroundStyle(Theme.Palette.accent)

            Text(headline)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .padding(.top, 6)

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }

            actions
                .padding(.top, 22)

            if let scheduledFor {
                // The one line that confirms the reminder took. Under the
                // buttons, quiet, and gone the moment the session starts.
                Label("Reminder set for \(scheduledFor.formatted(date: .omitted, time: .shortened))", systemImage: "bell.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The grouped-list card lift, and a wash of the accent bled up from the
        // top-left corner — the mockup's glow, kept faint so it reads as the
        // card catching the brand rather than a second surface.
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.dashboardSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.Palette.accent.opacity(0.16), .clear],
                                startPoint: .topLeading,
                                endPoint: .center
                            )
                        )
                }
        }
        .sheet(isPresented: $pickingTime) { reminderSheet }
    }

    // MARK: - Actions

    /// One filled control with no plan, two side by side with one: set a
    /// reminder, or start. The pair is the shape the reference uses — a plain
    /// glass secondary and a tinted-glass primary, equal width — because setting
    /// a time and training now are two answers to the same question and neither
    /// outranks the other enough to be the smaller word.
    ///
    /// Native Liquid Glass rather than hand-drawn capsules: `.glass` and
    /// `.glassProminent` are the system's own button styles, so these get the
    /// real material, the press-in refraction and the shape morphing for free,
    /// and match the tab bar and the accessory drawn from the same glass.
    private var actions: some View {
        // The same pair in both states. With a plan the reminder is pinned to
        // that session; without one it's a plain nudge to come back and train —
        // still worth setting, so the button is here either way rather than
        // appearing only once a plan exists.
        HStack(spacing: 12) {
            Button {
                pickingTime = true
            } label: {
                Text("Set Reminder")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .buttonBorderShape(.capsule)

            Button(action: onStart) {
                primaryLabel
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.Palette.accent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
        }
    }

    private var primaryLabel: some View {
        Text(startTitle)
            .font(.headline)
            // Black on the lime, whatever the prominent style would pick on its
            // own — the accent is bright enough that a light label would vanish.
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
    }

    /// A time and a confirm, and nothing else. The date is fixed to today —
    /// the whole idea is a nudge later *today*, not a calendar — so the picker
    /// offers the hour and minute alone.
    private var reminderSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                DatePicker(
                    "When",
                    selection: $reminderTime,
                    in: Date.now...,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()

                Button(action: setReminder) {
                    Text("Set reminder")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.Palette.accent, in: .capsule)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(24)
            .navigationTitle("Remind me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { pickingTime = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func setReminder() {
        let time = reminderTime
        // A plan pins the reminder to its session; without one it's a standing
        // "home" reminder to come back and train. The fixed id means either
        // kind replaces the last, so there's never a stack of them.
        let sessionID = plan?.sessionID ?? "home-reminder"
        let focus = plan?.focus ?? ""

        Task {
            let ok = await SessionReminder.schedule(
                at: time,
                sessionID: sessionID,
                focus: focus
            )
            await MainActor.run {
                if ok { scheduledFor = time }
                pickingTime = false
            }
        }
    }

    // MARK: - Copy

    private var header: String {
        isResuming ? "PICK UP WHERE YOU LEFT OFF" : "TODAY'S SESSION"
    }

    private var startTitle: String {
        // "Start" alone now the button shares the row with Set Reminder —
        // "Start a session" wrapped to two lines in half the width, and the
        // headline already says session.
        isResuming ? "Resume" : "Start"
    }

    private var headline: String {
        guard let plan else { return "Start a session" }
        // What today is *for*, not what the session is called. The focus is the
        // one word the fighter came to see — the title ("Sharpening day") is
        // flavour, the focus ("Guard") is the plan. Falls back to the title,
        // then the subtitle, only when a plan somehow carries no focus.
        let focus = plan.focus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !focus.isEmpty { return focus.capitalized }
        return plan.session?.title ?? plan.subtitle
    }

    /// "6 rounds · 3 min". Nil with no plan — there's nothing to describe, and
    /// the invitation reads better without an empty line under it. The focus is
    /// no longer here: it's the headline now, and repeating it under itself was
    /// the same word twice.
    private var detail: String? {
        guard let plan else { return nil }

        var parts = ["\(plan.roundCount) \(plan.roundCount == 1 ? "round" : "rounds")"]

        // The round length, off the first round — every round in a plan runs the
        // same clock, so one of them stands for all.
        if let seconds = plan.session?.rounds.first?.durationSeconds, seconds >= 60 {
            parts.append("\(seconds / 60) min")
        }

        return parts.joined(separator: "  ·  ")
    }
}
