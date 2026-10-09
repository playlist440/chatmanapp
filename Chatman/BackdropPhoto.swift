import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A picture of your own behind the app, chosen from the photo library.
///
/// Kept in the app's own folder on this phone and nowhere else: not sent to the server, not
/// to the watch, and left out of iCloud and computer backups. The photo picker hands over only
/// the one picture that was chosen, so the app never needs — and never asks for — access to
/// the library itself. Where it was taken and with what doesn't come along either: the
/// picture is drawn again from its pixels, and the place and camera details are left behind.
///
/// Stored cut to the shape of the screen and at its size, not as it came. A photo from the
/// camera is twelve megapixels or more and the wrong shape; behind a list it fills a screen
/// of three, and holding the rest in memory for nothing is what gets an app closed by the
/// system while it is in the background.
@MainActor
@Observable
final class BackdropPhoto {
    static let shared = BackdropPhoto()

    /// The picture, decoded and ready to draw. Nil until one has been chosen, and for a
    /// moment after launch while it is read.
    private(set) var image: UIImage?

    /// The same picture softened, and by how much. Worked out once whenever the blur changes,
    /// not on every frame the screen changes — a full-screen blur redrawn under a scrolling
    /// list is the most expensive thing that list could ask for.
    private(set) var softened: (amount: Double, image: UIImage)?

    private init() {
        let file = Self.file
        Task {
            image = await Task.detached(priority: .utility) {
                Self.decode(try? Data(contentsOf: file))
            }.value
        }
    }

    /// Where it lives.
    nonisolated private static var file: URL {
        URL.applicationSupportDirectory.appending(path: "Backdrop/photo.jpg")
    }

    /// The size it is cut to, in pixels: this phone's screen, upright.
    private static var screen: CGSize {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.screen.nativeBounds.size ?? CGSize(width: 1320, height: 2868)
    }

    /// Takes a picture as the photo picker handed it over, cuts it to the screen and keeps it.
    func use(_ data: Data) async throws {
        let target = Self.screen
        let shrunk = try await Task.detached(priority: .userInitiated) {
            try Self.fit(data, to: target)
        }.value

        let folder = Self.file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Out of the backups, so a picture that is meant to stay on this phone does.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var marked = folder
        try? marked.setResourceValues(values)

        try shrunk.write(to: Self.file, options: [.atomic, .completeFileProtection])

        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(shrunk) }.value
        softened = nil
        image = decoded
    }

    /// Forgets the picture, from memory and from disk.
    func remove() {
        try? FileManager.default.removeItem(at: Self.file)
        image = nil
        softened = nil
    }

    /// Softens the picture by this much, off the main thread, unless it already is.
    func soften(_ amount: Double) async {
        guard let image, softened?.amount != amount else { return }

        guard amount > 0.01 else {
            softened = (amount, image)
            return
        }

        let blurred = await Task.detached(priority: .userInitiated) {
            Self.blur(image, by: amount)
        }.value

        // A newer amount asked for in the meantime wins.
        guard !Task.isCancelled, let blurred, self.image === image else { return }
        softened = (amount, blurred)
    }

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "That picture couldn't be read." }
    }

    // MARK: - Off the main thread

    nonisolated private static let context = CIContext()

    /// Reads it and decodes it now, rather than at the moment it is first drawn.
    nonisolated private static func decode(_ data: Data?) -> UIImage? {
        guard let data, let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    /// Up to twenty-four points of softening at full, at this screen's three pixels a point:
    /// the colours and the light of the picture survive, the details that would compete with
    /// words don't.
    nonisolated private static func blur(_ image: UIImage, by amount: Double) -> UIImage? {
        guard let source = image.cgImage else { return nil }
        let input = CIImage(cgImage: source)
        let output = input
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 36 * amount)
            .cropped(to: input.extent)
        guard let blurred = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: blurred)
    }

    /// Decodes no more than it needs, turned the right way up, cuts the middle out at the
    /// screen's shape and writes that back as a JPEG.
    nonisolated private static func fit(_ data: Data, to target: CGSize) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0
        else { throw Failure.unreadable }

        // Orientations five to eight are stored on their side.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let upright = orientation >= 5
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)

        // Large enough to cover the screen once cut, and never made larger than it was.
        let scale = min(1, max(target.width / upright.width, target.height / upright.height))
        let longest = Int((max(upright.width, upright.height) * scale).rounded(.up))

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let whole = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw Failure.unreadable }

        // The middle, at the screen's shape.
        let shape = target.width / target.height
        let w = Double(whole.width), h = Double(whole.height)
        let cut = w / h > shape
            ? CGRect(x: (w - h * shape) / 2, y: 0, width: h * shape, height: h)
            : CGRect(x: 0, y: (h - w / shape) / 2, width: w, height: w / shape)
        let picture = whole.cropping(to: cut.integral) ?? whole

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw Failure.unreadable }

        CGImageDestinationAddImage(
            destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return out as Data
    }
}

/// The chosen picture, filling the screen, softened and veiled so that what is written over
/// it can still be read: darkened in the dark, lightened in the light.
///
/// Still, on purpose. A photo is already busy; making it move as well would be one thing too
/// many behind a conversation.
struct PhotoBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    /// From nought to one: how much of the page lies over the picture.
    let veil: Double
    /// From nought to one: how soft the picture is.
    let blur: Double

    private var photo: BackdropPhoto { BackdropPhoto.shared }

    var body: some View {
        ZStack {
            Color(.systemBackground)

            // The softened copy once it's there, and the sharp one until then — or the last
            // softened one while a new amount is being worked out, so a dial being dragged
            // doesn't flicker between the two.
            if let image = photo.softened?.image ?? photo.image {
                // Laid out at the size of whatever it sits behind and cut to it, so a tall
                // photo fills a short preview without spilling over the rest of the screen.
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                    .clipped()

                (scheme == .dark ? Color.black : Color.white)
                    .opacity(0.1 + 0.75 * veil)
            }
        }
        // Again when the amount changes, and when a new picture arrives.
        .task(id: "\(blur) \(photo.image.map { ObjectIdentifier($0).hashValue } ?? 0)") {
            await photo.soften(blur)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
