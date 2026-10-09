import SwiftUI

/// The last thing said in a chat, the way Messages shows it: words as words, and a photo as a
/// small camera and the word for it rather than "Photo".
///
/// The line is stored as text when a message arrives, so older chats still carry the English
/// word from before the app spoke Dutch. Both spellings are recognised here and drawn the same.
public struct PreviewText: View {
    let line: String

    public init(_ line: String) { self.line = line }

    private struct Kind {
        let symbol: String
        let word: LocalizedStringResource
    }

    private static let kinds: [String: Kind] = {
        let photo = Kind(symbol: "photo", word: LocalizedStringResource("Photo", bundle: .atURL(Bundle.module.bundleURL)))
        let video = Kind(symbol: "video", word: LocalizedStringResource("Video", bundle: .atURL(Bundle.module.bundleURL)))
        let gif = Kind(symbol: "photo.stack", word: LocalizedStringResource("GIF", bundle: .atURL(Bundle.module.bundleURL)))
        let voice = Kind(symbol: "waveform", word: LocalizedStringResource("Voice message", bundle: .atURL(Bundle.module.bundleURL)))
        let sticker = Kind(symbol: "face.smiling", word: LocalizedStringResource("Sticker", bundle: .atURL(Bundle.module.bundleURL)))
        let locked = Kind(symbol: "lock", word: LocalizedStringResource("Encrypted message", bundle: .atURL(Bundle.module.bundleURL)))
        return [
            "Photo": photo, "Foto": photo,
            "Video": video,
            "GIF": gif,
            "Voice message": voice, "Spraakbericht": voice,
            "Sticker": sticker,
            "Encrypted message": locked, "Versleuteld bericht": locked
        ]
    }()

    public var body: some View {
        // A group's line starts with who said it: "Anna: Photo".
        let parts = line.split(separator: ": ", maxSplits: 1, omittingEmptySubsequences: false)
        let (who, what) = parts.count == 2 && Self.kinds[String(parts[1])] != nil
            ? (String(parts[0]) + ": ", String(parts[1]))
            : ("", line)

        if let kind = Self.kinds[what] {
            Text(verbatim: who) + Text(Image(systemName: kind.symbol)) + Text(verbatim: " ") + Text(kind.word)
        } else {
            Text(verbatim: line)
        }
    }
}
