import Testing
import Foundation
import SwiftData
@testable import ChatmanKit

/// Reactions, edits and deletions — the parts of a conversation that change a message
/// after it has arrived.
///
/// Each of these was a real fault found in review. They are here so they stay found.
@MainActor
@Suite("Reactions, edits and deletions")
struct ReactionAndEditTests {

    private func makeSession() throws -> ChatSession {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([Conversation.self, Message.self]),
            configurations: configuration
        )
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return ChatSession(profile: .phone, container: container, defaults: defaults)
    }

    private func decode(_ json: String) throws -> MatrixAPI.SyncResponse {
        try JSONDecoder().decode(MatrixAPI.SyncResponse.self, from: Data(json.utf8))
    }

    private func onlyConversation(in session: ChatSession) throws -> Conversation {
        try #require(try session.container.mainContext.fetch(FetchDescriptor<Conversation>()).first)
    }

    /// One sync for one room with the events given, as JSON objects.
    private func sync(_ events: String, batch: String = "s1") -> String {
        """
        {"next_batch":"\(batch)","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[\(events)]}
        }}}}
        """
    }

    private let message = """
    {"event_id":"$m1","type":"m.room.message","sender":"@anna:example.com",
     "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Gelukt!"}}
    """

    private func reaction(_ id: String, by sender: String, key: String = "🎉") -> String {
        """
        {"event_id":"\(id)","type":"m.reaction","sender":"\(sender)",
         "origin_server_ts":1700000000500,
         "content":{"m.relates_to":{"rel_type":"m.annotation","event_id":"$m1","key":"\(key)"}}}
        """
    }

    // MARK: - Reactions

    @Test("The same reaction delivered twice still counts once")
    func duplicateReactionCountsOnce() throws {
        let session = try makeSession()
        session.apply(try decode(sync(message + "," + reaction("$r1", by: "@bas:example.com"))))
        // The same event again, the way a replayed sync delivers it.
        session.apply(try decode(sync(reaction("$r1", by: "@bas:example.com"), batch: "s2")))

        let stored = try #require(try onlyConversation(in: session).messages.first)
        #expect(stored.reactions["🎉"] == 1)
    }

    @Test("Two people giving the same emoji count as two")
    func twoPeopleCountTwice() throws {
        let session = try makeSession()
        session.apply(try decode(sync(
            message + "," + reaction("$r1", by: "@bas:example.com")
                + "," + reaction("$r2", by: "@cor:example.com")
        )))

        let stored = try #require(try onlyConversation(in: session).messages.first)
        #expect(stored.reactions["🎉"] == 2)
    }

    @Test("A reaction that is taken back comes off the message")
    func withdrawnReactionIsRemoved() throws {
        let session = try makeSession()
        session.apply(try decode(sync(message + "," + reaction("$r1", by: "@bas:example.com"))))

        // Taking a reaction back redacts the reaction's own event, not the message.
        session.apply(try decode(sync("""
        {"event_id":"$x1","type":"m.room.redaction","sender":"@bas:example.com",
         "origin_server_ts":1700000001000,"redacts":"$r1","content":{"redacts":"$r1"}}
        """, batch: "s2")))

        let conversation = try onlyConversation(in: session)
        let stored = try #require(conversation.messages.first)
        #expect(stored.reactions.isEmpty)
        // And the message itself is untouched.
        #expect(conversation.messages.count == 1)
    }

    @Test("Your own reaction and the server's echo of it are one reaction")
    func ownReactionAndEchoCountOnce() throws {
        let stored = Message(
            id: "$m1", sender: "@anna:example.com", timestamp: .now, body: "Hoi", kind: .text
        )

        // Shown straight away under a stand-in, then the server's copy arrives.
        stored.addReaction("👍", by: "@alex:example.com", event: "~pending")
        stored.addReaction("👍", by: "@alex:example.com", event: "$real")
        #expect(stored.reactions["👍"] == 1)

        // And confirming the stand-in afterwards doesn't bring a second one back.
        stored.confirmReaction("~pending", as: "$real")
        #expect(stored.reactions["👍"] == 1)
        #expect(stored.holdsReaction(event: "$real"))
        #expect(!stored.holdsReaction(event: "~pending"))
    }

    @Test("A confirmed reaction can be found by its real event and taken off")
    func confirmedReactionCanBeWithdrawn() throws {
        let stored = Message(
            id: "$m1", sender: "@anna:example.com", timestamp: .now, body: "Hoi", kind: .text
        )
        stored.addReaction("❤️", by: "@alex:example.com", event: "~pending")
        stored.confirmReaction("~pending", as: "$real")

        #expect(stored.removeReaction(event: "$real"))
        #expect(stored.reactions.isEmpty)
    }

    @Test("Counts stored in the old format survive, and new reactions add to them")
    func oldFormatIsKept() throws {
        let stored = Message(
            id: "$m1", sender: "@anna:example.com", timestamp: .now, body: "Hoi", kind: .text
        )
        stored.reactionsBlob = "❤️:2|👍:1"
        #expect(stored.reactions == ["❤️": 2, "👍": 1])

        stored.addReaction("❤️", by: "@cor:example.com", event: "$r9")
        #expect(stored.reactions == ["❤️": 3, "👍": 1])

        // Untouched messages are written back exactly as they were.
        let untouched = Message(
            id: "$m2", sender: "@anna:example.com", timestamp: .now, body: "Hoi", kind: .text,
            reactions: ["🎉": 4]
        )
        #expect(untouched.reactionsBlob == "🎉:4")
    }

    // MARK: - Edits

    private func edit(by sender: String, to body: String) -> String {
        """
        {"event_id":"$e1","type":"m.room.message","sender":"\(sender)",
         "origin_server_ts":1700000002000,
         "content":{"msgtype":"m.text","body":"* \(body)",
           "m.new_content":{"msgtype":"m.text","body":"\(body)"},
           "m.relates_to":{"rel_type":"m.replace","event_id":"$m1"}}}
        """
    }

    @Test("The writer's own edit is applied")
    func ownEditApplies() throws {
        let session = try makeSession()
        session.apply(try decode(sync(message + "," + edit(by: "@anna:example.com", to: "Gelukt, echt!"))))

        let conversation = try onlyConversation(in: session)
        let stored = try #require(conversation.messages.first)
        #expect(stored.body == "Gelukt, echt!")
        #expect(stored.wasEdited)
        #expect(conversation.messages.count == 1)
    }

    @Test("Somebody else cannot edit your message")
    func foreignEditIsRefused() throws {
        let session = try makeSession()
        session.apply(try decode(sync(message + "," + edit(by: "@mallory:example.com", to: "Ik heb gelogen"))))

        let conversation = try onlyConversation(in: session)
        let stored = try #require(conversation.messages.first)
        #expect(stored.body == "Gelukt!")
        #expect(!stored.wasEdited)
        #expect(conversation.messages.count == 1)
    }

    @Test("An edit whose original isn't loaded never becomes a message of its own")
    func orphanEditIsNotStored() throws {
        let session = try makeSession()
        session.apply(try decode(sync(edit(by: "@anna:example.com", to: "Gelukt, echt!"))))

        let conversations = try session.container.mainContext.fetch(FetchDescriptor<Conversation>())
        let messages = conversations.flatMap(\.messages)
        #expect(messages.isEmpty)
        #expect(!(conversations.first?.lastMessagePreview.hasPrefix("*") ?? false))
    }

    // MARK: - Typing

    private func ephemeral(_ events: String, batch: String) -> String {
        """
        {"next_batch":"\(batch)","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[]},
          "ephemeral":{"events":[\(events)]}
        }}}}
        """
    }

    @Test("A read receipt doesn't take away somebody who is still typing")
    func receiptLeavesTypingAlone() throws {
        let session = try makeSession()
        session.apply(try decode(sync(message)))
        session.apply(try decode(ephemeral("""
        {"type":"m.typing","content":{"user_ids":["@anna:example.com"]}}
        """, batch: "s2")))
        #expect(session.typingByRoom["!room1:example.com"] == ["@anna:example.com"])

        // Only a receipt this time: nothing said about typing, so nothing changes.
        session.apply(try decode(ephemeral("""
        {"type":"m.receipt","content":{"$m1":{"m.read":{"@bas:example.com":{"ts":1700000000000}}}}}
        """, batch: "s3")))
        #expect(session.typingByRoom["!room1:example.com"] == ["@anna:example.com"])

        // And when the list does come, empty, the indicator goes.
        session.apply(try decode(ephemeral("""
        {"type":"m.typing","content":{"user_ids":[]}}
        """, batch: "s4")))
        #expect(session.typingByRoom["!room1:example.com"] == nil)
    }

    // MARK: - Notifications

    @Test("A request to delete a pusher says kind is null, rather than leaving kind out")
    func pusherDeletionSaysNull() throws {
        let request = MatrixAPI.PusherRequest(
            appID: "com.example.ios", appDisplayName: "Chatman", deviceDisplayName: "",
            pushkey: "abc", kind: nil, lang: "en", data: .init(url: "")
        )
        let json = try #require(String(data: try JSONEncoder().encode(request), encoding: .utf8))
        #expect(json.contains("\"kind\":null"))
    }

    // MARK: - History, invitations and m.direct

    private func timeline(_ events: String, prev: String, limited: Bool, batch: String) -> String {
        """
        {"next_batch":"\(batch)","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[\(events)],"prev_batch":"\(prev)","limited":\(limited)}
        }}}}
        """
    }

    @Test("A new room gets a way back into its history, and a reached start is kept")
    func reachedStartIsKept() throws {
        let session = try makeSession()
        session.apply(try decode(timeline(message, prev: "p1", limited: false, batch: "s1")))
        let conversation = try onlyConversation(in: session)
        #expect(conversation.previousBatch == "p1")

        // Scrolling up has reached the very first message.
        conversation.previousBatch = nil

        let later = """
        {"event_id":"$m2","type":"m.room.message","sender":"@anna:example.com",
         "origin_server_ts":1700000005000,"content":{"msgtype":"m.text","body":"Nog eentje"}}
        """
        session.apply(try decode(timeline(later, prev: "p2", limited: false, batch: "s2")))
        #expect(conversation.previousBatch == nil)

        // But a gap — the server skipping events — still needs the way back.
        let gap = """
        {"event_id":"$m3","type":"m.room.message","sender":"@anna:example.com",
         "origin_server_ts":1700000009000,"content":{"msgtype":"m.text","body":"Na een gat"}}
        """
        session.apply(try decode(timeline(gap, prev: "p3", limited: true, batch: "s3")))
        #expect(conversation.previousBatch == "p3")
    }

    @Test("An invitation that is withdrawn leaves the list")
    func withdrawnInvitationIsForgotten() throws {
        let session = try makeSession()
        // Arrives the way a real one does, from a person rather than a bridge.
        session.apply(try decode("""
        {"next_batch":"s0","rooms":{"invite":{"!inv:example.com":{
          "invite_state":{"events":[
            {"type":"m.room.member","sender":"@anna:example.com",
             "state_key":"@alex:example.com","event_id":"$i",
             "origin_server_ts":1700000000000,"content":{"membership":"invite"}}
          ]}
        }}}}
        """))
        #expect(session.invitations.count == 1)

        session.apply(try decode("""
        {"next_batch":"s1","rooms":{"leave":{"!inv:example.com":{}}}}
        """))

        #expect(session.invitations.isEmpty)
    }

    @Test("m.direct marks a room even when the room itself isn't in that batch")
    func directAppliesOutsideBatch() throws {
        let session = try makeSession()
        session.apply(try decode(sync(message)))

        session.apply(try decode("""
        {"next_batch":"s2","account_data":{"events":[
          {"type":"m.direct","content":{"@anna:example.com":["!room1:example.com"]}}
        ]}}
        """))

        let conversation = try onlyConversation(in: session)
        #expect(conversation.isDirect)
        #expect(conversation.directPartnerID == "@anna:example.com")
    }

    // MARK: - Deletions

    @Test("Deleting the newest message puts the conversation's last line right")
    func deletingNewestFixesPreview() throws {
        let session = try makeSession()
        session.apply(try decode(sync("""
        {"event_id":"$m0","type":"m.room.message","sender":"@anna:example.com",
         "origin_server_ts":1699999990000,"content":{"msgtype":"m.text","body":"Eerste"}},
        \(message)
        """)))

        let conversation = try onlyConversation(in: session)
        #expect(conversation.lastMessagePreview == "Gelukt!")

        let newest = try #require(conversation.messages.first { $0.id == "$m1" })
        session.remove(newest, from: conversation)

        #expect(conversation.lastMessagePreview == "Eerste")
    }
}
