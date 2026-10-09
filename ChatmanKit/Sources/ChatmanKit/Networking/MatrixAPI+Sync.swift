import Foundation

extension MatrixAPI {

    /// What a homeserver sends back from `/sync`.
    public struct SyncResponse: Decodable, Sendable {
        public let nextBatch: String
        public let rooms: Rooms?

        /// Which rooms are one-to-one conversations, keyed by the other person's ID.
        ///
        /// Matrix has no separate concept of a DM: it's a normal room that both sides agreed
        /// to label. Without this, bridged Signal chats and group conversations look the same,
        /// and the conversation list can't be ordered sensibly.
        public let directRooms: [String: [String]]

        /// The rooms your push rules silence, when this batch carried the rules at all.
        ///
        /// `nil` means the rules didn't change, not that nothing is muted. They arrive whole,
        /// in the first sync and whenever any of them changes — muting on the phone reaches the
        /// watch this way, and so does muting in Element.
        public let mutedRooms: Set<String>?

        /// The names you chose for people, when this batch carried them.
        public let chosenNames: [String: String]?

        enum CodingKeys: String, CodingKey {
            case nextBatch = "next_batch"
            case rooms
            case accountData = "account_data"
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nextBatch = try container.decode(String.self, forKey: .nextBatch)
            rooms = try container.decodeIfPresent(Rooms.self, forKey: .rooms)

            let accountData = try container.decodeIfPresent(AccountData.self, forKey: .accountData)
            directRooms = accountData?.directRooms ?? [:]
            mutedRooms = accountData?.mutedRooms
            chosenNames = accountData?.chosenNames
        }

        public struct Rooms: Decodable, Sendable {
            public let join: [String: JoinedRoom]?
            public let leave: [String: LeftRoom]?
            public let invite: [String: InvitedRoom]?
        }

        public struct JoinedRoom: Decodable, Sendable {
            public let timeline: Timeline?
            public let state: State?
            public let summary: Summary?
            public let unreadNotifications: UnreadCounts?
            public let ephemeral: Ephemeral?
            public let accountData: RoomAccountData?

            enum CodingKeys: String, CodingKey {
                case timeline, state, summary, ephemeral
                case unreadNotifications = "unread_notifications"
                case accountData = "account_data"
            }
        }

        /// What the account says about one room, as opposed to what happened in it.
        ///
        /// Everything in here follows the same rule: `nil` means this batch said nothing
        /// about it, which is not the same as "no". A sync that mentions no tags must leave
        /// the tags alone rather than clearing them.
        public struct RoomAccountData: Decodable, Sendable {
            /// Tagged low priority — how Chatman, and every other Matrix client, records
            /// that a chat has been put away.
            public let isLowPriority: Bool?

            /// Tagged a favourite, which is what pinning a chat to the top writes.
            public let isFavourite: Bool?

            /// Marked unread by hand.
            public let isMarkedUnread: Bool?

            /// A name given by hand. An empty string means it was cleared.
            public let customName: String?

            enum CodingKeys: String, CodingKey { case events }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                var events = try container.nestedUnkeyedContainer(forKey: .events)

                var lowPriority: Bool?
                var favourite: Bool?
                var unread: Bool?
                var chosen: String?

                while !events.isAtEnd {
                    guard let event = try? events.decode(AccountEvent.self) else {
                        // Consumed so the loop moves on. Decoding something and throwing it
                        // away is the only way to step past an element of an unkeyed
                        // container that didn't fit.
                        _ = try? events.decode(Anything.self)
                        continue
                    }

                    switch event.type {
                    case "m.tag":
                        let tags = event.content.tags ?? [:]
                        lowPriority = tags.keys.contains("m.low_priority")
                        favourite = tags.keys.contains("m.favourite")

                    case "m.marked_unread", "com.famedly.marked_unread":
                        unread = event.content.unread

                    case "nl.chatman.name":
                        chosen = event.content.name ?? ""

                    default:
                        break
                    }
                }

