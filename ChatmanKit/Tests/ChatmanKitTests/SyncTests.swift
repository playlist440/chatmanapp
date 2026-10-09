import Testing
import Foundation
import SwiftData
@testable import ChatmanKit

/// Tests for turning a sync response into conversations and messages.
///
/// This is the code most likely to break against a real homeserver, so it's exercised with
/// responses shaped the way Synapse and the mautrix bridges actually send them — including
/// the parts that are easy to get wrong: `m.direct` living in account data rather than in the
/// room, reactions arriving as separate events, and gappy timelines.
@MainActor
@Suite("Sync processing")
struct SyncTests {

    /// A session backed by a throwaway in-memory store.
    private func makeSession() throws -> ChatSession {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([Conversation.self, Message.self]),
            configurations: configuration
        )

        // A fresh UserDefaults per test, so a stored sync token can't leak between them.
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!

        return ChatSession(profile: .phone, container: container, defaults: defaults)
    }

    private func decode(_ json: String) throws -> MatrixAPI.SyncResponse {
        try JSONDecoder().decode(MatrixAPI.SyncResponse.self, from: Data(json.utf8))
    }

    private func conversations(in session: ChatSession) throws -> [Conversation] {
        try session.container.mainContext.fetch(FetchDescriptor<Conversation>())
    }

    // MARK: - Tests

    @Test("A read marker that arrives before the message it covers still counts")
    func receiptBeforeMessage() throws {
        let session = try makeSession()
        session.credentials = Credentials(
            userID: "@alex:example.com", deviceID: "D1",
            accessToken: "token", homeserver: Homeserver(string: "example.com")!
        )

        // First sync: the other side has read up to a message this device doesn't have yet.
        // That's the ordinary case for a fresh install, where one message per room arrives
        // and the rest is loaded when a conversation is opened.
        let first = try decode("""
        {
          "next_batch": "s1",
          "rooms": {"join": {"!room1:example.com": {
            "timeline": {"events": [], "prev_batch": "p1", "limited": false},
            "ephemeral": {"events": [
              {"type":"m.receipt",
               "content":{"$mine":{"m.read":{"@signal_a1b2c3:example.com":{"ts":1700000005000}}}}}
            ]}
          }}}
        }
        """)
        session.apply(first)

        let conversation = try #require(try conversations(in: session).first)
        #expect(conversation.readThrough != nil)

        // Then the message itself, sent by us before that marker was made.
        let second = try decode("""
        {
          "next_batch": "s2",
          "rooms": {"join": {"!room1:example.com": {
            "timeline": {"events": [
              {"event_id":"$mine","type":"m.room.message","sender":"@alex:example.com",
               "origin_server_ts":1700000000000,
               "content":{"msgtype":"m.text","body":"See you at eight"}}
            ], "prev_batch": "p2", "limited": false}
          }}}
        }
        """)
        session.apply(second)

        let message = try #require(conversation.messages.first)
        #expect(message.readAt != nil)
        #expect(session.sendStatus(of: message) != .sent)
    }

    @Test("A read marker that arrives after the message puts the ticks on it")
    func receiptAfterMessage() throws {
        // The ordinary way round, and the one the ticks actually depend on: you send
        // something, and a moment later the other side's marker comes back for it.
        let session = try makeSession()
        session.credentials = Credentials(
            userID: "@alex:example.com", deviceID: "D1",
            accessToken: "token", homeserver: Homeserver(string: "example.com")!
        )

        let sent = try decode("""
        {
          "next_batch": "s1",
          "rooms": {"join": {"!room1:example.com": {
            "timeline": {"events": [
              {"event_id":"$mine","type":"m.room.message","sender":"@alex:example.com",
               "origin_server_ts":1700000000000,
               "content":{"msgtype":"m.text","body":"See you at eight"}}
            ], "prev_batch": "p1", "limited": false}
          }}}
        }
        """)
        session.apply(sent)

        let conversation = try #require(try conversations(in: session).first)
        let message = try #require(conversation.messages.first)
        #expect(message.readAt == nil)

        let marker = try decode("""
        {
          "next_batch": "s2",
          "rooms": {"join": {"!room1:example.com": {
            "ephemeral": {"events": [
              {"type":"m.receipt",
               "content":{"$mine":{"m.read":{"@signal_a1b2c3:example.com":{"ts":1700000005000}}}}}
            ]}
          }}}
        }
        """)
        session.apply(marker)

        #expect(message.readAt != nil)
        #expect(message.deliveredAt != nil)
    }

    @Test("A bridged Signal chat becomes a named, direct conversation")
    func bridgedDirectMessage() throws {
        let session = try makeSession()

        let response = try decode("""
        {
          "next_batch": "s1",
          "account_data": {"events": [
            {"type": "m.direct",
             "content": {"@signal_a1b2c3:example.com": ["!room1:example.com"]}}
          ]},
          "rooms": {"join": {"!room1:example.com": {
            "state": {"events": [
              {"event_id":"$s1","type":"m.room.member","sender":"@signal_a1b2c3:example.com",
               "state_key":"@signal_a1b2c3:example.com","origin_server_ts":1,
               "content":{"membership":"join","displayname":"Anna"}}
            ]},
            "timeline": {"events": [
              {"event_id":"$m1","type":"m.room.message","sender":"@signal_a1b2c3:example.com",
               "origin_server_ts":1700000000000,
               "content":{"msgtype":"m.text","body":"See you at eight"}}
            ], "prev_batch": "p1", "limited": false},
            "unread_notifications": {"notification_count": 1}
          }}}
        }
        """)

        session.apply(response)

        let all = try conversations(in: session)
        #expect(all.count == 1)

        let conversation = try #require(all.first)
        #expect(conversation.isDirect)
        // The network is deduced from the ghost account's prefix — this is what lets the
        // interface show "Signal" instead of a raw Matrix ID.
        #expect(conversation.network == .signal)
        #expect(conversation.displayName == "Anna")
        #expect(conversation.unreadCount == 1)
        #expect(conversation.messages.count == 1)
        #expect(conversation.lastMessagePreview == "See you at eight")
    }

    @Test("A group keeps its own name and isn't marked direct")
    func groupConversation() throws {
        let session = try makeSession()

        let response = try decode("""
        {
          "next_batch": "s1",
          "rooms": {"join": {"!group:example.com": {
            "state": {"events": [
              {"event_id":"$n1","type":"m.room.name","sender":"@alex:example.com",
               "state_key":"","origin_server_ts":1,"content":{"name":"Familie"}}
            ]},
            "timeline": {"events": [
              {"event_id":"$m2","type":"m.room.message","sender":"@signal_zzz:example.com",
               "origin_server_ts":1700000001000,
               "content":{"msgtype":"m.text","body":"Wie haalt brood?"}}
            ], "prev_batch": "p2"}
          }}}
        }
        """)

        session.apply(response)

        let conversation = try #require(try conversations(in: session).first)
        #expect(conversation.displayName == "Familie")
        #expect(!conversation.isDirect)
    }

    @Test("A reaction attaches to the message it belongs to, not the timeline")
    func reactionsAttachToMessages() throws {
        let session = try makeSession()

        let response = try decode("""
        {
          "next_batch": "s1",
          "rooms": {"join": {"!room1:example.com": {
            "timeline": {"events": [
              {"event_id":"$m1","type":"m.room.message","sender":"@anna:example.com",
               "origin_server_ts":1700000000000,
               "content":{"msgtype":"m.text","body":"Gelukt!"}},
              {"event_id":"$r1","type":"m.reaction","sender":"@alex:example.com",
               "origin_server_ts":1700000000500,
               "content":{"m.relates_to":{"rel_type":"m.annotation","event_id":"$m1","key":"🎉"}}}
            ]}
          }}}
        }
        """)

        session.apply(response)

        let conversation = try #require(try conversations(in: session).first)

        // The reaction must not appear as its own message.
        #expect(conversation.messages.count == 1)

        let message = try #require(conversation.messages.first)
        #expect(message.reactions["🎉"] == 1)
    }

    @Test("A second sync adds to a conversation instead of duplicating it")
    func repeatedSyncsAccumulate() throws {
        let session = try makeSession()

        session.apply(try decode("""
        {"next_batch":"s1","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[
            {"event_id":"$m1","type":"m.room.message","sender":"@anna:example.com",
             "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Eerste"}}
          ]}}}}}
        """))

        session.apply(try decode("""
        {"next_batch":"s2","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[
            {"event_id":"$m2","type":"m.room.message","sender":"@anna:example.com",
             "origin_server_ts":1700000002000,"content":{"msgtype":"m.text","body":"Tweede"}}
          ]}}}}}
        """))

        let all = try conversations(in: session)
        #expect(all.count == 1)
        #expect(all.first?.messages.count == 2)
        #expect(all.first?.lastMessagePreview == "Tweede")
    }

    @Test("The same event arriving twice is stored once")
    func duplicateEventsAreIgnored() throws {
        let session = try makeSession()

        let json = """
        {"next_batch":"s1","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[
            {"event_id":"$m1","type":"m.room.message","sender":"@anna:example.com",
             "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Hallo"}}
          ]}}}}}
        """

        session.apply(try decode(json))
        session.apply(try decode(json))

        #expect(try conversations(in: session).first?.messages.count == 1)
    }

    @Test("A message someone deleted disappears")
    func redactionRemovesTheMessage() throws {
        let session = try makeSession()

        session.apply(try decode("""
        {
          "next_batch": "s1",
          "rooms": {"join": {"!room1:example.com": {
            "timeline": {"events": [
              {"event_id":"$m1","type":"m.room.message","sender":"@anna:example.com",
               "origin_server_ts":1700000000000,
               "content":{"msgtype":"m.text","body":"Oops, wrong chat"}}
            ], "prev_batch": "p1", "limited": false}
          }}}
        }
        """))

        #expect(try conversations(in: session).first?.messages.count == 1)

        // Rooms up to version 10 put `redacts` beside the type rather than in the content.
        // Reading only one of the two places is how a deleted message stays on screen.
        session.apply(try decode("""
        {
          "next_batch": "s2",
          "rooms": {"join": {"!room1:example.com": {
            "timeline": {"events": [
              {"event_id":"$r1","type":"m.room.redaction","sender":"@anna:example.com",
               "origin_server_ts":1700000001000,"redacts":"$m1","content":{}}
            ], "prev_batch": "p2", "limited": false}
          }}}
        }
        """))

        let conversation = try #require(try conversations(in: session).first)
        #expect(conversation.messages.isEmpty)
        #expect(conversation.lastMessagePreview.isEmpty)
    }

    @Test("A redaction that carries its target in the content works too")
    func redactionInContent() throws {
        let session = try makeSession()

        session.apply(try decode("""
        {
          "next_batch": "s1",
          "rooms": {"join": {"!room1:example.com": {
            "timeline": {"events": [
              {"event_id":"$m1","type":"m.room.message","sender":"@anna:example.com",
               "origin_server_ts":1700000000000,
               "content":{"msgtype":"m.text","body":"Never mind"}},
              {"event_id":"$r1","type":"m.room.redaction","sender":"@anna:example.com",
               "origin_server_ts":1700000001000,"content":{"redacts":"$m1"}}
            ], "prev_batch": "p1", "limited": false}
          }}}
        }
        """))

        #expect(try conversations(in: session).first?.messages.isEmpty == true)
    }

    @Test("An edited message reads as corrected, without the asterisk")
    func editUsesNewContent() throws {
        let session = try makeSession()

        session.apply(try decode("""
        {
          "next_batch": "s1",
          "rooms": {"join": {"!room1:example.com": {
            "timeline": {"events": [
              {"event_id":"$m1","type":"m.room.message","sender":"@anna:example.com",
               "origin_server_ts":1700000000000,
               "content":{"msgtype":"m.text","body":"see you at seven"}}
            ], "prev_batch": "p1", "limited": false}
          }}}
        }
        """))

        // An edit's own body carries the "* " that clients which can't apply edits show.
        // Taking it literally leaves a stray asterisk on every corrected message.
        session.apply(try decode("""
        {
          "next_batch": "s2",
          "rooms": {"join": {"!room1:example.com": {
            "timeline": {"events": [
              {"event_id":"$m2","type":"m.room.message","sender":"@anna:example.com",
               "origin_server_ts":1700000002000,
               "content":{"msgtype":"m.text","body":"* see you at eight",
                          "m.new_content":{"msgtype":"m.text","body":"see you at eight"},
                          "m.relates_to":{"rel_type":"m.replace","event_id":"$m1"}}}
            ], "prev_batch": "p2", "limited": false}
          }}}
        }
        """))

        let conversation = try #require(try conversations(in: session).first)
        #expect(conversation.messages.count == 1)

        let message = try #require(conversation.messages.first)
        #expect(message.body == "see you at eight")
        #expect(message.wasEdited)
        #expect(conversation.lastMessagePreview == "see you at eight")
    }

    @Test("A reply arrives without the copy of the message it answers")
    func replyFallbackIsStripped() throws {
        let session = try makeSession()

        session.apply(try decode("""
        {
          "next_batch": "s1",
          "rooms": {"join": {"!room1:example.com": {
            "timeline": {"events": [
              {"event_id":"$m2","type":"m.room.message","sender":"@anna:example.com",
               "origin_server_ts":1700000000000,
               "content":{"msgtype":"m.text",
                          "body":"> <@alex:example.com> are you coming?\\n\\nyes, on my way",
                          "m.relates_to":{"m.in_reply_to":{"event_id":"$m1"}}}}
            ], "prev_batch": "p1", "limited": false}
          }}}
        }
        """))

        let conversation = try #require(try conversations(in: session).first)
        let message = try #require(conversation.messages.first)

        #expect(message.body == "yes, on my way")
        #expect(message.replyToID == "$m1")
        // The list has to agree with the bubble, or the same message reads two ways.
        #expect(conversation.lastMessagePreview == "yes, on my way")
    }

    @Test("A gap in the timeline never costs you the messages you already had")
    func limitedTimelineKeepsHistory() throws {
        let session = try makeSession()

        session.apply(try decode("""
        {"next_batch":"s1","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[
            {"event_id":"$old","type":"m.room.message","sender":"@anna:example.com",
             "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Oud"}}
          ],"limited":false}}}}}
        """))

        // "limited" means the server skipped events. Throwing away what's stored to avoid a
        // gap leaves an empty conversation instead — and when the response carries no token,
        // no way to fetch anything back either. That was worse than the gap.
        session.apply(try decode("""
        {"next_batch":"s2","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[
            {"event_id":"$new","type":"m.room.message","sender":"@anna:example.com",
             "origin_server_ts":1700000900000,"content":{"msgtype":"m.text","body":"Nieuw"}}
          ],"limited":true}}}}}
        """))

        let conversation = try #require(try conversations(in: session).first)
        #expect(conversation.messages.count == 2)
        #expect(conversation.lastMessagePreview == "Nieuw")
    }

    @Test("A newer history token replaces the old one")
    func limitedTimelineTakesTheNewToken() throws {
        let session = try makeSession()

        session.apply(try decode("""
        {"next_batch":"s1","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[
            {"event_id":"$m1","type":"m.room.message","sender":"@anna:example.com",
             "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Hoi"}}
          ],"prev_batch":"p1"}}}}}
        """))

        session.apply(try decode("""
        {"next_batch":"s2","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[],"prev_batch":"p9","limited":true}}}}}
        """))

        #expect(try conversations(in: session).first?.previousBatch == "p9")
    }

    @Test("Leaving a room removes it from the list")
    func leftRoomsDisappear() throws {
        let session = try makeSession()

        session.apply(try decode("""
        {"next_batch":"s1","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[
            {"event_id":"$m1","type":"m.room.message","sender":"@anna:example.com",
             "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Hoi"}}
          ]}}}}}
        """))
        #expect(try conversations(in: session).count == 1)

        session.apply(try decode("""
        {"next_batch":"s2","rooms":{"leave":{"!room1:example.com":{}}}}
        """))
        #expect(try conversations(in: session).isEmpty)
    }

    @Test("A photo keeps the details needed to show it")
    func imageMessagesKeepTheirMedia() throws {
        let session = try makeSession()

        session.apply(try decode("""
        {"next_batch":"s1","rooms":{"join":{"!room1:example.com":{
          "timeline":{"events":[
            {"event_id":"$i1","type":"m.room.message","sender":"@signal_x:example.com",
             "origin_server_ts":1700000000000,
             "content":{"msgtype":"m.image","body":"foto.jpg","url":"mxc://example.com/abc",
                        "info":{"mimetype":"image/jpeg","w":1600,"h":1200}}}
          ]}}}}}
        """))

        let message = try #require(try conversations(in: session).first?.messages.first)
        #expect(message.kind == .image)
        #expect(message.mediaURL == "mxc://example.com/abc")
        // Needed to size the placeholder before the image lands, so the bubble doesn't jump.
        #expect(message.mediaWidth == 1600)
        #expect(message.mediaHeight == 1200)
    }

    @Test("An invitation isn't shown as a conversation until it's joined")
    func invitesAreNotConversationsYet() throws {
        let session = try makeSession()

        // A bridge creates a room per chat and invites you to it. Nothing should appear in
        // the list from the invitation alone — the row arrives once the room is joined and
        // its messages come through, which is the next sync.
        session.apply(try decode("""
        {"next_batch":"s1","rooms":{"invite":{"!portal:example.com":{
          "invite_state":{"events":[
            {"type":"m.room.member","sender":"@signalbot:example.com",
             "state_key":"@alex:example.com","content":{"membership":"invite"}}
          ]}}}}}
        """))

        #expect(try conversations(in: session).isEmpty)

        // And once joined, it shows up as normal.
        session.apply(try decode("""
        {"next_batch":"s2","rooms":{"join":{"!portal:example.com":{
          "timeline":{"events":[
            {"event_id":"$m1","type":"m.room.message","sender":"@signal_x:example.com",
             "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Hoi"}}
          ]}}}}}
        """))

        #expect(try conversations(in: session).count == 1)
    }

    @Test("A group's network is recognised from who's talking in it")
    func groupNetworkFromSender() throws {
        let session = try makeSession()

        // A group has no `m.direct` entry, so the only clue is the sender. Without this the
        // conversation shows no sign of which service it belongs to.
        session.apply(try decode("""
        {"next_batch":"s1","rooms":{"join":{"!group:example.com":{
          "state":{"events":[
            {"event_id":"$n1","type":"m.room.name","sender":"@alex:example.com",
             "state_key":"","origin_server_ts":1,"content":{"name":"Familie"}}
          ]},
          "timeline":{"events":[
            {"event_id":"$m1","type":"m.room.message","sender":"@whatsapp_316:example.com",
             "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Hoi"}}
          ]}}}}}
        """))

        let conversation = try #require(try conversations(in: session).first)
        #expect(conversation.network == .whatsapp)
        #expect(!conversation.isDirect)
    }

    @Test("An empty sync changes nothing")
    func emptySyncIsHarmless() throws {
        let session = try makeSession()
        session.apply(try decode(#"{"next_batch":"s1"}"#))
        #expect(try conversations(in: session).isEmpty)
    }

    @Test("A room the sync brings for the first time is counted straight away, not at the next tidy-up")
    func newRoomIsCountedStraightAway() throws {
        let session = try makeSession()
        // As after the first sync of a launch, when whatever was left uncounted is dealt with.
        session.hasUncountedRooms = false

        let room = """
        {"timeline": {"events": [], "prev_batch": "p1", "limited": false}}
        """
        session.apply(try decode("""
        {"next_batch": "s1", "rooms": {"join": {"!group:example.com": \(room)}}}
        """))
        #expect(session.hasUncountedRooms)

        // Known the second time round: nothing new to count.
        session.hasUncountedRooms = false
        session.apply(try decode("""
        {"next_batch": "s2", "rooms": {"join": {"!group:example.com": \(room)}}}
        """))
        #expect(!session.hasUncountedRooms)
    }
}
