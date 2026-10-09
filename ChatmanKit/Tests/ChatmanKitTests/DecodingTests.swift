import Testing
import Foundation
@testable import ChatmanKit

/// The event decoder is the one place where a server can hand us anything at all, so it gets
/// tested against the shapes real homeservers and bridges actually send.
@Suite("Event decoding")
struct EventDecodingTests {

    private func decode(_ json: String) throws -> MatrixEvent {
        try JSONDecoder().decode(MatrixEvent.self, from: Data(json.utf8))
    }

    @Test("A plain text message")
    func textMessage() throws {
        let event = try decode("""
        {"event_id":"$1","sender":"@alex:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,"content":{"msgtype":"m.text","body":"Hello"}}
        """)

        #expect(event.id == "$1")
        #expect(event.content == .text(body: "Hello", formatted: nil))
        #expect(event.content.isMessage)
    }

    @Test("An image keeps its dimensions so a placeholder can be sized before it loads")
    func imageMessage() throws {
        let event = try decode("""
        {"event_id":"$2","sender":"@signal_abc:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,
         "content":{"msgtype":"m.image","body":"photo.jpg","url":"mxc://example.com/abc",
                    "info":{"mimetype":"image/jpeg","size":12345,"w":1920,"h":1080}}}
        """)

        guard case .image(let media) = event.content else {
            Issue.record("expected an image, got \(event.content)")
            return
        }

        #expect(media.url == "mxc://example.com/abc")
        #expect(media.width == 1920)
        #expect(media.height == 1080)
    }

    @Test("A GIF from WhatsApp or Signal arrives as a film, and is recognised anyway")
    func bridgedGIF() throws {
        // What both networks actually send: an MP4, with one flag from the bridge saying it
        // was a GIF before they got hold of it.
        let event = try decode("""
        {"event_id":"$g1","sender":"@whatsapp_31612345678:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,
         "content":{"msgtype":"m.video","body":"video.mp4","url":"mxc://example.com/movie",
                    "info":{"mimetype":"video/mp4","size":204800,"w":480,"h":270,
                            "fi.mau.gif":true,
                            "thumbnail_url":"mxc://example.com/still"}}}
        """)

        guard case .video(let media) = event.content else {
            Issue.record("expected a video, got \(event.content)")
            return
        }

        #expect(media.isAnimated)
        // Without this the app asks the homeserver to scale an MP4, gets nothing back, and
        // leaves a spinner turning forever.
        #expect(media.thumbnailURL == "mxc://example.com/still")
        #expect(event.content.preview == "GIF")
    }

    @Test("A GIF sent as a file is a GIF on its mimetype alone")
    func fileGIF() throws {
        let event = try decode("""
        {"event_id":"$g2","sender":"@alex:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,
         "content":{"msgtype":"m.image","body":"cat.gif","url":"mxc://example.com/cat",
                    "info":{"mimetype":"image/gif","size":51200,"w":320,"h":240}}}
        """)

        guard case .image(let media) = event.content else {
            Issue.record("expected an image, got \(event.content)")
            return
        }

        #expect(media.isAnimated)
        #expect(event.content.preview == "GIF")
    }

    @Test("An ordinary video is not mistaken for a GIF")
    func plainVideo() throws {
        let event = try decode("""
        {"event_id":"$v1","sender":"@alex:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,
         "content":{"msgtype":"m.video","body":"holiday.mp4","url":"mxc://example.com/holiday",
                    "info":{"mimetype":"video/mp4","size":9999999,"w":1920,"h":1080,
                            "thumbnail_url":"mxc://example.com/holiday-still"}}}
        """)

        guard case .video(let media) = event.content else {
            Issue.record("expected a video, got \(event.content)")
            return
        }

        #expect(!media.isAnimated)
        #expect(media.thumbnailURL == "mxc://example.com/holiday-still")
        #expect(event.content.preview == "Video")
    }

    @Test("WhatsApp's status feed is recognised however the bridge spells it", arguments: [
        "WhatsApp Status Broadcast",
        "whatsapp status broadcast",
        "WhatsApp Status Updates"
    ])
    func statusBroadcastByName(_ name: String) {
        #expect(StatusBroadcast.matches(name: name, partnerID: nil))
    }

