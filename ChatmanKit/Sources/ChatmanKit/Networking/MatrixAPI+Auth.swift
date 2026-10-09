import Foundation

extension MatrixAPI {

    // MARK: - Well-known discovery

    struct WellKnown: Decodable {
        struct HomeserverInfo: Decodable {
            let baseURL: String
            enum CodingKeys: String, CodingKey { case baseURL = "base_url" }
        }

        let homeserver: HomeserverInfo

        enum CodingKeys: String, CodingKey { case homeserver = "m.homeserver" }
    }

    /// Resolves the server that actually answers for a domain.
    ///
    /// A user ID like `@you:example.com` doesn't have to mean the server lives at
    /// `example.com` — the domain can delegate elsewhere. This is checked once at sign-in so
    /// people can type their Matrix ID and nothing else.
    public static func discoverHomeserver(
        forDomain domain: String,
        urlSession: URLSession = MatrixAPI.connection
    ) async -> Homeserver? {
        guard let base = Homeserver(string: domain),
              let url = base.endpoint("/.well-known/matrix/client")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let wellKnown = try? JSONDecoder().decode(WellKnown.self, from: data)
        else {
            // No delegation configured is normal and not an error: the domain is the server.
            return base
        }

        return Homeserver(string: wellKnown.homeserver.baseURL) ?? base
    }

    // MARK: - Sign in

    struct LoginRequest: Encodable {
        struct Identifier: Encodable {
            let type = "m.id.user"
            let user: String
        }

        let type = "m.login.password"
        let identifier: Identifier
        let password: String
        let initialDeviceDisplayName: String

        enum CodingKeys: String, CodingKey {
            case type, identifier, password
            case initialDeviceDisplayName = "initial_device_display_name"
        }
    }

    public struct LoginResponse: Decodable, Sendable {
        public let userID: String
        public let accessToken: String
        public let deviceID: String

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case accessToken = "access_token"
            case deviceID = "device_id"
        }
    }

    /// Signs in with a username and password.
    ///
    /// - Parameter username: Either a localpart (`alex`) or a full ID (`@alex:example.com`).
    ///   Both are accepted because people type both.
    public func logIn(username: String, password: String, deviceName: String) async throws -> LoginResponse {
        let user = username.hasPrefix("@")
            ? String(username.dropFirst().prefix { $0 != ":" })
            : username

        let body = LoginRequest(
            identifier: .init(user: user),
            password: password,
            initialDeviceDisplayName: deviceName
        )

        return try await send(.post, path: "/_matrix/client/v3/login", body: body,
                              requiresAuth: false, as: LoginResponse.self)
    }

    /// Signs out, invalidating this device's access token on the server.
    public func logOut() async throws {
        try await send(.post, path: "/_matrix/client/v3/logout")
    }

    public struct WhoAmIResponse: Decodable, Sendable {
        public let userID: String
        enum CodingKeys: String, CodingKey { case userID = "user_id" }
    }

    /// Checks that the stored token still works. Used on launch before trusting a session.
    public func whoAmI() async throws -> WhoAmIResponse {
        try await send(.get, path: "/_matrix/client/v3/account/whoami", as: WhoAmIResponse.self)
    }
}
