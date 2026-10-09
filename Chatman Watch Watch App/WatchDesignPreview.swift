import SwiftData
import SwiftUI
import ChatmanKit

/// The same trick as on the phone: a screen with invented conversations behind it, so a
/// layout can be looked at without a server, a pairing and a five-minute install.
enum WatchDesignPreview {

    static var requested: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--design-preview"),
              index + 1 < arguments.count
        else { return nil }

        return arguments[index + 1]
    }

    @MainActor
    static func makeSession() -> (ChatSession, ModelContainer) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: Schema([Conversation.self, Message.self]), configurations: configuration
        )

        let session = ChatSession(
            profile: .watch,
            container: container,
            defaults: UserDefaults(suiteName: "design.preview.watch") ?? .standard
        )

        let context = container.mainContext
        let conversation = Conversation(
            id: "!room0:example.com", name: "Anna", isDirect: true, network: .signal
        )
        conversation.otherMemberCount = 1
        conversation.lastMessagePreview = "Zie je zo"
        context.insert(conversation)

        for (offset, line) in [
            ("@signal_abc:example.com", "Ben je er al?"),
            ("@alex:example.com", "Bijna, over vijf minuten"),
            ("@signal_abc:example.com", "Top, ik zit binnen bij het raam")
        ].enumerated() {
            let message = Message(
                id: "$m\(offset)",
                sender: line.0,
                timestamp: Date(timeIntervalSinceNow: Double(offset) * 60 - 300),
                body: line.1,
                kind: .text
            )
            message.conversation = conversation
            context.insert(message)
        }

        // A message somebody reacted to, and a picture with words under it: the two layouts
        // that are easy to get wrong and impossible to judge without seeing them.
        let reacted = Message(
            id: "$reacted",
            sender: "@signal_abc:example.com",
            timestamp: Date(timeIntervalSinceNow: -120),
            body: "Zullen we om acht uur afspreken?",
            kind: .text
        )
        reacted.reactions = ["👍": 2, "❤️": 1]
        reacted.conversation = conversation
        context.insert(reacted)

        let photo = Message(
            id: "$photo",
            sender: "@alex:example.com",
            timestamp: Date(timeIntervalSinceNow: -60),
            body: "Photo",
            kind: .image
        )
        photo.caption = "Hier stonden we vanochtend"
        photo.conversation = conversation
        context.insert(photo)

        // An album as a bridge delivers one: loose pictures with a line of its own prose
        // among them, carrying the reaction that was meant for the set.
        for number in 0..<5 {
            let part = Message(
                id: "$album-\(number)",
                sender: "@signal_def:example.com",
                timestamp: Date(timeIntervalSinceNow: -20 + Double(number)),
                body: "Photo",
                kind: .image
            )
            part.conversation = conversation
            context.insert(part)
        }

        let notice = Message(
            id: "$album-notice",
            sender: "@signal_def:example.com",
            timestamp: Date(timeIntervalSinceNow: -19.5),
            body: "Sent an album with 5 images:",
            kind: .text
        )
        notice.reactions = ["❤️": 2]
        notice.conversation = conversation
        context.insert(notice)

        // A few pinned, so the row of faces has something in it.
        for (index, name) in ["Anna", "Papa", "Mama", "Klas 4B"].enumerated() {
            let face = Conversation(
                id: "!pin\(index):example.com",
                name: name,
                isDirect: index != 3,
                network: index.isMultiple(of: 2) ? .signal : .whatsapp
            )
            face.isPinned = true
            face.unreadCount = index == 0 ? 3 : (index == 2 ? 12 : 0)
            face.lastActivity = Date(timeIntervalSinceNow: Double(-index) * 60)
            face.lastMessagePreview = "Tot zo"
            context.insert(face)
        }

        // Enough chats to have to scroll for. With one in the list there is no way to see
        // whether the pinned faces above it stay where they are.
        for (index, name) in ["Werk", "Larissa", "Aniek", "Bas", "Mama", "Oma", "Buren"].enumerated() {
            let other = Conversation(
                id: "!more\(index):example.com",
                name: name,
                isDirect: true,
                network: index.isMultiple(of: 2) ? .whatsapp : .signal
            )
            other.otherMemberCount = 1
            other.lastMessagePreview = "Photo"
            other.lastActivity = Date(timeIntervalSinceNow: Double(-index - 5) * 60)
            context.insert(other)
        }

        // A long history under Anna's chat and a long list besides, so scrolling with the
        // crown can be judged on something the size of a real account rather than on a
        // screenful that barely moves.
        let lines = ["Ja", "Klinkt goed!", "Ik kijk even", "Wanneer ben je thuis?",
                     "Heb je de sleutel nog?", "😂", "Oké, tot straks dan",
                     "Zullen we zaterdag naar het strand gaan als het mooi weer is?"]
        for number in 0..<160 {
            let message = Message(
                id: "$history-\(number)",
                sender: number.isMultiple(of: 3) ? "@alex:example.com" : "@signal_abc:example.com",
                timestamp: Date(timeIntervalSinceNow: -Double(200 - number) * 600),
                body: lines[number % lines.count],
                kind: .text
            )
            message.conversation = conversation
            context.insert(message)
        }

        for number in 0..<30 {
            let group = number.isMultiple(of: 3)
            let other = Conversation(
                id: "!long\(number):example.com",
                name: group ? "Groep \(number)" : "Contact \(number)",
                isDirect: !group,
                network: number.isMultiple(of: 2) ? .whatsapp : .signal
            )
            other.otherMemberCount = group ? 6 : 1
            other.unreadCount = number.isMultiple(of: 4) ? 2 : 0
            other.lastMessagePreview = lines[number % lines.count]
            other.lastActivity = Date(timeIntervalSinceNow: Double(-number - 20) * 600)
            context.insert(other)
        }

        // One chat put away, so the door to the archive has something behind it.
        let archived = Conversation(
            id: "!room1:example.com", name: "Oude groep", isDirect: false, network: .whatsapp
        )
        archived.otherMemberCount = 4
        archived.isArchived = true
        archived.unreadCount = 2
        archived.lastMessagePreview = "Bedankt allemaal!"
        context.insert(archived)

        try? context.save()
        return (session, container)
    }
}

struct WatchDesignPreviewView: View {
    let session: ChatSession

    /// Which screen was asked for on the command line.
    var screen: String { WatchDesignPreview.requested ?? "conversation" }

    var body: some View {
        switch screen {
        case "list":
            WatchDesignListPreview(session: session)

        // The list with the archive already open on top of it, for checking the way back.
        case "archive":
            WatchDesignListPreview(session: session, path: [.archive])

        default:
            // Outside the stack. A pushed screen is built by the navigation stack itself,
            // so anything handed to the root alone never reaches it — and a screen that
            // reads the session out of the environment and doesn't find it stops the app.
            NavigationStack {
                if let conversation = session.conversation(withID: "!room0:example.com") {
                    WatchConversationView(conversation: conversation)
                }
            }
            .environment(session)
        }
    }
}

/// The chat list, for looking at the title and the rows.
private struct WatchDesignListPreview: View {
    let session: ChatSession
    @State var path: [WatchRoute] = []

    var body: some View {
        // Outside the stack, not inside it. A pushed screen is built by the navigation
        // stack itself, so anything handed to the list alone never reaches it — and a screen
        // that reads the session out of the environment and doesn't find it does not fail
        // politely, it stops the app. Which is what this preview did.
        NavigationStack(path: $path) {
            WatchConversationListView(path: $path)
        }
        .environment(session)
    }
}
