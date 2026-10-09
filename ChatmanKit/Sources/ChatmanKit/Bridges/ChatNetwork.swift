import Foundation

/// The chat service a conversation actually lives on.
///
/// This is the idea Chatman is built around. A general Matrix client shows you rooms and user
/// IDs; you're left to work out that `@signal_a1b2c3:example.com` is your sister on Signal.
/// Bridges name their accounts after themselves, so that's recoverable — and once recovered,
/// the app can look like a messaging app instead of a directory listing.
public enum ChatNetwork: String, Sendable, Codable, CaseIterable, Hashable {
    case signal
    case whatsapp
    case telegram
    case discord
    case slack
    /// Facebook Messenger and Instagram are one bridge run twice, in two modes.
    case facebook
    case instagram
    /// Google Messages: RCS and SMS, through an Android phone that stays paired.
    case gmessages
    case gvoice
    case twitter
    case linkedin
    case bluesky
    case irc
    case zulip
    /// A native Matrix user, not bridged from anywhere.
    case matrix

    public var displayName: String {
        switch self {
        case .signal: "Signal"
        case .whatsapp: "WhatsApp"
        case .telegram: "Telegram"
        case .discord: "Discord"
        case .slack: "Slack"
        case .facebook: "Messenger"
        case .instagram: "Instagram"
        case .gmessages: "Google Messages"
        case .gvoice: "Google Voice"
        case .twitter: "X"
        case .linkedin: "LinkedIn"
        case .bluesky: "Bluesky"
        case .irc: "IRC"
        case .zulip: "Zulip"
        case .matrix: "Matrix"
        }
    }

    /// What the badge says when the service's own icon isn't in the asset catalogue.
    ///
    /// Spelled out rather than taken from the first letter, because half of these share one:
    /// Signal and Slack, Telegram and X's old name, both Google services, Instagram and IRC.
    /// A badge that can't be told apart is worse than no badge.
    public var initials: String {
        switch self {
        case .signal: "Si"
        case .whatsapp: "W"
        case .telegram: "Tg"
        case .discord: "D"
        case .slack: "Sl"
        case .facebook: "M"
        case .instagram: "Ig"
        case .gmessages: "GM"
        case .gvoice: "GV"
        case .twitter: "X"
        case .linkedin: "in"
        case .bluesky: "B"
        case .irc: "IRC"
        case .zulip: "Z"
        case .matrix: "M"
        }
    }

    /// The prefix mautrix gives the accounts it creates, e.g. `@signal_a1b2c3:example.com`.
    ///
    /// Bridges can be configured to use something else, which is why this is matched rather
    /// than assumed: an unrecognised prefix falls back to ``matrix`` instead of guessing.
    /// The stack that comes with Chatman sets each bridge to exactly these.
    var ghostPrefix: String? {
        switch self {
        case .matrix: nil
        default: "\(rawValue)_"
        }
    }

    /// The bridge's own control account, which you talk to for logging in and out.
    var botLocalpart: String? {
        switch self {
        case .matrix: nil
        default: "\(rawValue)bot"
        }
    }

    /// The colour the service is known by, as its own brand uses it.
    ///
    /// Deliberately not the system palette: people recognise these colours from the apps they
    /// already use, and a badge that's roughly the right blue reads as wrong rather than as
    /// neutral. The badge pairs this with a letter, so nothing depends on telling them apart.
    public var brandColour: (red: Double, green: Double, blue: Double) {
        switch self {
        case .signal:    (0.23, 0.46, 0.94)   // #3A76F0
        case .whatsapp:  (0.15, 0.83, 0.40)   // #25D366
        case .telegram:  (0.16, 0.66, 0.92)   // #29A9EB
        case .discord:   (0.35, 0.40, 0.95)   // #5865F2
        case .slack:     (0.29, 0.08, 0.29)   // #4A154B
        case .facebook:  (0.00, 0.52, 1.00)   // #0084FF
        case .instagram: (0.88, 0.19, 0.42)   // #E1306C
        case .gmessages: (0.10, 0.45, 0.91)   // #1A73E8
        case .gvoice:    (0.20, 0.66, 0.33)   // #34A853
        case .twitter:   (0.09, 0.09, 0.10)   // #17181A
        case .linkedin:  (0.04, 0.40, 0.76)   // #0A66C2
        case .bluesky:   (0.00, 0.52, 1.00)   // #0085FF
        case .irc:       (0.35, 0.38, 0.42)   // #59616B
        case .zulip:     (0.15, 0.55, 0.50)   // #268C80
        case .matrix:    (0.45, 0.45, 0.47)
        }
    }

