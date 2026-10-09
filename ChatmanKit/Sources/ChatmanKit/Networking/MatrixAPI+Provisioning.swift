import Foundation

// MARK: - Logging into a bridged network

/// Mautrix bridges expose their login process over HTTP as well as through their chat bot.
///
/// This is what lets Chatman show a QR code instead of a conversation with something called
/// `signalbot`. The bridge returns each step as data — "display this QR, then wait" — so the
/// app can render it as a screen rather than asking someone to type a command at a robot.
///
/// It runs on the same host and the same access token as everything else, so there's no second
/// secret to store and nothing extra to configure in the app.
extension MatrixAPI {

    /// Where a bridge's own interface lives.
    ///
    /// Each bridge serves its API at the same path, so with more than one they have to be
    /// told apart before the request leaves the app. The reverse proxy strips this prefix
    /// again, which keeps every bridge running its stock configuration.
    ///
    /// The shape of that prefix is a convention, not a standard — it's how the stack that
    /// comes with Chatman routes them, and somebody else's server may well do it differently.
    /// So it's a setting, defaulting to what the included stack does. See
    /// ``bridgePathTemplate``.
    private static func provisioningBase(_ network: ChatNetwork) -> String {
        let template = UserDefaults.standard.string(forKey: bridgePathKey) ?? defaultBridgePath
        let path = template.replacingOccurrences(of: "{network}", with: network.rawValue)

        // Escaped a piece at a time, because unlike every other path in this app this one is
        // typed by hand. It used to go into the address exactly as typed, and a space, a `%`
        // or a mistyped `{Network}` was enough to crash the app — on every launch, since the
        // setting is saved with each keystroke. Escaped, a typo is just an address where no
        // bridge answers, which the connect screen already knows how to say. Empty pieces are
        // dropped, which also takes care of a trailing slash or a missing leading one.
        let pieces = path.split(separator: "/").map { String($0).pathEscaped }
        return "/" + (pieces + ["_matrix", "provision", "v3"]).joined(separator: "/")
    }

    /// Where the app looks for the bridges, with `{network}` standing in for each one.
    public static let defaultBridgePath = "/bridge/{network}"

    static let bridgePathKey = "chatman.bridgePath"

