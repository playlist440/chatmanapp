#if canImport(UIKit)
import UIKit

/// Works out what an attachment should look like, whatever it turns out to be.
///
/// Both apps ask the same question — "give me a picture for this message" — and the answer
/// involves three different addresses depending on whether the thing is a photo, a film, or a
/// GIF pretending to be one. Neither app should have to know that, so it lives here once.
@MainActor
public enum AttachmentLoader {

    /// What to show, and whether it moves.
    public struct Result: Sendable {
        public let image: UIImage
        /// True when the picture is the still from a film that has to be opened to be watched.
        public let isPlayable: Bool
    }

    /// What a message's attachment is filed under at a given size.
    ///
    /// Shared so a viewer can put the list's copy on screen straight away instead of a
    /// spinner, while the sharper one is still on its way.
    public static func cacheKey(for message: Message, width: Int) -> String? {
        guard let address = message.mediaURL else { return nil }
        return "\(address)@\(width)\(message.isAnimated ? "-moving" : "")"
    }

    /// Loads a message's attachment at roughly the size it will be shown.
    ///
    /// Everything is cached by address and size, because a conversation is scrolled through
    /// far more often than it is added to.
    public static func load(
        _ message: Message,
        session: ChatSession,
        limits: AnimatedMedia.Limits,
        width: Int,
        height: Int
    ) async -> Result? {
        // Something you are sending, from the copy on this device. It is on screen the moment
        // you tap send, instead of as a grey box until the server has it — and once the upload
        // has given it an address, it is filed under that, so the server's copy of the same
        // message finds it already there and nothing flickers when one replaces the other.
        if let local = message.localCopy,
           let image = await localPicture(of: message, at: local, limits: limits) {
            if let key = cacheKey(for: message, width: width) {
                ImageCache.shared.store(image, for: key)
            }
            return Result(image: image, isPlayable: message.kind == .video && !message.isAnimated)
        }

        guard message.mediaURL != nil else { return nil }

        await fillInDetails(of: message, session: session)

        guard let key = cacheKey(for: message, width: width) else { return nil }

        if let cached = ImageCache.shared.image(for: key) {
            return Result(image: cached, isPlayable: playable(message, image: cached))
        }

        if message.isAnimated, let moving = await animation(for: message, session: session, limits: limits) {
            ImageCache.shared.store(moving, for: key)
            return Result(image: moving, isPlayable: false)
        }

        // Either it doesn't move, or it wouldn't play — a still is better than a spinner that
        // never stops, which is what an unreadable attachment used to leave behind. Scaled
        // by the server, so small, so on the connection for small things; see `preview`.
        if let request = session.previewRequest(for: message, width: width, height: height),
           let (data, response) = try? await MatrixAPI.preview.data(for: request),
           let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
           let still = AnimatedMedia.image(from: data, limits: limits) {
            ImageCache.shared.store(still, for: key)
            return Result(image: still, isPlayable: playable(message, image: still))
        }

        // Last resort, and only worth it for a film: take a frame out of the video itself.
        // Some are sent without any preview picture at all, and a phone can make one — which
        // beats a grey rectangle saying the video is unavailable when it plays perfectly well.
        guard let own = await frameFromVideoItself(message, session: session, limits: limits)
        else { return nil }

        ImageCache.shared.store(own, for: key)
        return Result(image: own, isPlayable: playable(message, image: own))
    }

    /// A picture of something still on this device: the photo itself, or a frame of the film.
    private static func localPicture(
        of message: Message, at file: URL, limits: AnimatedMedia.Limits
    ) async -> UIImage? {
        switch message.kind {
        case .image, .sticker:
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: file)
            }.value
            return data.flatMap { AnimatedMedia.image(from: $0, limits: limits) }

        case .video:
            #if os(watchOS)
            return nil
            #else
            return await AnimatedMedia.still(fromVideoAt: file, limits: limits)
            #endif

        default:
            return nil
        }
    }

    /// Asked once per message per launch, and only when something is actually missing.
    private static var completed: Set<String> = []

    /// Brings a stored message up to date with what the server says about it.
    ///
    /// Two things get fixed here. A GIF sent as a file gives itself away by its type alone, so
    /// that needs nothing but a look. A video's preview picture has to be asked for, and only
    /// for messages stored by a version of the app that didn't keep it.
    private static func fillInDetails(of message: Message, session: ChatSession) async {
        if !message.isAnimated, message.mediaMimeType?.lowercased() == "image/gif" {
            message.isAnimated = true
        }

        guard message.kind == .video, message.mediaThumbnailURL == nil else { return }
        guard !completed.contains(message.id) else { return }

        completed.insert(message.id)
        await session.refreshAttachment(message)
    }

    /// A frame cut out of the film, when it came without a picture of its own.
    private static func frameFromVideoItself(
        _ message: Message, session: ChatSession, limits: AnimatedMedia.Limits
    ) async -> UIImage? {
        #if os(watchOS)
        // watchOS has no frame reader at all, so there is nothing to fall back to.
        return nil
        #else
        guard message.kind == .video,
              let address = message.mediaURL,
              let request = session.fullSizeRequest(for: message),
              let file = await AnimatedMedia.file(
                  for: request, key: address,
                  mimeType: message.mediaMimeType, limit: 40_000_000
              )
        else { return nil }

        if message.isAnimated,
           let moving = await AnimatedMedia.image(fromVideoAt: file, limits: limits) {
            return moving
        }

        return await AnimatedMedia.still(fromVideoAt: file, limits: limits)
        #endif
    }

    /// A film keeps its play button; a GIF never gets one, even where it couldn't be made to
    /// move — a watch has no way to play an MP4 at all, and a play button that does nothing is
    /// worse than a still picture.
    private static func playable(_ message: Message, image: UIImage) -> Bool {
        guard message.kind == .video, !message.isAnimated else { return false }
        return (image.images?.count ?? 0) <= 1
    }

    /// The moving version, from whichever kind of file this actually is.
    private static func animation(
        for message: Message, session: ChatSession, limits: AnimatedMedia.Limits
    ) async -> UIImage? {
        guard let request = session.animatedSourceRequest(for: message),
              let address = message.mediaURL
        else { return nil }

        // A real GIF is decoded straight from its bytes. Anything else claiming to be one is
        // a film, and has to be written to disk before AVFoundation will look at it.
        let isGIF = message.mediaMimeType?.lowercased() == "image/gif"

        if isGIF {
            guard let (data, response) = try? await MatrixAPI.download.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return nil }

            return AnimatedMedia.image(from: data, limits: limits)
        }

        guard let file = await AnimatedMedia.file(
            for: request, key: address, mimeType: message.mediaMimeType,
            limit: limits.maximumFrames > 40 ? 12_000_000 : 4_000_000
        ) else { return nil }

        return await AnimatedMedia.image(fromVideoAt: file, limits: limits)
    }
}
#endif
