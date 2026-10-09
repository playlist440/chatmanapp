import Testing
import Foundation
import SwiftData
@testable import ChatmanKit

/// What a board leads with.
@MainActor
@Suite("Board headlines")
struct HeadlineTests {

    private func makeSession() throws -> ChatSession {
        let container = try ModelContainer(
            for: Schema([Conversation.self, Message.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let session = ChatSession(
            profile: .phone, container: container,
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        )
        session.credentials = Credentials(
            userID: "@alex:example.com", deviceID: "DEV", accessToken: "token",
            homeserver: Homeserver(string: "example.com")!
        )
        return session
    }

    /// A group of five with some unread messages, oldest first.
    private func board(
        in session: ChatSession, _ lines: [(id: String, sender: String, body: String)]
    ) -> Conversation {
        let group = Conversation(id: "!board:example.com", name: "Buurt", otherMemberCount: 5)
        session.insert(group)
        for (index, line) in lines.enumerated() {
            let message = Message(
                id: line.id, sender: line.sender, senderName: String(line.sender.dropFirst().prefix(4)),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
                body: line.body, kind: .text
            )
            message.conversation = group
            session.insert(message)
        }
        group.unreadCount = lines.count
        group.lastActivity = Date(timeIntervalSince1970: 1_700_000_000 + Double(lines.count) * 60)
        session.saveContext()
        return group
    }

    @Test("What the group reacted to leads, over whatever came last")
    func reactedTo() throws {
        let session = try makeSession()
        let group = board(in: session, [
            ("$1", "@anna:example.com", "De straat is zaterdag afgesloten"),
            ("$2", "@bert:example.com", "haha"),
            ("$3", "@cees:example.com", "dank je")
        ])
        let news = try #require(session.message(id: "$1"))
        news.addReaction("👍", by: "@bert:example.com", event: "$r1")
        news.addReaction("👍", by: "@cees:example.com", event: "$r2")
        news.addReaction("❤️", by: "@dirk:example.com", event: "$r3")

        let lead = session.headline(for: group)
        #expect(lead.messageID == "$1")
        #expect(lead.reason == .reactedTo)
        #expect(lead.fresh == 3)
        #expect(lead.people == 3)
    }

    @Test("Somebody you also talk to privately comes before a stranger")
    func someoneYouKnow() throws {
        let session = try makeSession()
        let friend = Conversation(id: "!dm:example.com", isDirect: true,
                                  directPartnerID: "@bert:example.com", otherMemberCount: 1)
        session.insert(friend)
        let group = board(in: session, [
            ("$1", "@bert:example.com", "Wie heeft er een ladder?"),
            ("$2", "@anna:example.com", "haha")
        ])

        let lead = session.headline(for: group)
        #expect(lead.messageID == "$1")
        #expect(lead.reason == .fromSomeoneYouKnow)
    }

    @Test("Nothing standing out: the newest, as before")
    func newest() throws {
        let session = try makeSession()
        let group = board(in: session, [
            ("$1", "@anna:example.com", "a"),
            ("$2", "@bert:example.com", "b")
        ])
        #expect(session.headline(for: group).messageID == "$2")
        #expect(session.headline(for: group).reason == .newest)
    }
}
