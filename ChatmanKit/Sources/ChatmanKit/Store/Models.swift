import Foundation
import SwiftData

/// A conversation, whether that's one person or a group.
///
/// This is a cache of what the homeserver knows, not a source of truth. Anything here can be
/// rebuilt by syncing from scratch, which is what makes it safe to delete the whole store when
/// something looks wrong rather than trying to repair it.
@Model
public final class Conversation {

    /// The Matrix room ID, e.g. `!abc:example.com`.
    @Attribute(.unique) public var id: String

    /// The room's own name. Group chats have one; one-to-one conversations usually don't and
    /// are named after the other person instead.
    public var name: String?

    public var avatarURL: String?

    /// Whether this is a one-to-one conversation, as opposed to a group.
    public var isDirect: Bool

    /// Which chat service this conversation actually lives on.
    public var networkID: String

    /// When something last happened here. Drives the order of the conversation list.
    public var lastActivity: Date

    /// A one-line summary of the last message, for the conversation list.
    public var lastMessagePreview: String

    /// How many messages have arrived since you last read.
    public var unreadCount: Int

    /// Token for loading older messages. `nil` once the start of the room is reached.
    public var previousBatch: String?

    /// True when the room is encrypted, which Chatman shows but doesn't decrypt.
    public var isEncrypted: Bool

    /// The other person, in a one-to-one conversation.
    public var directPartnerID: String?

    /// How many other people are in this room, excluding you and any bridge bots.
    ///
    /// Asked of the server once and kept. Deciding "is this a group" from who has spoken is
    /// unreliable in both directions: a quiet group looks like a private chat, and a chat
    /// whose history predates double puppeting counts your own old account as a second
    /// person.
    public var otherMemberCount: Int = 0

    /// Kept at the top of the list, whatever it says.
    ///
    /// Every messaging app has this and they all mean the same thing: three or four people
    /// you talk to constantly, above the shop that texted you once about a parcel.
    public var isPinned: Bool = false

    /// Marked unread by hand, after you'd already read it.
    ///
    /// Not the same as having unread messages, which is a count from the server. This is the
    /// "deal with this later" flag: a dot with no number, which is exactly what Mail and
    /// Messages show for it.
    public var isManuallyUnread: Bool = false

    /// Silenced. The room is muted on the server, so it stops notifying every device.
    public var isMuted: Bool = false

    /// A name you chose yourself, when nothing else got it right.
    ///
    /// The address book is matched on phone number, and there are people that can't reach:
    /// somebody on Signal with a username instead of a number has nothing to match against,
    /// and arrives called something like "bdbkyra" forever. This is the way out — and being
    /// stored here, it survives every resync and outranks whatever the network says.
    public var customName: String?

    /// A picture you chose along with that name.
    public var customPhoto: Data?

    /// Kept, but out of the way.
    ///
    /// Archiving is not deleting and not muting: the conversation stays exactly as it is,
    /// it simply stops taking up a line in the list. Which is what people actually want for
    /// the shop that texted them once about a delivery.
    public var isArchived: Bool = false

    /// How far the other side has confirmed reading, and how far the bridge has confirmed
    /// passing messages on.
    ///
    /// Kept on the conversation as well as on each message because a receipt says "up to
    /// here", and it can easily arrive for a message this device hasn't stored yet — the
    /// first sync fetches one message per room, and the rest is loaded later. Without this,
    /// scrolling back would show older messages as unsent when they were read days ago.
    public var readThrough: Date?
    public var deliveredThrough: Date?

    // MARK: Attention
    //
    // What the rules in `Attention` need to decide whether this conversation is waiting on
    // you. All of it counts or times — nothing here is ever read from the words themselves.

    /// How many unread messages here mention you, as the server counts them.
    ///
    /// `highlight_count` in the sync: the server applies your push rules, so a mention or a
    /// keyword you set up is counted without this device reading anything.
    public var mentionCount: Int = 0

