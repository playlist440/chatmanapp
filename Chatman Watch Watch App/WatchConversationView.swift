import SwiftUI
import SwiftData
import ChatmanKit

/// One conversation on the watch: read everything, reply with text or an emoji.
///
/// Sending attachments is deliberately absent. Reading them isn't — a photo someone sent you
/// is worth seeing on your wrist; picking one to send is not something anyone wants to do
/// there.
struct WatchConversationView: View {
    let conversation: Conversation

    /// How far back is drawn. Fewer than on the phone: the screen is smaller and so is
    /// everything behind it.
    ///
    /// Held out here, one level above the screen, because it decides what the store is asked
    /// for — and a query can only be told that when it is made. See `WatchConversationScreen`.
    ///
    /// A dozen to open with, the rest once the screen has arrived: building forty bubbles
    /// in the opening animation was a second of a busy watch before the first one showed.
    @State private var window = 12

    var body: some View {
        WatchConversationScreen(conversation: conversation, window: $window)
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                if window < 40 { window = 40 }
            }
    }
}

private struct WatchConversationScreen: View {
    @Environment(ChatSession.self) private var session

    let conversation: Conversation

    /// The newest messages, as many as are drawn and one more — the one more says whether
    /// there is anything above.
    ///
    /// Only those. This used to ask for the whole conversation, sorted, and the store answers
    /// that again after every save: every receipt, every message in any other chat. With a
    /// year of history that was thousands of messages fetched on the main thread while the
    /// crown was turning, and a watch has no time to spare for that — it showed up as a
    /// judder in exactly the moments something arrived.
    @Query private var stored: [Message]

    @Binding var window: Int

