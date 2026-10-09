import Testing
import Foundation
import SwiftData
@testable import ChatmanKit

/// Tests for the order in which waiting messages go out.
///
/// The server keeps messages in the order they reach it. Coming back after a lost connection
/// used to send everything that was waiting side by side, and two of them could arrive the
/// wrong way round — and swap places, for you and for whoever got them.
@MainActor
@Suite("Outbox order", .serialized)
struct OutboxOrderTests {

    private let room = "!room:example.com"

    private func makeSession() throws -> ChatSession {
        let container = try ModelContainer(
            for: Schema([Conversation.self, Message.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let session = ChatSession(profile: .phone, container: container, defaults: defaults)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowServer.self]
        session.api = MatrixAPI(
            homeserver: Homeserver(url: URL(string: "https://example.com")!),
            accessToken: "token",
            urlSession: URLSession(configuration: configuration)
        )
        return session
    }

    /// Three messages written while offline, one second apart, still waiting.
    private func writeWhileOffline(_ ids: [String], in session: ChatSession) {
        let conversation = Conversation(id: room)
        session.insert(conversation)

        let start = Date.now.addingTimeInterval(-60)
        for (offset, id) in ids.enumerated() {
            let stand = Message(
                id: id,
                sender: "@me:example.com",
                timestamp: start.addingTimeInterval(Double(offset)),
                body: id,
                kind: .text,
                isPending: true
            )
            session.queue(stand, in: conversation, preview: id)
            stand.queuedAt = stand.timestamp
        }
    }

    @Test("Waiting messages reach the server in the order they were written")
    func waitingMessagesGoInOrder() async throws {
        SlowServer.reset()
        let session = try makeSession()
        writeWhileOffline(["t1", "t2", "t3"], in: session)

        // The connection is back.
        session.flushOutbox()
        _ = await session.lanes[room]?.value

        // The first one written is the slowest to land: side by side, it arrived last.
        #expect(SlowServer.arrivals == ["t1", "t2", "t3"])
        #expect(session.message(id: "t3")?.isPending == false)
    }

    @Test("A message still waiting holds back the ones written after it")
    func waitingMessageHoldsTheLine() async throws {
        SlowServer.reset()
        SlowServer.offline = ["t1"]
        let session = try makeSession()
        writeWhileOffline(["t1", "t2"], in: session)

        session.flushOutbox()
        _ = await session.lanes[room]?.value

        #expect(SlowServer.arrivals.isEmpty)
        #expect(session.message(id: "t1")?.isPending == true)
        #expect(session.message(id: "t2")?.isPending == true)

        // Back for real: both go, in order.
        SlowServer.offline = []
        session.flushOutbox()
        _ = await session.lanes[room]?.value

        #expect(SlowServer.arrivals == ["t1", "t2"])
    }

    @Test("A few words written while a picture uploads don't wait for it, and land once it's up")
    func textOvertakesUpload() async throws {
        SlowServer.reset()
        SlowServer.uploadDelay = 0.4
        let session = try makeSession()
        let conversation = Conversation(id: room)
        session.insert(conversation)

        let kept = try Outbox.keep(Data(repeating: 7, count: 64), for: "t1", named: "photo.jpg")
        defer { Outbox.remove(kept) }

        let photo = Message(
            id: "t1", sender: "@me:example.com", timestamp: .now.addingTimeInterval(-60),
            body: "photo.jpg", kind: .image, isPending: true
        )
        photo.outboxFile = kept
        session.queue(photo, in: conversation, preview: "Photo")
        photo.queuedAt = photo.timestamp

        let words = Message(
            id: "t2", sender: "@me:example.com", timestamp: .now.addingTimeInterval(-59),
            body: "t2", kind: .text, isPending: true
        )
        session.queue(words, in: conversation, preview: "t2")
        words.queuedAt = words.timestamp

        let picture = session.enqueue("t1")
        let text = session.enqueue("t2")

        _ = await text?.value
        #expect(SlowServer.arrivals == ["t2"])

        _ = await picture?.value
        #expect(SlowServer.arrivals == ["t2", "t1"])
        #expect(session.message(id: "t1")?.isPending == false)
    }

    @Test("A message held in line past ten minutes asks rather than going late")
    func heldTooLongAsks() async throws {
        SlowServer.reset()
        let session = try makeSession()
        let conversation = Conversation(id: room)
        session.insert(conversation)

        let old = Message(
            id: "t1", sender: "@me:example.com", timestamp: .now.addingTimeInterval(-700),
            body: "t1", kind: .text, isPending: true
        )
        session.queue(old, in: conversation, preview: "t1")
        old.queuedAt = old.timestamp

        _ = await session.enqueue("t1")?.value

        #expect(SlowServer.arrivals.isEmpty)
        #expect(session.message(id: "t1")?.didFailToSend == true)
    }
}

/// A homeserver that takes longer over the messages written first.
///
/// Records a message as arrived when its request is answered — the moment the server has
/// it — so messages sent side by side land in reverse.
final class SlowServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var landed: [String] = []
    nonisolated(unsafe) private static var unreachable: Set<String> = []
    nonisolated(unsafe) private static var uploadWait: TimeInterval = 0

    static var arrivals: [String] { lock.withLock { landed } }

    static var offline: Set<String> {
        get { lock.withLock { unreachable } }
        set { lock.withLock { unreachable = newValue } }
    }

    /// How long an upload takes before the server hands back its address.
    static var uploadDelay: TimeInterval {
        get { lock.withLock { uploadWait } }
        set { lock.withLock { uploadWait = newValue } }
    }

    static func reset() {
        lock.withLock {
            landed = []
            unreachable = []
            uploadWait = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // An upload: answered with an address after a while, and not a message arriving.
        if request.url?.path.contains("/upload") == true {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.uploadDelay) { [self] in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"content_uri": "mxc://example.com/up"}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }

        let id = request.url?.lastPathComponent ?? ""
        let number = Int(id.dropFirst()) ?? 0
        let delay = Double(max(0, 4 - number)) * 0.05

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            if Self.offline.contains(id) {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }

            Self.lock.withLock { Self.landed.append(id) }

            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"event_id": "$\#(id)"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