    /// Unread messages that mention one of your bridged accounts, or answer something you
    /// wrote, counted on this device.
    ///
    /// The server's count only sees your Matrix account. Without double puppeting a bridge
    /// names the account that stands for you on WhatsApp instead, and the server doesn't know
    /// that one is you — this does.
    public var localMentions: Int = 0

    /// Until when this group counts as having something going on. See `Attention.Burst`.
    public var burstUntil: Date?

    /// When a burst was last called here, so one busy evening is one tap and not six.
    public var lastBurstAt: Date?

    /// How many messages arrive here on an ordinary day, learned slowly from the counts.
    public var typicalDaily: Double = 0

    /// The server's unread count the last time it was looked at, and when.
    public var countSample: Int = 0
    public var countSampledAt: Date?

    /// Recent rises in that count, as `seconds:rise` pairs. Kept short: only the last half
    /// hour matters, and only the rule in `Attention.Burst` reads it.
    public var riseLog: String = ""

    // MARK: Closeness

    /// How much you talk here, fading with time. See `Closeness`.
    ///
    /// Your own messages and reactions only: what other people send says how busy a chat is,
    /// not how close you are to it.
    public var closeness: Double = 0
    public var closenessAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    public var messages: [Message] = []

    public init(
        id: String,
        name: String? = nil,
        avatarURL: String? = nil,
        isDirect: Bool = false,
        network: ChatNetwork = .matrix,
        lastActivity: Date = .distantPast,
        lastMessagePreview: String = "",
        unreadCount: Int = 0,
        previousBatch: String? = nil,
        isEncrypted: Bool = false,
        directPartnerID: String? = nil,
        otherMemberCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.isDirect = isDirect
        self.networkID = network.rawValue
        self.lastActivity = lastActivity
        self.lastMessagePreview = lastMessagePreview
        self.unreadCount = unreadCount
        self.previousBatch = previousBatch
        self.isEncrypted = isEncrypted
        self.directPartnerID = directPartnerID
        self.otherMemberCount = otherMemberCount
    }

    /// Whether this is a group rather than a private chat.
    public var isGroup: Bool { otherMemberCount > 1 }

    /// The chat service this conversation belongs to.
    ///
    /// Stored as a string because SwiftData can't persist an enum directly, but always read
    /// through here so the rest of the app never touches the raw value.
    public var network: ChatNetwork {
        get { ChatNetwork(rawValue: networkID) ?? .matrix }
        set { networkID = newValue.rawValue }
    }

    /// Whether this is WhatsApp's status feed. See ``StatusBroadcast``.
    ///
    /// Read from the room's own name and address rather than stored, so a room that was
    /// created before the setting existed is recognised without being downloaded again.
    public var isStatusBroadcast: Bool {
        StatusBroadcast.matches(name: name, partnerID: directPartnerID)
    }

    /// The name to show in the conversation list.
    public var displayName: String {
        if let name, !name.isEmpty {
            return BridgeIdentity.cleanDisplayName(name, network: network)
        }
        return "Conversation"
    }
}

/// A single message in a conversation.
@Model
public final class Message {

    /// Every conversation screen asks for its messages newest first, and every one of those
    /// questions sorts on this.
    #Index<Message>([\.timestamp])

    /// The Matrix event ID.
    @Attribute(.unique) public var id: String

    public var sender: String
    public var senderName: String?
    public var timestamp: Date

    /// The text, or a filename for attachments.
    public var body: String

    /// Which kind of message this is. See ``kind``.
    public var kindID: String

    /// The `mxc://` address of an attachment.
    public var mediaURL: String?
    public var mediaWidth: Int?
    public var mediaHeight: Int?
    public var mediaMimeType: String?

    /// The `mxc://` address of the preview picture a video was sent with.
    ///
    /// A homeserver makes thumbnails of pictures, not of films — asking it to scale an MP4
    /// gets an error, which is why a video needs its own still. The sender's client uploads
    /// one alongside the file, and this is where it lives.
    public var mediaThumbnailURL: String?

