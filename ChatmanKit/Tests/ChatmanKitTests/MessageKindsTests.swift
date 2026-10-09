import Testing
import Foundation
import SwiftData
@testable import ChatmanKit

/// Things that used to vanish without a trace: stickers, polls, and what a bridge says about
/// a message it couldn't pass on.
@Suite("Stickers, polls and more")
struct MessageKindsDecodingTests {

    private func decode(_ json: String) throws -> MatrixEvent {
        try JSONDecoder().decode(MatrixEvent.self, from: Data(json.utf8))
    }

    @Test("A sticker is a picture of its own kind")
    func sticker() throws {
        let event = try decode("""
        {"event_id":"$s","sender":"@whatsapp_1:example.com","type":"m.sticker",
         "origin_server_ts":1700000000000,
         "content":{"body":"🐱","url":"mxc://example.com/cat",
                    "info":{"mimetype":"image/webp","w":512,"h":512}}}
        """)

        guard case .sticker(let media) = event.content else {
            Issue.record("Expected a sticker, got \(event.content)")
            return
        }
        #expect(media.url == "mxc://example.com/cat")
        #expect(event.content.isMessage)
        #expect(event.content.preview == "Sticker")
    }

    @Test("A poll the way the bridges send it")
    func unstablePoll() throws {
        let event = try decode("""
        {"event_id":"$p","sender":"@whatsapp_1:example.com","type":"org.matrix.msc3381.poll.start",
         "origin_server_ts":1700000000000,
         "content":{
           "org.matrix.msc3381.poll.start":{
             "kind":"org.matrix.msc3381.poll.disclosed","max_selections":1,
             "question":{"org.matrix.msc1767.text":"Barbecue zaterdag?"},
             "answers":[{"id":"a","org.matrix.msc1767.text":"Ja"},
                        {"id":"b","org.matrix.msc1767.text":"Nee"}]},
           "org.matrix.msc1767.text":"Barbecue zaterdag?\\n1. Ja\\n2. Nee"}}
        """)

        guard case .poll(let poll) = event.content else {
            Issue.record("Expected a poll, got \(event.content)")
            return
        }
        #expect(poll.question == "Barbecue zaterdag?")
        #expect(poll.answers.map(\.text) == ["Ja", "Nee"])
        #expect(poll.maxSelections == 1)
        #expect(event.content.preview == "📊 Barbecue zaterdag?")
    }

    @Test("And in its stable form")
    func stablePoll() throws {
        let event = try decode("""
        {"event_id":"$p","sender":"@a:example.com","type":"m.poll.start",
         "origin_server_ts":1700000000000,
         "content":{"m.poll":{"max_selections":2,
           "question":{"m.text":[{"body":"Welke avond?"}]},
           "answers":[{"m.id":"1","m.text":[{"body":"Vrijdag"}]},
                      {"m.id":"2","m.text":[{"body":"Zaterdag"}]}]}}}
        """)

        guard case .poll(let poll) = event.content else {
            Issue.record("Expected a poll, got \(event.content)")
            return
        }
        #expect(poll.question == "Welke avond?")
        #expect(poll.answers.map(\.id) == ["1", "2"])
        #expect(poll.maxSelections == 2)
    }

    @Test("A vote points at its poll")
    func pollResponse() throws {
        let event = try decode("""
        {"event_id":"$v","sender":"@whatsapp_2:example.com","type":"org.matrix.msc3381.poll.response",
         "origin_server_ts":1700000000000,
         "content":{"m.relates_to":{"rel_type":"m.reference","event_id":"$p"},
                    "org.matrix.msc3381.poll.response":{"answers":["a"]}}}
        """)

        #expect(event.content == .pollResponse(answers: ["a"]))
        #expect(event.relation?.kind == .reference)
        #expect(event.relation?.eventID == "$p")
        #expect(!event.content.isMessage)
    }

    @Test("A bridge saying a message didn't get through")
    func sendStatus() throws {
        let event = try decode("""
        {"event_id":"$st","sender":"@whatsappbot:example.com","type":"com.beeper.message_send_status",
         "origin_server_ts":1700000000000,
         "content":{"network":"whatsapp","status":"FAIL_PERMANENT",
                    "message":"You're not logged in to WhatsApp",
                    "m.relates_to":{"rel_type":"m.reference","event_id":"$mine"}}}
        """)

        guard case .sendStatus(let report) = event.content else {
            Issue.record("Expected a status, got \(event.content)")
            return
        }
        #expect(report.outcome == .failedPermanently)
        #expect(report.message == "You're not logged in to WhatsApp")
        #expect(event.relation?.eventID == "$mine")
    }

