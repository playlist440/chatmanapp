import Foundation

/// How much of a message a notification shows.
///
/// This is purely a local display choice, and that's worth being clear about. Chatman always
/// registers for `event_id_only` notifications, so what Apple's servers carry is never more
/// than "something happened in room X" — no sender, no text, ever. The message itself is
/// fetched straight from your own homeserver by the notification extension on the device.
///
/// The trade-off is not privacy but reliability: when the phone can't reach your server at
/// the moment a notification arrives, there's nothing to show but a placeholder.
public enum NotificationDetail: String, Sendable, Codable, CaseIterable {
    /// "Alex: see you at eight"
    case senderAndMessage
    /// "Message from Alex"
    case senderOnly
    /// "New message"
    case nothing

    public var title: String {
        switch self {
        case .senderAndMessage: return "Name and message"
        case .senderOnly: return "Name only"
        case .nothing: return "No details"
        }
    }

    public var explanation: String {
        switch self {
        case .senderAndMessage:
            return "Show who wrote and what they said."
        case .senderOnly:
            return "Show who wrote, but not what they said."
        case .nothing:
            return "Only show that something arrived."
        }
    }
}

extension MatrixAPI {

    struct PusherRequest: Encodable {
        struct Data: Encodable {
            let url: String
            /// Tells the homeserver to send the push gateway an event ID and nothing else.
            let format = "event_id_only"
        }

        let appID: String
        let appDisplayName: String
        let deviceDisplayName: String
        let pushkey: String
        let kind: String?
        let lang: String
        let data: Data
        /// `false` replaces any existing pusher for this key, so re-registering can't pile up
        /// duplicates and cause double notifications.
        let append = false

        enum CodingKeys: String, CodingKey {
            case appID = "app_id"
            case appDisplayName = "app_display_name"
            case deviceDisplayName = "device_display_name"
            case pushkey, kind, lang, data, append
        }