    /// Whether this attachment plays by itself. See ``MatrixEvent/Media/isAnimated``.
    public var isAnimated: Bool = false

    /// What the sender typed under a picture, when they typed anything.
    public var caption: String?

    /// The message this one replies to.
    public var replyToID: String?

    /// Emoji reactions, stored as a compact string because SwiftData handles a scalar far
    /// better than a second relationship for something this small and this frequently rewritten.
    ///
    /// Two formats live in here, and a string column holds both, so changing the format
    /// needed no migration of anyone's store.
    ///
    /// The first, `👍:2|❤️:1`, is counts and nothing else, and that was the flaw: with no idea
    /// who reacted or which event said so, there was nothing to recognise a reaction by. Your
    /// own reaction counted twice — once shown straight away, once more when the server sent
    /// it back. An event the sync happened to deliver twice counted twice. And a reaction
    /// somebody took back could never be taken off, because taking one back names the
    /// reaction's event, and there was no event to find.
    ///
    /// The second is JSON with one entry per reaction event: who gave it, and which emoji.
    /// Counting then goes per person, and a withdrawn reaction can be found by its event.
    /// Counts written in the first format are kept as they were — they cannot be tied to
    /// people after the fact, but they get no worse either.
    public var reactionsBlob: String

    /// True while a message is on its way to the server.
    ///
    /// Sent messages appear immediately and are reconciled when they come back through sync,
    /// so a slow connection never means a slow-feeling app.
    public var isPending: Bool

    /// True when sending failed and the message can be retried.
    public var didFailToSend: Bool

    /// Whether this message has been changed since it was sent.
    public var wasEdited: Bool = false

    /// When the bridge confirmed it had handed this on to the other network.
    ///
    /// Matrix has no notion of delivery — an event either exists on the server or it doesn't.
    /// What comes closest is the bridge's own read marker, which it sends once it has passed
    /// the message to Signal or WhatsApp. That's the honest meaning of the word here.
    public var deliveredAt: Date?

    /// When the other party's read marker first covered this message.
    public var readAt: Date?

    /// What the bridge said when it couldn't pass this message on, when it said so.
    ///
    /// Your server has it; WhatsApp or Signal doesn't. Without this the message looks sent,
    /// and the other person never gets it.
    public var deliveryProblem: String?

    /// When this was put in the queue to send. Set again when you ask to try once more.
    ///
    /// A message waits for a connection for a while, and then stops: "I'm there in five
    /// minutes" arriving half an hour late is worse than it not arriving at all.
    public var queuedAt: Date?

    /// The bytes of an attachment that hasn't reached the server yet, kept on disk under this
    /// name in the outbox until it has. See `Outbox`.
    public var outboxFile: String?

    /// Whether this was spoken rather than sent as a file.
    public var isVoice: Bool = false

    /// How long a recording or a film plays, in milliseconds.
    public var mediaDuration: Int?

    /// The shape of a recording, as heights from 0 to 1024 separated by commas.
    public var waveformBlob: String?

    /// A poll's answers and who picked what, as JSON. See ``PollState``.
    public var pollBlob: String?

    public var conversation: Conversation?

    public init(
        id: String,
        sender: String,
        senderName: String? = nil,
        timestamp: Date,
        body: String,
        kind: Kind,
        mediaURL: String? = nil,
        mediaWidth: Int? = nil,
        mediaHeight: Int? = nil,
        mediaMimeType: String? = nil,
        mediaThumbnailURL: String? = nil,
        isAnimated: Bool = false,
        caption: String? = nil,
        replyToID: String? = nil,
        reactions: [String: Int] = [:],
        isPending: Bool = false,
        didFailToSend: Bool = false,
        wasEdited: Bool = false
    ) {
        self.id = id
        self.sender = sender
        self.senderName = senderName
        self.timestamp = timestamp
        self.body = body
        self.kindID = kind.rawValue
        self.mediaURL = mediaURL
        self.mediaWidth = mediaWidth
        self.mediaHeight = mediaHeight
        self.mediaMimeType = mediaMimeType
        self.mediaThumbnailURL = mediaThumbnailURL
        self.isAnimated = isAnimated
        self.caption = caption
        self.replyToID = replyToID
        self.reactionsBlob = Message.encode(reactions)
        self.isPending = isPending
        self.didFailToSend = didFailToSend
        self.wasEdited = wasEdited
    }

