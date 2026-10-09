import Foundation
import Security

/// Who is waiting on you, shared with the watch face.
///
/// A complication runs in its own process with its own container, so it can't read the app's
/// store. The usual answer is an App Group — which Apple only grants to paid developer
/// accounts. A free account's provisioning profile does grant `keychain-access-groups` as a
/// wildcard over the whole team, so the keychain is the one place both processes can reach.
///
/// Storing a count there is unusual and it's worth being plain about why: it isn't a secret,
/// it's simply the only shared shelf available. The value is a count and a few first names,
/// written only when they change.
public enum UnreadBadge {

    /// The shared shelf. The prefix is the team ID, which is what makes it shared: both the
    /// watch app and the complication sign with it, and the profile allows anything under it.
    ///
    /// Worked out at runtime rather than written down. The team ID belongs to whoever built
    /// the app, so a copy of this source built by somebody else would otherwise be asking for
    /// a shelf they have no key to — and the number on their watch face would silently stay
    /// at zero, with nothing anywhere to say why.
    private static let accessGroup: String = {
        let suffix = (Bundle.main.bundleIdentifier ?? "com.example.Chatman")
            .components(separatedBy: ".watchkitapp").first ?? "com.example.Chatman"

        guard let prefix = teamPrefix() else { return "\(suffix).shared" }
        return "\(prefix)\(suffix).shared"
    }()

    /// Everything under the shelf is named after the app, so two builds by two people never
    /// collide even on one device.
    private static let service: String = {
        let base = (Bundle.main.bundleIdentifier ?? "com.example.Chatman")
            .components(separatedBy: ".watchkitapp").first ?? "com.example.Chatman"
        return "\(base).unread"
    }()

    private static let account = "count"

    /// The team prefix this build was signed with, asked of the keychain itself.
    ///
    /// There is no API that reports it. What there is: add an item without naming a group,
    /// and the keychain files it under the first group in the entitlement and says which —
    /// with the prefix on the front. The probe is written and removed immediately.
    private static func teamPrefix() -> String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "chatman.prefix.probe",
            kSecAttrService as String: "chatman.prefix.probe",
            kSecReturnAttributes as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        SecItemDelete(probe as CFDictionary)

        var result: CFTypeRef?
        let status = SecItemAdd(probe as CFDictionary, &result)

        defer { SecItemDelete(probe as CFDictionary) }

        guard status == errSecSuccess,
              let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              let dot = group.firstIndex(of: ".")
        else { return nil }

        return String(group[...dot])
    }

    /// What the watch face shows: how many are waiting, who, and how fresh that is.
    ///
    /// Written as a small piece of JSON. It used to be a bare number, and one of those is
    /// still read — a face drawn before the app has run once more after an update would
    /// otherwise show nothing at all.
    public struct Snapshot: Codable, Sendable, Equatable {
        /// How many conversations are waiting on you.
        public var count: Int
        /// Who, most recent first, as many as a face has room for.
        public var names: [String]
        /// When the app last heard from the server, whether or not anything changed.
        public var syncedAt: Date?

        public init(count: Int, names: [String] = [], syncedAt: Date? = nil) {
            self.count = count
            self.names = names
            self.syncedAt = syncedAt
        }

        enum CodingKeys: String, CodingKey { case count = "c", names = "n", syncedAt = "s" }

        /// Whether two snapshots draw the same face. The time only matters once it is old,
        /// and the face works that out for itself.
        func drawsLike(_ other: Snapshot) -> Bool {
            count == other.count && names == other.names
        }
    }

    /// What the complication should show.
    public static func read() -> Snapshot {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return Snapshot(count: 0) }

        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return snapshot
        }

        // The old format: a number and nothing else.
        let count = String(data: data, encoding: .utf8).flatMap { Int($0) } ?? 0
        return Snapshot(count: count)
    }

    /// Records what the face should show.
    ///
    /// The time is written at most every few minutes when nothing else changed: often enough
    /// that the face can tell fresh from stale, rarely enough that a watch syncing every half
    /// minute isn't writing to its keychain every half minute.
    ///
    /// - Returns: Whether the face would now look different, so the caller knows whether the
    ///   complication is worth reloading. Asking WidgetKit to redraw on every sync would spend
    ///   the day's budget of refreshes on a face that stayed the same.
    @discardableResult
    public static func write(_ snapshot: Snapshot) -> Bool {
        let stored = read()
        let changed = !stored.drawsLike(snapshot)

        if !changed {
            let age = snapshot.syncedAt.map { stored.syncedAt.map($0.timeIntervalSince) ?? .infinity } ?? 0
            guard age > 5 * 60 else { return false }
        }

        guard let data = try? JSONEncoder().encode(snapshot) else { return false }

        SecItemDelete(baseQuery() as CFDictionary)

        var query = baseQuery()
        query[kSecValueData as String] = data
        // The face is drawn before the watch is unlocked, so this has to be readable then.
        // Kept on this watch and out of any backup: it is nobody's business but the face's.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess && changed
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }
}
