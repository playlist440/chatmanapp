#if canImport(UIKit)
import AVFoundation
import ImageIO
import UIKit

/// Moving pictures, from either of the two shapes a GIF arrives in.
///
/// Sent as a file, a GIF is an `image/gif` and ImageIO can read it. Sent through WhatsApp or
/// Signal it is a silent MP4 that only a bridge flag says was ever a GIF, and there is no
/// picture in it to decode — the frames have to be pulled out of the film one at a time.
///
/// Both roads end in the same place: a `UIImage` that animates on its own, which is all a
/// `SwiftUI` `Image` needs to play something without a player, a control strip, or a tap.
@MainActor
public enum AnimatedMedia {

    /// Everything here is capped. A GIF is somebody else's file and can be a thousand frames
    /// of nothing; a watch has neither the memory to hold that nor a screen that would show
    /// the difference.
    public struct Limits: Sendable {
        public let maximumPixelSize: Int
        public let maximumFrames: Int

        public init(maximumPixelSize: Int, maximumFrames: Int) {
            self.maximumPixelSize = maximumPixelSize
            self.maximumFrames = maximumFrames
        }

        /// Room for a bubble on a phone.
        public static let phone = Limits(maximumPixelSize: 480, maximumFrames: 120)

        /// A watch screen is 200 points across and its memory allowance is small enough that
        /// a careless animation is what gets the app killed mid-conversation.
        public static let watch = Limits(maximumPixelSize: 200, maximumFrames: 24)
    }

    // MARK: - Animated image files

