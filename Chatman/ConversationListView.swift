import SwiftUI
import SwiftData
import ChatmanKit

/// Your conversations, most recent first.
struct ConversationListView: View {
    @Environment(ChatSession.self) private var session

    /// Sorted by the store rather than in Swift, so the list updates as messages arrive
    /// without recomputing anything.
    @Query(sort: \Conversation.lastActivity, order: .reverse)
    private var allConversations: [Conversation]

    /// Everything worth showing: no bridge plumbing, and no status feed unless it's wanted.
    ///
    /// A bridge creates a room to talk to you in, and every other Matrix client shows it
    /// sitting between your friends under a name like "signalbot". What counts as plumbing
    /// is decided in one place, so the phone and the watch can't disagree about it.
    /// Everything the screen needs to know about the list, worked out in one go.
    ///
    /// It used to be four computed properties, each walking every conversation and each
    /// asking `isHidden` about every one of them — so a redraw asked the same question four
    /// times per chat. That question is not free: it lowercases the name and searches it
    /// three times over, and reads two properties back out of the store. Measured over two
    /// hundred conversations the four passes cost 1.5 ms of every redraw on a Mac, which is
    /// several times that on the phone this has to be quick on.
    private struct Tally {
        var shown: [Conversation] = []

        /// The ones lifted out of the list into the row of faces at the top.
        var pinned: [Conversation] = []

        /// The groups, kept out of the list of people. See ``GroupsRow``.
        var boards: [Conversation] = []

        /// Whether there is nothing to show at all.
        ///
        /// Both, not just the list: pin every chat you have and the list below is empty
        /// while the row above it is full, and "No chats yet" would be drawn over the very
        /// faces it is denying the existence of.
        var isEmpty: Bool { shown.isEmpty && pinned.isEmpty && boards.isEmpty }

        var archived = 0
        var archivedUnread = 0
        var unread = 0
    }

    private var tally: Tally {
        var result = Tally()

        for conversation in allConversations {
            if session.isHidden(conversation) { continue }

            if conversation.isArchived {
                result.archived += 1
                result.archivedUnread += conversation.unreadCount
            }

            // The same test the filter itself uses, so the button is never off while there
            // is something to filter to. Counting only real unread messages left a chat you
            // had marked unread yourself out: with nothing else waiting the button stayed
            // off, and the one chat you had flagged could not be got at through it.
            if session.isWaiting(conversation), conversation.isArchived == showsArchive {
                // The archive is not in this list, so what's waiting in there can't be
                // filtered to. Counting it would leave the button enabled and the screen
                // empty.
                result.unread += 1
            }

            guard conversation.isArchived == showsArchive else { continue }
            if showsUnreadOnly, !session.isWaiting(conversation) { continue }

            // Pinned chats leave the list and become faces along the top. In two places at
            // once they would only be the same chat twice, and the row exists precisely so
            // the ones you reach for most don't have to be found in a list at all.
            if conversation.isPinned, !showsArchive {
                result.pinned.append(conversation)
            } else if conversation.isGroup, !showsArchive {
                // A group is a noticeboard, not a conversation you answer. In the list it
                // wins on recency every time somebody says something in the street app,
                // and the person who actually asked you a question loses. Pinned still
                // beats this: a group you care about is a face at the top.
                result.boards.append(conversation)
            } else {
                result.shown.append(conversation)
            }
        }

        return result
    }

    @State private var isPresentingNewChat = false

    /// At the largest text sizes faces and tiles turn into ordinary rows: a row of circles
    /// with names under them has no room left for names that size.
    @Environment(\.dynamicTypeSize) private var typeSize
    /// What a conversation grows out of when you open one.
    ///
    /// Taken out once and brought back, on better footing. It was the rows that made it feel
    /// slow, not the animation: a navigation link spent 197 ms deciding before anything moved,
    /// so the unfolding began late and then held the screen. Off a button the push starts in
    /// 3 ms, and the same animation is now covering work that used to happen in silence.
    @Namespace private var openingChat

    /// Everything around the list that moves while it scrolls: how far the pinned faces have
    /// folded, how far the shelf is open, and where the title, the faces and the shelf end.
    ///
    /// Measured rather than counted out — see the conversation screen, where guessing at this
    /// took three goes — and kept in an object of its own, so that following a scroll frame by
    /// frame redraws the faces, the shelf and the fades and never the list. See ``ListChrome``.
    @State private var chrome = ListChrome()


    @State private var isPresentingSettings = false

    /// A bridge being connected again, from the line in the list that said it had stopped.
    @State private var reconnecting: ChatSession.BridgeProblem?

