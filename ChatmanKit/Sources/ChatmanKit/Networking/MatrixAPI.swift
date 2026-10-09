import Foundation

/// A thin, stateless client for the Matrix client-server API.
///
/// Only the endpoints Chatman actually uses are implemented. That's a deliberate limit: the
/// app exists to talk to bridged Signal and WhatsApp conversations, so spaces, threads,
/// voice rooms, widgets and the rest of Matrix's surface area stay out. Less code means a
/// smaller watch binary and fewer ways to be slow.
///
/// The type is a value: it holds no mutable state, so it's safe to pass anywhere. When
/// credentials change, make a new one.
public struct MatrixAPI: Sendable {

    public let homeserver: Homeserver
    public let accessToken: String?

    let urlSession: URLSession

    /// The connection used for everything, unless a caller supplies its own.
    ///
    /// Not `URLSession.shared`, because the defaults are wrong for a watch away from its
    /// phone. On cellular the radio is often asleep when a request goes out: the shared
    /// session fails immediately, while this one waits for the connection to come up. And a
    /// watch on a metered link is exactly the case `allowsExpensiveNetworkAccess` refuses by
    /// default — refusing it here would mean the app simply never works outdoors, which is
    /// the whole reason it exists.
    public static let connection: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 45
        // With `waitsForConnectivity` this is also the cap on how long a request may sit
        // waiting for a network that never comes. It's the difference between an app that
        // says "not connected" within the minute and one that shows "Updating…" for several
        // — which is what a watch with no usable data connection did.
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// The connection used for photos and other attachments.
    ///
    /// Separate from ``connection`` because the two want opposite things. A sync that can't
    /// get through should give up quickly and say so; a photo someone has just tapped is
    /// worth several megabytes and a long wait on a slow cellular link, and giving up on it
    /// early only means they tap again.
    public static let download: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// The connection for small pictures: faces, and the thumbnails in a conversation.
    ///
    /// Apart from ``download`` because it gives up much sooner. That one allows three minutes,
    /// which is right for an original of several megabytes on a slow link and wrong for a
    /// thumbnail of a few kilobytes: on a watch, one that stalled kept its spinner turning
    /// for all of that time, which looks the same as for ever. A thumbnail that hasn't come
    /// in three quarters of a minute isn't coming, and saying "unavailable" lets the next look
    /// try again. Its own connections, too, so it never waits behind an original.
    public static let preview: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()

    /// The connection for requests that are meant to take minutes: uploads, and a bridge
    /// waiting for a code to be scanned.
    ///
    /// Those set a long timeout of their own, and on ``connection`` it did nothing. A request's
    /// timeout only governs how long it may sit silent; the minute ``connection`` allows for a
    /// whole request is a separate limit, and the shorter of the two wins. So a film that took
    /// longer than a minute to upload failed as "Not sent", and a bridge login gave up on its
    /// code after one minute instead of four and started again with a new one.
    ///
    /// Ten minutes, because that is the longest any request here asks for.
    static let longRunning: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// The session that will actually let a request run as long as it asks to.
    ///
    /// The ordinary one whenever it can, so everything that doesn't ask for more — the long
    /// poll included — keeps the quick failure it was given. A session a caller supplied is
    /// only passed over when its own limit is too short as well.
    func session(allowing timeout: TimeInterval?) -> URLSession {
        guard let timeout,
              timeout > urlSession.configuration.timeoutIntervalForResource
        else { return urlSession }

        return Self.longRunning
    }

    public init(
        homeserver: Homeserver,
        accessToken: String? = nil,
        urlSession: URLSession = MatrixAPI.connection
    ) {
        self.homeserver = homeserver
        self.accessToken = accessToken
        self.urlSession = urlSession
    }

    /// Returns a copy carrying the given access token.
    public func authenticated(with token: String) -> MatrixAPI {
        MatrixAPI(homeserver: homeserver, accessToken: token, urlSession: urlSession)
    }

    // MARK: - Request machinery

    enum Method: String {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
    }

    /// Performs a request and decodes the response.
    ///
    /// - Parameter timeout: Overrides the request timeout. Sync uses this to hold a long poll
    ///   open; everything else should leave it alone.
    func send<Response: Decodable>(
        _ method: Method,
        path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        requiresAuth: Bool = true,
        timeout: TimeInterval? = nil,
        as responseType: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await sendReturningData(
            method, path: path, query: query, body: body,
            requiresAuth: requiresAuth, timeout: timeout
        )

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw MatrixError.decoding(String(describing: error))
        }
    }

    /// Performs a request, ignoring the response body.
    func send(
        _ method: Method,
        path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        requiresAuth: Bool = true
    ) async throws {
        _ = try await sendReturningData(
            method, path: path, query: query, body: body,
            requiresAuth: requiresAuth, timeout: nil
        )
    }

    func sendReturningData(
        _ method: Method,
        path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable)? = nil,
        requiresAuth: Bool = true,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        guard let url = homeserver.endpoint(path, query: query) else {
            throw MatrixError.invalidHomeserver
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue

        if let timeout {
            request.timeoutInterval = timeout
        }

        if requiresAuth {
            guard let accessToken else { throw MatrixError.notSignedIn }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                throw MatrixError.decoding(String(describing: error))
            }
        }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session(allowing: timeout).data(for: request)
        } catch let error as URLError {
            throw MatrixError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MatrixError.unexpectedStatus(-1)
        }

        guard (200..<300).contains(http.statusCode) else {
            // Matrix puts a structured error in the body. It tells us whether this is worth
            // retrying, so read it before giving up.
            if let apiError = try? JSONDecoder().decode(MatrixErrorResponse.self, from: data) {
                throw MatrixError.api(apiError)
            }
            throw MatrixError.unexpectedStatus(http.statusCode)
        }

        return data
    }

    /// A transaction ID for requests that must not be applied twice.
    ///
    /// The server deduplicates on this, so a retried send after a dropped connection doesn't
    /// post the message twice — which on a watch drifting between networks is a real risk.
    public static func transactionID() -> String {
        "chatman.\(UUID().uuidString)"
    }
}
