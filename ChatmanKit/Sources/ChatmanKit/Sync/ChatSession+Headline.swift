import Foundation
import SwiftData

/// What a board leads with: the message the group itself thought mattered.
///
/// A noticeboard's newest message is, more often than not, "haha" or "thanks!". Leading with
/// it tells you nothing about whether the thirty messages behind it are worth opening. The
/// group has already said which ones matter, in ways that can be counted without reading:
/// it reacted to them, or somebody you actually talk to wrote them.
///
/// From the unread messages, the first of these that exists:
/// 1. the one the most different people reacted to, if at least three did;
/// 2. the newest from somebody you also have a private chat with;
/// 3. the newest.
extension ChatSession {

    /// A board's lead, and the counts under it.
    public struct Headline: Sendable, Equatable {
        /// Why this message leads, which decides whether opening the board goes to it.
        public enum Reason: Sendable, Equatable {
            /// The group reacted to it.
            case reactedTo
            /// Somebody you know wrote it.
            case fromSomeoneYouKnow
            /// Nothing stood out; it's simply the newest.
            case newest
        }

        /// The message, when there is one to point at.
        public let messageID: String?
        /// "Anna: the street party is moved to Sunday"
        public let line: String
        public let reason: Reason
        /// Unread messages, and how many people wrote them.
        public let fresh: Int
        public let people: Int
    }

    /// The fewest reactions from different people that make a message stand out.
    static let headlineReactors = 3

    /// A board's lead. Worked out once per change and remembered, like the list's previews.
    public func headline(for board: Conversation) -> Headline {
        let key = "\(board.lastActivity.timeIntervalSince1970)|\(board.unreadCount)|\(board.lastMessagePreview)"
        if let remembered = headlines[board.id], remembered.key == key {
            return remembered.headline
        }

        let worked = workOutHeadline(for: board)
        headlines[board.id] = (key, worked)
        return worked
    }

    private func workOutHeadline(for board: Conversation) -> Headline {
        let fallback = Headline(
            messageID: nil, line: preview(for: board), reason: .newest, fresh: 0, people: 0
        )
        guard board.unreadCount > 0 else { return fallback }

        let room = board.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.conversation?.id == room },
            sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
        )
        // The unread ones, as far as they are stored. A busy group makes the sync skip some,
        // and then this looks at what is here — never worse than the newest alone.
        descriptor.fetchLimit = min(board.unreadCount, 80)

        let unread = ((try? container.mainContext.fetch(descriptor)) ?? [])
            .filter { !isSelf($0.sender) }
        guard let newest = unread.first else { return fallback }

        let people = Set(unread.map(\.sender)).count

        // 1. What the group reacted to.
        var reacted: (message: Message, count: Int)?
        for message in unread {
            let count = message.reactorCount
            guard count >= Self.headlineReactors else { continue }
            // Most reactors wins; between equals the newer one, which comes first here.
            if count > (reacted?.count ?? 0) { reacted = (message, count) }
        }

        if let message = reacted?.message {
            return Headline(messageID: message.id, line: line(for: message),
                            reason: .reactedTo, fresh: board.unreadCount, people: people)
        }

        // 2. Somebody you know. The same account sits in the group and in your private chat
        // with them, so this is a lookup of names in two lists, not a reading of anything.
        let known = privatePartners()
        if let message = unread.first(where: { known.contains($0.sender) }) {
            return Headline(messageID: message.id, line: line(for: message),
                            reason: .fromSomeoneYouKnow, fresh: board.unreadCount, people: people)
        }

        // 3. The newest.
        return Headline(messageID: newest.id, line: line(for: newest),
                        reason: .newest, fresh: board.unreadCount, people: people)
    }

    /// "Anna: what she said", in the list's own shape.
    private func line(for message: Message) -> String {
        let text = Self.preview(of: message)
        guard let who = senderName(of: message)?.split(separator: " ").first else { return text }
        return "\(who): \(text)"
    }

    /// Everyone you have a private chat with, by the account they write under.
    private func privatePartners() -> Set<String> {
        let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []
        return Set(all.filter { !$0.isGroup }.compactMap(\.directPartnerID))
    }
}

extension Message {
    /// How many different people reacted, whatever with.
    ///
    /// Counted per person, not per reaction: six thumbs from six neighbours says more than one
    /// neighbour tapping every emoji there is. Counts kept in the old format, which never knew
    /// who gave them, are added as they are.
    public var reactorCount: Int {
        let stored = Reactions(blob: reactionsBlob)
        return Set(stored.events.values.map(\.sender)).count + stored.base.values.reduce(0, +)
    }
}

extension ChatSession {

    /// The first message you haven't read, counted back from the newest.
    ///
    /// Counted among other people's messages only, because that is what the unread count
    /// counts: something you sent in between doesn't make you further behind. Asked of the
    /// store directly, so a screen that only holds the last forty messages can still find
    /// where the unread ones begin.
    public func firstUnreadMessageID(in conversation: Conversation, unread: Int) -> String? {
        guard unread > 0 else { return nil }

        let room = conversation.id
        var newestFirst = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.conversation?.id == room },
            sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
        )
        newestFirst.fetchLimit = min(unread * 2 + 20, 400)

        var counted = 0
        for message in (try? container.mainContext.fetch(newestFirst)) ?? [] where !isSelf(message.sender) {
            counted += 1
            if counted == unread { return message.id }
        }
        return nil
    }
}

extension ChatSession {

    /// How many messages came after this one, so a screen that holds only the newest can be
    /// told how far back to reach for it.
    public func messagesNewer(than messageID: String, in conversation: Conversation) -> Int? {
        guard let target = message(id: messageID) else { return nil }
        let room = conversation.id
        let moment = target.timestamp
        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.conversation?.id == room && $0.timestamp > moment }
        )
        return try? container.mainContext.fetchCount(descriptor)
    }

    /// The pictures and films of a conversation, oldest first, for swiping through.
    ///
    /// Asked for when a picture is opened rather than kept on hand: the conversation screen
    /// holds only its newest messages, and the viewer wants every picture — within reason.
    /// Three hundred, centred on the one that was tapped, is more than anybody swipes through.
    public func pictures(in conversation: Conversation, around message: Message) -> [Message] {
        let room = conversation.id
        let image = Message.Kind.image.rawValue
        let video = Message.Kind.video.rawValue
        let moment = message.timestamp

        var before = FetchDescriptor<Message>(
            predicate: #Predicate<Message> {
                $0.conversation?.id == room && ($0.kindID == image || $0.kindID == video)
                    && $0.timestamp < moment
            },
            sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
        )
        before.fetchLimit = 150

        var after = FetchDescriptor<Message>(
            predicate: #Predicate<Message> {
                $0.conversation?.id == room && ($0.kindID == image || $0.kindID == video)
                    && $0.timestamp >= moment
            },
            sortBy: [SortDescriptor(\Message.timestamp)]
        )
        after.fetchLimit = 150

        let earlier = ((try? container.mainContext.fetch(before)) ?? []).reversed()
        let later = (try? container.mainContext.fetch(after)) ?? []
        let all = Array(earlier) + later
        return all.contains(where: { $0.id == message.id }) ? all : [message]
    }
}