    init(conversation: Conversation, window: Binding<Int>) {
        self.conversation = conversation
        _window = window

        let room = conversation.id
        var newestFirst = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { $0.conversation?.id == room },
            sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
        )
        newestFirst.fetchLimit = window.wrappedValue + 1
        _stored = Query(newestFirst)
    }

    /// Whether the newest message is in view.
    @State private var isAtBottom = true

    /// The first message you hadn't read when this opened, and how many there were.
    @State private var firstUnreadID: String?
    @State private var unreadAtOpen = 0

    /// From four unread on — about a screenful here — the conversation opens where they
    /// begin, and the crown reads forwards. Fewer fit on the screen at the end anyway.
    private static let opensAtFirstUnread = 4

    /// Where the unread messages begin.
    private let dividerAnchor = "chatman.new-messages"

    /// What "the bottom" means: the end of the screen, field included.
    private let bottomAnchor = "chatman.end-of-conversation"

    @State private var draft = ""
    /// What's on top of the conversation, if anything.
    ///
    /// One sheet rather than three modifiers on the same view. Stacked presentations on
    /// watchOS leave the screen believing something is still open after it has closed, and
    /// the first press of the back button goes to dismissing that instead of to going back —
    /// which is why leaving a chat took two goes.
    private enum Sheet: Identifiable {
        case share
        case emoji
        /// What to do with one message: the three things worth doing to one.
        case actions(Message)
        /// Which emoji to react with.
        case react(Message)
        /// Where to pass a message on to.
        case forward(Message)
        /// Where the watch thinks you are, waiting to be looked at before it goes anywhere.
        ///
        /// In here with the rest rather than on a sheet of its own. It had one, which made
        /// two on the same view — the arrangement this enum exists to avoid — and the
        /// location is asked for the moment the share menu starts closing, so a quick fix
        /// could arrive while that menu was still on its way out and never be shown.
        case location(SharedLocation)

        var id: String {
            switch self {
            case .share: "share"
            case .emoji: "emoji"
            case .actions(let message): "actions-\(message.id)"
            case .react(let message): "react-\(message.id)"
            case .forward(let message): "forward-\(message.id)"
            case .location(let place): "location-\(place.id)"
            }
        }
    }

    @State private var sheet: Sheet?

    /// The message being answered, if any.
    @State private var replyTarget: Message?

    /// The way out, for the strip along the left edge.
    @Environment(\.dismiss) private var dismiss

    /// Whether the other person's picture is being looked at on its own.
    @State private var isShowingPortrait = false

    /// True while the watch is working out where it is. Outdoors that's a second or two;
    /// indoors it can be most of a minute, which is exactly why it says so.
    @State private var isFindingLocation = false

    /// Why the last thing asked of this screen didn't work, when it leaves no trace of its own
    /// in the conversation.
    ///
    /// A location that couldn't be found, and a forward that failed. A forward used to fail in
    /// silence: the picker closed at once, the error was thrown away, and on a watch on
    /// cellular — where failing is most likely — you walked off believing it had been sent.
    @State private var problem: String?

    /// Whether the crown or a finger is moving the conversation right now.
    ///
    /// While it is, nothing else moves it. Something loading and growing near the bottom used
    /// to pull the conversation back down under a crown that had just started turning up.
    @State private var isScrolling = false

    /// Whether the conversation has been put in its opening place yet.
    ///
    /// Once. The opening scroll ran again every time the screen came back from behind a
    /// sheet — the plus menu, a reaction, forwarding — and put you back at the bottom, away
    /// from whatever you had scrolled up to read.
    @State private var hasPositioned = false

    /// What fits above a chat on a watch.
    ///
    /// A first name, once the whole thing stops fitting. Twelve characters is about what the
    /// widest watch shows before it starts trimming letters off the end, and "Anna" beats
    /// "Anna van der B…" every time.
    private var shortName: String {
        let full = session.displayName(for: conversation)
        guard full.count > 12, let first = full.split(separator: " ").first else { return full }
        return String(first)
    }

    /// How tall the plus and the field both are.
    private let composerHeight: CGFloat = 32

    /// What's actually drawn: the tail of the conversation, oldest first.
    private var messages: [Message] {
        Array(stored.prefix(window).reversed())
    }

    /// Whether there is more above, stored or on the server.
    private var hasMore: Bool {
        stored.count > window || conversation.previousBatch != nil
    }

    /// The one message that carries a delivery status: the newest you sent.
    private var statusMessageID: String? {
        messages.last { session.isMine($0) }?.id
    }

    /// Messages by event ID, so a reply can find what it answers.
    private var byID: [String: Message] {
        Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }



    /// Whether this message begins a new run by the same person.
    private func endsRun(at index: Int, in items: [PhotoAlbum.Item]) -> Bool {
        guard index + 1 < items.count else { return true }
        return items[index + 1].anchor.sender != items[index].anchor.sender
    }

    private func startsRun(at index: Int, in items: [PhotoAlbum.Item]) -> Bool {
        guard index > 0 else { return true }
        return items[index - 1].anchor.sender != items[index].anchor.sender
    }

    /// A time is shown above the first message and whenever a quarter of an hour has passed.
    private func showsTime(at index: Int, in items: [PhotoAlbum.Item]) -> Bool {
        guard index > 0 else { return true }
        let now = items[index].anchor.timestamp
        return now.timeIntervalSince(items[index - 1].anchor.timestamp) > 900
    }

    var body: some View {
        // Worked out once for the whole list rather than inside the loop. The helpers below
        // used to rebuild the window every time they were asked, and the reply lookup built
        // a dictionary of it — several times per row. This screen runs on the slowest chip
        // either app has to deal with, which is exactly where that shows.
        let shown = messages
        let quotedBy = byID
        let newest = statusMessageID
        // Pictures sent together are drawn together, and the line the bridge writes about
        // them is dropped on the way. See `PhotoAlbum`.
        let items = PhotoAlbum.group(shown)
        let pictures = shown.filter(\.isPicture)

        return ScrollViewReader { proxy in
            // A scroll view, not a list. Every row in a watch list gets a minimum height
            // built for a fingertip on a menu item, and between messages that becomes a
            // finger's width of nothing after every line. Here the spacing is whatever the
            // messages say it is.
            ScrollView {
                VStack(spacing: 4) {
                if hasMore {
                    Button("Earlier messages") {
                        // What's already here first: widening the window is instant, and
                        // covers scrolling back through this morning.
                        guard stored.count <= window else {
                            withAnimation { window += 40 }
                            return
                        }

                        Task {
                            await session.loadOlderMessages(in: conversation, limit: 20)
                            window += 40
                        }
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let message = item.anchor

                    // Where you left off, once, when there was enough to lose your place in.
                    if message.id == firstUnreadID, unreadAtOpen >= Self.opensAtFirstUnread {
                        HStack(spacing: 5) {
                            Rectangle().fill(.blue.opacity(0.5)).frame(height: 1)
                            Text("New")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.blue)
                            Rectangle().fill(.blue.opacity(0.5)).frame(height: 1)
                        }
                        .padding(.vertical, 3)
                        .id(dividerAnchor)
                    }

                    // A time above a run of messages instead of under every one. Messages
                    // does this because a timestamp per line eats a watch screen alive.
                    if showsTime(at: index, in: items) {
                        Text(message.timestamp, format: .dateTime.hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 4)
                    }

                    if case .album(let album) = item {
                        WatchAlbumRow(album: album, isMine: session.isMine(message))
                            .id(message.id)
                            .onLongPressGesture { sheet = .actions(album.photos[0]) }
                    } else if message.kind == .image || message.kind == .video {
                        // The link sits on the whole row rather than on the picture inside
                        // it: watchOS handles a tap on a control nested in a list row badly,
                        // and a photo you can't open is worse than a generous tap target.
                        NavigationLink {
                            WatchMediaViewer(photos: pictures, start: message)
                        } label: {
                            WatchMessageRow(
                                message: message,
                                isMine: session.isMine(message),
                                showsSender: conversation.isGroup && startsRun(at: index, in: items),
                                endsRun: endsRun(at: index, in: items),
                                quoted: message.replyToID.flatMap { quotedBy[$0] },
                                showsStatus: message.id == newest
                            )
                        }
                        .buttonStyle(.plain)
                        .id(message.id)
                        .onLongPressGesture { sheet = .actions(message) }
                    } else {
                        WatchMessageRow(
                            message: message,
                            isMine: session.isMine(message),
                            // Only above the first of a run: repeating the name on every line
                            // of someone talking is noise.
                            showsSender: conversation.isGroup && startsRun(at: index, in: items),
                            endsRun: endsRun(at: index, in: items),
                            quoted: message.replyToID.flatMap { quotedBy[$0] },
                            showsStatus: message.id == newest
                        )
                        .id(message.id)
                        // Held down rather than swiped. Dragging a message sideways is what
                        // the phone does, and on a watch that is the same movement as going
                        // back — two gestures that mean opposite things and start the same
                        // way is how you end up doing neither on purpose.
                        .onLongPressGesture { sheet = .actions(message) }
                    }
                }

                if let typing = session.typingSummary(in: conversation) {
                    Text(typing)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }

                // The last row, so it travels with the conversation: scroll back through
                // yesterday and the field goes with it. It sits at the bottom when you
                // arrive because the list itself is anchored there.
                composer

                // The end of it all, and what every scroll aims at.
                //
                // Aiming at the last message instead put that message against the bottom of
                // the screen — and the field, which lives below it here, off the bottom
                // entirely. Same mistake as on the phone, opposite symptom.
                Color.clear
                    .frame(height: 1)
                    .id(bottomAnchor)
                }
                .padding(.horizontal, 2)
            }
            .task {
                guard !hasPositioned else { return }

                // A frame's grace: scrolling before the list has laid itself out lands
                // somewhere in the middle, which is why it always needed a nudge by hand.
                try? await Task.sleep(for: .milliseconds(120))
                guard !messages.isEmpty else { return }
                hasPositioned = true

                // A screenful or more unread: open where it begins, so the crown reads
                // forwards instead of backwards. The window is widened to reach it first.
                if unreadAtOpen >= Self.opensAtFirstUnread, firstUnreadID != nil {
                    window = max(window, min(unreadAtOpen + 4, 150))
                    try? await Task.sleep(for: .milliseconds(60))
                    isAtBottom = false
                    proxy.scrollTo(dividerAnchor, anchor: .top)
                    return
                }

                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            // Only when you were already at the bottom. Being pulled away from what you're
            // reading because somebody wrote something is worse on a watch than anywhere:
            // there is one screenful, and you lose all of it.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let bottom = geometry.contentSize.height - geometry.containerSize.height
                return geometry.contentOffset.y >= bottom - 40
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
            .onScrollPhaseChange { _, phase in
                let moving = phase != .idle
                if isScrolling != moving { isScrolling = moving }
            }
            // Never while the crown or a finger is moving it. Something that loaded and grew
            // near the bottom used to pull the conversation back down under a crown that had
            // just started turning up — the first forty points of every scroll were a tug of
            // war.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { _, _ in
                guard isAtBottom, !isScrolling, !messages.isEmpty else { return }
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            .onChange(of: messages.last?.id) { _, _ in
                guard isAtBottom, !messages.isEmpty else { return }
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            // Bottom-aligned, like every conversation anywhere. A list shorter than the
            // screen otherwise sits at the top, leaving a hole between the last message and
            // the field you're about to type in.
            .defaultScrollAnchor(.bottom)
            // No focus of its own. This was made focusable to make sure the crown came back
            // after a picture or a sheet, and a scroll view that is a focus target turns the
            // crown through the focus system instead of scrolling with it — which is the
            // judder. As the only scroll view here, it gets the crown by itself.
            // A watch list is built for rows you tap, so every one of them gets a tall
            // minimum height and a gap after it. A conversation is not a menu: the rows are
            // already the right height, and on a screen this size the space between them was
            // costing more than the messages.
        }
        // Laid out the way Messages does it on a watch: the name in the middle, the face on
        // the right, the back button on the left. A long name loses its surname rather than
        // its last three letters — a watch title has room for one word and everybody knows
        // which word matters.
        .navigationTitle(shortName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingPortrait = true
                } label: {
                    WatchConversationFace(conversation: conversation)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Photo")
            }
        }
        .watchEdgeBack()
        .task {
            // Where you left off, before reading it sets the count to nought. Only the first
            // time: this runs again coming back from a picture, when the count is already zero.
            let waiting = conversation.unreadCount
            if firstUnreadID == nil, waiting > 0,
               let first = session.firstUnreadMessageID(in: conversation, unread: waiting) {
                firstUnreadID = first
                unreadAtOpen = waiting
            }
            await session.markRead(conversation)
        }
        // And again on the way out, as on the phone. Marking only on arrival read up to the
        // newest message at that moment, so anything that came in while you were reading
        // left the chat in the list with a dot on it, and counted on the watch face.
        .onDisappear {
            Task { await session.markRead(conversation) }
        }
        // Typing on a watch happens on a screen of its own, so nothing here should be
        // holding on to the keyboard when you try to leave.
        .scrollDismissesKeyboard(.immediately)
        .sheet(item: $sheet) { which in
            switch which {
            case .share:
                ShareMenu(
                    isFindingLocation: isFindingLocation,
                    onEmoji: { sheet = .emoji },
                    onLocation: {
                        sheet = nil
                        shareLocation()
                    }
                )

            case .emoji:
                EmojiPicker { emoji in
                    sheet = nil
                    Task { await session.send(emoji, to: conversation) }
                }

            case .actions(let message):
                MessageActions(
                    onQuickReaction: { emoji in
                        sheet = nil
                        Task { await session.react(with: emoji, to: message) }
                    },
                    onReply: {
                        replyTarget = message
                        sheet = nil
                    },
                    onForward: { sheet = .forward(message) },
                    onReact: { sheet = .react(message) }
                )

            case .react(let message):
                EmojiPicker { emoji in
                    sheet = nil
                    Task { await session.react(with: emoji, to: message) }
                }

            case .forward(let message):
                ForwardPicker(message: message) { target in
                    sheet = nil
                    problem = nil

                    Task {
                        do {
                            try await session.forward(message, to: target)
                        } catch {
                            problem = "Couldn't forward: \(error.localizedDescription)"
                        }
                    }
                }

            case .location(let place):
                WatchLocationConfirmation(place: place) {
                    sheet = nil
                    Task { await session.send(place.message, to: conversation) }
                } onCancel: {
                    sheet = nil
                }
            }
        }
        .fullScreenCover(isPresented: $isShowingPortrait) {
            AvatarPortrait(conversation: conversation, session: session) {
                isShowingPortrait = false
            }
        }
    }

    /// The text field gives dictation, scribble and — on the Ultra — a full keyboard, all for
    /// free. Building a custom input here would only take those away.
    ///
    /// Beside it, one plus. Emoji used to live in the top bar and the location button under
    /// the field, which is two permanent controls on a screen that has room for none: the
    /// same arrangement Messages settled on, for the same reason.
    private var composer: some View {
        VStack(spacing: 6) {
            // What you are answering, and the way out of answering it. One line, because
            // that is all there is room for — and the name matters more than the words.
            if let replyTarget {
                HStack(spacing: 5) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)

                    Text(replyTarget.body.isEmpty ? "Photo" : replyTarget.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Button {
                        self.replyTarget = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 5) {
                Button {
                    sheet = .share
                } label: {
                    Group {
                        if isFindingLocation {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "plus")
                                .font(.body.weight(.semibold))
                        }
                    }
                    // Square, and exactly as tall as the field beside it. The two used to be
                    // different heights and grew into each other's space.
                    .frame(width: composerHeight, height: composerHeight)
                }
                .buttonStyle(.plain)
                .chatmanGlass(in: .circle, interactive: true)
                .contentShape(.circle)
                .disabled(isFindingLocation)
                .accessibilityLabel("Share something")

                // Not a TextField. watchOS draws one as a grey slab and there is no way to
                // talk it out of that — a plain style, a clear background, none of it takes.
                // A TextFieldLink opens the very same typing screen, and hands the whole
                // appearance over: what's below is ours, capsule and all.
                //
                // It also does away with the trick that was needed to clear the field after
                // sending: there is no field to clear.
                TextFieldLink(prompt: Text("Message")) {
                    Text(draft.isEmpty ? "Message" : draft)
                        .font(.body)
                        .foregroundStyle(draft.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: composerHeight)
                        .chatmanGlass(in: .capsule)
                } onSubmit: { typed in
                    draft = typed
                    send()
                }
                .buttonStyle(.plain)
                // Double tap answers, the way it does in Messages: pinch twice and start
                // talking, without touching the screen.
                .handGestureShortcut(.primaryAction)
            }

            if let problem {
                Text(problem)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 2)
    }

    /// Sends where you are, as something anyone can open.
    ///
    /// Text, not a location message: no bridge carries one of those intact, and text arrives
    /// everywhere. The link opens in whatever map app the other person uses, and the numbers
    /// under it are what you read out loud when a link is no use.
    private func shareLocation() {
        guard !isFindingLocation else { return }
        isFindingLocation = true
        problem = nil

        Task {
            defer { isFindingLocation = false }

            do {
                // Looked at before it's sent. A fix taken indoors, from a watch, can be a
                // street off — and the numbers give no hint of that.
                sheet = .location(try await LocationFix.current())
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let target = replyTarget

        draft = ""
        replyTarget = nil

        Task { await session.send(text, to: conversation, replyingTo: target) }
    }
}

/// Several pictures sent at once, drawn as one thing.
///
/// Two across and four at most, with a count over the last when there is more behind it —
/// the same shape as the phone, at the size this screen can give it. Tapping one opens that
/// picture; holding the row does what holding any message does.
private struct WatchAlbumRow: View {
    @Environment(ChatSession.self) private var session

    let album: PhotoAlbum.Album
    let isMine: Bool

    private var tiles: [Message] { Array(album.photos.prefix(4)) }
    private var hidden: Int { album.photos.count - tiles.count }

    private let side: CGFloat = 84

    var body: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: 12) }

            VStack(alignment: .leading, spacing: 2) {
                LazyVGrid(
                    columns: [
                        GridItem(.fixed(side), spacing: 2),
                        GridItem(.fixed(side), spacing: 2)
                    ],
                    spacing: 2
                ) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, photo in
                        // The last tile of a shortened album opens the album, not the
                        // picture under the number — that number is a door, not a photo.
                        let isDoor = hidden > 0 && index == tiles.count - 1

                        NavigationLink {
                            if isDoor {
                                WatchAlbumOverview(photos: album.photos)
                            } else {
                                WatchMediaViewer(photos: album.photos, start: photo)
                            }
                        } label: {
                            WatchAttachment(message: photo, tile: side)
                                .overlay {
                                    if isDoor {
                                        ZStack {
                                            Color.black.opacity(0.45)
                                            Text("+\(hidden)")
                                                .font(.title3.weight(.semibold))
                                                .foregroundStyle(.white)
                                        }
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: side * 2 + 2)

                if let caption = album.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .frame(width: side * 2 + 2, alignment: .leading)
                        .background(Color.white.opacity(0.15))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: isMine ? .bottomLeading : .bottomTrailing) {
                if !album.reactions.isEmpty {
                    Tapbacks(reactions: album.reactions, size: 20)
                        .offset(x: isMine ? -10 : 10, y: 10)
                }
            }
            .padding(.bottom, album.reactions.isEmpty ? 0 : 10)

            if !isMine { Spacer(minLength: 12) }
        }
    }
}

/// Every picture in one album, so a number on a tile leads somewhere.
private struct WatchAlbumOverview: View {
    let photos: [Message]

    /// How many across, for this many pictures. Two of them side by side are two stamps with
    /// a screen of black under them; a dozen in two columns is a column you scroll forever.
    private var columns: Int { photos.count <= 2 ? 1 : 2 }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 2),
                    count: columns
                ),
                spacing: 2
            ) {
                ForEach(photos) { photo in
                    NavigationLink {
                        WatchMediaViewer(photos: photos, start: photo)
                    } label: {
                        Color.clear
                            .aspectRatio(1, contentMode: .fill)
                            .overlay { WatchAlbumTile(message: photo) }
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("\(photos.count) photos")
    }
}

/// One square in the overview, filled rather than fitted: a grid of different heights is a
/// mess to look along, and an overview exists to be looked along.
private struct WatchAlbumTile: View {
    @Environment(ChatSession.self) private var session

    let message: Message

    @State private var loaded: AttachmentLoader.Result?

    /// A picture that didn't come, which says so rather than turning for ever.
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded {
                Image(uiImage: loaded.image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .overlay {
                        if failed {
                            Image(systemName: message.kind == .video ? "film" : "photo")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .task {
            guard loaded == nil else { return }
            failed = false
            loaded = await AttachmentLoader.load(
                message,
                session: session,
                limits: AnimatedMedia.Limits(maximumPixelSize: 240, maximumFrames: 1),
                width: 240,
                height: 240
            )
            if loaded == nil, !Task.isCancelled { failed = true }
        }
    }
}

/// What to do with one message: react straight away, or one of three things.
///
/// A reaction is the cheapest answer there is on a wrist, and it used to take four steps:
/// hold, React, find the face, tap. Now it's two — hold, tap — with Apple's six in Apple's
/// order, the same row as the phone, and a seventh that learns which one you use most.
///
/// Seven targets fit when they're in two rows and nothing else crowds them. The full grid is
/// still one tap further, behind the smiling face.
private struct MessageActions: View {
    let onQuickReaction: (String) -> Void
    let onReply: () -> Void
    let onForward: () -> Void
    let onReact: () -> Void

    private let reactions = QuickReactions.row()

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                // Answering first, where it always was: the reactions below it are the
                // newcomers, and they don't get to push the most used action down the screen.
                HStack(spacing: 10) {
                    action("arrowshape.turn.up.left.fill", label: "Reply", action: onReply)
                    action("arrowshape.turn.up.right.fill", label: "Forward", action: onForward)
                    action("face.smiling", label: "More emoji", action: onReact)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 6) {
                    ForEach(reactions, id: \.self) { emoji in
                        Button { onQuickReaction(emoji) } label: {
                            Text(emoji)
                                .font(.title3)
                                .frame(width: 40, height: 40)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .chatmanGlass(in: .circle, interactive: true)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func action(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 46, height: 46)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .chatmanGlass(in: .circle, interactive: true)
        .accessibilityLabel(label)
    }
}

/// Where a message goes next.
///
/// The same list the phone offers, minus the search: on a watch you are passing something to
/// somebody you were just talking to, and that chat is at the top by definition.
private struct ForwardPicker: View {
    @Environment(ChatSession.self) private var session

    let message: Message

    /// Called with where it should go. The sending is left to the conversation, which is
    /// still on screen to say so if it fails — this picker is gone the moment you choose.
    let onPick: (Conversation) -> Void

    var body: some View {
        NavigationStack {
            List(session.forwardTargets()) { conversation in
                Button {
                    onPick(conversation)
                } label: {
                    Text(session.displayName(for: conversation))
                        .font(.footnote)
                        .lineLimit(1)
                }
            }
            .navigationTitle("Forward")
        }
    }
}

private struct WatchMessageRow: View {
    @Environment(ChatSession.self) private var session

    let message: Message
    let isMine: Bool
    /// Whether to name the sender. Only worth the room in a group.
    let showsSender: Bool
    /// Whether this is the last of a run, which is the one that gets the tail.
    let endsRun: Bool
    /// The message this one answers, when it's loaded.
    var quoted: Message? = nil
    /// Whether this is the message that reports how far it got.
    var showsStatus: Bool = false

    /// How wide the picture turned out, so a caption under it can match.
    @State private var mediaWidth: CGFloat?

    /// Nothing but emoji: drawn large and bare, and a watch has even less room to spend on a
    /// bubble around two characters.
    private var isLargeEmoji: Bool {
        message.kind == .text && EmojiOnly.matches(message.body)
    }

    /// Pictures, stickers and emoji stand on their own.
    private var wearsBubble: Bool {
        !isLargeEmoji && message.kind != .image && message.kind != .video && message.kind != .sticker
    }

    var body: some View {
        HStack(spacing: 0) {
            // Yours to the right, theirs to the left, neither reaching the far edge. That gap
            // is what makes a conversation readable at a glance — without it every line looks
            // the same and you have to read each one to know who said it.
            if isMine { Spacer(minLength: 24) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
                // The face beside the name, as Messages does in a group. On a header line
                // rather than beside the bubble: a watch has no width to give away.
                if showsSender, !isMine,
                   let name = session.senderName(of: message)?.split(separator: " ").first {
                    HStack(spacing: 4) {
                        WatchSenderAvatar(message: message)
                        Text(name)
                            .font(.caption.weight(.semibold))
                            // The same colour this person has on the phone, worked out from
                            // their account so it never shifts between devices or restarts.
                            .foregroundStyle(SenderColour.of(message.sender))
                            .lineLimit(1)
                    }
                }

                if let quoted {
                    WatchQuotedMessage(message: quoted)
                }

                content
                    .padding(.horizontal, wearsBubble ? 9 : 0)
                    .padding(.vertical, wearsBubble ? 6 : 0)
                    .background {
                        if wearsBubble {
                            BubbleShape(tail: endsRun ? (isMine ? .trailing : .leading) : nil, radius: 14)
                                .fill(bubble)
                        }
                    }
                    .foregroundStyle(isMine && wearsBubble ? .white : .primary)
                    .opacity(message.didFailToSend ? 0.55 : 1)
                    // On the bubble and over its corner, the way the phone draws it and the
                    // way Messages does. Underneath as a line of its own it read as somebody
                    // having sent you a single character.
                    .overlay(alignment: isMine ? .topLeading : .topTrailing) {
                        if !message.reactions.isEmpty {
                            Tapbacks(reactions: message.reactions, size: 20)
                                .offset(x: isMine ? -10 : 10, y: -12)
                        }
                    }
                    .padding(.top, message.reactions.isEmpty ? 0 : 12)

                // Away from the phone a send can fail quietly, and a message that looks
                // delivered but never left is worse than one that plainly didn't. A tap sends
                // it again — the same message, so the server takes it once however often it's
                // tried.
                if message.didFailToSend {
                    if session.canRetry(message) {
                        Button {
                            Task { await session.retry(message) }
                        } label: {
                            Label("Not sent · tap to retry", systemImage: "exclamationmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label("Not sent", systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } else if let problem = message.deliveryProblem, isMine {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if showsStatus {
                    // Only under the newest message you sent — the same rule as the phone,
                    // and on this screen the only one there's room for.
                    Text(session.sendStatus(of: message).label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)

            if !isMine { Spacer(minLength: 24) }
        }
    }

    /// Yours carries a gradient, theirs is flat — the same distinction Messages makes, and it
    /// survives being glanced at from an arm's length.
    private var bubble: AnyShapeStyle {
        guard isMine else { return AnyShapeStyle(Color.white.opacity(0.15)) }

        // The colour of the service this conversation lives on, at a fraction of its
        // strength — enough to tell a Signal chat from a WhatsApp one at a glance, nowhere
        // near enough to fight with the words on top of it.
        let brand = (message.conversation?.network ?? .matrix).brandColour
        let colour = Color(red: brand.red, green: brand.green, blue: brand.blue)

        return AnyShapeStyle(LinearGradient(
            colors: [colour.opacity(0.55), colour.opacity(0.35)],
            startPoint: .top, endPoint: .bottom
        ))
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .image, .video:
            // Two shapes that meet, exactly as on the phone: the picture keeps its own
            // edges, and the words get a bubble that starts where the picture stops and is
            // no wider than it. The width has to be measured, because a standing photo is
            // narrower than the row it sits in.
            if let caption = message.caption, !caption.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    WatchAttachment(message: message, squaresBottom: true)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.width
                        } action: { width in
                            mediaWidth = width
                        }

                    Text(caption)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .frame(width: mediaWidth, alignment: .leading)
                        .background(bubble)
                        .clipShape(
                            UnevenRoundedRectangle(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: 8,
                                bottomTrailingRadius: 8,
                                topTrailingRadius: 0
                            )
                        )
                }
            } else {
                WatchAttachment(message: message)
            }

        case .sticker:
            WatchAttachment(message: message, sticker: true)

        case .poll:
            WatchPoll(message: message)

        case .encrypted:
            Label("Encrypted", systemImage: "lock")
                .font(.caption2)

        case .audio:
            Label("Voice message", systemImage: "waveform")
                .font(.caption2)

        case .file:
            Label(message.body, systemImage: "doc")
                .font(.caption2)

        case .text, .emote, .notice:
            VStack(alignment: .leading, spacing: 5) {
                Text(LinkedText.containsLink(message.body)
                     ? LinkedText.attributed(message.body)
                     : AttributedString(message.body))
                    .font(isLargeEmoji ? .system(size: 34) : .body)
                    .opacity(message.isPending ? 0.5 : 1)
                    // As tall as the words need. The same squeeze as on the phone: a long
                    // message with a quote above it had its last line replaced by an
                    // ellipsis, and on this screen a message is long far sooner.
                    .fixedSize(horizontal: false, vertical: true)

                // Somebody's location, from Chatman or from anything else that sent one.
                if let place = SharedLocation.inside(message.body), let url = place.appleMapsURL {
                    Link(destination: url) {
                        Label("Open in Maps", systemImage: "map.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

/// A poll on the watch: the question, and how the answers stand.
///
/// Read only. Voting is a phone thing — a list of answers to tap on a screen this size is a
/// list of targets too close together, and a poll is rarely urgent.
private struct WatchPoll: View {
    @Environment(ChatSession.self) private var session

    let message: Message

    var body: some View {
        let state = message.poll
        let tally = state?.tally ?? [:]
        let chosen = session.myVote(in: message)

        VStack(alignment: .leading, spacing: 4) {
            Label(message.body, systemImage: "chart.bar.fill")
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            ForEach(state?.answers ?? [], id: \.id) { answer in
                HStack(spacing: 4) {
                    Image(systemName: chosen.contains(answer.id) ? "checkmark.circle.fill" : "circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(answer.text)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 2)
                    if let count = tally[answer.id], count > 0 {
                        Text(count.formatted())
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// The sender's picture in a group, small enough to sit next to their name.
private struct WatchSenderAvatar: View {
    @Environment(ChatSession.self) private var session

    let message: Message

    private var initial: String {
        let name = session.senderName(of: message) ?? ""
        return name.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        RemoteImage(
            request: session.avatarRequest(for: session.senderAvatarURL(of: message), size: 60),
            cacheKey: session.senderAvatarURL(of: message)
        ) {
            Circle()
                .fill(.gray.opacity(0.35))
                .overlay {
                    Text(initial)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: 18, height: 18)
        .clipShape(Circle())
    }
}

/// One line of whatever is being answered, so a reply reads as a reply.
private struct WatchQuotedMessage: View {
    @Environment(ChatSession.self) private var session

    let message: Message

    /// Who is being answered, first name only — a watch has room for one line, and the name
    /// is half of what makes a reply make sense.
    private var who: String {
        if session.isMine(message) { return "You" }
        return session.senderName(of: message)?.split(separator: " ").first.map(String.init) ?? ""
    }

    /// Who said it and what they said, as one piece of text.
    ///
    /// One attributed string rather than three `Text`s added together: that operator is
    /// deprecated, and the name still needs to be the bold half.
    private var quoted: AttributedString {
        var name = AttributedString(who)
        name.font = .system(size: 11, weight: .semibold)

        var rest = AttributedString(who.isEmpty ? message.body : " " + message.body)
        rest.font = .system(size: 11)

        name.append(rest)
        return name
    }

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(.gray)
                .frame(width: 2)

            Text(quoted)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 2)
    }
}

/// A received photo, film or GIF, fetched at watch size.
///
/// A watch downloads over its own radio and holds very little, so this asks for the smallest
/// version that still reads at arm's length. A GIF plays — sampled down to a couple of dozen
/// frames, because the alternative on this much memory is the app being closed for you.
struct WatchAttachment: View {
    @Environment(ChatSession.self) private var session
    let message: Message

    /// Whether something is going to sit directly underneath this.
    ///
    /// A caption joins onto the bottom edge, and a rounded corner there would leave two
    /// notches of the page showing through between the picture and the words.
    var squaresBottom = false

    /// When set, the picture fills a square of this size instead of keeping its own shape.
    var tile: CGFloat?

    /// Drawn the size of a large emoji, fitted and unclipped.
    var sticker = false

    @State private var loaded: AttachmentLoader.Result?
    @State private var failed = false

    /// The outline: rounded all round on its own, flat along the bottom when a caption is
    /// joining on.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 8,
            bottomLeadingRadius: squaresBottom ? 0 : 8,
            bottomTrailingRadius: squaresBottom ? 0 : 8,
            topTrailingRadius: 8
        )
    }

    var body: some View {
        Group {
            if let loaded, sticker {
                Image(uiImage: loaded.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 90, maxHeight: 90)
            } else if let loaded {
                Image(uiImage: loaded.image)
                    .resizable()
                    .aspectRatio(contentMode: tile == nil ? .fit : .fill)
                    // Held to its own shape and capped in height. Without the ratio a
                    // standing photo is drawn narrow inside a row-wide view, and anything
                    // measuring that view — a caption, for one — comes out too wide. A tile
                    // in an album is a square by definition, so it skips all of that.
                    .aspectRatio(
                        tile == nil
                            ? loaded.image.size.width / max(loaded.image.size.height, 1)
                            : nil,
                        contentMode: tile == nil ? .fit : .fill
                    )
                    .frame(width: tile, height: tile)
                    .frame(maxHeight: tile == nil ? 140 : nil)
                    .clipped()
                    .clipShape(shape)
                    .overlay {
                        if loaded.isPlayable {
                            Image(systemName: "play.fill")
                                .font(.footnote)
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if message.isAnimated {
                            Text("GIF")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 3))
                                .padding(4)
                        }
                    }
            } else if failed {
                // Given the same outline as a picture that did arrive, so a caption still
                // has something to join onto. Bare text with a bubble welded under it looks
                // like a mistake rather than like a photo that didn't come through.
                //
                // In an album it is the symbol alone: four words do not fit in a square that
                // size and break into a column of syllables trying.
                Group {
                    if tile == nil {
                        Label(
                            message.kind == .video ? "Video unavailable" : "Picture unavailable",
                            systemImage: message.kind == .video ? "film" : "photo"
                        )
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Image(systemName: message.kind == .video ? "film" : "photo")
                            .font(.title3)
                            .frame(width: tile, height: tile)
                    }
                }
                .foregroundStyle(.secondary)
                .background(.gray.opacity(0.25), in: shape)
            } else {
                shape
                    .fill(.gray.opacity(0.3))
                    .frame(width: tile, height: tile ?? 80)
                    .overlay { ProgressView() }
            }
        }
        // Again when the message gets its address; see the phone's thumbnail.
        .task(id: "\(message.mediaURL ?? "")#\(message.didFailToSend)") { await load() }
    }

    /// What this photo is filed under at this size. The viewer reads the same key, so
    /// opening a picture shows something immediately instead of a spinner.
    static func cacheKey(for message: Message) -> String? {
        AttachmentLoader.cacheKey(for: message, width: 320)
    }

    private func load() async {
        guard loaded == nil else { return }

        // Waiting, not failed, while your own picture is still on its way — and a load
        // cancelled by opening another picture is not a failure either. See the phone.
        if message.isStandIn, !message.hasLocalCopy, !message.didFailToSend { return }
        failed = false

        let result = await AttachmentLoader.load(
            message, session: session, limits: .watch, width: 320, height: 240
        )

        if let result {
            loaded = result
        } else if !Task.isCancelled {
            failed = true
        }
    }
}

/// What sits behind the plus.
///
/// Two rows and nothing else. A menu on a watch that needs scrolling before you can read it
/// is a menu that costs more than the thing it's hiding.
private struct ShareMenu: View {
    let isFindingLocation: Bool
    let onEmoji: () -> Void
    let onLocation: () -> Void

    var body: some View {
        List {
            Button(action: onEmoji) {
                Label("Emoji", systemImage: "face.smiling")
            }

            Button(action: onLocation) {
                Label("Location", systemImage: "location.fill")
            }
            .disabled(isFindingLocation)
        }
        .navigationTitle("Share")
    }
}

/// Emoji, laid out the way Messages lays them out.
///
/// Grouped rather than one long list: the point of a grid on a watch is that you find what
/// you want by looking, and eighty faces in no order is a search rather than a glance. The
/// order inside each group is Apple's — the most-used first, because that's where a thumb
/// goes without being told.
private struct EmojiPicker: View {
    let onPick: (String) -> Void

    private struct Group: Identifiable {
        let id: String
        let emoji: [String]
    }

    /// The ones you use most first, then everything grouped the way Messages groups it.
    private var groups: [Group] {
        let frequent = QuickReactions.frequent()
        return frequent.isEmpty ? Self.catalogue : [Group(id: "Frequently used", emoji: frequent)] + Self.catalogue
    }

    private static let catalogue: [Group] = [
        Group(id: "Smileys", emoji: [
            "😀", "😂", "🤣", "🥲", "😊", "😇", "🙂", "😉", "😍", "🥰",
            "😘", "😋", "😜", "🤪", "🤨", "😎", "🥳", "😏", "😌", "😔",
            "😢", "😭", "😤", "😠", "🤯", "😱", "🥶", "😴", "🤤", "🤒",
            "🤢", "🥴", "😵", "🤠", "🤡", "👻", "💀", "👽", "🤖", "🎃"
        ]),
        Group(id: "Hands", emoji: [
            "👍", "👎", "👌", "🤌", "✌️", "🤞", "🫶", "🙏", "👏", "🙌",
            "💪", "🫡", "🤝", "👋", "🖖", "✊", "👊", "🤙"
        ]),
        Group(id: "Hearts", emoji: [
            "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "💔", "❣️",
            "💕", "💞", "💯", "🔥", "✨"
        ]),
        Group(id: "Things", emoji: [
            "🎉", "🎊", "🎁", "🎂", "☕️", "🍺", "🍕", "🚗", "🏠", "☀️",
            "🌧️", "⏰", "📞", "✅", "❌", "⚠️", "❓", "❗️", "💤", "👀"
        ])
    ]

    private let columns = [GridItem(.adaptive(minimum: 40))]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(group.emoji, id: \.self) { symbol in
                                Button { onPick(symbol) } label: {
                                    Text(symbol).font(.title3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text(group.id)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .background(.background)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("Emoji")
    }
}

/// The other person, at the top right of a conversation on the watch.
///
/// The same size as the back button opposite it, because two round things at either end of a
/// bar that don't match is the sort of thing you can't stop seeing once you've seen it.
private struct WatchConversationFace: View {
    @Environment(ChatSession.self) private var session

    let conversation: Conversation

    private var initials: String {
        let words = session.displayName(for: conversation).split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        RemoteImage(
            request: session.avatarRequest(for: conversation, size: 60),
            cacheKey: conversation.avatarURL
        ) {
            if let image = session.contactPicture(for: conversation) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(.gray.opacity(0.35))
                    .overlay {
                        Text(initials)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 33, height: 33)
        .clipShape(Circle())
    }
}
