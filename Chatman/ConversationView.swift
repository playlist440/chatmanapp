import AVFoundation
import ImageIO
import QuickLook
import UniformTypeIdentifiers
import SwiftUI
import SwiftData
import PhotosUI
import ChatmanKit

/// One conversation: its messages, and somewhere to type.
struct ConversationView: View {
    let conversation: Conversation

    /// How many messages back are on screen.
    ///
    /// A conversation from a year ago holds thousands, and building all of them is what made
    /// opening one feel slow. Sixty is more than a screenful; the rest arrives when you ask
    /// for it, which is the same gesture as fetching older ones from the server.
    ///
    /// Held one level up, because it decides what the store is asked for, and a query can
    /// only be told that when it is made. See `ConversationScreen`.
    @State private var window = ConversationScreen.openingWindow

    var body: some View {
        ConversationScreen(conversation: conversation, window: $window)
    }
}

private struct ConversationScreen: View {
    @Environment(ChatSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation

    /// The newest messages, as many as are drawn and one more to say whether there is more.
    ///
    /// Sorted and limited by the store. This used to be the whole conversation, sorted —
    /// and the store answers again after every save, which during a sync is several times a
    /// second. A year of history meant thousands of messages fetched on the main thread each
    /// time, to draw sixty of them.
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

    /// How many messages the first drawing of a conversation is built from.
    ///
    /// Eighteen, which is about two screenfuls. The rest arrives a moment later, while you are
    /// looking at the bottom — where the widening happens off-screen above you and the
    /// settling logic holds your place.
    ///
    /// The point is what happens before anything moves. The transition into a conversation
    /// cannot begin until the conversation has been built, so every row built before the first
    /// frame is time spent looking at the screen you are trying to leave. Sixty messages came
    /// to forty-four rows, all of them laid out for a screen that shows about ten.
    static let openingWindow = 18
    private static let settledWindow = 60

    /// What is being typed, in a box of its own.
    ///
    /// As plain state on this screen every letter ran the whole conversation's body again —
    /// every bubble, every measurement — and a tap on send or back straight after typing
    /// waited behind that. Only the field reads it now.
    @State private var draftBox = DraftText()

    private var draft: String {
        get { draftBox.text }
        nonmutating set { draftBox.text = newValue }
    }
    @State private var replyTarget: Message?
    @State private var isLoadingHistory = false
    @State private var viewing: Message?

    /// Whether the other person's picture is being looked at on its own.
    @State private var isShowingPortrait = false
    @State private var sendFailure: String?

    /// Why taking a message back didn't work, when it didn't.
    @State private var deleteFailure: String?
    @State private var editing: Message?

    /// True while the device is working out where it is.
    @State private var isFindingLocation = false

    /// Why sharing a location didn't work, when it didn't.
    @State private var locationProblem: String?

    /// A downloaded attachment, on its way to Quick Look.
    @State private var previewing: URL?
    @State private var isFetchingFile = false

    /// Bumped whenever something should put the newest message back in view.
    /// Where the name ends and where the field begins, in points from their own edge.
    ///
    /// Measured, not counted out. These were two hand-tuned numbers and it took three goes to
    /// land them: the name sits lower than it looks, because the 46 points this screen keeps
    /// free above the messages fall inside the safe area and stack on top of the status bar.
    /// A number arrived at that way is right for one phone on one version of iOS and quietly
    /// wrong on the next — and eight points is exactly the sort of thing a system update
    /// moves. Asking the views where they actually are costs nothing and cannot drift.
    /// Whether the conversation is still finding its feet after being opened.
    ///
    /// Pictures arrive, bubbles grow, and the bottom moves out from under the view — so for
    /// the first moments the bottom is held rather than watched. Without it the correction
    /// gives up the instant the content settling pushes the last message out of sight, which
    /// is exactly when it is needed.
    /// Whether the screen is up and the animation over.
    ///
    /// Everything you can only reach after that moment is built after that moment. See
    /// `chatmanMenu`.
    @State private var isReady = false

    @State private var isSettling = true

    /// Whether the opening has run its course once.
    ///
    /// The opening task starts again when this screen comes back from a full-screen film
    /// or album, and it began by settling all over again — six hundred milliseconds in which
    /// any change in height sent the list to the bottom. Reading halfway up, you lost your
    /// place for having looked at a picture.
    @State private var hasOpened = false

    /// Whether a finger is moving the conversation right now. The backdrop draws as often as
    /// the screen while it is, so whatever follows the scroll keeps up with it.
    /// Whether the conversation is moving, in a box: only the backdrop reads it, so starting
    /// or stopping a scroll doesn't run this whole screen again.
    @State private var scrollFlag = ScrollFlag()

    /// Where the conversation has scrolled to, for the backdrop behind it. See `SkyDepth`.
    @State private var skyDepth = SkyDepth()

    @State private var composerHeight: CGFloat = 96

    @State private var scrollRequests = 0

    /// What's presented over the conversation.
    @State private var sheet: Sheet?

    /// Whether the newest message is in view.
    @State private var isAtBottom = true

    /// The first message you hadn't read when this conversation opened, for the divider.
    ///
    /// Remembered as which message it was, not how far it was from the end. Counted from the
    /// end, the divider moved every time anything arrived: send a reply to two unread
    /// messages and it sat above the second one, send another and it sat above your own.
    @State private var firstUnreadID: String?

    /// How many were unread when the conversation opened, before reading it set that to nought.
    @State private var unreadAtOpen = 0

    /// From this many unread messages on, the conversation opens where they begin rather than
    /// at the end — about a screenful and a half. Fewer than that fit on the screen anyway,
    /// and opening at the end shows them all; more, and opening at the end means scrolling
    /// back to find where you were and then reading upwards.
    private static let opensAtFirstUnread = 10

    /// A message to flash after jumping to it, so the eye lands in the right place.
    @State private var highlighted: String?

    /// A picture off the clipboard, waiting to be looked at before it goes anywhere.
    @State private var pendingPhotos: [PastedPhoto] = []

    /// An album being looked through, from the tile that said how many were hidden.
    @State private var overview: AlbumOverview.Contents?

    /// What "the bottom" means: the end of the conversation, not the last message in it.
    private let bottomAnchor = "chatman.end-of-conversation"

    /// Where the unread messages begin.
    private static let dividerAnchor = "chatman.new-messages"


    /// The message that was at the top before older ones were added, so the view can go back
    /// to it rather than jumping.
    @State private var topBeforeWidening: String?

    /// What's actually drawn: the tail of the conversation.
    private var messages: [Message] {
        Array(stored.prefix(window).reversed())
    }

    /// Whether there is more above what's on screen, stored or on the server.
    private var hasMore: Bool {
        stored.count > window || conversation.previousBatch != nil
    }

    /// The one message that carries a delivery status, the way Messages does it: the newest
    /// you sent, and no other.
    ///
    /// Taken from what's on screen. The newest thing you sent is by definition at the end of
    /// the conversation, so there is no reason to walk the whole of it to find it.
    private var statusMessageID: String? {
        messages.last { session.isMine($0) }?.id
    }

    /// Messages by event ID, so a reply can find what it answers without a scan per row.
    ///
    /// Built over the visible window rather than the whole conversation: a reply to something
    /// from last year has nothing to point at on screen anyway.
    private var byID: [String: Message] {
        Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        timeline
        // A firm edge under the name, as Messages has in iOS 27: what scrolls up stops at the
        // bar. The soft one let a quoted message read through under the status bar.
        .scrollEdgeEffectStyle(.hard, for: .top)
        // The messages themselves fade out at both ends, rather than something being painted
        // over them.
        //
        // Painting was the first attempt and it was plainly wrong: a band of the backdrop's
        // darkest colour, laid over a backdrop which at that point is that colour mixed with
        // black and dimmed by the glow setting. Two different colours, meeting in a straight
        // line across the screen. Nothing short of recomputing the backdrop's own shading
        // would have matched it, and a copy of a drawing is a second thing to keep in step.
        //
        // A mask takes the words away instead and lets whatever is behind them carry on
        // untouched — any colour, any glow, light mode or dark, and nothing to keep in step.
        .mask(alignment: .top) { edgeFades }
        // What the messages sit on. Behind everything else on purpose: the bubbles are
        // translucent and take their light from whatever is underneath them.
        //
        // The same backdrop as the list, so opening a chat is going further into one place
        // rather than into another one.
        .background {
            MovingBackdrop(depth: skyDepth, flag: scrollFlag)
                .ignoresSafeArea()
        }
        // The way back down, just above the field and in the middle, where your thumb
        // already is. It only exists while there is somewhere to go back to.
        .overlay(alignment: .bottom) {
            if !isAtBottom {
                Button {
                    scrollRequests += 1
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))

                        if conversation.unreadCount > 0 {
                            Text("\(conversation.unreadCount) new")
                                .font(.footnote.weight(.medium))
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .chatmanGlass(in: .capsule, interactive: true)
                .padding(.bottom, 8)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Its height plus whatever sits under it, so the fade ends where the field
            // begins however tall it has grown — a reply banner, a pasted photo, two lines
            // of typing.
            Composer(
                draft: Bindable(draftBox).text,
                replyTarget: $replyTarget,
                onSend: send,
                onTypingChanged: { isTyping in
                    Task { await session.setTyping(isTyping, in: conversation) }
                },
                onFocusChanged: { focused in
                    // The keyboard changes the height of the screen, not the height of the
                    // list, so without this the newest messages end up behind it.
                    guard focused else { return }
                    scrollRequests += 1
                },
                onPickPhoto: sendFromLibrary,
                onCapture: sendCapture,
                onPickFile: sendFile,
                onPasteImage: holdPastedImage,
                pendingPhotos: $pendingPhotos,
                onShareLocation: shareLocation,
                editing: $editing,
                isFindingLocation: isFindingLocation,
                isReady: isReady
            )
            .onGeometryChange(for: CGFloat.self) { proxy in
                // The field's own height, and nothing underneath it.
                //
                // This used to add the safe area below as well, which is the home indicator
                // when nothing is up and the whole keyboard when something is. So the moment
                // you tapped the field, the band held at its faintest grew by three hundred
                // points and washed out half the conversation. What the fade covers is the
                // field; the keyboard covers itself.
                proxy.size.height
            } action: { height in
                composerHeight = height
            }
        }
        // The system's bar, with who you're talking to in the middle as one button — face and
        // name together, the way Messages does it. It used to be our own: a circle to go back,
        // a pill with the name and a face, all glass, with the messages running through it at
        // a fifth of their strength. The real bar brings what that copy never had: the edge
        // effect that keeps text from reading through the title, the glass setting, and the
        // swipe back from anywhere on the screen.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    sheet = .details
                } label: {
                    HStack(spacing: 8) {
                        Avatar(conversation: conversation, size: 30, showsNetwork: false)
                        Text(headerName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(session.displayName(for: conversation)))
                .accessibilityHint("Shows chat info")
            }
        }
        // One sheet, chosen by what's in it. Three separate `.sheet` modifiers on the same
        // view is how the details screen quietly stopped opening: SwiftUI honours one of
        // them and drops the rest without saying so.
        .sheet(item: $sheet) { which in
            switch which {
            case .details:
                ConversationDetailView(conversation: conversation)

            case .forward(let message):
                ForwardPicker(message: message)

            case .reactions(let message):
                EmojiPicker { emoji in
                    sheet = nil
                    Task { await session.react(with: emoji, to: message) }
                }

            case .location(let place):
                LocationConfirmation(place: place) {
                    sheet = nil

                    // Passed on, like any other message. It was being read and thrown away,
                    // so answering somebody with your location quietly stopped being an
                    // answer — the compiler spotted it before anybody did.
                    let target = replyTarget
                    replyTarget = nil
                    Task {
                        await session.send(place.message, to: conversation, replyingTo: target)
                    }
                } onCancel: {
                    sheet = nil
                }
            }
        }
        .fullScreenCover(item: $viewing) { message in
            // Every picture in the conversation, not only the one that was tapped: opening
            // one and being stuck with it is the thing every photo viewer learned not to do.
            MediaViewer(photos: session.pictures(in: conversation, around: message), start: message)
        }
        // Its own stack, so opening a picture is a step forward with a way back — rather
        // than one screen closing and another opening over the conversation.
        .fullScreenCover(item: $overview) { contents in
            NavigationStack {
                AlbumOverview(photos: contents.photos)
            }
        }
        .quickLookPreview($previewing)
        .alert("Couldn't send", isPresented: .constant(sendFailure != nil)) {
            Button("OK") { sendFailure = nil }
        } message: {
            Text(sendFailure ?? "")
        }
        // Said out loud, because the message is still on everyone else's screen and you
        // need to know that before you assume it is gone.
        .alert(
            "Couldn't delete",
            isPresented: Binding(
                get: { deleteFailure != nil },
                set: { if !$0 { deleteFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deleteFailure = nil }
        } message: {
            Text("It is still there for everyone else. \(deleteFailure ?? "")")
        }
        .alert(
            "Couldn't share your location",
            isPresented: Binding(
                get: { locationProblem != nil },
                set: { if !$0 { locationProblem = nil } }
            )
        ) {
            Button("OK", role: .cancel) { locationProblem = nil }
        } message: {
            Text(locationProblem ?? "")
        }
        .task {
            // Before anything is marked, so the divider knows where you left off. Once only:
            // this runs again when the screen comes back from a film or an album, and by
            // then the count is zero — which took the divider away while you were still
            // reading past it.
            let waiting = conversation.unreadCount
            if firstUnreadID == nil, waiting > 0,
               let first = session.firstUnreadMessageID(in: conversation, unread: waiting) {
                firstUnreadID = first
                unreadAtOpen = waiting
            }
            session.setManuallyUnread(false, for: conversation)
            await session.markRead(conversation)
        }
        // And again on the way out. Messages that arrive while you're reading push the count
        // back up, and marking only on arrival left a chat you had just finished sitting in
        // the list with a badge on it.
        .onDisappear {
            Task { await session.markRead(conversation) }
        }
    }

    /// What goes beside the face in the bar.
    ///
    /// A first name for a person, the whole thing for a group. Somebody's surname is not what
    /// you check when you look up to see who you're talking to, and leaving it out is what
    /// lets the pill stay the size of a name.
    private var headerName: String {
        let full = session.displayName(for: conversation)
        guard !conversation.isGroup, let first = full.split(separator: " ").first else {
            return full
        }
        return String(first)
    }

    /// What's on top of the conversation, if anything.
    private enum Sheet: Identifiable {
        case details
        case forward(Message)
        case location(SharedLocation)
        case reactions(Message)

        var id: String {
            switch self {
            case .details: "details"
            case .forward(let message): "forward-" + message.id
            case .location(let place): "location-" + place.id
            case .reactions(let message): "reactions-" + message.id
            }
        }
    }

    /// Sends where you are, as something anyone can open.
    ///
    /// A location goes as text on purpose: no bridge carries a location message intact, and
    /// text arrives everywhere. What the other person gets is a link — their own map app
    /// opens it — and the numbers underneath it, which is what you read out loud if the link
    /// is no use to whoever you're talking to.
    private func shareLocation() {
        guard !isFindingLocation else { return }
        isFindingLocation = true

        Task {
            defer { isFindingLocation = false }

            do {
                // Shown before it's sent, never after. A location is the one message where
                // being wrong matters and where you can't tell it's wrong from the numbers:
                // a fix taken indoors can be a street away, and the only way to know is to
                // look at it on a map.
                sheet = .location(try await LocationFix.current())
            } catch {
                locationProblem = error.localizedDescription
            }
        }
    }

    private func send() {
        // Trimmed, because a trailing newline from the keyboard is not part of what somebody
        // meant to say — and on the other end it's an empty line in the bubble.
        // A picture waiting above the field is what the button is for, and whatever is in
        // the field goes with it as its caption rather than as a message of its own.
        if !pendingPhotos.isEmpty {
            sendPendingPhotos()
            return
        }

        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Felt at once, before anything has gone over the network: that is what makes sending
        // feel instant on a slow connection.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // The same button does both, because the composer is already telling you which one
        // you're doing — a second button would only be there to be pressed by mistake.
        if let message = editing {
            editing = nil
            draft = ""

            Task {
                do {
                    try await session.edit(message, to: text)
                } catch {
                    sendFailure = error.localizedDescription
                }
            }
            return
        }

        let target = replyTarget

        draft = ""
        replyTarget = nil

        #if DEBUG
        OpenStopwatch.write("[send] sending \(text.prefix(12))")
        #endif

        Task { await session.send(text, to: conversation, replyingTo: target) }

        // Asked for explicitly rather than left to the arrival of the message: what you just
        // sent should be fully clear of the field you typed it in, and waiting for the echo
        // means it sits half behind it until the server answers.
        isAtBottom = true
        scrollRequests += 1
    }

    private func beginEditing(_ message: Message) {
        replyTarget = nil
        editing = message
        draft = message.body
    }

    /// Sends whatever was picked from the library: a photo, or now also a film.
    private func sendFromLibrary(_ item: PhotosPickerItem) {
        // What the picker says it is, rather than what it looks like. A Live Photo is an
        // image and arrives as its still frame; a film is a film.
        if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
            let target = replyTarget
            replyTarget = nil
            sendLibraryVideo(item, replyingTo: target)
        } else {
            holdLibraryPhoto(item)
        }
    }

    /// Puts a photo from the library above the field, where it waits to be sent.
    ///
    /// Picking used to be sending: one tap in the picker and the photo was in somebody
    /// else's conversation, wrong one or not. Now it waits with any others you pick, can be
    /// taken off again or given a caption, and goes when you press send.
    private func holdLibraryPhoto(_ item: PhotosPickerItem) {
        Task {
            // Loaded as data rather than as an Image: the bytes are what gets uploaded, and
            // re-encoding a picture only makes it bigger and worse.
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                sendFailure = "That picture couldn't be read."
                return
            }
            let photo = PastedPhoto(
                data: data,
                type: item.supportedContentTypes.first,
                preview: await PastedPhoto.thumbnail(of: data)
            )
            withAnimation(.snappy) { pendingPhotos.append(photo) }
        }
    }

    /// Sends a film from the library, as a file from beginning to end.
    ///
    /// Never as `Data`. A minute of 4K is around four hundred megabytes, and reading that
    /// into memory to hand it to an uploader that copies it again is two ways of being killed
    /// by the system before the send finishes.
    private func sendLibraryVideo(_ item: PhotosPickerItem, replyingTo target: Message?) {
        Task {
            guard let film = try? await item.loadTransferable(type: LibraryVideo.self) else {
                sendFailure = "That video couldn't be read."
                return
            }

            // Ours now, and ours to clear up: the picker's own copy is gone the moment it
            // hands it over.
            defer { try? FileManager.default.removeItem(at: film.url) }

            let bytes = (try? film.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard bytes <= 100_000_000 else {
                sendFailure = "That video is too large to send."
                return
            }

            let type = UTType(filenameExtension: film.url.pathExtension)
            let mime = type?.preferredMIMEType ?? "video/quicktime"

            do {
                try await session.sendAttachment(
                    .file(film.url),
                    filename: film.url.lastPathComponent,
                    mimeType: mime,
                    kind: .video,
                    size: await film.dimensions,
                    to: conversation,
                    replyingTo: target
                )
            } catch {
                sendFailure = error.localizedDescription
            }
        }
    }

    /// Takes a picture off the clipboard and puts it above the field, not in the chat.
    ///
    /// Pasting is one tap, and one tap should never be the last thing that happens before a
    /// picture lands in somebody else's conversation. So it waits here, where it can be
    /// looked at, given a line of text, or thrown away.
    private func holdPastedImage(_ data: Data, type: UTType?) {
        withAnimation(.snappy) {
            pendingPhotos.append(PastedPhoto(
                data: data, type: type, preview: UIImage(data: data)
            ))
        }
    }

    /// Sends the pictures that have been waiting, with whatever was typed as the caption of
    /// the last one — so the words arrive under the photos they are about.
    private func sendPendingPhotos() {
        let photos = pendingPhotos
        let target = replyTarget
        let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        replyTarget = nil
        draft = ""
        withAnimation(.snappy) { pendingPhotos = [] }

        isAtBottom = true
        scrollRequests += 1

        Task {
            // One after another, in the order they were picked. Sent side by side they would
            // be free to arrive in any order, and an album is read in sequence.
            for (index, photo) in photos.enumerated() {
                let isLast = index == photos.count - 1
                // As it is: a screenshot is PNG, a photo HEIC or JPEG, and re-encoding it here
                // would cost quality to gain nothing.
                let mime = photo.type?.preferredMIMEType ?? "image/jpeg"
                let name = "photo." + (photo.type?.preferredFilenameExtension ?? "jpg")
                do {
                    try await session.sendImage(
                        photo.data,
                        filename: name,
                        mimeType: mime,
                        size: photo.size,
                        caption: isLast && !caption.isEmpty ? caption : nil,
                        to: conversation,
                        replyingTo: index == 0 ? target : nil
                    )
                } catch {
                    sendFailure = error.localizedDescription
                }
            }
        }
    }

    /// Something at the very end to scroll to, so the typing line counts as "the bottom".
    private let typingAnchor = "typing"

    /// The conversation itself.
    ///
    /// Its own property because the compiler gave up type-checking a body that had the list,
    /// a toolbar, four sheets and an alert in one expression.
    private var timeline: some View {
        // Worked out once for the whole list, then handed down.
        //
        // These used to be computed properties read from inside the loop, which is a trap
        // with a measurable price: `messages` rebuilds the window and `byID` builds a
        // dictionary of it, and a row asked for them four times over. Sixty rows meant sixty
        // dictionaries per redraw — and a redraw happens on every keystroke. Measured on a
        // Mac it was 1.46 ms against 0.025 ms; on an iPhone 13 that is the difference
        // between typing that keeps up and typing that doesn't.
        #if DEBUG
        let startedAt = Date()
        #endif

        let shown = messages
        let quotedBy = byID
        let newest = statusMessageID
        // Pictures sent together are drawn together, and the line the bridge writes about
        // them is dropped on the way. See `PhotoAlbum`.
        let items = PhotoAlbum.group(shown)
        let divider = firstUnreadIndex(in: items)

        // Which row each message ended up in.
        //
        // A row is identified by the message it is anchored to, and an album swallows six
        // other messages into one row. Without this, tapping a quote of the third picture in
        // an album asks the list to scroll to an ID that no longer exists — which fails
        // quietly, and looks exactly like a tap that didn't register.
        let rowFor: [String: String] = items.reduce(into: [:]) { map, item in
            switch item {
            case .single(let message):
                map[message.id] = message.id
            case .album(let album):
                for photo in album.photos { map[photo.id] = album.id }
            }
        }

        #if DEBUG
        OpenStopwatch.prepared(from: startedAt, rows: items.count)
        #endif

        return ScrollViewReader { proxy in
            ScrollView {
                // Not lazy, and it has to stay that way.
                //
                // A lazy stack saved 32 ms on opening and broke what opening is for: it does
                // not know how tall it is until it has built everything, so anchoring to the
                // bottom put you somewhere above the messages and left the screen blank until
                // you scrolled. A conversation that opens fast on nothing is not fast.
                VStack(spacing: 0) {
                    if hasMore {
                        LoadMoreButton(isLoading: isLoadingHistory, action: loadHistory)
                    }

                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let message = item.anchor

                        // A day at a time, the way every messaging app since the first one
                        // has done it: "Today", "Yesterday", then the date. Without it a
                        // conversation is one endless column and 09:12 could be any morning.
                        if startsDay(at: index, in: items) {
                            // A plain capsule and not glass. Bare text over the backdrop
                            // lands on whatever the light happens to be doing, so it needs
                            // something under it — but glass inside a scrolling list is the
                            // expensive kind of pretty: every piece of it samples and blurs
                            // what is behind it, on every frame you scroll. This is one
                            // rounded rectangle.
                            Text(daySeparator(for: message.timestamp))
                                .chatmanFont(size: 12, weight: .medium, relativeTo: .caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .frame(height: 24)
                                .background(Color(.secondarySystemBackground).opacity(0.86), in: .capsule)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }

                        // Where you left off. Shown once, above the first message you
                        // hadn't seen, and gone the next time you open the conversation —
                        // which is exactly how long it's useful for.
                        if index == divider {
                            HStack(spacing: 8) {
                                Rectangle().fill(.blue.opacity(0.35)).frame(height: 1)

                                Text("New messages")
                                    .chatmanFont(size: 12, weight: .semibold, relativeTo: .caption2)
                                    .fixedSize()
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 12)
                                    .frame(height: 24)
                                    .background(
                                        Color(.secondarySystemBackground).opacity(0.86),
                                        in: .capsule
                                    )

                                Rectangle().fill(.blue.opacity(0.35)).frame(height: 1)
                            }
                            .padding(.vertical, 8)
                            .id(Self.dividerAnchor)
                        }

                        Group {
                            switch item {
                            case .single:
                                bubble(
                                    for: message,
                                    at: index,
                                    in: items,
                                    quotedBy: quotedBy,
                                    newest: newest,
                                    rowFor: rowFor,
                                    proxy: proxy
                                )

                            case .album(let album):
                                AlbumBubble(
                                    isReady: isReady,
                                    album: album,
                                    isMine: session.isMine(album.photos[0]),
                                    isInGroup: conversation.isGroup,
                                    showsSender: showsSender(at: index, in: items),
                                    onOpen: { viewing = $0 },
                                    onOpenAll: {
                                        overview = .init(photos: album.photos)
                                    },
                                    onReply: { replyTarget = album.photos[0] },
                                    onForward: { sheet = .forward(album.photos[0]) },
                                    onReact: { sheet = .reactions(album.photos[0]) }
                                )
                            }
                        }
                            .id(message.id)
                            .background {
                                if highlighted == message.id {
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(.blue.opacity(0.12))
                                        .padding(.horizontal, -6)
                                }
                            }
                    }

                    if let typing = session.typingSummary(in: conversation) {
                        TypingLine(text: typing)
                            .padding(.top, 4)
                            .id(typingAnchor)
                    }

                    // The end of the conversation, as a view — and the one thing every
                    // scroll aims at.
                    //
                    // It used to be a one-point sliver that only *watched*, while the
                    // scrolling aimed at the last message instead. Those are not the same
                    // place: below the last bubble sit its own padding and this marker, so
                    // parking the last bubble against the bottom of the screen left fifteen
                    // points of conversation under the composer — including the marker.
                    // Measured, on opening a chat: the scroll stopped at 1721 where the real
                    // bottom is 1736, the marker never came into view, and `isAtBottom`
                    // stayed false from that moment on. Everything that follows the
                    // conversation is gated on that flag, which is why a chat opened with
                    // the newest message tucked behind the field and why a message you sent
                    // slid away under it.
                    //
                    // Aiming at this instead makes the two agree by construction: scrolled
                    // to the end means this is on screen, and this on screen means scrolled
                    // to the end. Sixteen points rather than one, so a half-point of
                    // rounding can't tuck it away again — it replaces the padding that used
                    // to be here, so nothing grew.
                    Color.clear
                        .frame(height: 16)
                        .id(bottomAnchor)
                        .onScrollVisibilityChange(threshold: 0.1) { visible in
                            withAnimation(.snappy) { isAtBottom = visible }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            // Opens at the newest message rather than scrolling to it.
            //
            // There used to be two scrolls after the screen appeared, at 30 and 280
            // milliseconds. Two fixed moments, neither of which is when the content happens
            // to settle, so the conversation jumped into place twice in plain sight during
            // the animation that opens it. Following the content instead means one movement
            // that ends where it should, rather than two guesses at when it is over.
            .defaultScrollAnchor(.bottom)
            .onScrollPhaseChange { _, phase in
                let moving = phase != .idle
                if scrollFlag.moving != moving { scrollFlag.moving = moving }
            }
            // For the sky's depth. Written into a box it reads while drawing, so a scroll here
            // changes nothing that SwiftUI would have to work out again.
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                skyDepth.offset = offset
            }
            // The height of everything, which changes long after the messages arrive: a
            // photo lands, a bubble grows, and the bottom moves out from under you.
            //
            // The composer counts too. It sits in the bottom safe area, so when it grows —
            // an answer-banner appears, the field takes a second line, the keyboard comes
            // up — the conversation doesn't change height but the room it has does, and the
            // newest message ends up behind it. Watching only the content missed all three.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.bottom
            } action: { _, _ in
                guard isAtBottom || isSettling else { return }
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
            .onChange(of: messages.last?.id) { _, newValue in
                // Only when you were already there. Being yanked to the bottom because
                // somebody wrote something while you were reading is the rudest thing a
                // chat app does.
                guard isAtBottom, newValue != nil else { return }
                withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
            .task(id: conversation.id) {
                guard !hasOpened else { return }

                #if DEBUG
                OpenStopwatch.appeared("conversation")
                #endif

                isSettling = true

                // The rest of the window once the opening animation is over — not in the middle of
                // it, where forty more rows to build was the biggest stall in the app — and a
                // screenful at a time, so no single frame carries all of it.
                try? await Task.sleep(for: .milliseconds(380))
                while window < Self.settledWindow, !Task.isCancelled {
                    window = min(Self.settledWindow, window + 18)
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(16))
                }

                // Somewhere other than the end, when there is a reason to.
                //
                // A board opened from its lead goes to that message. A conversation with a
                // screenful and more of unread messages goes to where they begin, with the
                // divider at the top, so you read down instead of scrolling up to find your
                // place and then reading backwards. The window is widened to reach it first.
                if let focus = session.requestedFocus, focus.conversationID == conversation.id {
                    session.requestedFocus = nil
                    if let newer = session.messagesNewer(than: focus.messageID, in: conversation) {
                        window = max(window, min(newer + 5, 300))
                        try? await Task.sleep(for: .milliseconds(40))
                        // Both let go of the bottom first, or the next picture that lands
                        // pulls the list straight back down there.
                        isSettling = false
                        isAtBottom = false
                        jump(to: focus.messageID, using: proxy)
                    }
                } else if unreadAtOpen >= Self.opensAtFirstUnread, firstUnreadID != nil {
                    window = max(window, min(unreadAtOpen + 6, 300))
                    try? await Task.sleep(for: .milliseconds(40))
                    isSettling = false
                    isAtBottom = false
                    proxy.scrollTo(Self.dividerAnchor, anchor: .top)
                }

                isReady = true

                try? await Task.sleep(for: .milliseconds(480))
                isSettling = false
                hasOpened = true
            }
            .onChange(of: scrollRequests) { _, _ in
                Task {
                    // After the keyboard has finished coming up, not while it is on its way:
                    // scrolling to a position that is still moving lands short of it.
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !messages.isEmpty else { return }
                    withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                }
            }
            // Growing the window adds messages above what you're looking at, which would
            // otherwise shove the whole conversation down the screen.
            .onChange(of: window) { _, _ in
                guard let anchor = topBeforeWidening else { return }
                topBeforeWidening = nil
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    /// Solid in the middle, dimmed at the top and the bottom, fading between.
    ///
    /// Dimmed and not removed. Taking the words away entirely was the first attempt and it
    /// went too far: what runs under the name and the field should recede, the way it does in
    /// Messages, not vanish into the backdrop. You are meant to be able to see that the
    /// conversation carries on up there.
    ///
    /// Held at its faintest for the height of the status bar and the home indicator, so the
    /// clock and the line at the bottom sit on something steady, and brought back to full
    /// over the stretch below and above them.
    ///
    /// Built from fixed heights rather than fractions, so the bands are the same on every
    /// screen: a proportional fade eats a quarter of an iPhone SE and grazes the corner of a
    /// Pro Max.
    private var edgeFades: some View {
        VStack(spacing: 0) {
            // Nothing at the top: the bar's own edge effect does that job now, and does it
            // the way every other app on the phone does.
            Color.black

            LinearGradient(
                colors: [.black, .black.opacity(Self.faintest)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.bottomFade)
            Color.black.opacity(Self.faintest)
                .frame(height: max(0, composerHeight))
        }
        .ignoresSafeArea()
    }

    /// How much of a message is still there at the very top and bottom of the screen.
    ///
    /// A fifth. Enough to see that something is written there, not enough to start reading it
    /// and find the name in the way.
    private static let faintest = 0.20

    private static let bottomFade: CGFloat = 92

    /// Where the messages you hadn't read begin, if any.
    private func firstUnreadIndex(in items: [PhotoAlbum.Item]) -> Int? {
        guard let first = firstUnreadID else { return nil }

        // Drawn in entries, and an album is several messages drawn as one — so the divider
        // is looked up, whole message first and then inside the albums.
        return items.firstIndex { $0.anchor.id == first }
            ?? items.firstIndex { item in
                if case .album(let album) = item {
                    return album.photos.contains { $0.id == first }
                }
                return false
            }
    }

    /// Scrolls to a message and flashes it.
    ///
    /// The flash is the point: jumping somewhere without it leaves you looking at a wall of
    /// text wondering which line you were sent to.
    private func jump(to id: String, using proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(id, anchor: .center) }
        highlighted = id

        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation { highlighted = nil }
        }
    }

    /// Whether this message opens a new day.
    private func startsDay(at index: Int, in items: [PhotoAlbum.Item]) -> Bool {
        guard index > 0 else { return true }

        return !Calendar.current.isDate(
            items[index].anchor.timestamp, inSameDayAs: items[index - 1].anchor.timestamp
        )
    }

    /// Whether an album should be introduced by the name of whoever sent it.
    private func showsSender(at index: Int, in items: [PhotoAlbum.Item]) -> Bool {
        guard conversation.isGroup else { return false }
        let message = items[index].anchor
        guard !session.isMine(message) else { return false }
        guard index > 0 else { return true }
        return items[index - 1].anchor.sender != message.sender
    }

    /// "Today", "Yesterday", or the date — whichever says the most in the fewest words.
    private func daySeparator(for date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }

        // Within the week, the day is more use than the date: "Thursday" places a
        // conversation instantly, "14/09" needs working out.
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }

        return date.formatted(.dateTime.day().month(.wide).year())
    }

    /// One message, with everything it needs to know about its neighbours.
    private func bubble(
        for message: Message,
        at index: Int,
        in items: [PhotoAlbum.Item],
        quotedBy: [String: Message],
        newest: String?,
        rowFor: [String: String],
        proxy: ScrollViewProxy
    ) -> some View {
        MessageBubble(
            message: message,
            isMine: session.isMine(message),
            isReady: isReady,
            previous: index > 0 ? items[index - 1].anchor : nil,
            next: index + 1 < items.count ? items[index + 1].anchor : nil,
            isInGroup: conversation.isGroup,
            quoted: message.replyToID.flatMap { quotedBy[$0] },
            showsStatus: message.id == newest,
            onReply: { replyTarget = message },
            onReact: { emoji in Task { await session.react(with: emoji, to: message) } },
            onOpenMedia: { viewing = $0 },
            onForward: { sheet = .forward(message) },
            onOpenFile: { openFile(message) },
            onEdit: session.canEdit(message) ? { beginEditing(message) } : nil,
            onDelete: session.isMine(message) && !message.isPending
                ? {
                    Task {
                        do {
                            try await session.delete(message, forEveryone: true)
                        } catch {
                            deleteFailure = error.localizedDescription
                        }
                    }
                }
                : nil,
            onOpenQuoted: { quoted in
                jump(to: rowFor[quoted.id] ?? quoted.id, using: proxy)
            },
            onMoreReactions: { sheet = .reactions(message) }
        )
    }

    /// Downloads an attachment and hands it to Quick Look.
    ///
    /// Quick Look is what opens a PDF everywhere else on the phone — it reads Pages files,
    /// spreadsheets, zip archives and a dozen other things, it has a share button, and it
    /// costs one line. What it needs is a file on disk, which is the only work here.
    private func openFile(_ message: Message) {
        guard !isFetchingFile, let address = message.mediaURL else { return }
        isFetchingFile = true

        Task {
            defer { isFetchingFile = false }

            guard let request = session.fullSizeRequest(for: message),
                  let file = await AnimatedMedia.file(
                      for: request,
                      key: address + "-file",
                      mimeType: message.mediaMimeType,
                      // A cap on what is worth keeping on the phone. It goes straight to
                      // disk now, so this is no longer about memory — only about not filling
                      // the phone with something too large to open here anyway.
                      limit: 60_000_000
                  )
            else {
                sendFailure = "That file couldn't be downloaded. It may be too large to open here."
                return
            }

            // Named after what it is, not after its address: Quick Look decides what to show
            // from the extension, and the share sheet puts this name on the file.
            //
            // In a folder of its own per attachment. The named copies all used to go into one
            // shared folder, written only when nothing of that name was there yet — so open
            // "document.pdf" from one message, then a different "document.pdf" from another,
            // and Quick Look showed the first. Its share button then sent the wrong document.
            let folder = file.deletingLastPathComponent()
                .appendingPathComponent("named", isDirectory: true)
                .appendingPathComponent(Self.safeName(address), isDirectory: true)
            let named = folder.appendingPathComponent(
                message.body.isEmpty ? file.lastPathComponent : Self.safeName(message.body)
            )

            if !FileManager.default.fileExists(atPath: named.path) {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: file, to: named)
            }

            previewing = FileManager.default.fileExists(atPath: named.path) ? named : file
        }
    }

    /// A name that can stand as one piece of a path: no slashes to open folders that aren't
    /// there, no colons from an `mxc://` address.
    private static func safeName(_ name: String) -> String {
        String(name.map { $0 == "/" || $0 == ":" ? "_" : $0 })
    }

    /// Sends what the camera produced, whichever of the two it was.
    private func sendCapture(_ capture: CameraPicker.Capture) {
        switch capture {
        case .photo(let image): sendCapturedPhoto(image)
        case .video(let url): sendCapturedVideo(url)
        }
    }

    /// Sends a picture straight from the camera.
    ///
    /// Encoded here rather than handed over as it came: what the camera gives back is an
    /// uncompressed frame, and nobody wants to wait for twelve megabytes over cellular to
    /// send a photo of a parking space. How hard it's squeezed is a setting, because the
    /// right answer depends on the connection you're on. See ``PhotoQuality``.
    private func sendCapturedPhoto(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: session.photoQuality.compression) else {
            sendFailure = "That picture couldn't be read."
            return
        }
        // Like a photo from the library: above the field first, sent when you say so.
        withAnimation(.snappy) {
            pendingPhotos.append(PastedPhoto(data: data, type: .jpeg, preview: image))
        }
    }

    /// Sends a film straight from the camera.
    ///
    /// As it was recorded. The camera already compresses what it captures, and squeezing it
    /// again here would cost minutes of the phone's time to make it worse.
    private func sendCapturedVideo(_ url: URL) {
        // The reply goes with it and the banner goes away, as it does for a photo. Neither
        // happened here: the film went out as a plain message, the "Replying to" banner
        // stayed, and the next thing you typed went out as the reply instead.
        let target = replyTarget
        replyTarget = nil

        Task {
            do {
                try await session.sendAttachment(
                    .file(url),
                    filename: url.lastPathComponent,
                    mimeType: "video/quicktime",
                    kind: .video,
                    to: conversation,
                    replyingTo: target
                )
            } catch {
                sendFailure = error.localizedDescription
            }
        }
    }

    /// Sends anything the Files app can hand over.
    private func sendFile(_ url: URL) {
        // As for a film from the camera: the reply travels with it.
        let target = replyTarget
        replyTarget = nil

        Task {
            // A file from iCloud Drive or another app is handed over under guard: without
            // asking, reading it is refused and the send fails for no visible reason.
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }

            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard let bytes else {
                sendFailure = "That file couldn't be read."
                return
            }

            guard bytes <= 100_000_000 else {
                sendFailure = "That file is too large to send."
                return
            }

            let type = UTType(filenameExtension: url.pathExtension)
            let mime = type?.preferredMIMEType ?? "application/octet-stream"

            do {
                try await session.sendAttachment(
                    .file(url),
                    filename: url.lastPathComponent,
                    mimeType: mime,
                    kind: type?.conforms(to: .movie) == true ? .video : .file,
                    to: conversation,
                    replyingTo: target
                )
            } catch {
                sendFailure = error.localizedDescription
            }
        }
    }

