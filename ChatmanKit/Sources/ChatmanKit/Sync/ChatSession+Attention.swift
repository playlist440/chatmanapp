import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Where the rules in ``Attention`` meet the conversations they are about.
extension ChatSession {

    /// Everything the rule needs to know about one conversation.
    func attentionFacts(for conversation: Conversation) -> Attention.Facts {
        Attention.Facts(
            isHidden: isHidden(conversation),
            isArchived: conversation.isArchived,
            isGroup: conversation.isGroup,
            isPinned: conversation.isPinned,
            isManuallyUnread: conversation.isManuallyUnread,
            unread: conversation.unreadCount,
            mentions: conversation.mentionCount + conversation.localMentions,
            burstUntil: conversation.burstUntil
        )
    }

    /// Whether this conversation is waiting on you. See ``Attention/isWaiting(_:now:)``.
    ///
    /// Not the same as having unread messages, which ``isWaiting(_:)`` answers and the list's
    /// blue dots show. A group can be full of unread messages and wait on nobody.
    public func needsYou(_ conversation: Conversation) -> Bool {
        Attention.isWaiting(attentionFacts(for: conversation))
    }

    /// Whether a group has something in it about you, as opposed to merely something new.
    public func mentionsYou(_ conversation: Conversation) -> Bool {
        conversation.mentionCount + conversation.localMentions > 0
    }

    /// Everything waiting on you, most recent first.
    public func waitingOnYou() -> [Conversation] {
        let all = (try? container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []
        return all
            .filter(needsYou)
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Counts a message that just arrived towards whether its conversation needs you.
    ///
    /// Named by one of your accounts, or an answer to something you wrote. The server already
    /// counts a mention of your Matrix account; this catches the account that stands for you
    /// on WhatsApp or Signal, which the server has no way of knowing is you — and an answer
    /// that nobody marked as a mention at all.
    ///
    /// Only for news: what a first sync fetches is history, and all of it has been read.
    func noteAttention(to message: Message, from event: MatrixEvent, in conversation: Conversation) {
        guard hasSyncedBefore, !isSelf(event.sender) else { return }

        let named = event.mentionedUserIDs.contains { isSelf($0) }
        let answered = message.replyToID
            .flatMap { self.message(id: $0) }
            .map { isSelf($0.sender) } ?? false

        if named || answered {
            conversation.localMentions += 1
        }
    }

    /// Takes the counts the server sent for one room.
    ///
    /// Besides storing them, this is where a group's ordinary day is learned and a burst is
    /// noticed — from how much the unread count rose since the last look, never from reading
    /// the messages. See ``Attention/Burst``.
    func noteCounts(
        _ counts: MatrixAPI.SyncResponse.UnreadCounts?,
        for conversation: Conversation,
        now: Date = .now
    ) {
        if let highlights = counts?.highlightCount {
            conversation.mentionCount = highlights
        }

        guard let count = counts?.notificationCount else { return }

        let previous = conversation.unreadCount
        conversation.unreadCount = count

        // Read somewhere else: on the phone, in WhatsApp, in Element. What was waiting has
        // been seen, wherever it was seen.
        if previous > 0, count == 0 {
            conversation.localMentions = 0
            conversation.burstUntil = nil
        }

        guard conversation.isGroup else { return }
        judgeBurst(in: conversation, count: count, now: now)
    }

    /// Learns a group's pace, and calls a burst when this half hour is far beyond it.
    func judgeBurst(in conversation: Conversation, count: Int, now: Date) {
        typealias Burst = Attention.Burst

        let lastLook = conversation.countSampledAt
        let rise = Burst.rise(from: conversation.countSample, to: count)
        conversation.countSample = count
        conversation.countSampledAt = now

        // The very first look has nothing to compare with.
        guard let lastLook else { return }

        let interval = now.timeIntervalSince(lastLook)
        conversation.typicalDaily = Burst.learn(
            typicalDaily: conversation.typicalDaily, rise: rise, after: interval
        )

        // A rise across hours is an afternoon's worth, not a burst. It still teaches the
        // group's pace above; it just doesn't go in the half-hour log.
        let fresh = interval < Burst.freshness
        conversation.riseLog = Burst.log(conversation.riseLog, adding: fresh ? rise : 0, at: now)
        guard fresh else { return }

        let messages = Burst.total(in: conversation.riseLog, now: now)
        // Cheap before it's thorough: counting people means asking the store.
        guard messages >= Burst.minimumMessages else { return }

        let people = writers(in: conversation, since: now.addingTimeInterval(-Burst.window))

        if Burst.isBurst(
            messages: messages, people: people,
            typicalDaily: conversation.typicalDaily,
            lastBurst: conversation.lastBurstAt, now: now
        ) {
            conversation.burstUntil = now.addingTimeInterval(Burst.lasts)
            conversation.lastBurstAt = now
        }
    }

    /// How many different people wrote here since a moment, not counting you.
    ///
    /// From what is stored. A busy group makes the sync skip messages, but each sync still
    /// brings the last twenty or thirty, and that is plenty to see whether four people are
    /// talking or two.
    func writers(in conversation: Conversation, since start: Date) -> Int {
        let room = conversation.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> {
                $0.conversation?.id == room && $0.timestamp >= start
            }
        )
        descriptor.fetchLimit = 300
        let recent = (try? container.mainContext.fetch(descriptor)) ?? []
        return Set(recent.map(\.sender).filter { !isSelf($0) }).count
    }

    /// Clears what was waiting in a conversation you have just read.
    func clearAttention(in conversation: Conversation) {
        conversation.mentionCount = 0
        conversation.localMentions = 0
        conversation.burstUntil = nil
    }

    /// Hands the watch face who is waiting, and asks it to redraw only when that changed.
    ///
    /// Watch only: the complication lives there, and the phone has nothing to tell. Trying
    /// anyway would mean a keychain call on every sync that can only fail, since the phone
    /// doesn't carry the shared group.
    func publishUnreadCount() {
        #if os(watchOS)
        let waiting = waitingOnYou()
        let snapshot = UnreadBadge.Snapshot(
            count: waiting.count,
            names: waiting.prefix(3).map { shortName(for: $0) },
            syncedAt: lastHeardFromServer
        )
        guard UnreadBadge.write(snapshot) else { return }
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// A first name, or a group's name, short enough for a watch face.
    func shortName(for conversation: Conversation) -> String {
        let full = displayName(for: conversation)
        guard !conversation.isGroup, let first = full.split(separator: " ").first else {
            return full
        }
        return String(first)
    }
}
