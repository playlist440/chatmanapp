import AVKit
import SwiftUI
import ChatmanKit

/// One attachment, filling the screen, at the size it was actually sent.
///
/// The list and the bubbles use thumbnails because over cellular the difference is kilobytes
/// against megabytes. This is the one place that's worth the full download — someone opened it
/// deliberately, which is exactly when detail matters.
///
/// A film gets a player instead, and a GIF keeps moving: opening one shouldn't be the moment
/// it stops.
///
/// Built to behave the way Messages does, because that is the one every hand already knows:
/// drag it anywhere to put it away and it follows you, with the conversation showing through
/// behind; let go short and it springs back. Tap once and everything but the picture gets out
/// of the way. Pinch where you are looking, not where the middle happens to be, and the
/// picture cannot be dragged off into the dark.
struct MediaViewer: View {

    /// Every picture in this conversation, oldest first, so one can be swiped to the next.
    let photos: [Message]

    /// The one that was tapped.
    let start: Message

    @Environment(\.dismiss) private var dismiss

    @State private var current: String

    /// How far the picture has been pulled away from the middle, on the way out.
    @State private var pull: CGSize = .zero

    /// Whether the picture on screen is zoomed in. Sent up from the page, because a zoomed
    /// picture panned with a finger must not also be a picture being thrown away.
    @State private var isZoomed = false

    /// Whether the buttons are on screen.
    @State private var showsChrome = true

    /// How much black there is between one picture and the next.
    private static let gutter: CGFloat = 24

    /// Which picture the scroll view is on, as an optional, which is what it asks for.
    private var scrolled: Binding<String?> {
        Binding(get: { current }, set: { if let value = $0 { current = value } })
    }

    /// How far you have to pull before letting go means goodbye.
    private let escape: CGFloat = 110

    private var dismissal: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                // Judged on the whole movement so far rather than the last twitch, or a
                // straight pull down with a wobble in it keeps changing its mind. Half again,
                // so a lazy diagonal still counts as a page turn rather than half of each.
                guard abs(value.translation.height) > abs(value.translation.width) * 1.5
                else { return }
                pull = value.translation
            }
            .onEnded { value in
                guard pull != .zero else { return }

                let far = abs(value.translation.height) > escape
                // A flick counts even when it is short: how fast you were going when you let
                // go says as much about what you meant as how far you got.
                let quick = abs(value.predictedEndTranslation.height) > escape * 2

                if far || quick {
                    dismiss()
                } else {
                    pull = .zero
                }
            }
    }

    init(photos: [Message], start: Message) {
        self.photos = photos
        self.start = start
        // Set here rather than in `onAppear`: a page view with no valid selection shows the
        // first page for a frame and then jumps, which reads as the app opening the wrong
        // picture and correcting itself.
        _current = State(initialValue: start.id)
    }

    var body: some View {
        ZStack {
            // Fades as you pull, so what you are going back to is already there before you
            // arrive. The cover itself is see-through — without that this would fade to the
            // system's own black and the whole point would be lost.
            Color.black
                .opacity(darkness)
                .ignoresSafeArea()

            // A scroll view that snaps, rather than a page view.
            //
            // The page view had no room between one picture and the next: halfway through a
            // swipe two photographs touched along a seam, which nothing that shows pictures
            // for a living does. Here there is a strip of black between them, wide enough to
            // read as a gap and narrow enough not to become a third thing on the screen.
            //
            // It also settles the old argument about gestures by construction: scrolling is
            // switched off outright while a picture is magnified, so a finger on a zoomed
            // photo moves the photo and nothing has to guess what was meant.
            ScrollView(.horizontal) {
                LazyHStack(spacing: Self.gutter) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        MediaPage(
                            message: photo,
                            position: index + 1,
                            total: photos.count,
                            isCurrent: photo.id == current,
                            isZoomed: Binding(
                                get: { photo.id == current ? isZoomed : false },
                                set: { if photo.id == current { isZoomed = $0 } }
                            ),
                            pull: $pull,
                            onSingleTap: {
                                withAnimation(.snappy(duration: 0.22)) { showsChrome.toggle() }
                            }
                        )
                        .containerRelativeFrame(.horizontal)
                        .id(photo.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: scrolled)
            .scrollIndicators(.hidden)
            .scrollDisabled(isZoomed)
            .ignoresSafeArea()
            // Around the scroll view, not inside it.
            //
            // Inside, on the page, a drag recogniser claims the touch and the scroll view
            // never sees it — which is how turning the page stopped working the moment this
            // was added there. Out here the two sit side by side: sideways is scrolling's,
            // and this one only answers to a pull that is clearly more up-or-down, so neither
            // has to guess what a diagonal meant.
            //
            // Off while zoomed in: a finger on a magnified picture is moving the picture.
            .simultaneousGesture(dismissal, including: isZoomed ? .subviews : .all)

            // The left edge goes back, everything else turns the page.
            //
            // Kept alongside the pull-to-put-away, not replaced by it. Two opposite meanings
            // for the same sideways movement, told apart by where it starts — which is the
            // rule iOS uses everywhere, and the reason a narrow strip is enough: nobody
            // starts a page turn with their thumb against the bezel.
            .overlay(alignment: .leading) {
                Color.clear
                    .frame(width: 22)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onEnded { value in
                                guard value.translation.width > 50,
                                      abs(value.translation.height) < 120
                                else { return }
                                dismiss()
                            }
                    )
                    .ignoresSafeArea()
            }

            chrome
        }
        .statusBarHidden()
        // So the fade above reveals the conversation rather than a black wall.
        .presentationBackground(.clear)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: pull)
    }

    /// How dark the ground behind the picture is.
    private var darkness: Double {
        max(0, 1 - Double(abs(pull.height)) / 320)
    }

    /// The buttons, which get out of the way when asked and while you are pulling.
    private var chrome: some View {
        VStack {
            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .chatmanGlass(in: .circle, interactive: true)
                        // Drawn at 34, aimed at 44 — the same as the composer's buttons, and
                        // inside the label where a button can see it.
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.chatmanPress)

                Spacer()

                // Which of how many. Without it a swipe that lands on a picture you have
                // seen before feels like the app went backwards on its own.
                if photos.count > 1, let index = photos.firstIndex(where: { $0.id == current }) {
                    Text("\(index + 1) / \(photos.count)")
                        .font(.footnote.weight(.medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .chatmanGlass(in: .capsule)
                }

                Spacer()

                SharePhoto(message: photos.first { $0.id == current })
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            Spacer()
        }
        // Gone while you are pulling: a bar hanging in mid-air over a picture on its way out
        // is the one thing that gives away that this is two views and not one.
        .opacity(showsChrome && pull == .zero ? 1 : 0)
        .allowsHitTesting(showsChrome && pull == .zero)
        .animation(.easeOut(duration: 0.18), value: pull == .zero)
    }
}

