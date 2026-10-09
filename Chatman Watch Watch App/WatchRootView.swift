import SwiftUI
import ChatmanKit

/// Decides what the watch shows.
struct WatchRootView: View {
    @Environment(ChatSession.self) private var session

    /// What's open on top of the list. Held here rather than in the list so a chat that was
    /// just started can be opened without waiting for someone to find it again.
    @State private var path: [WatchRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            switch session.state {
            case .signedOut, .signingIn:
                WatchSignInPrompt()

            case .firstSync:
                WatchFirstSyncView()

            case .firstSyncFailed(let reason):
                WatchProblemView(reason: reason)

            case .ready, .offline:
                WatchConversationListView(path: $path)
                    // Once there is something to tap you about, ask whether that's allowed.
                    .task { await WristTap.prepare() }
            }
        }
        // A tap on a notification, straight into the conversation it was about.
        .onChange(of: session.requestedConversationID) { _, requested in
            guard let requested, let conversation = session.conversation(withID: requested) else { return }
            session.requestedConversationID = nil
            path = [.conversation(conversation)]
        }
    }
}

/// Sign-in happens on the phone.
///
/// Typing a server address and password on a watch is miserable, and the session is already
/// on the phone. Saying so plainly beats offering a form nobody wants to fill in.
private struct WatchSignInPrompt: View {
    @Environment(ChatSession.self) private var session

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                Text("Sign in on your iPhone")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Open Chatman on your phone and sign in. Your watch picks it up from there.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // Waiting and failing look identical without this.
                if let status = session.linkStatus {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

/// The same wording as the phone, at watch size.
///
/// A spinner labelled "Loading" says nothing about how long or why. Away from the phone, on a
/// cellular connection, that difference decides whether someone waits or gives up.
private struct WatchFirstSyncView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)

                Text("Getting your conversations")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("This only takes a moment the first time.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 4)
            .padding(.top, 12)
        }
    }
}

private struct WatchProblemView: View {
    @Environment(ChatSession.self) private var session
    let reason: String

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.title2)
                    .foregroundStyle(.orange)

                Text("Can't reach your server")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Try again") { session.retryFirstSync() }
            }
            .padding(.horizontal, 4)
        }
    }
}
