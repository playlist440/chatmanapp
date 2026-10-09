import SwiftUI
import ChatmanKit

/// Decides what the app shows: the sign-in screen, or your conversations.
struct RootView: View {
    @Environment(ChatSession.self) private var session

    var body: some View {
        switch session.state {
        case .signedOut, .signingIn:
            SignInView()

        case .firstSync:
            FirstSyncView()

        case .firstSyncFailed(let reason):
            FirstSyncFailedView(reason: reason)

        case .ready, .offline:
            ConversationListView()
        }
    }
}

/// Shown while the first sync runs, when there's genuinely nothing to display yet.
///
/// Every later sync happens behind whatever is already on screen — once there are cached
/// conversations, a spinner would only hide them.
private struct FirstSyncView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            Text("Getting your conversations")
                .chatmanFont(size: 17, weight: .semibold, relativeTo: .headline)

            Text("This only takes a moment the first time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// Shown when the very first sync can't complete.
///
/// Other Matrix clients leave people on a spinner forever here; a named problem and a button
/// is the difference between a bug report and a retry.
private struct FirstSyncFailedView: View {
    @Environment(ChatSession.self) private var session
    let reason: String

    var body: some View {
        ContentUnavailableView {
            Label("Can't reach your server", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text(reason)
        } actions: {
            Button("Try again") { session.retryFirstSync() }
                .buttonStyle(.borderedProminent)

            Button("Sign out") {
                Task { await session.signOut() }
            }
        }
    }
}
