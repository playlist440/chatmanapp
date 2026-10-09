import SwiftUI
import SwiftData
import ChatmanKit

/// Where the watch can go from its list.
///
/// The groups and the archive are screens of their own, pushed like a conversation. That is
/// what gives them the system's own way back — swiping in from the edge — which the archive,
/// as the same list with a flag turned over, never had.
enum WatchRoute: Hashable {
    case conversation(Conversation)
    case groups
    case archive
}

/// Your conversations, on the wrist.
struct WatchConversationListView: View {
    @Environment(ChatSession.self) private var session

    /// The navigation stack this list sits in, so a new chat can be opened straight away.
    @Binding var path: [WatchRoute]

    @Query(sort: \Conversation.lastActivity, order: .reverse)
    private var allConversations: [Conversation]

    /// Everything worth showing: no bridge plumbing, and no status feed unless it's wanted.
    ///
    /// A bridge creates a room to talk to you in, and every other Matrix client shows it
    /// sitting between your friends under a name like "signalbot". What counts as plumbing
    /// is decided in one place, so the phone and the watch can't disagree about it.
    private var conversations: [Conversation] {
        // What was typed wins over every other filter: looking somebody up is looking
        // somebody up, whichever list you happened to be standing in.
        //
        // Read from state, not searched here. Asking the store from inside a computed
        // property a view body reads means a fetch of every conversation and a text search
        // over every message — on every redraw, on the slowest chip in the house.
        if needle.count >= 2 { return found }

        return everyday.filter { !isLifted($0) }
    }

    /// The chats you pinned, lifted out of the list into the row of faces at the top.
    ///
    /// Pinning lives with the account now — a room tag — so what you pin on the phone is
    /// pinned here without the two devices having to agree about anything.
    private var pinned: [Conversation] {
        everyday.filter(isLifted)
    }

    /// Whether a chat belongs in the row rather than in the list. In two places at once it
    /// would only be the same chat twice.
    private func isLifted(_ conversation: Conversation) -> Bool {
        conversation.isPinned && needle.count < 2
    }

    /// Everything worth showing, before pinned and unpinned part ways.
    private var everyday: [Conversation] {
        allConversations.filter { conversation in
            if session.isHidden(conversation) { return false }
            // The archive is a place you go to, not a thing mixed into the list.
            if conversation.isArchived { return false }
            // Waiting, not merely counted. A chat you marked unread yourself has no number,
            // and asking for the number hid it from this filter while its face in the row
            // above still wore the badge that says it is waiting.
            if showsUnreadOnly, !session.isWaiting(conversation) { return false }
            return true
        }
    }

    /// Whether the list is split into people and the door to the groups.
    ///
    /// Not while searching: a search shows whatever matches, groups included.
    private var splitsGroups: Bool {
        needle.count < 2
    }

    /// The people: private chats, the list itself.
    ///
    /// The phone keeps its groups on a shelf along the bottom. The watch has no room for a
    /// shelf, so they have a screen of their own behind one row at the top — and the people
    /// who actually asked you something are what fills the screen when you raise your wrist.
    private var people: [Conversation] {
        splitsGroups ? conversations.filter { !$0.isGroup } : conversations
    }

    /// Every group, for the row that leads to them. Pinned ones too: that screen is where
    /// all the groups are, whatever else they are.
    private var allGroups: [Conversation] {
        allConversations.filter { $0.isGroup && !$0.isArchived && !session.isHidden($0) }
    }

    /// What is being searched for, with the spaces taken off.
    private var needle: String {
        query.trimmingCharacters(in: .whitespaces)
    }

    /// How many chats are put away, so an empty drawer doesn't get a door.
    private var archivedCount: Int {
        allConversations.filter { $0.isArchived && !session.isHidden($0) }.count
    }

    /// How much is waiting inside the archive, which is the only thing worth saying about it
    /// from the outside.
    private var archivedUnread: Int {
        allConversations
            .filter { $0.isArchived && !session.isHidden($0) }
            .reduce(0) { $0 + $1.unreadCount }
    }

    /// What an empty list says, which depends on why it is empty.
    private var emptyTitle: String {
        if needle.count >= 2 { return "Nothing found" }
        return showsUnreadOnly ? "Nothing unread" : "No chats yet"
    }

    private var emptySymbol: String {
        if needle.count >= 2 { return "magnifyingglass" }
        return showsUnreadOnly ? "checkmark.circle" : "bubble.left.and.bubble.right"
    }

