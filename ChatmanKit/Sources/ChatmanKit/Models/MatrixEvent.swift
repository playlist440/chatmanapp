import Foundation

/// A single thing that happened in a room.
///
/// Matrix events are polymorphic JSON: the `type` field decides what `content` means, and for
/// messages a nested `msgtype` decides again. Rather than pass dictionaries around, everything
/// is decoded once into the cases Chatman knows about, and anything else becomes
/// ``Content/unsupported(type:)`` so an unknown event can never crash a timeline.
public struct MatrixEvent: Sendable, Identifiable, Hashable {

    public let id: String
    public let sender: String
    public let timestamp: Date

    /// Present on state events. An empty string is still a valid state key.
    public let stateKey: String?

    public let content: Content

    /// What this event relates to: the message a reaction is on, or the one being replied to.
    public let relation: Relation?

    /// Set when the event has been deleted. The content is gone but the placeholder remains.
    public let isRedacted: Bool

    /// The transaction ID we sent it with, when this is our own echoed message.
    ///
    /// Used to match a message coming back through sync with the one already shown locally,
    /// so a sent message doesn't briefly appear twice.
    public let transactionID: String?

    /// The message a redaction deletes.
    ///
    /// Where this sits moved: rooms up to version 10 put `redacts` beside the event type, and
    /// version 11 moved it into the content. Both are read, because which one arrives depends
    /// on how old the room is — and a client that reads only one of them leaves messages
    /// people deleted sitting on screen for good.
    public let redactedEventID: String?

    /// What an edit says the message should now read, from `m.new_content`.
    ///
    /// An edit's own `body` carries the "* " that clients which don't understand edits show,
    /// so applying it verbatim leaves a stray asterisk on every corrected message.
    public let replacementBody: String?

    /// Who the sender meant to address, from `m.mentions`.
    ///
    /// Read as a list of accounts and nothing else — no text is searched for names. A bridge
    /// fills this in when somebody @-mentions you or answers something you wrote, and it names
    /// whichever account stands for you on that network. The server only counts it as a
    /// mention when that account is your Matrix one, which it is not without double puppeting;
    /// this is how the app still hears about it.
    public let mentionedUserIDs: [String]

    // MARK: - Content

    public enum Content: Sendable, Hashable {
        case text(body: String, formatted: String?)
        case emote(body: String)
        case notice(body: String)
        case image(Media)
        case video(Media)
        case audio(Media)
        case file(Media)
        /// A sticker: a picture, but one meant to stand on its own at the size of a word.
        case sticker(Media)
        /// A question with answers to choose from.
        case poll(Poll)
        /// Somebody's choice in a poll. Points at the poll with a reference.
        case pollResponse(answers: [String])
        /// A poll closed by whoever started it.
        case pollEnd
        /// A bridge saying how far one of your messages got on the other network.
        ///
        /// mautrix sends one of these for every message it handles when it is told to, and it
        /// is the only place a message that reached your server but not WhatsApp shows up.
        case sendStatus(SendStatusReport)
        case reaction(key: String)
        case redaction
        case membership(Membership)
        case roomName(String?)
        case roomAvatar(String?)
        /// The room is end-to-end encrypted, which Chatman deliberately doesn't decrypt.
        case encrypted
        case unsupported(type: String)

        /// A one line summary for the conversation list.
        public var preview: String {
            switch self {
            case .text(let body, _), .notice(let body):
                return body
            case .emote(let body):
                return body
            case .image(let media):
                if let caption = media.caption { return caption }
                return media.isAnimated ? "GIF" : String(localized: "Photo", bundle: .module)
            case .video(let media):
                if let caption = media.caption { return caption }
                return media.isAnimated ? "GIF" : String(localized: "Video", bundle: .module)
            case .audio(let media):
                return media.isVoice ? "Voice message" : media.body
            case .file(let media):
                return media.body
            case .sticker:
                return String(localized: "Sticker", bundle: .module)
            case .poll(let poll):
                return "📊 " + poll.question
            case .reaction(let key):
                return key
            case .encrypted:
                return String(localized: "Encrypted message", bundle: .module)
            case .redaction, .membership, .roomName, .roomAvatar, .unsupported,
                 .pollResponse, .pollEnd, .sendStatus:
                return ""
            }
        }

