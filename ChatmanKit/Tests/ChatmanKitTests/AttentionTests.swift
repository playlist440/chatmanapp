import Testing
import Foundation
import SwiftData
@testable import ChatmanKit

/// Who is waiting on you, decided without reading a word.
@Suite("Attention")
struct AttentionTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A person who wrote is waiting; a group that talks among itself is not")
    func peopleAndGroups() {
        #expect(Attention.isWaiting(.init(unread: 1), now: now))
        #expect(!Attention.isWaiting(.init(isGroup: true, unread: 30), now: now))
    }

    @Test("A group waits when it is about you")
    func groupMention() {
        #expect(Attention.isWaiting(.init(isGroup: true, unread: 30, mentions: 1), now: now))
    }

    @Test("A mention gets through a mute, the way WhatsApp lets one through")
    func mentionInMutedGroup() {
        // Muted: the server counts nothing, but still counts the mention.
        #expect(Attention.isWaiting(.init(isGroup: true, unread: 0, mentions: 1), now: now))
    }

    @Test("Pinned means it always counts")
    func pinnedGroup() {
        #expect(Attention.isWaiting(.init(isGroup: true, isPinned: true, unread: 2), now: now))
        #expect(!Attention.isWaiting(.init(isGroup: true, isPinned: true, unread: 0), now: now))
    }

    @Test("Archived and hidden never count, whatever is in them")
    func archivedAndHidden() {
        #expect(!Attention.isWaiting(.init(isArchived: true, unread: 5, mentions: 1), now: now))
        #expect(!Attention.isWaiting(.init(isHidden: true, unread: 5), now: now))
    }

    @Test("Marked unread by hand outranks everything")
    func manuallyUnread() {
        #expect(Attention.isWaiting(.init(isGroup: true, isManuallyUnread: true), now: now))
    }

    @Test("A burst keeps a group counting until it runs out")
    func burstLasts() {
        let facts = Attention.Facts(isGroup: true, unread: 40, burstUntil: now.addingTimeInterval(60))
        #expect(Attention.isWaiting(facts, now: now))
        #expect(!Attention.isWaiting(facts, now: now.addingTimeInterval(120)))
    }

    // MARK: - Bursts

    typealias Burst = Attention.Burst

    @Test("A count that went down means you read in between")
    func riseAfterReading() {
        #expect(Burst.rise(from: 3, to: 10) == 7)
        #expect(Burst.rise(from: 20, to: 4) == 4)
        #expect(Burst.rise(from: 5, to: 5) == 0)
    }

    @Test("The half-hour log forgets what is older than half an hour")
    func logWindow() {
        var log = Burst.log("", adding: 6, at: now)
        log = Burst.log(log, adding: 5, at: now.addingTimeInterval(10 * 60))
        #expect(Burst.total(in: log, now: now.addingTimeInterval(10 * 60)) == 11)
        #expect(Burst.total(in: log, now: now.addingTimeInterval(35 * 60)) == 5)

        // And drops the old entries when it is next written.
        let trimmed = Burst.log(log, adding: 0, at: now.addingTimeInterval(45 * 60))
        #expect(trimmed.isEmpty)
    }

    @Test("A quiet group needs the minimum; a busy one needs half its day")
    func threshold() {
        #expect(Burst.isBurst(messages: 16, people: 5, typicalDaily: 4, lastBurst: nil, now: now))
        #expect(!Burst.isBurst(messages: 16, people: 5, typicalDaily: 100, lastBurst: nil, now: now))
        #expect(Burst.isBurst(messages: 60, people: 5, typicalDaily: 100, lastBurst: nil, now: now))
    }

    @Test("Two people arguing is not a street on fire")
    func tooFewPeople() {
        #expect(!Burst.isBurst(messages: 40, people: 2, typicalDaily: 4, lastBurst: nil, now: now))
    }

    @Test("One busy evening is one tap")
    func cooldown() {
        let hourAgo = now.addingTimeInterval(-3600)
        #expect(!Burst.isBurst(messages: 40, people: 6, typicalDaily: 4, lastBurst: hourAgo, now: now))
        let yesterday = now.addingTimeInterval(-86_400)
        #expect(Burst.isBurst(messages: 40, people: 6, typicalDaily: 4, lastBurst: yesterday, now: now))
    }

    @Test("The ordinary day settles on what the group really sends")
    func learning() {
        // Ten messages a day, seen once an hour, for eight weeks.
        var typical = 0.0
        for hour in 0..<(24 * 56) {
            // Ten a day, all in the evening.
            let rise = hour % 24 == 20 ? 10 : 0
            typical = Burst.learn(typicalDaily: typical, rise: rise, after: 3600)
        }
        #expect(abs(typical - 10) < 1.5)
    }
}