    /// How many conversations have something waiting, whatever the filter is doing.
    ///
    /// The same question the filter asks. Counting only numbers left the button greyed out
    /// when the one thing waiting was a chat marked unread by hand — the one chat the filter
    /// would have shown.
    private var unreadConversations: Int {
        allConversations.filter {
            session.isWaiting($0) && !$0.isArchived && !session.isHidden($0)
        }.count
    }

    @State private var isPresentingNewChat = false

    /// Whether the list is showing only what you haven't read. The same toggle as on the
    /// phone, in the same corner, because the two shouldn't need learning separately.
    @State private var showsUnreadOnly = false

    /// The conversation a new chat just created.
    @State private var startedConversationID: String?

    /// What is being searched for. Empty means nobody is searching.
    @State private var query = ""

    /// Whether the search row has been pulled into view.
    @State private var showsSearch = false


    /// What the last search turned up.
    @State private var found: [Conversation] = []

    /// How the fetching is going, in the space of a few points beside the title.
    ///
    /// A watch screen is a hundred and eighty points wide and most of it is the conversation
    /// list. Spending a whole line of it on "Updating…" pushes a chat off the bottom to say
    /// something nobody asked — and it says it in a row, where anything that appears looks
    /// like it wants doing something about. Here it is where the eye already is, costs no
    /// room, and reads at a glance: turning means busy, a green dot means done.
    ///
    /// Failure is the one case that keeps a line of its own. That is worth losing a chat
    /// over, and it needs the words.
    @ViewBuilder
    private var titleMark: some View {
        if session.isReconnecting {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
        } else if session.justReconnected {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .transition(.opacity)
        }
    }