        /// Whether this belongs in a conversation, as opposed to being room bookkeeping.
        public var isMessage: Bool {
            switch self {
            case .text, .emote, .notice, .image, .video, .audio, .file, .encrypted,
                 .sticker, .poll:
                return true
            case .reaction, .redaction, .membership, .roomName, .roomAvatar, .unsupported,
                 .pollResponse, .pollEnd, .sendStatus:
                return false
            }
        }
    }

    /// A poll as it was asked: the question, and the answers in the order they were given.
    public struct Poll: Sendable, Hashable, Codable {
        public struct Answer: Sendable, Hashable, Codable {
            public let id: String
            public let text: String

            public init(id: String, text: String) {
                self.id = id
                self.text = text
            }
        }

        public let question: String
        public let answers: [Answer]
        /// How many answers one person may pick. One unless the poll says otherwise.
        public let maxSelections: Int

        public init(question: String, answers: [Answer], maxSelections: Int) {
            self.question = question
            self.answers = answers
            self.maxSelections = maxSelections
        }
    }

    /// What a bridge reported about a message it was handed.
    public struct SendStatusReport: Sendable, Hashable {
        public enum Outcome: String, Sendable {
            case success = "SUCCESS"
            case pending = "PENDING"
            case failedRetriable = "FAIL_RETRIABLE"
            case failedPermanently = "FAIL_PERMANENT"
        }

        public let outcome: Outcome
        /// The bridge's own words for what went wrong, written for people.
        public let message: String?
    }

    /// An attachment. `url` is an `mxc://` reference that needs the media endpoints to fetch.
    public struct Media: Sendable, Hashable {
        public let body: String

        /// The file's own name, when the sender gave one separately.
        ///
        /// This is what makes a caption possible. Normally `body` is the filename; when a
        /// message carries both, `filename` is the file and `body` is what the person typed
        /// underneath it. Reading only `body` is why captions arrived nowhere.
        public let filename: String?

        public let url: String?
        public let mimeType: String?
        public let size: Int?
        public let width: Int?
        public let height: Int?
        /// Playback length in milliseconds, for video and audio.
        public let duration: Int?
        public let thumbnailURL: String?
        /// A compact representation of the image, used to show something before it loads.
        public let blurhash: String?

        /// What the sender typed under the picture, if anything.
        ///
        /// Only when the two differ: plenty of clients put the filename in both fields, and
        /// "IMG_4021.HEIC" is not a caption.
        public var caption: String? {
            guard let filename, !filename.isEmpty, filename != body, !body.isEmpty else {
                return nil
            }
            return body
        }

        /// Whether this should play by itself, on a loop, without a play button.
        ///
        /// A GIF arrives in two shapes. Sent as a file it's an `image/gif` and says so. Sent
        /// through WhatsApp or Signal it isn't a GIF at all: both networks convert one to a
        /// silent MP4 and the bridge marks it `fi.mau.gif`, because a video that has to be
        /// started by hand is not what anybody meant by "GIF".
        public let isAnimated: Bool

        /// Whether this is a voice message rather than an audio file someone sent.
        ///
        /// Both arrive as `m.audio`. A voice message carries `org.matrix.msc3245.voice`, which
        /// is how the bridges mark what WhatsApp and Signal recorded with the microphone.
        public var isVoice: Bool = false

        /// The shape of the recording, as heights from 0 to 1024, when the sender gave one.
        public var waveform: [Int]? = nil
    }

    public struct Membership: Sendable, Hashable {
        public enum State: String, Sendable {
            case join, leave, invite, ban, knock
        }

        public let state: State
        public let displayName: String?
        public let avatarURL: String?
    }

    public struct Relation: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case annotation
            case replacement
            case reply
            /// "About that one": a poll answer pointing at its poll, a bridge's report on a
            /// message it passed on.
            case reference
            case other(String)
        }

        public let kind: Kind
        public let eventID: String
        /// The emoji, for annotations.
        public let key: String?
    }
}

// MARK: - Decoding

extension MatrixEvent: Decodable {

