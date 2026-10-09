import Foundation
import SwiftData

#if canImport(UIKit)
import UIKit
#endif

extension ChatSession {

    // MARK: - Sending

    /// Sends a message, showing it immediately.
    ///
    /// The message appears in the conversation before the server has seen it and is replaced
    /// when it comes back through sync. That's what makes sending feel instant on a slow
    /// connection — which, on a watch over cellular, is most of the time. What happens if the
    /// connection isn't there is the outbox's business; see `ChatSession+Outbox`.
    public func send(
        _ text: String,
        to conversation: Conversation,
        replyingTo replyTarget: Message? = nil
    ) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let credentials else { return }

        let transactionID = MatrixAPI.transactionID()

        // The local copy is keyed by transaction ID. When the real event arrives it carries
        // the same ID in `unsigned`, which is how the two are matched up.
        let pending = Message(
            id: transactionID,
            sender: credentials.userID,
            timestamp: .now,
            body: body,
            kind: .text,
            replyToID: replyTarget?.id,
            isPending: true
        )
        queue(pending, in: conversation, preview: body)

        // A single emoji sent on its own is a reaction by other means, and counts towards
        // which one earns the seventh place. See `QuickReactions`.
        if body.count == 1, EmojiOnly.matches(body) { QuickReactions.note(body) }

        _ = await enqueue(transactionID)?.value
    }

    /// Adds an emoji reaction to a message.
    public func react(with emoji: String, to message: Message) async {
        guard let api, let conversation = message.conversation else { return }

        guard let me = credentials?.userID else { return }
        let target = message.id

        // Shown straight away, under a stand-in ID that no real event can have — real ones
        // start with `$`. It is counted as yours, so when the server sends the real event
        // back it is the same person with the same emoji, and still one reaction.
        let provisional = "~" + UUID().uuidString
        message.addReaction(emoji, by: me, event: provisional)
        noteCloseness(to: conversation, weight: 0.5)
        QuickReactions.note(emoji)
        saveContext()

        let answer: String?
        do {
            answer = try await api.sendReaction(emoji, to: target, in: conversation.id)
        } catch {
            answer = nil
        }

        // Looked up again rather than trusted: the wait was long enough for the message to
        // have been deleted by the sync, and a deleted model must not be touched.
        guard let current = self.message(id: target) else { return }
        if let answer {
            current.confirmReaction(provisional, as: answer)
        } else {
            current.removeReaction(event: provisional)
        }
        saveContext()
    }

    /// Deletes a message for everyone.
    ///
    /// Throws when the server did not take it back, and leaves the message where it is.
    /// It used to swallow that and delete it here anyway, so on a bad connection the message
    /// vanished from your screen while staying on everyone else's — an unsend that quietly
    /// did not happen, with nothing left to retry it from.
    public func delete(_ message: Message, forEveryone: Bool) async throws {
        guard let api, let conversation = message.conversation else { return }
        let target = message.id

        if forEveryone {
            try await api.redact(eventID: target, in: conversation.id)
        }

        // Looked up again: the server's own confirmation can come back through the sync
        // during that wait and take the message out first.
        guard let current = self.message(id: target) else { return }
        remove(current, from: conversation)
        saveContext()
    }

    // MARK: - Reading

    /// Marks a conversation as read, up to its most recent message.
    public func markRead(_ conversation: Conversation) async {
        // Opening a chat is the plainest "I have read this" there is, so it takes the
        // hand-placed mark off too. Without this the dot you put there yourself never came
        // off again: reading the chat cleared the count and left the flag, so the chat sat
        // there looking unread until you swiped it twice. Now that the flag is kept with the
        // account, that stuck dot would have followed you onto the watch and survived a
        // reinstall — so it is worth undoing where it is undone.
        if conversation.isManuallyUnread {
            setManuallyUnread(false, for: conversation)
        }

        // Fetched rather than walked. `conversation.messages` is the whole relationship, and
        // reading it loads every message in the room out of the store to find the newest —
        // on a conversation with thousands in it, on the way into that conversation, which
        // is exactly the moment that has to feel quick. The store can answer this with one
        // indexed query.
        //
        // The newest message the server actually has, which is not always the newest one
        // here. Something you just sent, or something that failed to send, is stored under
        // the phone's own transaction ID until the server's copy comes back — and a read
        // marker naming that ID points at an event that doesn't exist. The server refused
        // it without a word, the count here went to zero anyway, and the next sync put the
        // unread count and the watch's badge straight back. Real event IDs start with `$`.
        let room = conversation.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate {
                $0.conversation?.id == room
                    && !$0.isPending
                    && !$0.didFailToSend
                    && $0.id.starts(with: "$")
            },
            sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        // What was waiting is seen now, whatever the server has yet to say about it — and a
        // tap still sitting on the wrist for it has said what it had to.
        clearAttention(in: conversation)
        #if os(watchOS)
        WristTap.withdraw(for: conversation.id)
        #endif

        guard let api,
              let latest = try? container.mainContext.fetch(descriptor).first
        else {
            saveContext()
            return
        }

        conversation.unreadCount = 0
        saveContext()

        try? await api.markRead(upTo: latest.id, in: conversation.id)
    }

    /// Loads a page of older messages.
    ///
    /// - Returns: `false` when the start of the conversation has been reached.
    @discardableResult
    public func loadOlderMessages(in conversation: Conversation, limit: Int = 30) async -> Bool {
        guard let api, let token = conversation.previousBatch else { return false }

        do {
            let page = try await api.messages(in: conversation.id, from: token, limit: limit)

            for event in page.chunk where event.content.isMessage {
                addHistoricalMessage(event, to: conversation)
            }

            conversation.previousBatch = page.end
            saveContext()

            return page.end != nil && !page.chunk.isEmpty
        } catch {
            return false
        }
    }

    /// Tells the room you're typing.
    ///
    /// Does nothing on the watch: a request per keystroke to drive an indicator the watch
    /// doesn't show is exactly the kind of traffic that empties a battery.
    public func setTyping(_ isTyping: Bool, in conversation: Conversation) async {
        guard deviceProfile.sendsTypingNotifications,
              let api, let credentials
        else { return }

        try? await api.setTyping(isTyping, userID: credentials.userID, in: conversation.id)
    }

    // MARK: - Starting conversations

    /// Finds people to message.
    ///
    /// Returns bridged contacts alongside Matrix users, which is what lets a new chat start
    /// from a name instead of a command to a bot.
    public func searchPeople(matching term: String) async throws -> [Person] {
        guard let api else { throw MatrixError.notSignedIn }

        let results = try await api.searchPeople(matching: term)

        return results
            .filter { $0.userID != credentials?.userID }
            .filter { !BridgeIdentity.isBridgeBot($0.userID) }
            .map(Person.init)
    }

    /// Starts a one-to-one conversation and returns its ID.
    public func startConversation(with person: Person) async throws -> String {
        guard let api else { throw MatrixError.notSignedIn }

        let roomID = try await api.startDirectMessage(with: person.userID)

        // Insert it right away so the interface can navigate there without waiting a whole
        // sync cycle for the room to appear.
        if conversation(withID: roomID) == nil {
            let conversation = Conversation(
                id: roomID,
                name: person.name,
                isDirect: true,
                network: person.network,
                lastActivity: .now,
                directPartnerID: person.userID
            )
            insert(conversation)
            saveContext()
        }

        return roomID
    }

    /// Someone who can be messaged.
    public struct Person: Identifiable, Hashable, Sendable {
        public let userID: String
        public let name: String
        public let avatarURL: String?
        public let network: ChatNetwork

        public var id: String { userID }

        init(_ user: MatrixAPI.DirectoryUser) {
            userID = user.userID
            network = BridgeIdentity.network(of: user.userID)

            let raw = user.displayName?.isEmpty == false
                ? user.displayName!
                : String(BridgeIdentity.localpart(of: user.userID))
            name = BridgeIdentity.cleanDisplayName(raw, network: network)

            avatarURL = user.avatarURL
        }
    }

    // MARK: - Media

    /// A request for a picture at a size worth downloading.
    ///
    /// Always prefer this over the full-size version in lists and bubbles: on cellular the
    /// difference between a thumbnail and an original is the difference between kilobytes and
    /// megabytes.
    ///
    /// `crop` matters more than it looks. A homeserver only keeps the sizes it was configured
    /// to make — Synapse's own defaults are 32 and 96 square for cropping, and 320, 640 and
    /// 800 wide for scaling — and it answers with the nearest one it has of the kind asked
    /// for. Asking to crop at 800 therefore gets a 96-pixel square back: the right shape and
    /// a sixteenth of the detail, which is exactly how a photo ends up looking like gravel.
    public func thumbnailRequest(
        for message: Message, width: Int, height: Int, crop: Bool = false
    ) -> URLRequest? {
        guard let url = message.mediaURL else { return nil }
        return api?.thumbnailRequest(for: url, width: width, height: height, crop: crop)
    }

    /// The still to show for an attachment before anyone touches it.
    ///
    /// Which address that comes from depends on what was sent. A photo scales from itself. A
    /// video can't: Synapse thumbnails pictures only, so asking it to scale an MP4 comes back
    /// empty — and an empty answer is why a film, and every GIF that WhatsApp and Signal turn
    /// into one, used to sit under a spinner that never stopped. What a video does carry is a
    /// still of its own, uploaded beside it, and that is what gets scaled here.
    public func previewRequest(for message: Message, width: Int, height: Int) -> URLRequest? {
        if message.kind == .video {
            guard let still = message.mediaThumbnailURL else { return nil }
            return api?.thumbnailRequest(for: still, width: width, height: height, crop: false)
        }

        // A GIF sent as a picture is still a picture as far as the server is concerned, and
        // it will happily scale one frame of it — which is what to show if the moving version
        // turns out to be too big to be worth downloading.
        return thumbnailRequest(for: message, width: width, height: height)
    }

    /// Fills in what an older stored message never learned.
    ///
    /// Videos and GIFs stopped working for everything already on the device when the app
    /// started keeping a video's own preview picture: the messages were stored before that
    /// field existed, so every one of them looked like a video with no preview — which is
    /// exactly the case that can't be drawn. Asking the server for the event again is far
    /// cheaper than downloading the film, and it only ever happens once per message.
    @discardableResult
    public func refreshAttachment(_ message: Message) async -> Bool {
        guard let api, let roomID = message.conversation?.id, message.mediaURL != nil else {
            return false
        }

        guard let event = try? await api.event(message.id, in: roomID),
              let media = event.content.media
        else { return false }

        var changed = false

        if message.mediaThumbnailURL != media.thumbnailURL, media.thumbnailURL != nil {
            message.mediaThumbnailURL = media.thumbnailURL
            changed = true
        }
        if message.isAnimated != media.isAnimated, media.isAnimated {
            message.isAnimated = true
            changed = true
        }
        if message.mediaMimeType == nil, media.mimeType != nil {
            message.mediaMimeType = media.mimeType
            changed = true
        }
        if message.mediaWidth == nil { message.mediaWidth = media.width }
        if message.mediaHeight == nil { message.mediaHeight = media.height }

        return changed
    }

    /// A request for the bytes an animation has to be played from.
    ///
    /// There is no scaled-down version of a moving picture on the server — a thumbnail is one
    /// frame and holds still — so this is the whole file, which is also why it's only asked
    /// for when something is actually going to play it.
    public func animatedSourceRequest(for message: Message) -> URLRequest? {
        guard message.isAnimated, let url = message.mediaURL else { return nil }
        return api?.mediaRequest(for: url)
    }

    /// A request that loads an attachment at full size, for viewing on its own.
    public func fullSizeRequest(for message: Message) -> URLRequest? {
        guard let url = message.mediaURL else { return nil }
        return api?.mediaRequest(for: url)
    }

    /// A request for an avatar.
    public func avatarRequest(for conversation: Conversation, size: Int) -> URLRequest? {
        guard let url = conversation.avatarURL else { return nil }
        return api?.thumbnailRequest(for: url, width: size, height: size)
    }
}