/// Emoji the thumb can learn.
@Suite("Quick reactions")
struct QuickReactionTests {

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    @Test("Apple's six, in Apple's order, until something has earned a seventh")
    func standardRow() {
        let store = defaults()
        #expect(QuickReactions.row(defaults: store) == ["❤️", "👍", "👎", "😂", "‼️", "❓"])
        QuickReactions.note("🙏", defaults: store)
        QuickReactions.note("🙏", defaults: store)
        #expect(QuickReactions.learned(defaults: store) == nil)
        QuickReactions.note("🙏", defaults: store)
        #expect(QuickReactions.row(defaults: store).last == "🙏")
    }

    @Test("The six themselves never take the seventh place")
    func standardNeverLearned() {
        let store = defaults()
        for _ in 0..<10 { QuickReactions.note("❤️", defaults: store) }
        #expect(QuickReactions.learned(defaults: store) == nil)
    }

    @Test("The seventh place moves rarely, and only for something well ahead")
    func stableSeventh() {
        let store = defaults()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<3 { QuickReactions.note("🙏", defaults: store, now: start) }
        #expect(QuickReactions.learned(defaults: store) == "🙏")

        // Ahead, but within the week: stays.
        for _ in 0..<10 { QuickReactions.note("🔥", defaults: store, now: start.addingTimeInterval(3600)) }
        #expect(QuickReactions.learned(defaults: store) == "🙏")

        // A week later, still well ahead: moves.
        QuickReactions.note("🔥", defaults: store, now: start.addingTimeInterval(8 * 86_400))
        #expect(QuickReactions.learned(defaults: store) == "🔥")
    }
}

@Suite("Closeness")
struct ClosenessTests {

    @Test("A message from two weeks ago counts half")
    func halfLife() {
        let then = Date(timeIntervalSince1970: 1_700_000_000)
        let later = then.addingTimeInterval(Closeness.halfLife)
        #expect(abs(Closeness.faded(4, since: then, now: later) - 2) < 0.0001)
    }
}

/// The sync, applied: what arrives and what it does to whether a chat waits on you.
@MainActor
@Suite("Attention from the sync")
struct AttentionSyncTests {