    /// Whether the list is showing only what you haven't read.
    ///
    /// A toggle rather than a mode you have to leave: it survives nothing, resets when the
    /// app does, and the button says which state it's in.
    @State private var showsUnreadOnly = false

    /// Whether the list is showing the archive instead of the everyday chats.
    @State private var showsArchive = false

    /// What's being searched for. Empty means the field is there but nobody is using it.
    @State private var query = ""

    /// Whether a fetch asked for by hand is under way.
    @State private var isRefreshing = false

    /// Carried into a new chat when the search turned up nobody.
    @State private var newChatSearch = ""

    /// What the last search turned up.
    @State private var found: (conversations: [Conversation], messages: [Message]) = ([], [])

    /// Which search `found` is the answer to.
    ///
    /// The answer takes a beat. Without knowing what an empty `found` belongs to, "nothing
    /// yet" and "nothing at all" looked the same, and every search opened with a flash of
    /// "No Results" for a name that was sitting right there.
    @State private var foundFor = ""

    /// What is actually being searched for: the query without the spaces around it.
    private var searchTerm: String { query.trimmingCharacters(in: .whitespaces) }

    /// The conversation a new chat or group just created, so it can be opened.
    @State private var openedConversationID: String?

    /// What's pushed on top of the list: conversations, and the list of every group.
    @State private var path = NavigationPath()

    /// Where "All" in the groups row leads.
    private struct AllGroups: Hashable {}

