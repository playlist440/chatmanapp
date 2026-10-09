import Foundation

/// Where you are, as a message anybody can open.
///
/// Bridges have no way to carry a location: Signal and WhatsApp both have their own kind of
/// message for it, and nothing on the Matrix side survives the trip intact. What does survive
/// is text, through every bridge there is — so a location goes as a link, and the person at
/// the other end taps it and lands in whatever map app their phone already uses.
///
/// Both halves are deliberate. The coordinates are there to be read out loud over a phone
/// call, which is the moment this is actually for; the link is there so nobody has to.
public struct SharedLocation: Sendable, Hashable, Identifiable {

    public let latitude: Double
    public let longitude: Double

    /// How far off the fix might be, in metres, when the device said.
    public let accuracy: Double?

    /// What the place is called, when the map knew. A street and a town say more at a glance
    /// than six decimal places, and it's what somebody reads out to a taxi driver.
    public let address: String?

    public var id: String { coordinates }

    public init(
        latitude: Double, longitude: Double, accuracy: Double? = nil, address: String? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.address = address
    }

    /// The same place, with a name attached.
    public func naming(_ address: String?) -> SharedLocation {
        SharedLocation(
            latitude: latitude, longitude: longitude, accuracy: accuracy, address: address
        )
    }

    /// Six decimal places: about a tenth of a metre, which is far past what any phone knows
    /// and short enough to read aloud.
    public var coordinates: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }

    /// The link that goes in the message.
    ///
    /// Google's, and not because of Google. It's the one address that opens the right app on
    /// an Android phone, opens Google Maps on an iPhone that has it, and falls back to a
    /// working map in any browser — and the person receiving this is on whatever they're on.
    /// Apple's own link does none of those three outside Apple's own devices.
    public var mapsURL: URL? {
        URL(string: "https://maps.google.com/?q=\(latitude),\(longitude)")
    }

    /// Opens in Maps on an Apple device, for the copy shown inside Chatman itself.
    public var appleMapsURL: URL? {
        URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=Shared%20location")
    }

    /// What actually gets sent.
    ///
    /// Three lines at most, and each one is there for a different person: the address for
    /// whoever is reading it, the numbers for whoever is typing them into something else, and
    /// the link for whoever just wants to tap.
    public var message: String {
        var lines: [String] = []

        if let address, !address.isEmpty {
            lines.append("📍 My location — \(address)")
            lines.append(coordinates)
        } else {
            lines.append("📍 My location: \(coordinates)")
        }

        if let link = mapsURL { lines.append(link.absoluteString) }

        return lines.joined(separator: "\n")
    }

    // MARK: - Reading one back

    /// Finds a location in a message somebody sent.
    ///
    /// Written against what arrives rather than what Chatman sends: a location from WhatsApp
    /// comes through the bridge as a maps link of its own, and one from a Matrix client comes
    /// as a `geo:` URI. All three read the same way once the numbers are out.
    public static func inside(_ body: String) -> SharedLocation? {
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { continue }

            let range = NSRange(body.startIndex..., in: body)
            guard let match = expression.firstMatch(in: body, range: range),
                  match.numberOfRanges >= 3,
                  let latitude = double(match.range(at: 1), in: body),
                  let longitude = double(match.range(at: 2), in: body),
                  (-90...90).contains(latitude), (-180...180).contains(longitude)
            else { continue }

            return SharedLocation(latitude: latitude, longitude: longitude)
        }

        return nil
    }

    private static let patterns = [
        // geo:52.37,4.89 — what a Matrix client sends.
        #"geo:(-?\d+\.\d+),\s*(-?\d+\.\d+)"#,
        // maps.google.com/?q=… and maps.apple.com/?ll=…
        #"maps\.[a-z]+\.com/[^\s]*[?&](?:q|ll|daddr)=(-?\d+\.\d+),(-?\d+\.\d+)"#,
        // google.com/maps/@52.37,4.89,15z and /maps/place/…/@…
        #"google\.[a-z.]+/maps[^\s]*@(-?\d+\.\d+),(-?\d+\.\d+)"#,
        // Bare coordinates on their own, as Chatman writes them.
        #"(?:^|\s)(-?\d{1,3}\.\d{4,}),\s*(-?\d{1,3}\.\d{4,})"#
    ]

    private static func double(_ range: NSRange, in body: String) -> Double? {
        guard let swiftRange = Range(range, in: body) else { return nil }
        return Double(body[swiftRange])
    }
}