    private func loadHistory() {
        // What's already on the device first, and instantly: widening the window costs
        // nothing and covers the common case of scrolling back through this morning.
        guard stored.count <= window else {
            topBeforeWidening = messages.first?.id
            window += 60
            return
        }

        guard !isLoadingHistory else { return }
        isLoadingHistory = true

        Task {
            await session.loadOlderMessages(in: conversation)
            topBeforeWidening = messages.first?.id
            window += 60
            isLoadingHistory = false
        }
    }
}

private struct LoadMoreButton: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                Button("Load earlier messages", action: action)
                    .font(.footnote)
            }
        }
        .padding(.vertical, 8)
    }
}

/// A single message.
private struct MessageBubble: View {
    let message: Message
    let isMine: Bool

    /// Whether the screen has finished arriving; see `chatmanMenu`.
    let isReady: Bool
    /// The message above this one, for deciding whether the sender needs introducing again.
    var previous: Message? = nil
    /// The message below it, for deciding where the face goes.
    var next: Message? = nil
    /// Groups show who is speaking; a private chat never needs to.
    var isInGroup: Bool = false
    /// The message this one answers, when it's still loaded.
    var quoted: Message? = nil
    /// Whether this is the message that reports how far it got.
    var showsStatus: Bool = false
    let onReply: () -> Void
    let onReact: (String) -> Void
    /// Called when a picture in this bubble is tapped.
    var onOpenMedia: ((Message) -> Void)? = nil
    /// Called to pass this message on to another conversation.
    var onForward: (() -> Void)? = nil
    /// Called when a file in this bubble is tapped.
    var onOpenFile: (() -> Void)? = nil
    /// Present only on messages that can still be changed.
    var onEdit: (() -> Void)? = nil
    /// Present only on your own messages, which are the only ones you can take back.
    var onDelete: (() -> Void)? = nil
    /// Called when the quoted message above this one is tapped.
    var onOpenQuoted: ((Message) -> Void)? = nil
    /// Called to open the full list of emoji.
    var onMoreReactions: (() -> Void)? = nil

