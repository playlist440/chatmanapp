import Foundation

/// Who is waiting on you, decided by rules rather than by reading anything.
///
/// Every input is a count, a flag or a time: how many unread messages the server counted,
/// whether one of them mentions you, whether you pinned the chat. Not a word of any message is
/// looked at, which is what lets the same rule run on the watch face, in the watch list and on
/// the phone's shelf without any of them knowing more than they already did.
///
/// Correcting it goes through gestures that already exist. Pinned means "always counts".
/// Muted means "never counts" — the server stops counting a muted room, so this never sees it.
/// Archived means out of sight. There is no setting of its own, and there shouldn't be.
public enum Attention {

    /// What the rule needs to know about one conversation.
    public struct Facts: Sendable, Equatable {
        public var isHidden = false
        public var isArchived = false
        public var isGroup = false
        public var isPinned = false
        public var isManuallyUnread = false
        /// Unread messages, as the server counts them.
        public var unread = 0
        /// Unread mentions of you or answers to you, from the server or from this device.
        public var mentions = 0
        /// Until when a burst of activity keeps a group counting. See ``Burst``.
        public var burstUntil: Date?

        public init(
            isHidden: Bool = false, isArchived: Bool = false, isGroup: Bool = false,
            isPinned: Bool = false, isManuallyUnread: Bool = false,
            unread: Int = 0, mentions: Int = 0, burstUntil: Date? = nil
        ) {
            self.isHidden = isHidden
            self.isArchived = isArchived
            self.isGroup = isGroup
            self.isPinned = isPinned
            self.isManuallyUnread = isManuallyUnread
            self.unread = unread
            self.mentions = mentions
            self.burstUntil = burstUntil
        }
    }

    /// Whether this conversation is waiting on you.
    ///
    /// A person is, as soon as they have written. A group is only when it is about you —
    /// somebody named you or answered you — or when something is plainly going on in it. The
    /// neighbourhood chat talking among itself is not waiting on you, and a watch face that
    /// says it is teaches you to stop looking at the watch face.
    public static func isWaiting(_ facts: Facts, now: Date = .now) -> Bool {
        if facts.isHidden || facts.isArchived { return false }

        // Put back on the pile by hand. That is you saying so, and it outranks everything.
        if facts.isManuallyUnread { return true }

        // A mention counts everywhere, in a muted room as well: the server lets one through a
        // mute for the same reason WhatsApp does.
        if facts.mentions > 0 { return true }

        if !facts.isGroup || facts.isPinned {
            return facts.unread > 0
        }

        if let until = facts.burstUntil, until > now { return true }
        return false
    }

    /// The conversations to name, in the order to name them: the most recent first.
    public static func names<Item>(
        of items: [Item], waiting: (Item) -> Bool, name: (Item) -> String,
        newest: (Item) -> Date, limit: Int = 3
    ) -> [String] {
        items
            .filter(waiting)
            .sorted { newest($0) > newest($1) }
            .prefix(limit)
            .map(name)
    }
}

extension Attention {

    /// A group where something is plainly going on.
    ///
    /// The street is on fire, the school is closed, the family is sorting out who picks up
    /// grandma. None of that mentions you, and all of it should reach your wrist once. What it
    /// has in common can be counted without reading a word: a lot of messages, in a short
    /// time, from several people, and far more than this group usually manages.
    ///
    /// Counted from the rise in the server's unread count between two syncs rather than from
    /// the messages stored here. A busy group makes the sync skip messages, so the stored ones
    /// undercount exactly when it matters.
    ///
    /// The numbers are a starting point. See `server/terugtest.sql` for how to check them
    /// against a year of a real group, and change them here with a note of what the check found.
    public enum Burst {
        /// How far back the rule looks.
        public static let window: TimeInterval = 30 * 60

        /// How many messages that half hour needs, at the least.
        public static let minimumMessages = 15

        /// How many different people have to be writing. A heated argument between two is not
        /// a street on fire.
        public static let minimumPeople = 4

        /// How long the group then counts as waiting on you.
        public static let lasts: TimeInterval = 2 * 60 * 60

        /// How long before the same group can do it again. One busy evening is one tap.
        public static let cooldown: TimeInterval = 6 * 60 * 60

        /// Two counts further apart than this say nothing about a half hour: the rise is the
        /// sum of an afternoon, not a burst.
        public static let freshness: TimeInterval = 30 * 60

        /// How slowly the idea of an ordinary day changes, in seconds. Two weeks: a single
        /// busy weekend moves it a little, a group that has become busier moves it for good.
        public static let memory: TimeInterval = 14 * 24 * 60 * 60

        /// Whether this counts as a burst.
        ///
        /// - Parameters:
        ///   - messages: How many messages arrived in the last ``window``.
        ///   - people: How many different people wrote them.
        ///   - typicalDaily: How many messages an ordinary day here brings.
        ///   - lastBurst: When the previous burst here was called.
        public static func isBurst(
            messages: Int, people: Int, typicalDaily: Double, lastBurst: Date?, now: Date = .now
        ) -> Bool {
            guard messages >= minimumMessages, people >= minimumPeople else { return false }

            // More than half an ordinary day, in half an hour. A family group that sends a
            // hundred messages a day needs fifty; the neighbourhood that sends five needs the
            // minimum above.
            guard Double(messages) > typicalDaily / 2 else { return false }

            if let lastBurst, now.timeIntervalSince(lastBurst) < cooldown { return false }
            return true
        }

        /// The ordinary day, brought up to date with messages that just arrived.
        ///
        /// A moving average that forgets at a steady rate: whatever it knew fades by half in
        /// ten days, and every message adds a little. After a few weeks it settles on how many
        /// messages this group really sends in a day, whenever you happen to look.
        public static func learn(typicalDaily: Double, rise: Int, after interval: TimeInterval) -> Double {
            let faded = typicalDaily * exp(-max(0, interval) / memory)
            return faded + Double(max(0, rise)) * 86_400 / memory
        }

        /// How much the count went up between two looks.
        ///
        /// A count that went down means you read in between, somewhere; everything in the new
        /// count arrived since then.
        public static func rise(from previous: Int, to current: Int) -> Int {
            current >= previous ? current - previous : current
        }

        /// The rises still inside the window, with the new one added.
        public static func log(_ log: String, adding rise: Int, at now: Date) -> String {
            var entries = parse(log).filter { now.timeIntervalSince($0.at) < window }
            if rise > 0 { entries.append((now, rise)) }
            return entries
                .map { "\(Int($0.at.timeIntervalSince1970)):\($0.rise)" }
                .joined(separator: ",")
        }

        /// How many messages the log holds inside the window.
        public static func total(in log: String, now: Date) -> Int {
            parse(log)
                .filter { now.timeIntervalSince($0.at) < window }
                .reduce(0) { $0 + $1.rise }
        }

        static func parse(_ log: String) -> [(at: Date, rise: Int)] {
            log.split(separator: ",").compactMap { entry in
                let parts = entry.split(separator: ":")
                guard parts.count == 2,
                      let seconds = Double(parts[0]),
                      let rise = Int(parts[1])
                else { return nil }
                return (Date(timeIntervalSince1970: seconds), rise)
            }
        }
    }
}
