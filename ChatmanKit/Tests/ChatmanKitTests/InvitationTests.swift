import Testing
import Foundation
import SwiftData
@testable import ChatmanKit

/// Tests for who is allowed to put a room in your list without asking.
///
/// Chatman was written against a server with registration closed and federation off, where
/// the only account that could invite you was your own bridge — so it took every invitation
/// silently. On a server that talks to the rest of Matrix that is a stranger's room appearing
/// in your chats with no way to refuse it. These pin down the line between the two.
@MainActor
@Suite("Invitations")
struct InvitationTests {

    private func makeSession() throws -> ChatSession {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([Conversation.self, Message.self]), configurations: configuration
        )
        let defaults = UserDefaults(suiteName: "invites.\(UUID().uuidString)")!
        let session = ChatSession(profile: .phone, container: container, defaults: defaults)

        session.credentials = Credentials(
            userID: "@alex:example.com", deviceID: "D1",
            accessToken: "token", homeserver: Homeserver(string: "example.com")!
        )
        return session
    }

    /// A sync carrying one invitation, from `inviter`.
    private func invite(from inviter: String, named name: String? = nil) throws
        -> MatrixAPI.SyncResponse
    {
        let nameEvent = name.map {
            """
            ,{"type":"m.room.name","sender":"\(inviter)","state_key":"",
              "event_id":"$n","origin_server_ts":1700000000000,
              "content":{"name":"\($0)"}}
            """
        } ?? ""

        let json = """
        {
          "next_batch": "s1",
          "rooms": {"invite": {"!room1:example.com": {
            "invite_state": {"events": [
              {"type":"m.room.member","sender":"\(inviter)",
               "state_key":"@alex:example.com","event_id":"$m",
               "origin_server_ts":1700000000000,
               "content":{"membership":"invite"}}\(nameEvent)
            ]}
          }}}
        }
        """

        return try JSONDecoder().decode(
            MatrixAPI.SyncResponse.self, from: Data(json.utf8)
        )
    }

    @Test("A bridge's invitation is taken without asking")
    func bridgeBotIsTrusted() throws {
        let session = try makeSession()
        session.apply(try invite(from: "@signalbot:example.com"))

        #expect(session.invitations.isEmpty)
    }

    @Test("So is one from a bridged contact")
    func ghostIsTrusted() throws {
        let session = try makeSession()
        session.apply(try invite(from: "@whatsapp_31612345678:example.com"))

        #expect(session.invitations.isEmpty)
    }

    @Test("A person's invitation waits for an answer")
    func strangerIsAsked() throws {
        let session = try makeSession()
        session.apply(try invite(from: "@anna:matrix.org", named: "Weekend weg"))

        #expect(session.invitations.count == 1)
        #expect(session.invitations.first?.inviter == "@anna:matrix.org")
        #expect(session.invitations.first?.name == "Weekend weg")
    }

    @Test("Someone on your own server is still someone")
    func sameServerIsStillAsked() throws {
        // Registration being closed is a choice of the server, not something a client can
        // see. A neighbour on the same homeserver gets asked about like anybody else.
        let session = try makeSession()
        session.apply(try invite(from: "@buurman:example.com"))

        #expect(session.invitations.count == 1)
    }

    @Test("The same invitation twice is still one invitation")
    func doesNotPileUp() throws {
        let session = try makeSession()
        session.apply(try invite(from: "@anna:matrix.org"))
        session.apply(try invite(from: "@anna:matrix.org"))

        #expect(session.invitations.count == 1)
    }

    @Test("Turning one down takes it off the list")
    func decliningClearsIt() throws {
        let session = try makeSession()
        session.apply(try invite(from: "@anna:matrix.org"))

        let waiting = try #require(session.invitations.first)
        session.decline(waiting)

        #expect(session.invitations.isEmpty)
    }

    @Test("An invitation survives the app being closed")
    func survivesRestart() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([Conversation.self, Message.self]), configurations: configuration
        )
        let suite = "invites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!

        let first = ChatSession(profile: .phone, container: container, defaults: defaults)
        first.credentials = Credentials(
            userID: "@alex:example.com", deviceID: "D1",
            accessToken: "token", homeserver: Homeserver(string: "example.com")!
        )
        first.apply(try invite(from: "@anna:matrix.org"))
        #expect(first.invitations.count == 1)

        // A second session over the same stored settings: what was waiting is still waiting.
        let second = ChatSession(profile: .phone, container: container, defaults: defaults)
        #expect(second.invitations.count == 1)
    }
}
