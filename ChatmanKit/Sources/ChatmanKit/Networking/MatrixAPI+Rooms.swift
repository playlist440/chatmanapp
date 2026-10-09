import Foundation

extension MatrixAPI {

    // MARK: - Sending

    struct SendResponse: Decodable {
        let eventID: String
        enum CodingKeys: String, CodingKey { case eventID = "event_id" }
    }

    struct TextMessage: Encodable {
        let msgtype = "m.text"
        let body: String
        let relatesTo: ReplyRelation?

        enum CodingKeys: String, CodingKey {
            case msgtype, body
            case relatesTo = "m.relates_to"
        }
    }

    struct ReplyRelation: Encodable {
        struct InReplyTo: Encodable {
            let eventID: String
            enum CodingKeys: String, CodingKey { case eventID = "event_id" }
        }

        let inReplyTo: InReplyTo

        enum CodingKeys: String, CodingKey { case inReplyTo = "m.in_reply_to" }
    }

    struct AnnotationRelation: Encodable {
        struct Relation: Encodable {
            let relType = "m.annotation"
            let eventID: String
            let key: String

            enum CodingKeys: String, CodingKey {
                case relType = "rel_type"
                case eventID = "event_id"
                case key
            }
        }

        let relatesTo: Relation

        enum CodingKeys: String, CodingKey { case relatesTo = "m.relates_to" }
    }

