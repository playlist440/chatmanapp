#if canImport(UIKit)
import SwiftUI

/// A colour per person, in a group.
///
/// Borrowed from WhatsApp and Telegram, where it's the thing that makes a busy group readable
/// at a glance: you learn "green is Marieke" within a day and stop reading names altogether.
/// The colour has to be the same on every device and after every restart, so it comes from
/// the person's own account name rather than from the order they happened to speak in.
///
/// Chosen to stay legible on both a white bubble and a black watch screen, which rules out
/// yellows and the palest greens.
public enum SenderColour {

    private static let palette: [Color] = [
        Color(red: 0.20, green: 0.45, blue: 0.90),   // blue
        Color(red: 0.85, green: 0.25, blue: 0.35),   // red
        Color(red: 0.15, green: 0.60, blue: 0.35),   // green
        Color(red: 0.60, green: 0.30, blue: 0.80),   // purple
        Color(red: 0.90, green: 0.45, blue: 0.10),   // orange
        Color(red: 0.10, green: 0.55, blue: 0.60),   // teal
        Color(red: 0.80, green: 0.30, blue: 0.60),   // pink
        Color(red: 0.35, green: 0.40, blue: 0.75)    // indigo
    ]

    /// The colour for whoever this is.
    public static func of(_ account: String) -> Color {
        palette[index(for: account)]
    }

    /// A stable number for a string, without relying on Swift's hashing.
    ///
    /// `hashValue` is seeded differently on every launch, so using it here would give
    /// somebody a new colour every time the app started — which is worse than no colours.
    private static func index(for account: String) -> Int {
        var hash: UInt64 = 5381
        for byte in account.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return Int(hash % UInt64(palette.count))
    }
}
#endif
