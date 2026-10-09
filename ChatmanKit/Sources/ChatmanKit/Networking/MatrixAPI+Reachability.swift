import Foundation

extension MatrixAPI {

    /// What a single quick attempt to reach the homeserver found.
    ///
    /// Deliberately not the sync path. Sync holds a request open for half a minute and waits
    /// for the radio to come up, which is right for keeping messages flowing and useless for
    /// answering "is this thing reachable at all" — the answer arrives long after anyone
    /// stopped watching. This asks the smallest question the server can answer, once, and
    /// gives up quickly.
    public enum Reachability: Sendable, Equatable {
        case reachable
        case noNetwork
        case timedOut
        case nameNotFound
        case refused
        case tlsFailed
        case answeredBadly(Int)
        case other(String)

        /// One short line, written to be read on a watch by someone standing outside.
        public var summary: String {
            switch self {
            case .reachable: String(localized: "Server reachable", bundle: .module)
            case .noNetwork: String(localized: "No internet on this device", bundle: .module)
            case .timedOut: String(localized: "Server didn't answer", bundle: .module)
            case .nameNotFound: String(localized: "Server name not found", bundle: .module)
            case .refused: String(localized: "Connection refused", bundle: .module)
            case .tlsFailed: String(localized: "Secure connection failed", bundle: .module)
            case .answeredBadly(let status): "Server replied \(status)"
            case .other(let reason): reason
            }
        }
    }

    /// Asks the homeserver which API versions it speaks, and reports what happened.
    ///
    /// Needs no access token, so it separates "the network can't get there" from "the server
    /// doesn't like this session" — two failures that look identical from a stuck sync.
    public func reachability(timeout: TimeInterval = 12) async -> Reachability {
        guard let url = homeserver.endpoint("/_matrix/client/versions") else {
            return .other(String(localized: "Server address isn't valid", bundle: .module))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Its own connection, set to fail rather than wait: waiting is what the sync does,
        // and a probe that waits answers nothing.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(status) ? .reachable : .answeredBadly(status)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff,
                 .dataNotAllowed:
                return .noNetwork
            case .timedOut:
                return .timedOut
            case .cannotFindHost, .dnsLookupFailed:
                return .nameNotFound
            case .cannotConnectToHost:
                return .refused
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot:
                return .tlsFailed
            default:
                return .other(error.localizedDescription)
            }
        } catch {
            return .other(error.localizedDescription)
        }
    }
}