    private enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case sender
        case type
        case stateKey = "state_key"
        case originServerTS = "origin_server_ts"
        case content
        case unsigned
        case redacts
    }

    private enum ContentKeys: String, CodingKey {
        case msgtype
        case body
        case format
        case formattedBody = "formatted_body"
        case url
        case info
        case membership
        case displayName = "displayname"
        case avatarURL = "avatar_url"
        case name
        case relatesTo = "m.relates_to"
        case filename
        case newContent = "m.new_content"
        case redacts
        case mentions = "m.mentions"
        case voice = "org.matrix.msc3245.voice"
        case extensibleAudio = "org.matrix.msc1767.audio"
        case status, message
    }

    private enum MentionKeys: String, CodingKey {
        case userIDs = "user_ids"
    }

    private enum AudioKeys: String, CodingKey {
        case duration, waveform
    }

    private enum InfoKeys: String, CodingKey {
        case mimetype, size, w, h, duration
        case thumbnailURL = "thumbnail_url"
        case gifPlayback = "fi.mau.gif"
        case blurhash = "xyz.amorgan.blurhash"
    }

    private enum UnsignedKeys: String, CodingKey {
        case redactedBecause = "redacted_because"
        case transactionID = "transaction_id"
    }

    private enum RelatesToKeys: String, CodingKey {
        case relType = "rel_type"
        case eventID = "event_id"
        case key
        case inReplyTo = "m.in_reply_to"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(String.self, forKey: .eventID) ?? UUID().uuidString
        sender = try container.decodeIfPresent(String.self, forKey: .sender) ?? ""
        stateKey = try container.decodeIfPresent(String.self, forKey: .stateKey)

        let milliseconds = try container.decodeIfPresent(Int64.self, forKey: .originServerTS) ?? 0
        timestamp = Date(timeIntervalSince1970: Double(milliseconds) / 1000)

        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""

        let unsigned = try? container.nestedContainer(keyedBy: UnsignedKeys.self, forKey: .unsigned)
        isRedacted = unsigned?.contains(.redactedBecause) ?? false
        transactionID = try? unsigned?.decodeIfPresent(String.self, forKey: .transactionID)

        // A redacted event has an empty content object, so don't try to read anything from it.
        guard !isRedacted else {
            content = .redaction
            relation = nil
            redactedEventID = nil
            replacementBody = nil
            mentionedUserIDs = []
            return
        }

        let content = try? container.nestedContainer(keyedBy: ContentKeys.self, forKey: .content)
        relation = Self.decodeRelation(from: content)

        let mentions = try? content?.nestedContainer(keyedBy: MentionKeys.self, forKey: .mentions)
        mentionedUserIDs = (try? mentions?.decodeIfPresent([String].self, forKey: .userIDs)) ?? []

        redactedEventID = (try? container.decodeIfPresent(String.self, forKey: .redacts) ?? nil)
            ?? (try? content?.decodeIfPresent(String.self, forKey: .redacts) ?? nil)

        replacementBody = Self.decodeReplacementBody(from: content)

        switch type {
        case "m.room.message":
            self.content = Self.decodeMessage(from: content)

        case "m.reaction":
            self.content = .reaction(key: relation?.key ?? "")

        case "m.room.redaction":
            self.content = .redaction

        case "m.room.member":
            let state = (try? content?.decodeIfPresent(String.self, forKey: .membership))
                .flatMap { $0.flatMap(Membership.State.init(rawValue:)) } ?? .leave
            self.content = .membership(.init(
                state: state,
                displayName: try? content?.decodeIfPresent(String.self, forKey: .displayName) ?? nil,
                avatarURL: try? content?.decodeIfPresent(String.self, forKey: .avatarURL) ?? nil
            ))

        case "m.room.name":
            self.content = .roomName(try? content?.decodeIfPresent(String.self, forKey: .name) ?? nil)

        case "m.room.avatar":
            self.content = .roomAvatar(try? content?.decodeIfPresent(String.self, forKey: .url) ?? nil)

        case "m.room.encrypted":
            self.content = .encrypted

        case "m.sticker":
            let body = (try? content?.decodeIfPresent(String.self, forKey: .body) ?? nil) ?? ""
            self.content = .sticker(Self.decodeMedia(from: content, body: body))

        case "org.matrix.msc3381.poll.start", "m.poll.start":
            if let poll = (try? container.decode(PollStart.self, forKey: .content))?.poll {
                self.content = .poll(poll)
            } else {
                self.content = .unsupported(type: type)
            }

        case "org.matrix.msc3381.poll.response", "m.poll.response":
            let chosen = (try? container.decode(PollResponse.self, forKey: .content))?.answers
            self.content = .pollResponse(answers: chosen ?? [])

        case "org.matrix.msc3381.poll.end", "m.poll.end":
            self.content = .pollEnd

        case "com.beeper.message_send_status":
            let raw = (try? content?.decodeIfPresent(String.self, forKey: .status) ?? nil) ?? ""
            if let outcome = SendStatusReport.Outcome(rawValue: raw) {
                self.content = .sendStatus(SendStatusReport(
                    outcome: outcome,
                    message: try? content?.decodeIfPresent(String.self, forKey: .message) ?? nil
                ))
            } else {
                self.content = .unsupported(type: type)
            }

        default:
            self.content = .unsupported(type: type)
        }
    }

    /// The text an edit replaces the original with.
    private static func decodeReplacementBody(
        from content: KeyedDecodingContainer<ContentKeys>?
    ) -> String? {
        guard let replacement = try? content?.nestedContainer(
            keyedBy: ContentKeys.self, forKey: .newContent
        ) else { return nil }

        return try? replacement.decodeIfPresent(String.self, forKey: .body) ?? nil
    }

    private static func decodeMessage(
        from content: KeyedDecodingContainer<ContentKeys>?
    ) -> Content {
        let body = (try? content?.decodeIfPresent(String.self, forKey: .body) ?? nil) ?? ""
        let msgtype = (try? content?.decodeIfPresent(String.self, forKey: .msgtype) ?? nil) ?? "m.text"

        switch msgtype {
        case "m.image":
            return .image(decodeMedia(from: content, body: body))
        case "m.video":
            return .video(decodeMedia(from: content, body: body))
        case "m.audio":
            return .audio(decodeMedia(from: content, body: body))
        case "m.file":
            // What it is, not what it was sent as. A film or a photo that came in as a
            // document — WhatsApp's "send as file", a video note, a bridge's own choice — used
            // to be drawn as a paper icon saying "Tap to open", when it plays and shows
            // perfectly well as what it is.
            let media = decodeMedia(from: content, body: body)
            switch MatrixEvent.Media.nature(of: media.mimeType) {
            case .video: return .video(media)
            case .image: return .image(media)
            case .other: return .file(media)
            }
        case "m.emote":
            return .emote(body: body)
        case "m.notice":
            return .notice(body: body)
        default:
            let formatted = try? content?.decodeIfPresent(String.self, forKey: .formattedBody) ?? nil
            return .text(body: body, formatted: formatted)
        }
    }

    private static func decodeMedia(
        from content: KeyedDecodingContainer<ContentKeys>?,
        body: String
    ) -> Media {
        let url = try? content?.decodeIfPresent(String.self, forKey: .url) ?? nil
        let info = try? content?.nestedContainer(keyedBy: InfoKeys.self, forKey: .info)

        let mimeType = try? info?.decodeIfPresent(String.self, forKey: .mimetype) ?? nil
        let flagged = (try? info?.decodeIfPresent(Bool.self, forKey: .gifPlayback) ?? nil) ?? false

        // Present, even empty, means "this was spoken". The shape of the recording sits beside
        // it in the extensible-events block, when the sender drew one.
        let isVoice = content?.contains(.voice) ?? false
        let audio = try? content?.nestedContainer(keyedBy: AudioKeys.self, forKey: .extensibleAudio)
        let waveform = try? audio?.decodeIfPresent([Int].self, forKey: .waveform) ?? nil
        let spokenFor = try? audio?.decodeIfPresent(Int.self, forKey: .duration) ?? nil

        var media = Media(
            body: body,
            filename: try? content?.decodeIfPresent(String.self, forKey: .filename) ?? nil,
            url: url,
            mimeType: mimeType,
            size: try? info?.decodeIfPresent(Int.self, forKey: .size) ?? nil,
            width: try? info?.decodeIfPresent(Int.self, forKey: .w) ?? nil,
            height: try? info?.decodeIfPresent(Int.self, forKey: .h) ?? nil,
            duration: try? info?.decodeIfPresent(Int.self, forKey: .duration) ?? nil,
            thumbnailURL: try? info?.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? nil,
            blurhash: try? info?.decodeIfPresent(String.self, forKey: .blurhash) ?? nil,
            isAnimated: flagged || mimeType?.lowercased() == "image/gif"
        )
        media.isVoice = isVoice
        media.waveform = waveform
        if media.duration == nil, let spokenFor { media = media.lasting(spokenFor) }
        return media
    }

    private static func decodeRelation(
        from content: KeyedDecodingContainer<ContentKeys>?
    ) -> Relation? {
        guard let relates = try? content?.nestedContainer(keyedBy: RelatesToKeys.self, forKey: .relatesTo) else {
            return nil
        }

        // Replies are nested one level deeper and have no rel_type, which is a quirk of the
        // spec rather than an oversight here.
        if let reply = try? relates.nestedContainer(keyedBy: RelatesToKeys.self, forKey: .inReplyTo),
           let eventID = try? reply.decodeIfPresent(String.self, forKey: .eventID) ?? nil {
            return Relation(kind: .reply, eventID: eventID, key: nil)
        }

        guard let eventID = try? relates.decodeIfPresent(String.self, forKey: .eventID) ?? nil else {
            return nil
        }

        let relType = (try? relates.decodeIfPresent(String.self, forKey: .relType) ?? nil) ?? ""
        let key = try? relates.decodeIfPresent(String.self, forKey: .key) ?? nil

        let kind: Relation.Kind = switch relType {
        case "m.annotation": .annotation
        case "m.replace": .replacement
        case "m.reference": .reference
        default: .other(relType)
        }

        return Relation(kind: kind, eventID: eventID, key: key)
    }
}