    @Test("And by the address it comes from, for a room with no name")
    func statusBroadcastByAddress() {
        #expect(StatusBroadcast.matches(
            name: nil, partnerID: "@whatsapp_status_broadcast:example.com"
        ))
    }

    @Test("A chat with somebody who happens to mention status is left alone")
    func notStatusBroadcast() {
        #expect(!StatusBroadcast.matches(name: "Status meeting", partnerID: nil))
        // A group whose name merely contains the words is a group, not the feed.
        #expect(!StatusBroadcast.matches(name: "Weekly status updates", partnerID: nil))
        #expect(!StatusBroadcast.matches(name: "Project status broadcast team", partnerID: nil))
        #expect(!StatusBroadcast.matches(name: "Alex", partnerID: "@whatsapp_31612345678:example.com"))
    }

    @Test("A caption under a picture is the body beside a filename")
    func captionedImage() throws {
        // What a bridge sends when somebody typed something under the photo: the file has
        // its own name, so the body is free to be words.
        let event = try decode("""
        {"event_id":"$c1","sender":"@whatsapp_316:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,
         "content":{"msgtype":"m.image","body":"Look at this","filename":"IMG_4021.jpg",
                    "url":"mxc://example.com/pic",
                    "info":{"mimetype":"image/jpeg","w":100,"h":100}}}
        """)

        guard case .image(let media) = event.content else {
            Issue.record("expected an image, got \(event.content)")
            return
        }

        #expect(media.caption == "Look at this")
        #expect(event.content.preview == "Look at this")
    }

    @Test("A filename repeated in both fields is not a caption")
    func noCaption() throws {
        let event = try decode("""
        {"event_id":"$c2","sender":"@alex:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,
         "content":{"msgtype":"m.image","body":"IMG_4021.jpg","filename":"IMG_4021.jpg",
                    "url":"mxc://example.com/pic","info":{"mimetype":"image/jpeg"}}}
        """)

        guard case .image(let media) = event.content else {
            Issue.record("expected an image")
            return
        }

        #expect(media.caption == nil)
        #expect(event.content.preview == "Photo")
    }

    @Test("A reaction carries the emoji and the message it belongs to")
    func reaction() throws {
        let event = try decode("""
        {"event_id":"$3","sender":"@alex:example.com","type":"m.reaction",
         "origin_server_ts":1700000000000,
         "content":{"m.relates_to":{"rel_type":"m.annotation","event_id":"$1","key":"👍"}}}
        """)

        #expect(event.content == .reaction(key: "👍"))
        #expect(event.relation?.eventID == "$1")
        #expect(event.relation?.kind == .annotation)
    }

    @Test("A reply points at the message being answered")
    func reply() throws {
        let event = try decode("""
        {"event_id":"$4","sender":"@alex:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,
         "content":{"msgtype":"m.text","body":"Sure",
                    "m.relates_to":{"m.in_reply_to":{"event_id":"$1"}}}}
        """)

        #expect(event.relation?.kind == .reply)
        #expect(event.relation?.eventID == "$1")
    }

    @Test("A redacted event has no content to read")
    func redacted() throws {
        let event = try decode("""
        {"event_id":"$5","sender":"@alex:example.com","type":"m.room.message",
         "origin_server_ts":1700000000000,"content":{},
         "unsigned":{"redacted_because":{"type":"m.room.redaction"}}}
        """)

        #expect(event.isRedacted)
        #expect(event.content == .redaction)
    }

    @Test("An unknown event type never breaks the timeline")
    func unknownType() throws {
        let event = try decode("""
        {"event_id":"$6","sender":"@alex:example.com","type":"org.example.whatever",
         "origin_server_ts":1700000000000,"content":{"anything":[1,2,3]}}
        """)

        #expect(event.content == .unsupported(type: "org.example.whatever"))
        #expect(!event.content.isMessage)
    }
}

@Suite("Bridge identity")
struct BridgeIdentityTests {

    @Test("Ghost accounts reveal which network someone is on", arguments: [
        ("@signal_a1b2c3:example.com", ChatNetwork.signal),
        ("@whatsapp_31612345678:example.com", .whatsapp),
        ("@telegram_9988:example.com", .telegram),
        ("@alex:example.com", .matrix)
    ])
    func networkDetection(userID: String, expected: ChatNetwork) {
        #expect(BridgeIdentity.network(of: userID) == expected)
    }

    @Test("Bridge control accounts are told apart from people")
    func bridgeBots() {
        #expect(BridgeIdentity.isBridgeBot("@signalbot:example.com"))
        #expect(BridgeIdentity.isBridgeBot("@whatsappbot:example.com"))
        #expect(!BridgeIdentity.isBridgeBot("@signal_a1b2c3:example.com"))
        #expect(!BridgeIdentity.isBridgeBot("@alex:example.com"))
    }

    @Test("A redundant network suffix is trimmed from display names")
    func cleanNames() {
        #expect(BridgeIdentity.cleanDisplayName("Anna (Signal)", network: .signal) == "Anna")
        #expect(BridgeIdentity.cleanDisplayName("Anna", network: .signal) == "Anna")
    }
}

@Suite("Homeserver addresses")
struct HomeserverTests {

    @Test("A bare hostname is assumed to be https")
    func bareHostname() {
        #expect(Homeserver(string: "matrix.example.com")?.url.absoluteString == "https://matrix.example.com")
    }