    private func makeSession() throws -> ChatSession {
        let container = try ModelContainer(
            for: Schema([Conversation.self, Message.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        // Past the first sync: what arrives now is news.
        defaults.set("s0", forKey: "chatman.nextBatch")
        let session = ChatSession(profile: .phone, container: container, defaults: defaults)
        session.credentials = Credentials(
            userID: "@alex:example.com", deviceID: "DEV", accessToken: "token",
            homeserver: Homeserver(string: "example.com")!
        )
        session.selfAccounts = ["@whatsapp_31600000000:example.com"]
        return session
    }

    private func decode(_ json: String) throws -> MatrixAPI.SyncResponse {
        try JSONDecoder().decode(MatrixAPI.SyncResponse.self, from: Data(json.utf8))
    }

    private func room(in session: ChatSession) throws -> Conversation {
        try #require(session.conversation(withID: "!group:example.com"))
    }

    /// A group of five, which is what makes it a group.
    private func makeGroup(in session: ChatSession) throws {
        session.apply(try decode("""
        {"next_batch":"s1","rooms":{"join":{"!group:example.com":{
          "timeline":{"events":[
            {"event_id":"$mine","type":"m.room.message","sender":"@whatsapp_31600000000:example.com",
             "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Wie neemt de taart mee?"}}
          ]},
          "unread_notifications":{"notification_count":0,"highlight_count":0}
        }}}}
        """))
        try room(in: session).otherMemberCount = 5
    }

    @Test("An answer to something you wrote counts as being about you")
    func replyToMine() throws {
        let session = try makeSession()
        try makeGroup(in: session)

        session.apply(try decode("""
        {"next_batch":"s2","rooms":{"join":{"!group:example.com":{
          "timeline":{"events":[
            {"event_id":"$answer","type":"m.room.message","sender":"@whatsapp_31611111111:example.com",
             "origin_server_ts":1700000060000,"content":{"msgtype":"m.text","body":"Ik!",
              "m.relates_to":{"m.in_reply_to":{"event_id":"$mine"}}}}
          ]},
          "unread_notifications":{"notification_count":1,"highlight_count":0}
        }}}}
        """))

        let group = try room(in: session)
        #expect(group.localMentions == 1)
        #expect(session.needsYou(group))
    }

    @Test("A mention of the account that stands for you on WhatsApp counts, too")
    func mentionOfBridgedSelf() throws {
        let session = try makeSession()
        try makeGroup(in: session)

        session.apply(try decode("""
        {"next_batch":"s2","rooms":{"join":{"!group:example.com":{
          "timeline":{"events":[
            {"event_id":"$m","type":"m.room.message","sender":"@whatsapp_31611111111:example.com",
             "origin_server_ts":1700000060000,"content":{"msgtype":"m.text","body":"@Alex?",
              "m.mentions":{"user_ids":["@whatsapp_31600000000:example.com"]}}}
          ]},
          "unread_notifications":{"notification_count":1,"highlight_count":0}
        }}}}
        """))

        #expect(session.needsYou(try room(in: session)))
    }

    @Test("Chatter in a group doesn't wait on you")
    func chatterDoesNotCount() throws {
        let session = try makeSession()
        try makeGroup(in: session)

        session.apply(try decode("""
        {"next_batch":"s2","rooms":{"join":{"!group:example.com":{
          "timeline":{"events":[
            {"event_id":"$m","type":"m.room.message","sender":"@whatsapp_31611111111:example.com",
             "origin_server_ts":1700000060000,"content":{"msgtype":"m.text","body":"Haha"}}
          ]},
          "unread_notifications":{"notification_count":12,"highlight_count":0}
        }}}}
        """))

        #expect(!session.needsYou(try room(in: session)))
    }

    @Test("The server's mention count is taken as it comes")
    func serverHighlights() throws {
        let session = try makeSession()
        try makeGroup(in: session)

        session.apply(try decode("""
        {"next_batch":"s2","rooms":{"join":{"!group:example.com":{
          "unread_notifications":{"notification_count":3,"highlight_count":1}
        }}}}
        """))

        #expect(session.needsYou(try room(in: session)))
    }

    @Test("Your own read marker, from anywhere, takes it off again")
    func readElsewhere() throws {
        let session = try makeSession()
        try makeGroup(in: session)
        try room(in: session).localMentions = 1
        try room(in: session).lastActivity = Date(timeIntervalSince1970: 1_700_000_000)

        session.apply(try decode("""
        {"next_batch":"s2","rooms":{"join":{"!group:example.com":{
          "ephemeral":{"events":[{"type":"m.receipt","content":{"$mine":{"m.read":{
            "@alex:example.com":{"ts":1700000100000}}}}}]}
        }}}}
        """))

        #expect(try room(in: session).localMentions == 0)
    }
}
