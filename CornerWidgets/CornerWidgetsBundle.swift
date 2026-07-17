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
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Round \(context.state.roundIndex) of \(context.state.totalRounds)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(headline(for: context.state))
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityClock(state: context.state)
                        .font(.title2.weight(.heavy).monospacedDigit())
                        .foregroundStyle(Palette.clock(for: context.state.phase))
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

/// The Lock Screen banner.
struct SessionActivityCard: View {

    let state: SessionActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Round \(state.roundIndex) of \(state.totalRounds)")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                Text(headline)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Palette.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                ActivityClock(state: state)
                    .font(.system(size: 40, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.clock(for: state.phase))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .padding()
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
/// target's sources, and four colours don't earn a shared framework —
/// if `Theme.Live` changes, change these to match.
private enum Palette {

    static let accent = Color(red: 1.0, green: 0.29, blue: 0.16)
    static let work = Color(red: 0.10, green: 0.52, blue: 0.24)
    static let resting = Color(red: 0.70, green: 0.12, blue: 0.10)
    static let primaryText = Color(white: 0.09)
    static let secondaryText = Color(white: 0.45)
    static let background = Color(red: 0.973, green: 0.969, blue: 0.961)
    static let workWash = Color(red: 0.87, green: 0.94, blue: 0.87)
    static let restWash = Color(red: 0.94, green: 0.87, blue: 0.87)

    /// The same statement the app's whole screen makes: green while the round
    /// runs, red while you breathe, off-white otherwise.
    static func wash(for phase: SessionActivityAttributes.Phase) -> Color {
        switch phase {
        case .work: workWash
        case .rest: restWash
        case .announcing, .paused, .done: background
        }
    }

    static func clock(for phase: SessionActivityAttributes.Phase) -> Color {
        switch phase {
        case .work: work
        case .rest: resting
        case .announcing, .paused, .done: primaryText
        }
    }
}
