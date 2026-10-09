import Foundation

/// Whether a message is nothing but emoji, and should be drawn large and bare.
///
/// Messages does this, and it's right to: a bubble around two characters is more chrome than
/// content. Getting the test right is fiddlier than it looks, because an emoji is rarely one
/// scalar. "❤️" is a heart plus an invisible marker that says "draw this as an emoji"; a
/// family is several people joined by zero-width joiners; a flag is two letters that mean
/// something else together. Testing every scalar for `isEmoji` fails all three — and ❤️ is
/// the one people actually send.
public enum EmojiOnly {

    /// The most a message can hold and still be drawn large.
    ///
    /// Beyond a handful it stops reading as an exclamation and starts being a wall.
    static let limit = 3

    public static func matches(_ body: String) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= limit else { return false }

        return text.allSatisfy(isEmoji)
    }

    /// Whether one character — one thing a person sees — is an emoji.
    private static func isEmoji(_ character: Character) -> Bool {
        guard let first = character.unicodeScalars.first else { return false }

        // Drawn as an emoji by default: 😂, 👍, and everything with a skin tone or a
        // zero-width joiner hanging off it, since those follow the first scalar.
        if first.properties.isEmojiPresentation { return true }

        // Text by default until a variation selector says otherwise. This is ❤️, ☺️ and ‼️ —
        // ordinary symbols that only became emoji when U+FE0F was appended.
        if character.unicodeScalars.contains(where: { $0.value == 0xFE0F }) {
            return first.properties.isEmoji
        }

        // Flags and keycaps: several scalars that each mean nothing alone. A lone ASCII digit
        // also reports `isEmoji`, which is why one scalar is never enough on its own.
        return character.unicodeScalars.count > 1
            && character.unicodeScalars.allSatisfy { $0.properties.isEmoji }
    }
}