    /// How far the bubble has been dragged towards a reply.
    @State private var dragged: CGFloat = 0

    /// Whether this drag has gone far enough to answer, so the tap you feel comes once.
    @State private var dragWillReply = false

    /// How wide the picture turned out, so the caption under it can match.
    @State private var mediaWidth: CGFloat?

    @Environment(ChatSession.self) private var session

    /// A message that is nothing but emoji, drawn large and bare.
    private var isLargeEmoji: Bool {
        message.kind == .text && EmojiOnly.matches(message.body)
    }

    /// Pictures, stickers and emoji stand on their own; only words get a bubble.
    private var wearsBubble: Bool {
        !isLargeEmoji && message.kind != .image && message.kind != .video && message.kind != .sticker
    }

    /// Whether to name the sender above this message.
    ///
    /// Only on the first message of a run, and only in a group: repeating the same name down
    /// a whole back-and-forth adds nothing and costs the width the messages need.
    private var showsSenderDetails: Bool {
        isInGroup && !isMine && previous?.sender != message.sender
    }

    /// Whether the face goes beside this one.
    ///
    /// On the last message of a run, not the first — which is where Messages puts it, and it
    /// is the better of the two: the picture sits level with the end of what somebody said,
    /// so your eye finishes reading and lands on who said it.
    private var showsAvatar: Bool {
        isInGroup && !isMine && next?.sender != message.sender
    }

