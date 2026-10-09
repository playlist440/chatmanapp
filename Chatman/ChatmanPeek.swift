import SwiftUI

/// Chatman himself, looking over the bottom of the settings screen.
///
/// The same character as the app icon rather than a drawing of him: it's the picture the app
/// is named after, and half a face appearing over the edge is the joke. Small and to one
/// side on purpose — it's a wink, and a wink that demands attention isn't one.
///
/// He used to duck now and then. He stands still now: a loop running on the settings screen
/// for a joke nobody waits for is work the phone does for nothing.
struct ChatmanPeek: View {

    /// Small enough to be a detail, big enough to be recognised.
    private let height: CGFloat = 44

    var body: some View {
        Image("chatman-peek")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityHidden(true)
    }
}
