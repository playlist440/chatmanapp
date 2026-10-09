import Foundation
import SwiftData

/// How close you are to a conversation, from what you do in it.
///
/// Your own messages count one each and your reactions half, and all of it fades: a message
/// from two weeks ago counts half, one from a month ago a quarter. What other people send
/// counts for nothing — that says how busy a chat is, not how much it matters to you.
///
/// Used only to put things in order, never to hide anything: the people you talk to at the top
/// of "send this to…" and of a new chat, and everybody else where they always were.
public enum Closeness {

    /// How long until a message counts half.
    public static let halfLife: TimeInterval = 14 * 24 * 60 * 60

    /// A score as it stands at a moment, faded from when it was last added to.
    public static func faded(_ score: Double, since: Date?, now: Date = .now) -> Double {
        guard let since else { return score }
        let elapsed = max(0, now.timeIntervalSince(since))
        return score * pow(0.5, elapsed / halfLife)
    }

    /// A conversation's score now.
    public static func current(_ conversation: Conversation, now: Date = .now) -> Double {
        faded(conversation.closeness, since: conversation.closenessAt, now: now)
    }
}

extension ChatSession {

    /// The people you talk to most, by private chat, closest first.
    ///
    /// Only chats you have actually written in: somebody who writes to you and never hears
    /// back is not who you're looking for when you go to start a conversation.
    public func closestPeople(limit: Int = 5) -> [Conversation] {
        let now = Date.now
        let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []
        var scored: [(conversation: Conversation, score: Double)] = []
        for conversation in all where !conversation.isGroup && !conversation.isArchived {
            guard !isHidden(conversation) else { continue }
            let score = Closeness.current(conversation, now: now)
            if score > 0.05 { scored.append((conversation, score)) }
        }

        scored.sort { first, second in
            if first.score != second.score { return first.score > second.score }
            return first.conversation.lastActivity > second.conversation.lastActivity
        }
        return scored.prefix(limit).map(\.conversation)
    }

    /// Adds to how close you are to a conversation. See ``Closeness``.
    func noteCloseness(to conversation: Conversation, weight: Double, at moment: Date = .now) {
        conversation.closeness = Closeness.faded(
            conversation.closeness, since: conversation.closenessAt, now: moment
        ) + weight
        conversation.closenessAt = moment
    }

    /// Works the scores out once from what is already stored.
    ///
    /// The score is kept as you go, but everything said before this version existed would
    /// otherwise count for nothing — and "send this to…" would start from a blank page. One
    /// pass over your own messages from the last three months, per conversation, then never
    /// again.
    public func seedClosenessIfNeeded() {
        let key = "chatman.closenessSeeded"
        guard !defaults.bool(forKey: key) else { return }

        let since = Date.now.addingTimeInterval(-90 * 24 * 60 * 60)
        var mine = Array(selfAccounts)
        if let me = credentials?.userID { mine.append(me) }
        guard !mine.isEmpty else { return }

        let descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.timestamp >= since && mine.contains($0.sender) },
            sortBy: [SortDescriptor(\Message.timestamp)]
        )

        for message in (try? container.mainContext.fetch(descriptor)) ?? [] {
            guard let conversation = message.conversation else { continue }
            noteCloseness(to: conversation, weight: 1, at: message.timestamp)
        }

        defaults.set(true, forKey: key)
        saveContext()
    }
}