                isLowPriority = lowPriority
                isFavourite = favourite
                isMarkedUnread = unread
                customName = chosen
            }
        }

        /// One entry of room account data. Every field is optional because one shape has to
        /// decode all of them: a tag event, a marked-unread flag and a chosen name.
        struct AccountEvent: Decodable, Sendable {
            let type: String
            let content: Content

            struct Content: Decodable, Sendable {
                let tags: [String: Anything]?
                let unread: Bool?
                let name: String?
            }
        }

        /// Anything at all, kept for nothing. What matters about a tag is that it is there.
        public struct Anything: Decodable, Sendable {}

        /// Things that happen in a room but aren't part of its history: who is typing, and
        /// who has read how far.
        public struct Ephemeral: Decodable, Sendable {
            /// Every read marker in this batch, flattened.
            public let receipts: [Receipt]

            /// Who is typing in this room, right now.
            ///
            /// Sent as the whole list every time it changes, not as "started" and "stopped" —
            /// so an empty list means nobody, and there is nothing to time out by hand.
            ///
            /// `nil` when this batch said nothing about typing at all, which is not the same as
            /// an empty list. The server sends this section for a room whenever anything
            /// passing happens in it — a read receipt, say — and when "nothing said" read as
            /// "nobody typing", a receipt arriving mid-sentence took the indicator away while
            /// the other person was still writing.
            public let typing: [String]?

            enum CodingKeys: String, CodingKey { case events }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                var events = try container.nestedUnkeyedContainer(forKey: .events)

                var found: [Receipt] = []
                var whoIsTyping: [String]?

                while !events.isAtEnd {
                    if let event = try? events.decode(ReceiptEvent.self) {
                        found.append(contentsOf: event.receipts)
                    } else if let event = try? events.decode(TypingEvent.self) {
                        whoIsTyping = event.userIDs
                    } else {
                        _ = try? events.decode(Ignored.self)
                    }
                }

                receipts = found
                typing = whoIsTyping
            }