    var body: some View {
        // Only trouble gets a line of its own. Catching up and having caught up are drawn
        // beside the title instead — see `titleMark`.
        VStack(spacing: 0) {
            if case .offline(let reason) = session.state {
                WatchOfflineBanner(reason: reason)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
            } else if let problem = session.bridgeProblems.first {
                // A bridge that stopped, which on the wrist is otherwise indistinguishable
                // from a quiet day. Mending it needs a code or a QR scan, so that is the
                // phone's job; the watch only says so.
                Label {
                    Text(problem.isUnanswered
                         ? "\(problem.network.displayName) bridge not answering"
                         : "\(problem.network.displayName) disconnected · reconnect on iPhone")
                        .font(.caption2)
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "link.badge.plus")
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            }

            List {
                // Out of sight, one pull down away — the same gesture as on the phone, and
                // the same reason: a search box and a door to the archive parked at the top
                // of a watch screen would cost two of the four rows that fit on it.
                if showsSearch || !query.isEmpty {
                    WatchSearchRow(query: $query)
                        .listRowBackground(Color.clear)
                }

                if showsSearch, query.isEmpty, archivedCount > 0 {
                    Button {
                        path.append(.archive)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "archivebox")
                            Text("Archived")
                                .font(.footnote)
                            Spacer(minLength: 0)
                            if archivedUnread > 0 {
                                Text(archivedUnread.formatted())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.chatmanRow)
                }

                // Somebody asking to be let in, above everything else.
                ForEach(session.invitations) { invitation in
                    WatchInvitationRow(
                        invitation: invitation,
                        onAccept: { withAnimation { session.accept(invitation) } },
                        onDecline: { withAnimation { session.decline(invitation) } }
                    )
                }

                // The pinned faces scroll away with everything else here, and on the phone
                // they don't. That is a decision, not an oversight.
                //
                // The phone has room to give: a row held at the top costs a fraction of the
                // screen and buys you the chats you reach for most, always in the same place.
                // A watch is 205 points wide and about 250 tall, and the same row is most of
                // what fits — holding it there would leave two chats visible under it and
                // turn the list into a letterbox. What is scarce differs, so the answer does.
                if !pinned.isEmpty {
                    WatchPinnedRow(conversations: pinned) { path.append(.conversation($0)) }
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowBackground(Color.clear)
                }

                // The door to the groups, at the top where it can be seen without scrolling
                // past everybody you know. It says what is waiting in there, so it also says
                // whether it is worth going in.
                if splitsGroups, !allGroups.isEmpty {
                    WatchGroupsRow(groups: allGroups) { path.append(.groups) }
                }

                // A button that pushes rather than a navigation link, for the reason
                // measured on the phone: a link spends its thinking time before anything
                // moves, a button while the screen is already on its way. A watch has less
                // to spare than a phone, so it matters more here, not less.
                ForEach(people) { conversation in
                    WatchChatRow(conversation: conversation) { path.append(.conversation($0)) }
                }
            }
            // The crown is the list's without being asked for.
            //
            // watchOS gives the crown to a scroll view by itself, as long as there is only
            // one. There used to be two — the pinned chats scrolled sideways — and the system
            // stopped choosing, so the list claimed the crown by hand: made itself focusable,
            // and took the focus back after every chat, sheet, search and archive. It never
            // held for long, and a scroll view that is also a focus target turns the crown
            // through the focus system instead of scrolling with it, which is where the
            // judder came from. The pinned chats are a grid now, there is one scroll view
            // again, and none of that is needed.
            // How far the list has been dragged past its own top. A shorter pull than the
            // phone asks for: there is less screen to drag across, and the crown does most
            // of the scrolling anyway.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                if offset < -34, !showsSearch {
                    withAnimation(.snappy) { showsSearch = true }
                }

                // Scrolled well into the list: put it away again, so it isn't sitting there
                // the next time you come back to the top.
                if offset > 60, query.isEmpty, showsSearch {
                    withAnimation(.snappy) { showsSearch = false }
                }
            }
        }
        // Searched once per pause in the typing, and cancelled the moment the next letter
        // arrives.
        .task(id: needle) {
            guard needle.count >= 2 else {
                found = []
                return
            }

            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }

            found = session.search(needle).conversations
        }
        .navigationTitle {
            HStack(spacing: 4) {
                titleMark
                Text("Chats")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation { showsUnreadOnly.toggle() }
                } label: {
                    Image(systemName: showsUnreadOnly
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .disabled(unreadConversations == 0 && !showsUnreadOnly)
            }

            // Where Messages puts it. The clock gives way, which is a fair trade on a watch
            // that already shows the time on its face.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingNewChat = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        // Asks the bridges how they're doing and which rooms are their own bookkeeping —
        // when that is due, not every time this screen comes back from a chat. See
        // `tidyUpIfDue`: it used to run it all on every return, over the watch's own radio.
        .task { await session.tidyUpIfDue() }
        .navigationDestination(for: WatchRoute.self) { route in
            switch route {
            case .conversation(let conversation):
                WatchConversationView(conversation: conversation)
            case .groups:
                WatchGroupsView(path: $path)
            case .archive:
                WatchArchiveView(path: $path)
            }
        }
        .sheet(isPresented: $isPresentingNewChat, onDismiss: openStartedConversation) {
            NavigationStack {
                WatchNewChatView(startedConversationID: $startedConversationID)
            }
        }
        .overlay {
            // Invitations count as something to show. Without them in the question, an
            // account whose only news was an invitation got "No chats yet" drawn over it —
            // on top of the very buttons that answer it.
            if conversations.isEmpty, pinned.isEmpty, session.invitations.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySymbol
                )
            }
        }
    }
}

private extension WatchConversationListView {
    /// Opens the chat that was just started, once the sheet is out of the way.
    func openStartedConversation() {
        guard let id = startedConversationID else { return }
        startedConversationID = nil

        guard let conversation = session.conversation(withID: id) else { return }
        path.append(.conversation(conversation))
    }
}

/// One chat in a list, with the three things worth doing to it without opening it.
///
/// Swiped, the way Mail and Messages on the watch do it. Pinning is how you tell the watch
/// face "this one always counts", and muting how you tell it "this one never does"; both are
/// kept with the account, so the phone agrees without being told. Shared by the list, the
/// groups and the archive, so a chat behaves the same wherever it is found.
struct WatchChatRow: View {
    @Environment(ChatSession.self) private var session

    let conversation: Conversation
    let onOpen: (Conversation) -> Void