    @Test("Paths are stripped, because a base URL is all this needs")
    func stripsPath() {
        #expect(Homeserver(string: "https://matrix.example.com/_matrix/foo")?.url.absoluteString
                == "https://matrix.example.com")
    }

    @Test("A non-standard port survives and is shown")
    func keepsPort() throws {
        // The case that matters here: a provider blocking 443 forces the server onto another
        // port, and every request after sign-in has to keep using it. Leaving the port out of
        // the display would also hand people an address that never answers.
        let server = try #require(Homeserver(string: "matrix.example.com:8443"))
        #expect(server.url.port == 8443)
        #expect(server.displayName == "matrix.example.com:8443")

        let endpoint = try #require(server.endpoint("/_matrix/client/versions"))
        #expect(endpoint.absoluteString == "https://matrix.example.com:8443/_matrix/client/versions")
    }

    @Test("Without a port, none is invented")
    func noPortShown() throws {
        let server = try #require(Homeserver(string: "matrix.example.com"))
        #expect(server.displayName == "matrix.example.com")
    }

    @Test("A room ID inside a path survives intact")
    func roomIDInPathIsNotDoubleEncoded() throws {
        // Matrix IDs contain "!" and ":", which have to be percent-encoded to sit in a path.
        // Encoding them twice produces a URL the server answers with 404 — an error that
        // reads like a missing endpoint rather than a mangled address.
        let server = try #require(Homeserver(string: "matrix.example.com:8443"))
        let roomID = "!abc:matrix.example.com".pathEscaped

        let url = try #require(server.endpoint("/_matrix/client/v3/join/\(roomID)"))

        #expect(url.absoluteString ==
                "https://matrix.example.com:8443/_matrix/client/v3/join/%21abc%3Amatrix.example.com")
        #expect(!url.absoluteString.contains("%25"))
    }

    @Test("Nonsense is rejected rather than half-accepted")
    func rejectsGarbage() {
        #expect(Homeserver(string: "") == nil)
        #expect(Homeserver(string: "   ") == nil)
    }
}

@Suite("Reply fallbacks")
struct ReplyFallbackTests {

    @Test("The quoted original is dropped, the reply is kept")
    func stripsQuote() {
        let body = "> <@alex:example.com> are you coming?\n\nyes, on my way"
        #expect(ReplyFallback.strip(body) == "yes, on my way")
    }

    @Test("A quote spanning several lines is dropped whole")
    func stripsMultilineQuote() {
        let body = "> <@a:b> first\n> second\n> third\n\nok"
        #expect(ReplyFallback.strip(body) == "ok")
    }

    @Test("A message that isn't a reply is left alone")
    func leavesPlainText() {
        #expect(ReplyFallback.strip("just a message") == "just a message")
        #expect(ReplyFallback.strip("2 > 1, always") == "2 > 1, always")
    }

    @Test("A message that is only a quote is someone quoting on purpose")
    func keepsDeliberateQuote() {
        // Nothing follows the quote, so removing it would leave an empty message where there
        // was something to read.
        #expect(ReplyFallback.strip("> a thing worth repeating") == "> a thing worth repeating")
    }
}

@Suite("Emoji-only messages")
struct EmojiOnlyTests {

    @Test("Plain emoji are drawn large")
    func plainEmoji() {
        #expect(EmojiOnly.matches("😂"))
        #expect(EmojiOnly.matches("🥳"))
        #expect(EmojiOnly.matches("😂😂"))
        #expect(EmojiOnly.matches("👍🏻"))
    }

    @Test("Emoji that need a variation selector count too")
    func variationSelectors() {
        // The ones an earlier version missed. ❤️ is the single most-sent emoji there is, so
        // failing on it meant the feature effectively didn't exist.
        #expect(EmojiOnly.matches("❤️"))
        #expect(EmojiOnly.matches("☺️"))
        #expect(EmojiOnly.matches("‼️"))
    }

    @Test("Joined sequences and flags are one emoji each")
    func sequences() {
        #expect(EmojiOnly.matches("👨‍👩‍👧"))
        #expect(EmojiOnly.matches("🇳🇱"))
        #expect(EmojiOnly.matches("1️⃣"))
    }

    @Test("Anything with words in it keeps its bubble")
    func text() {
        #expect(!EmojiOnly.matches("ok"))
        #expect(!EmojiOnly.matches("😂 leuk"))
        #expect(!EmojiOnly.matches("1"))
        #expect(!EmojiOnly.matches(""))
        #expect(!EmojiOnly.matches("   "))
    }

    @Test("A row of emoji is a message, not an exclamation")
    func tooMany() {
        #expect(!EmojiOnly.matches("😂😂😂😂"))
    }
}