// MARK: - Bridges

extension ChatSession {

    /// Who is typing in this conversation, by name, ready to put on screen.
    public func typingNames(in conversation: Conversation) -> [String] {
        (typingByRoom[conversation.id] ?? []).map { account in
            customAccountNames[account]
                ?? contactNamesByAccount[account]
                ?? memberNames[account]
                ?? BridgeIdentity.cleanDisplayName(
                    String(BridgeIdentity.localpart(of: account)),
                    network: BridgeIdentity.network(of: account)
                )
        }
    }

    /// The line to show under a conversation while somebody is writing.
    public func typingSummary(in conversation: Conversation) -> String? {
        let names = typingNames(in: conversation)

        switch names.count {
        case 0: return nil
        case 1: return conversation.isGroup ? "\(names[0]) is typing…" : "typing…"
        case 2: return "\(names[0]) and \(names[1]) are typing…"
        default: return "\(names.count) people are typing…"
        }
    }

    // MARK: - What a conversation is worth

    /// Keeps a conversation at the top of the list, or lets it back into the flow.
    public func setPinned(_ pinned: Bool, for conversation: Conversation) {
        conversation.isPinned = pinned
        try? container.mainContext.save()

        // As a favourite, which is the tag every Matrix client uses for a chat lifted to the
        // top. Written to the account rather than to this device, so the watch sees the same
        // order without being told about it separately.
        guard let api, let userID = credentials?.userID else { return }
        let room = conversation.id

        Task {
            if pinned {
                try? await api.tagRoom(room, as: "m.favourite", for: userID)
            } else {
                try? await api.untagRoom(room, as: "m.favourite", for: userID)
            }
        }
    }

    /// Marks a conversation unread by hand, or clears that.
    ///
    /// Kept with the account, under the type other Matrix clients settled on, so a chat put
    /// back on the pile here is on the pile on the watch too — and in Element, for that
    /// matter. It travels no further than Matrix: no bridge carries this to WhatsApp or
    /// Signal, and none of those networks has the idea in the first place.
    public func setManuallyUnread(_ unread: Bool, for conversation: Conversation) {
        conversation.isManuallyUnread = unread
        try? container.mainContext.save()
        publishUnreadCount()

        guard let api, let userID = credentials?.userID else { return }
        let room = conversation.id

        Task {
            try? await api.setRoomAccountData(
                MatrixAPI.MarkedUnread(unread: unread),
                type: "m.marked_unread",
                room: room,
                for: userID
            )
        }
    }

    /// Silences a conversation, or stops silencing it.
    ///
    /// Done on the server rather than in the app, so it holds for every device you own and
    /// for notifications that arrive while Chatman isn't running.
    public func setMuted(_ muted: Bool, for conversation: Conversation) async {
        conversation.isMuted = muted
        try? container.mainContext.save()

        guard let api else { return }
        if muted {
            try? await api.muteRoom(conversation.id)
        } else {
            try? await api.unmuteRoom(conversation.id)
        }
    }

    /// Whether this conversation should show as having something waiting.
    public func isWaiting(_ conversation: Conversation) -> Bool {
        conversation.unreadCount > 0 || conversation.isManuallyUnread
    }

    // MARK: - Keeping the list short

    /// Puts a conversation away without touching a message in it.
    ///
    /// Written here first so the list moves under your finger, and told to the server after,
    /// as a room tag. That tag is what makes the drawer the same drawer everywhere: the
    /// watch keeps its own database and has no way of hearing about a flag that only ever
    /// existed on the phone, which is exactly the way it used to be.
    public func setArchived(_ archived: Bool, for conversation: Conversation) {
        conversation.isArchived = archived
        try? container.mainContext.save()
        publishUnreadCount()

        guard let api, let userID = credentials?.userID else { return }
        let room = conversation.id

        Task {
            if archived {
                try? await api.tagRoom(room, as: "m.low_priority", for: userID)
            } else {
                try? await api.untagRoom(room, as: "m.low_priority", for: userID)
            }
        }
    }

    /// Tells the server about the things that were decided before it was being told.
    ///
    /// Archiving, pinning and names you chose yourself all used to live in this device's
    /// database and nowhere else, so an account can carry a drawer full of chats the server
    /// has never heard of — and a watch that will never hear of them either. This walks that
    /// list once and writes what it finds. Afterwards the account is the truth and this does
    /// nothing.
    public func publishLocalChoices() async {
        guard profile == .phone, !defaults.bool(forKey: "publishedLocalChoices") else { return }
        guard let api, let userID = credentials?.userID else { return }

        let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []

        for conversation in all {
            let room = conversation.id

            if conversation.isArchived {
                try? await api.tagRoom(room, as: "m.low_priority", for: userID)
            }

            if conversation.isPinned {
                try? await api.tagRoom(room, as: "m.favourite", for: userID)
            }

            if conversation.isManuallyUnread {
                try? await api.setRoomAccountData(
                    MatrixAPI.MarkedUnread(unread: true),
                    type: "m.marked_unread", room: room, for: userID
                )
            }

            if let chosen = conversation.customName, !chosen.isEmpty {
                try? await api.setRoomAccountData(
                    MatrixAPI.ChosenName(name: chosen),
                    type: "nl.chatman.name", room: room, for: userID
                )
            }
        }

        defaults.set(true, forKey: "publishedLocalChoices")
    }