            /// Anything that is neither, decoded only to step past it.
            private struct Ignored: Decodable {}
        }

        /// `m.typing` carries the full list of people currently typing.
        private struct TypingEvent: Decodable {
            let userIDs: [String]

            private struct Content: Decodable {
                let userIDs: [String]?
                enum CodingKeys: String, CodingKey { case userIDs = "user_ids" }
            }

            enum CodingKeys: String, CodingKey { case type, content }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)

                guard try container.decodeIfPresent(String.self, forKey: .type) == "m.typing"
                else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .type, in: container, debugDescription: "not a typing event"
                    )
                }

                userIDs = (try container.decode(Content.self, forKey: .content)).userIDs ?? []
            }
        }

        /// One person's read marker on one event.
        ///
        /// A receipt means "everything up to and including this", not "this one message" —
        /// which is what makes it usable for marking a whole run of messages at once.
        public struct Receipt: Sendable, Hashable {
            public let eventID: String
            public let userID: String
            public let timestamp: Date?
        }

        /// `m.receipt` nests three dictionaries deep: event, then kind, then reader. This
        /// unpacks that into a flat list, because nothing downstream cares about the shape.
        private struct ReceiptEvent: Decodable {
            let receipts: [Receipt]

            private struct Marker: Decodable {
                let ts: Int64?
            }

            enum CodingKeys: String, CodingKey { case type, content }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)

                guard try container.decodeIfPresent(String.self, forKey: .type) == "m.receipt"
                else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .type, in: container, debugDescription: "not a receipt"
                    )
                }

                let content = try container.decode(
                    [String: [String: [String: Marker]]].self, forKey: .content
                )

                var found: [Receipt] = []
                for (eventID, kinds) in content {
                    // Both the public marker and the private one mean the same thing to us.
                    for (kind, readers) in kinds where kind.hasPrefix("m.read") {
                        for (userID, marker) in readers {
                            let stamp = marker.ts.map {
                                Date(timeIntervalSince1970: Double($0) / 1000)
                            }
                            found.append(
                                Receipt(eventID: eventID, userID: userID, timestamp: stamp)
                            )
                        }
                    }
                }

                receipts = found
            }
        }

        public struct LeftRoom: Decodable, Sendable {}

        public struct InvitedRoom: Decodable, Sendable {
            public let inviteState: State?
            enum CodingKeys: String, CodingKey { case inviteState = "invite_state" }
        }

        public struct Timeline: Decodable, Sendable {
            public let events: [MatrixEvent]?
            /// Token for fetching what came before these events.
            public let previousBatch: String?
            /// True when there's a gap: events were skipped and history must be re-fetched.
            public let isLimited: Bool?

            enum CodingKeys: String, CodingKey {
                case events
                case previousBatch = "prev_batch"
                case isLimited = "limited"
            }
        }

        public struct State: Decodable, Sendable {
            public let events: [MatrixEvent]?
        }

        public struct Summary: Decodable, Sendable {
            /// A few members, used to name a room that has no name of its own.
            public let heroes: [String]?
            public let joinedMemberCount: Int?

            enum CodingKeys: String, CodingKey {
                case heroes = "m.heroes"
                case joinedMemberCount = "m.joined_member_count"
            }
        }

        public struct UnreadCounts: Decodable, Sendable {
            public let notificationCount: Int?
            public let highlightCount: Int?

            enum CodingKeys: String, CodingKey {
                case notificationCount = "notification_count"
                case highlightCount = "highlight_count"
            }
        }

        /// Account-level data. `m.direct` and the push rules are read; the rest is ignored on
        /// purpose.
        struct AccountData: Decodable {
            let directRooms: [String: [String]]?
            let mutedRooms: Set<String>?
            let chosenNames: [String: String]?

            /// One event, read for whichever of the two it is. Anything else decodes to
            /// nothing rather than failing, so one odd event can't take the rest with it.
            private struct Event: Decodable {
                let direct: [String: [String]]?
                let muted: Set<String>?
                var chosen: [String: String]? = nil

                enum CodingKeys: String, CodingKey { case type, content }

                init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    switch try? container.decodeIfPresent(String.self, forKey: .type) {
                    case "m.direct":
                        direct = try? container.decode([String: [String]].self, forKey: .content)
                        muted = nil
                    case "m.push_rules":
                        direct = nil
                        muted = (try? container.decode(PushRules.self, forKey: .content))?.mutedRooms
                    case "nl.chatman.names":
                        direct = nil
                        muted = nil
                        chosen = (try? container.decode(MatrixAPI.ChosenNames.self, forKey: .content))?.names
                    default:
                        direct = nil
                        muted = nil
                    }
                }
            }

            enum CodingKeys: String, CodingKey { case events }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let events = (try? container.decodeIfPresent([Event].self, forKey: .events)) ?? []
                directRooms = events.lazy.compactMap(\.direct).first
                mutedRooms = events.lazy.compactMap(\.muted).first
                chosenNames = events.lazy.compactMap(\.chosen).first
            }
        }

        /// The push rules, read for one thing: which rooms are silenced.
        ///
        /// A room is muted when a rule about it says not to notify. Chatman writes that as a
        /// room rule with no actions; Element writes it as an override rule named after the
        /// room. Both are read, so a chat muted anywhere is muted here.
        struct PushRules: Decodable {
            let mutedRooms: Set<String>

            private struct Ruleset: Decodable {
                let override: [Rule]?
                let room: [Rule]?
            }

            private struct Rule: Decodable {
                let ruleID: String
                let enabled: Bool?
                let notifies: Bool

                enum CodingKeys: String, CodingKey {
                    case ruleID = "rule_id"
                    case enabled, actions
                }

                /// An action is a word or an object; only the word "notify" matters here.
                private struct Action: Decodable {
                    let word: String?
                    init(from decoder: any Decoder) throws {
                        word = try? decoder.singleValueContainer().decode(String.self)
                    }
                }

                init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    ruleID = try container.decode(String.self, forKey: .ruleID)
                    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
                    let actions = (try? container.decodeIfPresent([Action].self, forKey: .actions)) ?? []
                    notifies = actions.contains { $0.word == "notify" }
                }

                var silences: Bool {
                    enabled != false && !notifies && ruleID.hasPrefix("!")
                }
            }

            enum CodingKeys: String, CodingKey { case global }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let global = try container.decodeIfPresent(Ruleset.self, forKey: .global)
                let rules = (global?.room ?? []) + (global?.override ?? [])
                mutedRooms = Set(rules.filter(\.silences).map(\.ruleID))
            }
        }
    }

    // MARK: - Sync

    /// Long polls the homeserver for new events.
    ///
    /// - Parameters:
    ///   - since: The `nextBatch` from the previous response, or `nil` for a first sync.
    ///   - timeout: How long the server holds the request open when nothing is happening.
    ///     This is the single biggest lever on battery life: each time the poll returns, a
    ///     watch on cellular has to power up its radio, and the energy cost of that is
    ///     dominated by the wake-up rather than the bytes transferred.
    ///   - filter: A JSON filter. See ``SyncFilter``.
    public func sync(
        since: String?,
        timeout: Duration = .seconds(30),
        filter: String? = nil
    ) async throws -> SyncResponse {
        var query = [URLQueryItem]()

        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        if let filter { query.append(URLQueryItem(name: "filter", value: filter)) }

        let milliseconds = Int(timeout.components.seconds * 1000)
        query.append(URLQueryItem(name: "timeout", value: String(milliseconds)))

        // Give the request longer than the poll itself, or URLSession cancels a healthy
        // connection just before the server would have answered.
        let requestTimeout = TimeInterval(timeout.components.seconds) + 20

        return try await send(.get, path: "/_matrix/client/v3/sync",
                              query: query, timeout: requestTimeout, as: SyncResponse.self)
    }
}

