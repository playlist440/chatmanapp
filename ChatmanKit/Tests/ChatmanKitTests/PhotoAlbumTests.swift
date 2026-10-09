import Testing
import Foundation
import SwiftData
@testable import ChatmanKit

/// Tests for putting a WhatsApp album back together.
///
/// The shapes here are the ones a mautrix bridge actually produces: every picture as its own
/// event, a line of bridge-written text somewhere among them, and the reaction sitting on
/// that line rather than on any of the pictures.
@MainActor
@Suite("Photo albums")
struct PhotoAlbumTests {

    /// Built and never stored. Grouping only reads what a message says about itself, so
    /// there is nothing here for a database to do — and putting the same event ID in two
    /// in-memory stores is how this suite first went down in flames.
    private func message(
        _ id: String,
        _ kind: Message.Kind,
        from sender: String = "@jordy:example.com",
        at seconds: TimeInterval,
        body: String = "",
        reactions: [String: Int] = [:],
        caption: String? = nil
    ) -> Message {
        let message = Message(
            id: id,
            sender: sender,
            timestamp: Date(timeIntervalSince1970: seconds),
            body: body,
            kind: kind
        )
        message.reactions = reactions
        message.caption = caption
        return message
    }

    @Test("Pictures sent together become one album")
    func groupsARun() {
        let messages = [
            message("$a", .image, at: 100),
            message("$b", .image, at: 102),
            message("$c", .image, at: 104)
        ]

        let items = PhotoAlbum.group(messages)

        #expect(items.count == 1)
        guard case .album(let album) = items[0] else {
            Issue.record("expected an album")
            return
        }
        #expect(album.photos.count == 3)
    }

    @Test("The bridge's own sentence is dropped and its reactions move to the pictures")
    func swallowsTheNotice() {
        let messages = [
            message("$a", .image, at: 100),
            message(
                "$notice", .text, at: 101,
                body: "Sent an album with 7 images:",
                reactions: ["❤️": 2],
            ),
            message("$b", .image, at: 102)
        ]

        let items = PhotoAlbum.group(messages)

        #expect(items.count == 1)
        guard case .album(let album) = items[0] else {
            Issue.record("expected an album")
            return
        }
        #expect(album.photos.map(\.id) == ["$a", "$b"])
        #expect(album.reactions == ["❤️": 2])
    }

    @Test("One picture with the bridge's sentence still loses the sentence")
    func singlePictureKeepsItsReaction() {
        let messages = [
            message("$a", .image, at: 100),
            message(
                "$notice", .text, at: 101,
                body: "Sent an album with 1 image:",
                reactions: ["👍": 1],
            )
        ]

        let items = PhotoAlbum.group(messages)

        #expect(items.count == 1)
        guard case .album(let album) = items[0] else {
            Issue.record("expected an album")
            return
        }
        #expect(album.photos.map(\.id) == ["$a"])
        #expect(album.reactions == ["👍": 1])
    }

    @Test("The bridge writes that sentence as a notice, which is what broke it")
    func swallowsANotice() {
        // The shape a real mautrix bridge sends: `m.notice`, not `m.text`. Checking only for
        // text left the first picture stranded on its own above the sentence, which is
        // exactly what it looked like on the phone.
        let messages = [
            message("$a", .image, at: 100),
            message(
                "$notice", .notice, at: 101,
                body: "Sent an album with 7 images:",
                reactions: ["❤️": 2],
            ),
            message("$b", .image, at: 102),
            message("$c", .image, at: 103)
        ]

        let items = PhotoAlbum.group(messages)

        #expect(items.count == 1)
        guard case .album(let album) = items[0] else {
            Issue.record("expected an album")
            return
        }
        #expect(album.photos.count == 3)
        #expect(album.reactions == ["❤️": 2])
    }

    @Test("That sentence typed by a person, with no pictures around it, stays a message")
    func leavesRealMessagesAlone() {
        let messages = [
            message("$a", .text, at: 100, body: "Sent an album with 7 images:")
        ]

        let items = PhotoAlbum.group(messages)

        #expect(items.count == 1)
        guard case .single = items[0] else {
            Issue.record("expected a plain message")
            return
        }
    }

    @Test("Pictures from two people are two things, not one")
    func splitsBySender() {
        let messages = [
            message("$a", .image, from: "@jordy:example.com", at: 100),
            message("$b", .image, from: "@marcia:example.com", at: 101)
        ]

        let items = PhotoAlbum.group(messages)

        #expect(items.count == 2)
    }

    @Test("Pictures an hour apart are two moments, not an album")
    func splitsByTime() {
        let messages = [
            message("$a", .image, at: 100),
            message("$b", .image, at: 4000)
        ]

        let items = PhotoAlbum.group(messages)

        #expect(items.count == 2)
    }

    @Test("A caption on any picture belongs to the album")
    func keepsTheCaption() {
        let messages = [
            message("$a", .image, at: 100),
            message("$b", .image, at: 102, caption: "Bij de dokter")
        ]

        let items = PhotoAlbum.group(messages)

        guard case .album(let album) = items[0] else {
            Issue.record("expected an album")
            return
        }
        #expect(album.caption == "Bij de dokter")
    }

    @Test("A single picture on its own is still a single picture")
    func leavesOnePictureAlone() {
        let messages = [message("$a", .image, at: 100)]

        let items = PhotoAlbum.group(messages)

        #expect(items.count == 1)
        guard case .single = items[0] else {
            Issue.record("expected a plain message")
            return
        }
    }

    @Test("A message between two albums keeps them apart")
    func textBreaksTheRun() {
        let messages = [
            message("$a", .image, at: 100),
            message("$talk", .text, at: 101, body: "Mooi hè"),
            message("$b", .image, at: 102)
        ]

        let items = PhotoAlbum.group(messages)

        #expect(items.count == 3)
    }
}
