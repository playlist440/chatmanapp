import Testing
import Foundation
import SwiftData
@testable import ChatmanKit

/// What the chat list costs to draw, once, per row.
///
/// Every one of these runs for every visible row on every redraw, and the list redraws
/// whenever anything on the session changes — which during a sync is constantly. A tenth of a
/// millisecond here is nothing; a millisecond here is a list that drags.
@MainActor
@Suite("Drawing the list")
struct ListDrawingTests {

    private func makeSession(groupMessages: Int) throws -> (ChatSession, Conversation) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema([Conversation.self, Message.self]), configurations: configuration
        )
        let defaults = UserDefaults(suiteName: "perf.\(UUID().uuidString)")!
        let session = ChatSession(profile: .phone, container: container, defaults: defaults)
        session.credentials = Credentials(
            userID: "@alex:example.com", deviceID: "D1",
            accessToken: "token", homeserver: Homeserver(string: "example.com")!
        )

        let group = Conversation(id: "!group:example.com", name: "Klas 4B", network: .whatsapp)
        group.otherMemberCount = 8
        group.lastMessagePreview = "Tot morgen"
        container.mainContext.insert(group)

        // A group with a year behind it, which is the ordinary case and not the extreme one.
        for index in 0..<groupMessages {
            let message = Message(
                id: "$m\(index)",
                sender: "@whatsapp_3161234567\(index % 7):example.com",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                body: "Bericht \(index)",
                kind: .text
            )
            message.conversation = group
            container.mainContext.insert(message)
        }
        try container.mainContext.save()

        return (session, group)
    }

    @Test("A group's preview line")
    func groupPreview() throws {
        let (session, group) = try makeSession(groupMessages: 2_000)

        // Warm, so the first fault-in of the relationship isn't counted as the cost of a
        // redraw. Every redraw after that is what this measures.
        _ = session.preview(for: group)

        let rounds = 200
        let taken = ContinuousClock().measure {
            for _ in 0..<rounds { _ = session.preview(for: group) }
        }

        let milliseconds = Double((taken / rounds).components.attoseconds) / 1e15
        report("Group preview line: \(String(format: "%.3f", milliseconds)) ms per row per redraw")

        // Eight rows on a screen at sixty frames a second leaves about two milliseconds for
        // everything. One row's preview may not eat a tenth of it.
        #expect(milliseconds < 0.2)
    }

    @Test("And working it out again from scratch")
    func groupPreviewCold() throws {
        let (session, group) = try makeSession(groupMessages: 2_000)

        // The answer is remembered until something is said, so this is what a new message
        // costs — once, not once a frame. It still has to be quick: a busy group is a group
        // where this happens often.
        let rounds = 50
        let taken = ContinuousClock().measure {
            for _ in 0..<rounds {
                session.groupPreviews.removeAll()
                _ = session.preview(for: group)
            }
        }

        let milliseconds = Double((taken / rounds).components.attoseconds) / 1e15
        report("Group preview, worked out: \(String(format: "%.3f", milliseconds)) ms per new message")

        #expect(milliseconds < 1.0)
    }
}

/// Writes a measurement where the machine running the tests can read it back.
private func report(_ line: String) {
    print(line)
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("list-bench.txt")

    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    } else {
        try? (line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
