import SwiftUI
import SwiftData
import ChatmanKit

@main
struct ChatmanApp: App {

    @Environment(\.scenePhase) private var scenePhase

    /// Handles the token Apple hands back, when there is one to hand back.
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar

    private let container: ModelContainer
    @State private var session: ChatSession

    /// Built only when a screen was named on the command line. Left as a stored property it
    /// was made on every launch — a second store, seeded with invented conversations, for
    /// nothing.
    private let preview: (ChatSession, ModelContainer)?

    init() {
        let container = Self.makeContainer()
        self.container = container
        let session = ChatSession(profile: .phone, container: container)
        _session = State(initialValue: session)
        IntentSession.current = session
        preview = DesignPreview.requested == nil ? nil : DesignPreview.makeSession()
    }

    var body: some Scene {
        WindowGroup {
            // Only ever true when a screen was named on the command line; see DesignPreview.
            if let screen = DesignPreview.requested, let preview {
                DesignPreviewView(screen: screen, session: preview.0)
                    .modelContainer(preview.1)
            } else {
                RootView()
                    .environment(session)
                    // Handed down from the root, so every screen sets its words the same
                    // way without each one having to ask what was chosen.
                    .environment(\.chatmanTypeface, session.typeface)
                    // Light means light everywhere a word doesn't ask for a weight of its own.
                    .fontWeight(session.typeface.weight)
                    // Nil, not `.light`, when it's off: nil means "whatever the phone says",
                    // and picking a side there would override the very setting it's meant to
                    // follow.
                    .preferredColorScheme(session.forcesDarkMode ? .dark : nil)
                    .modelContainer(container)
                    // Signing in on the phone is enough; the watch is handed the session.
                    .task {
                        session.startDeviceLink()

                        PushRegistrar.session = session
                        if session.wantsNotifications {
                            await PushRegistrar.enable()
                        }
                    }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Syncing only runs while the app is on screen. iOS suspends background apps
            // anyway, and holding a connection open in the background just spends battery on
            // work the system won't let finish.
            switch phase {
            case .active:
                // The backdrop carries on from where it was, not from where the wall clock
                // has got to. See `BackdropClock`.
                BackdropClock.resume()
                // One sync, not two. Its first request already comes back at once when there is
                // anything new — the server holds a long poll open only when there is nothing
                // to say — so a separate catch-up alongside it fetched the same news twice and
                // applied it twice, racing the loop to write where the sync had got to.
                session.startSyncing()
                // And a look at the bridges, when one is due: a WhatsApp that was logged out
                // while the phone was in a pocket should say so when you take it out.
                Task { await session.tidyUpIfDue() }
                // Names change in the address book while the app is elsewhere, and the list
                // only reads them when it first appears. Coming back is the moment to look
                // again — a contact renamed an hour ago shouldn't need the app restarting.
                Task { await session.refreshContacts() }
            case .inactive, .background:
                session.stopSyncing()
                BackdropClock.pause()
            @unknown default:
                break
            }
        }
    }

    /// Builds the local store.
    ///
    /// Everything here is a cache of what the homeserver already knows, so if the store can't
    /// be opened — a failed migration, a corrupt file — starting fresh is the right answer.
    /// Refusing to launch would be worse than re-syncing.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([Conversation.self, Message.self])

        do {
            return try ModelContainer(for: schema)
        } catch {
            // The journal files go with it. Only the store itself used to be removed, which
            // left its write-ahead log beside the fresh one — SQLite's to reconcile against a
            // file it has never seen, and a retry that could fail for it and drop the app to
            // memory for good.
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: URL.applicationSupportDirectory.appending(path: "default.store" + suffix)
                )
            }

            if let fresh = try? ModelContainer(for: schema) { return fresh }

            // Last resort: run without persistence rather than not run at all.
            let memoryOnly = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: memoryOnly)
        }
    }
}
