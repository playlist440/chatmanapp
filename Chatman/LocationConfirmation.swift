import SwiftUI
import ChatmanKit

/// What you're about to send, before it goes.
///
/// A location is the one message where being wrong matters and where the message itself
/// doesn't show it: six decimals look equally certain whether the phone found you by satellite
/// or guessed from a wifi network two streets away. So it gets a look first — on the same map
/// the person receiving it will end up on.
struct LocationConfirmation: View {
    @Environment(\.dismiss) private var dismiss

    let place: SharedLocation
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LocationPreview(place)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                details
            }
            .navigationTitle("Send your location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
    }

    private var details: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                if let address = place.address, !address.isEmpty {
                    Text(address)
                        .chatmanFont(size: 17, weight: .semibold, relativeTo: .headline)
                        .multilineTextAlignment(.center)
                }

                Text(place.coordinates)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)

                // Said plainly, because it's the reason to look at the map rather than the
                // numbers: a fix good to two hundred metres is a neighbourhood, not a house.
                if let accuracy = place.accuracy, accuracy > 20 {
                    Text("Accurate to about \(Int(accuracy.rounded())) m")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Button {
                onSend()
                dismiss()
            } label: {
                Text("Send")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Sent as a link anyone can open, whichever map app they use.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
