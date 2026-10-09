import SwiftUI
import SwiftData
import ChatmanKit

/// Who you're talking to, and everything they've sent you.
///
/// Reached by tapping the name at the top of a conversation, the way every messaging app does
/// it. The media grid is the part people actually come here for: a picture from three weeks
/// ago is far easier to find as a thumbnail than by scrolling a timeline.
struct ConversationDetailView: View {
    @Environment(ChatSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let conversation: Conversation

    @State private var viewing: Message?

    /// Whether this conversation is still going by a name nobody chose.
    ///
    /// A chat the address book could place needs nothing; one that arrived as a handle from
    /// the network does. Held-open for a name you set yourself too, so you can change it.
    private var needsNaming: Bool {
        conversation.customName != nil
            || session.unmatchedConversations.contains(session.displayName(for: conversation))
    }

    /// Whether the picture is being looked at on its own.
    @State private var isShowingPortrait = false

    /// Whether the address book is open to pick who this is.
    @State private var isPickingContact = false

    /// The pictures and films, newest first, asked of the store.
    ///
    /// It used to be worked out from `conversation.messages`, which loads every message in
    /// the room, then filtered and sorted — four times over, since the screen asks for it in
    /// four places, and again on every message arriving in that chat. For a conversation
    /// with a year behind it that was thousands of messages sorted on the main thread on
    /// each redraw, the very thing the conversation screen had already been cured of. A
    /// query hands over the hundred and twenty wanted, and nothing else.
    @Query private var media: [Message]

    init(conversation: Conversation) {
        self.conversation = conversation

        let room = conversation.id
        let image = Message.Kind.image.rawValue
        let video = Message.Kind.video.rawValue
        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> {
                $0.conversation?.id == room && ($0.kindID == image || $0.kindID == video)
            },
            sortBy: [SortDescriptor(\Message.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 120
        _media = Query(descriptor)
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        NavigationStack {
            ScrollView {
                header

                if media.isEmpty {
                    ContentUnavailableView(
                        "No photos yet",
                        systemImage: "photo.on.rectangle",
                        description: Text("Pictures from this conversation collect here.")
                    )
                    .padding(.top, 40)
                } else {
                    grid
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(item: $viewing) { message in
                // The whole collection, swipeable, from wherever you opened it.
                MediaViewer(photos: media, start: message)
            }
            .sheet(isPresented: $isPickingContact) {
                ContactPicker { name, photo in
                    isPickingContact = false
                    guard let name else { return }
                    session.rename(conversation, to: name, photo: photo)
                }
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $isShowingPortrait) {
                AvatarPortrait(conversation: conversation, session: session) {
                    isShowingPortrait = false
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            // The picture opens itself. This is the one screen where a photo of somebody is
            // the subject rather than a label, so tapping it does the obvious thing.
            Button {
                isShowingPortrait = true
            } label: {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(
                    request: session.avatarRequest(for: conversation.avatarURL, size: 240),
                    // The size in the key. Filed under the bare address, it found the list's
                    // own small copy first — the list always loads before this screen — and
                    // the larger one was never asked for: a face a third as sharp as it
                    // should be, at the top of the screen that is about that person.
                    cacheKey: conversation.avatarURL.map { "\($0)@240" }
                ) {
                    if let image = session.contactPicture(for: conversation) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Circle()
                            .fill(Monogram.gradient(for: session.displayName(for: conversation)))
                            .overlay {
                                Text(initials)
                                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                            }
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(Circle())

                if conversation.network != .matrix {
                    NetworkBadge(network: conversation.network, size: 28)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                }
            }
            .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View photo")

            Text(session.displayName(for: conversation))
                .chatmanFont(size: 22, weight: .semibold, relativeTo: .title2)
                .multilineTextAlignment(.center)

            // The way out when the address book can't reach somebody. Signal lets people
            // hide their number behind a username, and a chat with one of those arrives
            // called something like "bdbkyra" and stays that way — there is nothing to
            // match on. Picking the contact by hand fixes it once, permanently.
            // Only where it's needed. Matching on phone number reaches nearly everybody, and
            // a button offering to fix a name that is already right is a button that makes
            // you wonder what's wrong with it.
            if needsNaming {
                Button {
                    isPickingContact = true
                } label: {
                    Label(
                        conversation.customName == nil ? "Choose from contacts" : "Change contact",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .font(.footnote)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 2)
            }

            if conversation.customName != nil {
                Button("Use the name from \(conversation.network.displayName)") {
                    session.rename(conversation, to: nil)
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !media.isEmpty {
                Text("\(media.count) photos and videos")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 3) {
            ForEach(media) { message in
                Button {
                    viewing = message
                } label: {
                    // The square is claimed first and the picture drawn inside it. Asking
                    // the picture to be square instead let a portrait one keep its own
                    // height, push the cell taller and spill over the text above.
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            RemoteImage(
                                // A film has no thumbnail of its own on the server — only
                                // the still that was uploaded beside it — so this asks for
                                // whichever of the two the message actually has.
                                request: session.previewRequest(
                                    for: message, width: 320, height: 240
                                ),
                                cacheKey: message.mediaThumbnailURL ?? message.mediaURL
                            ) {
                                Rectangle().fill(.quaternary)
                            }
                        }
                        .clipped()
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottomLeading) {
                            if message.isAnimated {
                                Text("GIF")
                                    .font(.caption2.weight(.heavy))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .shadow(radius: 2)
                            } else if message.kind == .video {
                                Image(systemName: "play.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .shadow(radius: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 3)
    }

    private var subtitle: String? {
        // What the network calls them, when that isn't already the name on screen. Worth
        // showing: it's how you check you're talking to the person you think you are.
        if conversation.isDirect, let partner = conversation.directPartnerID {
            let networkName = conversation.name
            let shown = session.displayName(for: conversation)

            if let networkName, networkName != shown {
                return "\(networkName) · \(conversation.network.displayName)"
            }

            return BridgeIdentity.network(of: partner) == .matrix
                ? partner
                : conversation.network.displayName
        }

        return conversation.network == .matrix ? nil : conversation.network.displayName
    }

    private var initials: String {
        let words = session.displayName(for: conversation).split(separator: " ").prefix(2)
        let letters = words.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
