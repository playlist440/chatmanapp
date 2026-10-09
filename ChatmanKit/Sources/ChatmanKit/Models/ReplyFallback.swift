import Foundation

/// The quoted copy of the original that clients put at the top of a reply.
///
/// Matrix calls this the reply fallback: the message being answered, every line prefixed with
/// `>`, so a client that can't draw replies still shows what was replied to. Chatman draws
/// them properly, so keeping the fallback would say the same thing twice — once as a quote and
/// once as the message itself.
public enum ReplyFallback {

    /// The message without its quoted original.
    public static func strip(_ body: String) -> String {
        guard body.hasPrefix(">") else { return body }

        var lines = body.components(separatedBy: "\n")

        while let first = lines.first, first.hasPrefix(">") {
            lines.removeFirst()
        }

        // The spec puts one blank line between the quote and the reply.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }

        let stripped = lines.joined(separator: "\n")

        // A message that is nothing but a quote is someone quoting on purpose, not a fallback.
        return stripped.isEmpty ? body : stripped
    }
}
