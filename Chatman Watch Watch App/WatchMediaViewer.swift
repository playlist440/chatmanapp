import SwiftUI
import ImageIO
import ChatmanKit

/// One picture, on a screen the size of a stamp.
///
/// The Digital Crown does the zooming. On a watch there's no room for a pinch — two fingers
/// cover the whole image — and the crown is the one control you can use without hiding what
/// you're looking at.
struct WatchMediaViewer: View {

    /// Every picture worth paging to from here, oldest first.
    let photos: [Message]

    /// The one that was tapped.
    let start: Message

    @Environment(\.dismiss) private var dismiss
    @State private var current: String

    init(photos: [Message], start: Message) {
        self.photos = photos
        self.start = start
        _current = State(initialValue: start.id)
    }

    /// One picture, for when there is nothing to page between.
    init(message: Message) {
        self.init(photos: [message], start: message)
    }

    var body: some View {
        TabView(selection: $current) {
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                WatchMediaPage(
                    message: photo,
                    position: index + 1,
                    total: photos.count,
                    isCurrent: photo.id == current
                )
                .tag(photo.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // The left edge goes back, everything else turns the page — the same rule as on the
        // phone. watchOS already goes back on a swipe from the edge, but only from the very
        // edge; this makes the strip wide enough to hit without aiming.
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 18)
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
        .navigationTitle("")
    }
}

/// One picture, on a screen the size of a stamp.
private struct WatchMediaPage: View {
    @Environment(ChatSession.self) private var session

    let message: Message
    let position: Int
    let total: Int

    /// Whether this is the page being looked at.
    ///
    /// A page view builds its neighbours before you reach them, and each of them used to
    /// claim the Digital Crown as it appeared. Three pages asking for the same crown means
    /// the last one to load wins — so a turn could zoom a picture that isn't on screen.
    let isCurrent: Bool

    @State private var image: UIImage?
    @State private var failed = false
    /// True while the sharp copy is still on its way and what's shown is the list's thumbnail.
    @State private var isSharpening = false

    /// Whether what's shown is the sharp copy, so coming back to a page doesn't fetch it again.
    @State private var isSharp = false

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    @FocusState private var crownFocused: Bool

    var body: some View {
        Group {
            if let image {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(zoom)
                        .offset(offset)
                        // Only once there is something to pan: attached always, it eats
                        // every sideways drag and the page never turns.
                        .gesture(drag, including: zoom > 1 ? .all : .subviews)
                        .overlay(alignment: .topTrailing) {
                            // Small, and only while it lasts: the picture is already there to
                            // look at, this only says a better one is coming.
                            if isSharpening {
                                ProgressView()
                                    .controlSize(.mini)
                                    .padding(6)
                            }
                        }
                }
            } else if failed {
                Text(message.kind == .video
                     ? "Couldn't load this video."
                     : "Couldn't load this picture.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .focusable(isCurrent)
        .focused($crownFocused)
        .digitalCrownRotation(
            $zoom,
            from: 1, through: 5, by: 0.05,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onChange(of: zoom) { _, new in
            // Back to fitting the screen means back to the middle: panning a picture that
            // already fits only loses it off the edge.
            if new <= 1 {
                offset = .zero
                committedOffset = .zero
            }
        }
        .onAppear { crownFocused = isCurrent }
        .onChange(of: isCurrent) { _, mine in crownFocused = mine }
        // Which of how many, in the corner where a watch has room for it.
        .overlay(alignment: .bottom) {
            if total > 1 {
                Text("\(position) / \(total)")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .chatmanGlass(in: .capsule)
                    .padding(.bottom, 2)
            }
        }
        .navigationTitle("")
        // Again whenever the page becomes the one being looked at — see `load`. Swiping on
        // before the sharp copy has arrived cancels it, which is the point: that download
        // was for a picture nobody is looking at any more.
        .task(id: isCurrent) { await load() }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in committedOffset = offset }
    }

    private func load() async {
        guard !isSharp else { return }

        // The copy already downloaded for the list. Coarse, but it costs nothing and it's
        // something to look at while the real one arrives.
        if image == nil,
           let key = WatchAttachment.cacheKey(for: message),
           let cached = ImageCache.shared.image(for: key) {
            image = cached
        }

        // Only the page being looked at goes any further.
        //
        // The page view builds its neighbours before you reach them, and each of them used to
        // fetch its own full-size original as it appeared: opening one photo on cellular
        // downloaded three, and decoded three at 2048 pixels on a watch that can barely hold
        // one. A neighbour shows the list's copy until it is swiped to.
        guard isCurrent else { return }

        failed = false
        isSharpening = image != nil
        defer { isSharpening = false }

        // A GIF is worth a second look at twice the frames, and a film has no player on a
        // watch — its own still is the whole of what can be shown here.
        if message.isAnimated || message.kind == .video {
            let closer = AnimatedMedia.Limits(maximumPixelSize: 320, maximumFrames: 40)
            let result = await AttachmentLoader.load(
                message, session: session, limits: closer, width: 400, height: 300
            )

            // Swiped away while it was coming: not a failure, and not this page's to show.
            guard !Task.isCancelled else { return }

            if let result {
                image = result.image
                isSharp = true
            } else {
                failed = image == nil
            }
            return
        }

        // Opening a picture is the moment to spend the data. Anything smaller falls apart
        // under the crown, which zooms to five times: the picture has to carry five times the
        // screen's own pixels or there is nothing there to magnify.
        guard let request = session.fullSizeRequest(for: message),
              let (data, response) = try? await MatrixAPI.download.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = Self.downsampled(data, to: 2048)
        else {
            guard !Task.isCancelled else { return }
            failed = image == nil
            return
        }

        image = decoded
        isSharp = true
    }

    /// Decodes a photo no larger than a watch can hold.
    ///
    /// A modern camera's original is twelve megapixels or more, and decoding one whole costs
    /// around fifty megabytes of memory — more than this app is given. ImageIO scales while
    /// decoding, so the full frame never exists: 2048 across is still four times the screen
    /// and holds up at the crown's furthest zoom.
    private static func downsampled(_ data: Data, to maximum: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return UIImage(data: data) }

        return UIImage(cgImage: cgImage)
    }
}
