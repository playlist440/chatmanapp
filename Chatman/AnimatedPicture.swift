import SwiftUI
import UIKit

/// A picture that can move: a GIF, played or held on its first frame.
///
/// SwiftUI's `Image` draws an animated `UIImage` as its first frame and nothing more, which is
/// why every GIF in the app stood still. A `UIImageView` plays one by itself.
struct AnimatedPicture: UIViewRepresentable {
    let image: UIImage
    var isPlaying: Bool
    var contentMode: UIView.ContentMode = .scaleAspectFill

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = contentMode
        view.clipsToBounds = true
        // Sized by SwiftUI, never by the picture: an image view otherwise asks for the
        // picture's own size and pushes the bubble out of shape.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.contentMode = contentMode
        let shown = isPlaying ? image : (image.images?.first ?? image)
        if view.image !== shown { view.image = shown }
    }
}