    /// Whether this is the last of what one person said in a row.
    private var endsRun: Bool {
        guard let next else { return true }
        return next.sender != message.sender
    }

    /// Whether this message is the one that carries the time.
    ///
    /// Only the last of a burst. Four messages typed inside a minute are one thought, and
    /// four clocks under them says four times what one says — so the time waits for the end
    /// of the run. It chains by itself: every message with another one close behind it stays
    /// quiet, so a message a minute keeps only the newest stamp.
    private var showsTime: Bool {
        guard let next else { return true }
        return next.timestamp.timeIntervalSince(message.timestamp) >= 60
    }

    /// The width the avatar column takes, including the gap after it.
    private var avatarLane: CGFloat { isInGroup && !isMine ? 32 : 0 }

    var body: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: 48) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine, showsSenderDetails, let name = session.senderName(of: message) {
                    // Bigger than a caption and in this person's own colour, the way WhatsApp
                    // and Telegram do it. In a group of eight you stop reading names within a
                    // day and go by the colour — which only works if it never changes, so it
                    // comes from the account rather than from who spoke first.
                    Text(name)
                        .chatmanFont(size: 15, weight: .semibold)
                        .foregroundStyle(SenderColour.of(message.sender))
                        .padding(.leading, avatarLane + 2)
                        .padding(.top, 2)
                }

                HStack(alignment: .bottom, spacing: 6) {
                    if !isMine, isInGroup {
                        if showsAvatar {
                            SenderAvatar(message: message)
                        } else {
                            Color.clear.frame(width: 26, height: 1)
                        }
                    }

                    VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                        if let quoted {
                            Button {
                                onOpenQuoted?(quoted)
                            } label: {
                                QuotedMessage(message: quoted, isMine: isMine)
                            }
                            .buttonStyle(.plain)
                        }

                        captioned
                            .padding(.horizontal, wearsBubble ? 12 : 0)
                            .padding(.vertical, wearsBubble ? 8 : 0)
                            .background {
                                if wearsBubble {
                                    // A tail only on the last of a run, as in Messages: a run
                                    // reads as one voice, and the tail says where it ends.
                                    BubbleShape(tail: endsRun ? (isMine ? .trailing : .leading) : nil)
                                        .fill(bubbleFill)
                                }
                            }
                            .foregroundStyle(.primary)
                            .opacity(message.isPending ? 0.6 : 1)
                            // On the bubble, over its top corner, the way Messages does it.
                            // A reaction is about the message; underneath it as a line of its
                            // own it read as somebody sending you a single character.
                            .overlay(alignment: isMine ? .topLeading : .topTrailing) {
                                if !message.reactions.isEmpty {
                                    Tapbacks(reactions: message.reactions)
                                        .offset(x: isMine ? -16 : 16, y: -16)
                                }
                            }
                            .padding(.top, message.reactions.isEmpty ? 0 : 16)
                    }
                }

                footer
                    .padding(.leading, avatarLane)

                // Under the newest message you sent, and nowhere else. The failure case is
                // already spelled out in the footer, so it isn't repeated here.
                if showsStatus, !message.didFailToSend {
                    Text(session.sendStatus(of: message).label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !isMine { Spacer(minLength: 48) }
        }
        // Messages sent within a minute of each other belong together, and sit closer for
        // it — theirs as well as yours. It's the same rule that decides which of them shows
        // a time, so the two always agree.
        .padding(.bottom, showsTime ? 8 : 2)
        // Swipe a message to answer it — the gesture WhatsApp, Telegram and Signal all use,
        // and the one people try first. The bubble goes with your finger, because a gesture
        // you can't see happening is a gesture you don't trust: it moves, it resists as it
        // goes, and it springs back if you let go too early.
        .offset(x: dragged)
        .overlay(alignment: .leading) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .opacity(min(1, dragged / 44))
                .offset(x: dragged - 30)
        }
        // A UIKit recogniser that only starts for a drag to the right.
        //
        // Two SwiftUI versions came before this and both got in the way of something. As an
        // ordinary gesture it had to win the touch from the scroll view, and on a real phone —
        // where a thumb sets off a little upwards as often as not — the scroll view usually
        // won, so the bubble never moved. Run alongside the scroll view instead, it saw every
        // drag, scrolling included, and scrolling started to feel sticky: each bubble under the
        // thumb was weighing up whether this was a reply.
        //
        // UIKit can ask the question before anything starts. A drag that sets off mostly
        // sideways and to the right is a reply, and only that one begins; everything else is
        // left to the scroll view untouched, the way Mail's swipes sit in its list.
        .gesture(
            ReplySwipe(
                onChange: { across in
                    // Square-rooted, so it slows down the further you pull. Past sixty points
                    // it barely moves, which is how you feel where the end is.
                    dragged = min(64, sqrt(across) * 7)

                    // And a tap at the point where letting go will answer, so you know
                    // before you let go rather than after.
                    let far = dragged > 40
                    if far != dragWillReply {
                        dragWillReply = far
                        if far { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    }
                },
                onEnd: {
                    let far = dragged > 40
                    dragWillReply = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragged = 0 }
                    if far { onReply() }
                }
            )
        )
        .chatmanMenu(isReady) {
            // The reactions first, as one row across the top — where Messages keeps them.
            Picker("React", selection: Binding<String?>(
                get: { nil },
                set: { emoji in if let emoji { onReact(emoji) } }
            )) {
                ForEach(QuickReactions.row(), id: \.self) { emoji in
                    Text(emoji).tag(Optional(emoji))
                }
            }
            .pickerStyle(.palette)

            Button("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)

            if let onForward {
                Button("Forward", systemImage: "arrowshape.turn.up.right", action: onForward)
            }

            if let onEdit {
                Button("Edit", systemImage: "pencil", action: onEdit)
            }

            if message.kind == .text, !message.body.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = message.body
                }
            }

            if let onMoreReactions {
                Button("More emoji…", systemImage: "face.smiling", action: onMoreReactions)
            }

            if let onDelete {
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
        } preview: {
            // Lifted onto a plate of its own. Left to itself the preview is the bubble and
            // nothing more, and a bubble's fill is translucent on purpose — over the blurred
            // conversation the system puts behind it, one message's words landed on top of
            // another's and neither could be read. So: glass, over something solid enough to
            // read on, still carrying the colour this message wears in the list.
            content
                // The preview is drawn outside this screen's views, and doesn't inherit what
                // they carry. A photo asks the session for its picture, and without it here
                // holding one down to react crashed the app.
                .environment(session)
                .foregroundStyle(.primary)
                .frame(
                    idealWidth: 260,
                    maxWidth: 260,
                    alignment: isMine ? .trailing : .leading
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background {
                    ZStack {
                        Color(.systemBackground).opacity(0.75)
                        Rectangle().fill(bubbleFill)
                    }
                }
                .chatmanGlass(in: .rect(cornerRadius: 24, style: .continuous))
        }
    }

    /// The message, with any addresses in it turned into links.
    ///
    /// Only when there's something to find: running the detector over every line while
    /// scrolling costs more than it's worth.
    private var styledText: AttributedString {
        LinkedText.containsLink(message.body)
            ? LinkedText.attributed(message.body)
            : AttributedString(message.body)
    }

    /// The message with "edited" after it, as one piece of text.
    ///
    /// Built as an attributed string rather than by adding two `Text`s together: that
    /// operator is on its way out, and this keeps the smaller, quieter styling it had.
    private var edited: AttributedString {
        var whole = styledText

        var suffix = AttributedString("  edited")
        suffix.font = .caption2
        suffix.foregroundColor = .secondary
        whole.append(suffix)

        return whole
    }

    /// Whether there are words under this picture.
    private var hasCaption: Bool {
        !wearsBubble && !(message.caption ?? "").isEmpty
    }

    /// What somebody typed under the picture, joined onto the bottom of it.
    ///
    /// Two shapes rather than one: the picture keeps its own edges and the words get a
    /// bubble that starts exactly where the picture stops, the same width and not a point
    /// wider. A box drawn round both of them made the picture look like it had been pasted
    /// into a message; this way the caption reads as a label on the thing above it.
    ///
    /// The width has to be measured, because a photo is as wide as its own shape: a portrait
    /// one is narrower than the cap, and a caption stretched past its edges is the exact
    /// thing being fixed here.
    @ViewBuilder
    private var captioned: some View {
        if hasCaption {
            VStack(alignment: .leading, spacing: 0) {
                content
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        mediaWidth = width
                    }

                Text(message.caption ?? "")
                    .chatmanFont(size: 17)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(width: mediaWidth, alignment: .leading)
                    .background(bubbleFill)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 12,
                            bottomTrailingRadius: 12,
                            topTrailingRadius: 0
                        )
                    )
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .image, .video:
            Button {
                onOpenMedia?(message)
            } label: {
                AttachmentThumbnail(message: message, squaresBottom: hasCaption)
            }
            .buttonStyle(.plain)

        case .sticker:
            // No button and no viewer: a sticker is a word said with a picture, and it is
            // already as big as it is meant to be.
            AttachmentThumbnail(message: message)

        case .poll:
            PollCard(message: message)

        case .encrypted:
            Label("Encrypted message", systemImage: "lock")
                .font(.footnote)

        case .audio, .file:
            // Tappable, because a PDF somebody sent you is a PDF you want to read. Quick Look
            // opens it in the app, the same way Mail does.
            Button {
                onOpenFile?()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: message.kind == .audio ? "waveform" : "doc")
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(message.body)
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(message.kind == .audio ? "Voice message" : "Tap to open")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

        case .text, .emote, .notice:
            VStack(alignment: .leading, spacing: 8) {
                // "Edited" belongs with the message, not in a tooltip: without it a changed
                // message quietly rewrites what someone remembers reading.
                Group {
                    if message.wasEdited {
                        Text(edited)
                    } else {
                        Text(styledText)
                    }
                }
                // One font modifier, not two.
                //
                // `.font()` sets an environment value for what it wraps, so of two the one
                // nearest the text wins — and the one nearest here was `.font(nil)`, which
                // does not mean "leave it alone" but "use the default". The chosen typeface
                // was being set and then explicitly thrown away, on every message in the app.
                .chatmanFont(size: isLargeEmoji ? 48 : 17)
                .textSelection(.enabled)
                // Take the height the words need, and never less.
                //
                // Without it a long message under a quoted one came out cut short with an
                // ellipsis: the two sit in the same stack, and when the stack is offered a
                // height it hands what is left to the most flexible thing in it — the text.
                // The message beside it with nothing quoted above it kept all four of its
                // lines, which is what gave the game away. Nothing here is ever meant to be
                // shortened: a message is as tall as it is.
                .fixedSize(horizontal: false, vertical: true)

                // A location, from Chatman or from anything else that sent one. Opening it
                // shouldn't mean reading coordinates off a screen and typing them into Maps.
                if let place = SharedLocation.inside(message.body) {
                    MapLink(place: place)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 6) {
            if message.didFailToSend {
                // Anything with its bytes still on this phone, or already on the server, can
                // be sent again — as the same message, so the server takes it once however
                // often it's tried. Only what has neither says so plainly instead.
                Group {
                    if session.canRetry(message) {
                        Button {
                            Task { await session.retry(message) }
                        } label: {
                            Label("Not sent · tap to retry", systemImage: "exclamationmark.circle")
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label("Not sent", systemImage: "exclamationmark.circle")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.red)
            } else if let problem = message.deliveryProblem, isMine {
                // On your server, but not on WhatsApp: the bridge said so, in its own words.
                // A message that looks sent and never arrives is the worst thing a messenger
                // can do, so this is said where the message is.
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if !showsStatus, showsTime {
                // One time per message and no more — and not even that for a message with
                // another one right behind it. The status line under the newest one you sent
                // already carries a time when there is one to carry, "Read 10:04", and two
                // clocks under the same sentence is one too many.
                Text(message.timestamp, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What a bubble is filled with.
    ///
    /// Yours takes the colour of the service the conversation lives on, at a fraction of its
    /// strength: enough that a Signal chat and a WhatsApp chat don't look identical when you
    /// glance at your own words, nowhere near enough to fight with the text on top of it.
    /// What a bubble is filled with.
    ///
    /// Nearly solid rather than the quarter-strength fill this used to be. Over a plain screen
    /// a see-through bubble looks light on its feet; over the backdrop the filaments run
    /// straight through the words, and a sentence you have to pick out of a moving picture is
    /// a sentence you read twice.
    ///
    /// Both sides sit on the same ground and differ only in tint, so neither hides less than
    /// the other. Mixed rather than laid over: one colour is one layer, and one layer is what
    /// the shapes that use this can take.
    private var bubbleFill: AnyShapeStyle {
        let ground = Color(.secondarySystemBackground)
        guard isMine else { return AnyShapeStyle(ground.opacity(0.92)) }

        let brand = (message.conversation?.network ?? .matrix).brandColour
        let colour = Color(red: brand.red, green: brand.green, blue: brand.blue)

        return AnyShapeStyle(ground.mix(with: colour, by: 0.30).opacity(0.92))
    }
}

/// Swiping a message to the right, and only that.
///
/// See the bubble for why this is UIKit: the one thing SwiftUI can't do is decline a drag
/// before it starts, and that is exactly what keeps it out of the way of scrolling.
private struct ReplySwipe: UIGestureRecognizerRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed:
            onChange(max(0, pan.translation(in: pan.view).x))
        case .ended, .cancelled, .failed:
            onEnd()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Only a drag that sets off to the right, clearly more sideways than up or down —
        /// and not one that starts at the left edge, which is going back.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else {
                return false
            }
            // The edge belongs to the system's swipe back, always, as in Messages. Without
            // this a reply and going back both started on the same drag, and which one won
            // came down to timing.
            if let window = view.window {
                let start = pan.location(in: window).x - pan.translation(in: window).x
                if start < 30 { return false }
            }
            let moved = pan.translation(in: view)
            let speed = pan.velocity(in: view)
            let across = moved.x + speed.x * 0.05
            let upDown = abs(moved.y) + abs(speed.y) * 0.05
            return across > 0 && across > upDown * 1.5
        }

        /// Side by side with scrolling only: a reply that drifts a little up or down
        /// shouldn't freeze the conversation under it. Never alongside going back — the two
        /// used to run together, which is what made swiping back unreliable.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other.view is UIScrollView
        }

        /// Swiping back from the middle of the screen waits for this to decide. On a bubble,
        /// a drag to the right is a reply — as in Messages — and going back takes over only
        /// when it isn't. The edge never waits: that one is refused in `shouldBegin` above.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer
                && !(other is UIScreenEdgePanGestureRecognizer)
                && !(other.view is UIScrollView)
        }
    }
}