    /// Sends a text message, optionally as a reply to another one.
    ///
    /// - Parameter transactionID: Pass the same value when retrying so the server can tell a
    ///   retry from a second message. Defaults to a fresh one.
    /// - Returns: The event ID the server assigned.
    @discardableResult
    public func sendText(
        _ body: String,
        to roomID: String,
        replyingTo replyEventID: String? = nil,
        transactionID: String = MatrixAPI.transactionID()
    ) async throws -> String {
        let content = TextMessage(
            body: body,
            relatesTo: replyEventID.map { ReplyRelation(inReplyTo: .init(eventID: $0)) }
        )

        let response: SendResponse = try await send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/send/m.room.message/\(transactionID)",
            body: content
        )
        return response.eventID
    }

    struct ImageMessage: Encodable {
        struct Info: Encodable {
            let mimetype: String
            let size: Int
            let w: Int?
            let h: Int?
        }

        let msgtype = "m.image"
        let body: String
        /// Sent only when there is a caption.
        ///
        /// This is the whole mechanism behind captions, and it reads backwards until you
        /// know it: normally `body` is the filename and there is no `filename` field at all.
        /// Put both in, and `filename` becomes the file while `body` becomes the words
        /// typed under it. It is how the app already reads other people's captions, so it
        /// is how it writes its own.
        let filename: String?
        let url: String
        let info: Info
        let relatesTo: ReplyRelation?

        enum CodingKeys: String, CodingKey {
            case msgtype, body, filename, url, info
            case relatesTo = "m.relates_to"
        }
    }

    /// Sends a picture that has already been uploaded.
    ///
    /// The dimensions travel with it so the other side can lay out a placeholder before the
    /// file arrives — without them a conversation jumps around as pictures load.
    @discardableResult
    public func sendImage(
        mxcURL: String,
        filename: String,
        mimeType: String,
        byteCount: Int,
        width: Int?,
        height: Int?,
        caption: String? = nil,
        to roomID: String,
        replyingTo replyEventID: String? = nil,
        transactionID: String = MatrixAPI.transactionID()
    ) async throws -> String {
        let content = ImageMessage(
            body: caption ?? filename,
            filename: caption == nil ? nil : filename,
            url: mxcURL,
            info: .init(mimetype: mimeType, size: byteCount, w: width, h: height),
            relatesTo: replyEventID.map { ReplyRelation(inReplyTo: .init(eventID: $0)) }
        )

        let response: SendResponse = try await send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/send/m.room.message/\(transactionID)",
            body: content
        )
        return response.eventID
    }

    struct AttachmentMessage: Encodable {
        struct Info: Encodable {
            let mimetype: String?
            let w: Int?
            let h: Int?
            let size: Int?
            let duration: Int?
        }

        /// The shape of a recording, where extensible events keep it.
        struct Recording: Encodable {
            let duration: Int?
            let waveform: [Int]?
        }

        /// An empty object, which is all the voice flag ever is.
        struct Marker: Encodable {}

        let msgtype: String
        let body: String
        let url: String
        let info: Info
        let relatesTo: ReplyRelation?
        /// Present only on a voice message. Its being there is the whole message.
        let voice: Marker?
        let recording: Recording?

        enum CodingKeys: String, CodingKey {
            case msgtype, body, url, info
            case relatesTo = "m.relates_to"
            case voice = "org.matrix.msc3245.voice"
            case recording = "org.matrix.msc1767.audio"
        }
    }

    /// Sends something that is already on the server, again.
    ///
    /// Forwarding, in other words. Nothing is uploaded: the file has an address on your own
    /// homeserver and this points a second message at the same one, which is why passing a
    /// photo from a Signal chat to a WhatsApp chat costs no bytes on the phone at all. The
    /// bridge at the other end fetches it and hands it to its own network.
    ///
    /// Also the second half of sending a new file, once it has been uploaded.
    ///
    /// - Parameter isVoice: Marks a recording as spoken. That flag is what makes WhatsApp and
    ///   Signal show it as a voice message with a play button instead of a file to download;
    ///   the bridge converts the sound to what the network expects.
    @discardableResult
    public func sendAttachment(
        mxcURL: String,
        msgtype: String,
        filename: String,
        mimeType: String?,
        width: Int?,
        height: Int?,
        byteCount: Int? = nil,
        duration: Int? = nil,
        isVoice: Bool = false,
        waveform: [Int]? = nil,
        to roomID: String,
        replyingTo replyEventID: String? = nil,
        transactionID: String = MatrixAPI.transactionID()
    ) async throws -> String {
        let content = AttachmentMessage(
            msgtype: msgtype,
            body: filename,
            url: mxcURL,
            info: .init(mimetype: mimeType, w: width, h: height, size: byteCount, duration: duration),
            relatesTo: replyEventID.map { ReplyRelation(inReplyTo: .init(eventID: $0)) },
            voice: isVoice ? .init() : nil,
            recording: isVoice ? .init(duration: duration, waveform: waveform) : nil
        )

        let response: SendResponse = try await send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/send/m.room.message/\(transactionID)",
            body: content
        )
        return response.eventID
    }

    struct EditedMessage: Encodable {
        struct Replacement: Encodable {
            let relType = "m.replace"
            let eventID: String

            enum CodingKeys: String, CodingKey {
                case relType = "rel_type"
                case eventID = "event_id"
            }
        }

        struct NewContent: Encodable {
            let msgtype = "m.text"
            let body: String
        }

        let msgtype = "m.text"
        /// What clients that don't understand edits will show. The asterisk is the convention.
        let body: String
        let newContent: NewContent
        let relatesTo: Replacement

        enum CodingKeys: String, CodingKey {
            case msgtype, body
            case newContent = "m.new_content"
            case relatesTo = "m.relates_to"
        }
    }

    /// Replaces the text of a message you sent.
    ///
    /// Matrix doesn't change the original event — nothing ever changes an event. It sends a
    /// new one that points at the old one and says "read this instead", and every client is
    /// expected to apply that itself.
    @discardableResult
    public func editText(
        _ body: String,
        replacing eventID: String,
        in roomID: String,
        transactionID: String = MatrixAPI.transactionID()
    ) async throws -> String {
        let content = EditedMessage(
            body: "* \(body)",
            newContent: .init(body: body),
            relatesTo: .init(eventID: eventID)
        )

        let response: SendResponse = try await send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/send/m.room.message/\(transactionID)",
            body: content
        )
        return response.eventID
    }

    /// Reacts to a message with an emoji.
    @discardableResult
    public func sendReaction(
        _ key: String,
        to eventID: String,
        in roomID: String,
        transactionID: String = MatrixAPI.transactionID()
    ) async throws -> String {
        let content = AnnotationRelation(relatesTo: .init(eventID: eventID, key: key))

        let response: SendResponse = try await send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/send/m.reaction/\(transactionID)",
            body: content
        )
        return response.eventID
    }

    struct PollVote: Encodable {
        struct Reference: Encodable {
            let relType = "m.reference"
            let eventID: String
            enum CodingKeys: String, CodingKey {
                case relType = "rel_type"
                case eventID = "event_id"
            }
        }

        struct Choice: Encodable { let answers: [String] }

        let relatesTo: Reference
        let choice: Choice

        enum CodingKeys: String, CodingKey {
            case relatesTo = "m.relates_to"
            case choice = "org.matrix.msc3381.poll.response"
        }
    }

    /// Votes in a poll. An empty list takes a vote back.
    ///
    /// In the unstable form, because that is the one the bridges send and read: a vote cast
    /// here reaches WhatsApp as a vote, not as a message.
    @discardableResult
    public func vote(
        _ answers: [String],
        inPoll pollEventID: String,
        in roomID: String,
        transactionID: String = MatrixAPI.transactionID()
    ) async throws -> String {
        let content = PollVote(relatesTo: .init(eventID: pollEventID), choice: .init(answers: answers))

        let response: SendResponse = try await send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/send/org.matrix.msc3381.poll.response/\(transactionID)",
            body: content
        )
        return response.eventID
    }

    /// Deletes a message, or removes a reaction.
    public func redact(
        eventID: String,
        in roomID: String,
        transactionID: String = MatrixAPI.transactionID()
    ) async throws {
        struct Empty: Encodable {}
        try await send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/redact/\(eventID.pathEscaped)/\(transactionID)",
            body: Empty()
        )
    }

    // MARK: - Reading

    /// Marks everything up to and including `eventID` as read.
    public func markRead(upTo eventID: String, in roomID: String) async throws {
        struct Empty: Encodable {}
        try await send(
            .post,
            path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/receipt/m.read/\(eventID.pathEscaped)",
            body: Empty()
        )
    }

    struct TypingRequest: Encodable {
        let typing: Bool
        let timeout: Int?
    }

    /// Tells the room whether you're typing.
    ///
    /// Only sent from iPhone. On the watch this would mean a request per keystroke to power a
    /// display the watch doesn't have.
    public func setTyping(_ isTyping: Bool, userID: String, in roomID: String) async throws {
        let body = TypingRequest(typing: isTyping, timeout: isTyping ? 20_000 : nil)
        try await send(
            .put,
            path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/typing/\(userID.pathEscaped)",
            body: body
        )
    }

    public struct MessagesResponse: Decodable, Sendable {
        public let chunk: [MatrixEvent]
        /// Token to continue paginating from, or `nil` at the start of the room.
        public let end: String?
    }

    /// Loads older messages, working backwards from `token`.
    public func messages(
        in roomID: String,
        from token: String,
        limit: Int = 30
    ) async throws -> MessagesResponse {
        let query = [
            URLQueryItem(name: "from", value: token),
            URLQueryItem(name: "dir", value: "b"),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        return try await send(.get,
                              path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/messages",
                              query: query, as: MessagesResponse.self)
    }

    struct MembersResponse: Decodable {
        let chunk: [MatrixEvent]
    }

    /// Fetches the room's members, for naming rooms and attributing messages.
    ///
    /// Only the people in it now. Without the filter the server sends everyone who was ever
    /// a member — who left, who was removed, who was invited and never came — and all of them
    /// were counted, so a private chat that somebody else had once passed through looked like
    /// a group.
    public func members(of roomID: String) async throws -> [MatrixEvent] {
        let response: MembersResponse = try await send(
            .get,
            path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/members",
            query: [URLQueryItem(name: "membership", value: "join")]
        )
        return response.chunk
    }

    // MARK: - Creating

    struct CreateRoomRequest: Encodable {
        let isDirect: Bool
        let invite: [String]
        let preset: String

        enum CodingKeys: String, CodingKey {
            case isDirect = "is_direct"
            case invite, preset
        }
    }

    struct CreateRoomResponse: Decodable {
        let roomID: String
        enum CodingKeys: String, CodingKey { case roomID = "room_id" }
    }

    /// Accepts an invitation to a room.
    public func joinRoom(_ roomID: String) async throws {
        try await send(.post, path: "/_matrix/client/v3/join/\(roomID.pathEscaped)")
    }

    /// Turns an invitation down, or leaves a room you are in.
    ///
    /// Declining and leaving are the same call in Matrix: an invitation you refuse is a
    /// membership you end before it began.
    public func leaveRoom(_ roomID: String) async throws {
        try await send(.post, path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/leave")
    }

    /// Fetches a single event, for when the copy kept on the device is missing something.
    ///
    /// Everything a message needs normally arrives with it through sync. What doesn't is
    /// whatever the app didn't know to keep at the time — a video's preview picture, say,
    /// stored by no version of Chatman before this one. Rather than make people wait for the
    /// message to be sent again, it can be asked for.
    public func event(_ eventID: String, in roomID: String) async throws -> MatrixEvent {
        try await send(
            .get,
            path: "/_matrix/client/v3/rooms/\(roomID.pathEscaped)/event/\(eventID.pathEscaped)",
            as: MatrixEvent.self
        )
    }

    /// Starts a one-to-one conversation with someone.
    ///
    /// `is_direct` is what makes a bridge treat this as a private chat rather than creating a
    /// group on the other side, so it matters more here than the name suggests.
    public func startDirectMessage(with userID: String) async throws -> String {
        let body = CreateRoomRequest(isDirect: true, invite: [userID], preset: "trusted_private_chat")
        let response: CreateRoomResponse = try await send(
            .post, path: "/_matrix/client/v3/createRoom", body: body
        )
        return response.roomID
    }
}

extension String {
    /// Percent-encodes this string for use as a single URL path segment.
    var pathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .matrixPathSegment) ?? self
    }
}