    /// How many conversations are tucked away.
    public var archivedCount: Int {
        let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []
        return all.filter { $0.isArchived && !isHidden($0) }.count
    }

    // MARK: - Passing something on

    /// Sends a message you already have into another conversation.
    ///
    /// A picture doesn't travel through the phone to do this: it already lives on your own
    /// server, so what gets sent is the same address again. The bridge on the other end picks
    /// it up from there and hands it to whichever network that conversation belongs to —
    /// which is what makes forwarding across two different services work at all.
    public func forward(_ message: Message, to conversation: Conversation) async throws {
        switch message.kind {
        case .image, .video, .audio, .file, .sticker:
            guard let url = message.mediaURL else {
                await send(message.body, to: conversation)
                return
            }

            try await sendExistingMedia(url, like: message, to: conversation)

        case .poll:
            // A poll can't be asked twice from here, but what it asked can be passed on.
            let options = (message.poll?.answers ?? []).map { "• " + $0.text }
            await send((["📊 " + message.body] + options).joined(separator: "\n"), to: conversation)

        case .text, .emote, .notice, .encrypted:
            // The quoted original of a reply doesn't belong in somebody else's conversation.
            await send(ReplyFallback.strip(message.body), to: conversation)
        }
    }

    /// Puts an attachment that already exists into another conversation.
    ///
    /// Throws only when it plainly didn't go. Waiting for a connection isn't failing: the
    /// stand-in sits in the other conversation saying "Sending…" and goes when it can.
    private func sendExistingMedia(
        _ mxcURL: String, like original: Message, to conversation: Conversation
    ) async throws {
        guard let credentials else { throw MatrixError.notSignedIn }

        let transactionID = MatrixAPI.transactionID()

        // Shown straight away, like anything else you send.
        let pending = Message(
            id: transactionID,
            sender: credentials.userID,
            timestamp: .now,
            body: original.body,
            kind: original.kind,
            mediaURL: mxcURL,
            mediaWidth: original.mediaWidth,
            mediaHeight: original.mediaHeight,
            mediaMimeType: original.mediaMimeType,
            mediaThumbnailURL: original.mediaThumbnailURL,
            isAnimated: original.isAnimated,
            isPending: true
        )
        pending.isVoice = original.isVoice
        pending.mediaDuration = original.mediaDuration
        pending.waveformBlob = original.waveformBlob
        queue(pending, in: conversation, preview: Self.preview(of: pending))

        if await enqueue(transactionID)?.value == .failed {
            throw MatrixError.decoding(String(localized: "It didn't go through. It's marked in that chat, to try again.", bundle: .module))
        }
    }

    /// The line the list shows for something you just sent.
    static func preview(of message: Message) -> String {
        switch message.kind {
        case .image: message.caption ?? (message.isAnimated ? "GIF" : String(localized: "Photo", bundle: .module))
        case .video: message.caption ?? (message.isAnimated ? "GIF" : String(localized: "Video", bundle: .module))
        case .audio: message.isVoice ? "Voice message" : message.body
        case .sticker: String(localized: "Sticker", bundle: .module)
        case .poll: "📊 " + message.body
        default: message.body
        }
    }

    /// Everything reachable, for a "send this to…" list.
    public func forwardTargets() -> [Conversation] {
        let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []

        // The people you actually talk to first, then everything else by how recent it is.
        // A busy group you never write in used to sit at the top because it was busy.
        let now = Date.now
        return all
            .filter { !isHidden($0) }
            .sorted { first, second in
                let a = Closeness.current(first, now: now)
                let b = Closeness.current(second, now: now)
                if abs(a - b) > 0.05 { return a > b }
                return first.lastActivity > second.lastActivity
            }
    }

    // MARK: - Finding things

    /// One thing worth showing for a search.
    public enum SearchResult: Identifiable, Hashable {
        case conversation(Conversation)
        case message(Message)

        public var id: String {
            switch self {
            case .conversation(let conversation): "c:" + conversation.id
            case .message(let message): "m:" + message.id
            }
        }
    }

    /// Conversations whose name matches, and messages whose words do.
    ///
    /// People first, always. Searching a messaging app is nearly always looking for a person
    /// rather than for a sentence, and a name buried under forty messages that happen to
    /// contain the same letters is a name nobody finds.
    public func search(_ text: String, limit: Int = 40) -> (
        conversations: [Conversation], messages: [Message]
    ) {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return ([], []) }

        let context = container.mainContext
        let all = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        let visible = all.filter { !isHidden($0) }

        let conversations = visible
            .filter { displayName(for: $0).localizedCaseInsensitiveContains(needle) }
            .sorted { $0.lastActivity > $1.lastActivity }

        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate { $0.body.localizedStandardContains(needle) },
            sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit

        let hidden = Set(all.filter { isHidden($0) }.map(\.id))
        let messages = ((try? context.fetch(descriptor)) ?? [])
            .filter { message in
                guard let room = message.conversation?.id else { return false }
                return !hidden.contains(room)
            }

        return (conversations, messages)
    }

    /// The networks Chatman can set up from the interface.
    ///
    /// Every bridge mautrix builds in Go answers the same provisioning interface, so the app
    /// needs nothing network-specific to log into any of them — which is why they're all
    /// here rather than only the two that have been tried. What differs is what each one asks
    /// for: a code to scan, a phone number, a page to sign in on. That difference is the
    /// bridge's to describe and this app's to render, and it does.
    ///
    /// The order is the order people are likely to want them, not the order they were added.
    public static let configurableNetworks: [ChatNetwork] = [
        .signal, .whatsapp, .telegram, .facebook, .instagram, .discord, .slack,
        .gmessages, .gvoice, .twitter, .linkedin, .bluesky, .irc, .zulip
    ]

    /// The networks worth asking about on this server.
    ///
    /// A bridge that isn't installed answers nothing, and there is no point asking it again
    /// every time the app opens. This is emptied on sign-out, so a server that gains a bridge
    /// only needs the app restarted rather than reinstalled.
    public var availableNetworks: [ChatNetwork] {
        Self.configurableNetworks.filter { !missingNetworks.contains($0) }
    }

    /// Whether a bridge for this network is actually running on the server.
    ///
    /// Used to say so on the connect screen rather than letting someone tap a network that
    /// will never answer.
    public func isInstalled(_ network: ChatNetwork) -> Bool {
        installedNetworks.contains(network)
    }

    /// Remembers that a bridge isn't there, but only when the server said so.
    ///
    /// A refused connection or a timeout means the phone couldn't ask, not that the answer
    /// was no — marking a bridge missing on those would make one bad moment on the train look
    /// like an uninstalled bridge for the rest of the session.
    private func noteBridgeAbsence(_ error: any Error, on network: ChatNetwork) {
        guard let matrix = error as? MatrixError else { return }

        switch matrix {
        // Nothing at that address. A 502 or 503 used to count too, and it means the opposite:
        // the server knows the bridge and couldn't get an answer out of it. Counting that as
        // "no bridge here" is how a WhatsApp in trouble came to say "No WhatsApp bridge yet".
        case .unexpectedStatus(404):
            missingNetworks.insert(network)
        case .decoding:
            // What a reverse proxy sends when nothing is listening on that path: a page,
            // where JSON was expected.
            missingNetworks.insert(network)
        default:
            break
        }
    }

    /// What a bridge said the last time it was asked, in a few words, for the settings.
    ///
    /// The one thing that tells a broken bridge apart from a broken app, and it used to be
    /// visible nowhere: everything a bridge answers is reduced to "connected" or not.
    public struct BridgeAnswer: Sendable, Hashable {
        public let at: Date
        public let summary: String
    }

    /// One look at the bridges: which were asked, and whether all of them have answered.
    ///
    /// A look that never ends leaves every answer as it was, and from the outside that can't
    /// be told apart from a bridge that isn't asked at all.
    public struct BridgeRound: Sendable {
        public let started: Date
        public let asked: [ChatNetwork]
        public internal(set) var finished: Date?
    }

    /// Writes down what one bridge said, as soon as it says it.
    ///
    /// Not at the end of the round, as it used to be: a bridge that took its time held back
    /// every other bridge's answer with it.
    private func note(_ answer: Result<MatrixAPI.BridgeWhoami, any Error>, from network: ChatNetwork) {
        let summary = switch answer {
        case .success(let whoami) where whoami.logins.isEmpty:
            "Answered: no account signed in"
        case .success(let whoami):
            "Answered: " + whoami.logins.map { $0.state.stateEvent.lowercased() }.joined(separator: ", ")
        case .failure(let error):
            Self.describe(error)
        }
        bridgeQuestions[network] = nil
        bridgeAnswers[network] = BridgeAnswer(at: .now, summary: summary)
    }

    /// Whether this bridge didn't answer the last time it was asked.
    public func isUnanswered(_ network: ChatNetwork) -> Bool {
        unansweredNetworks.contains(network)
    }

    private static func describe(_ error: any Error) -> String {
        switch error as? MatrixError {
        case .unexpectedStatus(let status): "No answer: HTTP \(status)"
        case .api(let response): "Refused: \(response.errcode)"
        case .decoding: "Answered with something that isn't a bridge"
        case .network(let failure): "Not reached: \(failure.localizedDescription)"
        case nil where error is DeadlinePassed: "No answer within 15 seconds"
        default: "No answer: \(error.localizedDescription)"
        }
    }

    /// The address of a bridge's control account on your own server.
    public func bridgeBotID(for network: ChatNetwork) -> String? {
        guard let credentials, let localpart = network.botLocalpart else { return nil }

        let parts = credentials.userID.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        return "@\(localpart):\(parts[1])"
    }

    /// The existing conversation with a bridge's control account, if one has been started.
    ///
    /// Its presence is what the settings screen uses to tell "not set up yet" from "already
    /// linked" — asking the bridge itself would mean a round trip for a screen that should
    /// open instantly.
    public func bridgeConversation(for network: ChatNetwork) -> Conversation? {
        guard let botID = bridgeBotID(for: network) else { return nil }

        let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []
        return all.first { $0.directPartnerID == botID }
    }

    /// Opens the conversation with a bridge's control account, creating it if needed.
    ///
    /// The one place in Chatman where you talk to a bot instead of a person. Linking an
    /// account has to happen somewhere, and a button in Settings beats expecting people to
    /// look up an address they had no way of knowing. Every other client makes you type it.
    ///
    /// An existing room is reused: `createRoom` makes a new one on every call, so without
    /// this a second tap would leave a duplicate behind.
    @discardableResult
    public func openBridgeChat(for network: ChatNetwork) async throws -> Conversation {
        guard let api else { throw MatrixError.notSignedIn }
        guard let botID = bridgeBotID(for: network) else { throw MatrixError.invalidHomeserver }

        if let existing = bridgeConversation(for: network) { return existing }

        let roomID = try await api.startDirectMessage(with: botID)

        if let existing = conversation(withID: roomID) { return existing }

        let conversation = Conversation(
            id: roomID,
            name: network.displayName,
            isDirect: true,
            network: network,
            lastActivity: .now,
            directPartnerID: botID
        )

        insert(conversation)
        saveContext()

        return conversation
    }
}