    /// Whether this is something to look at rather than to read.
    public var isPicture: Bool {
        kind == .image || kind == .video
    }

    public enum Kind: String, Sendable, CaseIterable {
        case text
        case emote
        case notice
        case image
        case video
        case audio
        case file
        case encrypted
        case sticker
        case poll
    }

    /// What Matrix calls this kind of message.
    ///
    /// A sticker goes out as a picture: it is one, and every bridge knows what to do with a
    /// picture where not all of them take stickers from Matrix.
    var msgtypeName: String {
        switch kind {
        case .image, .sticker: "m.image"
        case .video: "m.video"
        case .audio: "m.audio"
        case .file: "m.file"
        default: "m.text"
        }
    }

    /// The shape of a recording, when there is one.
    public var waveform: [Int] {
        get { (waveformBlob ?? "").split(separator: ",").compactMap { Int($0) } }
        set { waveformBlob = newValue.isEmpty ? nil : newValue.map(String.init).joined(separator: ",") }
    }

    /// The poll this message asks, with every vote counted so far.
    public var poll: PollState? {
        get { pollBlob.flatMap(PollState.init(blob:)) }
        set { pollBlob = newValue?.blob }
    }

    /// Whether this is a stand-in for something you sent that the server hasn't confirmed.
    ///
    /// Real event IDs start with `$`. A stand-in is filed under its transaction ID until the
    /// server's copy comes back and takes its place.
    public var isStandIn: Bool {
        !id.hasPrefix("$")
    }

    public var kind: Kind {
        get { Kind(rawValue: kindID) ?? .text }
        set { kindID = newValue.rawValue }
    }

    /// Emoji reactions and how many people gave each.
    ///
    /// Setting this writes plain counts, the old way, and forgets who gave what. That is
    /// right for the places that set it — a preview, a test — and wrong for anything that
    /// arrives from the server, which goes through ``addReaction(_:by:event:)``.
    public var reactions: [String: Int] {
        get { Reactions(blob: reactionsBlob).counts }
        set { reactionsBlob = Reactions(counts: newValue).blob }
    }

    /// Records a reaction carried by one event.
    ///
    /// The same person giving the same emoji twice is still one reaction: that is your own
    /// reaction and the server's echo of it, or one event delivered twice.
    public func addReaction(_ key: String, by sender: String, event: String) {
        var stored = Reactions(blob: reactionsBlob)
        stored.events[event] = .init(sender: sender, key: key)
        reactionsBlob = stored.blob
    }

    /// Takes off the reaction that one event carried. Returns whether there was one.
    @discardableResult
    public func removeReaction(event: String) -> Bool {
        var stored = Reactions(blob: reactionsBlob)
        guard stored.events.removeValue(forKey: event) != nil else { return false }
        reactionsBlob = stored.blob
        return true
    }

    /// Gives a reaction shown before the server answered the ID the server gave it.
    ///
    /// Whichever arrives first. If the sync already brought the real event back, the
    /// stand-in simply goes; otherwise it takes the real ID, so that withdrawing it later
    /// finds it.
    public func confirmReaction(_ provisional: String, as event: String) {
        var stored = Reactions(blob: reactionsBlob)
        guard let entry = stored.events.removeValue(forKey: provisional) else { return }
        if stored.events[event] == nil { stored.events[event] = entry }
        reactionsBlob = stored.blob
    }