    var body: some View {
        Button {
            onOpen(conversation)
        } label: {
            WatchConversationRow(conversation: conversation)
        }
        .buttonStyle(.chatmanRow)
        // All three on the right. The left edge belongs to going back: on the groups and
        // the archive, a pin waiting on the left meant that swiping back from a row pinned
        // the chat instead — the same movement, meaning two opposite things.
        .swipeActions(edge: .trailing) {
            // Not for something put away: pinning what you archived is a contradiction.
            if !conversation.isArchived {
                Button {
                    withAnimation { session.setPinned(!conversation.isPinned, for: conversation) }
                } label: {
                    Label(conversation.isPinned ? "Unpin" : "Pin",
                          systemImage: conversation.isPinned ? "pin.slash.fill" : "pin.fill")
                }
                .tint(.orange)
            }

            Button {
                Task { await session.setMuted(!conversation.isMuted, for: conversation) }
            } label: {
                Label(conversation.isMuted ? "Unmute" : "Mute",
                      systemImage: conversation.isMuted ? "bell.fill" : "bell.slash.fill")
            }
            .tint(.indigo)

            Button {
                withAnimation { session.setArchived(!conversation.isArchived, for: conversation) }
            } label: {
                Label(conversation.isArchived ? "Unarchive" : "Archive",
                      systemImage: conversation.isArchived ? "tray.and.arrow.up.fill" : "archivebox.fill")
            }
            .tint(.gray)
        }
    }
}

/// The groups, on a screen of their own.
///
/// About you first — somebody named you or answered you, or something is going on — then
/// anything new, then the rest, in the order they last spoke. Reading one and coming back
/// lands you here again, ready for the next.
struct WatchGroupsView: View {
    @Environment(ChatSession.self) private var session

    @Binding var path: [WatchRoute]

    @Query(sort: \Conversation.lastActivity, order: .reverse)
    private var allConversations: [Conversation]

    private var groups: [Conversation] {
        allConversations
            .filter { $0.isGroup && !$0.isArchived && !session.isHidden($0) }
            .enumerated()
            .sorted { ($0.element.rank(in: session), $0.offset) < ($1.element.rank(in: session), $1.offset) }
            .map(\.element)
    }

    var body: some View {
        List {
            ForEach(groups) { conversation in
                WatchChatRow(conversation: conversation) { path.append(.conversation($0)) }
            }
        }
        .navigationTitle("Groups")
        .watchEdgeBack()
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("No groups", systemImage: "person.3")
            }
        }
    }
}

/// What you put away, on a screen of its own — with the system's own way back.
struct WatchArchiveView: View {
    @Environment(ChatSession.self) private var session

    @Binding var path: [WatchRoute]

    @Query(sort: \Conversation.lastActivity, order: .reverse)
    private var allConversations: [Conversation]

    private var archived: [Conversation] {
        allConversations.filter { $0.isArchived && !session.isHidden($0) }
    }

    var body: some View {
        List {
            ForEach(archived) { conversation in
                WatchChatRow(conversation: conversation) { path.append(.conversation($0)) }
            }
        }
        .navigationTitle("Archived")
        .watchEdgeBack()
        .overlay {
            if archived.isEmpty {
                ContentUnavailableView("Nothing archived", systemImage: "archivebox")
            }
        }
    }
}

/// Somebody asking you into a room.
///
/// A bridge's rooms are taken without asking; a person's is a question. Two taps' worth of
/// answer, which is all a watch has room for.
private struct WatchInvitationRow: View {
    let invitation: ChatSession.Invitation
    let onAccept: () -> Void
    let onDecline: () -> Void

