import AppIntents
import SwiftData
import ChatmanKit

/// The session the intents act on: the app's own, handed over when it starts.
///
/// Intents run inside the app, so they can use the same session instead of building a second
/// one with its own connection.
@MainActor
enum IntentSession {
    static var current: ChatSession?
}

/// A conversation, as Shortcuts and Spotlight see it.
struct ConversationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chat")
    static let defaultQuery = ConversationQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ConversationQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ConversationEntity] {
        identifiers.compactMap { id in
            guard let session = IntentSession.current,
                  let conversation = session.conversation(withID: id)
            else { return nil }
            return ConversationEntity(id: id, name: session.displayName(for: conversation))
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ConversationEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ConversationEntity] {
        guard let session = IntentSession.current else { return [] }
        return session.recentConversations(limit: 50).map {
            ConversationEntity(id: $0.id, name: session.displayName(for: $0))
        }
    }
}

/// Opens a chat.
struct OpenChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Chat"
    static let openAppWhenRun = true

    @Parameter(title: "Chat") var chat: ConversationEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentSession.current?.open(conversationID: chat.id)
        return .result()
    }
}

/// Sends a message to a chat, without opening the app.
struct SendMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Message"

    @Parameter(title: "Chat") var chat: ConversationEntity
    @Parameter(title: "Message") var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$text) to \(\.$chat)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let session = IntentSession.current,
              let conversation = session.conversation(withID: chat.id)
        else { throw IntentFailure.notReady }
        await session.send(text, to: conversation)
        return .result(dialog: "Sent to \(chat.name).")
    }
}

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notReady
    var localizedStringResource: LocalizedStringResource { "Open Chatman and sign in first." }
}

/// The phrases Shortcuts and Spotlight offer without any setting up.
struct ChatmanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendMessageIntent(),
            phrases: ["Send a message with \(.applicationName)"],
            shortTitle: "Send Message",
            systemImageName: "paperplane"
        )
        AppShortcut(
            intent: OpenChatIntent(),
            phrases: ["Open a chat in \(.applicationName)"],
            shortTitle: "Open Chat",
            systemImageName: "bubble.left"
        )
    }
}