// MARK: - Polls

extension MatrixEvent.Media {
    /// What a file's type says it is, for the ones worth drawing as more than a file.
    public enum Nature { case video, image, other }

    public static func nature(of mimeType: String?) -> Nature {
        guard let type = mimeType?.lowercased() else { return .other }
        if type.hasPrefix("video/") { return .video }
        // Not a vector drawing or an icon: those don't decode as a picture here.
        if type.hasPrefix("image/"), !type.contains("svg"), !type.contains("icon") { return .image }
        return .other
    }

    /// The same attachment with its length filled in from somewhere other than `info`.
    func lasting(_ milliseconds: Int) -> MatrixEvent.Media {
        var copy = MatrixEvent.Media(
            body: body, filename: filename, url: url, mimeType: mimeType, size: size,
            width: width, height: height, duration: milliseconds,
            thumbnailURL: thumbnailURL, blurhash: blurhash, isAnimated: isAnimated
        )
        copy.isVoice = isVoice
        copy.waveform = waveform
        return copy
    }
}

/// Any key at all, for content whose keys are namespaced strings with dots in them.
private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// A piece of text as extensible events write it, in whichever of its shapes it came.
///
/// The unstable form puts the words under `org.matrix.msc1767.text`, the stable one under
/// `m.text` as a list of representations, and plenty of senders add a plain `body` besides.
/// All three are read; whichever has something wins.
private struct PollText: Decodable {
    let text: String