extension ChatSession {

    /// Starts connecting a chat account, as a screen instead of a bot conversation.
    public func beginBridgeLogin(for network: ChatNetwork) -> BridgeLogin? {
        guard let api, let credentials else { return nil }
        return BridgeLogin(api: api, network: network, userID: credentials.userID)
    }
}

extension ChatSession {

    /// How a bridged account is doing.
    public struct BridgeAccount: Sendable, Hashable {

        public enum Status: Sendable, Hashable {
            case connecting
            case connected
            /// Temporarily unreachable; the bridge is retrying by itself.
            case reconnecting
            /// The link is dead and has to be made again.
            case loggedOut(String?)
            case failed(String?)

            /// From the bridge's own word for it. Every word mautrix uses is placed, so that
            /// only something genuinely unexpected reads as "not working".
            init(stateEvent: String, message: String?) {
                switch stateEvent {
                case "CONNECTED", "BACKFILLING": self = .connected
                // Starting up, or not reported on yet: on its way, not broken.
                case "CONNECTING", "STARTING", "UNKNOWN": self = .connecting
                case "TRANSIENT_DISCONNECT", "BRIDGE_UNREACHABLE": self = .reconnecting
                case "BAD_CREDENTIALS", "LOGGED_OUT": self = .loggedOut(message)
                default: self = .failed(message)
                }
            }
        }

        /// What the network calls this account. For Signal, your phone number.
        public let name: String?
        public let status: Status
    }

    /// Asks each bridge how it's doing and which rooms are its own bookkeeping.
    ///
    /// Both answers come from one request. The rooms are kept out of the chat list, and the
    /// status is what tells "connected" apart from "silently logged out days ago" — a
    /// difference the interface hid until now.
    ///
    /// Failures are ignored on purpose: a bridge that can't be reached is not a reason to put
    /// an error in front of someone who only wanted to open their messages.
    public func refreshBridges() async {
        guard let api, let credentials else { return }

        var hidden = hiddenRoomIDs
        var accounts = bridgeAccounts
        var mine = selfAccounts

        // Every network, every time. Skipping the ones that said "no such bridge" saved a dozen
        // answers of a few milliseconds each, and it was one more way for a bridge that is
        // there to go unasked for the rest of the day.
        let asking = Set(Self.configurableNetworks)
        let started = Date.now
        bridgeRound = BridgeRound(started: started, asked: ChatNetwork.allCases.filter(asking.contains))
        for network in asking {
            bridgeQuestions[network] = started
        }

        // All at once. Chatman offers every network mautrix bridges, and most servers run two
        // or three of them — asking fourteen questions one after another would make opening
        // the app wait on thirteen answers nobody is interested in.
        let answers = await withTaskGroup(
            of: (ChatNetwork, Result<MatrixAPI.BridgeWhoami, any Error>).self
        ) { group in
            for network in asking {
                // Copied into a constant and named in every capture list, on purpose. Captured
                // implicitly, the optimised build handed WhatsApp's answer back labelled as
                // Signal's — measured on the phone, never in a debug build — so the settings
                // had Signal twice and WhatsApp never, for days. Each task now carries its
                // own network, and says which one it answers for.
                let asked = network
                group.addTask { [asked, api, credentials] in
                    do {
                        // Never longer than this, whatever the network does. See `withDeadline`.
                        let whoami = try await withDeadline(seconds: 15) { [asked, api, credentials] in
                            try await api.bridgeWhoami(as: credentials.userID, on: asked)
                        }
                        return (asked, .success(whoami))
                    } catch {
                        return (asked, .failure(error))
                    }
                }
            }

            var collected: [(ChatNetwork, Result<MatrixAPI.BridgeWhoami, any Error>)] = []
            for await answer in group {
                note(answer.1, from: answer.0)
                collected.append(answer)
            }
            return collected
        }
        if bridgeRound?.started == started { bridgeRound?.finished = .now }

        var unanswered: Set<ChatNetwork> = []
        for (network, answer) in answers {
            guard case .success(let whoami) = answer else {
                if case .failure(let error) = answer {
                    noteBridgeAbsence(error, on: network)
                }
                unanswered.insert(network)
                continue
            }

            installedNetworks.insert(network)
            missingNetworks.remove(network)

            hidden.formUnion(whoami.housekeepingRooms)

            if let login = whoami.logins.first {
                accounts[network] = BridgeAccount(
                    name: login.name,
                    status: .init(stateEvent: login.state.stateEvent, message: login.state.message)
                )
            } else {
                accounts[network] = nil
            }

            // The bridge represents you on the other side with an account of your own. It
            // looks like any other contact, so it has to be named explicitly to be excluded.
            if let domain = credentials.userID.split(separator: ":", maxSplits: 1).last,
               let prefix = network.ghostPrefix {
                for login in whoami.logins {
                    mine.insert("@\(prefix)\(login.id):\(domain)")
                }
            }
        }

        hiddenRoomIDs = hidden
        bridgeAccounts = accounts
        selfAccounts = mine
        unansweredNetworks = unanswered
        noteConnectedNetworks()
        noteReconnecting()
        recheckSoonIfUnanswered()

        // By now the rooms are known, which is the earliest the server can be told to keep
        // quiet about the one nobody wants to hear from.
        await applyStatusBroadcastRule()
    }