/// The share button, which only exists once there is something to share.
private struct SharePhoto: View {
    @Environment(ChatSession.self) private var session

    let message: Message?

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ShareLink(
                    item: Image(uiImage: image),
                    preview: .init("Photo", image: Image(uiImage: image))
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .chatmanGlass(in: .circle, interactive: true)
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
            } else {
                // Held open, so the counter beside it doesn't jump sideways the moment the
                // picture finishes loading.
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .task(id: message?.id) {
            image = nil
            guard let message, message.kind != .video, !message.isAnimated else { return }
            image = await MediaCache.picture(for: message, session: session)
        }
    }
}

/// One picture, filling the screen.
private struct MediaPage: View {
    @Environment(ChatSession.self) private var session

    let message: Message

    /// Where this one sits in the conversation's pictures.
    let position: Int
    let total: Int

    /// Whether this is the one being looked at.
    ///
    /// A picture left magnified and swiped away from should be back at its full size when you
    /// come to it again — otherwise a photo you looked at closely half an hour ago greets you
    /// at four times its size with no way of knowing why.
    let isCurrent: Bool

    @Binding var isZoomed: Bool

    /// How far this page has been pulled away, reported up so the ground behind can fade.
    @Binding var pull: CGSize

    let onSingleTap: () -> Void

    @State private var image: UIImage?
    @State private var video: URL?

    /// The one player for this page's film.
    ///
    /// Made once, when the film is ready, and kept. It used to be made inside the view, and
    /// this page redraws on every frame of a pull — so each frame built a new player, and a
    /// film you tugged at a little and let go of sprang back to the start, stopped.
    @State private var player: AVPlayer?
    @State private var failed = false

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    /// How far in a double tap goes, and how far a pinch is allowed to.
    private let closeUp: CGFloat = 2.6
    private let maximumZoom: CGFloat = 8