    /// Whether any reaction here was carried by this event.
    public func holdsReaction(event: String) -> Bool {
        Reactions(blob: reactionsBlob).events[event] != nil
    }

    /// Both formats, read and written in one place.
    struct Reactions: Codable {
        /// Counts from the old format, which never knew who reacted.
        var base: [String: Int] = [:]

        /// One entry per reaction event.
        var events: [String: Entry] = [:]

        struct Entry: Codable, Hashable {
            var sender: String
            var key: String

            enum CodingKeys: String, CodingKey { case sender = "s", key = "k" }
        }

        enum CodingKeys: String, CodingKey { case base = "b", events = "e" }

        init(counts: [String: Int]) { base = counts }

        init(blob: String) {
            // JSON always starts with a brace, and the old format never can: it starts with
            // an emoji. That is the whole of the version check.
            if blob.hasPrefix("{"),
               let data = blob.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(Reactions.self, from: data) {
                self = decoded
            } else {
                base = Message.decode(blob)
            }
        }

        /// Per emoji, how many people. The old counts, plus one for each distinct person.
        var counts: [String: Int] {
            var result = base
            for entry in Set(events.values) {
                result[entry.key, default: 0] += 1
            }
            return result
        }

        /// Written back in the old format while it can be — nothing about events to keep —
        /// so a message nobody reacted to since stays exactly as it was stored.
        var blob: String {
            guard !events.isEmpty else { return Message.encode(base) }
            guard let data = try? JSONEncoder().encode(self),
                  let text = String(data: data, encoding: .utf8)
            else { return Message.encode(counts) }
            return text
        }
    }

    static func encode(_ reactions: [String: Int]) -> String {
        reactions
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "|")
    }

    static func decode(_ blob: String) -> [String: Int] {
        guard !blob.isEmpty else { return [:] }

        return blob.split(separator: "|").reduce(into: [:]) { result, pair in
            // Emoji can't contain a colon, so splitting on the last one is safe.
            guard let separator = pair.lastIndex(of: ":") else { return }
            let key = String(pair[..<separator])
            let count = Int(pair[pair.index(after: separator)...]) ?? 0
            if !key.isEmpty, count > 0 { result[key] = count }
        }
    }
}

/// A poll, and who has picked what.
///
/// Counted the way the spec counts: one entry per person, holding their latest choice. A
/// second vote replaces the first, and a vote with nothing valid in it takes the first away.
public struct PollState: Codable, Sendable, Hashable {
    public var answers: [MatrixEvent.Poll.Answer]
    public var maxSelections: Int
    /// Per person, the answers they picked.
    public var votes: [String: [String]] = [:]
    public var isClosed = false

    enum CodingKeys: String, CodingKey {
        case answers = "a", maxSelections = "m", votes = "v", isClosed = "c"
    }

    public init(_ poll: MatrixEvent.Poll) {
        answers = poll.answers
        maxSelections = poll.maxSelections
    }

    init?(blob: String) {
        guard let data = blob.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PollState.self, from: data)
        else { return nil }
        self = decoded
    }

    var blob: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Records somebody's choice. Answers the poll doesn't have are dropped, and so is
    /// anything past the number one person may pick.
    public mutating func record(_ chosen: [String], by voter: String) {
        guard !isClosed else { return }
        let known = Set(answers.map(\.id))
        let valid = Array(chosen.filter(known.contains).prefix(maxSelections))
        if valid.isEmpty {
            votes.removeValue(forKey: voter)
        } else {
            votes[voter] = valid
        }
    }

    /// How many people picked each answer.
    public var tally: [String: Int] {
        votes.values.reduce(into: [:]) { counts, picked in
            for answer in Set(picked) { counts[answer, default: 0] += 1 }
        }
    }

    /// How many people have voted at all.
    public var voters: Int { votes.count }
}

/// The models this app persists, in one place so both the phone and watch build the same store.
public enum ChatmanSchema {
    public static let models: [any PersistentModel.Type] = [Conversation.self, Message.self]
}
