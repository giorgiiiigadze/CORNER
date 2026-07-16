import SwiftUI

/// The last time the user touches the screen.
///
/// Every control here has a sensible default, so the real flow is
/// Start → swipe up → "let's go". Anyone who wants to change something can;
/// nobody has to. This is a sheet rather than a screen on purpose — it's a
/// decision, not a destination.
struct SessionSetupSheet: View {

    @Binding var request: SessionRequest
    let onStart: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Free text, because it becomes a line in a prompt. The presets cover the
    /// common cases; the field is there for "left hook, I keep dropping it".
    private static let presets = [
        "Balanced", "Technique", "Power", "Conditioning", "Body work",
        "Head movement", "Footwork", "Freestyle",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Today") {
                    Picker("Focus", selection: $request.focus) {
                        ForEach(Self.presets, id: \.self) { preset in
                            Text(preset).tag(preset)
                        }
                    }
                }

                Section {
                    Stepper("\(request.rounds) rounds", value: $request.rounds, in: 1...15)
                    Picker("Round length", selection: $request.roundSeconds) {
                        Text("2 min").tag(120)
                        Text("3 min").tag(180)
                        Text("5 min").tag(300)
                    }
                    Picker("Rest", selection: $request.restSeconds) {
                        Text("30 sec").tag(30)
                        Text("1 min").tag(60)
                        Text("90 sec").tag(90)
                    }
                } header: {
                    Text("Rounds")
                } footer: {
                    Text(total)
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Write it") {
                        dismiss()
                        onStart()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
        .preferredColorScheme(.dark)
    }

    private var total: String {
        let seconds = request.rounds * request.roundSeconds
            + max(0, request.rounds - 1) * request.restSeconds
        let minutes = seconds / 60
        return "\(minutes) minutes on the bag, including rest."
    }
}