    @Test("A voice message says so, and brings its shape")
    func voice() throws {
        let event = try decode("""
        {"event_id":"$a","sender":"@whatsapp_1:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,
         "content":{"msgtype":"m.audio","body":"Voice message","url":"mxc://example.com/v",
                    "info":{"mimetype":"audio/ogg","duration":4200},
                    "org.matrix.msc3245.voice":{},
                    "org.matrix.msc1767.audio":{"duration":4200,"waveform":[10,500,1024,300]}}}
        """)

        guard case .audio(let media) = event.content else {
            Issue.record("Expected audio, got \(event.content)")
            return
        }
        #expect(media.isVoice)
        #expect(media.duration == 4200)
        #expect(media.waveform == [10, 500, 1024, 300])
    }

    @Test("Who a message names, from m.mentions")
    func mentions() throws {
        let event = try decode("""
        {"event_id":"$m","sender":"@a:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,
         "content":{"msgtype":"m.text","body":"hoi","m.mentions":{"user_ids":["@b:example.com"]}}}
        """)
        #expect(event.mentionedUserIDs == ["@b:example.com"])
    }
}

@Suite("Muted rooms from the push rules")
struct PushRuleTests {

    @Test("Muted here and muted in Element both count; a rule that notifies doesn't")
    func mutedRooms() throws {
        let response = try JSONDecoder().decode(MatrixAPI.SyncResponse.self, from: Data("""
        {"next_batch":"s1","account_data":{"events":[
          {"type":"m.direct","content":{"@anna:example.com":["!dm:example.com"]}},
          {"type":"m.push_rules","content":{"global":{
            "room":[{"rule_id":"!chatman:example.com","actions":[],"enabled":true,"default":false},
                    {"rule_id":"!loud:example.com","actions":["notify"],"enabled":true,"default":false}],
            "override":[{"rule_id":"!element:example.com","actions":["dont_notify"],"enabled":true,
                         "default":false,"conditions":[{"kind":"event_match","key":"room_id",
                         "pattern":"!element:example.com"}]},
                        {"rule_id":".m.rule.master","actions":[],"enabled":false,"default":true},
                        {"rule_id":"!off:example.com","actions":[],"enabled":false,"default":false}]
          }}}
        ]}}
        """.utf8))

        #expect(response.mutedRooms == ["!chatman:example.com", "!element:example.com"])
        // And m.direct beside it is still read.
        #expect(response.directRooms["@anna:example.com"] == ["!dm:example.com"])
    }

    @Test("No rules in the batch is not the same as nothing muted")
    func absentRules() throws {
        let response = try JSONDecoder().decode(
            MatrixAPI.SyncResponse.self, from: Data(#"{"next_batch":"s1"}"#.utf8)
        )
        #expect(response.mutedRooms == nil)
    }
}

@Suite("Polls, counted")
struct PollStateTests {

    private var poll: PollState {
        PollState(.init(question: "?", answers: [.init(id: "a", text: "A"), .init(id: "b", text: "B")],
                        maxSelections: 1))
    }

    @Test("A second vote replaces the first")
    func changedVote() {
        var state = poll
        state.record(["a"], by: "@x")
        state.record(["b"], by: "@x")
        #expect(state.tally == ["b": 1])
        #expect(state.voters == 1)
    }

    @Test("A vote with nothing valid in it takes the vote away")
    func spoiltVote() {
        var state = poll
        state.record(["a"], by: "@x")
        state.record(["zzz"], by: "@x")
        #expect(state.voters == 0)
    }

    @Test("No more answers than the poll allows")
    func limit() {
        var state = poll
        state.record(["a", "b"], by: "@x")
        #expect(state.votes["@x"] == ["a"])
    }
}

@MainActor
@Suite("New kinds, applied")
struct MessageKindsSyncTests {

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

