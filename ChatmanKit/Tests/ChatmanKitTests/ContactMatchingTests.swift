import Testing
import Foundation
import SwiftData
@testable import ChatmanKit

/// Tests for deciding who is on the other side of a conversation.
///
/// This is what a chat gets named after, so getting it wrong is loudly visible: a conversation
/// suddenly carrying your own name, or a group named after whoever spoke last.
@MainActor
@Suite("Identifying the other party")
struct ContactMatchingTests {

    private func makeSession() throws -> ChatSession {
        let container = try ModelContainer(
            for: Schema([Conversation.self, Message.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )

        let session = ChatSession(
            profile: .phone,
            container: container,
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        )

        session.credentials = Credentials(
            userID: "@alex:example.com",
            deviceID: "DEV",
            accessToken: "token",
            homeserver: Homeserver(string: "example.com")!
        )
        session.selfAccounts = ["@signal_me:example.com"]

        return session
    }

    private func conversation(
        in session: ChatSession, id: String, partner: String? = nil, senders: [String] = []
    ) -> Conversation {
        let conversation = Conversation(id: id, isDirect: partner != nil, directPartnerID: partner)
        session.container.mainContext.insert(conversation)

        for (index, sender) in senders.enumerated() {
            let message = Message(
                id: "\(id)-\(index)", sender: sender,
                timestamp: Date(timeIntervalSince1970: Double(index)), body: "hoi", kind: .text
            )
            message.conversation = conversation
            session.container.mainContext.insert(message)
        }

        return conversation
    }

    /// Every account the bridges know about, including the user's own.
    private let known: [String: [String]] = [
        "@signal_anna:example.com": ["+31600000001"],
        "@signal_bob:example.com": ["+31600000002"],
        "@signal_me:example.com": ["+31600000009"]
    ]

    @Test("The recorded partner is used when there is one")
    func usesRecordedPartner() throws {
        let session = try makeSession()
        let chat = conversation(in: session, id: "!a", partner: "@signal_anna:example.com")

        #expect(session.partnerAccount(of: chat, knownTo: known) == "@signal_anna:example.com")
    }

    @Test("Without one, a single other speaker identifies the chat")
    func fallsBackToTheOnlyOtherSpeaker() throws {
        let session = try makeSession()
        let chat = conversation(
            in: session, id: "!b",
            senders: ["@signal_anna:example.com", "@alex:example.com", "@signal_anna:example.com"]
        )

        #expect(session.partnerAccount(of: chat, knownTo: known) == "@signal_anna:example.com")
    }

    @Test("Your own account is never mistaken for the other party")
    func neverPicksYourself() throws {
        let session = try makeSession()

        // The bridge represents you with an account of your own, carrying your own number.
        // Picking it names the conversation after you — which is what it did once.
        let chat = conversation(
            in: session, id: "!c",
            senders: ["@signal_me:example.com", "@alex:example.com"]
        )

        #expect(session.partnerAccount(of: chat, knownTo: known) == nil)
    }

    @Test("A group is not named after whoever spoke last")
    func ignoresGroups() throws {
        let session = try makeSession()
        let chat = conversation(
            in: session, id: "!d",
            senders: ["@signal_anna:example.com", "@signal_bob:example.com"]
        )

        #expect(session.partnerAccount(of: chat, knownTo: known) == nil)
    }

    @Test("A recorded partner that is yourself is rejected too")
    func rejectsSelfAsRecordedPartner() throws {
        let session = try makeSession()
        let chat = conversation(in: session, id: "!e", partner: "@signal_me:example.com")

        #expect(session.partnerAccount(of: chat, knownTo: known) == nil)
    }
}
