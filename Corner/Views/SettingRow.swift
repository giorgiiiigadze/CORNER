import SwiftUI

/// One setting: what it's called, what it does, and the control that does it.
///
/// The description sits under the title rather than in a section footer. A
/// footer explains a *group*, so a screen where every setting needs its own
/// sentence ends up with one setting per section — which is how a settings
/// screen turns into a list of unrelated cards. Here the sentence belongs to
/// the row, and settings that genuinely relate can share a section again.
struct SettingRow<Control: View>: View {

    let title: String
    let description: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    // Wraps rather than truncates: the description is the whole
                    // reason the row is this tall, and half a sentence is worse
                    // than none.
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            control
                // The control keeps its natural width and the text takes the
                // rest — the other way round, a long description squeezes a
                // toggle until it clips.
                .layoutPriority(1)
        }
        .padding(.vertical, 6)
    }
}

/// The same row without a control, for a value you tap through to change.
///
/// A `NavigationLink` draws its own chevron, so this deliberately doesn't — two
/// chevrons on one row is the sort of thing that reads as a bug.
extension SettingRow where Control == EmptyView {
    init(title: String, description: String) {
        self.init(title: title, description: description) { EmptyView() }
    }
}
