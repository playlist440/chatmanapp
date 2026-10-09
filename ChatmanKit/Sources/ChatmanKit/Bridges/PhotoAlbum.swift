import Foundation

/// Several pictures sent at once, put back together.
///
/// WhatsApp sends an album as one thing. Matrix has no such event, so the bridge takes it
/// apart: every picture arrives as its own message, and a line of bridge-written text —
/// "Sent an album with 7 images:" — is sent along with them to say what happened. In a client
/// that doesn't know about any of this, an album of seven photos is seven separate bubbles
/// with a sentence nobody typed sitting in the middle of them.
///
/// Worse, a reaction to the album lands on that sentence, because the sentence is the event
/// the other person's phone treats as the album. So the heart ends up beside a line of
/// plumbing instead of beside the photos it was meant for.
///
/// This puts it back: a run of pictures from one person becomes one album, the bridge's
/// sentence is dropped, and whatever was said about it moves to the pictures.
public enum PhotoAlbum {

    /// One entry in a conversation: either a message on its own, or several pictures that
    /// were sent as one.
    public enum Item: Identifiable {
        case single(Message)
        case album(Album)

        public var id: String {
            switch self {
            case .single(let message): message.id
            case .album(let album): album.id
            }
        }

        /// The message this entry is anchored to, for scrolling, dates and runs.
        public var anchor: Message {
            switch self {
            case .single(let message): message
            case .album(let album): album.photos[0]
            }
        }
    }

    /// Pictures sent together, and everything that was said about them.
    public struct Album: Identifiable {
        public let photos: [Message]

        /// The reactions on every part of it, added up — including the ones that landed on
        /// the bridge's own sentence, which is where they usually are.
        public let reactions: [String: Int]

        /// What somebody wrote under the album. WhatsApp allows one for the set; whichever
        /// picture carries it, it belongs to all of them.
        public let caption: String?

        public var id: String { photos[0].id }
    }

    /// Whether a line of text is the bridge saying "this was an album".
    ///
    /// Matched on the words because there is nothing else to match on: the event is an
    /// ordinary text message and carries no mark saying who wrote it. That would be risky on
    /// its own — somebody could type this — so it only ever counts when it is found in the
    /// middle of a run of pictures from the same person. On its own it stays a message.
    public static func isAlbumNotice(_ body: String) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return text.hasPrefix("sent an album with")
    }

    /// How far apart two pictures can be and still count as sent together.
    ///
    /// Generous on purpose: a bridge relays an album one picture at a time over a connection
    /// it doesn't control, and the last of seven can arrive well after the first.
    private static let window: TimeInterval = 120

    /// Groups a conversation into what should be drawn.
    public static func group(_ messages: [Message]) -> [Item] {
        var items: [Item] = []
        var index = 0

        while index < messages.count {
            let message = messages[index]

            guard isPicture(message) else {
                items.append(.single(message))
                index += 1
                continue
            }

            // A run of pictures from the same person, close together, with any of the
            // bridge's own sentences swallowed along the way.
            var photos: [Message] = []
            var counted: [String: Int] = [:]
            var said: String?
            var last = message.timestamp
            var cursor = index

            while cursor < messages.count {
                let next = messages[cursor]

                guard next.sender == message.sender,
                      next.timestamp.timeIntervalSince(last) <= window
                else { break }

                if isPicture(next) {
                    photos.append(next)
                    if said == nil, let caption = next.caption, !caption.isEmpty {
                        said = caption
                    }
                } else if isText(next), isAlbumNotice(next.body) {
                    // Dropped, but not what was said about it.
                } else {
                    break
                }

                for (emoji, count) in next.reactions {
                    counted[emoji, default: 0] += count
                }

                last = next.timestamp
                cursor += 1
            }

            // One picture on its own is not an album, unless the bridge said it was — in
            // which case the sentence still has to go, and its reactions with it.
            if photos.count > 1 || cursor > index + 1 {
                items.append(
                    .album(Album(photos: photos, reactions: counted, caption: said))
                )
            } else {
                items.append(.single(message))
            }

            index = cursor
        }

        return items
    }

    private static func isPicture(_ message: Message) -> Bool {
        message.kind == .image || message.kind == .video
    }

    /// Anything made of words.
    ///
    /// A bridge writes its own sentence as `m.notice`, which is what the type is for: a line
    /// from a machine rather than from a person. Checking only for `m.text` is why the first
    /// picture of an album stayed on its own — the notice broke the run instead of being
    /// swallowed by it.
    private static func isText(_ message: Message) -> Bool {
        message.kind == .text || message.kind == .notice || message.kind == .emote
    }
}