    private var who: String {
        guard invitation.inviter.hasPrefix("@") else { return invitation.inviter }
        return String(invitation.inviter.dropFirst().prefix { $0 != ":" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(invitation.name ?? "A conversation")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)

            Text(invitation.inviter.isEmpty ? "Invitation" : "from \(who)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                Button(action: onDecline) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.chatmanPress)
                .chatmanGlass(in: .capsule, interactive: true)

                Button(action: onAccept) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(.chatmanPress)
                .chatmanGlass(in: .capsule, interactive: true, tint: .blue)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The chats you pinned, as faces in a grid.
///
/// A grid and not a row that scrolls sideways. A second scroll view inside the list is a
/// second thing the Digital Crown could belong to, and with two of them watchOS stopped giving
/// it to either: the list had to grab the crown by hand, and that is what made scrolling
/// judder and sometimes not work at all. A grid doesn't scroll, so there is one scroll view,
/// and the crown simply works.
///
/// Laid out for how many there are: two side by side, three across from five on, and
/// four as two pairs rather than three and a straggler.
private struct WatchPinnedRow: View {
    let conversations: [Conversation]
    let onOpen: (Conversation) -> Void

    /// At the largest text sizes, one face per line: a name that big doesn't fit under a
    /// face a third of the screen wide.
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: Int {
        if typeSize.isAccessibilitySize { return 1 }
        return switch conversations.count {
        case 1: 1
        case 2, 4: 2
        default: 3
        }
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(64), spacing: 2), count: columns),
            spacing: 4
        ) {
            ForEach(conversations) { conversation in
                Button {
                    onOpen(conversation)
                } label: {
                    WatchPinnedFace(conversation: conversation)
                }
                .buttonStyle(.chatmanPress)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// One pinned chat on the watch: a face, a name, and how much is waiting.
private struct WatchPinnedFace: View {
    @Environment(ChatSession.self) private var session

    let conversation: Conversation

    /// Larger than a chat row is tall, on purpose.
    ///
    /// This row started out held inside the height of one line of the list, and at that size
    /// the faces read as smaller than the chats underneath them — the opposite of what
    /// pinning means. The height rule lost: these are the chats that matter most, so they
    /// are the biggest thing on the screen.
    ///
    /// The name sits under the face as plain words, as on the phone.
    private let size: CGFloat = 55

    /// How wide one face and its name are allowed to be: a third of the narrowest screen.
    private let column: CGFloat = 64

    /// Just the first word. On a screen this wide there is room for one.
    private var shortName: String {
        let full = session.displayName(for: conversation)
        guard let first = full.split(separator: " ").first else { return full }
        return String(first)
    }

    var body: some View {
        WatchAvatar(conversation: conversation, size: size)
            .overlay(alignment: .topTrailing) {
                if session.isWaiting(conversation) { badge }
            }
            // Given the column's width before the pill is hung on it. An overlay is offered
            // the size of what it covers, so hung on the face itself the pill could only be
            // as wide as the face — and every name would come out cut short.
            .frame(width: column)
            // The name under the face as plain words, as on the phone and in Messages. It used
            // to hang over the bottom of the face on a capsule of glass: two shapes for one name.
            .overlay(alignment: .bottom) {
                Text(shortName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: column)
                    .alignmentGuide(.bottom) { $0[.top] - 3 }
            }
            .padding(.bottom, 18)
            // One element for VoiceOver: who, and how much is waiting.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.displayName(for: conversation))
            .accessibilityValue(
                conversation.unreadCount > 0
                    ? Text("\(conversation.unreadCount) unread")
                    : Text(verbatim: "")
            )
    }

    private var badge: some View {
        ZStack {
            Image(systemName: "bubble.fill")
                .font(.title3)
                .foregroundStyle(.blue)

            if conversation.unreadCount > 0 {
                Text(conversation.unreadCount > 9 ? "9+" : conversation.unreadCount.formatted())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .offset(y: -1)
            }
        }
        .offset(x: 5, y: -3)
    }
}

/// One row. Deliberately plain: on a screen this size, a name, a snippet and an unread dot
/// are all that fit before it stops being readable at a glance.
private struct WatchConversationRow: View {
    @Environment(ChatSession.self) private var session

    let conversation: Conversation

    var body: some View {
        HStack(spacing: 7) {
            // A face is quicker to place than a name, even on a screen this size — and it's
            // what makes the list scannable at a glance instead of readable at a stop.
            WatchAvatar(conversation: conversation)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    // Waiting, the same question the filter and the pinned badge ask: a chat
                    // marked unread by hand passed the filter and then showed up without a
                    // mark, as if it had got in by mistake.
                    if session.mentionsYou(conversation) {
                        // Somebody named you or answered you — "you", where the dot says "new".
                        Text("@")
                            .font(.caption2.weight(.bold)).fontDesign(.rounded)
                            .foregroundStyle(.white)
                            .frame(width: 12, height: 12)
                            .background(Color.blue, in: Circle())
                    } else if session.isWaiting(conversation) {
                        // Blue by name, not by accent: the accent colour follows the watch
                        // face, and this dot has to mean the same thing whatever face is on.
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                    }

                    Text(session.displayName(for: conversation))
                        .font(.headline)
                        .lineLimit(1)

                    // Said quietly, so a swipe that muted something visibly did.
                    if conversation.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                PreviewText(session.preview(for: conversation))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A strip along the left edge that goes back when you drag it.
///
/// watchOS already goes back on a swipe from the edge, but only from the very edge: start a
/// few points in — on a row or a bubble, which is where a thumb lands — and the touch belongs
/// to whatever is under it and the swipe does nothing. This adds to the system's gesture
/// rather than fighting it: if the system claims the drag, this never sees it. On every
/// screen that is pushed, so going back works the same everywhere.
struct WatchEdgeBack: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            Color.clear
                .frame(width: 16)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onEnded { value in
                            guard value.translation.width > 40,
                                  abs(value.translation.height) < 60
                            else { return }
                            dismiss()
                        }
                )
                .ignoresSafeArea()
        }
    }
}

extension View {
    func watchEdgeBack() -> some View { modifier(WatchEdgeBack()) }
}

/// The door to the groups, at the top of the list.
///
/// It says how many have something new, and marks it when one of them is about you, so the
/// row answers whether it's worth going in before you go in.
private struct WatchGroupsRow: View {
    @Environment(ChatSession.self) private var session

    let groups: [Conversation]
    let onOpen: () -> Void

    private var fresh: Int { groups.filter { $0.unreadCount > 0 || $0.isManuallyUnread }.count }
    private var aboutYou: Bool { groups.contains(where: session.needsYou) }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 7) {
                // A way in, not a notice: the icon in colour, and what's new said in words
                // underneath rather than with a dot in front of the name.
                Image(systemName: "person.3.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.gradient, in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text("Groups")
                        .font(.headline)

                    Text(aboutYou ? "Mentions you" : (fresh == 0 ? "Nothing new" : "\(fresh) with news"))
                        .font(.caption2)
                        .foregroundStyle(aboutYou ? Color.blue : .secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.chatmanRow)
    }
}

extension Conversation {
    /// Where a group goes in a list of groups: about you, then new, then the rest.
    @MainActor
    func rank(in session: ChatSession) -> Int {
        if session.needsYou(self) { return 0 }
        return unreadCount > 0 ? 1 : 2
    }
}

/// The picture beside a conversation, or its initials when there isn't one.
///
/// Small on purpose. The watch has room for a face or for words, not both at full size, and
/// the words are what you came for — the picture is only there to find them faster.
private struct WatchAvatar: View {
    @Environment(ChatSession.self) private var session

    let conversation: Conversation

    /// How big, in points. The list draws it small; the pinned row rather larger.
    var size: CGFloat = 28

    private var initials: String {
        let words = session.displayName(for: conversation).split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        RemoteImage(
            request: session.avatarRequest(for: conversation.avatarURL, size: 96),
            cacheKey: conversation.avatarURL
        ) {
            // The picture from the phone's address book, when there is one. On this side
            // there is no address book to read, so what the phone sent is all there is.
            // Decoded once and kept. This is drawn for every row that scrolls into view, and
            // turning the bytes into a picture each time is work the crown waits on.
            if let image = session.contactPicture(for: conversation) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                // In colour, the same as on the phone: one person is one colour everywhere.
                Circle()
                    .fill(Monogram.gradient(for: session.displayName(for: conversation)))
                    .overlay {
                        Text(initials)
                            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

/// Shown when syncing is failing but there are still cached conversations worth using.
///
/// Says what went wrong rather than only that something did. Away from the phone that
/// distinction is the whole message: "no internet on this device" is something you can fix by
/// walking outside, and "server didn't answer" is not.
private struct WatchOfflineBanner: View {
    @Environment(ChatSession.self) private var session

    let reason: String

    var body: some View {
        Button { session.reconnect() } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label("Not connected", systemImage: "wifi.exclamationmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)

                if session.isCheckingReachability {
                    Text("Checking the server…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(session.reachability?.summary ?? reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text("Tap to try again")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// The search box, as a list row.
///
/// A `TextFieldLink` rather than a `TextField`: a watch text field draws a grey slab that no
/// amount of styling talks it out of, and tapping it opens the system's typing screen anyway.
/// This is that screen, with the row underneath it drawn the way the rest of the app is.
private struct WatchSearchRow: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            TextFieldLink(prompt: Text("Search chats")) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    Text(query.isEmpty ? "Search" : query)
                        .font(.footnote)
                        .foregroundStyle(query.isEmpty ? .secondary : .primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .chatmanGlass(in: .capsule)
            } onSubmit: { typed in
                withAnimation { query = typed }
            }
            .buttonStyle(.plain)

            // Only once there is something to clear. A cross sitting there permanently is a
            // button that does nothing, on a screen with no room for one.
            if !query.isEmpty {
                Button {
                    withAnimation { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