/// Several pictures sent at once, drawn as one thing.
///
/// A grid of four at most, with a count over the last tile when there are more — the shape
/// WhatsApp uses, and the reason is the same: seven pictures down a column is a wall you have
/// to scroll past, while four in a square is a glance. Everything else about it behaves like
/// any other message: it can be answered, passed on and reacted to.
private struct AlbumBubble: View {
    /// Whether the screen has finished arriving; see `chatmanMenu`.
    let isReady: Bool

    @Environment(ChatSession.self) private var session

    let album: PhotoAlbum.Album
    let isMine: Bool
    let isInGroup: Bool
    let showsSender: Bool
    let onOpen: (Message) -> Void

    /// Asked for by the tile that says how many more there are.
    let onOpenAll: () -> Void

    let onReply: () -> Void
    let onForward: () -> Void
    let onReact: () -> Void

    /// Two across, and no more than four. The fourth carries the count of what is behind it.
    private var tiles: [Message] { Array(album.photos.prefix(4)) }
    private var hidden: Int { album.photos.count - tiles.count }

    private let side: CGFloat = 107

    /// The width the avatar column takes beside a message in a group. An album has to leave
    /// the same gap, or it sits further left than everything around it.
    private var avatarLane: CGFloat { isInGroup && !isMine ? 32 : 0 }

