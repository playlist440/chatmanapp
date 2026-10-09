import SwiftUI
import ChatmanKit

/// The groups, as one row of tiles under the pinned faces.
///
/// A group is not a conversation you answer, it is a noticeboard you glance at: the street,
/// the club, the class. In the same list as the people who asked you something, the people
/// lose, because a busy noticeboard is always the most recent thing that happened. So the
/// groups stay out of that list — but in it, as a section, not on a plate of their own.
///
/// They used to be a shelf of glass along the bottom of the screen that could be pulled up.
/// A second layer of conversations over the first, with the list running underneath the
/// names, on the very spot where iOS puts search. A row in the list is what Photos and Music
/// do with a shelf of things: in sight at a glance, out of the way once you scroll.
struct GroupsRow: View {
    @Environment(ChatSession.self) private var session

    let groups: [Conversation]
    let onOpen: (Conversation) -> Void

    /// Both ends of the transition have to name the same namespace.
    let opening: Namespace.ID

    @ScaledMetric(relativeTo: .caption) private var tileWidth: CGFloat = 76
    @ScaledMetric(relativeTo: .caption) private var face: CGFloat = 52

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(GroupsRow.ordered(groups, by: session)) { group in
                    Button {
                        onOpen(group)
                    } label: {
                        tile(group)
                    }
                    .buttonStyle(.chatmanPress)
                    .matchedTransitionSource(id: group.id, in: opening)
                    // The same menu a chat in the list gets: a group is a chat.
                    .contextMenu { ConversationActions(conversation: group) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }

    private func tile(_ group: Conversation) -> some View {
        let name = session.displayName(for: group)
        let waiting = session.isWaiting(group)

        return VStack(spacing: 5) {
            Avatar(conversation: group, size: face, showsNetwork: false)
                .overlay(alignment: .topTrailing) { mark(group) }

            Text(name)
                .font(.caption)
                .fontWeight(waiting ? .semibold : .regular)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: tileWidth, alignment: .top)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(accessibilityValue(group))
    }

    /// What is waiting in a group: a number, or an @ when it is about you.
    @ViewBuilder
    private func mark(_ group: Conversation) -> some View {
        if session.mentionsYou(group) {
            Image(systemName: "at")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 20, minHeight: 20)
                .background(.blue, in: Circle())
                .overlay { Circle().stroke(Color(.systemBackground), lineWidth: 2) }
                .offset(x: 4, y: -2)
        } else if group.unreadCount > 0 {
            Text(group.unreadCount, format: .number)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(.blue, in: Capsule())
                .overlay { Capsule().stroke(Color(.systemBackground), lineWidth: 2) }
                .offset(x: 6, y: -2)
        } else if group.isManuallyUnread {
            Circle()
                .fill(.blue)
                .frame(width: 12, height: 12)
                .overlay { Circle().stroke(Color(.systemBackground), lineWidth: 2) }
        }
    }

    private func accessibilityValue(_ group: Conversation) -> Text {
        if session.mentionsYou(group) { return Text("Mentions you") }
        if group.unreadCount > 0 { return Text("\(group.unreadCount) unread") }
        return Text(verbatim: "")
    }

    /// Groups about you first, then those with something new, then the rest — each in the
    /// order of the list. The original position breaks ties, because Swift's sort isn't
    /// stable and the right-hand end is the one a thumb learns.
    static func ordered(_ groups: [Conversation], by session: ChatSession) -> [Conversation] {
        func rank(_ group: Conversation) -> Int {
            if session.needsYou(group) { return 0 }
            return session.isWaiting(group) ? 1 : 2
        }
        return groups.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }
}

/// Every group, as a plain list. Where "All" in the groups row leads.
struct AllGroupsView: View {
    @Environment(ChatSession.self) private var session

    let groups: [Conversation]
    let onOpen: (Conversation) -> Void

    var body: some View {
        List {
            ForEach(GroupsRow.ordered(groups, by: session)) { group in
                Button {
                    onOpen(group)
                } label: {
                    ConversationRow(conversation: group)
                        .contentShape(.rect)
                }
                .buttonStyle(.chatmanRow)
                .contextMenu { ConversationActions(conversation: group) }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Groups")
        .navigationBarTitleDisplayMode(.inline)
    }
}
