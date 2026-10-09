import Foundation

/// WhatsApp's status feed, which the bridge turns into a chat like any other.
///
/// It isn't one. Everybody you know posts a picture of their coffee into the same room, it
/// never needs an answer, and left alone it sits at the top of the list all day pushing the
/// people who actually wrote to you out of sight.
///
/// Recognising it is done by hand because the bridge doesn't mark it: `status@broadcast` is
/// just another portal as far as Matrix is concerned. Both spellings the bridge has used are
/// matched, along with the address it comes from, so an older room doesn't reappear after an
/// update.
public enum StatusBroadcast {

    /// Whether a room is the status feed rather than a conversation with someone.
    ///
    /// Asked about every conversation on every redraw, so it was worth measuring rather than
    /// guessing at. A version using `range(of:options:.caseInsensitive)` to avoid the
    /// lowercased copy was tried and is slower — 0.26 ms against 0.20 ms over two hundred
    /// names — because that call goes through Foundation's collation machinery and this one
    /// does not. Left as it was, on the evidence.
    ///
    /// By the whole name, never by a piece of it. It used to look for the words anywhere in a
    /// room's name, so a group called "Weekly status updates" was taken for the feed — and the
    /// feed is hidden from both lists and muted on the server, on by default. Everything said
    /// in that group went unseen, with nothing to show it was happening.
    public static func matches(name: String?, partnerID: String?) -> Bool {
        if let name = name?.lowercased().trimmingCharacters(in: .whitespaces),
           Self.names.contains(name) {
            return true
        }

        if let partnerID = partnerID?.lowercased() {
            if partnerID.contains("status_broadcast") { return true }
            if partnerID.contains("statusbroadcast") { return true }
            if partnerID.contains("status@broadcast") { return true }
        }

        return false
    }

    /// Every name the bridge has given the feed, whole.
    private static let names: Set<String> = [
        "whatsapp status broadcast",
        "whatsapp status updates",
        "whatsapp status",
        "status broadcast",
    ]
}
