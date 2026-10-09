import SwiftUI
import ChatmanKit

/// What you're about to send, on a wrist.
///
/// The same idea as on the phone and the same map, with the crown for scrolling. A watch fix
/// taken indoors is the least reliable of the lot, so this is the screen where it matters
/// most — and it's also the moment you're most likely to be in a hurry, which is why Send is
/// one tap and sits where your thumb already is.
struct WatchLocationConfirmation: View {
    @Environment(\.dismiss) private var dismiss

    let place: SharedLocation
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                LocationPreview(place)
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)

                if let address = place.address, !address.isEmpty {
                    Text(address)
                        .font(.caption.weight(.medium))
                        .multilineTextAlignment(.center)
                }

                Text(place.coordinates)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)

                if let accuracy = place.accuracy, accuracy > 20 {
                    Text("± \(Int(accuracy.rounded())) m")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    onSend()
                    dismiss()
                } label: {
                    Text("Send")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
    }
}