    var body: some View {
        ZStack {
            content
        }
        // The picture moves with the pull, while the gesture that drives it lives outside
        // the scroll view — see there for why it cannot live in here.
        .offset(pull)
        // Shrinks a little as it goes, the way a card being put back does. Bounded, or a long
        // pull leaves a stamp in the corner.
        .scaleEffect(max(0.82, 1 - abs(pull.height) / 1400))
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: pull)
        // The whole page, so a pull that starts on the black beside a tall picture works too.
        .contentShape(.rect)
        .task { await load() }
        .onDisappear { player?.pause() }
        .onChange(of: zoom) { _, value in isZoomed = value > 1.01 }
        .onChange(of: isCurrent) { _, showing in
            // A film keeps playing on a page you have swiped past — the pages either side
            // stay alive — and its sound carried on under the next picture.
            if !showing { player?.pause() }

            guard !showing, zoom > 1 else { return }
            zoom = 1
            committedZoom = 1
            settle()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let player {
            // Its own controls, its own scrubber: a film is the one attachment where the
            // system player is better than anything worth writing here.
            VideoPlayer(player: player)
                .ignoresSafeArea()
        } else if let image {
            GeometryReader { proxy in
                // A GIF plays straight away here: opening it is asking to see it move.
                Group {
                    if image.images != nil {
                        AnimatedPicture(image: image, isPlaying: true, contentMode: .scaleAspectFit)
                    } else {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(zoom)
                    .offset(offset)
                    .contentShape(.rect)
                    .gesture(magnification(in: proxy.size, of: image))
                    // Only once there is something to pan. Attached always it would take
                    // every sideways drag and the pictures would stop turning.
                    .simultaneousGesture(
                        pan(in: proxy.size, of: image),
                        including: zoom > 1 ? .all : .subviews
                    )
                    // Zooms towards where you tapped rather than the middle of the screen,
                    // which is the difference between looking closer at a face and looking
                    // closer at whatever happened to be in the centre.
                    .gesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in
                                toggleZoom(at: value.location, in: proxy.size, of: image)
                            }
                    )
                    .onTapGesture(count: 1) { onSingleTap() }
                    .animation(.snappy(duration: 0.28), value: zoom)
                    .animation(.snappy(duration: 0.28), value: offset)
            }
        } else if failed {
            VStack(spacing: 10) {
                Image(systemName: message.kind == .video ? "film" : "photo.badge.exclamationmark")
                    .font(.largeTitle)
                Text(message.kind == .video
                     ? "This video couldn't be loaded."
                     : "This picture couldn't be loaded.")
                    .font(.footnote)
            }
            .foregroundStyle(.white.opacity(0.7))
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    // MARK: - Getting closer

    private func magnification(in container: CGSize, of image: UIImage) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let wanted = committedZoom * value.magnification
                let next = min(max(wanted, 1), maximumZoom)

                // The point under your fingers stays under your fingers. Without this the
                // picture grows away from the middle and whatever you were looking at slides
                // off the screen while you are trying to look at it.
                let anchor = CGPoint(
                    x: (value.startAnchor.x - 0.5) * container.width,
                    y: (value.startAnchor.y - 0.5) * container.height
                )
                let growth = next / committedZoom
                offset = CGSize(
                    width: anchor.x + (committedOffset.width - anchor.x) * growth,
                    height: anchor.y + (committedOffset.height - anchor.y) * growth
                )
                zoom = next
                offset = held(offset, at: next, in: container, of: image)
            }
            .onEnded { _ in
                committedZoom = zoom
                if zoom <= 1 {
                    settle()
                } else {
                    committedOffset = held(offset, at: zoom, in: container, of: image)
                    offset = committedOffset
                }
            }
    }

    /// Panning only does anything while zoomed in; at fit-to-screen there's nowhere to go.
    private func pan(in container: CGSize, of image: UIImage) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                offset = held(
                    CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    ),
                    at: zoom, in: container, of: image
                )
            }
            .onEnded { _ in committedOffset = offset }
    }

    private func toggleZoom(at point: CGPoint, in container: CGSize, of image: UIImage) {
        if zoom > 1 {
            zoom = 1
            committedZoom = 1
            settle()
            return
        }

        // Aim at what was tapped: move the picture so that point ends up in the middle, as
        // far as the edges allow.
        let fromCentre = CGPoint(
            x: point.x - container.width / 2,
            y: point.y - container.height / 2
        )
        zoom = closeUp
        committedZoom = closeUp

        let wanted = CGSize(
            width: -fromCentre.x * closeUp,
            height: -fromCentre.y * closeUp
        )
        offset = held(wanted, at: closeUp, in: container, of: image)
        committedOffset = offset
    }

    /// Keeps the picture's edges from coming inside the screen.
    ///
    /// Without this a zoomed picture can be thrown into a corner and left there, showing a
    /// wedge of black where a photograph should be — which no good viewer allows and which is
    /// the main thing that made this one feel homemade.
    private func held(
        _ wanted: CGSize, at zoom: CGFloat, in container: CGSize, of image: UIImage
    ) -> CGSize {
        let shown = fitted(image.size, in: container)
        let room = CGSize(
            width: max(0, (shown.width * zoom - container.width) / 2),
            height: max(0, (shown.height * zoom - container.height) / 2)
        )

        return CGSize(
            width: min(max(wanted.width, -room.width), room.width),
            height: min(max(wanted.height, -room.height), room.height)
        )
    }

    /// How large the picture is drawn before any zoom: as large as fits, keeping its shape.
    private func fitted(_ size: CGSize, in container: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return container }

        let scale = min(container.width / size.width, container.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func settle() {
        offset = .zero
        committedOffset = .zero
    }

    // MARK: - Getting it here

    private func load() async {
        guard image == nil, video == nil else { return }

        // A GIF that stops the moment you look closer at it isn't worth opening, so this
        // takes the moving version — larger than the bubble's, since it now fills a screen.
        if message.isAnimated {
            let bigger = AnimatedMedia.Limits(maximumPixelSize: 720, maximumFrames: 200)
            if let result = await AttachmentLoader.load(
                message, session: session, limits: bigger, width: 800, height: 600
            ) {
                image = result.image
                return
            }
        }

        if message.kind == .video, let request = session.fullSizeRequest(for: message),
           let file = await AnimatedMedia.file(
               for: request, key: (message.mediaURL ?? message.id) + "-full",
               mimeType: message.mediaMimeType, limit: 80_000_000
           ) {
            video = file
            player = AVPlayer(url: file)
            return
        }

        // A film that didn't come — too large, or the download failed — stops here. It used to
        // fall through to the picture loader, which fetched the same film all over again, with
        // no size limit and into memory, only to find it couldn't be read as a picture. A
        // 300 MB film cost two 300 MB downloads over cellular, and could take the app down
        // with it.
        if message.kind == .video {
            failed = true
            return
        }

        guard let decoded = await MediaCache.picture(for: message, session: session) else {
            failed = true
            return
        }

        image = decoded
    }
}

