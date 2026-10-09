import Foundation
import Security

/// Where the access token lives.
///
/// The token is the whole session: anyone holding it can read and send as you until it's
/// revoked. That's why it goes in the keychain and never in `UserDefaults`, which is a plain
/// file inside the app container.
public struct Credentials: Sendable, Equatable {
    public let userID: String
    public let deviceID: String
    public let accessToken: String
    public let homeserver: Homeserver

    public init(userID: String, deviceID: String, accessToken: String, homeserver: Homeserver) {
        self.userID = userID
        self.deviceID = deviceID
        self.accessToken = accessToken
        self.homeserver = homeserver
    }

    /// The part of the user ID before the colon, without the `@`.
    public var localpart: String {
        String(BridgeIdentity.localpart(of: userID))
    }
}

/// Reads and writes the signed-in session.
public enum CredentialStore {

    /// The keychain service name. Shared by the phone app, the watch app and the notification
    /// extension so all three can use the same session.
    ///
    /// Sharing across targets needs a keychain access group in the entitlements; without one
    /// each target simply keeps its own copy, which still works but means signing in twice.
    private static let service = "com.example.Chatman"
    private static let account = "session"

    public static func save(_ credentials: Credentials) {
        guard let data = try? JSONEncoder().encode(Stored(credentials)) else { return }

        // Delete first: SecItemUpdate needs a different query shape and this is simpler than
        // handling "exists" and "doesn't exist" separately.
        SecItemDelete(baseQuery() as CFDictionary)

        var query = baseQuery()
        query[kSecValueData as String] = data
        // Readable once the device has been unlocked once, so a sync after a restart in a
        // pocket still works. And kept on this device only: out of iCloud Keychain and out of
        // backups, so a restored phone signs in again rather than carrying the token along.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        SecItemAdd(query as CFDictionary, nil)
    }

    public static func load() -> Credentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }

        // Saved by a version that let the token travel with backups: written again, once,
        // under the stricter rule. Nothing else about it changes.
        if !UserDefaults.standard.bool(forKey: migratedKey), let credentials = stored.credentials {
            save(credentials)
            UserDefaults.standard.set(true, forKey: migratedKey)
        }

        return stored.credentials
    }

    private static let migratedKey = "chatman.keychainThisDeviceOnly"

    public static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// The on-disk shape. Separate from ``Credentials`` so the stored format can change
    /// without the rest of the app caring.
    private struct Stored: Codable {
        let userID: String
        let deviceID: String
        let accessToken: String
        let homeserverURL: String

        init(_ credentials: Credentials) {
            userID = credentials.userID
            deviceID = credentials.deviceID
            accessToken = credentials.accessToken
            homeserverURL = credentials.homeserver.url.absoluteString
        }

        var credentials: Credentials? {
            guard let homeserver = Homeserver(string: homeserverURL) else { return nil }
            return Credentials(userID: userID, deviceID: deviceID,
                               accessToken: accessToken, homeserver: homeserver)
        }
    }
}

/// Which device this is running on, and the behaviour that follows from it.
///
/// The phone and the watch want genuinely different things from the same code: a watch on
/// cellular pays for every radio wake-up, and shows less, so it should ask for less.
public enum DeviceProfile: Sendable {
    case phone
    case watch

    /// How long the server holds a sync request open.
    ///
    /// Long polling is what keeps this cheap. Each return costs a radio wake-up, and on
    /// cellular that dominates energy use far more than the size of the response.
    public var syncTimeout: Duration {
        switch self {
        case .phone: .seconds(30)
        // Longer on the wrist: half as many radio wake-ups an hour, and a message still
        // comes in the moment the server has it — a long poll returns as soon as there is
        // something to return.
        case .watch: .seconds(75)
        }
    }

    /// What a sync response is allowed to contain.
    public var syncFilter: String {
        switch self {
        case .phone: SyncFilter.phone
        case .watch: SyncFilter.watch
        }
    }

    /// Whether to tell other people when you're typing.
    ///
    /// Off on the watch: it would mean a request per keystroke to drive an indicator the watch
    /// never shows.
    public var sendsTypingNotifications: Bool {
        self == .phone
    }

    /// The longest a failed sync waits before trying again.
    public var maximumRetryDelay: Duration {
        switch self {
        case .phone: .seconds(30)
        case .watch: .seconds(60)
        }
    }

    /// The app ID registered with the push gateway. Phone and watch register separately so
    /// both can receive notifications.
    public var pushAppID: String {
        switch self {
        case .phone: "com.example.Chatman.ios"
        case .watch: "com.example.Chatman.watch"
        }
    }
}
