import SwiftUI
import ChatmanKit

/// Every picture in one album, so a number on a tile leads somewhere.
///
/// A grid of four with "+3" on the last is the right shape in a conversation — it says "an
/// album" in the space of one message. But it is a summary, and a summary has to be openable,
/// or those three pictures are simply gone.
///
/// How it is divided up depends on how many there are. Three pictures in a three-column grid
/// are three postage stamps with a screen of white under them; twelve in two columns are a
/// column you scroll forever. The count is known, so it decides.
struct AlbumOverview: View {
    @Environment(\.dismiss) private var dismiss

    /// What's being looked through. Wrapped so it can drive a presentation.
    struct Contents: Identifiable {
        let photos: [Message]
        var id: String { photos.first?.id ?? "" }
    }

    let photos: [Message]

    /// How many across, for this many pictures.
    private var columns: Int {
        switch photos.count {
        case 1: 1
        case 2...4: 2
        case 5...12: 3
        default: 4
        }
    }

    private let gap: CGFloat = 2

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: gap),
                    count: columns
                ),
                spacing: gap
            ) {
                ForEach(photos) { photo in
                    NavigationLink {
                        // Pushed, not presented. Opening a picture used to close this screen
                        // and open another over the conversation, which looked like the
                        // overview falling away underneath you — and left nothing to go back
                        // to. As a page on the stack, the way back is the way you came.
                        MediaViewer(photos: photos, start: photo)
                            .toolbar(.hidden, for: .navigationBar)
                    } label: {
                        AlbumTile(message: photo)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, gap)
        }
        .background(Color(.systemBackground))
        .navigationTitle("\(photos.count) photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// One square in the overview.
///
/// Square whatever the picture is: a grid of different heights is a mess to look along, and
/// the point of an overview is that the eye can run down it without stopping.
private struct AlbumTile: View {
    @Environment(ChatSession.self) private var session

    let message: Message

    @State private var loaded: AttachmentLoader.Result?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                if let loaded {
                    Image(uiImage: loaded.image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay { ProgressView() }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // Said out loud, because a still from a film looks like a photograph until
                // you tap it and it starts playing.
                if message.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .task {
                guard loaded == nil else { return }
                loaded = await AttachmentLoader.load(
                    message, session: session, limits: .phone, width: 400, height: 400
                )
            }
    }
}