    /// The path in use, so a settings screen can show and change it.
    public static var bridgePathTemplate: String {
        get { UserDefaults.standard.string(forKey: bridgePathKey) ?? defaultBridgePath }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty || cleaned == defaultBridgePath {
                UserDefaults.standard.removeObject(forKey: bridgePathKey)
            } else {
                UserDefaults.standard.set(cleaned, forKey: bridgePathKey)
            }
        }
    }

    /// A way of logging into the network behind a bridge.
    public struct BridgeLoginFlow: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let description: String
    }

    /// One step of a bridge login.
    public struct BridgeLoginStep: Decodable, Sendable {

        /// What the bridge is asking the client to do.
        public enum Kind: Sendable, Equatable {
            case displayAndWait
            case userInput
            case cookies
            case clientHTTP
            case webauthn
            case complete
            /// A step this version of Chatman doesn't know how to present.
            case unsupported(String)

            init(_ raw: String) {
                switch raw {
                case "display_and_wait": self = .displayAndWait
                case "user_input": self = .userInput
                case "cookies": self = .cookies
                case "client_http": self = .clientHTTP
                case "webauthn": self = .webauthn
                case "complete": self = .complete
                default: self = .unsupported(raw)
                }
            }
        }

        /// Something to put on screen while the bridge waits for the other side.
        public struct DisplayAndWait: Decodable, Sendable {

            public enum Presentation: String, Decodable, Sendable {
                case qr, emoji, code, nothing
            }

            public let type: Presentation
            /// The raw contents for the code — for Signal, what the QR must encode.
            public let data: String?
            /// A ready-made image. Present for some networks; Signal sends `data`.
            public let imageURL: String?
            public let canCancel: Bool?

            enum CodingKeys: String, CodingKey {
                case type, data
                case imageURL = "image_url"
                case canCancel = "can_cancel"
            }
        }

        /// A form the bridge wants filled in.
        ///
        /// Everything about it comes from the bridge: which fields, what to call them, what
        /// they should look like. That's what makes one screen work for a phone number, an
        /// app password and an IRC server address without the app knowing which is which.
        public struct UserInput: Decodable, Sendable {

            public struct Field: Decodable, Sendable, Identifiable, Hashable {

                public enum Kind: String, Decodable, Sendable {
                    case username, phoneNumber = "phone_number", email, password
                    case twoFactorCode = "2fa_code", token, url, domain, select
                }

                public let id: String
                public let type: Kind
                public let name: String
                public let description: String?
                public let defaultValue: String?
                public let pattern: String?
                public let options: [String]?

                enum CodingKeys: String, CodingKey {
                    case id, type, name, description, pattern, options
                    case defaultValue = "default_value"
                }

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    id = try container.decode(String.self, forKey: .id)
                    name = try container.decode(String.self, forKey: .name)
                    // An unfamiliar field is still a field: showing it as plain text is
                    // better than refusing the whole login over one word.
                    type = (try? container.decode(Kind.self, forKey: .type)) ?? .username
                    description = try container.decodeIfPresent(String.self, forKey: .description)
                    defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
                    pattern = try container.decodeIfPresent(String.self, forKey: .pattern)
                    options = try container.decodeIfPresent([String].self, forKey: .options)
                }
            }

            public let fields: [Field]
            public let canCancel: Bool?

            enum CodingKeys: String, CodingKey {
                case fields
                case canCancel = "can_cancel"
            }
        }

        /// A sign-in that happens on the network's own website.
        ///
        /// Meta, X and LinkedIn have no code to scan and no password a third party may hold.
        /// What they have is their own login page, and what the bridge needs afterwards is
        /// the cookies that page leaves behind. Chatman shows the page and keeps nothing but
        /// the named values.
        public struct Cookies: Decodable, Sendable {

            public struct Field: Decodable, Sendable, Hashable {
                public enum Source: String, Decodable, Sendable {
                    case cookie, localStorage = "local_storage"
                    case requestHeader = "request_header", requestBody = "request_body"
                    case special
                }

                public let type: Source
                public let name: String
                public let cookieDomain: String?

                enum CodingKeys: String, CodingKey {
                    case type, name
                    case cookieDomain = "cookie_domain"
                }

                public init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    name = try container.decode(String.self, forKey: .name)
                    type = (try? container.decode(Source.self, forKey: .type)) ?? .cookie
                    cookieDomain = try container.decodeIfPresent(String.self, forKey: .cookieDomain)
                }
            }

            public let url: String
            public let userAgent: String?
            public let waitForURLPattern: String?
            public let extractJS: String?
            public let hidden: Bool?
            public let fields: [Field]

            enum CodingKeys: String, CodingKey {
                case url, fields, hidden
                case userAgent = "user_agent"
                case waitForURLPattern = "wait_for_url_pattern"
                case extractJS = "extract_js"
            }
        }

        public let loginID: String
        public let kind: Kind
        public let stepID: String
        public let instructions: String?
        public let displayAndWait: DisplayAndWait?
        public let userInput: UserInput?
        public let cookies: Cookies?

        enum CodingKeys: String, CodingKey {
            case loginID = "login_id"
            case type
            case stepID = "step_id"
            case instructions
            case displayAndWait = "display_and_wait"
            case userInput = "user_input"
            case cookies
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            loginID = try container.decodeIfPresent(String.self, forKey: .loginID) ?? ""
            kind = Kind(try container.decode(String.self, forKey: .type))
            stepID = try container.decodeIfPresent(String.self, forKey: .stepID) ?? ""
            instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
            displayAndWait = try container.decodeIfPresent(
                DisplayAndWait.self, forKey: .displayAndWait
            )
            userInput = try container.decodeIfPresent(UserInput.self, forKey: .userInput)
            cookies = try container.decodeIfPresent(Cookies.self, forKey: .cookies)
        }
    }

    private struct FlowsResponse: Decodable {
        let flows: [BridgeLoginFlow]
    }

    /// Who the request is on behalf of.
    ///
    /// The bridge needs this alongside the token, and takes it from the query string rather
    /// than working it out from the token itself. It then asks the homeserver who the token
    /// belongs to and refuses the request unless the two agree — so this identifies, it
    /// doesn't authorise. Leaving it out is refused with a message about an invalid token,
    /// which points at the wrong thing entirely.
    private static func caller(_ userID: String) -> [URLQueryItem] {
        [URLQueryItem(name: "user_id", value: userID)]
    }

    /// What the bridge knows about you.
    ///
    /// Two uses. It names the rooms the bridge keeps for its own purposes, so they can stay
    /// out of the chat list — guessing those from the members would be wrong the moment a
    /// bridge puts its bot in a real conversation. And it reports whether the connection to
    /// the network is actually alive, which is the difference between a quiet app and a
    /// broken one.
    public struct BridgeWhoami: Decodable, Sendable {

        public struct Login: Decodable, Sendable {

            public struct State: Decodable, Sendable {
                public let stateEvent: String
                public let message: String?

                init(stateEvent: String, message: String?) {
                    self.stateEvent = stateEvent
                    self.message = message
                }

                enum CodingKeys: String, CodingKey {
                    case stateEvent = "state_event"
                    case message
                }
            }

            public let id: String
            /// How the network names this account. For Signal, your phone number.
            public let name: String?
            public let state: State
            /// A room the bridge creates to group this account's chats. Not a conversation.
            public let spaceRoom: String?

            enum CodingKeys: String, CodingKey {
                case id, name, state
                case spaceRoom = "space_room"
            }

            /// Read leniently: a login the bridge hasn't reported on yet comes without a
            /// state, and that is a login in an unknown state — not an answer that can't be
            /// read. See `logins` below for why that difference matters.
            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                name = try container.decodeIfPresent(String.self, forKey: .name)
                state = try container.decodeIfPresent(State.self, forKey: .state)
                    ?? State(stateEvent: "UNKNOWN", message: nil)
                spaceRoom = try container.decodeIfPresent(String.self, forKey: .spaceRoom)
            }
        }

        public let managementRoom: String?
        public let logins: [Login]

        enum CodingKeys: String, CodingKey {
            case managementRoom = "management_room"
            case logins
        }

        /// Read leniently. A bridge written in Go sends an empty list as `null`, and an answer
        /// that couldn't be read used to count as no bridge at all — so a WhatsApp that had
        /// just lost its login didn't say "disconnected", it vanished from the settings and
        /// said nothing.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            managementRoom = try container.decodeIfPresent(String.self, forKey: .managementRoom)
            logins = try container.decodeIfPresent([Login].self, forKey: .logins) ?? []
        }

        /// Rooms that exist for the bridge's own bookkeeping rather than for chatting.
        public var housekeepingRooms: [String] {
            ([managementRoom] + logins.map(\.spaceRoom)).compactMap { room in
                guard let room, !room.isEmpty else { return nil }
                return room
            }
        }
    }

    public func bridgeWhoami(as userID: String, on network: ChatNetwork) async throws -> BridgeWhoami {
        try await send(
            .get, path: "\(Self.provisioningBase(network))/whoami", query: Self.caller(userID)
        )
    }

    /// Someone the network knows about, whether or not you've ever chatted.
    public struct BridgeContact: Decodable, Sendable {
        /// The network's own ID for this person.
        public let id: String
        public let name: String?
        public let avatarURL: String?
        /// URIs like `tel:+31600000000` — how the network identifies them.
        public let identifiers: [String]?
        /// The Matrix account the bridge uses to represent them.
        public let mxid: String?
        /// The room for a private chat with them, once one exists.
        public let dmRoomID: String?

        enum CodingKeys: String, CodingKey {
            case id, name, identifiers, mxid
            case avatarURL = "avatar_url"
            case dmRoomID = "dm_room_mxid"
        }

        public var phoneNumbers: [String] {
            (identifiers ?? [])
                .filter { $0.hasPrefix("tel:") }
                .map { String($0.dropFirst("tel:".count)) }
        }
    }

    private struct ContactsResponse: Decodable {
        let contacts: [BridgeContact]
    }

    /// Everyone the bridge knows, with the identifiers the network uses for them.
    ///
    /// This is what makes matching against a phone's address book possible: a bridged account
    /// is named `@signal_<uuid>`, which says nothing about who it is. The phone number does.
    public func bridgeContacts(as userID: String, on network: ChatNetwork) async throws -> [BridgeContact] {
        let response: ContactsResponse = try await send(
            .get, path: "\(Self.provisioningBase(network))/contacts", query: Self.caller(userID)
        )
        return response.contacts
    }

    /// Opens a private chat with someone on the remote network.
    ///
    /// Goes through the bridge rather than creating a Matrix room directly, because only the
    /// bridge knows how to tie that room to the right person on the other side. Creating the
    /// room here would produce an empty room that never reaches anyone.
    public func createBridgeDM(
        with identifier: String, as userID: String, on network: ChatNetwork
    ) async throws -> BridgeContact {
        try await send(
            .post,
            path: "\(Self.provisioningBase(network))/create_dm/\(identifier.pathEscaped)",
            query: Self.caller(userID)
        )
    }

    struct GroupCreateRequest: Encodable {
        struct Name: Encodable { let name: String }

        let name: Name
        let participants: [String]
    }

    /// A group that now exists on the remote network.
    public struct CreatedGroup: Decodable, Sendable {
        public let id: String
        /// The Matrix room the bridge made for it.
        public let mxid: String
    }

    /// Creates a group on the network itself.
    ///
    /// Goes through the bridge rather than creating a Matrix room: a room made here would be
    /// a room on your own server that nobody on Signal or WhatsApp can see. Only the bridge
    /// can make a group that exists on the other side.
    public func createBridgeGroup(
        named name: String,
        with participants: [String],
        as userID: String,
        on network: ChatNetwork,
        type: String = "group"
    ) async throws -> CreatedGroup {
        try await send(
            .post,
            path: "\(Self.provisioningBase(network))/create_group/\(type.pathEscaped)",
            query: Self.caller(userID),
            body: GroupCreateRequest(name: .init(name: name), participants: participants)
        )
    }

    /// The ways this bridge can be logged into.
    public func bridgeLoginFlows(as userID: String, on network: ChatNetwork) async throws -> [BridgeLoginFlow] {
        let response: FlowsResponse = try await send(
            .get, path: "\(Self.provisioningBase(network))/login/flows", query: Self.caller(userID)
        )
        return response.flows
    }

    /// Begins a login and returns its first step.
    public func startBridgeLogin(
        flow: String, as userID: String, on network: ChatNetwork
    ) async throws -> BridgeLoginStep {
        try await send(
            .post,
            path: "\(Self.provisioningBase(network))/login/start/\(flow.pathEscaped)",
            query: Self.caller(userID)
        )
    }

    /// Tells the bridge the code is on screen, and waits for whatever happens next.
    ///
    /// This request deliberately hangs: it only comes back once the code has been scanned, so
    /// it needs a timeout measured in minutes rather than seconds. A timeout here means the
    /// code went stale, not that anything is broken.
    public func awaitBridgeLoginStep(
        loginID: String,
        stepID: String,
        as userID: String,
        on network: ChatNetwork,
        timeout: TimeInterval = 240
    ) async throws -> BridgeLoginStep {
        try await send(
            .post,
            path: "\(Self.provisioningBase(network))/login/step/\(loginID.pathEscaped)/\(stepID.pathEscaped)/display_and_wait",
            query: Self.caller(userID),
            timeout: timeout
        )
    }

    /// Hands the bridge what someone typed, and returns whatever it wants next.
    ///
    /// The keys are the field IDs the bridge asked for, which is why nothing here knows what
    /// a phone number is: the bridge named the fields, the app rendered them, and the answers
    /// go back under the same names.
    public func submitBridgeLoginInput(
        loginID: String,
        stepID: String,
        values: [String: String],
        as userID: String,
        on network: ChatNetwork
    ) async throws -> BridgeLoginStep {
        try await send(
            .post,
            path: "\(Self.provisioningBase(network))/login/step/\(loginID.pathEscaped)/\(stepID.pathEscaped)/user_input",
            query: Self.caller(userID),
            body: values,
            timeout: 120
        )
    }

    /// Hands the bridge the values collected from the network's own login page.
    public func submitBridgeLoginCookies(
        loginID: String,
        stepID: String,
        values: [String: String],
        as userID: String,
        on network: ChatNetwork
    ) async throws -> BridgeLoginStep {
        try await send(
            .post,
            path: "\(Self.provisioningBase(network))/login/step/\(loginID.pathEscaped)/\(stepID.pathEscaped)/cookies",
            query: Self.caller(userID),
            body: values,
            timeout: 120
        )
    }

    /// Abandons a login that was started but never finished.
    public func cancelBridgeLogin(
        loginID: String, as userID: String, on network: ChatNetwork
    ) async throws {
        try await send(
            .post,
            path: "\(Self.provisioningBase(network))/login/cancel/\(loginID.pathEscaped)",
            query: Self.caller(userID)
        )
    }
}
