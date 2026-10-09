#if canImport(UIKit)
import SwiftUI
import UIKit

/// Images already fetched, kept for as long as the app is running.
///
/// A conversation list draws the same handful of avatars over and over as rows scroll in and
/// out. Without this each appearance is a fresh authenticated request over the network — on a
/// watch, that's radio time spent re-downloading a picture that hasn't changed.
@MainActor
public final class ImageCache {
    public static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()

    /// Counted and weighed, not just counted.
    ///
    /// A count on its own says nothing about memory: two hundred thumbnails is a few
    /// megabytes, while two hundred full-size photos — or two hundred GIFs, each of which is
    /// dozens of frames held as one image — is enough to have the app shut down on a phone
    /// with other things open. The cost is what the pixels actually weigh, so a handful of
    /// large things push each other out long before the count is reached.
    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    public func image(for key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    public func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
    }

    /// Roughly what an image occupies once drawn: four bytes a pixel, times every frame.
    private static func cost(of image: UIImage) -> Int {
        let scale = image.scale
        let pixels = image.size.width * scale * image.size.height * scale
        let frames = image.images?.count ?? 1
        return Int(pixels) * 4 * frames
    }
}

/// An image loaded from the homeserver.
///
/// Matrix media needs an access token since version 1.11, so `AsyncImage` with a plain URL
/// gets a 401 and shows nothing. The request has to be prepared with the session's headers,
/// which is why this exists rather than the built-in view.
public struct RemoteImage<Placeholder: View>: View {

    private let request: URLRequest?
    private let cacheKey: String?
    private let placeholder: Placeholder

    @State private var image: UIImage?

    public init(
        request: URLRequest?,
        cacheKey: String?,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.request = request
        self.cacheKey = cacheKey
        self.placeholder = placeholder()
    }

    public var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .task(id: cacheKey) { await load() }
    }

    private func load() async {
        guard let request, let cacheKey else { return }

        if let cached = ImageCache.shared.image(for: cacheKey) {
            image = cached
            return
        }

        guard let (data, response) = try? await MatrixAPI.preview.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              var decoded = UIImage(data: data)
        else { return }

        // Decoded here, off the main thread, rather than on it at the first frame it is drawn
        // in — which was a hitch every time a new face scrolled into view.
        #if os(iOS)
        if let ready = await decoded.byPreparingForDisplay() { decoded = ready }
        #endif

        ImageCache.shared.store(decoded, for: cacheKey)
        image = decoded
    }
}
#endif