    /// Works out which service a conversation belongs to, when the sync didn't say.
    ///
    /// Sync uses lazy loading: it only sends the members who happen to have spoken in the
    /// events it returned. In a chat where you spoke last, no bridged account appears at all,
    /// and the conversation looks like plain Matrix. Asking for the member list settles it —
    /// once per room, and only for rooms still unaccounted for.
    public func identifyUnknownNetworks() async {
        guard let api, let credentials else { return }

        // One count at a time. The tidy-up and a sync that brought new rooms can both get
        // here, and two passes over the same list would ask for every room's members twice.
        guard !isCountingRooms else { return }
        isCountingRooms = true
        defer { isCountingRooms = false }

        // Once per room, as it says above — which it wasn't. `directPartnerID` is only ever
        // set for a private chat, so every group matched this every time, and every time the
        // list opened each group's whole member list came down again: on the watch, over
        // cellular. A room is unaccounted for until its members have been counted once.
        //
        // Except once, for everything. The counts already stored were made when the member
        // list still included everyone who had ever been in a room — who left, who was
        // removed, who was invited and never came. A private chat that somebody else had
        // once passed through was counted as a group, and with only uncounted rooms looked
        // at from now on, it would have stayed one. So every room is counted again, one
        // time, the new way.
        let countedWith = defaults.integer(forKey: "chatman.memberCounting")
        let recountAll = countedWith < Self.memberCounting

        let unknown = ((try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? [])
            .filter {
                (recountAll || $0.otherMemberCount == 0)
                    && !hiddenRoomIDs.contains($0.id)
            }

        // Rooms that couldn't be asked this time. The full recount only counts as done when
        // none were missed, or a room that failed would keep its old, wrong count for good.
        var missed = 0

        for conversation in unknown {
            guard let members = try? await api.members(of: conversation.id) else {
                missed += 1
                continue
            }

            // The names come free with this request and were being thrown away. Without them
            // a group shows no sender, because sync only sends the members who happened to
            // speak in the events it returned.
            for member in members {
                guard let id = member.stateKey,
                      case .membership(let details) = member.content
                else { continue }

                note(id, name: details.displayName, avatar: details.avatarURL)
            }

            // `isSelf` and not just the Matrix ID: the bridge also represents you with an
            // account of its own, and counting that as a second person turns every private
            // chat into a group.
            //
            // Only people in the room now. The request already asks for exactly that; this
            // holds even if a server ignores the question and sends everyone who ever passed
            // through, which is what made private chats look like groups.
            let others = members
                .filter {
                    guard case .membership(let details) = $0.content else { return false }
                    return details.state == .join
                }
                .compactMap(\.stateKey)
                .filter { !isSelf($0) && !BridgeIdentity.isBridgeBot($0) }

            if conversation.network == .matrix,
               let network = others.map(BridgeIdentity.network(of:)).first(where: { $0 != .matrix }) {
                conversation.network = network
            }

            conversation.otherMemberCount = Set(others).count

            // Exactly one other person means a private chat, whatever `m.direct` says — and
            // it's what lets this conversation be matched to an address book entry later.
            if Set(others).count == 1, conversation.directPartnerID == nil {
                conversation.directPartnerID = others[0]
                conversation.isDirect = true
            }
        }

        saveContext()
        // Kept now rather than with the next sync: a watch app can be put away before that.
        saveMemberDetails()

        if recountAll, missed == 0, !Task.isCancelled {
            defaults.set(Self.memberCounting, forKey: "chatman.memberCounting")
        }
    }

    /// Counts the members of rooms that have just arrived, straight away.
    ///
    /// Whether a conversation is a group, and what everybody in it is called, is only known
    /// once its members have been counted. Until then a group looks like a private chat, and
    /// nobody's name or face is over their messages. The counting used to wait for the
    /// half-hourly tidy-up — and on a fresh install the first tidy-up runs at launch, before
    /// the first sync has brought a single room. It found nothing to count, and the next one
    /// was half an hour away: for that half hour every group on the watch was a column of
    /// messages from nobody.
    ///
    /// Still once per room. Only rooms that were never counted are asked about, so after the
    /// first sync this settles down to nothing.
    func countNewRoomsIfNeeded() {
        // Already counting: left set, so the next sync tries again. The pass under way chose
        // its rooms before these arrived.
        guard hasUncountedRooms, !isCountingRooms else { return }
        hasUncountedRooms = false
        Task { await identifyUnknownNetworks() }
    }

    /// Which way of counting members the stored counts were made with. Raised when the
    /// counting changes, so every room is counted once more the new way.
    private static let memberCounting = 2

    /// Replaces network-chosen names with the ones from this device's address book.
    ///
    /// Only names. A picture someone set on Signal is a picture they chose to show you, and it
    /// stays; the address book fills in only where there is none. Names work the other way
    /// round, because a handle like "bdbkyra" is a username, not what you call someone.
    ///
    /// Nothing is written to the server and no contact leaves the device: the bridge is asked
    /// which phone number belongs to which bridged account, and the matching happens here.
    public func applyDeviceContacts() async {
        #if canImport(Contacts)
        guard let api, let credentials, ContactBook.isAuthorised else { return }

        let people = ContactBook.peopleByPhoneNumber()
        guard !people.isEmpty else { return }

        // Bridged account -> phone numbers, straight from the bridge. A contact can have
        // several, and the one your address book knows isn't always the first.
        var numbersByAccount: [String: [String]] = [:]
        for network in availableNetworks {
            guard let contacts = try? await api.bridgeContacts(as: credentials.userID, on: network)
            else { continue }

            for contact in contacts {
                guard let mxid = contact.mxid, !contact.phoneNumbers.isEmpty else { continue }
                numbersByAccount[mxid] = contact.phoneNumbers
            }
        }

        guard !numbersByAccount.isEmpty else { return }

        var names: [String: String] = [:]
        var byAccount: [String: String] = [:]
        var photos: [String: Data] = [:]
        var withPartner = 0

        let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []

        for conversation in all where !hiddenRoomIDs.contains(conversation.id) {
            // Only a one-to-one. A group has a name of its own, and in a group where just
            // one member happens to be in your address book, this would rename the whole
            // conversation after that person.
            //
            // Either signal counts: the member count when it's known, and the room's own
            // `is_direct` flag when it isn't. Insisting on the count alone left every chat
            // whose members hadn't been counted yet showing whatever name the network had.
            guard conversation.otherMemberCount == 1
                || (conversation.otherMemberCount == 0 && conversation.isDirect)
            else { continue }

            guard let partner = partnerAccount(of: conversation, knownTo: numbersByAccount)
            else { continue }

            withPartner += 1

            guard let numbers = numbersByAccount[partner],
                  let person = numbers.lazy
                      .map({ ContactBook.comparable($0) })
                      .compactMap({ people[$0] })
                      .first
            else { continue }

            names[conversation.id] = person.name
            byAccount[partner] = person.name

            // Sent whether or not the network has a picture of its own. The watch prefers
            // the network's, but when that can't be fetched this is what it falls back to —
            // and initials where a face should be is exactly what people notice.
            if let image = person.imageData {
                photos[conversation.id] = image
            }
        }

        // A name set by hand outranks the address book, and has to travel to the watch the
        // same way — over there this dictionary is the only source of names there is.
        for conversation in all {
            if let custom = conversation.customName, !custom.isEmpty {
                names[conversation.id] = custom
            }
            if let photo = conversation.customPhoto {
                photos[conversation.id] = photo
            }
        }

        // Which ones didn't match, by the name they're stuck with. This is the list that
        // answers "why is this one still called that" without guesswork.
        unmatchedConversations = all
            .filter { conversation in
                guard !isHidden(conversation) else { return false }
                guard conversation.otherMemberCount == 1
                    || (conversation.otherMemberCount == 0 && conversation.isDirect)
                else { return false }
                return names[conversation.id] == nil
            }
            .map { $0.displayName }
            .sorted()

        contactNames = names
        contactNamesByAccount = byAccount
        contactPhotos = photos
        matchStats = MatchStats(
            conversations: all.count - hiddenRoomIDs.count,
            withKnownAccount: withPartner,
            matched: names.count,
            addressBook: people.count
        )

        // The watch has its own copy of the conversations but no way to read these contacts,
        // so it's told the result rather than asked to work it out again — names and faces
        // both, because on that side there is no address book to fall back on.
        shareNamesWithWatch()
        #endif
    }

    /// The bridged account on the other side of a conversation.
    ///
    /// `m.direct` is the official answer and is often simply absent, so the senders of what's
    /// already been said are used as a second source. Without this, a chat whose partner was
    /// never recorded can never be matched to an address book entry.
    func partnerAccount(
        of conversation: Conversation, knownTo accounts: [String: [String]]
    ) -> String? {
        if let partner = conversation.directPartnerID,
           accounts[partner] != nil,
           !isSelf(partner) {
            return partner
        }

        // Two traps here, and both produce a confidently wrong name. Your own bridged account
        // is in the contact list too, with your own number — so a chat where you spoke last
        // would be named after you. And a group has many senders, so picking the first would
        // name the group after whoever happened to talk most recently. Only a conversation
        // with exactly one other party can be identified this way.
        let others = Set(
            recentSenders(in: conversation, limit: 200)
                .filter { accounts[$0] != nil && !isSelf($0) }
        )

        return others.count == 1 ? others.first : nil
    }

    /// Whether an account is one of yours rather than someone else's.
    public func isSelf(_ account: String) -> Bool {
        account == credentials?.userID || selfAccounts.contains(account)
    }

    /// Whether you wrote this message, whichever account it went out under.
    ///
    /// Not just your Matrix ID. Anything you sent from Signal or WhatsApp itself arrives
    /// under the account the bridge created for you, and judging by the Matrix ID alone puts
    /// your own words on the left as though a stranger had said them — the "me is not me"
    /// problem, which double puppeting fixes going forward but not for what's already stored.
    public func isMine(_ message: Message) -> Bool {
        isSelf(message.sender)
    }

    /// What the last matching run managed.
    public struct MatchStats: Sendable, Equatable {
        public var conversations = 0
        public var withKnownAccount = 0
        public var matched = 0
        public var addressBook = 0
    }

    /// Asks for the address book if that hasn't been decided, then applies it.
    ///
    /// Asked for once the list is on screen rather than at launch, so the reason is visible
    /// when the question appears. Refusing is fine and never asked again — the app simply
    /// keeps the names the networks provide.
    public func refreshContacts() async {
        #if canImport(Contacts)
        guard profile == .phone else { return }
        guard await ContactBook.requestAccess() else { return }
        await applyDeviceContacts()
        #endif
    }

    /// Hands the watch the names and faces it can't work out for itself.
    ///
    /// Called on its own as well as at the end of a match, because the two aren't the same
    /// thing: a name you chose by hand exists whether or not the address book was ever read.
    func shareNamesWithWatch() {
        #if canImport(WatchConnectivity)
        let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []

        var names = contactNames
        var photos = contactPhotos

        for conversation in all {
            if let custom = conversation.customName, !custom.isEmpty {
                names[conversation.id] = custom
            }
            if let photo = conversation.customPhoto {
                photos[conversation.id] = photo
            }
        }

        SessionLink.shared.shareContactNames(names)
        SessionLink.shared.sharePhotos(Self.thumbnails(from: photos))
        SessionLink.shared.shareSenderNames(
            contactNamesByAccount.merging(customAccountNames) { _, mine in mine }
        )
        #endif
    }

    /// The address-book pictures, shrunk to what a watch can be sent.
    ///
    /// An application context carries a few hundred kilobytes in total for everything in it,
    /// and a contact thumbnail is tens of kilobytes each. At sixty pixels a side they are a
    /// couple of kilobytes and still sharper than the circle they end up in.
    private static func thumbnails(from photos: [String: Data]) -> [String: Data] {
        #if os(iOS)
        var small: [String: Data] = [:]

        for (room, data) in photos {
            guard let image = UIImage(data: data) else { continue }

            let side: CGFloat = 60
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1

            let scaled = UIGraphicsImageRenderer(
                size: CGSize(width: side, height: side), format: format
            ).image { _ in
                image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            }

            if let jpeg = scaled.jpegData(compressionQuality: 0.7) {
                small[room] = jpeg
            }
        }

        return small
        #else
        return photos
        #endif
    }

    /// How the address-book matching is doing, in words.
    ///
    /// Built for one reason: a feature that silently does nothing looks exactly like a feature
    /// that isn't there. Each step of the chain is reported separately, because "no access",
    /// "nothing to match against" and "matched nothing" need different answers.
    public var contactMatchingSummary: String {
        #if canImport(Contacts)
        guard profile == .phone else {
            return contactNames.isEmpty
                ? String(localized: "Waiting for names from your iPhone.", bundle: .module)
                : "\(contactNames.count) names from your iPhone."
        }

        guard ContactBook.isAuthorised else {
            return String(localized: "No access to your contacts, so network names are used.", bundle: .module)
        }

        let stats = matchStats

        guard stats.addressBook > 0 else {
            return String(localized: "Access granted, but no contacts with phone numbers were found.", bundle: .module)
        }

        guard stats.withKnownAccount > 0 else {
            return "\(stats.addressBook) contacts read. None of your chats has a known account yet."
        }

        return """
        \(stats.matched) of \(stats.withKnownAccount) chats named from \
        \(stats.addressBook) contacts.
        """
        #else
        return String(localized: "Not available on this device.", bundle: .module)
        #endif
    }

    /// What to call whoever sent a message, when that's actually knowable.
    ///
    /// Returns nothing rather than a bridged account's raw identifier. `lid-123456789012345`
    /// is not a name — putting it in front of a message says nothing and costs the room the
    /// message itself needs.
    public func senderName(of message: Message) -> String? {
        // Your own name for them first, then your address book, and only then whatever the
        // network calls them. In a group that's the difference between a column of handles
        // and a conversation between people you know.
        if let chosen = customAccountNames[message.sender], !chosen.isEmpty { return chosen }
        if let known = contactNamesByAccount[message.sender], !known.isEmpty { return known }
        if let stored = message.senderName, !stored.isEmpty { return stored }
        if let known = memberNames[message.sender], !known.isEmpty { return known }
        return nil
    }

    /// The picture of whoever sent a message, for groups.
    public func senderAvatarURL(of message: Message) -> String? {
        guard let url = memberAvatars[message.sender], !url.isEmpty else { return nil }
        return url
    }

    /// Fetches the member list of any group where someone has spoken whose face isn't known.
    ///
    /// Sync only sends membership for rooms that changed, so a group joined long ago arrives
    /// with names but no pictures, and every line looks the same. Asked once per room: the
    /// answer is stored, including "this person has no picture", so this settles down to
    /// nothing after the first run.
    public func refreshGroupMembers() async {
        guard let api else { return }

        let groups = ((try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? [])
            .filter { $0.isGroup && !hiddenRoomIDs.contains($0.id) }

        for conversation in groups {
            // Asked of the store for the last few senders, rather than by walking the whole
            // relationship — which reads every message the group ever had, for every group,
            // each time this runs.
            let unknown = recentSenders(in: conversation).contains {
                !isSelf($0) && memberAvatars[$0] == nil
            }
            guard unknown, let members = try? await api.members(of: conversation.id) else { continue }

            for member in members {
                guard let id = member.stateKey,
                      case .membership(let details) = member.content
                else { continue }

                note(id, name: details.displayName, avatar: details.avatarURL)
            }
        }

        saveMemberDetails()
    }

    /// The line under a conversation's name in the list.
    ///
    /// In a group, who said it matters as much as what was said; in a one-to-one the name is
    /// already the title above, so repeating it would only cost room. Only the first word of
    /// the name — a full one pushes out the message it belongs to.
    ///
    /// Lives here rather than in the two lists so the phone and the watch can't drift apart,
    /// which is exactly what happened when only one of them had it.
    public func preview(for conversation: Conversation) -> String {
        guard conversation.isGroup else { return conversation.lastMessagePreview }

        // Answered from the last time it was worked out, if nothing has happened since.
        //
        // This runs for every group on screen every time the list draws, and the list draws
        // whenever anything on the session changes — which during a sync is many times a
        // second. It used to walk the whole conversation to find the newest message, which
        // measured 1.6 ms for a group with a year behind it. Eight rows of that is half a
        // frame gone before a single pixel is drawn.
        //
        // Keyed on the stored line as well as the time. An edit or a deletion changes what
        // the newest message says without changing when anything last happened, and keyed
        // on the time alone a group went on showing words that had been corrected or taken
        // back until somebody wrote something new.
        if let remembered = groupPreviews[conversation.id],
           remembered.at == conversation.lastActivity,
           remembered.source == conversation.lastMessagePreview {
            return remembered.line
        }

        let line = workOutPreview(for: conversation)
        groupPreviews[conversation.id] = (
            at: conversation.lastActivity,
            source: conversation.lastMessagePreview,
            line: line
        )
        return line
    }

    /// What it says on the line, worked out from scratch.
    ///
    /// One indexed query for one message rather than loading every message in the room and
    /// sorting them — the same fix `markRead` already had.
    private func workOutPreview(for conversation: Conversation) -> String {
        let room = conversation.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.conversation?.id == room },
            sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        guard let newest = try? container.mainContext.fetch(descriptor).first else {
            return conversation.lastMessagePreview
        }

        let who = isMine(newest)
            ? "You"
            : senderName(of: newest)?.split(separator: " ").first.map(String.init)

        // No usable name means no prefix: a raw account identifier says nothing.
        guard let who else { return conversation.lastMessagePreview }

        return "\(who): \(conversation.lastMessagePreview)"
    }

    /// What to call this conversation, preferring the name you gave the person yourself.
    public func displayName(for conversation: Conversation) -> String {
        // Never on a group. Its name is its own, and the watch takes these names from the
        // phone — so a wrong entry there would otherwise keep showing up here long after the
        // phone stopped producing it.
        // A name you set by hand beats everything, group or not: you only ever set one
        // because everything else was wrong.
        if let custom = conversation.customName, !custom.isEmpty { return custom }

        guard !conversation.isGroup else { return conversation.displayName }

        // A name you gave the person, wherever you gave it. Named in a group, they are named
        // in your private chat with them too.
        if let partner = conversation.directPartnerID,
           let chosen = customAccountNames[partner], !chosen.isEmpty {
            return chosen
        }

        return contactNames[conversation.id] ?? conversation.displayName
    }

    /// A picture from the address book, used only where the network offered none.
    public func contactPhoto(for conversation: Conversation) -> Data? {
        conversation.customPhoto ?? contactPhotos[conversation.id]
    }

    #if canImport(UIKit)
    /// The same picture, decoded once.
    ///
    /// Turning bytes into an image is the expensive half, and asking for it from a view's
    /// body does it again on every redraw — of every row, of a list that redraws whenever
    /// anything on the session changes. Remembered against the bytes it came from, so a
    /// picture that changes is decoded again and one that doesn't never is.
    public func contactPicture(for conversation: Conversation) -> UIImage? {
        guard let data = contactPhoto(for: conversation) else { return nil }

        let key = conversation.id
        if let remembered = decodedPhotos[key], remembered.count == data.count {
            return remembered.image
        }

        guard let image = UIImage(data: data) else { return nil }
        decodedPhotos[key] = (count: data.count, image: image)
        return image
    }
    #endif

    /// Names a conversation by hand, or puts it back the way it was.
    public func rename(_ conversation: Conversation, to name: String?, photo: Data? = nil) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)

