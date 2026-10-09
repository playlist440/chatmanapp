import Testing
import Foundation
@testable import ChatmanKit

/// A location has to survive the round trip through a bridge, which means through plain text.
@Suite("Sharing a location")
struct LocationTests {

    @Test("What gets sent carries both the numbers and a link")
    func message() {
        let place = SharedLocation(latitude: 52.370216, longitude: 4.895168)

        #expect(place.coordinates == "52.370216, 4.895168")
        #expect(place.message.contains("52.370216, 4.895168"))
        #expect(place.message.contains("https://maps.google.com/?q=52.370216,4.895168"))
    }

    @Test("A named place says where it is, and still carries the numbers")
    func namedPlace() throws {
        let place = SharedLocation(latitude: 52.370216, longitude: 4.895168)
            .naming("Kerkstraat 1, Amsterdam")

        let lines = place.message.split(separator: "\n").map(String.init)

        #expect(lines.count == 3)
        #expect(lines[0].contains("Kerkstraat 1, Amsterdam"))
        #expect(lines[1] == "52.370216, 4.895168")
        #expect(lines[2].hasPrefix("https://"))

        // An address must never cost the machine-readable half: this is what the receiving
        // side finds when it decides whether to show an "Open in Maps" button.
        let read = try #require(SharedLocation.inside(place.message))
        #expect(abs(read.latitude - 52.370216) < 0.000001)
    }

    @Test("Chatman reads back its own message")
    func roundTrip() throws {
        let sent = SharedLocation(latitude: 52.370216, longitude: 4.895168)
        let read = try #require(SharedLocation.inside(sent.message))

        #expect(abs(read.latitude - 52.370216) < 0.000001)
        #expect(abs(read.longitude - 4.895168) < 0.000001)
    }

    @Test("And what other apps send", arguments: [
        "geo:52.370216,4.895168",
        "Here I am https://maps.google.com/?q=52.370216,4.895168",
        "https://maps.apple.com/?ll=52.370216,4.895168&q=Me",
        "https://www.google.com/maps/@52.370216,4.895168,17z"
    ])
    func otherApps(_ body: String) throws {
        let place = try #require(SharedLocation.inside(body))

        #expect(abs(place.latitude - 52.370216) < 0.0001)
        #expect(abs(place.longitude - 4.895168) < 0.0001)
    }

    @Test("An ordinary message is not a location")
    func notALocation() {
        #expect(SharedLocation.inside("See you at eight") == nil)
        #expect(SharedLocation.inside("It cost 12.50, and 3.20 for the coffee") == nil)
        #expect(SharedLocation.inside("https://example.com/page") == nil)
    }

    @Test("Nonsense coordinates are refused rather than shown on a map")
    func outOfRange() {
        #expect(SharedLocation.inside("geo:952.370216,4.895168") == nil)
    }

    @Test("A link in a message becomes a link")
    func links() {
        #expect(LinkedText.containsLink("look: https://example.com"))
        #expect(!LinkedText.containsLink("no address here"))

        let attributed = LinkedText.attributed("Here: https://example.com/x")
        let hasLink = attributed.runs.contains { $0.link != nil }
        #expect(hasLink)
    }
}