    private struct Representation: Decodable { let body: String? }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)

        if let unstable = try? container.decode(String.self, forKey: AnyKey("org.matrix.msc1767.text")) {
            text = unstable
        } else if let list = try? container.decode([Representation].self, forKey: AnyKey("m.text")),
                  let first = list.compactMap(\.body).first {
            text = first
        } else if let plain = try? container.decode(String.self, forKey: AnyKey("m.text")) {
            text = plain
        } else if let body = try? container.decode(String.self, forKey: AnyKey("body")) {
            text = body
        } else {
            text = ""
        }
    }
}

/// The content of a poll's first event, unstable or stable.
private struct PollStart: Decodable {
    let poll: MatrixEvent.Poll?

    private struct Body: Decodable {
        let question: PollText?
        let answers: [Answer]?
        let maxSelections: Int?

        enum CodingKeys: String, CodingKey {
            case question, answers
            case maxSelections = "max_selections"
        }
    }

    private struct Answer: Decodable {
        let id: String
        let text: String

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            id = (try? container.decode(String.self, forKey: AnyKey("id")))
                ?? (try? container.decode(String.self, forKey: AnyKey("m.id")))
                ?? UUID().uuidString
            text = (try? PollText(from: decoder).text) ?? ""
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let body = (try? container.decode(Body.self, forKey: AnyKey("org.matrix.msc3381.poll.start")))
            ?? (try? container.decode(Body.self, forKey: AnyKey("m.poll")))

        guard let body, let question = body.question?.text, !question.isEmpty else {
            poll = nil
            return
        }

        poll = MatrixEvent.Poll(
            question: question,
            answers: (body.answers ?? []).map { .init(id: $0.id, text: $0.text) },
            maxSelections: max(1, body.maxSelections ?? 1)
        )
    }
}

/// Which answers somebody picked.
private struct PollResponse: Decodable {
    let answers: [String]

    private struct Unstable: Decodable { let answers: [String]? }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        if let unstable = try? container.decode(Unstable.self, forKey: AnyKey("org.matrix.msc3381.poll.response")) {
            answers = unstable.answers ?? []
        } else {
            answers = (try? container.decode([String].self, forKey: AnyKey("m.selections"))) ?? []
        }
    }
}