/// Full-size pictures, fetched once.
///
/// The page needs one to show and the share button needs the same one to hand over, and
/// downloading a photograph twice because two views asked separately is the sort of thing a
/// phone on a train notices.
enum MediaCache {
    /// Bounded, and let go of when the system asks.
    ///
    /// It was a plain dictionary that never gave anything back, and the viewer loads the
    /// pictures either side of the one you look at. A 12-megapixel photo is close to 50 MB
    /// once decoded, so swiping through a chat full of them held on to hundreds of megabytes
    /// for as long as the app lived — days, for an app that stays open — until the system
    /// ended it. A cache priced by the size of each picture keeps the few you are looking at
    /// and empties itself under memory pressure.
    @MainActor private static let pictures: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 80 * 1024 * 1024
        return cache
    }()

    /// What a picture costs in memory once drawn: four bytes a pixel.
    private static func cost(of image: UIImage) -> Int {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels) * 4
    }

    @MainActor
    static func picture(for message: Message, session: ChatSession) async -> UIImage? {
        let key = message.mediaURL ?? message.id
        if let remembered = pictures.object(forKey: key as NSString) { return remembered }

        #if DEBUG
        // A design preview has no server behind it, so every picture in it is a grey box
        // saying it couldn't be loaded — which is no way to judge a photo viewer. Drawn
        // rather than shipped: a real file in the bundle would travel to the phone for
        // nothing.
        if DesignPreview.requested != nil {
            let drawn = invented(for: key)
            pictures.setObject(drawn, forKey: key as NSString, cost: cost(of: drawn))
            return drawn
        }
        #endif

        guard let request = session.fullSizeRequest(for: message),
              let (data, response) = try? await MatrixAPI.download.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              var decoded = UIImage(data: data)
        else { return nil }

        // Decoded here rather than on the main thread at the first frame.
        if let ready = await decoded.byPreparingForDisplay() { decoded = ready }

        pictures.setObject(decoded, forKey: key as NSString, cost: cost(of: decoded))
        return decoded
    }

    #if DEBUG
    /// A picture to look at when there is no server: tall, so the edges of a zoom are
    /// somewhere findable, and marked out so movement is obvious.
    @MainActor
    private static func invented(for key: String) -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        let hue = Double(abs(key.hashValue) % 360) / 360

        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: hue, saturation: 0.55, brightness: 0.75, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor(hue: hue, saturation: 0.8, brightness: 0.35, alpha: 1).setStroke()
            context.cgContext.setLineWidth(8)
            for step in stride(from: 0, through: 1600, by: 100) {
                context.cgContext.move(to: CGPoint(x: 0, y: step))
                context.cgContext.addLine(to: CGPoint(x: 1200, y: step))
            }
            context.cgContext.strokePath()

            UIColor.white.setStroke()
            context.cgContext.setLineWidth(24)
            context.cgContext.stroke(CGRect(x: 12, y: 12, width: 1176, height: 1576))

            let text = "1200 x 1600" as NSString
            text.draw(
                at: CGPoint(x: 80, y: 80),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 96, weight: .bold),
                    .foregroundColor: UIColor.white,
                ]
            )
        }
    }
    #endif
}