    var body: some View {
        HStack(spacing: 0) {
            if isMine { Spacer(minLength: 48) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if showsSender, let name = session.senderName(of: album.photos[0]) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SenderColour.of(album.photos[0].sender))
                        .padding(.leading, 2)
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 0) {
                    grid


                    if let caption = album.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(width: side * 2 + 2, alignment: .leading)
                            .background(.quaternary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                // Over the top corner and mostly outside it, as in Messages: on the photo's
                // bottom corner it sat on the last picture and covered part of it.
                .overlay(alignment: isMine ? .topLeading : .topTrailing) {
                    if !album.reactions.isEmpty {
                        Tapbacks(reactions: album.reactions)
                            .offset(x: isMine ? -16 : 16, y: -16)
                    }
                }
                .padding(.top, album.reactions.isEmpty ? 0 : 16)

                Text(album.photos[0].timestamp, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, avatarLane)
            .chatmanMenu(isReady) {
                Button("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
                Button("Forward", systemImage: "arrowshape.turn.up.right", action: onForward)
                Button("React", systemImage: "face.smiling", action: onReact)
            }

            if !isMine { Spacer(minLength: 48) }
        }
        .padding(.bottom, 8)
    }

    private var grid: some View {
        LazyVGrid(
            columns: [
                GridItem(.fixed(side), spacing: 2),
                GridItem(.fixed(side), spacing: 2)
            ],
            spacing: 2
        ) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, photo in
                Button {
                    // The last tile of a shortened album opens the album, not the picture
                    // underneath the number — that number is a door, not a photo.
                    if hidden > 0, index == tiles.count - 1 {
                        onOpenAll()
                    } else {
                        onOpen(photo)
                    }
                } label: {
                    AttachmentThumbnail(message: photo, tile: side)
                        .overlay {
                            // On the last one, and only when there is more behind it.
                            if hidden > 0, index == tiles.count - 1 {
                                ZStack {
                                    // A material, not a tint: whatever is underneath — a
                                    // picture, or the stand-in's own icon — is blurred out
                                    // of the way instead of showing through the number.
                                    Rectangle().fill(.ultraThinMaterial)
                                    Color.black.opacity(0.3)
                                    Text("+\(hidden)")
                                        .font(.title2.weight(.semibold))
                                        .foregroundStyle(.white)
                                }
                                // The same corners as the picture under it.
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: side * 2 + 2)
    }
}

/// The face beside a message in a group.
private struct SenderAvatar: View {
    @Environment(ChatSession.self) private var session

    let message: Message

    private var initials: String {
        let words = (session.senderName(of: message) ?? "").split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        RemoteImage(
            request: session.avatarRequest(for: session.senderAvatarURL(of: message), size: 80),
            cacheKey: session.senderAvatarURL(of: message)
        ) {
            Circle()
                .fill(Monogram.gradient(for: session.senderName(of: message) ?? ""))
                .overlay {
                    Text(initials)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
        }
        .frame(width: 26, height: 26)
        .clipShape(Circle())
    }
}

/// The message being answered, drawn above the reply.
///
/// Without this a reply is indistinguishable from any other message: the app knows what it
/// answers, but nothing on screen says so.
private struct QuotedMessage: View {
    @Environment(ChatSession.self) private var session

    let message: Message
    let isMine: Bool

    private var who: String {
        session.isMine(message) ? "You" : session.senderName(of: message) ?? "Message"
    }

    /// The colour of whoever is being quoted, which is also the colour of their name in a
    /// group — so the bar down the side of a quote says who said it before you read a word.
    private var accent: Color {
        session.isMine(message) ? .accentColor : SenderColour.of(message.sender)
    }

    /// One line, whatever the message was.
    private var summary: String {
        switch message.kind {
        case .image: message.caption ?? "Photo"
        case .video: message.isAnimated ? "GIF" : (message.caption ?? "Video")
        case .audio: message.isVoice ? "Voice message" : message.body
        case .sticker: "Sticker"
        case .poll: "📊 " + message.body
        case .file: message.body
        default: message.body
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // A solid bar in the sender's colour, the full height of the quote. This is what
            // every other app draws, and the reason is that it reads as "quoted" from the
            // corner of your eye without being a box inside a box.
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(who)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)

                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 230, alignment: .leading)
        .padding(.leading, 6)
        .padding(.vertical, 4)
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(accent.opacity(0.10))
        }
    }
}

/// A poll, with how everybody voted so far.
///
/// Tap an answer to vote, tap it again to take the vote back. The vote goes to the bridge as
/// a vote, so it arrives in WhatsApp as a tick in the poll rather than as a message.
private struct PollCard: View {
    @Environment(ChatSession.self) private var session

    let message: Message

    var body: some View {
        let state = message.poll
        let tally = state?.tally ?? [:]
        let voters = max(state?.voters ?? 0, 1)
        let chosen = session.myVote(in: message)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.secondary)
                Text(message.body)
                    .chatmanFont(size: 17, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(state?.answers ?? [], id: \.id) { answer in
                let count = tally[answer.id] ?? 0
                let picked = chosen.contains(answer.id)

                Button {
                    Task { await session.vote(for: answer.id, in: message) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(picked ? Color.accentColor : .secondary)
                        Text(answer.text)
                            .chatmanFont(size: 16)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        if count > 0 {
                            Text(count.formatted())
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(alignment: .leading) {
                        // How far this answer got, as a bar behind it.
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.accentColor.opacity(0.16))
                                .frame(width: proxy.size.width * CGFloat(count) / CGFloat(voters))
                        }
                    }
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(state?.isClosed == true)
            }

            Text(pollFooter(state))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 220, maxWidth: 280, alignment: .leading)
    }

    private func pollFooter(_ state: PollState?) -> String {
        let count = state?.voters ?? 0
        let votes = count == 1 ? "1 vote" : "\(count) votes"
        if state?.isClosed == true { return votes + " · Closed" }
        if (state?.maxSelections ?? 1) > 1 { return votes + " · Pick up to \(state?.maxSelections ?? 1)" }
        return votes
    }
}

/// An image, a film, or a GIF, shown at a size worth downloading.
///
/// What gets drawn depends on what was sent, and the app works that out rather than asking:
/// a photo is a photo, a film gets a play button, and a GIF plays by itself. A GIF that has
/// to be started by hand isn't a GIF, which is the entire reason this isn't one view with a
/// play triangle on top.
private struct AttachmentThumbnail: View {
    @Environment(ChatSession.self) private var session
    let message: Message

    /// Whether something is going to sit directly underneath this.
    ///
    /// A caption joins onto the bottom edge, and a rounded corner there would leave two
    /// notches of page showing through between the picture and the words.
    var squaresBottom = false

    /// When set, the picture fills a square of this size instead of keeping its own shape.
    /// That is what an album is: a grid of equal tiles, not a column of different ones.
    var tile: CGFloat?

    @State private var loaded: AttachmentLoader.Result?
    @State private var failed = false

    /// Counts tries, so "Try again" can start the loading task over.
    @State private var attempt = 0

    /// Whether this GIF has been tapped to play.
    @State private var isPlayingGIF = false

    /// A cap rather than the real dimensions: attachments arrive at whatever size the sender's
    /// camera produced, and asking the server to scale is far cheaper than fetching it.
    ///
    /// Smaller for a sticker, which is meant to sit in a conversation like a large emoji
    /// rather than like a photo.
    private var maximumWidth: CGFloat { isSticker ? 140 : 220 }

    private var isSticker: Bool { message.kind == .sticker }

    var body: some View {
        Group {
            if let loaded, isSticker {
                // Fitted, never cropped, and never clipped to a rounded box: a sticker's own
                // outline is the point of it, transparent corners and all.
                Image(uiImage: loaded.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maximumWidth, maxHeight: maximumWidth)
            } else if let loaded, message.isAnimated {
                // A GIF holds still until it is tapped, then plays where it is; tapping it
                // again opens it full size. Playing every GIF in a conversation at once is a
                // lot of moving pictures and a lot of work for the phone.
                AnimatedPicture(image: loaded.image, isPlaying: isPlayingGIF)
                    .frame(width: tile ?? maximumWidth, height: tile ?? shownHeight(of: loaded.image))
                    .clipShape(shape)
                    .overlay {
                        if !isPlayingGIF {
                            Color.clear
                                .contentShape(shape)
                                .onTapGesture { isPlayingGIF = true }
                                .overlay {
                                    Image(systemName: "play.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                        .frame(width: 48, height: 48)
                                        .background(.black.opacity(0.4), in: Circle())
                                        .allowsHitTesting(false)
                                }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel("Play GIF")
                        }
                    }
                    .overlay(alignment: .bottomLeading) { gifBadge }
            } else if let loaded {
                Image(uiImage: loaded.image)
                    .resizable()
                    .scaledToFill()
                    // The same cap as the grey stand-in it replaces. Without one here, a tall
                    // screenshot or an upright film grew by up to half its height the moment
                    // it arrived, and reading back through history everything above jumped.
                    .frame(width: tile ?? maximumWidth, height: tile ?? shownHeight(of: loaded.image))
                    .clipped()
                    .clipShape(shape)
                    .overlay { if loaded.isPlayable { play } }
                    .overlay(alignment: .bottomLeading) { if message.isAnimated { gifBadge } }
            } else if failed {
                unavailable
            } else {
                shape
                    .fill(.quaternary)
                    .frame(width: tile ?? maximumWidth, height: tile ?? placeholderHeight)
                    .overlay { ProgressView() }
            }
        }
        // Again when the message gets its address. A picture you are sending has none until
        // the upload is done, and asked only once, before that, it had nothing to fetch.
        .task(id: "\(message.mediaURL ?? "")#\(message.didFailToSend)#\(attempt)") { await load() }
    }

    /// The outline of the picture: rounded all round on its own, flat along the bottom when
    /// a caption is joining on.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 12,
            bottomLeadingRadius: squaresBottom ? 0 : 12,
            bottomTrailingRadius: squaresBottom ? 0 : 12,
            topTrailingRadius: 12
        )
    }

    private var play: some View {
        Image(systemName: "play.fill")
            .font(.title2)
            .foregroundStyle(.white)
            .padding(14)
            .background(.black.opacity(0.45), in: Circle())
    }

    /// Said out loud, because a GIF that has already played once looks like a photo until it
    /// comes round again.
    private var gifBadge: some View {
        Text("GIF")
            .font(.caption2.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
    }

    /// The honest end of the road. Something arrived, it can't be drawn, and saying so is
    /// better than a spinner that turns until the app is closed.
    private var unavailable: some View {
        shape
            .fill(.quaternary)
            .frame(width: tile ?? maximumWidth, height: tile ?? 120)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: message.kind == .video ? "film" : "photo")
                        .font(.title2)

                    // In an album the words are dropped: four of them in a tile that size
                    // break into a column of syllables. The tile itself still retries.
                    if tile == nil {
                        Text(
                            message.kind == .video
                                ? "Video unavailable"
                                : "Picture unavailable"
                        )
                        .font(.caption)

                        if !message.didFailToSend {
                            Text("Tap to try again")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.secondary)
            }
            // A picture that didn't come is usually a connection that dropped. Tapping asks
            // again, instead of leaving a grey box for good.
            .contentShape(shape)
            .onTapGesture {
                guard !message.didFailToSend else { return }
                failed = false
                attempt += 1
            }
            .accessibilityAddTraits(message.didFailToSend ? [] : .isButton)
            .accessibilityHint(message.didFailToSend ? "" : String(localized: "Tap to try again"))
    }

    /// How tall the picture itself is drawn: its own proportions, within the same limit.
    ///
    /// Worked out from the image rather than from what the message said about it, so a picture
    /// that arrived without its size is still drawn in proportion — and where the size was
    /// known, this comes to exactly the stand-in's height and nothing moves.
    private func shownHeight(of image: UIImage) -> CGFloat {
        guard image.size.width > 0 else { return placeholderHeight }
        return min(maximumWidth * image.size.height / image.size.width, 320)
    }

    /// Uses the real aspect ratio so the bubble doesn't jump when the image lands.
    private var placeholderHeight: CGFloat {
        if isSticker { return maximumWidth }
        guard let width = message.mediaWidth, let height = message.mediaHeight, width > 0 else {
            return 160
        }
        return min(maximumWidth * CGFloat(height) / CGFloat(width), 320)
    }

    private func load() async {
        guard loaded == nil else { return }

        // Nothing to fetch yet is not the same as fetching and failing. A picture you are
        // sending has no address until it is up and the server's own copy — which carries
        // one — has come back, and every photo you sent used to say "Picture unavailable" for
        // exactly that long. Your own stand-in waits instead; it is the one whose ID is still
        // the phone's, without the server's `$`. Anything else without an address, like a
        // picture that arrived in a form this app can't open, is still said to be unavailable,
        // and so is a send that failed.
        //
        // Unless its bytes are still here, waiting in the outbox: then it is drawn from those,
        // straight away. See `AttachmentLoader`.
        if message.isStandIn, !message.hasLocalCopy, !message.didFailToSend { return }
        failed = false

        // A tile is a fraction of the screen, so it asks the server for a fraction of the
        // picture. Fetching a 640-wide photo to draw it at 105 is four times the bytes and
        // four times the memory for something nobody can see.
        let wanted = tile.map { Int($0 * 3) } ?? 640

        let result = await AttachmentLoader.load(
            message, session: session, limits: .phone, width: wanted, height: wanted
        )

        if let result {
            loaded = result
        } else if !Task.isCancelled {
            // Only a real failure. Opening a picture full-screen cancels the tiles still
            // loading behind it, and a cancelled load used to come back marked as broken.
            failed = true
        }
    }
}

/// The text field, send button, and the reply banner above them.
private struct Composer: View {
    @Environment(ChatSession.self) private var session

    @Binding var draft: String
    @Binding var replyTarget: Message?

    let onSend: () -> Void
    let onTypingChanged: (Bool) -> Void
    /// Called when the field takes or loses focus, so the list can follow the keyboard.
    let onFocusChanged: (Bool) -> Void
    let onPickPhoto: (PhotosPickerItem) -> Void
    let onCapture: (CameraPicker.Capture) -> Void
    let onPickFile: (URL) -> Void

    /// A picture off the clipboard, as bytes and whatever kind of picture it is.
    let onPasteImage: (Data, UTType?) -> Void

    /// The pictures waiting to be sent, shown above the field until they are.
    @Binding var pendingPhotos: [PastedPhoto]

    let onShareLocation: () -> Void
    @Binding var editing: Message?

    /// True while the device is working out where it is, which can take a few seconds.
    let isFindingLocation: Bool

    /// Whether the screen has arrived; see `ComposerPickers`.
    let isReady: Bool

    @FocusState private var isFocused: Bool
    @State private var picked: [PhotosPickerItem] = []
    @State private var isPickingPhoto = false
    @State private var isTakingPhoto = false
    @State private var isPickingFile = false

    /// Whether there is a picture on the clipboard right now.
    ///
    /// Asked, never read: `hasImages` is the question iOS lets an app ask without a word to
    /// the person using it. Actually taking the picture is what needs permission, and that
    /// is what the paste button is for — the system asks for it, gets the answer, and hands
    /// over the bytes, with no alert of our own in the way.
    @State private var canPasteImage = false

    var body: some View {
        VStack(spacing: 0) {
            if let editing {
                ComposerBanner(
                    icon: "pencil",
                    title: "Editing",
                    detail: editing.body,
                    accent: .orange
                ) {
                    self.editing = nil
                }
            }

            if !pendingPhotos.isEmpty {
                PendingPhotosTray(
                    photos: pendingPhotos,
                    onRemove: { photo in
                        withAnimation(.snappy) { pendingPhotos.removeAll { $0.id == photo.id } }
                    },
                    onAddMore: { isPickingPhoto = true }
                )
            }

            if let replyTarget {
                ComposerBanner(
                    icon: "arrowshape.turn.up.left.fill",
                    title: session.isMine(replyTarget)
                        ? "Replying to yourself"
                        : "Replying to \(session.senderName(of: replyTarget) ?? "them")",
                    detail: replyTarget.body,
                    accent: session.isMine(replyTarget)
                        ? .accentColor
                        : SenderColour.of(replyTarget.sender)
                ) {
                    self.replyTarget = nil
                }
            }

            // The buttons in here carry glass that doesn't answer touch: the press is the
            // button's own (`chatmanPress`), the glass is only the surface.
            //
            // Interactive glass handles touches itself, and inside a container the pieces
            // that come close are joined into one group whose touches go to its first member.
            // A tap on send could light up the glass and never reach the button — the
            // "pressed, nothing happened, press again" this used to do.
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                if editing == nil {
                    // One button, the way Messages does it. Three icons in a row read as
                    // three decisions to make before writing anything; a plus reads as
                    // "there's more if you want it".
                    Menu {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button("Camera", systemImage: "camera") { isTakingPhoto = true }
                        }

                        Button("Photos", systemImage: "photo.on.rectangle") {
                            isPickingPhoto = true
                        }

                        // The system's own file browser: iCloud Drive, Dropbox, whatever is
                        // installed. Nothing to build and nothing to explain.
                        Button("Files", systemImage: "folder") { isPickingFile = true }

                        Button("Location", systemImage: "location") { onShareLocation() }
                    } label: {
                        Group {
                            if isFindingLocation {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 28, height: 28)
                            } else {
                                Image(systemName: "plus")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .frame(width: 34, height: 34)
                        .chatmanGlass(in: .circle)
                        // Same as its neighbour: drawn at 34, aimed at 44, both inside the
                        // label where the button can see them.
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                    }
                    .buttonStyle(.chatmanPress)
                    .disabled(isFindingLocation)
                    .accessibilityLabel("Share something")
                }

                // Only while there is a picture to paste, and gone again the moment there
                // isn't. A paste button that is always there is a button that does nothing
                // most of the time, which is exactly the kind of furniture this app avoids.
                if canPasteImage, editing == nil {
                    PasteButton(supportedContentTypes: [.image]) { providers in
                        loadPastedImage(from: providers)
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                    // Quiet, not blue. Blue in this row means "send", and a second blue
                    // circle beside it reads as a second send button.
                    .tint(Color(.systemGray5))
                    .frame(height: 34)
                    .transition(.scale.combined(with: .opacity))
                }

                TextField(
                    pendingPhotos.isEmpty ? "Message" : "Add a caption",
                    text: $draft,
                    axis: .vertical
                )
                    .lineLimit(1...5)
                    .chatmanFont(size: 17)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    // Glass, but only around what you type into — not behind the words
                    // themselves. A message has to stay readable over whatever happens to be
                    // scrolling underneath it, and that is the one place not to be clever.
                    //
                    // A fixed corner, not a capsule: a capsule's radius is half its height,
                    // so a field that grows to five lines turns into a stadium. Twenty is
                    // exactly half of the one-line height, so at rest it is the pill it was.
                    .chatmanGlass(in: .rect(cornerRadius: 20, style: .continuous))
                    .focused($isFocused)

                Button {
                    #if DEBUG
                    OpenStopwatch.write("[send] tap")
                    #endif
                    onSend()
                } label: {
                    Image(systemName: editing == nil ? "arrow.up" : "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .chatmanGlass(in: .circle, tint: .accentColor)
                        // Drawn at 34, aimed at 44 — and both inside the label.
                        //
                        // Thirty-four is under the smallest thing Apple says a finger should
                        // have to hit, and this one sits in the corner a thumb reaches at an
                        // angle. A near miss looks exactly like a button that didn't work,
                        // and the answer to a button that didn't work is to press it again.
                        //
                        // Widening it from outside the button does nothing, which is how this
                        // was tested and found out: a button hit-tests what it was given as
                        // its label, so a frame wrapped around the button afterwards is
                        // layout and not target. A tap 19 points off centre still missed.
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.chatmanPress)
                // Never disabled: a button that switches on with the first letter could be
                // a frame behind your thumb, and the tap went nowhere. Pressing it with nothing
                // to send simply does nothing; it only looks quieter.
                .opacity(
                    pendingPhotos.isEmpty
                        && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1
                )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // Asked when the screen appears and every time the app comes back to the front,
        // which between them cover both ways a picture lands on the clipboard: copied
        // somewhere else, or copied here.
        .task { refreshPasteState() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )
        ) { _ in
            refreshPasteState()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)
        ) { _ in
            refreshPasteState()
        }
        // Films erbij. Ze stonden er niet in, waardoor de enige weg naar een filmpje
        // uit je eigen bibliotheek via "Bestanden" liep.
        // Only once the screen is standing still. Setting up a photo picker, a file
        // importer and a camera cover costs 59 ms, measured, and every one of them is
        // unreachable until the conversation has finished arriving.
        .modifier(ComposerPickers(
            isReady: isReady,
            isPickingPhoto: $isPickingPhoto,
            picked: $picked,
            isTakingPhoto: $isTakingPhoto,
            isPickingFile: $isPickingFile,
            onPickPhoto: onPickPhoto,
            onCapture: onCapture,
            onPickFile: onPickFile
        ))
        .onChange(of: isFocused) { _, focused in
            onTypingChanged(focused && !draft.isEmpty)
            onFocusChanged(focused)
        }
        .onChange(of: draft) { _, text in onTypingChanged(!text.isEmpty) }
    }
}

/// Somebody at the other end, writing.
private struct TypingLine: View {
    let text: String

    @State private var phase = 0

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { dot in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 5, height: 5)
                        .opacity(phase == dot ? 1 : 0.3)
                }
            }

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .task {
            // Three dots taking turns. The animation is the point: a static "typing…" reads
            // as a label, a moving one reads as somebody being there.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(.easeInOut(duration: 0.3)) { phase = (phase + 1) % 3 }
            }
        }
    }
}

