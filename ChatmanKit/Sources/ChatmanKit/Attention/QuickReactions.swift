import Foundation

/// The emoji a reaction is picked from without opening a grid.
///
/// Apple's six, in Apple's order, on the phone and on the watch alike — so a thumb that knows
/// where the heart is on one knows it on the other. Plus one place that learns: the emoji you
/// use most that isn't among the six, counted from your own reactions on this device.
///
/// The seventh changes rarely on purpose. A place that moves every time you use something new
/// is a place your thumb can't learn, so a newcomer has to be clearly ahead, and it can only
/// happen once a week.
public enum QuickReactions {

    /// Apple's own six.
    public static let standard = ["❤️", "👍", "👎", "😂", "‼️", "❓"]

    private static let countsKey = "chatman.reactionCounts"
    private static let chosenKey = "chatman.learnedReaction"
    private static let chosenAtKey = "chatman.learnedReactionAt"

    /// The six, and the learned one when there is one.
    public static func row(defaults: UserDefaults = .standard) -> [String] {
        guard let learned = learned(defaults: defaults) else { return standard }
        return standard + [learned]
    }

    /// The learned seventh, if one has earned its place.
    public static func learned(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: chosenKey)
    }

    /// Emoji you use most, for a "frequently used" row. The six included.
    public static func frequent(limit: Int = 8, defaults: UserDefaults = .standard) -> [String] {
        counts(defaults: defaults)
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// Counts one use of an emoji, and moves the seventh place if it has earned it.
    public static func note(_ emoji: String, defaults: UserDefaults = .standard, now: Date = .now) {
        var counts = counts(defaults: defaults)
        counts[emoji, default: 0] += 1
        defaults.set(counts, forKey: countsKey)

        let current = defaults.string(forKey: chosenKey)
        let contender = counts
            .filter { !standard.contains($0.key) }
            .max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }

        guard let contender, contender.key != current else { return }

        // The first one needs three uses to be more than an accident. A replacement has to be
        // well ahead, and only once a week.
        guard let current else {
            if contender.value >= 3 { choose(contender.key, defaults: defaults, now: now) }
            return
        }

        let held = counts[current] ?? 0
        let chosenAt = defaults.object(forKey: chosenAtKey) as? Date ?? .distantPast
        let settled = now.timeIntervalSince(chosenAt) >= 7 * 24 * 60 * 60

        if settled, Double(contender.value) >= Double(held) * 1.5 + 2 {
            choose(contender.key, defaults: defaults, now: now)
        }
    }

    private static func choose(_ emoji: String, defaults: UserDefaults, now: Date) {
        defaults.set(emoji, forKey: chosenKey)
        defaults.set(now, forKey: chosenAtKey)
    }

    private static func counts(defaults: UserDefaults) -> [String: Int] {
        defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
    }
}