    private func apply(_ events: String, to session: ChatSession, batch: String = "s1") throws {
        session.apply(try JSONDecoder().decode(MatrixAPI.SyncResponse.self, from: Data("""
        {"next_batch":"\(batch)","rooms":{"join":{"!room:example.com":{"timeline":{"events":[\(events)]}}}}}
        """.utf8)))
    }

    @Test("Votes are counted on the poll they belong to")
    func votesCounted() throws {
        let session = try makeSession()
        try apply("""
        {"event_id":"$p","sender":"@a:example.com","type":"org.matrix.msc3381.poll.start",
         "origin_server_ts":1700000000000,
         "content":{"org.matrix.msc3381.poll.start":{"max_selections":1,
           "question":{"org.matrix.msc1767.text":"Pizza?"},
           "answers":[{"id":"y","org.matrix.msc1767.text":"Ja"},{"id":"n","org.matrix.msc1767.text":"Nee"}]}}},
        {"event_id":"$v1","sender":"@b:example.com","type":"org.matrix.msc3381.poll.response",
         "origin_server_ts":1700000001000,
         "content":{"m.relates_to":{"rel_type":"m.reference","event_id":"$p"},
                    "org.matrix.msc3381.poll.response":{"answers":["y"]}}},
        {"event_id":"$v2","sender":"@alex:example.com","type":"org.matrix.msc3381.poll.response",
         "origin_server_ts":1700000002000,
         "content":{"m.relates_to":{"rel_type":"m.reference","event_id":"$p"},
                    "org.matrix.msc3381.poll.response":{"answers":["y"]}}}
        """, to: session)

        let poll = try #require(session.message(id: "$p"))
        #expect(poll.kind == .poll)
        #expect(poll.body == "Pizza?")
        #expect(poll.poll?.tally == ["y": 2])
        #expect(session.myVote(in: poll) == ["y"])
        #expect(session.conversation(withID: "!room:example.com")?.lastMessagePreview == "📊 Pizza?")
    }

    @Test("A bridge's failure report lands on the message it is about")
    func deliveryProblem() throws {
        let session = try makeSession()
        try apply("""
        {"event_id":"$mine","sender":"@alex:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Hoi"}},
        {"event_id":"$st","sender":"@whatsappbot:example.com","type":"com.beeper.message_send_status",
         "origin_server_ts":1700000001000,
         "content":{"status":"FAIL_RETRIABLE","message":"Couldn't reach WhatsApp",
                    "m.relates_to":{"rel_type":"m.reference","event_id":"$mine"}}}
        """, to: session)

        #expect(session.message(id: "$mine")?.deliveryProblem == "Couldn't reach WhatsApp")

        try apply("""
        {"event_id":"$st2","sender":"@whatsappbot:example.com","type":"com.beeper.message_send_status",
         "origin_server_ts":1700000002000,
         "content":{"status":"SUCCESS","m.relates_to":{"rel_type":"m.reference","event_id":"$mine"}}}
        """, to: session, batch: "s2")

        let mine = try #require(session.message(id: "$mine"))
        #expect(mine.deliveryProblem == nil)
        #expect(mine.deliveredAt != nil)
    }

    @Test("Muting on another device reaches this one")
    func muteFromServer() throws {
        let session = try makeSession()
        try apply("""
        {"event_id":"$m","sender":"@a:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Hoi"}}
        """, to: session)

        session.apply(try JSONDecoder().decode(MatrixAPI.SyncResponse.self, from: Data("""
        {"next_batch":"s2","account_data":{"events":[{"type":"m.push_rules","content":{"global":{
          "room":[{"rule_id":"!room:example.com","actions":[],"enabled":true,"default":false}]}}}]}}
        """.utf8)))
        #expect(session.conversation(withID: "!room:example.com")?.isMuted == true)

        session.apply(try JSONDecoder().decode(MatrixAPI.SyncResponse.self, from: Data("""
        {"next_batch":"s3","account_data":{"events":[{"type":"m.push_rules","content":{"global":{"room":[]}}}]}}
        """.utf8)))
        #expect(session.conversation(withID: "!room:example.com")?.isMuted == false)
    }
}

/// The outbox: what happens to something you sent when the connection doesn't cooperate.
@MainActor
@Suite("Outbox")
struct OutboxTests {

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