        /// Written out by hand for one field: `kind` has to be there even when it is empty.
        ///
        /// The spec deletes a pusher when `kind` is `null` — present, and null. The encoder
        /// Swift writes on its own leaves an empty optional out altogether, so a request to
        /// delete arrived with no `kind` at all, and could never delete anything.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(appID, forKey: .appID)
            try container.encode(appDisplayName, forKey: .appDisplayName)
            try container.encode(deviceDisplayName, forKey: .deviceDisplayName)
            try container.encode(pushkey, forKey: .pushkey)
            try container.encode(kind, forKey: .kind)
            try container.encode(lang, forKey: .lang)
            try container.encode(data, forKey: .data)
            try container.encode(append, forKey: .append)
        }
    }

    /// Registers this device for push notifications.
    ///
    /// - Parameters:
    ///   - deviceToken: The APNs token, as lowercase hex.
    ///   - appID: Must match the app ID configured in Sygnal, and differs between the phone
    ///     and watch builds so both can be registered at once.
    ///   - gatewayURL: Your Sygnal instance, e.g. `https://matrix.example.com/_matrix/push/v1/notify`.
    public func registerPusher(
        deviceToken: String,
        appID: String,
        appDisplayName: String = "Chatman",
        deviceDisplayName: String,
        gatewayURL: String
    ) async throws {
        let body = PusherRequest(
            appID: appID,
            appDisplayName: appDisplayName,
            deviceDisplayName: deviceDisplayName,
            pushkey: deviceToken,
            kind: "http",
            lang: "en",
            data: .init(url: gatewayURL)
        )

        try await send(.post, path: "/_matrix/client/v3/pushers/set", body: body)
    }

    /// Stops notifications for this device, without signing out.
    public func removePusher(deviceToken: String, appID: String) async throws {
        let body = PusherRequest(
            appID: appID,
            appDisplayName: "Chatman",
            deviceDisplayName: "",
            pushkey: deviceToken,
            kind: nil,      // a null kind is how the spec says "delete this pusher"
            lang: "en",
            data: .init(url: "")
        )

        try await send(.post, path: "/_matrix/client/v3/pushers/set", body: body)
    }

    /// An empty set of actions, which is how the spec spells "notify me about nothing".
    private struct MuteRule: Encodable {
        let actions: [String] = []
    }

    /// Silences a room on the server, for every device and every client.
    ///
    /// A rule set here outlives this app: it applies to notifications the homeserver pushes
    /// while Chatman isn't even running, which is the only way to make hiding something
    /// actually mean hidden. Doing it locally would leave the phone buzzing about a room
    /// nobody can see.
    public func muteRoom(_ roomID: String) async throws {
        try await send(
            .put,
            path: "/_matrix/client/v3/pushrules/global/room/\(roomID.pathEscaped)",
            body: MuteRule()
        )
    }

    /// Removes that rule again. Missing rules are not an error: the server answers 404 for a
    /// room that was never muted, and the end state is the one asked for either way.
    public func unmuteRoom(_ roomID: String) async throws {
        try await send(
            .delete,
            path: "/_matrix/client/v3/pushrules/global/room/\(roomID.pathEscaped)"
        )
    }

    /// Puts a room in the "low priority" drawer, for every client on the account.
    ///
    /// Archiving used to be a flag in this device's own database, which meant the phone knew
    /// about it and the watch never could. Matrix already has a place for exactly this — a
    /// room tag, kept with the account and handed to every client in `/sync` — so that is
    /// where it lives now. `m.low_priority` is the tag other Matrix clients use for the same
    /// idea, so a chat put away here is put away there too.
    public func tagRoom(_ roomID: String, as tag: String, for userID: String) async throws {
        try await send(
            .put,
            path: "/_matrix/client/v3/user/\(userID.pathEscaped)"
                + "/rooms/\(roomID.pathEscaped)/tags/\(tag.pathEscaped)",
            body: RoomTag()
        )
    }

    /// Takes the tag off again. A room that never had it answers 404, and the end state is
    /// the one asked for either way.
    public func untagRoom(_ roomID: String, as tag: String, for userID: String) async throws {
        try await send(
            .delete,
            path: "/_matrix/client/v3/user/\(userID.pathEscaped)"
                + "/rooms/\(roomID.pathEscaped)/tags/\(tag.pathEscaped)"
        )
    }

    /// The body of a tag. The order is what clients sort by within a tag; nothing here reads
    /// it, and leaving it out entirely makes some servers unhappy.
    struct RoomTag: Encodable {
        let order: Double = 0.5
    }

    /// Writes one piece of the account's own notes about a room.
    ///
    /// Room account data is where Matrix keeps what *you* think about a room as opposed to
    /// what happened in it, and the server hands it to every client in `/sync`. That is the
    /// whole reason for using it: a note kept in this device's database is a note the watch
    /// can never read.
    public func setRoomAccountData(
        _ body: some Encodable, type: String, room roomID: String, for userID: String
    ) async throws {
        try await send(
            .put,
            path: "/_matrix/client/v3/user/\(userID.pathEscaped)"
                + "/rooms/\(roomID.pathEscaped)/account_data/\(type.pathEscaped)",
            body: body
        )
    }

    /// Writes one piece of the account's own notes, not tied to a room.
    public func setAccountData(
        _ body: some Encodable, type: String, for userID: String
    ) async throws {
        try await send(
            .put,
            path: "/_matrix/client/v3/user/\(userID.pathEscaped)/account_data/\(type.pathEscaped)",
            body: body
        )
    }

    /// Names you chose for people, by the account they write under. Chatman's own type.
    public struct ChosenNames: Codable, Sendable {
        public let names: [String: String]
        public init(names: [String: String]) { self.names = names }
    }

    /// Whether a room has been marked unread by hand. The type other Matrix clients agreed
    /// on for this, so a chat marked here shows the same way in Element.
    public struct MarkedUnread: Encodable {
        public let unread: Bool
        public init(unread: Bool) { self.unread = unread }
    }

    /// A name somebody gave a conversation themselves. No standard exists for this, so it
    /// lives under Chatman's own type — which other clients will ignore, as they should.
    public struct ChosenName: Encodable {
        /// Empty means "put it back the way it was", because the absence of the event means
        /// "this batch said nothing about it" and the two have to stay different.
        public let name: String
        public init(name: String) { self.name = name }
    }

    public struct NotificationContext: Sendable {
        public let roomID: String
        public let senderName: String?
        public let roomName: String?
        public let body: String?
    }

    /// Fetches the content behind a notification.
    ///
    /// Called by the notification extension, which has a few seconds and very little memory,
    /// so this asks for exactly one event and nothing else.
    public func notificationContext(
        eventID: String,
        roomID: String
    ) async throws -> NotificationContext {
        let path = "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/event/\(eventID.pathEscaped)"
        let event: MatrixEvent = try await send(.get, path: path, as: MatrixEvent.self)

        let profile = try? await profile(of: event.sender)

        return NotificationContext(
            roomID: roomID,
            senderName: profile?.displayName ?? event.sender,
            roomName: nil,
            body: event.content.isMessage ? event.content.preview : nil
        )
    }
}