/// What sits above the field while you're answering or changing something.
///
/// The line it used to be said almost nothing: an icon, the message body, a cross. This says
/// what you are doing and to whom, in the colour that person has everywhere else, with the
/// same bar down the side as a quote in the conversation — so the thing above the keyboard
/// and the thing in the history are recognisably the same idea.
private extension Composer {

    /// Whether the paste button belongs on screen at this moment.
    func refreshPasteState() {
        let hasImage = UIPasteboard.general.hasImages
        guard hasImage != canPasteImage else { return }
        withAnimation(.snappy) { canPasteImage = hasImage }
    }

    /// Pulls the bytes out of whatever the system handed over.
    ///
    /// It arrives as a list of providers rather than a picture, because a single copied
    /// image is offered in several kinds at once — a screenshot is a PNG and a TIFF and a
    /// few other things besides. The first one that answers is the one that gets sent.
    func loadPastedImage(from providers: [NSItemProvider]) {
        let kinds: [UTType] = [.png, .jpeg, .heic, .heif, .gif, .tiff, .image]

        for provider in providers {
            for kind in kinds where provider.hasItemConformingToTypeIdentifier(kind.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: kind.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in onPasteImage(data, kind) }
                }
                return
            }
        }
    }
}

/// A picture off the clipboard, waiting above the field.
struct PastedPhoto: Identifiable {
    let id = UUID()
    let data: Data
    let type: UTType?

