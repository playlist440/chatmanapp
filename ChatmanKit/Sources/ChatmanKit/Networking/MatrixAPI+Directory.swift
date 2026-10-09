import Foundation

extension MatrixAPI {

    // MARK: - Finding people

    struct UserDirectoryRequest: Encodable {
        let searchTerm: String
        let limit: Int

        enum CodingKeys: String, CodingKey {
            case searchTerm = "search_term"
            case limit
        }
    }

    struct UserDirectoryResponse: Decodable {
        let results: [DirectoryUser]
    }

    /// Someone who can be messaged, as returned by the homeserver's user directory.
    public struct DirectoryUser: Decodable, Sendable, Hashable, Identifiable {
        public let userID: String
        public let displayName: String?
        public let avatarURL: String?

        public var id: String { userID }

        enum CodingKeys: String, CodingKey {
            case userID = "user_id"
            case displayName = "display_name"
            case avatarURL = "avatar_url"
        }
    }

    /// Searches the homeserver for people whose name or ID matches `term`.
    ///
    /// This is what makes starting a conversation feel like a phone rather than a terminal.
    /// It only returns bridged contacts when the homeserver has `search_all_users` enabled —
    /// without it Synapse restricts results to people you already share a room with, which is
    /// exactly the people you don't need to look up.
    public func searchPeople(matching term: String, limit: Int = 20) async throws -> [DirectoryUser] {
        let body = UserDirectoryRequest(searchTerm: term, limit: limit)
        let response: UserDirectoryResponse = try await send(
            .post, path: "/_matrix/client/v3/user_directory/search", body: body
        )
        return response.results
    }

    // MARK: - Profiles

    public struct Profile: Decodable, Sendable {
        public let displayName: String?
        public let avatarURL: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "displayname"
            case avatarURL = "avatar_url"
        }
    }

    /// Looks up someone's display name and avatar.
    public func profile(of userID: String) async throws -> Profile {
        let encoded = userID.addingPercentEncoding(withAllowedCharacters: .matrixPathSegment) ?? userID
        return try await send(.get, path: "/_matrix/client/v3/profile/\(encoded)", as: Profile.self)
    }
}

extension CharacterSet {
    /// Characters that may appear unescaped in a path segment.
    ///
    /// Matrix identifiers contain `@`, `!`, `#`, `:` and `$`, all of which have meaning in a
    /// URL. Percent-encoding them is not optional: room IDs break routing without it.
    static let matrixPathSegment: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()
}
