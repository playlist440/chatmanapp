import Foundation

/// The error body Matrix servers return alongside a failing status code.
public struct MatrixErrorResponse: Sendable, Decodable, Hashable {
    /// A machine readable code such as `M_FORBIDDEN` or `M_UNKNOWN_TOKEN`.
    public let errcode: String
    /// A human readable message. Servers write these for developers, not for users.
    public let error: String?
    /// Present on rate limit responses.
    public let retryAfterMilliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case errcode
        case error
        case retryAfterMilliseconds = "retry_after_ms"
    }
}

/// Everything that can go wrong talking to a homeserver.
public enum MatrixError: Error, Sendable {
    case notSignedIn
    case invalidHomeserver
    case network(URLError)
    case decoding(String)
    case api(MatrixErrorResponse)
    case unexpectedStatus(Int)

    /// Whether the session is no longer valid and the user has to sign in again.
    ///
    /// Worth distinguishing, because it's the one failure that can't be retried: everything
    /// else is worth another attempt, this one needs the user.
    public var requiresSignIn: Bool {
        guard case .api(let response) = self else { return false }
        return response.errcode == "M_UNKNOWN_TOKEN" || response.errcode == "M_MISSING_TOKEN"
    }

    /// How long the server asked us to wait, when it asked at all.
    public var retryAfter: Duration? {
        guard case .api(let response) = self,
              let milliseconds = response.retryAfterMilliseconds
        else { return nil }
        return .milliseconds(milliseconds)
    }

    /// Whether trying again later stands a chance of working.
    public var isTransient: Bool {
        switch self {
        case .network:
            return true
        case .unexpectedStatus(let status):
            return status >= 500 || status == 429
        case .api(let response):
            return response.errcode == "M_LIMIT_EXCEEDED"
        case .notSignedIn, .invalidHomeserver, .decoding:
            return false
        }
    }

    /// Whether this failure points at the address rather than at the server.
    ///
    /// A homeserver that can't be reached at all is far more often a wrong or incomplete
    /// address than a server that's actually down. The case that matters here: a server on a
    /// port other than 443 can't announce itself through well-known delegation, because that
    /// lookup happens on 443 in the first place. All the app can do is ask.
    public var suggestsWrongAddress: Bool {
        switch self {
        case .invalidHomeserver:
            return true

        case .network(let error):
            switch error.code {
            case .cannotFindHost, .cannotConnectToHost, .timedOut, .dnsLookupFailed,
                 .secureConnectionFailed, .serverCertificateUntrusted:
                return true
            default:
                return false
            }

        case .unexpectedStatus(let status):
            // Something answered, but it isn't a homeserver.
            return status == 404

        case .notSignedIn, .decoding, .api:
            return false
        }
    }
}

extension MatrixError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return String(localized: "You're not signed in.", bundle: .module)
        case .invalidHomeserver:
            return String(localized: "That server address doesn't look right.", bundle: .module)
        case .network(let error):
            return error.localizedDescription
        case .decoding:
            return String(localized: "The server sent something this app didn't understand.", bundle: .module)
        case .api(let response) where response.errcode == "M_FORBIDDEN":
            return String(localized: "The server refused. Check your username and password.", bundle: .module)
        case .api(let response):
            return response.error ?? response.errcode
        case .unexpectedStatus(let status):
            return "The server replied with an error (\(status))."
        }
    }
}