    /// Reads a GIF — or an animated PNG or WebP, which cost nothing extra here.
    ///
    /// Frames in a GIF each carry their own delay, while an animated `UIImage` gives every
    /// frame the same share of the total. Rather than average them and have everything drift,
    /// slow frames are simply repeated: the picture keeps the timing it was drawn with.
    public static func image(from data: Data, limits: Limits) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        // A single frame is left exactly as it arrived. The size asked of the server is
        // already the size it will be shown at, and scaling it again here is how a photo
        // ends up looking like gravel.
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limits.maximumPixelSize
        ]

        // A long GIF is sampled rather than truncated: dropping the tail would cut the joke
        // off, and every other frame still reads as the same animation.
        let stride = max(1, Int((Double(count) / Double(limits.maximumFrames)).rounded(.up)))

        var frames: [UIImage] = []
        var total: Double = 0

        for index in Swift.stride(from: 0, to: count, by: stride) {
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, index, options as CFDictionary
            ) else { continue }

            let delay = self.delay(of: source, at: index) * Double(stride)
            frames.append(UIImage(cgImage: cgImage))
            total += delay
        }

        guard !frames.isEmpty else { return UIImage(data: data) }
        guard frames.count > 1 else { return frames[0] }

        return UIImage.animatedImage(with: frames, duration: total)
    }

    /// How long one frame is meant to stay on screen.
    ///
    /// `unclamped` is the delay the file asks for; `delay` is what browsers agreed to allow.
    /// Ancient GIFs ask for zero, meaning "as fast as you can", and every renderer since 1996
    /// has quietly read that as a tenth of a second instead of a strobe.
    private static func delay(of source: CGImageSource, at index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any] else { return 0.1 }

        let frame = (properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            ?? (properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])
            ?? (properties[kCGImagePropertyWebPDictionary] as? [CFString: Any])
            ?? (properties[kCGImagePropertyHEICSDictionary] as? [CFString: Any])

        let unclamped = frame?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = frame?[kCGImagePropertyGIFDelayTime] as? Double
        let seconds = unclamped ?? clamped ?? 0.1

        return seconds < 0.011 ? 0.1 : seconds
    }

    // MARK: - Short films

    /// Turns a bridged GIF back into an animation.
    ///
    /// The frames are taken at even intervals rather than at the film's own rate: a two second
    /// clip at sixty frames a second is a hundred and twenty pictures, and a dozen of them
    /// carries the movement at the size this ever gets shown.
    ///
    /// Not on a watch. watchOS ships AVFoundation without the frame reader, so there is no way
    /// to get a picture out of an MP4 there at all — a bridged GIF falls back to the still that
    /// was uploaded with it, which at least arrives instead of hanging.
    public static func image(fromVideoAt url: URL, limits: Limits) async -> UIImage? {
        #if os(watchOS)
        return nil
        #else
        let asset = AVURLAsset(url: url)

        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            return nil
        }

        let seconds = min(duration.seconds, 8)
        let count = max(2, min(limits.maximumFrames, Int(seconds * 12)))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: limits.maximumPixelSize, height: limits.maximumPixelSize
        )
        // Exact frames are far slower to find than nearby ones, and nobody watching a GIF is
        // counting.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        var frames: [UIImage] = []

        for index in 0..<count {
            let time = CMTime(
                seconds: seconds * Double(index) / Double(count), preferredTimescale: 600
            )

            guard let cgImage = try? await generator.image(at: time).image else { continue }
            frames.append(UIImage(cgImage: cgImage))
        }

        guard !frames.isEmpty else { return nil }
        guard frames.count > 1 else { return frames[0] }

        return UIImage.animatedImage(with: frames, duration: seconds)
        #endif
    }

    /// One frame, for a film that arrived without a preview picture of its own.
    ///
    /// A second in, rather than at the very start: films often open on a black frame, and a
    /// black rectangle in a conversation looks like something that failed to load.
    public static func still(fromVideoAt url: URL, limits: Limits) async -> UIImage? {
        #if os(watchOS)
        return nil
        #else
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: limits.maximumPixelSize * 2, height: limits.maximumPixelSize * 2
        )
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let at = CMTime(seconds: min(1, duration.seconds / 2), preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: at).image else { return nil }

        return UIImage(cgImage: cgImage)
        #endif
    }

    // MARK: - Files on disk

    /// Downloads an attachment to a file and keeps it there.
    ///
    /// A film can only be read from a file — `AVFoundation` will not take the bytes on their
    /// own — and media on a homeserver never changes, so the copy is worth keeping: scrolling
    /// past the same GIF twice shouldn't cost the radio twice.
    ///
    /// The extension is not cosmetic. AVFoundation works out what a file is from its name
    /// before it looks inside it, and a file called `mxc-example-com-AbCdEf` is nothing at
    /// all as far as it's concerned: no duration, no tracks, no frames, no error worth the
    /// name. Matrix addresses carry no extension, so one has to be put back.
    public static func file(
        for request: URLRequest,
        key: String,
        mimeType: String?,
        limit: Int = 12_000_000
    ) async -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Attachments", isDirectory: true)

        let name = key.map { $0.isLetter || $0.isNumber ? $0 : "-" }.suffix(80)
        let file = directory
            .appendingPathComponent(String(name))
            .appendingPathExtension(fileExtension(for: mimeType))

        if FileManager.default.fileExists(atPath: file.path) { return file }

        // Straight to disk, and measured there. It used to be read whole into memory first
        // and only then held up against the limit — so a film of a few hundred megabytes
        // was already sitting in memory, all of it, at the moment it was turned away, and
        // that is enough for the system to end the app. Downloaded as a file, it never
        // passes through memory at all.
        guard let (temporary, response) = try? await MatrixAPI.download.download(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? .max
        guard size <= limit else { return nil }

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        // Two requests for the same file can be under way at once — a GIF tapped open while
        // its bubble is still fetching it. The second one to finish finds the first one's
        // file already in place, and the move fails; that is not a failure, the file is
        // there. Returning nothing for it left the viewer with a frozen still.
        if (try? FileManager.default.moveItem(at: temporary, to: file)) == nil,
           !FileManager.default.fileExists(atPath: file.path) {
            return nil
        }

        return file
    }

    /// What to call the file so that the rest of the system recognises it.
    private static func fileExtension(for mimeType: String?) -> String {
        switch mimeType?.lowercased() {
        case "video/mp4", "video/mpeg4": "mp4"
        case "video/quicktime": "mov"
        case "video/x-m4v": "m4v"
        case "video/webm": "webm"
        case "video/3gpp": "3gp"
        case "image/gif": "gif"
        case "audio/mpeg": "mp3"
        case "audio/mp4", "audio/aac": "m4a"
        case "audio/ogg": "ogg"
        // Anything else that got this far is a film of some sort, and MP4 is what both
        // bridges send. Guessing right is worth more than guessing nothing.
        default: "mp4"
        }
    }
}
#endif
