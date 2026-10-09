import Foundation

/// Message text with its links made into links.
///
/// SwiftUI's `Text` renders a URL as plain characters, which is fine until the app starts
/// sending them itself: a shared location that can't be tapped is a row of numbers. The
/// detector is the same one Mail and Messages use, so what counts as a link matches what
/// people are used to.
public enum LinkedText {

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Turns any addresses in a message into tappable links.
    public static func attributed(_ body: String) -> AttributedString {
        var attributed = AttributedString(body)

        guard let detector else { return attributed }

        let range = NSRange(body.startIndex..., in: body)
        let matches = detector.matches(in: body, range: range)

        for match in matches {
            guard let url = match.url,
                  let swiftRange = Range(match.range, in: body),
                  let attributedRange = Range(swiftRange, in: attributed)
            else { continue }

            attributed[attributedRange].link = url
        }

        return attributed
    }

    /// Whether there's anything in here worth making tappable.
    ///
    /// Checked first because most messages have no link at all, and running the detector over
    /// every line of every conversation while scrolling is work for nothing.
    public static func containsLink(_ body: String) -> Bool {
        body.contains("://") || body.contains("www.") || body.contains("geo:")
    }
}
