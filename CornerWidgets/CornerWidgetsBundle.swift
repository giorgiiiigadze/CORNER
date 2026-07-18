import ActivityKit
import SwiftUI
import WidgetKit

@main
struct CornerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SessionActivityWidget()
    }
}

/// The running session, seen from the Lock Screen and the Dynamic Island.
///
/// Strava's shape: identity in the corner, the state on the left, the number
/// that matters big on the right. It exists for the phone that's face-up on a
/// bench with the app backgrounded — the one place the in-app timer can't reach.
struct SessionActivityWidget: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            SessionActivityCard(state: context.state)
                .activityBackgroundTint(Palette.wash(for: context.state.phase))
                .activitySystemActionForegroundColor(Palette.primaryText)
        } dynamicIsland: { context in
            DynamicIsland {
                // The focus rides in `.center`, which is the strip directly
                // under the sensor cutout — that's what puts the title above
                // the numbers instead of beside them. Leading and trailing stay
                // empty on purpose: anything in them flanks the cutout and
                // pulls the eye sideways, which is the layout we're replacing.
                DynamicIslandExpandedRegion(.center) {
                    Text(headline(for: context.state))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                // `.bottom` spans the full width below the cutout, so the clock
                // lands centred under the island rather than off to one side.
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityStatRow(state: context.state, clockSize: 44)
                        .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "figure.boxing")
                    .foregroundStyle(Palette.clock(for: context.state.phase))
            } compactTrailing: {
                ActivityClock(state: context.state)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Palette.clock(for: context.state.phase))
                    .frame(maxWidth: 44)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } minimal: {
                Image(systemName: "figure.boxing")
                    .foregroundStyle(Palette.clock(for: context.state.phase))
            }
            .keylineTint(Palette.accent)
        }
    }

    private func headline(for state: SessionActivityAttributes.ContentState) -> String {
        state.phase == .rest ? "Rest" : state.focus
    }
}

/// One stat in the row: the number, and what the number means under it.
///
/// The label is what makes a bare figure readable at arm's length — "4" means
/// nothing on its own, "4 / To go" is a session you can size up without
/// picking the phone up.
private struct ActivityStat<Value: View>: View {

    let value: Value
    let label: String
    var emphasis: Bool = false

    var body: some View {
        VStack(spacing: 1) {
            value
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: emphasis ? .infinity : nil)
    }
}

/// The three stats, side by side, clock in the middle.
///
/// Shared by the Lock Screen card and the Dynamic Island's `.bottom` region so
/// the two surfaces can't drift apart — the island only asks for a smaller
/// clock, because it has less room above it.
private struct ActivityStatRow: View {

    let state: SessionActivityAttributes.ContentState
    let clockSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ActivityStat(
                value: Text("\(state.roundIndex)/\(state.totalRounds)")
                    .font(.system(size: clockSize * 0.52, weight: .heavy).monospacedDigit())
                    .foregroundStyle(Palette.primaryText),
                label: "Round"
            )
            .frame(maxWidth: .infinity)

            ActivityStat(
                value: ActivityClock(state: state)
                    .font(.system(size: clockSize, weight: .heavy).monospacedDigit())
                    .foregroundStyle(Palette.clock(for: state.phase)),
                label: caption,
                emphasis: true
            )

            ActivityStat(
                value: Text("\(max(0, state.totalRounds - state.roundIndex))")
                    .font(.system(size: clockSize * 0.52, weight: .heavy).monospacedDigit())
                    .foregroundStyle(Palette.primaryText),
                label: "To go"
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var caption: String {
        switch state.phase {
        case .announcing: "Get ready"
        case .work: "This round"
        case .rest: "Breathe"
        case .paused: "Paused"
        case .done: "Session over"
        }
    }
}

/// The Lock Screen banner.
///
/// Strava's shape, because it solves the same problem: the phone is face-up on
/// a bench and you get one glance. Title centred on top, three stats in a row
/// under it, and the one that matters — the clock — sitting in the middle at
/// twice the size of its neighbours. The eye lands on the big number first and
/// only reaches for the flanks if it wants them.
struct SessionActivityCard: View {

    let state: SessionActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 28)
                HStack {
                    Spacer()
                    Image(systemName: "figure.boxing")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
            }

            ActivityStatRow(state: state, clockSize: 46)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headline: String {
        switch state.phase {
        case .rest: "Rest"
        case .done: "Done"
        default: state.focus
        }
    }

    private var caption: String {
        switch state.phase {
        case .announcing: "Get ready"
        case .work: "This round"
        case .rest: "Breathe"
        case .paused: "Paused"
        case .done: "Session over"
        }
    }
}

/// The countdown. The system runs it toward `endsAt` without waking anyone;
/// when nothing is running — paused, opener being spoken, done — it's a
/// frozen number instead, because a clock that moves through a pause lies.
struct ActivityClock: View {

    let state: SessionActivityAttributes.ContentState

    var body: some View {
        if let end = state.endsAt, end > .now {
            Text(timerInterval: Date.now...end, countsDown: true)
                .multilineTextAlignment(.trailing)
        } else {
            Text(frozen)
        }
    }

    private var frozen: String {
        String(format: "%d:%02d", state.secondsRemaining / 60, state.secondsRemaining % 60)
    }
}

/// Theme.swift's live palette, restated. The widget can't see the app
/// target's sources, and a handful of colours don't earn a shared framework —
/// if `Theme.Live` changes, change these to match.
///
/// Deliberately dark, unlike the app's off-white chrome. The Dynamic Island is
/// always dark and the Lock Screen sits over whatever wallpaper you have, so a
/// card that brings its own near-black stays legible in both places — the same
/// reason Strava's does. The green/red phase signal survives the switch; it
/// just moves off the background and onto the clock, brightened to hold
/// contrast against black.
private enum Palette {

    static let accent = Color(red: 1.0, green: 0.29, blue: 0.16)
    static let work = Color(red: 0.30, green: 0.85, blue: 0.45)
    static let resting = Color(red: 1.0, green: 0.42, blue: 0.38)
    static let primaryText = Color.white
    static let secondaryText = Color(white: 0.62)
    static let surface = Color(white: 0.04)

    /// A single near-black behind every phase. The app's screen carries the
    /// green/red wash; here it would fight the wallpaper for no gain, so the
    /// colour lives on the clock instead.
    static func wash(for phase: SessionActivityAttributes.Phase) -> Color {
        surface
    }

    static func clock(for phase: SessionActivityAttributes.Phase) -> Color {
        switch phase {
        case .work: work
        case .rest: resting
        case .announcing, .paused, .done: primaryText
        }
    }
}