    /// Decoded once, when it arrives. Asking `UIImage(data:)` from a view's body would do it
    /// again on every redraw, and a redraw happens whenever anything on the session changes.
    let preview: UIImage?

    /// The full picture's size, for the message; the preview may be a thumbnail.
    var size: CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return preview?.size }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// A small picture to show in the tray, made off the main thread: a photo from the
    /// library is twelve megapixels, and the tray needs a hundred and twenty points of it.
    static func thumbnail(of data: Data) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 360
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
}

/// What is about to be sent, shown before it is: every picture, each with a way to take it
/// off again, and a way to add more.
private struct PendingPhotosTray: View {
    let photos: [PastedPhoto]
    let onRemove: (PastedPhoto) -> Void
    let onAddMore: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(photos) { photo in
                    Group {
                        if let preview = photo.preview {
                            Image(uiImage: preview)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color(.secondarySystemFill)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            onRemove(photo)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .font(.title3)
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(2)
                        .accessibilityLabel("Remove photo")
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                Button(action: onAddMore) {
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, height: 72)
                        .background(
                            Color(.secondarySystemFill),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
                .buttonStyle(.chatmanPress)
                .accessibilityLabel("Add more photos")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct ComposerBanner: View {
    let icon: String
    let title: String
    let detail: String
    let accent: Color
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 15)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(alignment: .leading) {
            accent.opacity(0.08)
        }
        // The bar is drawn over the banner rather than beside it. As a sibling in the row it
        // was a shape with no height of its own, so anything that offered the banner more
        // room — and the bottom inset offers it the whole screen — was taken: the bar grew,
        // the banner grew with it, and the conversation was squeezed off the top.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 3)
        }
        // And this is the belt to that pair of braces: whatever height is offered, the
        // banner is exactly as tall as the two lines inside it.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A location somebody shared, as one tap.
///
/// Chatman sends a link that works on any phone, which means a Google address — but the
/// person reading this is on an iPhone, and on an iPhone the map they use is Maps. So inside
/// the app the same coordinates open there instead.
private struct MapLink: View {
    let place: SharedLocation

    var body: some View {
        Link(destination: place.appleMapsURL ?? URL(string: "https://maps.apple.com")!) {
            HStack(spacing: 8) {
                Image(systemName: "map.fill")
                    .font(.system(size: 15))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Open in Maps")
                        .font(.footnote.weight(.medium))
                    Text(place.coordinates)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}


/// The composer's three ways of getting a file in, attached once the screen has arrived.
///
/// Together they measured 59 ms on the way into a conversation — a third of everything spent
/// before the first frame moved, for a photo picker, a file importer and a camera screen that
/// nobody can reach until the conversation is standing in front of them.
private struct ComposerPickers: ViewModifier {
    let isReady: Bool

    @Binding var isPickingPhoto: Bool
    @Binding var picked: [PhotosPickerItem]
    @Binding var isTakingPhoto: Bool
    @Binding var isPickingFile: Bool

    let onPickPhoto: (PhotosPickerItem) -> Void
    let onCapture: (CameraPicker.Capture) -> Void
    let onPickFile: (URL) -> Void

    func body(content: Content) -> some View {
        if isReady {
            content
                .photosPicker(
                    isPresented: $isPickingPhoto,
                    selection: $picked,
                    maxSelectionCount: 10,
                    selectionBehavior: .ordered,
                    matching: .any(of: [.images, .videos])
                )
                .onChange(of: picked) { _, items in
                    guard !items.isEmpty else { return }
                    picked = []
                    items.forEach(onPickPhoto)
                }
                .fullScreenCover(isPresented: $isTakingPhoto) {
                    CameraPicker { capture in
                        isTakingPhoto = false
                        guard let capture else { return }
                        onCapture(capture)
                    }
                    .ignoresSafeArea()
                }
                .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.item]) { result in
                    guard case .success(let url) = result else { return }
                    onPickFile(url)
                }
        } else {
            content
        }
    }
}


/// The text being typed. See `ConversationView.draftBox`.
@Observable final class DraftText {
    var text = ""
}

/// Whether the conversation is scrolling. See `ConversationView.scrollFlag`.
@Observable final class ScrollFlag {
    var moving = false
}

/// The backdrop, reading the scroll flag itself so nothing above it has to.
private struct MovingBackdrop: View {
    let depth: SkyDepth
    let flag: ScrollFlag

    var body: some View {
        Backdrop(depth: depth, isScrolling: flag.moving)
    }
}