/// Filters that decide what a sync response contains.
///
/// Everything excluded here is something Chatman never displays. That isn't only about
/// bandwidth: any event that arrives ends the long poll, so filtering removes wake-ups as
/// well as bytes.
public enum SyncFilter {

    /// For the first sync: enough to build the conversation list, and nothing more.
    ///
    /// Fetching one event per room keeps the initial response small on an account with a lot
    /// of bridged conversations, where a full history would otherwise arrive in one go.
    ///
    /// Receipts are the exception, and they have to be here. A first sync is the only time
    /// the server sends the markers that already exist; after that it sends only new ones.
    /// Leaving them out meant a fresh install showed "Sent" forever under messages the other
    /// person had read days ago, because the one moment their read marker was on offer had
    /// been filtered away.
    public static let initial = """
    {"room":{"state":{"lazy_load_members":true},"timeline":{"limit":1},\
    "ephemeral":{"types":["m.receipt"]}},"presence":{"not_types":["*"]}}
    """

    /// For ongoing syncs on iPhone, where typing indicators are worth their cost.
    public static let phone = """
    {"room":{"state":{"lazy_load_members":true},"timeline":{"limit":30},\
    "ephemeral":{"types":["m.typing","m.receipt"]}},"presence":{"not_types":["*"]}}
    """

    /// For ongoing syncs on the watch.
    ///
    /// Typing notifications stay out: they would wake the radio on every keystroke anyone
    /// makes, to draw something the watch doesn't show. Receipts are worth the wake-up —
    /// knowing a message landed is half of why you glance at your wrist after sending one.
    public static let watch = """
    {"room":{"state":{"lazy_load_members":true},"timeline":{"limit":20},\
    "ephemeral":{"types":["m.receipt"]}},"presence":{"not_types":["*"]}}
    """
}
