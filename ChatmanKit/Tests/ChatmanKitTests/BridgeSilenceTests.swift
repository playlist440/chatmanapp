import Testing
import Foundation
import SwiftData
@testable import ChatmanKit

/// Tests for telling a bridge in trouble apart from one that was never set up.
///
/// A WhatsApp that lost its login used to vanish from the settings and say nothing at all: an
/// answer that couldn't be read, or no answer, counted as "no such bridge here".
@MainActor
@Suite("Bridge silence")
struct BridgeSilenceTests {

    private func makeSession() throws -> ChatSession {
        let container = try ModelContainer(
            for: Schema([Conversation.self, Message.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ChatSession(
            profile: .phone, container: container,
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        )
    }

    @Test("A bridge with no logins at all is read, not taken for no bridge")
    func nullLoginsAreRead() throws {
        let whoami = try JSONDecoder().decode(
            MatrixAPI.BridgeWhoami.self,
            from: Data(#"{"management_room": "!m:example.com", "logins": null}"#.utf8)
        )
        #expect(whoami.logins.isEmpty)
        #expect(whoami.housekeepingRooms == ["!m:example.com"])
    }

    @Test("A login the bridge hasn't reported on yet is on its way, not broken")
    func loginWithoutStateIsConnecting() throws {
        let whoami = try JSONDecoder().decode(
            MatrixAPI.BridgeWhoami.self,
            from: Data(#"{"logins": [{"id": "31600000000", "name": "+31 6 00000000"}]}"#.utf8)
        )
        let login = try #require(whoami.logins.first)
        let status = ChatSession.BridgeAccount.Status(
            stateEvent: login.state.stateEvent, message: login.state.message
        )
        #expect(status == .connecting)
    }

    @Test("A network you use whose bridge doesn't answer is a problem, said as such")
    func silentBridgeIsReported() throws {
        let session = try makeSession()
        session.everConnected = [.whatsapp]
        // What it said the last time it answered.
        session.bridgeAccounts[.whatsapp] = .init(name: nil, status: .connected)
        session.unansweredNetworks = [.whatsapp, .telegram]

        let problems = session.bridgeProblems
        // Telegram was never used: a missing bridge there is no news.
        #expect(problems.map(\.network) == [.whatsapp])
        #expect(problems.first?.isUnanswered == true)
    }

    @Test("A network you use that has lost its login is a problem, not a blank")
    func lostLoginIsReported() throws {
        let session = try makeSession()
        session.everConnected = [.whatsapp]
        session.installedNetworks = [.whatsapp]

        #expect(session.bridgeProblems.map(\.network) == [.whatsapp])
        #expect(session.bridgeProblems.first?.isUnanswered == false)
    }

    @Test("A network let go of on purpose stops being reported")
    func forgottenNetworkIsQuiet() throws {
        let session = try makeSession()
        session.everConnected = [.whatsapp]
        session.installedNetworks = [.whatsapp]

        session.forget(.whatsapp)

        #expect(session.bridgeProblems.isEmpty)
    }

    @Test("A network there are chats from counts as used, even if no login was ever seen")
    func chatsMeanUsed() throws {
        let session = try makeSession()
        session.insert(Conversation(id: "!wa:example.com", name: "Weekend", network: .whatsapp))
        session.installedNetworks = [.whatsapp]

        session.noteConnectedNetworks()

        #expect(session.bridgeProblems.map(\.network) == [.whatsapp])
    }

    @Test("Letting a network go sticks, until it is signed in again")
    func forgettingSticks() throws {
        let session = try makeSession()
        session.insert(Conversation(id: "!wa:example.com", name: "Weekend", network: .whatsapp))
        session.installedNetworks = [.whatsapp]
        session.noteConnectedNetworks()

        session.forget(.whatsapp)
        session.noteConnectedNetworks()
        #expect(session.bridgeProblems.isEmpty)

        session.bridgeAccounts[.whatsapp] = .init(name: nil, status: .connected)
        session.noteConnectedNetworks()
        session.bridgeAccounts[.whatsapp] = nil
        #expect(session.bridgeProblems.map(\.network) == [.whatsapp])
    }

    @Test("Reconnecting for a few minutes is no news; since yesterday evening it is")
    func stuckReconnecting() throws {
        let session = try makeSession()
        session.bridgeAccounts[.signal] = .init(name: nil, status: .reconnecting)
        session.noteReconnecting()
        #expect(session.bridgeProblems.isEmpty)

        session.reconnectingSince = [.signal: .now.addingTimeInterval(-13 * 3600)]
        #expect(session.bridgeProblems.map(\.network) == [.signal])

        // Back by itself: the count starts again next time.
        session.bridgeAccounts[.signal] = .init(name: nil, status: .connected)
        session.noteReconnecting()
        #expect(session.reconnectingSince.isEmpty)
        #expect(session.bridgeProblems.isEmpty)
    }

    @Test("Every word mautrix uses for a state is placed")
    func statesAreMapped() {
        typealias Status = ChatSession.BridgeAccount.Status
        #expect(Status(stateEvent: "BACKFILLING", message: nil) == .connected)
        #expect(Status(stateEvent: "STARTING", message: nil) == .connecting)
        #expect(Status(stateEvent: "BRIDGE_UNREACHABLE", message: nil) == .reconnecting)
        #expect(Status(stateEvent: "LOGGED_OUT", message: "wa-logged-out") == .loggedOut("wa-logged-out"))
        #expect(Status(stateEvent: "UNKNOWN_ERROR", message: nil) == .failed(nil))
    }
}

/// The whole round: the bridges asked over a connection that answers the way a server in
/// trouble does, and what the app then says.
@MainActor
@Suite("Bridge silence, end to end", .serialized)
struct BridgeRoundTests {

    private func makeSession(answers: [String: (Int, String)]) throws -> ChatSession {
        let container = try ModelContainer(
            for: Schema([Conversation.self, Message.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let session = ChatSession(
            profile: .phone, container: container,
            defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        )
        let homeserver = Homeserver(url: URL(string: "https://example.com")!)
        session.credentials = Credentials(
            userID: "@me:example.com", deviceID: "D", accessToken: "t", homeserver: homeserver
        )
        BridgeServer.answers = answers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeServer.self]
        session.api = MatrixAPI(
            homeserver: homeserver, accessToken: "t",
            urlSession: URLSession(configuration: configuration)
        )
        return session
    }

    @Test("A WhatsApp you have chats from, whose bridge fails, stays in sight and says so")
    func failingBridge() async throws {
        let session = try makeSession(answers: [
            "whatsapp": (500, #"{"errcode": "M_UNKNOWN", "error": "internal"}"#),
            "signal": (200, #"{"logins": [{"id": "1", "state": {"state_event": "TRANSIENT_DISCONNECT"}}]}"#),
        ])
        session.insert(Conversation(id: "!wa:example.com", name: "Weekend", network: .whatsapp))

        await session.refreshBridges()

        let problem = try #require(session.bridgeProblems.first { $0.network == .whatsapp })
        #expect(problem.isUnanswered)
        #expect(session.bridgeAnswers[.whatsapp]?.summary.isEmpty == false)
        #expect(!session.missingNetworks.contains(.whatsapp))
    }

    @Test("A round says what it asked, and every answer is written down")
    func roundIsVisible() async throws {
        let session = try makeSession(answers: [
            "whatsapp": (200, #"{"logins": [{"id": "1", "state": {"state_event": "CONNECTED"}}]}"#),
            "signal": (200, #"{"logins": [{"id": "2", "state": {"state_event": "CONNECTED"}}]}"#),
        ])
        session.insert(Conversation(id: "!wa:example.com", name: "Weekend", network: .whatsapp))

        await session.refreshBridges()

        let round = try #require(session.bridgeRound)
        #expect(round.finished != nil)
        #expect(round.asked.contains(.whatsapp))
        #expect(session.bridgeQuestions.isEmpty)
        #expect(session.bridgeAnswers[.whatsapp]?.summary == "Answered: connected")
        #expect(session.bridgeDiagnoses.contains { $0.network == .whatsapp && $0.hasAccount })
    }

    @Test("A WhatsApp with no login left says it's disconnected")
    func noLoginLeft() async throws {
        let session = try makeSession(answers: [
            "whatsapp": (200, #"{"logins": null}"#),
        ])
        session.insert(Conversation(id: "!wa:example.com", name: "Weekend", network: .whatsapp))

        await session.refreshBridges()

        let problem = try #require(session.bridgeProblems.first { $0.network == .whatsapp })
        #expect(!problem.isUnanswered)
    }
}

/// A server whose bridges answer whatever they are told to, and 404 for the rest.
final class BridgeServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: (Int, String)] = [:]

    static var answers: [String: (Int, String)] {
        get { lock.withLock { table } }
        set { lock.withLock { table = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let network = Self.answers.keys.first { path.contains("/bridge/\($0)/") }
        let (status, body) = network.flatMap { Self.answers[$0] } ?? (404, "404 page not found")

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A whoami exactly as mautrix-go's bridgev2 writes it, every field included.
@Suite("Bridge whoami as sent")
struct BridgeWhoamiShapeTests {
    @Test("A full bridgev2 answer for a connected WhatsApp is read")
    func fullAnswer() throws {
        let json = #"""
        {"network":{"displayname":"WhatsApp","network_url":"https://whatsapp.com","network_icon":"mxc://maunium.net/NeXNQarUbrlYBiPCpprYsRqr","network_id":"whatsapp","beeper_bridge_type":"whatsapp","default_port":29318,"default_command_prefix":"!wa"},
         "login_flows":[{"name":"QR","description":"Scan a QR code","id":"qr"},{"name":"Pairing code","description":"Input your phone number","id":"phone"}],
         "homeserver":"matrix.example.com","bridge_bot":"@whatsappbot:matrix.example.com","command_prefix":"!wa",
         "management_room":"!mgmt:matrix.example.com",
         "logins":[{"state_event":"CONNECTED","state_ts":1791139000,
           "state":{"state_event":"CONNECTED","timestamp":1791139000,"ttl":3600,"source":"bridge","user_id":"@me:matrix.example.com","remote_id":"31600000000","remote_name":"+31 6 00000000","remote_profile":{"phone":"+31600000000","name":"Me"}},
           "id":"31600000000","name":"+31 6 00000000","profile":{"phone":"+31600000000","name":"Me"},"space_room":"!space:matrix.example.com"}]}
        """#
        let whoami = try JSONDecoder().decode(MatrixAPI.BridgeWhoami.self, from: Data(json.utf8))
        #expect(whoami.logins.first?.state.stateEvent == "CONNECTED")
    }
}

@Suite("Deadline")
struct DeadlineTests {
    @Test("A question that never comes back gives up on time")
    func neverReturns() async throws {
        let start = Date.now
        await #expect(throws: DeadlinePassed.self) {
            try await withDeadline(seconds: 0.2) {
                // Ignores cancellation on purpose, like the request that got stuck.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return 1
            }
        }
        #expect(Date.now.timeIntervalSince(start) < 2)
    }

    @Test("An answer in time comes through")
    func answers() async throws {
        let value = try await withDeadline(seconds: 2) { 7 }
        #expect(value == 7)
    }
}
