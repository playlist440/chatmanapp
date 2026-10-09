#if os(watchOS)
import Foundation
import SwiftData
import UserNotifications

/// A tap on the wrist, without push.
///
/// A free developer account gets no push, so nothing reaches the watch on its own. What it
/// does get is a background wake-up a few times an hour, in which the app syncs — and then,
/// until now, did nothing with what it found. A notification made on the watch itself needs
/// no Apple server and no certificate: this makes one, after each of those syncs, for each
/// conversation that has started waiting on you since the last.
///
/// Only what the rules in `Attention` let through: a person, a pinned chat, a group that is
/// about you or plainly on fire. Never the neighbourhood chatting among itself — a tap for
/// that is how people learn to ignore taps. One per conversation, replaced rather than piled
/// up, and taken away again when the conversation is read.
///
/// It is late by however long watchOS waited before waking the app, usually a few minutes.
/// When that's more than five, the notification says when the message came, so it reads as a
/// letter and not as a phone ringing.
@MainActor
public enum WristTap {

    /// The category the notifications carry, and the one action they offer.
    public static let category = "chatman.message"
    public static let muteAction = "chatman.mute"

    /// The conversation a notification is about.
    public static let roomKey = "room"

    private static let tappedKey = "chatman.wristTapped"

    /// Asks once whether the watch may tap you, and says what a tap can offer.
    public static func prepare() async {
        let center = UNUserNotificationCenter.current()

        let mute = UNNotificationAction(identifier: muteAction, title: "Mute", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [mute], intentIdentifiers: [])
        ])

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Taps once for each conversation that has started waiting on you.
    ///
    /// Called after a background sync, never while the app is open: then you are already
    /// looking.
    static func tap(for session: ChatSession, defaults: UserDefaults) async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }

        var tapped = defaults.dictionary(forKey: tappedKey) as? [String: Double] ?? [:]
        let firstTime = defaults.object(forKey: tappedKey) == nil

        for conversation in session.waitingOnYou() {
            guard let newest = session.newestFromOthers(in: conversation) else { continue }
            let when = newest.timestamp.timeIntervalSince1970

            // Already tapped for this one, or for something newer.
            if let last = tapped[conversation.id], last >= when { continue }
            tapped[conversation.id] = when

            // The very first time there is no "since last time", only a backlog. That was
            // waiting before this existed and it isn't news now.
            if firstTime { continue }

            let content = UNMutableNotificationContent()
            content.title = session.displayName(for: conversation)
            content.body = session.wristLine(for: conversation, newest: newest)
            content.threadIdentifier = conversation.id
            content.categoryIdentifier = category
            content.userInfo = [roomKey: conversation.id]
            content.sound = .default

            let late = Date.now.timeIntervalSince(newest.timestamp)
            if late > 5 * 60 {
                content.subtitle = "at " + newest.timestamp.formatted(date: .omitted, time: .shortened)
            }

            // Named after the room, so a second tap for the same conversation replaces the
            // first instead of stacking up beside it.
            try? await center.add(UNNotificationRequest(
                identifier: conversation.id, content: content, trigger: nil
            ))
        }

        // Only rooms still worth remembering: a conversation that left is forgotten.
        let known = Set(((try? session.container.mainContext.fetch(FetchDescriptor<Conversation>())) ?? []).map(\.id))
        tapped = tapped.filter { known.contains($0.key) }
        defaults.set(tapped, forKey: tappedKey)
    }

    /// Takes a conversation's notification away once it has been read.
    static func withdraw(for conversationID: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [conversationID])
    }
}

extension ChatSession {

    /// The newest message somebody else wrote here.
    func newestFromOthers(in conversation: Conversation) -> Message? {
        let room = conversation.id
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.conversation?.id == room },
            sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 20
        return ((try? container.mainContext.fetch(descriptor)) ?? []).first { !isSelf($0.sender) }
    }

    /// What a tap on the wrist says, as much as the chosen level of detail allows.
    func wristLine(for conversation: Conversation, newest: Message) -> String {
        let who = senderName(of: newest)?.split(separator: " ").first.map(String.init)
        let about = mentionsYou(conversation)

        // A group that is simply busy says so, rather than quoting whichever line came last.
        if conversation.isGroup, !about, !conversation.isPinned,
           let until = conversation.burstUntil, until > .now {
            return "Lots going on · \(conversation.unreadCount) new"
        }

        switch notificationDetail {
        case .nothing:
            return "New message"
        case .senderOnly:
            return who.map { "Message from \($0)" } ?? "New message"
        case .senderAndMessage:
            let text = Self.preview(of: newest)
            guard conversation.isGroup, let who else { return text }
            return "\(who): \(text)"
        }
    }
}
#endif
