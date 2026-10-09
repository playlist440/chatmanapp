import Foundation

/// The address of a Matrix homeserver.
///
/// Chatman talks to exactly one server — the one running your bridges — so this is a plain
/// value rather than something that needs discovering at runtime. Well-known delegation is
/// supported at sign-in only, to resolve `@you:example.com` to the server that actually
/// answers for it.
public struct Homeserver: Sendable, Hashable, Codable {

    /// The base URL, without a trailing slash, e.g. `https://matrix.example.com`.
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Creates a homeserver from user input, filling in `https` when no scheme is given.
    ///
    /// People type `matrix.example.com`, not `https://matrix.example.com`, and getting that
    /// wrong is the most common reason a sign-in fails for no visible reason.
    public init?(string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"

        guard var components = URLComponents(string: withScheme),
              let host = components.host, !host.isEmpty
        else { return nil }

        // Strip anything after the authority: a base URL is all this needs to be.
        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let url = components.url else { return nil }
        self.url = url
    }

    /// The host, for display in the interface.
    ///
    /// The port is included when there is one, because leaving it out turns a working address
    /// into one that isn't: a server reachable only on 8443 reads as plain `example.com`, and
    /// anyone copying that from the settings screen ends up somewhere that never answers.
    public var displayName: String {
        guard let host = url.host() else { return url.absoluteString }
        guard let port = url.port else { return host }
        return "\(host):\(port)"
    }

    /// Builds a URL for an endpoint path, with optional query items.
    ///
    /// The path arrives already percent-encoded, because Matrix identifiers live inside it and
    /// `!room:server` has to survive intact. Assigning to `path` would encode it a second time
    /// — `%21` becomes `%2521` — and the server then looks for a room that doesn't exist. It
    /// fails quietly, as a 404 on an endpoint that plainly exists.
    ///
    /// A path that isn't validly encoded gives `nil`, which every caller already turns into an
    /// error. It has to be checked here first: `percentEncodedPath` doesn't refuse such a path,
    /// it stops the app on the spot. That is how one space typed into the bridge path in the
    /// settings could crash Chatman on every launch — the list asks the bridges as it opens,
    /// before the setting that caused it can be reached to put it right.
    func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL? {
        guard Self.isEncodedPath(path),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query

        return components.url
    }

    /// Whether a path holds only what may stand in a URL path as it is: the characters allowed
    /// there, and `%` followed by two hex digits.
    ///
    /// The same test `percentEncodedPath` applies before it traps, asked in a way that can
    /// answer no.
    static func isEncodedPath(_ path: String) -> Bool {
        var scalars = path.unicodeScalars.makeIterator()

        while let scalar = scalars.next() {
            if scalar == "%" {
                guard let high = scalars.next(), high.properties.isASCIIHexDigit,
                      let low = scalars.next(), low.properties.isASCIIHexDigit
                else { return false }
            } else if !CharacterSet.urlPathAllowed.contains(scalar) {
                return false
            }
        }

        return true
    }
}