    /// What to tell someone before the bridge starts talking.
    ///
    /// Every network asks for something different — a code to scan, a phone number, a
    /// password made for the purpose — and the bridge's own instructions arrive too late,
    /// after the screen has already opened. This is the sentence that goes above them.
    public var connectionHint: String? {
        switch self {
        case .signal, .whatsapp:
            "Open \(displayName) on your phone, go to Settings → Linked devices, and scan this."
        case .telegram:
            "Sign in with the phone number your Telegram account uses, or scan the code from Telegram → Settings → Devices."
        case .discord:
            "Scan the code with the Discord app, or paste an account token if you'd rather."
        case .slack:
            "Signing in happens on Slack's own page. Chatman only keeps what Slack hands back."
        case .facebook, .instagram:
            "Signing in happens on Meta's own page. Chatman only keeps what it hands back."
        case .gmessages:
            "Pair with Google Messages on Android, the same way its web version does — the phone has to stay online."
        case .gvoice, .twitter, .linkedin:
            "Signing in happens on \(displayName)'s own page. Chatman only keeps what it hands back."
        case .bluesky:
            "Use an app password, not your account password. Make one in Bluesky under Settings → App passwords."
        case .irc:
            "You'll need the server address, and a nickname to use on it."
        case .zulip:
            "You'll need your organisation's address and an API key from Zulip's own settings."
        case .matrix:
            nil
        }
    }

    /// Whether Chatman has actually been used against this network.
    ///
    /// Only two of these have been tried against real accounts. The rest are built on the same
    /// interface every mautrix bridge answers, so they should work — but "should" is worth
    /// saying out loud rather than implying by silence.
    public var isSupported: Bool {
        self == .signal || self == .whatsapp || self == .matrix
    }
}

/// Works out where a user or room belongs, based on how mautrix names things.
public enum BridgeIdentity {

    /// Splits `@name:server.example` into its localpart.
    static func localpart(of userID: String) -> Substring {
        guard userID.hasPrefix("@") else { return userID.prefix { $0 != ":" } }
        return userID.dropFirst().prefix { $0 != ":" }
    }

    /// The network a user is on.
    public static func network(of userID: String) -> ChatNetwork {
        let name = localpart(of: userID)

        for network in ChatNetwork.allCases {
            if let prefix = network.ghostPrefix, name.hasPrefix(prefix) {
                return network
            }
            if let bot = network.botLocalpart, name == bot {
                return network
            }
        }

        return .matrix
    }

    /// Whether this is a bridge's control account rather than a person.
    ///
    /// These rooms are how you manage a bridge, not somewhere you chat, so the conversation
    /// list treats them differently instead of showing "signalbot" between your friends.
    public static func isBridgeBot(_ userID: String) -> Bool {
        botLocalparts.contains(String(localpart(of: userID)))
    }

    /// Every bridge bot's name, built once.
    ///
    /// This used to walk all fourteen networks per call and build each name from its raw
    /// value on the way past — fourteen fresh strings to answer a question asked about every
    /// conversation, several times per redraw.
    private static let botLocalparts: Set<String> = Set(
        ChatNetwork.allCases.compactMap(\.botLocalpart)
    )

    /// Strips a bridge's prefix from a display name when the bridge left one on.
    ///
    /// Some bridge configurations append the network to every name — "Anna (Signal)" — which
    /// is redundant once the app shows the network itself.
    public static func cleanDisplayName(_ name: String, network: ChatNetwork) -> String {
        let suffixes = [" (\(network.displayName))", " [\(network.displayName)]"]

        for suffix in suffixes where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }

        return name
    }
}