    private func standIn(in session: ChatSession, queued: Date) -> Message {
        let conversation = Conversation(id: "!room:example.com")
        session.insert(conversation)
        let stand = Message(
            id: "chatman.test", sender: "@alex:example.com", timestamp: queued,
            body: "Ik ben er over vijf minuten", kind: .text, isPending: true
        )
        stand.queuedAt = queued
        stand.conversation = conversation
        session.insert(stand)
        session.saveContext()
        return stand
    }

    @Test("A message that waited too long stops, and says so")
    func expires() throws {
        let session = try makeSession()
        let stand = standIn(in: session, queued: .now.addingTimeInterval(-11 * 60))

        session.flushOutbox()

        #expect(stand.didFailToSend)
        #expect(!stand.isPending)
        #expect(session.canRetry(stand))
    }

    @Test("A message still within its ten minutes keeps waiting")
    func stillWaiting() throws {
        let session = try makeSession()
        let stand = standIn(in: session, queued: .now.addingTimeInterval(-60))

        session.flushOutbox()

        #expect(stand.isPending)
        #expect(!stand.didFailToSend)
    }

    @Test("An attachment whose bytes are gone can't be sent again; one on the server can")
    func attachmentRetry() throws {
        let session = try makeSession()
        let lost = Message(id: "chatman.a", sender: "@alex:example.com", timestamp: .now,
                           body: "Photo", kind: .image, didFailToSend: true)
        lost.outboxFile = "chatman.a/nowhere.jpg"
        #expect(!session.canRetry(lost))

        let uploaded = Message(id: "chatman.b", sender: "@alex:example.com", timestamp: .now,
                               body: "Photo", kind: .image, mediaURL: "mxc://example.com/x",
                               didFailToSend: true)
        #expect(session.canRetry(uploaded))
    }
}

@MainActor
@Suite("Bridge health")
struct BridgeHealthTests {

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

    @Test("A bridge that lost its login is a problem; one that was never set up is not")
    func lostLogin() throws {
        let session = try makeSession()
        session.installedNetworks = [.whatsapp, .signal]
        session.bridgeAccounts = [.whatsapp: .init(name: "+31", status: .connected)]
        session.noteConnectedNetworks()
        #expect(session.bridgeProblems.isEmpty)

        // WhatsApp's login is gone; Signal was never connected.
        session.bridgeAccounts = [:]
        #expect(session.bridgeProblems.map(\.network) == [.whatsapp])
    }

    @Test("Logged out says so; reconnecting on its own does not")
    func statuses() throws {
        let session = try makeSession()
        session.bridgeAccounts = [
            .whatsapp: .init(name: nil, status: .loggedOut("Scan the code again")),
            .signal: .init(name: nil, status: .reconnecting)
        ]
        #expect(session.bridgeProblems == [.init(network: .whatsapp, detail: "Scan the code again")])
    }
}

@Suite("What a file really is")
struct FileNatureTests {

    private func decode(_ json: String) throws -> MatrixEvent {
        try JSONDecoder().decode(MatrixEvent.self, from: Data(json.utf8))
    }

    @Test("A film sent as a file is a film")
    func videoAsFile() throws {
        let event = try decode("""
        {"event_id":"$v","sender":"@whatsapp_1:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,
         "content":{"msgtype":"m.file","body":"VID-2026.mp4","url":"mxc://example.com/v",
                    "info":{"mimetype":"video/mp4","size":2000000}}}
        """)
        guard case .video = event.content else {
            Issue.record("Expected a video, got \(event.content)")
            return
        }
    }

    @Test("A document stays a document")
    func pdfStaysAFile() throws {
        let event = try decode("""
        {"event_id":"$f","sender":"@a:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,
         "content":{"msgtype":"m.file","body":"factuur.pdf","url":"mxc://example.com/f",
                    "info":{"mimetype":"application/pdf"}}}
        """)
        guard case .file = event.content else {
            Issue.record("Expected a file, got \(event.content)")
            return
        }
    }

    @Test("Names you chose are read from the account")
    func chosenNames() throws {
        let response = try JSONDecoder().decode(MatrixAPI.SyncResponse.self, from: Data("""
        {"next_batch":"s1","account_data":{"events":[
          {"type":"nl.chatman.names","content":{"names":{"@signal_x:example.com":"Kyra"}}}
        ]}}
        """.utf8))
        #expect(response.chosenNames == ["@signal_x:example.com": "Kyra"])
    }
}
