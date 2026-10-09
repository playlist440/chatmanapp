import WidgetKit
import SwiftUI
import ChatmanKit

/// Chatman on the watch face.
///
/// The point is the first tap. Getting to a message meant pressing the crown, finding the app
/// among the others and waiting for it to start — three steps to read one line. From the face
/// it's one, and the number is readable without any of them.
///
/// It shows who is waiting on you, not how many messages arrived: three people wanting you is
/// worth a glance, and "47" mostly says a group chat is busy. Which conversations count is
/// decided by the rules in `Attention` — people and pinned chats, and a group only when it is
/// about you.
struct ChatmanComplication: Widget {

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ChatmanUnread", provider: UnreadProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Chatman")
        .description("Open Chatman, and see what's waiting.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

@main
struct ChatmanComplicationBundle: WidgetBundle {
    var body: some Widget {
        ChatmanComplication()
    }
}

struct UnreadEntry: TimelineEntry {
    let date: Date
    let snapshot: UnreadBadge.Snapshot

    var unread: Int { snapshot.count }

    /// High when someone is waiting, so the Smart Stack brings Chatman up then — and leaves
    /// it down when there is nothing to see.
    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: unread > 0 ? Float(min(unread, 5)) : 0)
    }

    /// Whether what the app last heard is old enough to say so.
    ///
    /// Without push, the face is only as fresh as the last time the watch was allowed to
    /// look. That is usually minutes; on a bad day it's an afternoon, and "Anna" on the face
    /// at five o'clock is a different claim when it was true at two.
    var isStale: Bool {
        guard let synced = snapshot.syncedAt else { return false }
        return date.timeIntervalSince(synced) > UnreadProvider.staleAfter
    }
}

/// Reads what the app left behind.
///
/// The app asks for a redraw whenever who is waiting changes, so this timeline is short and
/// dull on purpose: an entry now, one more for the moment the news turns stale, and a standing
/// request to come back in a while in case the app never got the chance to ask.
struct UnreadProvider: TimelineProvider {

    /// After this long without hearing from the server, the face says when it last did.
    static let staleAfter: TimeInterval = 30 * 60

    func placeholder(in context: Context) -> UnreadEntry {
        UnreadEntry(date: .now, snapshot: .init(count: 2, names: ["Anna", "Piet"]))
    }

    func getSnapshot(in context: Context, completion: @escaping (UnreadEntry) -> Void) {
        let snapshot = context.isPreview
            ? UnreadBadge.Snapshot(count: 2, names: ["Anna", "Piet"])
            : UnreadBadge.read()
        completion(UnreadEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UnreadEntry>) -> Void) {
        let snapshot = UnreadBadge.read()
        var entries = [UnreadEntry(date: .now, snapshot: snapshot)]

        // The moment it goes stale, drawn in advance, so the face changes by itself even if
        // the app never gets to run again before then.
        if let synced = snapshot.syncedAt {
            let turns = synced.addingTimeInterval(Self.staleAfter)
            if turns > .now { entries.append(UnreadEntry(date: turns, snapshot: snapshot)) }
        }

        let again = Date.now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: entries, policy: .after(again)))
    }
}

/// One drawing, laid out for whichever slot the face has room for.
struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family

    let entry: UnreadEntry

    private var unread: Int { entry.unread }

    var body: some View {
        switch family {
        case .accessoryInline:
            // A single line of text beside the date. No room for anything but the point.
            Text(unread > 0 ? "Chatman · \(unread)" : "Chatman")

        case .accessoryCorner:
            ChatmanMark(count: unread)
                .padding(2)
                .widgetLabel { unread > 0 ? Text("\(unread) waiting") : Text(verbatim: "Chatman") }

        case .accessoryRectangular:
            HStack(spacing: 8) {
                ChatmanMark(count: unread)
                    .frame(width: 30, height: 30)
                    // Takes the face's tint on a tinted face, like Apple's own marks.
                    .widgetAccentable()

                VStack(alignment: .leading, spacing: 1) {
                    Text("Chatman")
                        .font(.headline)
                    // Who, not how many: "Anna, Piet" is something you can decide on from the
                    // wrist, "2 chats waiting" is a reason to open the app and find out.
                    // Hidden while the wrist is down, like any name on a watch face.
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .privacySensitive(!entry.snapshot.names.isEmpty)
                    if entry.isStale, let synced = entry.snapshot.syncedAt {
                        Text("Updated \(synced.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        default:
            // Circular, and the one most people will use. Always the mark, with the number
            // inside it — the icon shouldn't disappear the moment something arrives, which
            // is exactly when you most need to know which app is talking to you.
            ChatmanMark(count: unread)
                .padding(3)
        }
    }

    private var summary: String {
        let names = entry.snapshot.names
        if unread == 0 { return String(localized: "Nothing waiting") }
        if names.isEmpty { return String(localized: "\(unread) chats waiting") }

        let shown = names.joined(separator: ", ")
        let rest = unread - names.count
        return rest > 0 ? "\(shown) +\(rest)" : shown
    }
}