        conversation.customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if let photo { conversation.customPhoto = photo }
        if trimmed?.isEmpty ?? true { conversation.customPhoto = nil }

        // Against the person, not just against this room. You named them once; a group they
        // both happen to be in shouldn't go back to calling them by their handle.
        if let partner = conversation.directPartnerID, !isSelf(partner) {
            var chosen = customAccountNames
            chosen[partner] = conversation.customName
            customAccountNames = chosen
            publishChosenNames()
        }

        try? container.mainContext.save()

        // Straight to the watch, and not by way of the address book: somebody who never gave
        // Chatman access to their contacts can still name a chat by hand, and that name has
        // to travel. The full match runs too, for everything else it keeps up to date.
        shareNamesWithWatch()
        Task { await applyDeviceContacts() }

        // And kept with the account as well, which is the belt to that pair of braces. The
        // watch link only works while the two are in range of each other; the account works
        // everywhere, and survives the app being deleted and put back.
        //
        // Under Chatman's own type, because Matrix has no standard for "what I call this
        // room". Other clients will ignore it, which is exactly right.
        guard let api, let userID = credentials?.userID else { return }
        let room = conversation.id
        let chosen = conversation.customName ?? ""

        Task {
            try? await api.setRoomAccountData(
                MatrixAPI.ChosenName(name: chosen),
                type: "nl.chatman.name",
                room: room,
                for: userID
            )
        }
    }

    /// Everyone a bridge knows about, ready to start a chat with.
    ///
    /// Comes from the bridge and not from Synapse's user directory. That directory only knows
    /// people you already share a room with, so it's empty for exactly the person you're
    /// trying to reach for the first time.
    public func contacts(on network: ChatNetwork) async -> [MatrixAPI.BridgeContact] {
        guard let api, let credentials else { return [] }

        do {
            let found = try await api.bridgeContacts(as: credentials.userID, on: network)
            contactLookupFailure[network] = nil
            return found.sorted { ($0.name ?? "") < ($1.name ?? "") }
        } catch {
            contactLookupFailure[network] = error.localizedDescription
            return []
        }
    }

    /// Someone you can start a chat with, and where.
    ///
    /// The same person can appear twice — once per service they're on. That's deliberate:
    /// which one you use decides where the conversation lands, and only you know whether
    /// this is a WhatsApp friend or a Signal one.
    public struct Reachable: Identifiable, Sendable {
        public let network: ChatNetwork
        public let contact: MatrixAPI.BridgeContact

        public var id: String { "\(network.rawValue):\(contact.id)" }
        public var name: String { contact.name ?? contact.phoneNumbers.first ?? contact.id }
        public var number: String? { contact.phoneNumbers.first }
    }

    /// Everyone reachable across every connected service.
    public func everyoneReachable() async -> [Reachable] {
        var all: [Reachable] = []

        for network in availableNetworks {
            for contact in await contacts(on: network) {
                all.append(Reachable(network: network, contact: contact))
            }
        }

        return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Why looking up a network's contacts failed, if it did.
    public func contactLookupError(for network: ChatNetwork) -> String? {
        contactLookupFailure[network]
    }

    /// Opens a chat with someone, creating it on the network if needed.
    public func startChat(with contact: MatrixAPI.BridgeContact, on network: ChatNetwork) async throws -> String {
        guard let api, let credentials else { throw MatrixError.notSignedIn }

        if let existing = contact.dmRoomID, !existing.isEmpty {
            return existing
        }

        let created = try await api.createBridgeDM(
            with: contact.id, as: credentials.userID, on: network
        )

        guard let roomID = created.dmRoomID, !roomID.isEmpty else {
            throw MatrixError.decoding(String(localized: "The bridge didn't say which room it made.", bundle: .module))
        }

        if conversation(withID: roomID) == nil {
            let conversation = Conversation(
                id: roomID,
                name: contact.name,
                isDirect: true,
                network: network,
                lastActivity: .now,
                directPartnerID: created.mxid ?? contact.mxid
            )
            insert(conversation)
            saveContext()
        }

        return roomID
    }

    /// Brings each conversation's date and preview back in line with what it actually holds.
    ///
    /// Messages fetched as history used to be stored without touching the conversation, so a
    /// chat could be full and still carry the date it was created with — no date in the list,
    /// sorted to the bottom, looking empty. New messages no longer do that, but everything
    /// already stored still needs putting right, and only reading it can do that.
    public func repairConversationDates() {
        var changed = false

        for conversation in (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? [] {
            // The newest one, asked for by itself: the store sorts on an index, where
            // `messages.max` pulled every message of every conversation into memory to find it.
            let room = conversation.id
            var newestFirst = FetchDescriptor<Message>(
                predicate: #Predicate<Message> { $0.conversation?.id == room },
                sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
            )
            newestFirst.fetchLimit = 1
            guard let newest = try? container.mainContext.fetch(newestFirst).first else { continue }

            if newest.timestamp > conversation.lastActivity {
                conversation.lastActivity = newest.timestamp
                conversation.lastMessagePreview = newest.body
                changed = true
            }
        }

        if changed { saveContext() }
    }

    /// Sends a picture: uploads it, then posts it to the conversation.
    ///
    /// Shows up straight away as a pending message so the conversation reacts to the tap
    /// rather than to the round trip, and is replaced by the real one when the sync brings it
    /// back — the same trick as with text.
    /// Where the bytes of an attachment are, until they are somebody else's.
    ///
    /// A film stays a file all the way to the server. Everything else is small enough that
    /// handing over the bytes is simpler than handing over a path and a promise to clean up.
    public enum Attachment: Sendable {
        case bytes(Data)
        case file(URL)
    }

    /// Sends a film or a file: anything that isn't a photo.
    ///
    /// One path for both, because from here they differ only in what Matrix calls them and
    /// what the bridge does with them on the other side. A video that WhatsApp turns into a
    /// video and a PDF that it turns into a document take exactly the same route out.
    public func sendAttachment(
        _ payload: Attachment,
        filename: String,
        mimeType: String,
        kind: Message.Kind,
        size: CGSize? = nil,
        duration: Int? = nil,
        isVoice: Bool = false,
        waveform: [Int] = [],
        to conversation: Conversation,
        replyingTo replyTo: Message? = nil
    ) async throws {
        guard let credentials else { throw MatrixError.notSignedIn }

        let transactionID = MatrixAPI.transactionID()

        // On disk before anything else, so nothing that happens next can lose it.
        let kept: String
        switch payload {
        case .bytes(let data):
            kept = try Outbox.keep(data, for: transactionID, named: filename)
        case .file(let url):
            kept = try Outbox.keep(fileAt: url, for: transactionID, named: filename)
        }

        let pending = Message(
            id: transactionID,
            sender: credentials.userID,
            timestamp: .now,
            body: filename,
            kind: kind,
            mediaWidth: size.map { Int($0.width) },
            mediaHeight: size.map { Int($0.height) },
            mediaMimeType: mimeType,
            replyToID: replyTo?.id,
            isPending: true
        )
        pending.outboxFile = kept
        pending.isVoice = isVoice
        pending.mediaDuration = duration
        pending.waveform = waveform
        queue(pending, in: conversation, preview: Self.preview(of: pending))

        _ = await enqueue(transactionID)?.value
    }

    public func sendImage(
        _ data: Data,
        filename: String,
        mimeType: String,
        size: CGSize?,
        caption: String? = nil,
        to conversation: Conversation,
        replyingTo replyTo: Message? = nil
    ) async throws {
        guard let credentials else { throw MatrixError.notSignedIn }

        let transactionID = MatrixAPI.transactionID()
        let words = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let said = (words?.isEmpty ?? true) ? nil : words

        let kept = try Outbox.keep(data, for: transactionID, named: filename)

        let pending = Message(
            id: transactionID,
            sender: credentials.userID,
            timestamp: .now,
            body: "Photo",
            kind: .image,
            mediaWidth: size.map { Int($0.width) },
            mediaHeight: size.map { Int($0.height) },
            mediaMimeType: mimeType,
            replyToID: replyTo?.id,
            isPending: true
        )
        pending.caption = said
        pending.outboxFile = kept
        queue(pending, in: conversation, preview: said ?? "Photo")

        _ = await enqueue(transactionID)?.value
    }

    /// Changes the text of a message you sent.
    ///
    /// The change shows immediately and is put back if the server refuses — the same bargain
    /// as sending: react to the tap, not to the round trip.
    public func edit(_ message: Message, to newText: String) async throws {
        let body = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body != message.body else { return }
        guard let api, let conversation = message.conversation else { throw MatrixError.notSignedIn }

        let target = message.id
        let previous = message.body
        let wasEditedBefore = message.wasEdited
        let previousPreview = conversation.lastMessagePreview

        message.body = body
        message.wasEdited = true

        if conversation.lastMessagePreview == previous {
            conversation.lastMessagePreview = body
        }

        saveContext()

        do {
            try await api.editText(body, replacing: target, in: conversation.id)
        } catch {
            // Everything put back, not only the words. Restoring just the text left the
            // message marked "edited" for a change the server never took, and the list went
            // on showing the new wording as the chat's last line.
            if let current = self.message(id: target) {
                current.body = previous
                current.wasEdited = wasEditedBefore
            }
            if conversation.lastMessagePreview == body {
                conversation.lastMessagePreview = previousPreview
            }
            saveContext()
            throw error
        }
    }

    /// How far a message you sent has got.
    ///
    /// The same ladder Messages shows, and for the same reason: after sending something that
    /// matters you want to know whether it arrived, and an app that says nothing leaves you
    /// opening the other person's app to check.
    public enum SendStatus: Equatable, Sendable {
        case sending
        case failed
        /// On your server, but the bridge hasn't confirmed passing it on.
        case sent
        /// The bridge handed it to Signal or WhatsApp.
        case delivered
        case read(Date)

        /// The word for it, in Messages' own vocabulary.
        public var label: String {
            switch self {
            case .sending: String(localized: "Sending…", bundle: .module)
            case .failed: String(localized: "Not sent", bundle: .module)
            case .sent: String(localized: "Sent", bundle: .module)
            case .delivered: String(localized: "Delivered", bundle: .module)
            case .read(let when):
                "Read " + when.formatted(date: .omitted, time: .shortened)
            }
        }
    }

    /// Where a message you sent has got to.
    public func sendStatus(of message: Message) -> SendStatus {
        if message.didFailToSend { return .failed }
        if message.isPending { return .sending }
        if let readAt = message.readAt { return .read(readAt) }
        if message.deliveredAt != nil { return .delivered }
        return .sent
    }

    /// The message a conversation should show a status under.
    ///
    /// Only the newest one you sent, which is what Messages does. A status under every line
    /// turns a conversation into a delivery report.
    public func statusMessage(in conversation: Conversation) -> Message? {
        conversation.messages
            .filter { isMine($0) }
            .max { $0.timestamp < $1.timestamp }
    }

    /// Whether a message can still be changed.
    ///
    /// Only your own, only text, and only once it exists on the server — a message still on
    /// its way has no event to point an edit at.
    public func canEdit(_ message: Message) -> Bool {
        message.sender == credentials?.userID
            && message.kind == .text
            && !message.isPending
            && !message.didFailToSend
    }

    /// Creates a group on one network with the people you picked.
    ///
    /// Everyone has to be on the same service: a group lives on Signal or on WhatsApp, not
    /// across both. That's a limit of those networks, not of this app, and the interface says
    /// so rather than letting someone build a group that can't exist.
    public func createGroup(
        named name: String, with people: [Reachable], on network: ChatNetwork
    ) async throws -> String {
        guard let api, let credentials else { throw MatrixError.notSignedIn }

        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MatrixError.decoding("A group needs a name.")
        }

        let created = try await api.createBridgeGroup(
            named: title,
            with: people.map(\.contact.id),
            as: credentials.userID,
            on: network
        )

        guard !created.mxid.isEmpty else {
            throw MatrixError.decoding(String(localized: "The bridge didn't say which room it made.", bundle: .module))
        }

        if conversation(withID: created.mxid) == nil {
            let conversation = Conversation(
                id: created.mxid,
                name: title,
                isDirect: false,
                network: network,
                lastActivity: .now,
                otherMemberCount: people.count
            )
            insert(conversation)
            saveContext()
        }

        return created.mxid
    }

    /// Fetches a first page of history for conversations that arrived empty.
    ///
    /// Sync returns only the most recent event per room, and in a room where that event was
    /// something other than a message — someone joining, a name change — the conversation
    /// arrives with nothing in it. It then has no date, sorts to the bottom, and looks older
    /// than it is. This asks once for what's actually in there.
    public func fillEmptyConversations(limit: Int = 15) async {
        guard api != nil else { return }

        let empty = ((try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? [])
            .filter { !hiddenRoomIDs.contains($0.id) && !hasStoredMessages($0) }

        for conversation in empty {
            _ = await loadOlderMessages(in: conversation, limit: limit)
        }
    }

    /// A request that loads an avatar at the size it's drawn.
    public func avatarRequest(for url: String?, size: Int = 96) -> URLRequest? {
        guard let url, !url.isEmpty else { return nil }
        return api?.thumbnailRequest(for: url, width: size, height: size)
    }
}

extension ChatSession {

    /// Who wrote the last messages in a conversation, newest first. One small question to the
    /// store, instead of reading the whole conversation to find out.
    func recentSenders(in conversation: Conversation, limit: Int = 60) -> [String] {
        let room = conversation.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.conversation?.id == room },
            sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return ((try? container.mainContext.fetch(descriptor)) ?? []).map(\.sender)
    }

    /// The looking-after the lists used to do every time they appeared, done when it's due.
    ///
    /// Each of these asks the server something or walks every conversation. The list's own
    /// `.task` ran all of them again whenever it came back on screen — which on the watch is
    /// every time you leave a chat, over its own radio. Now: the bridges at most every five
    /// minutes, because a disconnected WhatsApp should show up soon; the rest at most every
    /// half hour, because none of it changes faster than that.
    public func tidyUpIfDue(force: Bool = false) async {
        let now = Date.now

        // Every five minutes on the phone, every half hour on the watch: there it ran on
        // nearly every raise of the wrist, fourteen requests at a time, for a banner that
        // the phone shows too.
        let bridgeInterval: TimeInterval = profile == .watch ? 30 * 60 : 5 * 60
        if force || now.timeIntervalSince(lastBridgeCheck) > bridgeInterval {
            lastBridgeCheck = now
            await refreshBridges()
        }

        guard force || now.timeIntervalSince(lastTidyUp) > 30 * 60 else { return }
        lastTidyUp = now

        if profile == .phone {
            await publishLocalChoices()
            publishChosenNamesIfNeeded()
        }
        await identifyUnknownNetworks()
        await fillEmptyConversations()
        await refreshGroupMembers()
        repairConversationDates()
        seedClosenessIfNeeded()
        if profile == .phone { await applyDeviceContacts() }
    }
}