    var body: some View {
        // Counted once for the whole screen. Read from several places as a computed property
        // it would be counted several times, which is the trap it was written to get out of.
        let counts = tally

        return NavigationStack(path: $path) {
            Group {
                if searchTerm.count >= 2 {
                    results
                } else if counts.isEmpty, showsArchive {
                    ContentUnavailableView(
                        "Nothing archived",
                        systemImage: "archivebox",
                        description: Text("Swipe a chat to the left to put it here.")
                    )
                } else if counts.isEmpty, showsUnreadOnly {
                    ContentUnavailableView(
                        "Nothing unread",
                        systemImage: "checkmark.circle",
                        description: Text("You're up to date.")
                    )
                } else if counts.isEmpty {
                    EmptyStateView(isPresentingNewChat: $isPresentingNewChat)
                } else {
                    list(counts)
                }
            }
            .background {
                ListBackdrop(chrome: chrome, isCovered: !path.isEmpty)
                    .ignoresSafeArea()
            }
            // The system's own bar, title and all. It used to be ours — a word on a capsule of
            // glass between round glass buttons — so that a spinner could sit beside "Chats".
            // The subtitle says the same thing in the place iOS keeps for it, and the bar
            // gets everything iOS 27 gives a bar: the large title, the edge effect under it,
            // and the glass setting from Settings.
            .navigationTitle(title)
            .navigationSubtitle(statusLine)
            .toolbar { toolbar(counts) }
            // Search where iOS 27 puts it: at the bottom, under the thumb.
            .searchable(text: $query, prompt: "Search")
            // Pull to fetch, the system way.
            .refreshable { await refresh() }
            // Searching runs from a task keyed on the query, so each new letter cancels the
            // search started by the one before it and only the last one reaches the store.
            .task(id: query) {
                guard searchTerm.count >= 2 else {
                    found = ([], [])
                    foundFor = ""
                    return
                }

                // A beat first. Typing "Anna" is four keystrokes, and without this it is
                // four searches, three of which nobody waits for.
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }

                found = session.search(query)
                foundFor = searchTerm
            }
            #if DEBUG
            .background { TouchClock().frame(width: 1, height: 1) }
            #endif

            // Asks the bridges how they're doing and which rooms are their own bookkeeping.
            .task {
                // Started together: asking about rooms takes a while with many conversations,
                // and the address-book question shouldn't appear minutes later.
                async let bridges: Void = session.tidyUpIfDue()
                async let contacts: Void = session.refreshContacts()
                _ = await (bridges, contacts)
            }
            .navigationDestination(for: Conversation.self) { conversation in
                ConversationView(conversation: conversation)
                    .navigationTransition(.zoom(sourceID: conversation.id, in: openingChat))
            }
            .navigationDestination(for: AllGroups.self) { _ in
                AllGroupsView(groups: counts.boards) { path.append($0) }
                    .background { Backdrop(depth: chrome.depth).ignoresSafeArea() }
            }
            // A chat asked for from outside: a notification, a link, or Shortcuts.
            .onChange(of: session.requestedConversationID, initial: true) { _, requested in
                guard let requested, let conversation = session.conversation(withID: requested)
                else { return }
                session.requestedConversationID = nil
                path = NavigationPath()
                path.append(conversation)
            }
            // Back to the list means back to the list, not back to a search left open half
            // an hour ago.
            .onChange(of: path) { _, stack in
                #if DEBUG
                if !stack.isEmpty { OpenStopwatch.tapped() }
                #endif
                guard stack.isEmpty else { return }
                query = ""
            }
            // Opened once the sheet is out of the way: picking someone and then being
            // returned to the list, with nothing else happening, is the kind of extra step
            // this app exists to remove.
            .sheet(isPresented: $isPresentingNewChat, onDismiss: openNewConversation) {
                NewChatView(
                    openedConversationID: $openedConversationID,
                    initialSearch: newChatSearch
                )
            }
            .sheet(isPresented: $isPresentingSettings) {
                SettingsView()
            }
            .sheet(item: $reconnecting) { problem in
                NavigationStack {
                    BridgeSetupView(network: problem.network)
                }
            }
        }
    }

    /// Settings on the left, the filter and a new chat on the right — where Messages has them.
    private var title: LocalizedStringKey {
        showsArchive ? "Archived" : (showsUnreadOnly ? "Unread" : "Chats")
    }

    @ToolbarContentBuilder
    private func toolbar(_ counts: Tally) -> some ToolbarContent {
        // The title itself, so a bridge that stopped can put an orange dot in front of it —
        // the first thing you see, staying until everything works again.
        ToolbarItem(placement: .largeTitle) {
            HStack(spacing: 10) {
                if !session.bridgeProblems.isEmpty {
                    Circle()
                        .fill(.orange)
                        .frame(width: 12, height: 12)
                        .accessibilityLabel("A service is disconnected")
                }
                Text(title)
                    .font(.largeTitle.bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        ToolbarItem(placement: .topBarLeading) {
            if showsArchive {
                Button {
                    withAnimation { showsArchive = false }
                } label: {
                    Label("Chats", systemImage: "chevron.left")
                }
            } else {
                Button {
                    isPresentingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            // The filter, as a menu with what it shows ticked — the way Messages offers its
            // own. The archive lives here too: a drawer you rarely open, one tap further in.
            Menu {
                Picker("Show", selection: Binding(
                    get: { showsUnreadOnly },
                    set: { value in withAnimation { showsUnreadOnly = value; showsArchive = false } }
                )) {
                    Label("All Chats", systemImage: "bubble.left.and.bubble.right")
                        .tag(false)
                    Label("Unread", systemImage: "circle.badge")
                        .badge(counts.unread)
                        .tag(true)
                }

                if counts.archived > 0 || showsArchive {
                    Section {
                        Button {
                            withAnimation { showsArchive = true; showsUnreadOnly = false }
                        } label: {
                            Label("Archived", systemImage: "archivebox")
                                .badge(counts.archivedUnread)
                        }
                    }
                }
            } label: {
                Label(
                    "Filter",
                    systemImage: showsUnreadOnly
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
            }
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isPresentingNewChat = true
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
        }
    }

    /// How the fetching is going, under the title: the same three states the watch shows.
    /// Busy says so, done says so for a moment and then goes away, and trouble gets a line of
    /// its own in the list — because that one needs more words than fit here.
    private var statusLine: Text {
        if isRefreshing || session.isReconnecting {
            return Text("Updating…")
        }
        if session.justReconnected {
            return Text("Up to date").foregroundStyle(.green)
        }
        return Text(verbatim: "")
    }

    /// Opens the conversation a new chat or group just made.
    private func openNewConversation() {
        guard let id = openedConversationID else { return }
        openedConversationID = nil

        guard let conversation = session.conversation(withID: id) else { return }
        path.append(conversation)
    }

    private func list(_ counts: Tally) -> some View {
        listContent(counts)
            // How far the list has scrolled, for the backdrop's parallax.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                chrome.depth.offset = offset
            }
            // Whether the list is moving, so the backdrop can keep up with it.
            .onScrollPhaseChange { _, phase in
                chrome.isScrolling = phase != .idle
            }
    }

    /// Fetches once, by hand.
    private func refresh() async {
        isRefreshing = true
        await session.refreshNow()
        // Long enough to be seen. A sync that returns in eighty milliseconds is still a sync,
        // and an indicator that flickers reads as nothing having happened.
        try? await Task.sleep(for: .milliseconds(400))
        withAnimation { isRefreshing = false }
    }

    private func listContent(_ counts: Tally) -> some View {
        List {
            // Pinned chats lead, as faces — the way Messages does it, and part of the list,
            // so they scroll away with it when you go looking further down.
            if typeSize.isAccessibilitySize {
                if !counts.pinned.isEmpty {
                    Section {
                        ForEach(counts.pinned) { row($0) }
                    } header: {
                        Text("Pinned").font(.headline).foregroundStyle(.primary).textCase(nil)
                    }
                }
            } else if !counts.pinned.isEmpty {
                PinnedRow(
                    conversations: counts.pinned,
                    onOpen: { path.append($0) },
                    opening: openingChat,
                    chrome: chrome
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            // Somebody asking to be let in. Above everything, because an unanswered
            // question at the bottom of a list is an unanswered question forever.
            ForEach(session.invitations) { invitation in
                InvitationRow(
                    invitation: invitation,
                    onAccept: { withAnimation { session.accept(invitation) } },
                    onDecline: { withAnimation { session.decline(invitation) } }
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            if case .offline(let reason) = session.state {
                OfflineBanner(reason: reason)
            }

            // A bridge that stopped. Without this a logged-out WhatsApp looks exactly like a
            // quiet one, for days.
            ForEach(session.bridgeProblems) { problem in
                BridgeBanner(problem: problem) { reconnecting = problem }
            }

            // The groups, kept out of the list of people and in sight above it.
            if typeSize.isAccessibilitySize, !counts.boards.isEmpty {
                Section {
                    ForEach(GroupsRow.ordered(counts.boards, by: session)) { row($0) }
                } header: {
                    Text("Groups").font(.headline).foregroundStyle(.primary).textCase(nil)
                        .accessibilityAddTraits(.isHeader)
                }
            } else if !counts.boards.isEmpty {
                Section {
                    GroupsRow(groups: counts.boards, onOpen: { path.append($0) }, opening: openingChat)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Groups")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button {
                            path.append(AllGroups())
                        } label: {
                            Text("All")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                    }
                    .textCase(nil)
                }
            }

            Section {
                ForEach(counts.shown) { conversation in
                    row(conversation)
                }
            } header: {
                if !counts.boards.isEmpty {
                    Text(showsArchive ? "Archived" : "People")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // The system's soft edge under the search field, so the rows fade out behind it.
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }

    private func row(_ conversation: Conversation) -> some View {
        // A button that pushes, rather than a navigation link: a link spends 197 ms before
        // the push begins, a button 3 ms.
        Button {
            path.append(conversation)
        } label: {
            HStack(spacing: 0) {
                ConversationRow(conversation: conversation)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 6)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.chatmanRow)
        .matchedTransitionSource(id: conversation.id, in: openingChat)

        // Left to put away, right to catch up: the same directions as Mail.
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                withAnimation { session.setArchived(!conversation.isArchived, for: conversation) }
            } label: {
                Label(
                    conversation.isArchived ? "Unarchive" : "Archive",
                    systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox"
                )
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if session.isWaiting(conversation) {
                Button {
                    Task {
                        session.setManuallyUnread(false, for: conversation)
                        await session.markRead(conversation)
                    }
                } label: {
                    Label("Read", systemImage: "checkmark.message")
                }
                .tint(.blue)
            } else {
                Button {
                    session.setManuallyUnread(true, for: conversation)
                } label: {
                    Label("Unread", systemImage: "circle.badge.fill")
                }
                .tint(.blue)
            }
        }
        .contextMenu { ConversationActions(conversation: conversation) }
        // The swipes and the menu, as actions VoiceOver offers on the row itself.
        .accessibilityAction(named: Text(conversation.isPinned ? "Unpin" : "Pin")) {
            session.setPinned(!conversation.isPinned, for: conversation)
        }
        .accessibilityAction(named: Text(session.isWaiting(conversation) ? "Read" : "Unread")) {
            if session.isWaiting(conversation) {
                Task {
                    session.setManuallyUnread(false, for: conversation)
                    await session.markRead(conversation)
                }
            } else {
                session.setManuallyUnread(true, for: conversation)
            }
        }
        .accessibilityAction(named: Text(conversation.isArchived ? "Unarchive" : "Archive")) {
            session.setArchived(!conversation.isArchived, for: conversation)
        }
        .listRowBackground(Color.clear)
    }

    /// What a search turns up: people first, then what was said.
    @ViewBuilder
    private var results: some View {
        List {
            // Only once the answer is for what is typed now. Before that an empty result is
            // not "nothing found", it is "not looked yet".
            if found.conversations.isEmpty, found.messages.isEmpty, foundFor == searchTerm {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }

            let people = found.conversations.filter { !$0.isGroup }
            let groups = found.conversations.filter(\.isGroup)

            ForEach([(LocalizedStringKey("People"), people), (LocalizedStringKey("Groups"), groups)], id: \.1) { title, chats in
                if !chats.isEmpty {
                    Section {
                        ForEach(chats) { conversation in
                            Button {
                                path.append(conversation)
                            } label: {
                                ConversationRow(conversation: conversation)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.chatmanRow)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text(title).accessibilityAddTraits(.isHeader)
                    }
                }
            }

            if !found.messages.isEmpty {
                Section("Messages") {
                    ForEach(found.messages) { message in
                        Button {
                            if let conversation = message.conversation {
                                // Opened at the message, not at the bottom: that's what was
                                // looked for.
                                session.requestedFocus = (conversation.id, message.id)
                                path.append(conversation)
                            }
                        } label: {
                            MessageResult(message: message, term: searchTerm)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }

            // Somebody you haven't spoken to yet won't be in either list, and looking for
            // them is exactly when you'd want to start.
            Section {
                Button {
                    newChatSearch = query
                    isPresentingNewChat = true
                } label: {
                    Label("Start a new chat with \u{201C}\(searchTerm)\u{201D}", systemImage: "square.and.pencil")
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
/// One message that matched a search, under the name of whoever said it.
private struct MessageResult: View {
    @Environment(ChatSession.self) private var session

    let message: Message
    let term: String

    /// The message with what was searched for in bold, the way Messages marks a hit.
    private var marked: AttributedString {
        var text = AttributedString(message.body)
        if let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].inlinePresentationIntent = .stronglyEmphasized
            text[range].foregroundColor = .primary
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.conversation.map { session.displayName(for: $0) } ?? "")
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(message.timestamp, format: .dateTime.day().month().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(marked)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .foregroundStyle(.primary)
    }
}

/// A single row: who, what they last said, and when.
struct ConversationRow: View {
    @Environment(ChatSession.self) private var session

    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            Avatar(conversation: conversation)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    if conversation.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(session.displayName(for: conversation))
                        // The name is what you scan the list for, so it is the largest thing
                        // in the row — and the same size as the names in the pinned row
                        // above, because they are the same thing.
                        .chatmanFont(size: 16, weight: .semibold)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // A room the bridge made but nothing has happened in yet still has its
                    // default date, which reads as "2,025 years ago". Better to show nothing.
                    if conversation.lastActivity > .distantPast {
                        Text(ListTime.string(for: conversation.lastActivity))
                            .monospacedDigit()
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 6) {
                    PreviewText(session.preview(for: conversation))
                        .chatmanFont(size: 15)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            // Blue by name, not by accent: the accent colour follows the
                            // system and this badge has to mean one thing on both devices.
                            .background(Color.blue, in: Capsule())
                    } else if conversation.isManuallyUnread {
                        // No number, because there isn't one: you marked this yourself.
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 10, height: 10)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A circle with initials, plus a badge showing which service the conversation is on.
///
/// The badge is the point: it's what turns a list of Matrix rooms into something that reads
/// like a phone.
/// Somebody asking you into a room.
///
/// Chatman joins a bridge's rooms without asking — that is a chat being handed over, not a
/// question. Anyone else gets this: who asked, what the room is called, and two answers. On
/// a server that talks to the rest of Matrix, the alternative is a stranger's room simply
/// appearing between your chats.
private struct InvitationRow: View {
    let invitation: ChatSession.Invitation
    let onAccept: () -> Void
    let onDecline: () -> Void

    /// The name without the server on the end, which is the half that means something.
    private var who: String {
        guard invitation.inviter.hasPrefix("@") else { return invitation.inviter }
        return String(invitation.inviter.dropFirst().prefix { $0 != ":" })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "envelope")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(.blue.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(invitation.name ?? "A conversation")
                        .font(.headline)
                        .lineLimit(1)

                    Text(
                        invitation.inviter.isEmpty
                            ? "You've been invited"
                            : "\(who) invited you"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                Button(action: onDecline) {
                    Text("Decline")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .chatmanGlass(in: .capsule, interactive: true)

                Button(action: onAccept) {
                    Text("Join")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .chatmanGlass(in: .capsule, interactive: true, tint: .accentColor)
            }
        }
        .padding(.vertical, 6)
    }
}

/// The chats you pinned, as a row of faces.
///
/// Borrowed from Messages, and for the reason Messages has it: the handful of people you talk
/// to every day should be one tap away, not a line in a list you have to read. A face is
/// found faster than a name — you recognise it before you have finished looking at it.
///
/// Always one row. Pin more than fits and the row scrolls sideways rather than wrapping onto
/// a second line, because a block of faces that grows downwards eats the list it sits above.
struct PinnedRow: View {
    @Environment(ChatSession.self) private var session

    let conversations: [Conversation]
    let onOpen: (Conversation) -> Void


    /// Handed down, because both ends of the transition have to be the same namespace.
    let opening: Namespace.ID

    /// How far the faces have folded away, read only where they are drawn. See ``ListChrome``.
    let chrome: ListChrome

    private func firstWord(of conversation: Conversation) -> String {
        String(session.displayName(for: conversation).split(separator: " ").first ?? "")
    }

    private var firstWords: [String] { conversations.map(firstWord(of:)) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Tight. What separates two faces is this plus whatever column is left over
            // around them, and both were doing the same job twice.
            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(conversations.enumerated()), id: \.element.id) { index, conversation in
                    Button {
                        onOpen(conversation)
                    } label: {
                        PinnedFace(
                            conversation: conversation,
                            chrome: chrome,
                            // Only when the next face has nothing hanging under it. A
                            // bubble that leans into its neighbour's column is fine over an
                            // empty one and unreadable over another bubble, so the question
                            // is asked of the neighbour rather than answered with a guess.
                            mayLean: index == conversations.count - 1
                                || !session.isWaiting(conversations[index + 1]),
                            isAmbiguous: firstWords.filter { $0 == firstWord(of: conversation) }.count > 1
                        )
                    }
                    .buttonStyle(.chatmanPress)
                    .matchedTransitionSource(id: conversation.id, in: opening)
                    .contextMenu { ConversationActions(conversation: conversation) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        // Off, or the row bounces in place on every list scroll when everything already fits.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

/// The pinned faces, folding as the list scrolls.
///
/// Laid out at full size, always. The faces fold inside the room they had whole, as a matter
/// of drawing, and the list shows through the space they give up; the room itself never
/// changes, so the top of the list never moves while you scroll it.
private struct PinnedBand: View {
    let conversations: [Conversation]
    let onOpen: (Conversation) -> Void
    let opening: Namespace.ID
    let chrome: ListChrome

    var body: some View {
        PinnedRow(
            conversations: conversations,
            onOpen: onOpen,
            opening: opening,
            chrome: chrome
        )
        .padding(.top, 4)
        .padding(.bottom, 8)
        // Where the band is, for the fade and for how far the list has to move to fold it.
        // Its layout, which a fold doesn't change: this fires when a chat is pinned or a
        // message arrives, not on every frame of a scroll.
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            chrome.placePinned(frame)
        }
        .onDisappear { chrome.removePinned() }
    }
}

/// The backdrop behind the list.
///
/// A view of its own for one reason: it reads whether the list is being scrolled, and a value
/// read in the list's own body would build the whole list again every time a scroll started
/// or stopped.
private struct ListBackdrop: View {
    let chrome: ListChrome
    let isCovered: Bool

    var body: some View {
        Backdrop(depth: chrome.depth, isScrolling: chrome.isScrolling, isCovered: isCovered)
    }
}

/// One pinned chat: a face, the name under it, and an unread message under that.
///
/// The message appears as a bubble, the way Messages does it and for the reason it does: a
/// number tells you that something happened, where a sentence tells you what. You can decide
/// whether it's worth opening without opening it. Read chats show nothing — an old message
/// under every face is a row of noise you stop reading within a day.
struct PinnedFace: View {
    @Environment(ChatSession.self) private var session

    let conversation: Conversation

    /// How far this face has folded. Handed on, not read: see ``FoldingFace``.
    let chrome: ListChrome

    /// Whether the bubble may run a quarter wider than its column, into the space under the
    /// next name. Decided by the row, which is the only place that can see the neighbour.
    let mayLean: Bool

    private var isWaiting: Bool { session.isWaiting(conversation) }

    /// The first word of the name, unless another pinned chat starts with the same word.
    ///
    /// A face usually tells you which Anna this is, and the surname only makes the column
    /// wider. But two Annas without a photo are two identical circles, so then the whole
    /// name is the only thing that tells them apart.
    let isAmbiguous: Bool

    private var shortName: String {
        let full = session.displayName(for: conversation)
        guard !isAmbiguous, let first = full.split(separator: " ").first else { return full }
        return String(first)
    }

    // Everything that asks the store something is asked here, once, when the chat changes.
    // The fold only moves the answers about.
    var body: some View {
        let waiting = isWaiting
        FoldingFace(
            chrome: chrome,
            isWaiting: waiting,
            mayLean: mayLean,
            face: Avatar(conversation: conversation, size: PinnedSizes.face),
            name: name,
            bubble: waiting ? bubble : nil
        )
    }

    /// Under the face, as plain words — the way Messages labels its pinned faces. It used to
    /// lie over the bottom of the face on a capsule of glass: a circle and a pill on top of
    /// each other, two shapes where one was enough.
    private var name: some View {
        Text(shortName)
            .font(.caption)
            .foregroundStyle(.primary)
            .fontWeight(isWaiting ? .semibold : .regular)
            .lineLimit(1)
            .frame(width: PinnedSizes.column)
    }

/// What was said, as the shape a message has.
    private var bubble: some View {
        PreviewText(session.preview(for: conversation))
            .font(.caption)
            .foregroundStyle(.primary)
            // Two lines. One was a sentence cut off after four words, which tells you
            // somebody wrote something but not what — and knowing what is the entire reason
            // a bubble is here instead of a number.
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            // The colour goes on before any width does, which is the whole trick.
            //
            // There was a frame of the full column between the words and their background, so
            // the bubble was that wide whatever was in it — somebody sending a single emoji
            // got a blue box as wide as their name with one small face floating in it. Put
            // the padding and the fill straight onto the text and it takes the width it
            // needs; the frame below only says where it sits, and the line limit still cuts
            // a long sentence off at the column.
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            // One circle overlapping the corner, pointing back up at the face it belongs to.
            // Two of them, trailing off into the white, read as specks of dirt rather than
            // as a tail — there is nothing up there for them to trail towards.
            .background(alignment: .topLeading) {
                Circle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 10, height: 10)
                    .offset(x: 7, y: -4)
            }
    }
}

/// The fold itself, and nothing else.
///
/// The one part of a pinned face that reads how far the faces have folded, and so the only
/// part built again on every frame of a scroll. What it is handed — the picture, the name,
/// the message — was made once by ``PinnedFace`` and is only moved about here: scaled, slid
/// and faded, all of which is drawing. Its height never changes as it folds; only its width
/// does, so the faces close up sideways while the room they stand in stays put.
///
/// It used to be the other way round. Every frame laid the whole face out again at its new
/// size, asked the store again whether a message was waiting and what it said, and measured
/// the result to size the room around it. On a phone that is a lot of asking sixty times a
/// second, and a measurement that sizes what it measures is a loop waiting for a reason.
private struct FoldingFace<Face: View, Name: View, Bubble: View>: View {
    let chrome: ListChrome
    let isWaiting: Bool
    let mayLean: Bool
    let face: Face
    let name: Name
    let bubble: Bubble?

    var body: some View {
        let collapse = chrome.pinnedCollapse
        // Smaller, not gone: still a face you can hit, no longer a row that takes a fifth
        // of the screen.
        let scale = 1 - (1 - PinnedSizes.foldedFace / PinnedSizes.face) * collapse
        // How far the bottom of the face has risen as it shrank towards its top.
        let risen = PinnedSizes.face * (1 - scale)
        // What is left of the name and the message: gone a little before the face has
        // finished shrinking, so the last part of the fold is only the face settling.
        let words = max(0, 1 - collapse * 1.5)
        // How wide one face and everything under it is. The same for everybody, whatever
        // their name or their last message: columns that each took the width of their own
        // contents made the row jump about as messages arrived.
        let column = PinnedSizes.column + (PinnedSizes.foldedColumn - PinnedSizes.column) * collapse

        // Leading, so a bubble wider than its column grows to the right and never to the
        // left. Leftwards it would cross the face before it, which is the one direction
        // nothing may do.
        VStack(alignment: .leading, spacing: 6) {
            face
                .frame(width: PinnedSizes.face, height: PinnedSizes.face)
                // A face without a photo is a see-through circle, and once the list runs
                // under the faces its names would show through it.
                .background(Circle().fill(Color(.systemBackground)))
                // Folded, the message is gone and something has to say it was there. Drawn
                // at its own size whatever the face around it is doing.
                .overlay(alignment: .topTrailing) {
                    if isWaiting, collapse > 0 {
                        Circle()
                            .fill(.blue)
                            .frame(width: 12, height: 12)
                            .overlay { Circle().stroke(Color(.systemBackground), lineWidth: 2) }
                            .scaleEffect(1 / scale)
                            .opacity(min(1, collapse * 1.5))
                    }
                }
                .scaleEffect(scale, anchor: .top)
                // Given the column's width before the pill is hung on it. An overlay is
                // offered the size of what it covers, so hung on the face itself the pill
                // could only be sixty-eight points wide and "Annabelle" came out "Annab…".
                .frame(width: column)
                .overlay(alignment: .bottom) {
                    name
                        .offset(y: 20 - risen)
                        .scaleEffect(0.8 + 0.2 * words, anchor: .top)
                        .opacity(words)
                }
                // Room for the half of the pill that hangs below the face.
                .padding(.bottom, 22)

            if let bubble {
                bubble
                    // Left under the face rather than centred: a short bubble centred under
                    // a wide column floats, and nothing points at anything. Its width is
                    // the column's at full size, so the words don't wrap again as it goes.
                    .frame(width: PinnedSizes.column * (mayLean ? 1.25 : 1), alignment: .leading)
                    // Shrinking with its column, so it never reaches into the next one's.
                    .scaleEffect(column / PinnedSizes.column, anchor: .topLeading)
                    // Rising with the face as it fades, into the space the name gave up.
                    .offset(y: -(risen + 21 * collapse))
                    .opacity(words)
            }
        }
        // The column keeps its width whatever the bubble does. A face that widened to fit
        // its own message would push every face after it sideways each time somebody wrote
        // something, and a row you aim a thumb at has to hold still.
        .frame(width: column, alignment: .topLeading)
    }
}

struct Avatar: View {
    @Environment(ChatSession.self) private var session

    let conversation: Conversation

    /// How big, in points. The list shows it at full size; the title bar smaller.
    var size: CGFloat = 44

    /// Whether to mark which service this conversation lives on.
    ///
    /// Off at the top of a conversation: there the badge is a speck against a photo that is
    /// being cropped and faded anyway, and it reads as dirt on the screen.
    var showsNetwork: Bool = true

    private var initials: String {
        let words = session.displayName(for: conversation).split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RemoteImage(
                request: session.avatarRequest(for: conversation.avatarURL),
                cacheKey: conversation.avatarURL
            ) {
                // Only where the network offered no picture: one someone chose to show you
                // is more current than whatever is in your address book.
                if let image = session.contactPicture(for: conversation) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    // A monogram in colour, the way Contacts draws somebody without a photo.
                    // Grey for everybody made a list of strangers; a colour of their own is
                    // the next best thing to a face.
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

            // Which service this conversation actually lives on. A letter rather than a
            // coloured dot: colour alone asks people to memorise a legend, and it says
            // nothing at all to anyone who can't tell the colours apart.
            if showsNetwork, conversation.network != .matrix, size >= 36 {
                NetworkBadge(network: conversation.network, size: 15)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
            }
        }
    }

}

/// Shown when syncing is failing but there's still cached content worth using.
private struct OfflineBanner: View {
    @Environment(ChatSession.self) private var session

    let reason: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("Not connected")
                    .font(.subheadline.weight(.medium))
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            // The delay between attempts grows with each failure, which is right for a
            // battery and wrong for someone who just walked back into range.
            Button("Try now") { session.reconnect() }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .listRowBackground(Color.clear)
    }
}

/// A bridge that stopped passing messages on, and the way to set it going again.
private struct BridgeBanner: View {
    let problem: ChatSession.BridgeProblem
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(problem.isUnanswered
                     ? "\(problem.network.displayName) isn't answering"
                     : "\(problem.network.displayName) is disconnected")
                    .font(.subheadline.weight(.medium))
                Text(problem.detail ?? "Nothing arrives from \(problem.network.displayName) until it's connected again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button("Reconnect", action: onReconnect)
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .listRowBackground(Color.clear)
    }
}

private struct EmptyStateView: View {
    @Binding var isPresentingNewChat: Bool

    var body: some View {
        ContentUnavailableView {
            Label("No conversations yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Chats from your bridges appear here as soon as they arrive.")
        } actions: {
            Button("Start a chat") { isPresentingNewChat = true }
                .buttonStyle(.borderedProminent)
        }
    }
}


/// What you can do to a chat without opening it.
///
/// One list, used by the row in the list and by the face in the pinned row above it. They had
/// grown apart: the row offered pinning, muting and archiving, and the face — added later,
/// only to close the hole where a pinned chat could not be unpinned — offered nothing else.
/// A pinned chat is still a chat, and the same press should find the same things.
struct ConversationActions: View {
    @Environment(ChatSession.self) private var session

    let conversation: Conversation

    var body: some View {
        Button {
            withAnimation(.snappy) { session.setPinned(!conversation.isPinned, for: conversation) }
        } label: {
            Label(
                conversation.isPinned ? "Unpin" : "Pin",
                systemImage: conversation.isPinned ? "pin.slash" : "pin"
            )
        }

        Button {
            Task { await session.setMuted(!conversation.isMuted, for: conversation) }
        } label: {
            Label(
                conversation.isMuted ? "Unmute" : "Mute",
                systemImage: conversation.isMuted ? "bell" : "bell.slash"
            )
        }

        Button {
            withAnimation(.snappy) { session.setArchived(!conversation.isArchived, for: conversation) }
        } label: {
            Label(
                conversation.isArchived ? "Unarchive" : "Archive",
                systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox"
            )
        }
    }
}


/// When something last happened, the way Messages says it: the time today, "Yesterday",
/// the weekday within the week, a date after that.
///
/// It said "14 seconds ago" — a third of the row, a number that kept changing while you
/// read it, and a sentence VoiceOver had to read out in full for every chat.
enum ListTime {
    static func string(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
