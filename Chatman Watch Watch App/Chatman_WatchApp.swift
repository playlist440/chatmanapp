import SwiftUI
import SwiftData
import UserNotifications
import ChatmanKit

@main
struct Chatman_Watch_Watch_AppApp: App {

    @Environment(\.scenePhase) private var scenePhase

    private let container: ModelContainer
    @State private var session: ChatSession

    /// Answers taps on the wrist. See `WristTap`.
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate

    /// Built only when a screen was named on the command line. Left as a stored property it
    /// was made on every launch — a second store, seeded with invented conversations, for
    /// nothing.
    private let preview: (ChatSession, ModelContainer)?

    init() {
        let container = Self.makeContainer()
        self.container = container

        // The watch profile asks the server for less and waits longer between retries.
        // Everything the phone shows that the watch doesn't — typing indicators, read
        // receipts, presence — is traffic that would wake the radio for nothing.
        _session = State(initialValue: ChatSession(profile: .watch, container: container))
        preview = WatchDesignPreview.requested == nil ? nil : WatchDesignPreview.makeSession()
    }

    var body: some Scene {
        WindowGroup {
            if WatchDesignPreview.requested != nil, let preview {
                WatchDesignPreviewView(session: preview.0)
                    .modelContainer(preview.1)
            } else {
                WatchRootView()
                    .environment(session)
                    .modelContainer(container)
                    // Signing in on the phone is enough; the watch is handed the session.
                    .task {
                        WatchDelegate.session = session
                        session.startDeviceLink()
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // On a watch this fires constantly: every time the wrist drops, the app is
            // suspended. Stopping cleanly and resuming quickly matters more here than
            // anywhere else.
            switch phase {
            case .active:
                // One sync, not two. The loop's first request comes back at once when there is
                // anything new — the server only holds a poll open when there is nothing to
                // say — so the extra catch-up this used to start beside it was the same news
                // fetched twice over the watch's radio, on every raise of the wrist.
                session.startSyncing()
                Task { await session.tidyUpIfDue() }
            case .inactive, .background:
                session.stopSyncing()
                // Ask to be woken. Going to the background is the only moment this is worth
                // asking for: while the app is open the sync loop is already running.
                BackgroundRefresh.schedule()
            @unknown default:
                break
            }
        }
        // Where the number on the watch face comes from when the app is shut.
        //
        // There is no push — a free developer account has no certificate for it — so nothing
        // arrives on its own. This is watchOS handing the app a few seconds now and then,
        // which is exactly enough for one sync that doesn't wait around.
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            // The watch face is told by the sync itself, and only when the number changed.
            // This used to ask for a redraw after every wake-up as well, which spent the
            // face's daily allowance on a number that stayed the same — and once that was
            // gone, the redraw for a number that did change was the one refused.
            await session.refreshInBackground()

            // Asked for again straight away: each wake-up only ever buys the next one.
            await BackgroundRefresh.schedule()
        }
    }

    private static func makeContainer() -> ModelContainer {
        let schema = Schema([Conversation.self, Message.self])

        if let container = try? ModelContainer(for: schema) {
            return container
        }

        // The store is only ever a cache of what the server holds, so starting over beats
        // refusing to launch — and starting over means clearing the file that wouldn't open.
        // This went straight to memory before and left the broken file where it was, so it
        // failed again on every launch after, and every launch was a first sync over
        // cellular. The journal files go too: a fresh store beside an old journal is
        // SQLite's to reconcile, and that is not a question worth asking it.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL.applicationSupportDirectory.appending(path: "default.store" + suffix)
            )
        }

        if let fresh = try? ModelContainer(for: schema) {
            return fresh
        }

        // Last resort: run without persistence rather than not run at all.
        let memoryOnly = ModelConfiguration(isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: memoryOnly)
    }
}

/// Where a tap on a notification lands.
///
/// Opening it opens the conversation. Its one button mutes the conversation, the same way a
/// swipe in the list does — on the server, so it is muted everywhere, and the rule that decides
/// what taps you stops counting it from then on.
final class WatchDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {

    @MainActor static weak var session: ChatSession?

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let room = info[WristTap.roomKey] as? String else { return }
        let action = response.actionIdentifier

        await MainActor.run {
            guard let session = Self.session,
                  let conversation = session.conversation(withID: room)
            else { return }

            if action == WristTap.muteAction {
                Task { await session.setMuted(true, for: conversation) }
            } else {
                session.open(conversationID: room)
            }
        }
    }

    /// While the app is open nothing is posted, so anything that shows up now is old news.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }
}
